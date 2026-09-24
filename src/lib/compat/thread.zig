//! Code taken from 0.17.0 `std.Io.Condition`. See README.md for license and
//! details.
//!
//! FIXME: Should be able to remove after 0.17.0, see:
//!   https://codeberg.org/ziglang/zig/pulls/31278
const builtin = @import("builtin");
const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;

pub const WaitTimeoutError = std.Io.Cancelable || std.Io.Timeout.Error;

/// Blocks until the condition is signaled, canceled, or the provided
/// timeout expires.
///
/// See also:
/// * `wait`
/// * `waitUncancelable`
pub fn waitTimeout(
    cond: *std.Io.Condition,
    io: std.Io,
    mutex: *std.Io.Mutex,
    timeout: std.Io.Timeout,
) WaitTimeoutError!void {
    const deadline = timeout.toDeadline(io);

    var epoch = cond.epoch.load(.acquire); // `.acquire` to ensure ordered before state load

    {
        const prev_state = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
        assert(prev_state.waiters < std.math.maxInt(u16)); // overflow caused by too many waiters
    }

    mutex.unlock(io);
    defer mutex.lockUncancelable(io);

    while (true) {
        const result = io.futexWaitTimeout(u32, &cond.epoch.raw, epoch, deadline);

        epoch = cond.epoch.load(.acquire); // `.acquire` to ensure ordered before `state` load

        // Even on error, try to consume a pending signal first. Otherwise a race might
        // cause a signal to get stuck in the state with no corresponding waiter.
        {
            var prev_state = cond.state.load(.monotonic);
            while (prev_state.signals > 0) {
                prev_state = cond.state.cmpxchgWeak(prev_state, .{
                    .waiters = prev_state.waiters - 1,
                    .signals = prev_state.signals - 1,
                }, .acquire, .monotonic) orelse {
                    // We successfully consumed a signal.
                    return;
                };
            }
        }

        // There are no more signals available; this was a spurious wakeup or an error. If it
        // was an error, we will remove ourselves as a waiter and return that error. If a
        // timeout was specified and the deadline has passed, we remove ourselves as a waiter
        // and return `error.Timeout`. Otherwise, we'll loop back to the futex wait.
        result catch |err| {
            if (leaveOrConsume(cond)) return;
            return err;
        };
        switch (deadline) {
            .none => {},
            .deadline => |d| if (d.untilNow(io).raw.nanoseconds >= 0) {
                if (leaveOrConsume(cond)) return;
                return error.Timeout;
            },
            .duration => unreachable,
        }
    }
}

/// Deregister a waiter that is giving up, unless a signal arrived since the
/// last check. A plain `fetchSub` of `waiters` races with `signal`: the signal
/// can land between our "no signals" load and the decrement, leaving
/// `signals > 0` with no waiter to consume it. Every later `signal` then sees
/// `waiters == signals` and wakes nobody, so a forever-waiter on the same
/// condition sleeps permanently. Returns true when a signal was consumed
/// instead (the caller was woken, not timed out).
fn leaveOrConsume(cond: *std.Io.Condition) bool {
    var prev_state = cond.state.load(.monotonic);
    while (true) {
        assert(prev_state.waiters > 0); // underflow caused by illegal state
        const consume = prev_state.signals > 0;
        prev_state = cond.state.cmpxchgWeak(prev_state, .{
            .waiters = prev_state.waiters - 1,
            .signals = if (consume) prev_state.signals - 1 else prev_state.signals,
        }, .acquire, .monotonic) orelse return consume;
    }
}

test "leaving waiter consumes a signal that raced its timeout" {
    const testing = std.testing;
    var cond: std.Io.Condition = .init;

    // The signal landed after the timed-out waiter's last check.
    cond.state.store(.{ .waiters = 1, .signals = 1 }, .monotonic);
    try testing.expect(leaveOrConsume(&cond));
    const after = cond.state.load(.monotonic);
    try testing.expectEqual(@as(u16, 0), after.waiters);
    try testing.expectEqual(@as(u16, 0), after.signals);

    // No signal: plain deregistration, reported as a timeout.
    cond.state.store(.{ .waiters = 2, .signals = 0 }, .monotonic);
    try testing.expect(!leaveOrConsume(&cond));
    try testing.expectEqual(@as(u16, 1), cond.state.load(.monotonic).waiters);
}
