//! An allocator of fixed-size slots, all reserved at `init`: what a lane's
//! `Io.Threaded` allocates its per-call closures from, so a call allocates
//! nothing from the runtime's allocator. A request larger than a slot, or
//! any once every slot is taken, fails as out of memory, which the lane
//! turns into a queued call.
const SlotPool = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const slot_len = 256;
pub const slot_alignment: Alignment = .@"16";

const Free = packed struct(u64) { index_plus_one: u32, tag: u32 };

buffer: []align(slot_alignment.toByteUnits()) u8,
links: []u32,
head: std.atomic.Value(u64) = .init(0),

pub fn init(gpa: Allocator, count: u32) Allocator.Error!SlotPool {
    const buffer = try gpa.alignedAlloc(u8, slot_alignment, @as(usize, count) * slot_len);
    errdefer gpa.free(buffer);
    var p: SlotPool = .{ .buffer = buffer, .links = try gpa.alloc(u32, count) };
    var i = count;
    while (i > 0) {
        i -= 1;
        p.push(i);
    }
    return p;
}

pub fn deinit(p: *SlotPool, gpa: Allocator) void {
    gpa.free(p.buffer);
    gpa.free(p.links);
    p.* = undefined;
}

pub fn allocator(p: *SlotPool) Allocator {
    return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const p: *SlotPool = @ptrCast(@alignCast(context)); // safe: `allocator` passed the pool
    if (len > slot_len or alignment.compare(.gt, slot_alignment)) return null;
    const index = p.pop() orelse return null;
    return p.buffer.ptr + @as(usize, index) * slot_len;
}

fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const p: *SlotPool = @ptrCast(@alignCast(context)); // safe: `allocator` passed the pool
    const offset = @intFromPtr(memory.ptr) - @intFromPtr(p.buffer.ptr); // safe: addresses inside the pool's buffer
    p.push(@intCast(offset / slot_len));
}

fn pop(p: *SlotPool) ?u32 {
    var raw = p.head.load(.acquire);
    while (true) {
        const f: Free = @bitCast(raw);
        if (f.index_plus_one == 0) return null;
        const index = f.index_plus_one - 1;
        const next: Free = .{ .index_plus_one = @atomicLoad(u32, &p.links[index], .monotonic), .tag = f.tag +% 1 };
        raw = p.head.cmpxchgWeak(raw, @bitCast(next), .acq_rel, .acquire) orelse return index;
    }
}

fn push(p: *SlotPool, index: u32) void {
    var raw = p.head.load(.monotonic);
    while (true) {
        const f: Free = @bitCast(raw);
        @atomicStore(u32, &p.links[index], f.index_plus_one, .monotonic);
        const next: Free = .{ .index_plus_one = index + 1, .tag = f.tag +% 1 };
        raw = p.head.cmpxchgWeak(raw, @bitCast(next), .release, .monotonic) orelse return;
    }
}
