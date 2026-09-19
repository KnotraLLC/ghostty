const std = @import("std");
const Screen = @import("Screen.zig");
const PageList = @import("PageList.zig");
const page = @import("page.zig");
const style = @import("style.zig");
const color = @import("color.zig");
const cursor = @import("cursor.zig");

/// Versioned, little-endian DMS1 payload limits. The embedded API allocates
/// only after this encoder has produced a complete payload.
pub const max_columns = 300;
pub const max_rows = 200;
pub const max_styles = 64;
pub const max_bytes = 256 * 1024;

const header_len = 22;
const style_len = 16;
const run_len = 10;
const null_color = 0xffffffff;

pub const Error = error{
    TooLarge,
    TooManyStyles,
    UnsupportedVisualState,
};

pub const Options = struct {
    palette: *const color.Palette,
    foreground: ?color.RGB,
    background: ?color.RGB,
    bold_color: ?style.Style.BoldColor,
    active_alternate: bool,
    application_cursor: bool,
    bracketed_paste: bool,
    cursor_visible: bool,
    cursor_shape: cursor.Style,
};

const WireStyle = struct {
    fg: u32,
    bg: u32,
    underline: u32,
    flags: u16,
    underline_style: u8,

    fn eql(self: WireStyle, other: WireStyle) bool {
        return std.meta.eql(self, other);
    }
};

/// Encode the active screen as a complete DMS1 buffer. Callers must hold the
/// renderer-state mutex for the lifetime of this call.
pub fn read(
    screen: *const Screen,
    options: Options,
    output: []u8,
) Error![]const u8 {
    const columns = screen.pages.cols;
    const rows = screen.pages.rows;
    if (columns > max_columns or rows > max_rows) return error.TooLarge;
    if (output.len < max_bytes) return error.TooLarge;

    var styles: [max_styles]WireStyle = undefined;
    var style_count: usize = 0;
    try collectStyles(screen, options, &styles, &style_count);

    var writer: std.Io.Writer = .fixed(output[0..max_bytes]);
    writeHeader(&writer, screen, options, @intCast(style_count)) catch return error.TooLarge;
    for (styles[0..style_count]) |entry| {
        writeStyle(&writer, entry) catch return error.TooLarge;
    }

    const run_count_offset = header_len - @sizeOf(u32);
    var run_count: u32 = 0;
    for (0..rows) |row| {
        var column: usize = 0;
        while (column < columns) {
            const pin = screen.pages.pin(.{ .active = .{
                .x = @intCast(column),
                .y = @intCast(row),
            } }) orelse return error.UnsupportedVisualState;
            const cell = pin.rowAndCell().cell;

            // A wide tail belongs to its leading cell. Emitting it separately
            // would let a decoder render a phantom grapheme.
            if (cell.wide == .spacer_tail) {
                column += 1;
                continue;
            }

            const wire_style = try resolveStyle(pin, cell, options);
            const style_index = styleIndex(styles[0..style_count], wire_style) orelse
                return error.UnsupportedVisualState;

            var text: [4 + page.grapheme_max_len * 4]u8 = undefined;
            const text_len = try encodeGrapheme(pin, cell, &text);
            const width: u8 = switch (cell.wide) {
                .wide => 2,
                // The final column of a soft-wrapped wide grapheme is a
                // visible blank cell. Its glyph is owned by the next row's
                // wide cell, so serialize only this styled blank here.
                .spacer_head => 1,
                .narrow => 1,
                .spacer_tail => unreachable,
            };

            // Blank, one-cell runs may be repeated only when their resolved
            // visual style is identical. `repeat * width` owns grid cells.
            var repeat: u16 = 1;
            if (text_len == 0 and width == 1) while (column + @as(usize, repeat) < columns and repeat < std.math.maxInt(u16)) {
                const next_pin = screen.pages.pin(.{ .active = .{
                    .x = @intCast(column + @as(usize, repeat)),
                    .y = @intCast(row),
                } }) orelse return error.UnsupportedVisualState;
                const next = next_pin.rowAndCell().cell;
                if (next.wide != .narrow) break;
                if ((try encodeGrapheme(next_pin, next, &text)) != 0) break;
                if (!(try resolveStyle(next_pin, next, options)).eql(wire_style)) break;
                repeat += 1;
            };

            writer.writeInt(u16, @intCast(row), .little) catch return error.TooLarge;
            writer.writeInt(u16, @intCast(column), .little) catch return error.TooLarge;
            writer.writeInt(u16, repeat, .little) catch return error.TooLarge;
            writer.writeByte(width) catch return error.TooLarge;
            writer.writeByte(@intCast(style_index)) catch return error.TooLarge;
            writer.writeInt(u16, @intCast(text_len), .little) catch return error.TooLarge;
            writer.writeAll(text[0..text_len]) catch return error.TooLarge;
            run_count = std.math.add(u32, run_count, 1) catch return error.TooLarge;
            column += @as(usize, repeat) * @as(usize, width);
        }
    }

    std.mem.writeInt(u32, output[run_count_offset..][0..4], run_count, .little);
    return writer.buffered();
}

fn collectStyles(
    screen: *const Screen,
    options: Options,
    styles: *[max_styles]WireStyle,
    style_count: *usize,
) Error!void {
    for (0..screen.pages.rows) |row| for (0..screen.pages.cols) |column| {
        const pin = screen.pages.pin(.{ .active = .{
            .x = @intCast(column),
            .y = @intCast(row),
        } }) orelse return error.UnsupportedVisualState;
        const cell = pin.rowAndCell().cell;
        if (cell.wide == .spacer_tail) continue;
        const entry = try resolveStyle(pin, cell, options);
        if (styleIndex(styles[0..style_count.*], entry) != null) continue;
        if (style_count.* == max_styles) return error.TooManyStyles;
        styles[style_count.*] = entry;
        style_count.* += 1;
    };
}

fn resolveStyle(
    pin: PageList.Pin,
    cell: *const page.Cell,
    options: Options,
) Error!WireStyle {
    if (cell.codepoint() == 0x10EEEE) return error.UnsupportedVisualState;
    const source = pin.style(cell);
    const foreground = resolveForeground(source, options);
    const background = source.bg(cell, options.palette) orelse options.background;
    const underline = source.underlineColor(options.palette);
    return .{
        .fg = rgbInt(foreground),
        .bg = rgbInt(background),
        .underline = rgbInt(underline),
        .flags = flags(source),
        .underline_style = @intFromEnum(source.flags.underline),
    };
}

fn resolveForeground(source: style.Style, options: Options) ?color.RGB {
    const default = options.foreground orelse return switch (source.fg_color) {
        .none => null,
        .palette => |index| options.palette[index],
        .rgb => |value| value,
    };
    return source.fg(.{
        .default = default,
        .palette = options.palette,
        .bold = options.bold_color,
    });
}

fn flags(source: style.Style) u16 {
    var result: u16 = 0;
    if (source.flags.bold) result |= 1 << 0;
    if (source.flags.faint) result |= 1 << 1;
    if (source.flags.italic) result |= 1 << 2;
    if (source.flags.invisible) result |= 1 << 3;
    if (source.flags.blink) result |= 1 << 4;
    if (source.flags.overline) result |= 1 << 5;
    if (source.flags.strikethrough) result |= 1 << 6;
    if (source.flags.inverse) result |= 1 << 7;
    return result;
}

fn rgbInt(value: ?color.RGB) u32 {
    const rgb = value orelse return null_color;
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

fn styleIndex(styles: []const WireStyle, wanted: WireStyle) ?usize {
    for (styles, 0..) |entry, index| if (entry.eql(wanted)) return index;
    return null;
}

fn encodeGrapheme(
    pin: PageList.Pin,
    cell: *const page.Cell,
    output: []u8,
) Error!usize {
    if (!cell.hasText()) return 0;
    var length = std.unicode.utf8Encode(cell.codepoint(), output[0..4]) catch
        return error.UnsupportedVisualState;
    if (pin.grapheme(cell)) |extra| for (extra) |codepoint| {
        length += std.unicode.utf8Encode(codepoint, output[length..]) catch
            return error.UnsupportedVisualState;
    };
    return length;
}

fn writeHeader(
    writer: *std.Io.Writer,
    screen: *const Screen,
    options: Options,
    style_count: u8,
) std.Io.Writer.Error!void {
    try writer.writeAll("DMS1");
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, screen.pages.cols, .little);
    try writer.writeInt(u16, screen.pages.rows, .little);
    try writer.writeInt(u16, screen.cursor.x, .little);
    try writer.writeInt(u16, screen.cursor.y, .little);
    try writer.writeByte(@intFromBool(options.cursor_visible));
    try writer.writeByte(cursorShape(options.cursor_shape));
    var modes: u8 = 0;
    if (options.active_alternate) modes |= 1 << 0;
    if (options.application_cursor) modes |= 1 << 1;
    if (options.bracketed_paste) modes |= 1 << 2;
    try writer.writeByte(modes);
    try writer.writeByte(style_count);
    try writer.writeInt(u32, 0, .little); // Backfilled after runs are emitted.
}

fn cursorShape(value: cursor.Style) u8 {
    return switch (value) {
        .block, .block_hollow => 0,
        .bar => 1,
        .underline => 2,
    };
}

fn writeStyle(writer: *std.Io.Writer, entry: WireStyle) std.Io.Writer.Error!void {
    try writer.writeInt(u32, entry.fg, .little);
    try writer.writeInt(u32, entry.bg, .little);
    try writer.writeInt(u32, entry.underline, .little);
    try writer.writeInt(u16, entry.flags, .little);
    try writer.writeByte(entry.underline_style);
    try writer.writeByte(0);
}

test "DMS1 preserves graphemes, wide-cell ownership, and visual style" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 6,
        .rows = 1,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();
    try screen.testWriteString("A界e\u{301}");

    var output: [max_bytes]u8 = undefined;
    const result = try read(&screen, .{
        .palette = &color.default,
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .background = .{ .r = 4, .g = 5, .b = 6 },
        .bold_color = null,
        .active_alternate = false,
        .application_cursor = true,
        .bracketed_paste = true,
        .cursor_visible = true,
        .cursor_shape = .block,
    }, &output);

    try std.testing.expectEqualStrings("DMS1", result[0..4]);
    try std.testing.expectEqual(@as(u8, 0b110), result[16]);
    try std.testing.expectEqual(@as(u8, 0), result[15]);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, result[18..][0..4], .little));
    // Header (22) + one style (16): A, wide grapheme, combining grapheme, blanks.
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, result[38..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, result[40..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, result[42..][0..2], .little));
    try std.testing.expectEqual(@as(u8, 1), result[44]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, result[46..][0..2], .little));
    try std.testing.expectEqual(@as(u8, 'A'), result[48]);
    // The following wide grapheme repeats once and owns two cells.
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, result[53..][0..2], .little));
    try std.testing.expectEqual(@as(u8, 2), result[55]);
}

test "DMS1 cursor mapping is independent of Ghostty enum order" {
    try std.testing.expectEqual(@as(u8, 0), cursorShape(.block));
    try std.testing.expectEqual(@as(u8, 0), cursorShape(.block_hollow));
    try std.testing.expectEqual(@as(u8, 1), cursorShape(.bar));
    try std.testing.expectEqual(@as(u8, 2), cursorShape(.underline));
}

test "DMS1 preserves a wide glyph split across a row boundary" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 3,
        .rows = 2,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();
    try screen.testWriteString("ab界");

    var output: [max_bytes]u8 = undefined;
    const result = try read(&screen, testOptions(), &output);
    const style_count = result[17];
    var offset: usize = header_len + @as(usize, style_count) * style_len;
    const run_count = std.mem.readInt(u32, result[18..][0..4], .little);
    var saw_head = false;
    var saw_wide = false;
    for (0..run_count) |_| {
        const row = std.mem.readInt(u16, result[offset..][0..2], .little);
        const column = std.mem.readInt(u16, result[offset + 2 ..][0..2], .little);
        const repeat = std.mem.readInt(u16, result[offset + 4 ..][0..2], .little);
        const width = result[offset + 6];
        const text_len = std.mem.readInt(u16, result[offset + 8 ..][0..2], .little);
        const text = result[offset + run_len ..][0..text_len];
        if (row == 0 and column == 2) {
            try std.testing.expectEqual(@as(u16, 1), repeat);
            try std.testing.expectEqual(@as(u8, 1), width);
            try std.testing.expectEqual(@as(usize, 0), text.len);
            saw_head = true;
        }
        if (row == 1 and column == 0) {
            try std.testing.expectEqual(@as(u16, 1), repeat);
            try std.testing.expectEqual(@as(u8, 2), width);
            try std.testing.expectEqualStrings("界", text);
            saw_wide = true;
        }
        offset += run_len + text_len;
    }
    try std.testing.expect(saw_head);
    try std.testing.expect(saw_wide);
}

test "DMS1 rejects more than 64 resolved styles" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 65,
        .rows = 1,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();

    for (0..65) |index| {
        screen.cursor.style.fg_color = .{ .rgb = .{
            .r = @intCast(index),
            .g = 0,
            .b = 0,
        } };
        try screen.manualStyleUpdate();
        try screen.testWriteString("x");
    }

    var output: [max_bytes]u8 = undefined;
    try std.testing.expectError(error.TooManyStyles, read(&screen, .{
        .palette = &color.default,
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .background = .{ .r = 4, .g = 5, .b = 6 },
        .bold_color = null,
        .active_alternate = false,
        .application_cursor = false,
        .bracketed_paste = false,
        .cursor_visible = true,
        .cursor_shape = .block,
    }, &output));
}

test "DMS1 accepts exactly 64 styles" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 64,
        .rows = 1,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();
    for (0..64) |index| {
        screen.cursor.style.fg_color = .{ .rgb = .{ .r = @intCast(index), .g = 0, .b = 0 } };
        try screen.manualStyleUpdate();
        try screen.testWriteString("x");
    }
    var output: [max_bytes]u8 = undefined;
    _ = try read(&screen, testOptions(), &output);
}

test "DMS1 accepts the maximum grid and rejects larger dimensions before writing" {
    var maximum = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = max_columns,
        .rows = max_rows,
        .max_scrollback_bytes = 0,
    });
    defer maximum.deinit();
    var output: [max_bytes]u8 = undefined;
    _ = try read(&maximum, testOptions(), &output);

    var too_wide = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = max_columns + 1,
        .rows = 1,
        .max_scrollback_bytes = 0,
    });
    defer too_wide.deinit();
    @memset(&output, 0xaa);
    try std.testing.expectError(error.TooLarge, read(&too_wide, testOptions(), &output));
    try std.testing.expectEqual(@as(u8, 0xaa), output[0]);

    var too_tall = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 1,
        .rows = max_rows + 1,
        .max_scrollback_bytes = 0,
    });
    defer too_tall.deinit();
    try std.testing.expectError(error.TooLarge, read(&too_tall, testOptions(), &output));
}

test "DMS1 rejects an encoded payload over 256 KiB" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = max_columns,
        .rows = max_rows,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();
    for (0..@as(usize, max_columns) * max_rows) |_| try screen.testWriteString("x");
    var output: [max_bytes]u8 = undefined;
    try std.testing.expectError(error.TooLarge, read(&screen, testOptions(), &output));
}

test "DMS1 style flags and underline variants are lossless" {
    const source: style.Style = .{ .flags = .{
        .bold = true,
        .faint = true,
        .italic = true,
        .invisible = true,
        .blink = true,
        .overline = true,
        .strikethrough = true,
        .inverse = true,
        .underline = .dashed,
    } };
    try std.testing.expectEqual(@as(u16, 0xff), flags(source));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(source.flags.underline));
}

test "DMS1 header records alternate mode and hidden bar cursor" {
    var screen = try Screen.init(std.testing.io, std.testing.allocator, .{
        .cols = 1,
        .rows = 1,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();
    var output: [max_bytes]u8 = undefined;
    const result = try read(&screen, .{
        .palette = &color.default,
        .foreground = null,
        .background = null,
        .bold_color = null,
        .active_alternate = true,
        .application_cursor = false,
        .bracketed_paste = false,
        .cursor_visible = false,
        .cursor_shape = .bar,
    }, &output);
    try std.testing.expectEqual(@as(u8, 0), result[14]);
    try std.testing.expectEqual(@as(u8, 1), result[15]);
    try std.testing.expectEqual(@as(u8, 1), result[16]);
}

fn testOptions() Options {
    return .{
        .palette = &color.default,
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .background = .{ .r = 4, .g = 5, .b = 6 },
        .bold_color = null,
        .active_alternate = false,
        .application_cursor = false,
        .bracketed_paste = false,
        .cursor_visible = true,
        .cursor_shape = .block,
    };
}
