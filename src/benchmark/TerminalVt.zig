//! This benchmark tests the full terminal VT stream path from raw input bytes
//! through terminal state mutation. Unlike TerminalStream.zig, this uses the
//! real Terminal.vtStream() handler so scrolling, carriage returns, escape
//! sequences, and scrollback policies are all part of the measurement.
const TerminalVt = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const Stream = terminalpkg.TerminalStream;

const log = std.log.scoped(.@"terminal-vt-bench");

opts: Options,
terminal: Terminal,
stream: Stream,

/// The file, opened in the setup function.
data_f: ?std.fs.File = null,

pub const Options = struct {
    /// The size of the terminal. This affects benchmarking when dealing with
    /// wrapping, scrolling, and page growth.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// Maximum scrollback budget in bytes. Zero disables scrollback.
    @"scrollback-bytes": usize = 10_000_000,

    /// The data to read as a filepath. If this is "-" then we will read stdin.
    /// If this is unset, then the benchmark is effectively a noop.
    data: ?[]const u8 = null,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalVt {
    const ptr = try alloc.create(TerminalVt);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .opts = opts,
        .terminal = try .init(alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
            .max_scrollback = opts.@"scrollback-bytes",
        }),
        .stream = undefined,
    };
    ptr.stream = ptr.terminal.vtStream();

    return ptr;
}

pub fn destroy(self: *TerminalVt, alloc: Allocator) void {
    self.stream.deinit();
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *TerminalVt) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalVt = @ptrCast(@alignCast(ptr));

    self.terminal.fullReset();

    // Recreate the stream so parser state starts clean for each run.
    self.stream.deinit();
    self.stream = self.terminal.vtStream();

    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *TerminalVt = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close();
        self.data_f = null;
    }
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalVt = @ptrCast(@alignCast(ptr));
    const f = self.data_f orelse return;

    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(&read_buf);
    const r = &f_reader.interface;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break;
        self.stream.nextSlice(buf[0..n]);
    }
}

test TerminalVt {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *TerminalVt = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
