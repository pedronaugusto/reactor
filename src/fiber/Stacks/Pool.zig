//! The stacks of a runtime's tasks, all reserved at `init` in slabs of 64
//! per mapping, handed out and taken back without allocating.
//!
//! What a stack costs is the pages a task touches: the reservation is
//! address space. Every stack has a guard below it: a guard region where
//! the kernel has them (Linux 6.13+, which costs no mapping), a guard page
//! elsewhere. A guard page on Linux splits its slab's mapping, two entries
//! per stack against `vm.max_map_count`, so `init` refuses a count that
//! would reach the limit rather than fail later. One guard per slab is not
//! enough: Zig emits no stack probes on aarch64, nor on x86_64 in
//! ReleaseFast, so a large frame would step over a shared guard into the
//! next stack unseen.
//!
//! On Windows a stack is reserved address space whose top pages are
//! committed when it is first handed out, with a guard page below them:
//! the system commits one more page each time the task touches the guard,
//! as it grows a thread's own stack, because the switch keeps the thread
//! information block's bounds on the running stack. The page below each
//! stack stays reserved and uncommitted: a fault, never grown into.
//!
//! Free stacks are a lock-free stack of indices (with a tag against ABA),
//! last freed first reused, so the stacks in use stay the warm ones.
const Pool = @This();

const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Bytes = aegis.units.Bytes(usize);
const memory = @import("../../sys/memory.zig");
const fiber = @import("../../fiber.zig");

const is_windows = builtin.os.tag == .windows;

/// Windows: what is committed of a stack when it is first handed out.
const initial_commit = 2 * 4096;

pub const per_slab = 64;

/// A stack's place in this pool. `Stacks` numbers stacks across every pool
/// with its own `Stack`; the two do not mix.
pub const Slot = aegis.id.Id(struct {}, u32);

pub const Options = struct {
    count: u32,
    /// Usable bytes per stack, rounded up to whole pages.
    size: aegis.units.Bytes(usize),
};

pub const InitError = error{ SystemResources, TooManyTasks } || Allocator.Error;

const Free = packed struct(u64) { index_plus_one: u32, tag: u32 };

size: usize,
/// A stack and the guard below it.
stride: usize,
/// Whether guards are guard regions, which never split a mapping.
regions: bool,
slabs: [][]align(memory.page_size_min) u8,
links: []u32,
free: std.atomic.Value(u64),
count: u32,
in_use: std.atomic.Value(u32) = .init(0),
/// Windows: per stack, the lowest committed byte, 0 until first handed
/// out. Only the stack's holder touches its entry.
limits: if (is_windows) []usize else void = if (is_windows) &.{} else {},

pub fn init(s: *Pool, gpa: Allocator, options: Options) InitError!void {
    const page = memory.pageSize();
    // The size is the caller's: one past the address space cannot be reserved, so it is
    // refused before it is rounded, and the stride and every slab are sized with checks.
    const wanted = @max(options.size.raw(), 4 * page);
    const size = std.mem.alignBackward(usize, std.math.add(usize, wanted, page - 1) catch return error.SystemResources, page);
    const with_guard = Bytes.fromRaw(size).add(Bytes.fromRaw(page)) catch return error.SystemResources;
    const slab_count = std.math.divCeil(usize, options.count, per_slab) catch unreachable; // unreachable: the divisor is a nonzero constant
    const regions = guardRegionsWork(page);
    if (!regions and !is_windows) try checkMapCount(options.count, slab_count);
    s.* = .{
        .size = size,
        .stride = with_guard.raw(),
        .regions = regions,
        .slabs = try gpa.alloc([]align(memory.page_size_min) u8, slab_count),
        .links = undefined,
        .free = .init(0),
        .count = options.count,
    };
    errdefer gpa.free(s.slabs);
    s.links = try gpa.alloc(u32, options.count);
    errdefer gpa.free(s.links);
    if (is_windows) {
        s.limits = try gpa.alloc(usize, options.count);
        @memset(s.limits, 0);
    }
    errdefer if (is_windows) gpa.free(s.limits);

    var made: usize = 0;
    errdefer for (s.slabs[0..made]) |slab| memory.release(slab);
    while (made < slab_count) : (made += 1) {
        const in_slab: usize = @min(per_slab, options.count - made * per_slab);
        const slab_bytes = with_guard.mul(in_slab) catch return error.SystemResources;
        const slab = try memory.reserveSpace(slab_bytes.raw());
        s.slabs[made] = slab;
        errdefer memory.release(slab);
        // Windows: the page below each stack is never committed.
        if (!is_windows) for (0..in_slab) |i| {
            const below: []align(memory.page_size_min) u8 = @alignCast(slab[i * s.stride ..][0..page]); // safe: the stride is whole pages
            try guard(below, regions);
        };
    }
    // Every stack free, index 0 first out.
    var i = options.count;
    while (i > 0) {
        i -= 1;
        s.push(.fromRaw(i));
    }
}

pub fn deinit(s: *Pool, gpa: Allocator) void {
    for (s.slabs) |slab| memory.release(slab);
    gpa.free(s.slabs);
    gpa.free(s.links);
    if (is_windows) gpa.free(s.limits);
    s.* = undefined;
}

/// A free stack's slot, or null when every stack is in use.
pub inline fn take(s: *Pool) ?Slot {
    var raw = s.free.load(.acquire);
    while (true) {
        const f: Free = @bitCast(raw);
        if (f.index_plus_one == 0) return null;
        const index = f.index_plus_one - 1;
        const next: Free = .{ .index_plus_one = @atomicLoad(u32, &s.links[index], .monotonic), .tag = f.tag +% 1 };
        if (s.free.cmpxchgWeak(raw, @bitCast(next), .acq_rel, .acquire)) |actual| {
            raw = actual;
            continue;
        }
        const slot: Slot = .fromRaw(index);
        if (is_windows and s.limits[index] == 0) s.prepare(slot) catch {
            s.push(slot);
            return null;
        };
        _ = s.in_use.fetchAdd(1, .monotonic);
        return slot;
    }
}

/// Windows: commits a stack's top pages and the guard below them, the
/// first time it is handed out.
fn prepare(s: *Pool, slot: Slot) error{SystemResources}!void {
    const page = (s.stride - s.size);
    const low = s.top(slot) - initial_commit;
    try memory.commit(pages(low - page, low), true);
    try memory.commit(pages(low, s.top(slot)), false);
    s.limits[slot.raw()] = low;
}

fn pages(from: usize, to: usize) []align(memory.page_size_min) u8 {
    const start: [*]align(memory.page_size_min) u8 = @ptrFromInt(from);
    return start[0 .. to - from];
}

/// The stack `slot` as a context starts on it.
pub inline fn stack(s: *const Pool, slot: Slot) fiber.Stack {
    return .{
        .top = s.top(slot),
        .limit = if (is_windows) s.limits[slot.raw()] else s.bottom(slot),
        .bottom = s.bottom(slot) - (s.stride - s.size),
    };
}

/// Makes stack `slot` usable down to `low` before anything but its own
/// task writes there (the task's record and its copied context, written by
/// the thread creating it): Windows grows a stack only for the thread
/// running on it. False when `low` is past what the stack can commit.
pub inline fn reach(s: *Pool, slot: Slot, low: usize) bool {
    if (!is_windows) return true;
    const page = (s.stride - s.size);
    const limit = s.limits[slot.raw()];
    const want = std.mem.alignBackward(usize, low, page);
    if (want >= limit) return true;
    if (want - page < s.bottom(slot)) return false;
    memory.commit(pages(want, limit), false) catch return false;
    memory.commit(pages(want - page, want), true) catch return false;
    s.limits[slot.raw()] = want;
    return true;
}

/// Windows: a task on stack `slot` ended with the stack committed down to
/// `limit`; the next task there starts with that much.
pub inline fn ended(s: *Pool, slot: Slot, limit: usize) void {
    if (!is_windows) return;
    s.limits[slot.raw()] = @min(s.limits[slot.raw()], limit);
}

/// Returns a stack no task runs on any more.
pub inline fn give(s: *Pool, slot: Slot) void {
    s.push(slot);
    // Zero publishes the last release after it stopped touching this pool.
    _ = s.in_use.fetchSub(1, .release);
}

fn push(s: *Pool, slot: Slot) void {
    const index = slot.raw();
    var raw = s.free.load(.monotonic);
    while (true) {
        const f: Free = @bitCast(raw);
        @atomicStore(u32, &s.links[index], f.index_plus_one, .monotonic);
        const next: Free = .{ .index_plus_one = index + 1, .tag = f.tag +% 1 };
        raw = s.free.cmpxchgWeak(raw, @bitCast(next), .release, .monotonic) orelse return;
    }
}

/// One past the highest usable byte of stack `slot`; 16-aligned.
pub inline fn top(s: *const Pool, slot: Slot) usize {
    return s.bottom(slot) + s.size;
}

/// The lowest usable byte of stack `slot`, just above its guard.
pub inline fn bottom(s: *const Pool, slot: Slot) usize {
    const index = slot.raw();
    const slab = s.slabs[index / per_slab];
    return @intFromPtr(slab.ptr) + (index % per_slab) * s.stride + (s.stride - s.size); // safe: an address, for laying out the stack
}

/// Gives the pages of stack `slot` below `keep_from` back to the system.
pub fn trim(s: *const Pool, slot: Slot, keep_from: usize) void {
    const page = (s.stride - s.size);
    const low = s.bottom(slot);
    const high = std.mem.alignBackward(usize, keep_from, page);
    if (high <= low) return;
    const start: [*]align(memory.page_size_min) u8 = @ptrFromInt(low);
    memory.discard(start[0 .. high - low]);
}

fn guard(page: []align(memory.page_size_min) u8, regions: bool) !void {
    if (regions and memory.installGuard(page)) return;
    try memory.protect(page);
}

/// Whether this kernel has guard regions: one page tried and released.
fn guardRegionsWork(page: usize) bool {
    if (builtin.os.tag != .linux) return false;
    const probe = memory.reserve(page) catch return false;
    defer memory.release(probe);
    return memory.installGuard(probe);
}

/// A guard page splits its stack's mapping off the slab: two mappings per
/// stack. Refuse at `init` a count that would hit `vm.max_map_count`.
fn checkMapCount(count: u32, slabs: usize) error{TooManyTasks}!void {
    const limit = memory.maxMapCount() orelse return;
    const headroom = 4096;
    const needed = 2 * @as(u64, count) + slabs + headroom;
    if (needed > limit) return error.TooManyTasks;
}
