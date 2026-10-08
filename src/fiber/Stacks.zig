//! Size classes reserved at init, with one stable index per task across
//! every class. The default class stays first; explicit sizes take the
//! smallest configured class that fits and has capacity.
const Stacks = @This();
const std = @import("std");
const builtin = @import("builtin");
const Pool = @import("Stacks/Pool.zig");
const memory = @import("../sys/memory.zig");
const fiber = @import("../fiber.zig");

pub const Class = struct { size: usize, count: u32 };
pub const Options = struct { count: u32, size: usize, classes: []const Class = &.{} };
pub const InitError = Pool.InitError;
default_pool: Pool,
/// Only additional classes need a table. The common pool stays directly
/// in runtime state, with no pointer alias into an init temporary.
pools: []Pool,
size: usize,
count: u32,
total_in_use: std.atomic.Value(u32) = .init(0),

pub fn init(s: *Stacks, gpa: std.mem.Allocator, options: Options) InitError!void {
    var extra: u64 = 0;
    for (options.classes) |class| extra += class.count;
    if (extra > options.count) return error.TooManyTasks;
    var default_pool: Pool = undefined;
    try default_pool.init(gpa, .{ .count = options.count - @as(u32, @intCast(extra)), .size = options.size });
    errdefer default_pool.deinit(gpa);
    const pools = try gpa.alloc(Pool, options.classes.len);
    errdefer gpa.free(pools);
    var made: usize = 0;
    errdefer for (pools[0..made]) |*pool| pool.deinit(gpa);
    for (options.classes, pools) |class, *pool| {
        try pool.init(gpa, .{ .count = class.count, .size = class.size });
        made += 1;
    }
    // Map limits apply to the whole runtime, not separately to each class.
    if (memory.maxMapCount()) |limit| {
        var needed: u64 = 4096 + default_pool.slabs.len + if (default_pool.regions) @as(u64, 0) else 2 * @as(u64, default_pool.count);
        for (pools) |pool| needed += pool.slabs.len + if (pool.regions) @as(u64, 0) else 2 * @as(u64, pool.count);
        if (needed > limit) return error.TooManyTasks;
    }
    s.* = .{ .default_pool = default_pool, .pools = pools, .size = default_pool.size, .count = options.count };
}

pub fn inUse(s: *const Stacks, comptime order: std.builtin.AtomicOrder) u32 {
    return if (s.pools.len == 0) s.default_pool.in_use.load(order) else s.total_in_use.load(order);
}
pub fn deinit(s: *Stacks, gpa: std.mem.Allocator) void {
    std.debug.assert(s.inUse(.acquire) == 0);
    s.default_pool.deinit(gpa);
    for (s.pools) |*pool| pool.deinit(gpa);
    gpa.free(s.pools);
    s.* = undefined;
}

pub fn take(s: *Stacks) ?u32 {
    const index = s.default_pool.take() orelse return null;
    if (s.pools.len > 0) _ = s.total_in_use.fetchAdd(1, .monotonic);
    return index;
}
fn poolAt(s: *Stacks, index: usize) *Pool {
    return if (index == 0) &s.default_pool else &s.pools[index - 1];
}
pub fn takeSized(s: *Stacks, bytes: ?usize) ?u32 {
    const size = bytes orelse return s.take();
    var previous: usize = 0;
    while (true) {
        var best: ?usize = null;
        for (0..s.pools.len + 1) |i| {
            const pool = s.poolAt(i);
            if (pool.size < size or pool.size <= previous) continue;
            if (best == null or pool.size < s.poolAt(best.?).size) best = i;
        }
        const chosen = best orelse return null;
        const usable = s.poolAt(chosen).size;
        var offset: u32 = 0;
        for (0..s.pools.len + 1) |i| {
            const pool = s.poolAt(i);
            if (pool.size == usable) if (pool.take()) |index| {
                if (s.pools.len > 0) _ = s.total_in_use.fetchAdd(1, .monotonic);
                return offset + index;
            };
            offset += pool.count;
        }
        previous = usable;
    }
}

pub const Location = struct { pool: *Pool, index: u32 };
pub fn locate(s: *Stacks, index: u32) Location {
    if (index < s.default_pool.count) return .{ .pool = &s.default_pool, .index = index };
    var remaining = index - s.default_pool.count;
    for (s.pools) |*pool| {
        if (remaining < pool.count) return .{ .pool = pool, .index = remaining };
        remaining -= pool.count;
    }
    unreachable; // unreachable: only indices returned by take are used
}

pub fn sizeAt(s: *Stacks, index: u32) usize {
    return s.locate(index).pool.size;
}
pub fn top(s: *Stacks, index: u32) usize {
    const l = s.locate(index);
    return l.pool.top(l.index);
}
pub fn bottom(s: *Stacks, index: u32) usize {
    const l = s.locate(index);
    return l.pool.bottom(l.index);
}
pub fn stack(s: *Stacks, index: u32) fiber.Stack {
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
    if (s.pools.len > 0) _ = s.total_in_use.fetchSub(1, .release);
}
pub fn trim(s: *Stacks, index: u32, keep_from: usize) void {
    const l = s.locate(index);
    l.pool.trim(l.index, keep_from);
}

/// Diagnostic painting commits the stack before entry; it is opt-in and
/// disabled in ordinary runs. No live frame is ever painted.
pub fn paint(s: *Stacks, index: u32, until: usize) bool {
    const low = s.bottom(index) + if (builtin.os.tag == .windows) memory.pageSize() else @as(usize, 0);
    if (!s.reach(index, low)) return false;
    const bytes: [*]u8 = @ptrFromInt(low); // safe: exclusively owned, committed stack below its initial frame
    @memset(bytes[0 .. until - low], 0xa5);
    return true;
}

/// Called off-stack, before publishing a wake or an ended task. The
/// lowest changed byte measures deepest touched storage, including work
/// which returned before the next park.
pub fn highWater(s: *Stacks, index: u32) usize {
    const low = s.bottom(index) + if (builtin.os.tag == .windows) memory.pageSize() else @as(usize, 0);
    const bytes: [*]const u8 = @ptrFromInt(low); // safe: the scheduler exclusively owns this suspended stack
    const size = s.top(index) - low;
    for (bytes[0..size], 0..) |byte, at| if (byte != 0xa5) return size - at;
    return 0;
}
