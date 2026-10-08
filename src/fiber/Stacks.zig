//! Size classes reserved at init, with one stable index per task across
//! every class. The default class stays first; explicit sizes take the
//! smallest configured class that fits and has capacity.
const Stacks = @This();
const std = @import("std");
const Pool = @import("Stacks/Pool.zig");
const memory = @import("../sys/memory.zig");
const fiber = @import("../fiber.zig");

pub const Class = struct { size: usize, count: u32 };
pub const Options = struct { count: u32, size: usize, classes: []const Class = &.{} };
pub const InitError = Pool.InitError;
pools: []Pool,
size: usize,
count: u32,
in_use: *std.atomic.Value(u32),

pub fn init(s: *Stacks, gpa: std.mem.Allocator, options: Options) InitError!void {
    var extra: u64 = 0;
    for (options.classes) |class| extra += class.count;
    if (extra > options.count) return error.TooManyTasks;
    const pools = try gpa.alloc(Pool, options.classes.len + 1);
    errdefer gpa.free(pools);
    var made: usize = 0;
    errdefer for (pools[0..made]) |*pool| pool.deinit(gpa);
    try pools[0].init(gpa, .{ .count = options.count - @as(u32, @intCast(extra)), .size = options.size });
    made += 1;
    for (options.classes, pools[1..]) |class, *pool| {
        try pool.init(gpa, .{ .count = class.count, .size = class.size });
        made += 1;
    }
    // Map limits apply to the whole runtime, not separately to each class.
    if (memory.maxMapCount()) |limit| {
        var needed: u64 = 4096;
        for (pools) |pool| needed += pool.slabs.len + if (pool.regions) @as(u64, 0) else 2 * @as(u64, pool.count);
        if (needed > limit) return error.TooManyTasks;
    }
    const in_use = if (pools.len == 1) &pools[0].in_use else try gpa.create(std.atomic.Value(u32));
    if (pools.len > 1) in_use.* = .init(0);
    s.* = .{ .pools = pools, .size = pools[0].size, .count = options.count, .in_use = in_use };
}

pub fn deinit(s: *Stacks, gpa: std.mem.Allocator) void {
    std.debug.assert(s.in_use.load(.acquire) == 0);
    for (s.pools) |*pool| pool.deinit(gpa);
    if (s.pools.len > 1) gpa.destroy(s.in_use);
    gpa.free(s.pools);
    s.* = undefined;
}

pub fn take(s: *Stacks) ?u32 {
    const index = s.pools[0].take() orelse return null;
    if (s.pools.len > 1) _ = s.in_use.fetchAdd(1, .monotonic);
    return index;
}

pub fn takeSized(s: *Stacks, bytes: ?usize) ?u32 {
    const size = bytes orelse return s.take();
    var previous: usize = 0;
    while (true) {
        var best: ?usize = null;
        for (s.pools, 0..) |pool, i| {
            if (pool.size < size or pool.size <= previous) continue;
            if (best == null or pool.size < s.pools[best.?].size) best = i;
        }
        const chosen = best orelse return null;
        const usable = s.pools[chosen].size;
        var offset: u32 = 0;
        for (s.pools) |*pool| {
            if (pool.size == usable) if (pool.take()) |index| {
                if (s.pools.len > 1) _ = s.in_use.fetchAdd(1, .monotonic);
                return offset + index;
            };
            offset += pool.count;
        }
        previous = usable;
    }
}

const Location = struct { pool: *Pool, index: u32 };
fn locate(s: *const Stacks, index: u32) Location {
    if (index < s.pools[0].count) return .{ .pool = &s.pools[0], .index = index };
    var remaining = index;
    for (s.pools) |*pool| {
        if (remaining < pool.count) return .{ .pool = pool, .index = remaining };
        remaining -= pool.count;
    }
    unreachable; // unreachable: only indices returned by take are used
}

pub fn sizeAt(s: *const Stacks, index: u32) usize {
    return s.locate(index).pool.size;
}
pub fn top(s: *const Stacks, index: u32) usize {
    const l = s.locate(index);
    return l.pool.top(l.index);
}
pub fn bottom(s: *const Stacks, index: u32) usize {
    const l = s.locate(index);
    return l.pool.bottom(l.index);
}
pub fn stack(s: *const Stacks, index: u32) fiber.Stack {
    const l = s.locate(index);
    return l.pool.stack(l.index);
}
pub fn reach(s: *Stacks, index: u32, low: usize) bool {
    const l = s.locate(index);
    return l.pool.reach(l.index, low);
}
pub fn ended(s: *Stacks, index: u32, limit: usize) void {
    const l = s.locate(index);
    l.pool.ended(l.index, limit);
}
pub fn give(s: *Stacks, index: u32) void {
    const l = s.locate(index);
    l.pool.give(l.index);
    if (s.pools.len > 1) _ = s.in_use.fetchSub(1, .release);
}
pub fn trim(s: *const Stacks, index: u32, keep_from: usize) void {
    const l = s.locate(index);
    l.pool.trim(l.index, keep_from);
}
