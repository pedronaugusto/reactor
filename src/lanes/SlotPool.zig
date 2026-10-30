//! An allocator of fixed-size slots, all reserved at `init`: what a lane's
//! `Io.Threaded` allocates its per-call closures from, so a call allocates
//! nothing from the runtime's allocator. A request larger than a slot, or
//! any once every slot is taken, fails as out of memory, which the lane
//! turns into a queued call.
const SlotPool = @This();

const std = @import("std");
const aegis = @import("aegis");
const FreeList = @import("../sync/FreeList.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const slot_len = 256;
pub const slot_alignment: Alignment = .@"16";

buffer: []align(slot_alignment.toByteUnits()) u8,
links: []aegis.Atomic(FreeList.Link),
size: usize,
free_slots: FreeList = .{},

pub fn init(gpa: Allocator, count: u32) Allocator.Error!SlotPool {
    return initSized(gpa, count, slot_len);
}

/// A pool with a caller-chosen fixed block size, for std calls with scratch arenas.
pub fn initSized(gpa: Allocator, count: u32, size: usize) Allocator.Error!SlotPool {
    std.debug.assert(size >= slot_len);
    std.debug.assert(size % slot_alignment.toByteUnits() == 0);
    const buffer = try gpa.alignedAlloc(u8, slot_alignment, @as(usize, count) * size);
    errdefer gpa.free(buffer);
    var p: SlotPool = .{ .buffer = buffer, .links = try gpa.alloc(aegis.Atomic(FreeList.Link), count), .size = size };
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
    // aegis: boundary(A019): std.mem.Allocator's vtable hands back as `*anyopaque` the pool `allocator` gave it
    const p: *SlotPool = @ptrCast(@alignCast(context));
    if (len > p.size or alignment.compare(.gt, slot_alignment)) return null;
    const index = p.pop() orelse return null;
    return p.buffer.ptr + @as(usize, index) * p.size;
}

fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    // aegis: boundary(A019): std.mem.Allocator's vtable hands back as `*anyopaque` the pool `allocator` gave it
    const p: *SlotPool = @ptrCast(@alignCast(context));
    const offset = @intFromPtr(memory.ptr) - @intFromPtr(p.buffer.ptr); // safe: addresses inside the pool's buffer
    p.push(@intCast(offset / p.size));
}

fn pop(p: *SlotPool) ?u32 {
    return p.free_slots.pop(p.links);
}

fn push(p: *SlotPool, index: u32) void {
    p.free_slots.push(p.links, index);
}
