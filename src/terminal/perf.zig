const std = @import("std");

const report_bytes: u64 = 100_000;

pub const GrowPath = enum {
    fast,
    prune_reuse,
    alloc,
};

const State = struct {
    enabled: bool = false,
    total_bytes: u64 = 0,
    bytes_since_report: u64 = 0,
    vt_write_calls: u64 = 0,
    vt_write_ns: u128 = 0,
    grow_fast: u64 = 0,
    grow_prune_reuse: u64 = 0,
    grow_alloc: u64 = 0,
    increase_capacity: u64 = 0,
};

var init_once = std.once(init);
var mutex: std.Thread.Mutex = .{};
var state: State = .{};

pub fn enabled() bool {
    init_once.call();
    return state.enabled;
}

fn init() void {
    const value = std.posix.getenv("GHOSTTY_VT_PROFILE") orelse return;
    if (value.len == 0) return;
    if (std.mem.eql(u8, value, "0")) return;
    if (std.ascii.eqlIgnoreCase(value, "false")) return;
    if (std.ascii.eqlIgnoreCase(value, "off")) return;
    state.enabled = true;
}

pub fn start() ?std.time.Instant {
    if (!enabled()) return null;
    return std.time.Instant.now() catch null;
}

pub fn recordVtWrite(started: ?std.time.Instant, bytes: usize) void {
    if (!enabled()) return;

    const elapsed_ns = elapsed: {
        const start_instant = started orelse break :elapsed 0;
        const end_instant = std.time.Instant.now() catch break :elapsed 0;
        break :elapsed end_instant.since(start_instant);
    };
    mutex.lock();
    defer mutex.unlock();

    state.total_bytes += @intCast(bytes);
    state.bytes_since_report += @intCast(bytes);
    state.vt_write_calls += 1;
    state.vt_write_ns += elapsed_ns;

    emitLocked();
}

pub fn recordGrow(path: GrowPath) void {
    if (!enabled()) return;

    mutex.lock();
    defer mutex.unlock();

    switch (path) {
        .fast => state.grow_fast += 1,
        .prune_reuse => state.grow_prune_reuse += 1,
        .alloc => state.grow_alloc += 1,
    }
}

pub fn recordIncreaseCapacity() void {
    if (!enabled()) return;

    mutex.lock();
    defer mutex.unlock();
    state.increase_capacity += 1;
}

fn emitLocked() void {
    if (state.bytes_since_report < report_bytes) return;

    const vt_write_ms = @as(f64, @floatFromInt(state.vt_write_ns)) / @as(f64, std.time.ns_per_ms);
    std.debug.print(
        "ghostty-vt-profile bytes={} vt_write_calls={} vt_write_ms={d:.3} grow_fast={} grow_prune_reuse={} grow_alloc={} increase_capacity={}\n",
        .{
            state.total_bytes,
            state.vt_write_calls,
            vt_write_ms,
            state.grow_fast,
            state.grow_prune_reuse,
            state.grow_alloc,
            state.increase_capacity,
        },
    );

    state.bytes_since_report = 0;
}
