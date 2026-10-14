//! Bounded plain-text reads of terminal history for an embedder's
//! "copy context" actions. Every read is capped in rows, inspected cells and
//! output bytes, and keeps the most recent end when a cap is reached. The
//! embedder owns clipboard authority: nothing here writes the clipboard.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const ScreenFormatter = @import("formatter.zig").ScreenFormatter;
const Selection = @import("Selection.zig");

/// The largest UTF-8 result returned by one read.
pub const max_output_bytes = 1024 * 1024;

/// The largest number of rows a scrollback tail read may request.
pub const max_tail_lines = 500;

/// The largest number of terminal cells formatted by one read.
pub const max_cell_work = 1 << 20;

pub const Kind = enum(u8) {
    /// The last `max_lines` rows of scrollback plus screen, ending at the
    /// lower of the cursor row and the last active row with text.
    scrollback_tail = 0,

    /// The most recent completed command: its prompt/command line through
    /// the end of its output, located with semantic prompt (OSC 133) marks.
    last_command = 1,
};

pub const Error = error{
    InvalidKind,
    InvalidLines,
    NoPrompts,
    NoContent,
    OutputTooLarge,
} || Allocator.Error;

/// Read bounded text into a newly allocated, sentinel-terminated string the
/// caller frees with `alloc`. `max_lines` applies to `scrollback_tail` only.
pub fn read(
    alloc: Allocator,
    screen: *const Screen,
    kind_raw: u8,
    max_lines: u32,
) Error![:0]u8 {
    const kind = std.enums.fromInt(Kind, kind_raw) orelse return error.InvalidKind;
    const range: Range = switch (kind) {
        .scrollback_tail => tail: {
            if (max_lines == 0 or max_lines > max_tail_lines) return error.InvalidLines;
            break :tail .{
                .floor = screen.pages.getTopLeft(.screen),
                .bottom = contentBottom(screen),
                .max_rows = max_lines,
            };
        },
        .last_command => try lastCommandRange(screen),
    };

    const output = try alloc.alloc(u8, max_output_bytes);
    defer alloc.free(output);
    const text = try formatTail(screen, range, output);
    if (text.len == 0) return error.NoContent;
    return try alloc.dupeZ(u8, text);
}

/// True when the active screen holds a completed command that `read` with
/// `last_command` can return. Iterates row metadata only.
pub fn hasLastCommand(screen: *const Screen) bool {
    _ = lastCommandRange(screen) catch return false;
    return true;
}

const Range = struct {
    /// The highest row the read may include.
    floor: Pin,
    /// The last row of the read.
    bottom: Pin,
    /// The most rows to read, counted up from `bottom`.
    max_rows: usize,
};

fn lastCommandRange(screen: *const Screen) Error!Range {
    // Without any prompt mark the iterator would walk all scrollback for
    // nothing; shell integration sets this flag on the first prompt.
    if (!screen.semantic_prompt.seen) return error.NoPrompts;

    // The first prompt at or above the cursor is the current one (the shell
    // is idle at it, or its command is still running). The prompt before it
    // is the most recent completed command.
    var it = screen.cursor.page_pin.promptIterator(.left_up, null);
    const current = it.next() orelse return error.NoPrompts;
    const previous = it.next() orelse return error.NoContent;
    const bottom = current.up(1) orelse return error.NoContent;
    return .{ .floor = previous, .bottom = bottom, .max_rows = std.math.maxInt(usize) };
}

/// The cursor row, or the last active row with text when that is lower.
fn contentBottom(screen: *const Screen) Pin {
    const pages = &screen.pages;
    var y: usize = pages.rows;
    while (y > screen.cursor.y + 1) {
        y -= 1;
        const pin = pages.pin(.{ .active = .{ .x = 0, .y = @intCast(y) } }).?;
        for (pin.cells(.all)) |cell| if (cell.hasText()) return pin;
    }
    return pages.pin(.{ .active = .{ .x = 0, .y = screen.cursor.y } }).?;
}

/// Rows from `floor` through `bottom` inclusive, or null beyond `limit`.
fn rowsThrough(floor: Pin, bottom: Pin, limit: usize) ?usize {
    var pin = bottom;
    var rows: usize = 1;
    while (true) : (rows += 1) {
        if (pin.node == floor.node and pin.y == floor.y) return rows;
        if (rows >= limit) return null;
        pin = pin.up(1) orelse return null;
    }
}

/// Format the most recent rows of `range`, halving the row count until the
/// result fits in `output`.
fn formatTail(screen: *const Screen, range: Range, output: []u8) Error![]const u8 {
    const cols: usize = @max(1, range.bottom.node.cols());
    const cell_rows = @max(1, max_cell_work / cols);
    const limit = @min(range.max_rows, cell_rows);
    const available = rowsThrough(range.floor, range.bottom, limit);
    var rows = available orelse limit;
    while (rows > 0) : (rows /= 2) {
        var top = if (available != null and rows == available.?)
            range.floor
        else
            range.bottom.up(rows - 1) orelse range.floor;
        top.x = 0;
        var bottom = range.bottom;
        bottom.x = bottom.node.cols() - 1;

        var writer: std.Io.Writer = .fixed(output);
        var formatter: ScreenFormatter = .init(screen, .{
            .emit = .plain,
            .unwrap = true,
            .trim = true,
        });
        formatter.content = .{ .selection = Selection.init(top, bottom, false) };
        formatter.format(&writer) catch continue;
        return writer.buffered();
    }
    return error.OutputTooLarge;
}

fn testScreen(cols: usize, rows: usize) !Screen {
    return try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .max_scrollback_bytes = 64 * 1024 * 1024,
    });
}

test "tail returns the most recent rows including scrollback" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(20, 5);
    defer screen.deinit();
    for (0..40) |i| {
        var buf: [32]u8 = undefined;
        try screen.testWriteString(try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    try screen.testWriteString("$ ");

    const text = try read(alloc, &screen, 0, 12);
    defer alloc.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    var last: []const u8 = "";
    var first: []const u8 = "";
    while (lines.next()) |line| : (count += 1) {
        if (count == 0) first = line;
        last = line;
    }
    try std.testing.expectEqual(@as(usize, 12), count);
    try std.testing.expectEqualStrings("line 29", first);
    try std.testing.expectEqualStrings("$", last);
}

test "tail returns all rows when history is shorter than requested" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(20, 10);
    defer screen.deinit();
    try screen.testWriteString("one\ntwo\nthree");

    const text = try read(alloc, &screen, 0, 500);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("one\ntwo\nthree", text);
}

test "tail unwraps soft-wrapped rows" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(4, 4);
    defer screen.deinit();
    try screen.testWriteString("abcdefgh\nz");

    const text = try read(alloc, &screen, 0, 3);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("abcdefgh\nz", text);
}

test "tail rejects invalid line counts and kinds" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(10, 3);
    defer screen.deinit();
    try screen.testWriteString("x");
    try std.testing.expectError(error.InvalidLines, read(alloc, &screen, 0, 0));
    try std.testing.expectError(error.InvalidLines, read(alloc, &screen, 0, max_tail_lines + 1));
    try std.testing.expectError(error.InvalidKind, read(alloc, &screen, 2, 1));
}

test "tail of a blank screen has no content" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(10, 3);
    defer screen.deinit();
    try std.testing.expectError(error.NoContent, read(alloc, &screen, 0, 10));
}

fn writeCommand(screen: *Screen, prompt: []const u8, command: []const u8, output: []const u8) !void {
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString(prompt);
    screen.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try screen.testWriteString(command);
    try screen.testWriteString("\n");
    screen.cursorSetSemanticContent(.output);
    try screen.testWriteString(output);
}

test "last command returns the previous command line and its output" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(20, 10);
    defer screen.deinit();
    try writeCommand(&screen, "$ ", "ls", "a\nb\n");
    try writeCommand(&screen, "$ ", "echo hello", "hello\n");
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString("$ ");

    try std.testing.expect(hasLastCommand(&screen));
    const text = try read(alloc, &screen, 1, 0);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("$ echo hello\nhello", text);
}

test "last command skips a running command" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(20, 10);
    defer screen.deinit();
    try writeCommand(&screen, "$ ", "echo done", "done\n");
    try writeCommand(&screen, "$ ", "sleep 9", "partial");

    const text = try read(alloc, &screen, 1, 0);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("$ echo done\ndone", text);
}

test "last command reads from scrollback" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(20, 4);
    defer screen.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    for (0..30) |i| try output.print(alloc, "out {d}\n", .{i});
    try writeCommand(&screen, "% ", "seq", output.items);
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString("% ");

    const text = try read(alloc, &screen, 1, 0);
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "% seq\nout 0\n"));
    try std.testing.expect(std.mem.endsWith(u8, text, "out 29"));
}

test "last command is unavailable without prompt marks" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(20, 4);
    defer screen.deinit();
    try screen.testWriteString("$ echo hello\nhello\n$ ");
    try std.testing.expect(!hasLastCommand(&screen));
    try std.testing.expectError(error.NoPrompts, read(alloc, &screen, 1, 0));
}

test "last command is unavailable at the first prompt" {
    const alloc = std.testing.allocator;
    var screen = try testScreen(20, 4);
    defer screen.deinit();
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString("$ ");
    try std.testing.expect(!hasLastCommand(&screen));
    try std.testing.expectError(error.NoContent, read(alloc, &screen, 1, 0));
}

test "output beyond the byte cap keeps the most recent rows" {
    const alloc = std.testing.allocator;
    // 500 rows of 4096 columns exceed the 1 MiB cap; halving keeps the tail.
    var screen = try testScreen(4096, 2);
    defer screen.deinit();
    const row = try alloc.alloc(u8, 4096);
    defer alloc.free(row);
    @memset(row, 'x');
    for (0..300) |i| {
        row[0] = @intCast('a' + i % 26);
        try screen.testWriteString(row);
        try screen.testWriteString("\n");
    }
    try screen.testWriteString("end");

    const text = try read(alloc, &screen, 0, 500);
    defer alloc.free(text);
    try std.testing.expect(text.len <= max_output_bytes);
    try std.testing.expect(std.mem.endsWith(u8, text, "\nend"));
}
