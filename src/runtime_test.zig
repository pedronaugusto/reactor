//! The runtime's tasks, timers, futexes, groups and cancellation, on the
//! seeded fake (`Driver`, virtual time) and on real worker threads over the
//! idle fake (`Threads`, real time); shakedown's conformance suite on both.
const builtin = @import("builtin");
const std = @import("std");
const getaddrinfo = @import("sys/getaddrinfo.zig");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");

const fiber = @import("fiber.zig");
const Driver = @import("testing/Driver.zig");
const Threads = @import("testing/Threads.zig");

fn skipWithoutFibers() !void {
    if (!fiber.supported) return error.SkipZigTest;
}

const Runtime = @import("Runtime.zig");
const blocking = @import("ext/blocking.zig").blocking;

const small: Runtime.Options = .{ .max_tasks = 256, .stack_size = 256 << 10, .offload = .none };

test "a sleep on the driver moves virtual time by exactly its length" {
    try skipWithoutFibers();
    var d: Driver = undefined;
    try d.init(testing.allocator, 1, small);
    defer d.deinit();
    const io = d.io();
    const before = d.elapsed();
    try io.sleep(.fromMilliseconds(250), .awake);
    const slept = d.elapsed() - before;
    try testing.expect(slept >= 250 * std.time.ns_per_ms);
    try testing.expect(slept < 251 * std.time.ns_per_ms);
}

fn addOne(x: u32) u32 {
    return x + 1;
}

test "concurrent runs a task whose result await returns" {
    try skipWithoutFibers();
    var d: Driver = undefined;
    try d.init(testing.allocator, 2, small);
    defer d.deinit();
    const io = d.io();
    var f = try io.concurrent(addOne, .{41});
    try testing.expectEqual(@as(u32, 42), f.await(io));
}

fn sleeper(io: Io, ms: i64, out: *u32) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(ms), .awake);
    out.* += 1;
}

test "a group's tasks all run, and its await waits for them" {
    try skipWithoutFibers();
    var d: Driver = undefined;
    try d.init(testing.allocator, 3, small);
    defer d.deinit();
    const io = d.io();
    var count: u32 = 0;
    var group: Io.Group = .init;
    for (0..10) |i| group.async(io, sleeper, .{ io, @as(i64, @intCast(i)) * 3, &count });
    try group.await(io);
    try testing.expectEqual(@as(u32, 10), count);
}

fn sleepLong(io: Io) Io.Cancelable!void {
    try io.sleep(.fromSeconds(3600), .awake);
}

test "cancel ends a task's sleep at once" {
    try skipWithoutFibers();
    var d: Driver = undefined;
    try d.init(testing.allocator, 4, small);
    defer d.deinit();
    const io = d.io();
    var f = try io.concurrent(sleepLong, .{io});
    try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectError(error.Canceled, f.cancel(io));
    try testing.expect(d.elapsed() < std.time.ns_per_s);
}

test "shakedown's conformance suite passes on the driver" {
    try skipWithoutFibers();
    for (0..8) |seed| {
        var d: Driver = undefined;
        try d.init(testing.allocator, seed, small);
        defer d.deinit();
        var failure: shakedown.conformance.Failure = undefined;
        shakedown.conformance.run(testing.allocator, d.io(), .{ .failure = &failure }) catch {
            std.debug.print("seed {d}: {s}: {t}\n", .{ seed, failure.check, failure.err });
            return error.Nonconforming;
        };
    }
}

test "shakedown's conformance suite passes on real worker threads" {
    try skipWithoutFibers();
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 3, .max_tasks = 256, .stack_size = 256 << 10 });
    defer t.deinit();
    var failure: shakedown.conformance.Failure = undefined;
    shakedown.conformance.run(testing.allocator, t.io(), .{ .failure = &failure }) catch {
        std.debug.print("{s}: {t}\n", .{ failure.check, failure.err });
        return error.Nonconforming;
    };
}

fn parkMany(io: Io, n: usize, home: std.Thread.Id) !void {
    var word: u32 = 0;
    for (0..n) |_| {
        // A wait that returns at once is still a trip through the scheduler.
        try io.futexWaitTimeout(u32, &word, 0, .{ .duration = .{ .raw = .fromNanoseconds(1), .clock = .awake } });
        if (std.Thread.getCurrentId() != home) return error.RootMigrated;
    }
}

fn busy(io: Io, stop: *std.atomic.Value(bool)) Io.Cancelable!void {
    while (!stop.load(.acquire)) try io.sleep(.fromMicroseconds(50), .awake);
}

test "the root never leaves the home thread, however often it waits" {
    try skipWithoutFibers();
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 4, .max_tasks = 64, .stack_size = 256 << 10 });
    defer t.deinit();
    const io = t.io();
    var stop: std.atomic.Value(bool) = .init(false);
    var group: Io.Group = .init;
    for (0..8) |_| try group.concurrent(io, busy, .{ io, &stop });
    try parkMany(io, 2000, std.Thread.getCurrentId());
    stop.store(true, .release);
    try group.await(io);
}

test "shakedown's conformance suite passes with shared-nothing processors" {
    try skipWithoutFibers();
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 3, .scheduling = .per_core, .max_tasks = 256, .stack_size = 256 << 10 });
    defer t.deinit();
    var failure: shakedown.conformance.Failure = undefined;
    shakedown.conformance.run(testing.allocator, t.io(), .{ .failure = &failure }) catch {
        std.debug.print("{s}: {t}\n", .{ failure.check, failure.err });
        return error.Nonconforming;
    };
}

/// An allocator that refuses everything once sealed: the runtime must not
/// allocate after `init`.
const Sealed = struct {
    backing: std.mem.Allocator,
    sealed: bool = false,

    fn allocator(s: *Sealed) std.mem.Allocator {
        return .{ .ptr = s, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn of(context: *anyopaque) *Sealed {
        return @ptrCast(@alignCast(context));
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const s = of(context);
        if (s.sealed) @panic("the runtime allocated after init");
        return s.backing.rawAlloc(len, alignment, ret);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const s = of(context);
        if (s.sealed) @panic("the runtime allocated after init");
        return s.backing.rawResize(memory, alignment, new_len, ret);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const s = of(context);
        if (s.sealed) @panic("the runtime allocated after init");
        return s.backing.rawRemap(memory, alignment, new_len, ret);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        of(context).backing.rawFree(memory, alignment, ret);
    }
};

test "after init the runtime allocates nothing: the conformance suite with the allocator sealed" {
    try skipWithoutFibers();
    var sealed: Sealed = .{ .backing = testing.allocator };
    var d: Driver = undefined;
    try d.initWith(testing.allocator, sealed.allocator(), 11, small);
    defer d.deinit();
    sealed.sealed = true;
    defer sealed.sealed = false;
    var failure: shakedown.conformance.Failure = undefined;
    shakedown.conformance.run(testing.allocator, d.io(), .{ .failure = &failure }) catch {
        std.debug.print("{s}: {t}\n", .{ failure.check, failure.err });
        return error.Nonconforming;
    };
}

fn fromAnotherThread(io: Io, out: *u32) void {
    var f = io.concurrent(addOne, .{41}) catch return;
    out.* = f.await(io);
    // Nothing cancels a thread outside the runtime.
    io.sleep(.fromMilliseconds(1), .awake) catch unreachable; // unreachable: no cancel reaches this thread
}

test "a thread outside the runtime uses its Io: a task started, awaited, and a sleep" {
    try skipWithoutFibers();
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 2, .max_tasks = 64, .stack_size = 256 << 10 });
    defer t.deinit();
    var out: u32 = 0;
    const thread = try std.Thread.spawn(.{}, fromAnotherThread, .{ t.io(), &out });
    thread.join();
    try testing.expectEqual(@as(u32, 42), out);
}

fn wakeFromThread(io: Io, word: *std.atomic.Value(u32)) void {
    io.sleep(.fromMilliseconds(2), .awake) catch unreachable; // unreachable: no cancel reaches this thread
    word.store(1, .release);
    io.futexWake(u32, &word.raw, 1);
}

test "a futex wake from a thread outside the runtime reaches a waiting task" {
    try skipWithoutFibers();
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 1, .max_tasks = 64, .stack_size = 256 << 10 });
    defer t.deinit();
    const io = t.io();
    var word: std.atomic.Value(u32) = .init(0);
    const thread = try std.Thread.spawn(.{}, wakeFromThread, .{ io, &word });
    defer thread.join();
    while (word.load(.acquire) == 0) try io.futexWait(u32, &word.raw, 0);
}

fn connectBriefly(io: Io, rounds: usize, failures: *std.atomic.Value(u32)) Io.Cancelable!void {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(9) };
    for (0..rounds) |_| {
        if (address.connect(io, .{ .mode = .stream, .timeout = .{ .duration = .{ .raw = .fromMicroseconds(200), .clock = .awake } } })) |stream| {
            stream.close(io);
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => {},
            else => _ = failures.fetchAdd(1, .monotonic),
        }
    }
}

test "a deadline's timer is disarmed on the processor that armed it, wherever its task was woken" {
    try skipWithoutFibers();
    // The runtime makes its own sockets only where it has a backend.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 3, .max_tasks = 128, .stack_size = 256 << 10 });
    defer t.deinit();
    const io = t.io();
    var failures: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    // The idle fake never completes a connect: every one ends at its
    // deadline, and other processors are free to steal the woken task.
    for (0..32) |_| try group.concurrent(io, connectBriefly, .{ io, 20, &failures });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
}

fn waitOnLane(gate: *std.atomic.Value(u32)) void {
    const sys = Io.Threaded.global_single_threaded.io();
    while (gate.load(.acquire) == 0) sys.futexWaitUncancelable(u32, &gate.raw, 0);
}

fn laneCall(io: Io, gate: *std.atomic.Value(u32)) void {
    blocking(io, .general, waitOnLane, .{gate});
}

test "calls beyond a lane's cap wait their turn, never inline on a worker" {
    try skipWithoutFibers();
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 2, .max_tasks = 1100, .stack_size = 64 << 10, .offload = .{ .owned = .{ .general = 1 } } });
    defer t.deinit();
    const io = t.io();
    var gate: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    // More calls than the lane's queue once held: the first holds the lane
    // until all have been made.
    for (0..1050) |_| try group.concurrent(io, laneCall, .{ io, &gate });
    while (t.runtime.stats().lanes[@backingInt(Runtime.Lane.general)].queued < 1049) try io.sleep(.fromMilliseconds(1), .awake);
    gate.store(1, .release);
    Io.Threaded.global_single_threaded.io().futexWake(u32, &gate.raw, std.math.maxInt(u32));
    try group.await(io);
    try testing.expectEqual(@as(u64, 0), t.runtime.stats().lanes[@backingInt(Runtime.Lane.general)].@"inline");
}

/// An executor that counts the calls handed to it.
const Counting = shakedown.Layer(std.atomic.Value(u32), .{ .groupConcurrent = struct {
    fn groupConcurrent(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, alignment: std.mem.Alignment, start: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
        const layer = Counting.of(userdata);
        _ = layer.state.fetchAdd(1, .monotonic);
        return layer.base.vtable.groupConcurrent(layer.base.userdata, group, context, alignment, start);
    }
}.groupConcurrent });

test "an injected executor carries every lane call" {
    try skipWithoutFibers();
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var counting: Counting = .init(threaded.io(), .init(0));
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 1, .max_tasks = 64, .stack_size = 256 << 10, .offload = .{ .injected = counting.io() } });
    defer t.deinit();
    const io = t.io();
    for (0..5) |i| try testing.expectEqual(@as(u32, @intCast(i)) + 1, blocking(io, .sync, addOne, .{@as(u32, @intCast(i))}));
    try testing.expectEqual(@as(u32, 5), counting.state.load(.monotonic));
}

fn manyCalls(io: Io, rounds: usize) !void {
    for (0..rounds) |_| if (blocking(io, .general, addOne, .{0}) != 1) return error.WrongResult;
}

test "lane calls one after another from a task and from the root keep their frames" {
    try skipWithoutFibers();
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 3, .max_tasks = 64, .stack_size = 256 << 10 });
    defer t.deinit();
    const io = t.io();
    // A value the caller keeps in a register across every switch.
    const me = std.Thread.getCurrentId();
    var task = try io.concurrent(manyCalls, .{ io, 5000 });
    try task.await(io);
    try manyCalls(io, 5000);
    try testing.expectEqual(me, std.Thread.getCurrentId());
}

test "process spawn on a lane has space for std's temporary arena" {
    try skipWithoutFibers();
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 0, .max_tasks = 16, .stack_size = 256 << 10 });
    defer t.deinit();
    const io = t.io();
    var child = try std.process.spawn(io, .{ .argv = if (builtin.os.tag == .windows) &.{ "C:\\Windows\\System32\\cmd.exe", "/c", @as([4096]u8, @splat(' ')) ++ "exit 0" } else &.{ "/bin/sh", "-c", @as([4096]u8, @splat(' ')) ++ "exit 0" } });
    errdefer child.kill(io);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

test "a canceled libc lookup detaches while its bounded storage stays alive" {
    try skipWithoutFibers();
    const Slow = struct {
        var runtime_io: Io = undefined;
        var started: Io.Event = .unset;
        var release: Io.Event = .unset;
        var finished: std.atomic.Value(bool) = .init(false);
        fn lookup(_: []const u8, port: u16, _: ?Io.net.IpAddress.Family, out: []Io.net.IpAddress, _: ?*[254]u8) getaddrinfo.Error!getaddrinfo.Result {
            started.set(runtime_io);
            release.waitUncancelable(testing.io);
            out[0] = .{ .ip4 = .loopback(port) };
            finished.store(true, .release);
            return .{ .addresses = out[0..1] };
        }
        fn run(t: *Threads) !usize {
            var out: [2]Io.net.IpAddress = undefined;
            return (try t.runtime.core.lookup.resolve(&t.runtime.core.scheduler, &t.runtime.core.lanes, lookup, try .init("slow.example"), .{ .port = 80 }, &out)).count;
        }
    };
    var t: Threads = undefined;
    try t.init(testing.allocator, .{ .workers = 1, .max_tasks = 16, .max_lookups = 1, .stack_size = 256 << 10 });
    defer t.deinit();
    Slow.runtime_io = t.io();
    var task = try t.io().concurrent(Slow.run, .{&t});
    defer Slow.release.set(testing.io);
    try Slow.started.wait(t.io());
    try testing.expectError(error.Canceled, task.cancel(t.io()));
    try testing.expect(!Slow.finished.load(.acquire));
    var second = try t.io().concurrent(Slow.run, .{&t});
    try testing.expectError(error.SystemResources, second.await(t.io()));
    Slow.release.set(testing.io);
}
