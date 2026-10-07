//! The runtime's tasks, timers, futexes, groups and cancellation, on the
//! seeded fake (`Driver`, virtual time) and on real worker threads over the
//! idle fake (`Threads`, real time); shakedown's conformance suite on both.
const std = @import("std");
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
