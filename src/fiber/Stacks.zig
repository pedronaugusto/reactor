//! Size classes reserved at init, with one stable index per task across
//! every class. The default class stays first; explicit sizes take the
//! smallest configured class that fits and has capacity.
const Stacks = @This();
const std = @import("std");
const aegis = @import("aegis");
const builtin = @import("builtin");
const Pool = @import("Stacks/Pool.zig");
const memory = @import("../sys/memory.zig");
const fiber = @import("../fiber.zig");

/// One stack among all of a runtime's, whatever its class. A `Pool.Slot` is
/// its place in one class; `locate` is the only way from one to the other.
pub const Stack = aegis.id.Id(struct {}, u32);

pub const Bytes = aegis.units.Bytes(usize);

pub const Class = struct { size: Bytes, count: u32 };
pub const Options = struct { count: u32, size: Bytes, classes: []const Class = &.{} };
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
    try default_pool.init(gpa, .{ .count = options.count - @as(u32, @intCast(extra)), .size = options.size }); // safe: not above `options.count`, checked above
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

/// A stack handed out: its number among all of them, and its place in its class.
pub const Taken = struct { stack: Stack, at: Location };

pub inline fn take(s: *Stacks) ?Taken {
    const slot = s.default_pool.take() orelse return null;
    if (s.pools.len > 0) _ = s.total_in_use.fetchAdd(1, .monotonic);
    // The default class comes first, so its slots are the first stacks.
    return .{ .stack = .fromRaw(slot.raw()), .at = .{ .pool = &s.default_pool, .slot = slot } };
}
fn poolAt(s: *Stacks, index: usize) *Pool {
    return if (index == 0) &s.default_pool else &s.pools[index - 1];
}
pub fn takeSized(s: *Stacks, bytes: ?Bytes) ?Taken {
    const size = (bytes orelse return s.take()).raw(); // the pools' sizes are plain: compared here, nowhere else
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
        var first: Stack = .fromRaw(0);
        for (0..s.pools.len + 1) |i| {
            const pool = s.poolAt(i);
            if (pool.size == usable) if (pool.take()) |slot| {
                if (s.pools.len > 0) _ = s.total_in_use.fetchAdd(1, .monotonic);
                const number = first.advance(.fromRaw(slot.raw())) catch unreachable; // unreachable: the classes hold `count` stacks in all, and a number is below it
                return .{ .stack = number, .at = .{ .pool = pool, .slot = slot } };
            };
            first = first.advance(.fromRaw(pool.count)) catch unreachable; // unreachable: the pools hold `count` stacks in all, which a stack number holds
        }
        previous = usable;
    }
}

pub const Location = struct { pool: *Pool, slot: Pool.Slot };
pub inline fn locate(s: *Stacks, stack_id: Stack) Location {
    const index = stack_id.raw(); // Stacks alone turns a stack number into a class and a slot
    if (index < s.default_pool.count) return .{ .pool = &s.default_pool, .slot = .fromRaw(index) };
    var remaining = index - s.default_pool.count;
    for (s.pools) |*pool| {
        if (remaining < pool.count) return .{ .pool = pool, .slot = .fromRaw(remaining) };
        remaining -= pool.count;
    }
    unreachable; // unreachable: only stacks returned by take are used
}

pub fn sizeAt(s: *Stacks, stack_id: Stack) usize {
    return s.locate(stack_id).pool.size;
}
pub fn top(s: *Stacks, stack_id: Stack) usize {
    const l = s.locate(stack_id);
    return l.pool.top(l.slot);
}
pub fn bottom(s: *Stacks, stack_id: Stack) usize {
    const l = s.locate(stack_id);
    return l.pool.bottom(l.slot);
}
pub fn stack(s: *Stacks, stack_id: Stack) fiber.Stack {
    const l = s.locate(stack_id);
    return l.pool.stack(l.slot);
}
pub fn reach(s: *Stacks, stack_id: Stack, low: usize) bool {
    const l = s.locate(stack_id);
    return l.pool.reach(l.slot, low);
}
pub inline fn ended(s: *Stacks, stack_id: Stack, limit: usize) void {
    const l = s.locate(stack_id);
    l.pool.ended(l.slot, limit);
}
pub inline fn give(s: *Stacks, stack_id: Stack) void {
    const l = s.locate(stack_id);
    l.pool.give(l.slot);
    if (s.pools.len > 0) _ = s.total_in_use.fetchSub(1, .release);
}
pub fn trim(s: *Stacks, stack_id: Stack, keep_from: usize) void {
    const l = s.locate(stack_id);
    l.pool.trim(l.slot, keep_from);
}

/// Diagnostic painting commits the stack before entry; it is opt-in and
/// disabled in ordinary runs. No live frame is ever painted.
pub fn paint(s: *Stacks, stack_id: Stack, until: usize) bool {
    const low = s.bottom(stack_id) + if (builtin.os.tag == .windows) memory.pageSize() else @as(usize, 0);
    if (!s.reach(stack_id, low)) return false;
    const bytes: [*]u8 = @ptrFromInt(low); // safe: exclusively owned, committed stack below its initial frame
    @memset(bytes[0 .. until - low], 0xa5);
    return true;
}

/// Called off-stack, before publishing a wake or an ended task. The
/// lowest changed byte measures deepest touched storage, including work
/// which returned before the next park.
pub fn highWater(s: *Stacks, stack_id: Stack) usize {
    const low = s.bottom(stack_id) + if (builtin.os.tag == .windows) memory.pageSize() else @as(usize, 0);
    const bytes: [*]const u8 = @ptrFromInt(low); // safe: the scheduler exclusively owns this suspended stack
    const size = s.top(stack_id) - low;
    for (bytes[0..size], 0..) |byte, at| if (byte != 0xa5) return size - at;
    return 0;
}
