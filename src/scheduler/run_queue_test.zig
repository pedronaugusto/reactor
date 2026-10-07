const std = @import("std");
const testing = std.testing;
const run_queue = @import("run_queue.zig");

const Item = struct { id: u32 };
const Queue = run_queue.RunQueue(Item);

test "the owner pops in push order" {
    var q: Queue = .{};
    var items: [10]Item = undefined;
    for (&items, 0..) |*it, i| {
        it.* = .{ .id = @intCast(i) };
        try testing.expect(q.push(it));
    }
    for (0..10) |i| try testing.expectEqual(@as(u32, @intCast(i)), q.pop().?.id);
    try testing.expectEqual(@as(?*Item, null), q.pop());
}

test "a full queue refuses, and gives its older half away" {
    var q: Queue = .{};
    var items: [run_queue.capacity + 1]Item = undefined;
    for (items[0..run_queue.capacity], 0..) |*it, i| {
        it.* = .{ .id = @intCast(i) };
        try testing.expect(q.push(it));
    }
    try testing.expect(!q.push(&items[run_queue.capacity]));
    var half: [run_queue.capacity / 2]*Item = undefined;
    try testing.expect(q.takeHalf(&half));
    try testing.expectEqual(@as(u32, 0), half[0].id);
    try testing.expect(q.push(&items[run_queue.capacity]));
    try testing.expectEqual(@as(u32, run_queue.capacity / 2), q.pop().?.id);
}

test "a steal moves half and returns one" {
    var a: Queue = .{};
    var b: Queue = .{};
    var items: [8]Item = undefined;
    for (&items, 0..) |*it, i| {
        it.* = .{ .id = @intCast(i) };
        try testing.expect(a.push(it));
    }
    const got = a.stealInto(&b).?;
    try testing.expectEqual(@as(u32, 3), got.id);
    try testing.expectEqual(@as(u32, 0), b.pop().?.id);
    try testing.expectEqual(@as(u32, 1), b.pop().?.id);
    try testing.expectEqual(@as(u32, 2), b.pop().?.id);
    try testing.expectEqual(@as(?*Item, null), b.pop());
    for (4..8) |i| try testing.expectEqual(@as(u32, @intCast(i)), a.pop().?.id);
}

test "stealers and an owner never lose or repeat a task" {
    const total = 200_000;
    const Shared = struct {
        const Self = @This();
        q: Queue = .{},
        seen: []std.atomic.Value(u8),
        done: std.atomic.Value(bool) = .init(false),
        taken: std.atomic.Value(usize) = .init(0),

        fn take(s: *Self, item: *Item) void {
            const before = s.seen[item.id].fetchAdd(1, .monotonic);
            std.debug.assert(before == 0);
            _ = s.taken.fetchAdd(1, .monotonic);
        }

        fn thief(s: *Self) void {
            var mine: Queue = .{};
            while (!s.done.load(.acquire) or !s.q.isEmpty()) {
                if (s.q.stealInto(&mine)) |item| s.take(item);
                while (mine.pop()) |item| s.take(item);
            }
            while (mine.pop()) |item| s.take(item);
        }
    };
    const gpa = testing.allocator;
    const items = try gpa.alloc(Item, total);
    defer gpa.free(items);
    const seen = try gpa.alloc(std.atomic.Value(u8), total);
    defer gpa.free(seen);
    @memset(seen, .init(0));
    var s: Shared = .{ .seen = seen };
    var thieves: [3]std.Thread = undefined;
    for (&thieves) |*t| t.* = try std.Thread.spawn(.{}, Shared.thief, .{&s});
    for (items, 0..) |*it, i| {
        it.* = .{ .id = @intCast(i) };
        while (!s.q.push(it)) if (s.q.pop()) |own| s.take(own);
        if (i % 3 == 0) if (s.q.pop()) |own| s.take(own);
    }
    while (s.q.pop()) |own| s.take(own);
    s.done.store(true, .release);
    for (thieves) |t| t.join();
    try testing.expectEqual(@as(usize, total), s.taken.load(.monotonic));
}
