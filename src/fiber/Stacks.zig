//! The stacks of a runtime's tasks, all reserved at `init` in slabs of 64
//! per mapping, handed out and taken back without allocating.
//!
//! What a stack costs is the pages a task touches: the reservation is
//! address space. Guards cost no mapping where the system allows it (Linux
//! 6.13+ guard regions, guard pages elsewhere but Linux); older Linux keeps
//! one guard page per slab and a canary at the bottom of every stack,
//! checked at every switch away from it, so that 64 stacks cost one entry
//! against `vm.max_map_count` instead of 128.
//!
//! Free stacks are a lock-free stack of indices (with a tag against ABA),
//! last freed first reused, so the stacks in use stay the warm ones.
const Stacks = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const memory = @import("../sys/memory.zig");

pub const per_slab = 64;

pub const Guard = enum {
    /// A guard below each stack: Linux 6.13+ guard regions, guard pages
    /// elsewhere but older Linux.
    per_stack,
    /// One guard page per slab and a canary per stack.
    per_slab,
};

pub const Options = struct {
    count: u32,
    /// Usable bytes per stack, rounded up to whole pages.
    size: usize,
    /// null: `per_stack` where it costs no mapping, else `per_slab`.
    guard: ?Guard = null,
};

pub const InitError = error{ SystemResources, TooManyTasks } || Allocator.Error;

const canary: u64 = 0x5eac_70c4_57ac_c0de;

const Free = packed struct(u64) { index_plus_one: u32, tag: u32 };

size: usize,
stride: usize,
guard: Guard,
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
    s.* = .{
        .size = size,
        .stride = size,
        .guard = .per_slab,
        .regions = false,
        .slabs = try gpa.alloc([]align(memory.page_size_min) u8, slab_count),
        .links = undefined,
        .free = .init(0),
        .count = options.count,
    };
    errdefer gpa.free(s.slabs);
    s.links = try gpa.alloc(u32, options.count);
    errdefer gpa.free(s.links);

    const regions = guardRegionsWork(page);
    s.regions = regions;
    s.guard = options.guard orelse if (regions or builtin.os.tag != .linux) .per_stack else .per_slab;
    if (s.guard == .per_stack) s.stride = size + page;
    if (s.guard == .per_stack and !regions) try checkMapCount(options.count, slab_count);

    var made: usize = 0;
    errdefer for (s.slabs[0..made]) |slab| memory.release(slab);
    while (made < slab_count) : (made += 1) {
        const in_slab = @min(per_slab, options.count - made * per_slab);
        const len = in_slab * s.stride + @as(usize, if (s.guard == .per_slab) page else 0);
        const slab = try memory.reserve(len);
        s.slabs[made] = slab;
        errdefer memory.release(slab);
        try s.guardSlab(slab, in_slab, page);
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
        if (s.guard == .per_slab) s.bottomWord(index).* = canary;
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

/// The lowest usable byte of stack `index`.
pub fn bottom(s: *const Stacks, index: u32) usize {
    const page = memory.pageSize();
    const slab = s.slabs[index / per_slab];
    const at = index % per_slab;
    // per_slab: the slab's guard, then the stacks; per_stack: each stack
    // after its own guard. Either way a page precedes stack 0.
    return @intFromPtr(slab.ptr) + page + at * s.stride; // safe: an address, for laying out the stack
}

/// False when a task has written below its stack (per-slab guards only;
/// a per-stack guard faults instead).
pub fn intact(s: *const Stacks, index: u32) bool {
    if (s.guard != .per_slab) return true;
    return s.bottomWord(index).* == canary;
}

/// Gives the pages of stack `index` below `keep_from` back to the system.
pub fn trim(s: *const Stacks, index: u32, keep_from: usize) void {
    const page = memory.pageSize();
    // Keep the canary's page: it is written once per take.
    const low = s.bottom(index) + @as(usize, if (s.guard == .per_slab) page else 0);
    const high = std.mem.alignBackward(usize, keep_from, page);
    if (high <= low) return;
    const start: [*]align(memory.page_size_min) u8 = @ptrFromInt(low);
    memory.discard(start[0 .. high - low]);
}

fn bottomWord(s: *const Stacks, index: u32) *u64 {
    return @ptrFromInt(s.bottom(index));
}

fn guardSlab(s: *Stacks, slab: []align(memory.page_size_min) u8, in_slab: usize, page: usize) !void {
    if (s.guard == .per_slab) return guardPage(slab[0..page], s.regions);
    for (0..in_slab) |i| {
        const at = i * s.stride;
        const guard: []align(memory.page_size_min) u8 = @alignCast(slab[at .. at + page]); // safe: stride is whole pages
        try guardPage(guard, s.regions);
    }
}

fn guardPage(page: []align(memory.page_size_min) u8, regions: bool) !void {
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

/// A guard page per stack splits every stack's mapping in two: refuse at
/// `init` a count that would hit the limit later as `ENOMEM`.
fn checkMapCount(count: u32, slabs: usize) error{TooManyTasks}!void {
    const limit = memory.maxMapCount() orelse return;
    const headroom = 4096;
    const needed = 2 * @as(u64, count) + slabs + headroom;
    if (needed > limit) return error.TooManyTasks;
}
