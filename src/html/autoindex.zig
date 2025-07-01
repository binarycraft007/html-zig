//==============================================================================
// 1. PUBLIC API & CONFIGURATION
//==============================================================================

/// User-facing options for the autoindexer.
pub const Options = struct {
    /// The root directory on the filesystem to start indexing from.
    root_fs_path: []const u8,
    /// The base URL to prepend to all generated links.
    base_url: []const u8,
    /// Optional custom CSS. If null, a default style is used.
    custom_style: ?[]const u8 = null,
};

/// Indexes an entire directory tree recursively and generates an `index.html`
/// file in each subdirectory. This is the primary public entry point.
pub fn indexTree(gpa: std.mem.Allocator, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // First, build a complete, in-memory representation of the directory tree.
    // This separates filesystem access from HTML generation.
    const root_dir_node = try buildDirectoryTree(allocator, options.root_fs_path);

    // Now, walk our in-memory tree and generate an index.html for each directory.
    try renderTree(allocator, root_dir_node, options);
}

//==============================================================================
// 2. INTERNAL DATA MODEL
// These structs represent the filesystem in memory.
//==============================================================================

const File = struct {
    name: []const u8,
    size: u64,
    mod_time: u64,

    pub fn formatSize(self: File, allocator: std.mem.Allocator) ![]const u8 {
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
        var unit_index: usize = 0;
        var readable_size: f64 = @floatFromInt(self.size);
        while (readable_size >= 1024 and unit_index < units.len - 1) {
            readable_size /= 1024;
            unit_index += 1;
        }
        if (unit_index == 0) {
            return std.fmt.allocPrint(allocator, "{d} {s}", .{ self.size, units[unit_index] });
        } else {
            return std.fmt.allocPrint(allocator, "{d:.2} {s}", .{ readable_size, units[unit_index] });
        }
    }

    pub fn formatTimestamp(self: File, allocator: std.mem.Allocator) ![]const u8 {
        const epoch_sec: std.time.epoch.EpochSeconds = .{ .secs = self.mod_time };
        const day_seconds = epoch_sec.getDaySeconds();
        const epoch_day = epoch_sec.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return try std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }
};

const Directory = struct {
    name: []const u8,
    web_path: []const u8, // The URL path from the base, e.g., "/aarch64/subdir"
    fs_path: []const u8, // The full filesystem path
    mod_time: u64,
    files: std.ArrayList(File),
    subdirs: std.ArrayList(Directory),
};

//==============================================================================
// 3. FILESYSTEM LOGIC
// Logic for reading the disk and building our data model.
//==============================================================================

/// Recursively scans a filesystem path and builds an in-memory `Directory` tree.
/// This function isolates all filesystem I/O.
fn buildDirectoryTree(allocator: std.mem.Allocator, root_fs_path: []const u8) !Directory {
    var root_dir = try std.fs.cwd().openDir(root_fs_path, .{ .iterate = true });
    defer root_dir.close();

    return try buildDirRecursive(allocator, root_dir, "/", root_fs_path);
}

const skip_list: []const []const u8 = @import("skip_list.zon");

fn buildDirRecursive(
    allocator: std.mem.Allocator,
    dir_handle: std.fs.Dir,
    current_web_path: []const u8,
    current_fs_path: []const u8,
) !Directory {
    const metadata = try dir_handle.metadata();
    var dir_node = Directory{
        .name = std.fs.path.basename(current_fs_path),
        .web_path = current_web_path,
        .fs_path = current_fs_path,
        .mod_time = @intCast(@divTrunc(metadata.modified(), std.time.ns_per_s)),
        .files = std.ArrayList(File).init(allocator),
        .subdirs = std.ArrayList(Directory).init(allocator),
    };

    var dir_iter = dir_handle.iterate();
    while (try dir_iter.next()) |entry| {
        // Skip hidden files and our own output files.
        if (entry.name[0] == '.') continue;
        for (skip_list) |file| if (std.mem.eql(u8, entry.name, file)) continue;

        const child_fs_path = try std.fs.path.join(allocator, &.{ current_fs_path, entry.name });
        switch (entry.kind) {
            .file => {
                const file_handle = try dir_handle.openFile(entry.name, .{});
                defer file_handle.close();
                const meta = try file_handle.metadata();
                try dir_node.files.append(.{
                    .name = try allocator.dupe(u8, entry.name),
                    .size = meta.size(),
                    .mod_time = @intCast(@divTrunc(meta.modified(), std.time.ns_per_s)),
                });
            },
            .directory => {
                var subdir_handle = try dir_handle.openDir(entry.name, .{ .iterate = true });
                defer subdir_handle.close();
                const child_web_path = try std.fs.path.join(allocator, &.{ current_web_path, entry.name });
                const subdir_node = try buildDirRecursive(allocator, subdir_handle, child_web_path, child_fs_path);
                try dir_node.subdirs.append(subdir_node);
            },
            else => {},
        }
    }
    return dir_node;
}

//==============================================================================
// 4. RENDERING LOGIC
// Logic for taking the data model and generating HTML.
//==============================================================================
const default_style = @embedFile("default_style.css");

/// Recursively walks the in-memory `Directory` tree and writes an `index.html`
/// for each node.
fn renderTree(gpa: std.mem.Allocator, dir_node: Directory, options: Options) !void {
    // Generate index.html for the current directory
    try renderSingleIndex(gpa, dir_node, options);

    // Recurse into subdirectories
    for (dir_node.subdirs.items) |subdir| {
        try renderTree(gpa, subdir, options);
    }
}

/// Renders a single index.html file for a given `Directory` node.
fn renderSingleIndex(gpa: std.mem.Allocator, dir_node: Directory, options: Options) !void {
    var file = try std.fs.cwd().createFile(
        try std.fs.path.join(gpa, &.{ dir_node.fs_path, "index.html" }),
        .{ .truncate = true },
    );
    defer file.close();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const is_root = std.mem.eql(u8, dir_node.web_path, "/");

    var table_rows = std.ArrayList(*html.Node).init(allocator);

    // Parent directory link
    if (!is_root) {
        const parent_web_path = std.fs.path.dirname(dir_node.web_path) orelse "/";
        const parent_url = try std.fs.path.join(allocator, &.{ options.base_url, parent_web_path });
        try table_rows.append(try html.tr(allocator, .{}, .{
            try html.td(allocator, .{ .class = "link" }, .{try html.a(allocator, .{ .href = parent_url }, "Parent directory/")}),
            try html.td(allocator, .{ .class = "size" }, "-"),
            try html.td(allocator, .{ .class = "date" }, "-"),
        }));
    }

    // Subdirectories
    for (dir_node.subdirs.items) |subdir| {
        const url = try std.fs.path.join(allocator, &.{ options.base_url, subdir.web_path });
        var child = File{ .mod_time = subdir.mod_time, .name = "", .size = 0 };
        try table_rows.append(try html.tr(allocator, .{}, .{
            try html.td(allocator, .{ .class = "link" }, .{try html.a(allocator, .{ .href = url, .title = subdir.name }, subdir.name)}),
            try html.td(allocator, .{ .class = "size" }, "-"),
            try html.td(allocator, .{ .class = "date" }, try child.formatTimestamp(allocator)),
        }));
    }

    // Files
    for (dir_node.files.items) |file_entry| {
        const url = try std.fs.path.join(allocator, &.{ options.base_url, dir_node.web_path, file_entry.name });
        try table_rows.append(try html.tr(allocator, .{}, .{
            try html.td(allocator, .{ .class = "link" }, .{try html.a(allocator, .{ .href = url, .title = file_entry.name }, file_entry.name)}),
            try html.td(allocator, .{ .class = "size" }, try file_entry.formatSize(allocator)),
            try html.td(allocator, .{ .class = "date" }, try file_entry.formatTimestamp(allocator)),
        }));
    }

    const doc = html.Document.init(try html.html(
        allocator,
        .{ .xmlns = "http://www.w3.org/1999/xhtml" },
        .{
            try html.head(allocator, .{}, .{
                try html.meta(allocator, .{ .name = "viewport", .content = "width=device-width" }, ""),
                try html.meta(allocator, .{ .@"http-equiv" = "content-type", .content = "text/html; charset=UTF-8" }, ""),
                try html.style(allocator, .{ .type = "text/css" }, options.custom_style orelse default_style),
            }),
            try html.body(allocator, .{}, .{
                try html.h1(allocator, .{}, try std.fmt.allocPrint(allocator, "Index of {s}", .{dir_node.web_path})),
                try html.table(allocator, .{ .id = "list" }, .{
                    try html.thead(allocator, .{}, .{
                        try html.tr(allocator, .{}, .{
                            try html.th(allocator, .{ .style = "width:55%" }, "File Name"),
                            try html.th(allocator, .{ .style = "width:20%" }, "File Size"),
                            try html.th(allocator, .{ .style = "width:25%" }, "Date"),
                        }),
                    }),
                    try html.tbody(allocator, .{}, try table_rows.toOwnedSlice()),
                }),
            }),
        },
    ));

    try doc.render(file.writer());
}

test {
    var tmpdir = testing.tmpDir(.{});
    defer tmpdir.cleanup();
    var file = try tmpdir.dir.createFile("test", .{});
    defer file.close();
    const file_path = try tmpdir.parent_dir.realpathAlloc(testing.allocator, &tmpdir.sub_path);
    defer testing.allocator.free(file_path);
    try indexTree(testing.allocator, .{
        .base_url = "http://example.com",
        .root_fs_path = file_path,
    });
}

const std = @import("std");
const testing = std.testing;
const html = @import("../html.zig");
