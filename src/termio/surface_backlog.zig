//! Surface notifications the pty parse thread could not enqueue without
//! blocking.
//!
//! The parse thread (io-reader) is the only thing draining the pty. If it
//! blocks on a full app mailbox, output stops being parsed, the gather
//! ring fills, the pty stops being read, and the surface freezes while
//! input still works. How fast the mailbox drains is up to the apprt (an
//! embedder may tick it from another process's event loop), so the parse
//! thread must not wait on it with its lock held.
//!
//! Instead, when the mailbox is full the parse thread parks the message
//! here, in arrival order. State whose latest value is all that matters
//! (title, mouse shape, progress, pwd, bell, one palette/dynamic color)
//! coalesces with an earlier parked message of the same kind, but only
//! within the trailing run of such state: an event whose order matters
//! (command start/stop, clipboard requests, title reports, notifications)
//! is a barrier, so nothing is ever delivered out of order relative to it.
//!
//! The backlog is flushed by the parse thread before its next message and
//! by the app thread after each mailbox drain (via `pending`), both under
//! the renderer state mutex.
const SurfaceBacklog = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");

const Message = apprt.surface.Message;

/// Parked messages above this apply backpressure: the parse thread stops
/// parsing (lock released) until the app drains the backlog below it, so a
/// dead consumer cannot grow memory without bound. Coalescing keeps state
/// storms far below it; only ordered events accumulate.
/// ponytail: fixed cap; make it configurable only if a real workload hits it.
pub const soft_limit = 1024;

/// Most messages one flush delivers. The app mailbox holds 64; leaving
/// room means a backlog never takes every slot from other producers (the
/// renderer's health report, other surfaces, a teardown in progress).
pub const max_per_flush = 32;

queue: std.ArrayListUnmanaged(Message) = .empty,

/// Set while anything is parked, so the app thread can skip the renderer
/// state lock for surfaces with nothing to flush.
pending: std.atomic.Value(bool) = .init(false),

/// Messages parked since creation. Diagnostic only; read lock-free.
parked_total: std.atomic.Value(u64) = .init(0),

pub fn deinit(self: *SurfaceBacklog, alloc: Allocator) void {
    for (self.queue.items) |*msg| discard(msg);
    self.queue.deinit(alloc);
    self.* = .{};
}

pub fn isEmpty(self: *const SurfaceBacklog) bool {
    return self.queue.items.len == 0;
}

pub fn overLimit(self: *const SurfaceBacklog) bool {
    return self.queue.items.len > soft_limit;
}

/// Park `msg` in order, coalescing latest-value state. Returns false only
/// if memory could not be grown; the caller must then deliver `msg` itself.
pub fn park(self: *SurfaceBacklog, alloc: Allocator, msg: Message) bool {
    park: {
        if (!isState(msg)) break :park;
        var i = self.queue.items.len;
        while (i > 0) {
            i -= 1;
            const slot = &self.queue.items[i];
            if (!isState(slot.*)) break; // barrier: keep order
            if (!sameState(slot.*, msg)) continue;
            discard(slot);
            slot.* = msg;
            self.noteParked();
            return true;
        }
    }
    self.queue.append(alloc, msg) catch return false;
    self.noteParked();
    return true;
}

/// Deliver up to `max_per_flush` parked messages, in order, as long as
/// `sink` accepts them without blocking. `sink` is anything with `push(Message, Timeout)`
/// returning the new length (0 when full): the surface mailbox, or a fake
/// in tests. Returns true when the backlog is empty.
pub fn flush(self: *SurfaceBacklog, sink: anytype) bool {
    var sent: usize = 0;
    const limit = @min(self.queue.items.len, max_per_flush);
    while (sent < limit) : (sent += 1) {
        if (sink.push(self.queue.items[sent], .{ .instant = {} }) == 0) break;
    }
    if (sent > 0) self.queue.replaceRangeAssumeCapacity(0, sent, &.{});
    if (self.queue.items.len > 0) return false;
    self.pending.store(false, .release);
    return true;
}

fn noteParked(self: *SurfaceBacklog) void {
    _ = self.parked_total.fetchAdd(1, .monotonic);
    self.pending.store(true, .release);
}

/// Latest-value state: only the newest message of its kind (and target)
/// matters, so an older parked one may be replaced.
fn isState(msg: Message) bool {
    return switch (msg) {
        .set_title,
        .set_mouse_shape,
        .progress_report,
        .pwd_change,
        .ring_bell,
        .color_change,
        => true,
        else => false,
    };
}

fn sameState(a: Message, b: Message) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        // One slot per palette index / dynamic color, not per kind.
        .color_change => |v| std.meta.eql(v.target, b.color_change.target),
        else => true,
    };
}

/// Free what a message owns when it will never be delivered.
fn discard(msg: *const Message) void {
    switch (msg.*) {
        .clipboard_write => |v| v.req.deinit(),
        .pwd_change => |v| v.deinit(),
        .kitty_clipboard_read => |req| req.destroy(),
        .kitty_clipboard_write => |req| req.destroy(),
        else => {},
    }
}

const Tag = std.meta.Tag(Message);

const FakeSink = struct {
    room: usize,
    got: std.ArrayListUnmanaged(Message) = .empty,

    fn push(self: *FakeSink, msg: Message, _: anytype) u32 {
        if (self.room == 0) return 0;
        self.room -= 1;
        self.got.append(std.testing.allocator, msg) catch unreachable;
        return 1;
    }

    fn tags(self: *const FakeSink) ![]Tag {
        const out = try std.testing.allocator.alloc(Tag, self.got.items.len);
        for (self.got.items, out) |m, *t| t.* = m;
        return out;
    }

    fn deinit(self: *FakeSink) void {
        for (self.got.items) |*m| discard(m);
        self.got.deinit(std.testing.allocator);
    }
};

fn stop(code: u8) Message {
    return .{ .stop_command = .{ .code = code, .at = .zero } };
}

fn titleMsg(c: u8) Message {
    var buf: [256]u8 = @splat(0);
    buf[0] = c;
    return .{ .set_title = buf };
}

test "state storms coalesce; events are barriers that keep order" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var b: SurfaceBacklog = .{};
    defer b.deinit(alloc);

    // A title storm interleaved with bells parks two entries, not 10000.
    for (0..5000) |i| {
        try testing.expect(b.park(alloc, titleMsg(@intCast(i % 200))));
        try testing.expect(b.park(alloc, .ring_bell));
    }
    try testing.expectEqual(@as(usize, 2), b.queue.items.len);

    // A title report must see the title set before it, so it is a barrier:
    // the next title may not coalesce across it.
    try testing.expect(b.park(alloc, .{ .report_title = .csi_21_t }));
    try testing.expect(b.park(alloc, titleMsg('z')));
    try testing.expect(b.pending.load(.acquire));

    var sink: FakeSink = .{ .room = 100 };
    defer sink.deinit();
    try testing.expect(b.flush(&sink));
    try testing.expect(b.isEmpty());
    try testing.expect(!b.pending.load(.acquire));

    const got = try sink.tags();
    defer alloc.free(got);
    try testing.expectEqualSlices(Tag, &.{ .set_title, .ring_bell, .report_title, .set_title }, got);
    try testing.expectEqual(@as(u8, 4999 % 200), sink.got.items[0].set_title[0]);
    try testing.expectEqual(@as(u8, 'z'), sink.got.items[3].set_title[0]);
}

test "colors coalesce per target, not per kind" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var b: SurfaceBacklog = .{};
    defer b.deinit(alloc);

    // A 256-entry palette load repeated 10 times parks 256 entries.
    for (0..10) |round| for (0..256) |i| {
        try testing.expect(b.park(alloc, .{ .color_change = .{
            .target = .{ .palette = @intCast(i) },
            .color = .{ .r = @intCast(round), .g = 0, .b = 0 },
        } }));
    };
    try testing.expectEqual(@as(usize, 256), b.queue.items.len);
    try testing.expectEqual(@as(u8, 9), b.queue.items[255].color_change.color.r);
}

test "partial flush resumes in order" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var b: SurfaceBacklog = .{};
    defer b.deinit(alloc);

    try testing.expect(b.park(alloc, stop(0)));
    try testing.expect(b.park(alloc, stop(1)));
    try testing.expect(b.park(alloc, titleMsg('x')));

    var full: FakeSink = .{ .room = 1 };
    defer full.deinit();
    try testing.expect(!b.flush(&full));
    try testing.expect(b.pending.load(.acquire));

    var rest: FakeSink = .{ .room = 10 };
    defer rest.deinit();
    try testing.expect(b.flush(&rest));
    try testing.expectEqual(@as(?u8, 0), full.got.items[0].stop_command.code);
    try testing.expectEqual(@as(?u8, 1), rest.got.items[0].stop_command.code);
    try testing.expectEqual(Tag.set_title, @as(Tag, rest.got.items[1]));
}

test "owned payloads are freed when replaced or never delivered" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var b: SurfaceBacklog = .{};

    const long: []const u8 = "/a/path/longer/than/the/small/inline/buffer/" ** 8;
    // Replaced pwd frees the old allocation; the parked clipboard write
    // and the newest pwd are freed by deinit (testing.allocator checks).
    try testing.expect(b.park(alloc, .{ .pwd_change = try .init(alloc, long) }));
    try testing.expect(b.park(alloc, .{ .pwd_change = try .init(alloc, long) }));
    try testing.expect(b.park(alloc, .{ .clipboard_write = .{
        .clipboard_type = .standard,
        .req = try .init(alloc, long),
    } }));
    try testing.expectEqual(@as(usize, 2), b.queue.items.len);
    b.deinit(alloc);
}

test "soft limit reports backpressure" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var b: SurfaceBacklog = .{};
    defer b.deinit(alloc);

    for (0..soft_limit) |_| try testing.expect(b.park(alloc, stop(0)));
    try testing.expect(!b.overLimit());
    try testing.expect(b.park(alloc, stop(0)));
    try testing.expect(b.overLimit());
}

test "one flush leaves mailbox room for other producers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var b: SurfaceBacklog = .{};
    defer b.deinit(alloc);

    for (0..100) |i| try testing.expect(b.park(alloc, stop(@intCast(i))));
    var sink: FakeSink = .{ .room = 64 };
    defer sink.deinit();
    try testing.expect(!b.flush(&sink));
    try testing.expectEqual(@as(usize, max_per_flush), sink.got.items.len);
    try testing.expectEqual(@as(usize, 100 - max_per_flush), b.queue.items.len);
    // Order resumes where it stopped.
    try testing.expectEqual(@as(?u8, max_per_flush), b.queue.items[0].stop_command.code);
}

test "termio-thread events are ordered barriers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var b: SurfaceBacklog = .{};
    defer b.deinit(alloc);

    try testing.expect(b.park(alloc, titleMsg('a')));
    try testing.expect(b.park(alloc, stop(0)));
    try testing.expect(b.park(alloc, .{ .child_exited = .{ .exit_code = 0, .runtime_ms = 1 } }));
    try testing.expect(b.park(alloc, .{ .password_input = true }));

    var sink: FakeSink = .{ .room = 10 };
    defer sink.deinit();
    try testing.expect(b.flush(&sink));
    const got = try sink.tags();
    defer alloc.free(got);
    try testing.expectEqualSlices(Tag, &.{ .set_title, .stop_command, .child_exited, .password_input }, got);
}
