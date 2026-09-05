const std = @import("std");
const Screen = @import("Screen.zig");
const ScreenFormatter = @import("formatter.zig").ScreenFormatter;
const Selection = @import("Selection.zig");

/// The largest UTF-8 snapshot accepted by the embedded API.
pub const max_output_bytes = 64 * 1024;

/// The largest number of terminal cells inspected by one snapshot.
pub const max_cell_work = 65_536;

const Mode = enum(u8) {
    cursor_context = 0,
    active_screen = 1,
};

pub const Result = struct {
    columns: u16,
    rows: u16,
    cursor_col: u16,
    cursor_row: u16,
    first_row: u16,
    row_count: u16,
    pending_wrap: bool,
    text: []const u8,
};

/// Format a bounded, active-screen-only snapshot into caller-owned storage.
/// The returned text borrows `output`; no allocation or renderer state is used.
pub fn read(
    screen: *const Screen,
    mode_raw: u8,
    output: []u8,
) error{ InvalidMode, InvalidScreen, TooManyCells, OutputTooLarge }!Result {
    const mode = std.enums.fromInt(Mode, mode_raw) orelse return error.InvalidMode;
    const columns = screen.pages.cols;
    const rows = screen.pages.rows;
    const cursor = screen.cursor;
    if (columns == 0 or rows == 0 or cursor.y >= rows) return error.InvalidScreen;

    const first_row: u16 = switch (mode) {
        .cursor_context => cursor.y -| 5,
        .active_screen => 0,
    };
    const row_count: u16 = switch (mode) {
        .cursor_context => cursor.y - first_row + 1,
        .active_screen => rows,
    };
    const cells = std.math.mul(
        usize,
        @as(usize, columns),
        @as(usize, row_count),
    ) catch return error.TooManyCells;
    if (cells > max_cell_work) return error.TooManyCells;

    var writer: std.Io.Writer = .fixed(output[0..@min(output.len, max_output_bytes)]);
    var row = first_row;
    for (0..row_count) |_| {
        formatRow(screen, row, &writer) catch return error.OutputTooLarge;
        writer.writeByte('\n') catch return error.OutputTooLarge;
        row += 1;
    }

    return .{
        .columns = columns,
        .rows = rows,
        .cursor_col = cursor.x,
        .cursor_row = cursor.y,
        .first_row = first_row,
        .row_count = row_count,
        .pending_wrap = cursor.pending_wrap,
        .text = writer.buffered(),
    };
}

fn formatRow(
    screen: *const Screen,
    row: u16,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const top_left = screen.pages.pin(.{ .active = .{ .x = 0, .y = row } }) orelse
        return error.WriteFailed;
    const bottom_right = screen.pages.pin(.{ .active = .{
        .x = screen.pages.cols - 1,
        .y = row,
    } }) orelse return error.WriteFailed;

    var formatter: ScreenFormatter = .init(screen, .{
        .emit = .plain,
        .unwrap = false,
        .trim = false,
    });
    formatter.content = .{ .selection = Selection.init(top_left, bottom_right, false) };
    try formatter.format(writer);
}

test "cursor context is limited to six active-screen rows" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 8,
        .rows = 10,
        .max_scrollback_bytes = 1_024,
    });
    defer screen.deinit();
    try screen.testWriteString("0\n1\n2\n3\n4\n5\n6\n7");

    var output: [256]u8 = undefined;
    const result = try read(&screen, 0, &output);

    try std.testing.expectEqual(@as(u16, 2), result.first_row);
    try std.testing.expectEqual(@as(u16, 6), result.row_count);
    try std.testing.expectEqualStrings("2\n3\n4\n5\n6\n7\n", result.text);
}

test "cursor context preserves blank rows at the top and cursor" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 8,
        .rows = 4,
        .max_scrollback_bytes = 1_024,
    });
    defer screen.deinit();
    try screen.testWriteString("top\n\n");

    var output: [256]u8 = undefined;
    const result = try read(&screen, 0, &output);

    try std.testing.expectEqual(@as(u16, 0), result.first_row);
    try std.testing.expectEqual(@as(u16, 3), result.row_count);
    try std.testing.expectEqualStrings("top\n\n\n", result.text);
}

test "snapshot keeps visual soft-wrap rows and exact metadata" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 3,
        .rows = 3,
        .max_scrollback_bytes = 1_024,
    });
    defer screen.deinit();
    try screen.testWriteString("abcdef");

    var output: [256]u8 = undefined;
    const result = try read(&screen, 0, &output);

    try std.testing.expectEqual(@as(u16, 3), result.columns);
    try std.testing.expectEqual(@as(u16, 3), result.rows);
    try std.testing.expectEqual(@as(u16, 2), result.cursor_col);
    try std.testing.expectEqual(@as(u16, 1), result.cursor_row);
    try std.testing.expect(result.pending_wrap);
    try std.testing.expectEqualStrings("abc\ndef\n", result.text);
}

test "whole active screen excludes scrollback" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 8,
        .rows = 2,
        .max_scrollback_bytes = 1_024,
    });
    defer screen.deinit();
    try screen.testWriteString("one\ntwo\nthree");

    var output: [256]u8 = undefined;
    const result = try read(&screen, 1, &output);

    try std.testing.expectEqual(@as(u16, 0), result.first_row);
    try std.testing.expectEqual(@as(u16, 2), result.row_count);
    try std.testing.expectEqualStrings("two\nthree\n", result.text);
}

test "whole active screen preserves blank trailing rows" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback_bytes = 1_024,
    });
    defer screen.deinit();
    try screen.testWriteString("ready");

    var output: [256]u8 = undefined;
    const result = try read(&screen, 1, &output);

    try std.testing.expectEqual(@as(u16, 3), result.row_count);
    try std.testing.expectEqualStrings("ready\n\n\n", result.text);
}

test "snapshot rejects invalid mode without writing output" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 8,
        .rows = 2,
        .max_scrollback_bytes = 1_024,
    });
    defer screen.deinit();

    var output = [_]u8{0xaa} ** 8;
    try std.testing.expectError(error.InvalidMode, read(&screen, 2, &output));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xaa} ** 8, &output);
}

test "snapshot rejects multibyte combining output beyond the fixed cap" {
    const alloc = std.testing.allocator;
    const repetitions = 32_768;

    var screen = try Screen.init(std.testing.io, alloc, .{
        .cols = repetitions,
        .rows = 1,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();

    const input = try alloc.alloc(u8, 3 + 2 * (repetitions - 1));
    defer alloc.free(input);
    @memcpy(input[0..3], "e\u{301}");
    for (0..repetitions - 1) |index| {
        @memcpy(input[3 + 2 * index ..][0..2], "é");
    }
    try screen.testWriteString(input);

    var output: [max_output_bytes]u8 = undefined;
    try std.testing.expectError(error.OutputTooLarge, read(&screen, 1, &output));
}
