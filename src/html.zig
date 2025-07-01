// At compile time, we generate a function for each common HTML tag.
pub const html = createElement(.html);
pub const head = createElement(.head);
pub const meta = createElement(.meta);
pub const style = createElement(.style);
pub const body = createElement(.body);
pub const h1 = createElement(.h1);
pub const table = createElement(.table);
pub const thead = createElement(.thead);
pub const tbody = createElement(.tbody);
pub const tr = createElement(.tr);
pub const th = createElement(.th);
pub const td = createElement(.td);
pub const a = createElement(.a);
pub const p = createElement(.p);
pub const div = createElement(.div);
pub const autoindex = @import("html/autoindex.zig");

/// Represents an HTML attribute (e.g., class="link").
const Attribute = struct {
    key: []const u8,
    value: []const u8,
};

/// Represents a single HTML node/element. Can contain text or other child nodes.
pub const Node = struct {
    allocator: std.mem.Allocator,
    tag: []const u8,
    attributes: std.ArrayList(Attribute),
    content: union(enum) {
        text: []const u8,
        children: std.ArrayList(*Node),
    },

    /// Recursively deinitializes the node and all of its children.
    pub fn deinit(self: *Node) void {
        switch (self.content) {
            .text => {}, // Text is a slice of a literal, no free needed.
            .children => |*children| {
                for (children.items) |child_node| {
                    child_node.deinit(); // Recursive call
                }
                children.deinit();
            },
        }
        self.attributes.deinit();
        self.allocator.destroy(self);
    }

    /// Renders the node and its children to a writer.
    fn render(self: *const Node, writer: anytype) !void {
        try writer.print("<{s}", .{self.tag});
        for (self.attributes.items) |attr| {
            try writer.print(" {s}=\"{s}\"", .{ attr.key, attr.value });
        }
        try writer.print(">", .{});

        switch (self.content) {
            .text => |txt| try writer.print("{s}", .{txt}),
            .children => |children| {
                for (children.items) |child_node| {
                    try child_node.render(writer);
                }
            },
        }

        try writer.print("</{s}>", .{self.tag});
    }
};

/// Represents the entire HTML document, including the DOCTYPE.
pub const Document = struct {
    root: *Node,

    pub fn init(root_node: *Node) Document {
        return .{
            .root = root_node,
        };
    }

    pub fn deinit(self: *Document) void {
        self.root.deinit();
    }

    /// Renders the full document, including DOCTYPE.
    pub fn render(self: *const Document, writer: anytype) !void {
        try writer.writeAll(
            \\<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
            \\  "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
        );
        try self.root.render(writer);
    }
};

/// COMPTIME MAGIC: This function returns a new function tailored to a specific HTML tag.
fn createElement(comptime tag: @Type(.enum_literal)) fn (std.mem.Allocator, anytype, anytype) std.mem.Allocator.Error!*Node {
    return struct {
        fn generated(
            allocator: std.mem.Allocator,
            // Attributes are passed as an anonymous struct literal, e.g., .{ .class = "foo" }
            comptime_attrs: anytype,
            // Content can be child nodes (a tuple) or text ([]const u8)
            content: anytype,
        ) std.mem.Allocator.Error!*Node {
            const node = try allocator.create(Node);
            node.* = .{
                .allocator = allocator,
                .tag = @tagName(tag),
                .attributes = std.ArrayList(Attribute).init(allocator),
                .content = undefined,
            };

            // At comptime, inspect the attributes struct and add them to the node.
            const AttrsType = @TypeOf(comptime_attrs);
            inline for (@typeInfo(AttrsType).@"struct".fields) |field| {
                const value = @field(comptime_attrs, field.name);
                // For simplicity, we assume all attribute values are string literals.
                try node.attributes.append(.{ .key = field.name, .value = value });
            }

            // At comptime, inspect the content type to see if it's text or children.
            const ContentType = @TypeOf(content);
            switch (@typeInfo(ContentType)) {
                .pointer => |ptr| {
                    const child_type = @typeInfo(ptr.child);
                    if (child_type == .array) {
                        node.content = .{ .text = content };
                    } else if (ptr.size == .slice) {
                        if (ptr.child == u8) {
                            node.content = .{ .text = content };
                        } else if (ptr.child == *Node) {
                            node.content = .{ .children = std.ArrayList(*Node).fromOwnedSlice(allocator, content) };
                        } else {
                            @compileError("Unsupported content type: " ++ @typeName(ContentType));
                        }
                    } else {
                        @compileError("Unsupported content type: " ++ @typeName(ContentType));
                    }
                },
                .@"struct" => {
                    node.content = .{ .children = std.ArrayList(*Node).init(allocator) };
                    inline for (content) |child| {
                        try node.content.children.append(child);
                    }
                },
                else => {
                    @compileError("Unsupported content type: " ++ @typeName(ContentType));
                },
            }

            return node;
        }
    }.generated;
}

// =============================================================================
// ||                              UNIT TESTS                                 ||
// =============================================================================

test "html.zig: basic node creation and rendering" {
    const allocator = std.testing.allocator;

    // 1. Test a simple text node
    const p_node = try p(allocator, .{}, "Hello, World!");
    defer p_node.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();

    try p_node.render(writer);
    try std.testing.expectEqualStrings("<p>Hello, World!</p>", buffer.items);
}

test "html.zig: node with attributes" {
    const allocator = std.testing.allocator;

    const a_node = try a(allocator, .{ .href = "#", .class = "test-link" }, "Click me");
    defer a_node.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();

    try a_node.render(writer);
    // Note: attribute order is not guaranteed, so we test for substrings.
    try std.testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, "<a "));
    try std.testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, " href=\"#\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, " class=\"test-link\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, buffer.items, 1, ">Click me</a>"));
}

test "html.zig: nested nodes" {
    const allocator = std.testing.allocator;

    const child = try p(allocator, .{}, "I am a child.");
    const parent = try div(allocator, .{ .id = "parent" }, .{child});
    defer parent.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();

    try parent.render(writer);
    const expected = "<div id=\"parent\"><p>I am a child.</p></div>";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "html.zig: void element (e.g. meta)" {
    const allocator = std.testing.allocator;

    // In XHTML, even "void" elements can have a full closing tag. Our renderer does this.
    const meta_node = try meta(allocator, .{ .charset = "UTF-8" }, "");
    defer meta_node.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();

    try meta_node.render(writer);
    try std.testing.expectEqualStrings("<meta charset=\"UTF-8\"></meta>", buffer.items);
}

test "html.zig: document rendering with DOCTYPE" {
    const allocator = std.testing.allocator;

    const root_node = try html(allocator, .{}, .{
        try head(allocator, .{}, ""),
    });
    var doc = Document.init(root_node);
    defer doc.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    const writer = buffer.writer();

    try doc.render(writer);

    const rendered_html = buffer.items;
    try std.testing.expect(std.mem.startsWith(u8, rendered_html, "<!DOCTYPE html"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered_html, 1, "<html><head></head></html>"));
}

test "html.zig: multiple nested children in a tuple" {
    const allocator = std.testing.allocator;

    const child1 = try p(allocator, .{}, "First paragraph.");
    const child2 = try div(allocator, .{}, "Second element is a div.");

    // Create a parent with a tuple containing multiple children
    const parent = try div(allocator, .{ .id = "container" }, .{ child1, child2 });
    defer parent.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try parent.render(buffer.writer());

    const expected = "<div id=\"container\"><p>First paragraph.</p><div>Second element is a div.</div></div>";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "autoindex" {
    _ = autoindex;
}

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
