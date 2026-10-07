const std = @import("std");
const testing = std.testing;
const Wheel = @import("Wheel.zig");

const Ignore = struct {
    pub fn fire(_: *const Ignore, _: *Wheel.Node) void {}
};

const Recorder = struct {
    fired: std.ArrayList(u64) = .empty,
    gpa: std.mem.Allocator,

    pub fn fire(r: *Recorder, node: *Wheel.Node) void {
        r.fired.append(r.gpa, node.deadline) catch @panic("OOM");
    }
};

test "the wheel fires every timer at its tick, earliest first" {
    var w: Wheel = .init(0);
    var nodes: [8]Wheel.Node = @splat(.{});
    const deadlines = [_]u64{ 5, 1, 64, 63, 4096, 70, 262_144, 2 };
    for (&nodes, deadlines) |*n, d| w.arm(n, d);
    try testing.expectEqual(@as(u32, 8), w.count);
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.fired.deinit(testing.allocator);
    w.advance(100, &r);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 5, 63, 64, 70 }, r.fired.items);
    try testing.expectEqual(@as(?u64, 4096), w.next());
    w.advance(1_000_000, &r);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 5, 63, 64, 70, 4096, 262_144 }, r.fired.items);
    try testing.expectEqual(@as(?u64, null), w.next());
    try testing.expectEqual(@as(u32, 0), w.count);
}

test "the wheel fires timers due at one tick in arming order" {
    var w: Wheel = .init(10);
    var nodes: [4]Wheel.Node = @splat(.{});
    // One armed far ahead (a high level), then nearer ones for the same tick.
    w.arm(&nodes[0], 5000);
    w.advance(4990, &Ignore{});
    w.arm(&nodes[1], 5000);
    w.arm(&nodes[2], 4995);
    w.arm(&nodes[3], 5000);
    const Order = struct {
        const Self = @This();
        seen: [4]*Wheel.Node = undefined,
        n: usize = 0,
        pub fn fire(o: *Self, node: *Wheel.Node) void {
            o.seen[o.n] = node;
            o.n += 1;
        }
    };
    var order: Order = .{};
    w.advance(6000, &order);
    try testing.expectEqual(@as(usize, 4), order.n);
    try testing.expectEqual(&nodes[2], order.seen[0]);
    try testing.expectEqual(&nodes[0], order.seen[1]);
    try testing.expectEqual(&nodes[1], order.seen[2]);
    try testing.expectEqual(&nodes[3], order.seen[3]);
}

test "a disarmed timer never fires, and its node can be armed again" {
    var w: Wheel = .init(0);
    var a: Wheel.Node = .{};
    var b: Wheel.Node = .{};
    w.arm(&a, 300);
    w.arm(&b, 300);
    w.disarm(&a);
    try testing.expect(!a.armed());
    w.arm(&a, 10);
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.fired.deinit(testing.allocator);
    w.advance(500, &r);
    try testing.expectEqualSlices(u64, &.{ 10, 300 }, r.fired.items);
    w.disarm(&a); // not armed: nothing happens
}

test "a timer armed for a passed tick fires at the next advance" {
    var w: Wheel = .init(1000);
    var a: Wheel.Node = .{};
    w.arm(&a, 3);
    try testing.expectEqual(@as(?u64, 1000), w.next());
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.fired.deinit(testing.allocator);
    w.advance(1000, &r);
    try testing.expectEqualSlices(u64, &.{3}, r.fired.items);
}

test "a deadline past the wheel's horizon waits on the overflow list and still fires on time" {
    var w: Wheel = .init(0);
    var far: Wheel.Node = .{};
    var near: Wheel.Node = .{};
    const horizon = @as(u64, 1) << Wheel.horizon_bits;
    w.arm(&far, horizon + 7);
    w.arm(&near, 7);
    var r: Recorder = .{ .gpa = testing.allocator };
    defer r.fired.deinit(testing.allocator);
    w.advance(horizon - 1, &r);
    try testing.expectEqualSlices(u64, &.{7}, r.fired.items);
    w.advance(horizon + 6, &r);
    try testing.expectEqual(@as(usize, 1), r.fired.items.len);
    w.advance(horizon + 7, &r);
    try testing.expectEqualSlices(u64, &.{ 7, horizon + 7 }, r.fired.items);
}

test "next reports the earliest deadline exactly, a crowded upper slot by its start" {
    var w: Wheel = .init(0);
    var a: Wheel.Node = .{};
    w.arm(&a, 37);
    try testing.expectEqual(@as(?u64, 37), w.next());
    w.disarm(&a);
    w.arm(&a, 64 * 5 + 3);
    try testing.expectEqual(@as(?u64, 64 * 5 + 3), w.next());
    w.advance(64 * 5, &Ignore{});
    try testing.expectEqual(@as(?u64, 64 * 5 + 3), w.next());
    var crowd: [40]Wheel.Node = @splat(.{});
    var v: Wheel = .init(0);
    for (&crowd, 0..) |*n, i| v.arm(n, 64 * 9 + 10 + i);
    try testing.expectEqual(@as(?u64, 64 * 9), v.next());
}

test "a million timers armed and nearly all disarmed" {
    const gpa = testing.allocator;
    const n = 1 << 20;
    const nodes = try gpa.alloc(Wheel.Node, n);
    defer gpa.free(nodes);
    @memset(nodes, .{});
    var w: Wheel = .init(0);
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    for (nodes) |*node| w.arm(node, random.uintLessThan(u64, 10_000_000) + 1);
    for (nodes, 0..) |*node, i| if (i % 100 != 0) w.disarm(node);
    const Count = struct {
        const Self = @This();
        n: usize = 0,
        last: u64 = 0,
        pub fn fire(c: *Self, node: *Wheel.Node) void {
            std.debug.assert(node.deadline >= c.last);
            c.last = node.deadline;
            c.n += 1;
        }
    };
    var c: Count = .{};
    w.advance(20_000_000, &c);
    try testing.expectEqual(@as(usize, (n + 99) / 100), c.n);
}
