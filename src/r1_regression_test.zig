//! Regressions that also build on the published R2-R5 main.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const reactor = @import("reactor.zig");
const Runtime = @import("Runtime.zig");
const Scheduler = @import("Scheduler.zig");
const Driver = @import("testing/Driver.zig");

fn init(r: *Runtime) !void {
    r.init(testing.allocator, .{ .workers = 0, .max_tasks = 32, .offload = .none }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
}

test "R1 native child wait uses no inline wait lane" {
    var r: Runtime = undefined;
    try init(&r);
    defer r.deinit();
    var child = try std.process.spawn(testing.io, .{
        .argv = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/c", "exit 7" } else &.{ "/bin/sh", "-c", "sleep 0.02; exit 7" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(testing.io);
    const before = r.stats().lanes[@backingInt(Runtime.Lane.wait)].@"inline";
    try testing.expectEqual(std.process.Child.Term{ .exited = 7 }, try child.wait(r.io()));
    try testing.expectEqual(before, r.stats().lanes[@backingInt(Runtime.Lane.wait)].@"inline");
}

test "R1 native open and stat use no inline file lane" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    try init(&r);
    defer r.deinit();
    if (r.backendKind() != .io_uring) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const before = r.stats().lanes[@backingInt(Runtime.Lane.general)].@"inline";
    const file = try tmp.dir.createFile(r.io(), "native", .{ .read = true });
    defer file.close(r.io());
    try file.writePositionalAll(r.io(), "native", 0);
    const opened = try tmp.dir.openFile(r.io(), "native", .{});
    defer opened.close(r.io());
    try testing.expectEqual(@as(u64, 6), (try opened.stat(r.io())).size);
    try testing.expectEqual(@as(u64, 6), (try tmp.dir.statFile(r.io(), "native", .{})).size);
    try testing.expectEqual(before, r.stats().lanes[@backingInt(Runtime.Lane.general)].@"inline");
}

noinline fn deepPark(io: Io, address: *usize) Io.Cancelable!u8 {
    var bytes: [192 << 10]u8 = @splat(73);
    const memory: *volatile [192 << 10]u8 = &bytes;
    memory[0] = 73;
    address.* = @intFromPtr(&bytes[16 << 10]); // safe: the runtime owns the mapping until deinit
    try io.sleep(.fromMilliseconds(1), .awake);
    return memory[16 << 10];
}

test "R1 ended deep stacks discard unused pages before recycling" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var d: Driver = undefined;
    try d.init(testing.allocator, 1, .{ .max_tasks = 8, .stack_size = 512 << 10, .offload = .none });
    defer d.deinit();
    var address: usize = 0;
    var future = try d.io().concurrent(deepPark, .{ d.io(), &address });
    try testing.expectEqual(@as(u8, 73), try future.await(d.io()));
    const byte: *volatile u8 = @ptrFromInt(address); // safe: reserved anonymous mapping, now free in the owned stack pool
    try testing.expectEqual(@as(u8, 0), byte.*);
}

fn idleStopGuard(done: *std.atomic.Value(bool)) void {
    for (0..2000) |_| {
        if (done.load(.acquire)) return;
        testing.io.sleep(.fromMilliseconds(1), .awake) catch return;
    }
    std.process.exit(97);
}
test "R1 stopping idle ring workers needs no subsequent source poll" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Runtime = undefined;
    r.init(testing.allocator, .{ .workers = 2, .backend = .io_uring, .max_tasks = 16 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer r.deinit();
    var done = std.atomic.Value(bool).init(false);
    const guard = try std.Thread.spawn(.{}, idleStopGuard, .{&done});
    defer {
        done.store(true, .release);
        guard.join();
    }
    try r.start();
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    r.stop();
}

test "R1 Linux dialing binds an interface without Threaded name lookup" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const name = try Io.net.Interface.Name.fromSlice("lo");
    const selected = try name.resolve(testing.io);
    var server = try (Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(testing.io, .{});
    defer server.deinit(testing.io);
    const connected = try reactor.net.connect(testing.io, &server.socket.address, .{ .interface = selected });
    defer connected.stream.close(testing.io);
    const peer = try server.accept(testing.io);
    defer peer.close(testing.io);
    try testing.expectEqual(connected.stream.socket.address.getPort(), peer.socket.address.getPort());
}

fn groupDeep(io: Io) void {
    var address: usize = 0;
    _ = deepPark(io, &address) catch @panic("group member sleep failed");
}
test "R1 group await observes all member stacks released" {
    var runtime: Runtime = undefined;
    runtime.init(testing.allocator, .{ .workers = 2, .max_tasks = 32, .stack_size = 512 << 10 }) catch |err| switch (err) {
        error.BackendUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer runtime.deinit();
    try runtime.start();
    const io = runtime.io();
    for (0..200) |_| {
        var group: Io.Group = .init;
        for (0..16) |_| try group.concurrent(io, groupDeep, .{io});
        try group.await(io);
        const observed = runtime.stats().tasks;
        // Let a broken before revision finish release, so the test reports
        // the assertion instead of panicking during runtime teardown.
        while (runtime.stats().tasks != 0) try testing.io.sleep(.fromMilliseconds(1), .awake);
        try testing.expectEqual(@as(u32, 0), observed);
    }
}

const CrossRuntime = struct {
    mode: enum { wake, spawn },
    scheduling: Scheduler.Scheduling = .stealing,
    published: Io.Event = .unset,
    release: Io.Event = .unset,
    event: Io.Event = .unset,
    io: Io = undefined,
    expected: usize = 0,
    observed: usize = 0,
    future: ?Io.Future(usize) = null,
    failure: ?Runtime.InitError = null,
    processor: *Scheduler.Processor = undefined,

    fn owner() usize {
        return @intFromPtr(Scheduler.processor().?.scheduler); // safe: identity only, retained until both threads finish
    }
    fn waiter(c: *CrossRuntime) usize {
        c.event.waitUncancelable(c.io);
        return owner();
    }
    fn destination(c: *CrossRuntime) void {
        var r: Runtime = undefined;
        r.init(testing.allocator, .{ .workers = if (c.scheduling == .stealing) 1 else 0, .max_tasks = 8, .offload = .none, .scheduling = c.scheduling }) catch |err| {
            c.failure = err;
            c.published.set(testing.io);
            return;
        };
        defer r.deinit();
        c.processor = Scheduler.processor().?;
        c.io = r.io();
        c.expected = owner();
        switch (c.mode) {
            .wake => {
                var future = c.io.concurrent(waiter, .{c}) catch @panic("destination spawn failed");
                r.run(.nowait);
                c.published.set(testing.io);
                c.observed = future.await(c.io);
                c.release.waitUncancelable(testing.io);
            },
            .spawn => {
                c.published.set(testing.io);
                c.release.waitUncancelable(testing.io);
                c.observed = c.future.?.await(c.io);
            },
        }
    }
    fn sender(c: *CrossRuntime) Io.ConcurrentError!bool {
        const p = Scheduler.processor().?;
        const before = if (comptime builtin.os.tag == .linux)
            if (p.loop.backend == .io_uring) p.loop.backend.io_uring.ring.sq.sqe_tail else 0
        else
            0;
        switch (c.mode) {
            .wake => {
                // Destination waiter and root are both off-stack before waking.
                while (!c.processor.sleeping.load(.seq_cst)) std.atomic.spinLoopHint();
                c.event.set(c.io);
            },
            .spawn => c.future = try c.io.concurrent(owner, .{}),
        }
        const after = if (comptime builtin.os.tag == .linux)
            if (p.loop.backend == .io_uring) p.loop.backend.io_uring.ring.sq.sqe_tail else 0
        else
            0;
        return before == after;
    }
    fn check(c: *CrossRuntime) !void {
        const thread = try std.Thread.spawn(.{}, destination, .{c});
        c.published.waitUncancelable(testing.io);
        if (c.failure) |err| {
            thread.join();
            if (err == error.BackendUnavailable) return error.SkipZigTest;
            return err;
        }
        var source: Runtime = undefined;
        try init(&source);
        var sender_future = try source.io().concurrent(sender, .{c});
        const ordinary_wake = try sender_future.await(source.io());
        source.run(.nowait);
        // Keep destination storage alive while the before source drains too.
        source.deinit();
        c.release.set(testing.io);
        thread.join();
        try testing.expectEqual(c.expected, c.observed);
        if (c.scheduling == .per_core) try testing.expect(ordinary_wake);
    }
};

test "R1 cross-runtime spawning retains destination scheduler ownership" {
    var c: CrossRuntime = .{ .mode = .spawn };
    try c.check();
}

test "R1 cross-runtime wake retains destination scheduler ownership" {
    var c: CrossRuntime = .{ .mode = .wake };
    try c.check();
}

test "R1 cross-runtime pinned wake retains no source-ring target reference" {
    var c: CrossRuntime = .{ .mode = .wake, .scheduling = .per_core };
    try c.check();
}
