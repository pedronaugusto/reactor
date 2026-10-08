//! The extensions over any `Io`: on std's `Io.Threaded` (the fallbacks),
//! on the seeded driver (the runtime's native waits, replayed from a
//! seed), and on real worker threads.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const posix = std.posix;

const reactor = @import("reactor.zig");
const fiber = @import("fiber.zig");
const Loop = @import("Loop.zig");
const Driver = @import("testing/Driver.zig");
const Threads = @import("testing/Threads.zig");
const Fake = @import("testing/Fake.zig");

const is_windows = builtin.os.tag == .windows;

fn skipWithoutFibers() !void {
    if (!fiber.supported) return error.SkipZigTest;
}

const small: reactor.Runtime.Options = .{ .max_tasks = 256, .stack_size = 256 << 10, .offload = .none };

fn ms(n: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(n), .clock = .awake } };
}

/// A pipe's two ends, for a descriptor to wait on.
fn pipe() ![2]posix.fd_t {
    return Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
}

fn closeAll(fds: []const posix.fd_t) void {
    for (fds) |fd| _ = posix.system.close(fd);
}

// Waits on std's `Io.Threaded`: the calling thread, in slices.

test "a wait on Threaded reports the readable member and times out on none" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    const a = try pipe();
    defer closeAll(&a);
    const b = try pipe();
    defer closeAll(&b);
    try testing.expectError(error.Timeout, reactor.waitAny(io, &.{ .{ .readable = a[0] }, .{ .readable = b[0] } }, ms(20)));
    _ = posix.system.write(b[1], "x", 1);
    try testing.expectEqual(@as(usize, 1), try reactor.waitAny(io, &.{ .{ .readable = a[0] }, .{ .readable = b[0] } }, ms(1000)));
    // A pipe with room is writable at once.
    try reactor.wait(io, .{ .writable = a[1] }, .none);
}

fn signalLater(w: *reactor.Wake) void {
    var threaded: Io.Threaded = .init_single_threaded;
    threaded.io().sleep(.fromMilliseconds(10), .awake) catch return;
    w.signal();
}

test "a Wake set from another thread ends a wait, which clears it" {
    const io = testing.io;
    var wake = try reactor.Wake.init(io);
    defer wake.deinit(io);
    const thread = try std.Thread.spawn(.{}, signalLater, .{&wake});
    defer thread.join();
    try reactor.wait(io, .{ .wake = &wake }, ms(5000));
    // Cleared by the wait that reported it; a signal while nobody waits is
    // kept for the next.
    try testing.expectError(error.Timeout, reactor.wait(io, .{ .wake = &wake }, ms(10)));
    wake.signal();
    try reactor.wait(io, .{ .wake = &wake }, .none);
}

fn waitForever(io: Io, w: *reactor.Wake) reactor.WaitError!void {
    return reactor.wait(io, .{ .wake = w }, .none);
}

test "a cancel ends a wait on Threaded within a slice" {
    const io = testing.io;
    var wake = try reactor.Wake.init(io);
    defer wake.deinit(io);
    var waiting = io.concurrent(waitForever, .{ io, &wake }) catch return error.SkipZigTest;
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, waiting.cancel(io));
}

// Processes.

fn spawnSleeper(io: Io, seconds: []const u8) !std.process.Child {
    return std.process.spawn(io, .{ .argv = &.{ "sleep", seconds }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
}

test "a process is reported once it ends, and is still there to reap" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var child = try spawnSleeper(io, "0.05");
    var p = try reactor.Process.open(io, child.id.?);
    defer p.close(io);
    try reactor.wait(io, .{ .process = &p }, ms(10_000));
    // Not reaped: the child's own wait collects the status.
    const term = try child.wait(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}

test "a process still running times out; one that ended before it was opened is ready at once" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var running = try spawnSleeper(io, "5");
    defer running.kill(io);
    var p = try reactor.Process.open(io, running.id.?);
    defer p.close(io);
    try testing.expectError(error.Timeout, reactor.wait(io, .{ .process = &p }, ms(20)));

    var done = try spawnSleeper(io, "0");
    // Ended but unreaped: a zombie, which Darwin refuses to watch.
    while (true) {
        var q = try reactor.Process.open(io, done.id.?);
        defer q.close(io);
        reactor.wait(io, .{ .process = &q }, ms(10)) catch |err| switch (err) {
            error.Timeout => continue,
            else => |e| return e,
        };
        break;
    }
    var q = try reactor.Process.open(io, done.id.?);
    defer q.close(io);
    try reactor.wait(io, .{ .process = &q }, .none);
    _ = try done.wait(io);
}

// Signals.

test "a signal reaches every listener that asked for it, and only those" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var first = try reactor.Signals.start(io, &.{ .user1, .user2 });
    defer first.stop(io);
    var second = try reactor.Signals.start(io, &.{.user1});
    defer second.stop(io);
    try testing.expectError(error.Unsupported, reactor.Signals.start(io, &.{.logoff}));
    try posix.raise(.USR1);
    try testing.expectEqual(reactor.Signals.Signal.user1, try first.next(io, ms(5000)));
    try testing.expectEqual(reactor.Signals.Signal.user1, try second.next(io, ms(5000)));
    try testing.expectError(error.Timeout, second.next(io, ms(10)));
    try posix.raise(.USR2);
    try testing.expectEqual(reactor.Signals.Signal.user2, try first.next(io, ms(5000)));
    try testing.expectError(error.Timeout, second.next(io, ms(10)));
}

test "the last listener to stop puts the previous handler back" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var before: posix.Sigaction = undefined;
    posix.sigaction(.USR2, null, &before);
    var s = try reactor.Signals.start(io, &.{.user2});
    var during: posix.Sigaction = undefined;
    posix.sigaction(.USR2, null, &during);
    try testing.expect(during.handler.handler != before.handler.handler);
    s.stop(io);
    var after: posix.Sigaction = undefined;
    posix.sigaction(.USR2, null, &after);
    try testing.expectEqual(before.handler.handler, after.handler.handler);
}

// Blocking calls.

fn triple(x: u32) u32 {
    return 3 * x;
}

test "blocking runs the call on the caller under Threaded, and on a lane under a runtime" {
    try testing.expectEqual(@as(u32, 21), reactor.blocking(testing.io, .general, triple, .{7}));
    try skipWithoutFibers();
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 1, .max_tasks = 64, .stack_size = 256 << 10 });
    defer t.deinit();
    const io = t.io();
    try testing.expectEqual(@as(u32, 42), reactor.blocking(io, .sync, triple, .{14}));
    try testing.expectEqual(@as(u64, 0), t.runtime.stats().lanes[@backingInt(reactor.Runtime.Lane.sync)].@"inline");
}

// The runtime's native waits, on the seeded driver.

/// A script under which readiness never comes: a wait ends only by its
/// deadline or a cancel.
fn neverReady(context: ?*anyopaque, o: *Loop.Op, random: std.Random) ?Loop.Op.Result {
    return switch (o.kind) {
        .wait => null,
        else => Fake.defaultScript(context, o, random),
    };
}

test "on the driver a wait's members are the loop's own operations: one ready ends it, all come back" {
    try skipWithoutFibers();
    if (is_windows) return error.SkipZigTest;
    for (0..8) |seed| {
        var d: Driver = undefined;
        try d.init(testing.allocator, seed, small);
        defer d.deinit();
        const io = d.io();
        var wake = try reactor.Wake.init(io);
        defer wake.deinit(io);
        const index = try reactor.waitAny(io, &.{ .{ .readable = 0 }, .{ .writable = 1 }, .{ .wake = &wake } }, .none);
        try testing.expect(index < 3);
        // Every operation is back: the loop holds nothing.
        try testing.expectEqual(@as(u32, 0), d.runtime.core.processors[0].loop.in_flight);
    }
}

test "on the driver a wait with nothing ready ends at its deadline, in virtual time" {
    try skipWithoutFibers();
    if (is_windows) return error.SkipZigTest;
    for (0..8) |seed| {
        var d: Driver = undefined;
        try d.init(testing.allocator, seed, small);
        defer d.deinit();
        d.fake.script = neverReady;
        const io = d.io();
        const before = d.elapsed();
        try testing.expectError(error.Timeout, reactor.waitAny(io, &.{ .{ .readable = 0 }, .{ .readable = 1 } }, ms(250)));
        const waited = d.elapsed() - before;
        try testing.expect(waited >= 250 * std.time.ns_per_ms and waited < 251 * std.time.ns_per_ms);
        try testing.expectEqual(@as(u32, 0), d.runtime.core.processors[0].loop.in_flight);
    }
}

fn waitOn(io: Io, fd: posix.fd_t) reactor.WaitError!void {
    return reactor.wait(io, .{ .readable = fd }, .none);
}

test "on the driver a cancel ends a native wait, and no operation is left behind" {
    try skipWithoutFibers();
    if (is_windows) return error.SkipZigTest;
    for (0..8) |seed| {
        var d: Driver = undefined;
        try d.init(testing.allocator, seed, small);
        defer d.deinit();
        d.fake.script = neverReady;
        const io = d.io();
        var waiting = try io.concurrent(waitOn, .{ io, 3 });
        try io.sleep(.fromMilliseconds(1), .awake);
        try testing.expectError(error.Canceled, waiting.cancel(io));
        try testing.expectEqual(@as(u32, 0), d.runtime.core.processors[0].loop.in_flight);
    }
}

test "on real worker threads a native wait ends at its deadline or its cancel" {
    try skipWithoutFibers();
    if (is_windows) return error.SkipZigTest;
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 2, .max_tasks = 64, .stack_size = 256 << 10 });
    defer t.deinit();
    const io = t.io();
    // The idle fake never makes a descriptor ready.
    try testing.expectError(error.Timeout, reactor.wait(io, .{ .readable = 0 }, ms(5)));
    var waiting = try io.concurrent(waitOn, .{ io, 0 });
    try io.sleep(.fromMilliseconds(2), .awake);
    try testing.expectError(error.Canceled, waiting.cancel(io));
}

test "an extension called with another Io counts a fallback; one with a runtime does not" {
    try skipWithoutFibers();
    var d: Driver = undefined;
    try d.init(testing.allocator, 1, small);
    defer d.deinit();
    const before = reactor.fallbacks();
    _ = reactor.blocking(d.io(), .general, triple, .{1});
    try testing.expectEqual(before, reactor.fallbacks());
    _ = reactor.blocking(testing.io, .general, triple, .{1});
    try testing.expect(reactor.fallbacks() > before);
}

// Windows: objects, a job's port, console control events.

extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;

test "Windows: a Wake and an event wait as objects, and a job with no process has no message" {
    if (!is_windows) return error.SkipZigTest;
    const io = testing.io;
    var wake = try reactor.Wake.init(io);
    defer wake.deinit(io);
    const win32 = @import("sys/win32.zig");
    const blocker = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.SystemResources;
    defer std.os.windows.CloseHandle(blocker);
    wake.signal();
    try testing.expectEqual(@as(usize, 1), try reactor.waitAny(io, &.{ .{ .object = blocker }, .{ .wake = &wake } }, ms(1000)));
    const handle = CreateJobObjectW(null, null) orelse return error.SkipZigTest;
    defer std.os.windows.CloseHandle(handle);
    var job = try reactor.Job.attach(io, handle);
    defer job.detach(io);
    try testing.expectError(error.AlreadyAttached, reactor.Job.attach(io, handle));
    try testing.expectError(error.Timeout, job.next(io, ms(20)));
}

test "Windows: console control events have listeners; the POSIX-only signals are refused" {
    if (!is_windows) return error.SkipZigTest;
    const io = testing.io;
    var s = try reactor.Signals.start(io, &.{ .interrupt, .close });
    defer s.stop(io);
    try testing.expectError(error.Unsupported, reactor.Signals.start(io, &.{.window_change}));
    try testing.expectError(error.Timeout, s.next(io, ms(10)));
}

test "a zero timeout consumes a ready Wake and otherwise times out" {
    const io = testing.io;
    var wake = try reactor.Wake.init(io);
    defer wake.deinit(io);
    wake.signal();
    try reactor.wait(io, .{ .wake = &wake }, ms(0));
    try testing.expectError(error.Timeout, reactor.wait(io, .{ .wake = &wake }, ms(0)));
}

test "a blocking hook runs a library's raw call on the sync lane" {
    try skipWithoutFibers();
    const Call = struct {
        fn run(context: *anyopaque) void {
            const id: *std.Thread.Id = @ptrCast(@alignCast(context)); // safe: the test passed the thread id
            id.* = std.Thread.getCurrentId();
        }
    };
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 0, .max_tasks = 16, .stack_size = 256 << 10 });
    defer t.deinit();
    var id: std.Thread.Id = undefined;
    const hook = reactor.blockingHook(t.io());
    hook.call(hook.context, Call.run, &id);
    try testing.expect(id != std.Thread.getCurrentId());
    const inline_hook = reactor.blockingHook(testing.io);
    inline_hook.call(inline_hook.context, Call.run, &id);
    try testing.expectEqual(std.Thread.getCurrentId(), id);
}

test "job notification storage bounds messages and ignores retired attachments" {
    if (@bitSizeOf(usize) != 64) return error.SkipZigTest;
    const Notifications = @import("backend/iocp/Notifications.zig");
    var table = try Notifications.init(testing.allocator, 1);
    defer table.deinit(testing.allocator);
    const record = table.acquire(testing.io).?;
    const first_key = record.key();
    try testing.expect(table.acquire(testing.io) == null);
    for (0..33) |i| try testing.expect(table.dispatch(first_key, i, 6));
    for (0..32) |i| {
        const message = try record.next(testing.io, ms(0));
        try testing.expectEqual(@as(u32, @intCast(i)), message.process);
    }
    try testing.expectError(error.SystemResources, record.next(testing.io, ms(0)));
    try testing.expectError(error.Timeout, record.next(testing.io, ms(0)));
    record.release();
    const next_record = table.acquire(testing.io).?;
    defer next_record.release();
    try testing.expect(first_key != next_record.key());
    try testing.expect(table.dispatch(first_key, 99, 6));
    try testing.expectError(error.Timeout, next_record.next(testing.io, ms(0)));
    try testing.expect(table.dispatch(next_record.key(), 42, 7));
    try testing.expectEqual(@as(u32, 42), (try next_record.next(testing.io, ms(0))).process);
}

test "a zero timeout chooses a ready Wake before an ended process" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var wake = try reactor.Wake.init(io);
    defer wake.deinit(io);
    wake.signal();
    const ended: reactor.Process = .{ .watch = .ended, .id = 0 };
    try testing.expectEqual(@as(usize, 0), try reactor.waitAny(io, &.{ .{ .wake = &wake }, .{ .process = &ended } }, ms(0)));
}

test "a reaped operation can alternate kernel and timer requests without reinitialization" {
    const clocks = @import("clock.zig");
    const loop_internal = @import("loop/internal.zig");
    var virtual: clocks.Virtual = .{};
    var fake = Fake.init(testing.allocator, .{ .seeded = .{ .seed = 71, .virtual = &virtual } });
    defer fake.deinit();
    var loop: Loop = undefined;
    loop_internal.initWith(&loop, .{ .custom = fake.custom() }, .{ .virtual = &virtual }, 8);
    defer loop.deinit(testing.allocator);
    var operation: Loop.Op = .{ .kind = .{ .sync = undefined } };
    var reaped: [1]*Loop.Op = undefined;
    for (0..32) |round| {
        operation.kind = .{ .sync = undefined };
        try loop.submit(&operation);
        // Stand in for bytes a kernel backend leaves in its scratch.
        @memset(std.mem.asBytes(&operation.state.storage.scratch), 0xa5);
        var polls: usize = 0;
        while (loop.in_flight > 0 and polls < 1000) : (polls += 1) _ = try loop.run(.nowait);
        try testing.expectEqual(@as(usize, 1), loop.reap(&reaped).len);
        try testing.expectEqual(&operation, reaped[0]);
        try operation.result.sync;
        operation.kind = .{ .timer = .{ .clock = .awake, .raw = virtual.now(.awake).addDuration(.fromMilliseconds(1)) } };
        try loop.submit(&operation);
        if (round % 2 == 0) {
            loop.cancel(&operation);
        } else {
            virtual.advance(.fromMilliseconds(1));
            _ = try loop.run(.nowait);
        }
        try testing.expectEqual(@as(usize, 1), loop.reap(&reaped).len);
        if (round % 2 == 0) try testing.expectError(error.Canceled, operation.result.timer) else try operation.result.timer;
    }
}
