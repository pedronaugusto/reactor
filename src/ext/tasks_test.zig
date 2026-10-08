const std = @import("std");
const testing = std.testing;
const reactor = @import("../reactor.zig");
const Scheduler = @import("../Scheduler.zig");
const Driver = @import("../testing/Driver.zig");

fn stackSize() usize {
    const p = Scheduler.processor().?;
    return p.scheduler.stacks.sizeAt(Scheduler.current().?.stack.?);
}

test "per-task sizes use init-reserved classes, remain bounded, and recycle" {
    var d: Driver = undefined;
    try d.init(testing.allocator, 0, .{ .max_tasks = 4, .stack_classes = &.{ .{ .size = 64 << 10, .count = 2 }, .{ .size = 2 << 20, .count = 1 } }, .offload = .none });
    defer d.deinit();
    const io = d.io();
    var small = try reactor.concurrentWith(io, .{ .stack_size = 64 << 10 }, stackSize, .{});
    var large = try reactor.concurrentWith(io, .{ .stack_size = 2 << 20 }, stackSize, .{});
    try testing.expectError(error.ConcurrencyUnavailable, reactor.concurrentWith(io, .{ .stack_size = 4 << 20 }, stackSize, .{}));
    try testing.expectEqual(@as(usize, 64 << 10), small.await(io));
    try testing.expectEqual(@as(usize, 2 << 20), large.await(io));
    var recycled = try reactor.concurrentWith(io, .{ .stack_size = 2 << 20 }, stackSize, .{});
    try testing.expectEqual(@as(usize, 2 << 20), recycled.await(io));
}

fn record(order: *[11]u8, used: *usize, value: u8) void {
    order[used.*] = value;
    used.* += 1;
}

test "latency tasks run ahead while normal work gets a turn after eight" {
    var d: Driver = undefined;
    try d.init(testing.allocator, 1, .{ .max_tasks = 16, .offload = .none });
    defer d.deinit();
    const io = d.io();
    var order: [11]u8 = undefined;
    var used: usize = 0;
    var normal = try io.concurrent(record, .{ &order, &used, @as(u8, 0) });
    var high: [10]std.Io.Future(void) = undefined;
    for (&high) |*future| future.* = try reactor.concurrentWith(io, .{ .priority = .latency }, record, .{ &order, &used, @as(u8, 1) });
    normal.await(io);
    for (&high) |*future| future.await(io);
    try testing.expectEqual(@as(usize, 11), used);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1 }, &order);
}

test "foreign Io refuses options it cannot honor and supports defaults" {
    try testing.expectError(error.ConcurrencyUnavailable, reactor.concurrentWith(testing.io, .{ .stack_size = 1024 }, record, undefined));
    var order: [11]u8 = undefined;
    var used: usize = 0;
    var future = try reactor.concurrentWith(testing.io, .{}, record, .{ &order, &used, @as(u8, 7) });
    future.await(testing.io);
    try testing.expectEqual(@as(u8, 7), order[0]);
}
