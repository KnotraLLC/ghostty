const std = @import("std");

const report_bytes: u64 = 100_000;

pub const GrowPath = enum {
    fast,
    prune_reuse,
    alloc,
};

pub const Action = enum {
    print,
    carriage_return,
    linefeed,
    index,
    set_attribute,
    cursor_down_scroll,
    cursor_scroll_above,
};

pub const ScrollStage = enum {
    grow,
    pin,
    cache,
    mark_dirty,
    clear,
    style_fill,
    rotate,
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
    action_print: u64 = 0,
    action_carriage_return: u64 = 0,
    action_linefeed: u64 = 0,
    action_index: u64 = 0,
    action_set_attribute: u64 = 0,
    action_cursor_down_scroll: u64 = 0,
    action_cursor_scroll_above: u64 = 0,
    action_print_ns: u128 = 0,
    action_carriage_return_ns: u128 = 0,
    action_linefeed_ns: u128 = 0,
    action_index_ns: u128 = 0,
    action_set_attribute_ns: u128 = 0,
    action_cursor_down_scroll_ns: u128 = 0,
    action_cursor_scroll_above_ns: u128 = 0,
    scroll_grow: u64 = 0,
    scroll_pin: u64 = 0,
    scroll_cache: u64 = 0,
    scroll_mark_dirty: u64 = 0,
    scroll_clear: u64 = 0,
    scroll_style_fill: u64 = 0,
    scroll_rotate: u64 = 0,
    scroll_grow_ns: u128 = 0,
    scroll_pin_ns: u128 = 0,
    scroll_cache_ns: u128 = 0,
    scroll_mark_dirty_ns: u128 = 0,
    scroll_clear_ns: u128 = 0,
    scroll_style_fill_ns: u128 = 0,
    scroll_rotate_ns: u128 = 0,
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

    emitLocked(false);
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

pub fn recordAction(action: Action, started: ?std.time.Instant) void {
    recordActionBatch(action, 1, started);
}

pub fn recordActionBatch(
    action: Action,
    count: usize,
    started: ?std.time.Instant,
) void {
    if (!enabled()) return;

    const elapsed_ns = elapsed: {
        const start_instant = started orelse break :elapsed 0;
        const end_instant = std.time.Instant.now() catch break :elapsed 0;
        break :elapsed end_instant.since(start_instant);
    };

    mutex.lock();
    defer mutex.unlock();

    const count_u64: u64 = @intCast(count);
    switch (action) {
        .print => {
            state.action_print += count_u64;
            state.action_print_ns += elapsed_ns;
        },
        .carriage_return => {
            state.action_carriage_return += count_u64;
            state.action_carriage_return_ns += elapsed_ns;
        },
        .linefeed => {
            state.action_linefeed += count_u64;
            state.action_linefeed_ns += elapsed_ns;
        },
        .index => {
            state.action_index += count_u64;
            state.action_index_ns += elapsed_ns;
        },
        .set_attribute => {
            state.action_set_attribute += count_u64;
            state.action_set_attribute_ns += elapsed_ns;
        },
        .cursor_down_scroll => {
            state.action_cursor_down_scroll += count_u64;
            state.action_cursor_down_scroll_ns += elapsed_ns;
        },
        .cursor_scroll_above => {
            state.action_cursor_scroll_above += count_u64;
            state.action_cursor_scroll_above_ns += elapsed_ns;
        },
    }
}

pub fn recordScrollStage(stage: ScrollStage, started: ?std.time.Instant) void {
    if (!enabled()) return;

    const elapsed_ns = elapsed: {
        const start_instant = started orelse break :elapsed 0;
        const end_instant = std.time.Instant.now() catch break :elapsed 0;
        break :elapsed end_instant.since(start_instant);
    };

    mutex.lock();
    defer mutex.unlock();

    switch (stage) {
        .grow => {
            state.scroll_grow += 1;
            state.scroll_grow_ns += elapsed_ns;
        },
        .pin => {
            state.scroll_pin += 1;
            state.scroll_pin_ns += elapsed_ns;
        },
        .cache => {
            state.scroll_cache += 1;
            state.scroll_cache_ns += elapsed_ns;
        },
        .mark_dirty => {
            state.scroll_mark_dirty += 1;
            state.scroll_mark_dirty_ns += elapsed_ns;
        },
        .clear => {
            state.scroll_clear += 1;
            state.scroll_clear_ns += elapsed_ns;
        },
        .style_fill => {
            state.scroll_style_fill += 1;
            state.scroll_style_fill_ns += elapsed_ns;
        },
        .rotate => {
            state.scroll_rotate += 1;
            state.scroll_rotate_ns += elapsed_ns;
        },
    }
}

pub fn reset() void {
    if (!enabled()) return;

    mutex.lock();
    defer mutex.unlock();
    state = .{ .enabled = true };
}

pub fn emitNow() void {
    if (!enabled()) return;

    mutex.lock();
    defer mutex.unlock();
    emitLocked(true);
}

fn emitLocked(force: bool) void {
    if (!force and state.bytes_since_report < report_bytes) return;
    if (state.total_bytes == 0 and state.vt_write_calls == 0) return;

    const vt_write_ms = @as(f64, @floatFromInt(state.vt_write_ns)) / @as(f64, std.time.ns_per_ms);
    std.debug.print(
        "ghostty-vt-profile bytes={} vt_write_calls={} vt_write_ms={d:.3} grow_fast={} grow_prune_reuse={} grow_alloc={} increase_capacity={} print={} print_ms={d:.3} cr={} cr_ms={d:.3} lf={} lf_ms={d:.3} index={} index_ms={d:.3} sgr={} sgr_ms={d:.3}\n",
        .{
            state.total_bytes,
            state.vt_write_calls,
            vt_write_ms,
            state.grow_fast,
            state.grow_prune_reuse,
            state.grow_alloc,
            state.increase_capacity,
            state.action_print,
            @as(f64, @floatFromInt(state.action_print_ns)) / @as(f64, std.time.ns_per_ms),
            state.action_carriage_return,
            @as(f64, @floatFromInt(state.action_carriage_return_ns)) / @as(f64, std.time.ns_per_ms),
            state.action_linefeed,
            @as(f64, @floatFromInt(state.action_linefeed_ns)) / @as(f64, std.time.ns_per_ms),
            state.action_index,
            @as(f64, @floatFromInt(state.action_index_ns)) / @as(f64, std.time.ns_per_ms),
            state.action_set_attribute,
            @as(f64, @floatFromInt(state.action_set_attribute_ns)) / @as(f64, std.time.ns_per_ms),
        },
    );
    std.debug.print(
        "ghostty-vt-profile-scroll cds={} cds_ms={d:.3} csa={} csa_ms={d:.3} sgrow={} sgrow_ms={d:.3} spin={} spin_ms={d:.3} scache={} scache_ms={d:.3} sdirty={} sdirty_ms={d:.3} sclear={} sclear_ms={d:.3} sfill={} sfill_ms={d:.3} srotate={} srotate_ms={d:.3}\n",
        .{
            state.action_cursor_down_scroll,
            @as(f64, @floatFromInt(state.action_cursor_down_scroll_ns)) / @as(f64, std.time.ns_per_ms),
            state.action_cursor_scroll_above,
            @as(f64, @floatFromInt(state.action_cursor_scroll_above_ns)) / @as(f64, std.time.ns_per_ms),
            state.scroll_grow,
            @as(f64, @floatFromInt(state.scroll_grow_ns)) / @as(f64, std.time.ns_per_ms),
            state.scroll_pin,
            @as(f64, @floatFromInt(state.scroll_pin_ns)) / @as(f64, std.time.ns_per_ms),
            state.scroll_cache,
            @as(f64, @floatFromInt(state.scroll_cache_ns)) / @as(f64, std.time.ns_per_ms),
            state.scroll_mark_dirty,
            @as(f64, @floatFromInt(state.scroll_mark_dirty_ns)) / @as(f64, std.time.ns_per_ms),
            state.scroll_clear,
            @as(f64, @floatFromInt(state.scroll_clear_ns)) / @as(f64, std.time.ns_per_ms),
            state.scroll_style_fill,
            @as(f64, @floatFromInt(state.scroll_style_fill_ns)) / @as(f64, std.time.ns_per_ms),
            state.scroll_rotate,
            @as(f64, @floatFromInt(state.scroll_rotate_ns)) / @as(f64, std.time.ns_per_ms),
        },
    );

    state.bytes_since_report = 0;
}
