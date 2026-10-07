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
//! Free stacks are a lock-free stack of indices (with a tag against ABA),
//! last freed first reused, so the stacks in use stay the warm ones.
const Stacks = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const memory = @import("../sys/memory.zig");

pub const per_slab = 64;

pub const Options = struct {
    count: u32,
    /// Usable bytes per stack, rounded up to whole pages.
    size: usize,
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

pub fn init(s: *Stacks, gpa: Allocator, options: Options) InitError!void {
    const page = memory.pageSize();
    const size = std.mem.alignForward(usize, @max(options.size, 4 * page), page);
    const slab_count = (options.count + per_slab - 1) / per_slab;
    const regions = guardRegionsWork(page);
    if (!regions) try checkMapCount(options.count, slab_count);
    s.* = .{
        .size = size,
        .stride = size + page,
        .regions = regions,
        .slabs = try gpa.alloc([]align(memory.page_size_min) u8, slab_count),
        .links = undefined,
        .free = .init(0),
        .count = options.count,
    };
    errdefer gpa.free(s.slabs);
    s.links = try gpa.alloc(u32, options.count);
    errdefer gpa.free(s.links);

    var made: usize = 0;
    errdefer for (s.slabs[0..made]) |slab| memory.release(slab);
    while (made < slab_count) : (made += 1) {
        const in_slab = @min(per_slab, options.count - made * per_slab);
        const slab = try memory.reserve(in_slab * s.stride);
        s.slabs[made] = slab;
        errdefer memory.release(slab);
        for (0..in_slab) |i| {
            const below: []align(memory.page_size_min) u8 = @alignCast(slab[i * s.stride ..][0..page]); // safe: the stride is whole pages
            try guard(below, regions);
        }
    }
    // Every stack free, index 0 first out.
    var i = options.count;
    while (i > 0) {
        i -= 1;
        s.push(i);
    }
}

pub fn deinit(s: *Stacks, gpa: Allocator) void {
    for (s.slabs) |slab| memory.release(slab);
    gpa.free(s.slabs);
    gpa.free(s.links);
    s.* = undefined;
}

/// A free stack's index, or null when every stack is in use.
pub fn take(s: *Stacks) ?u32 {
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
        _ = s.in_use.fetchAdd(1, .monotonic);
        return index;
    }
}

/// Returns a stack no task runs on any more.
pub fn give(s: *Stacks, index: u32) void {
    _ = s.in_use.fetchSub(1, .monotonic);
    s.push(index);
}

fn push(s: *Stacks, index: u32) void {
    var raw = s.free.load(.monotonic);
    while (true) {
        const f: Free = @bitCast(raw);
        @atomicStore(u32, &s.links[index], f.index_plus_one, .monotonic);
        const next: Free = .{ .index_plus_one = index + 1, .tag = f.tag +% 1 };
        raw = s.free.cmpxchgWeak(raw, @bitCast(next), .release, .monotonic) orelse return;
    }
}

/// One past the highest usable byte of stack `index`; 16-aligned.
pub fn top(s: *const Stacks, index: u32) usize {
    return s.bottom(index) + s.size;
}

/// The lowest usable byte of stack `index`, just above its guard.
pub fn bottom(s: *const Stacks, index: u32) usize {
    const slab = s.slabs[index / per_slab];
    return @intFromPtr(slab.ptr) + (index % per_slab) * s.stride + memory.pageSize(); // safe: an address, for laying out the stack
}

/// Gives the pages of stack `index` below `keep_from` back to the system.
pub fn trim(s: *const Stacks, index: u32, keep_from: usize) void {
    const page = memory.pageSize();
    const low = s.bottom(index);
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
