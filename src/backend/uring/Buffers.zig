//! Sparse fixed-buffer slots. One contiguous pool occupies one slot;
//! READ_FIXED/WRITE_FIXED may use any subrange of that registered memory.
const Buffers = @This();
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const Slot = struct { base: usize = 0, length: usize = 0, users: u32 = 0 };
slots: []Slot,
enabled: bool,
registered: u16 = 0,
pub const Error = error{ Unsupported, SystemResources, Unexpected };

pub fn init(gpa: std.mem.Allocator, ring: *linux.IoUring, count: u16) std.mem.Allocator.Error!Buffers {
    const slots = try gpa.alloc(Slot, count);
    @memset(slots, .{});
    const reg: linux.io_uring_rsrc_register = .{ .nr = count, .flags = linux.IORING_RSRC_REGISTER_SPARSE, .resv2 = 0, .data = 0, .tags = 0 };
    const enabled = count > 0 and linux.errno(linux.io_uring_register(ring.fd, .REGISTER_BUFFERS2, &reg, @sizeOf(@TypeOf(reg)))) == .SUCCESS;
    return .{ .slots = slots, .enabled = enabled };
}

pub fn deinit(b: *Buffers, gpa: std.mem.Allocator) void {
    for (b.slots) |slot| {
        std.debug.assert(slot.base == 0);
        std.debug.assert(slot.users == 0);
    }
    gpa.free(b.slots);
    b.* = undefined;
}

pub fn register(b: *Buffers, ring: *linux.IoUring, memory: []u8) Error!u16 {
    if (!b.enabled) return error.Unsupported;
    const index = for (b.slots, 0..) |slot, i| {
        if (slot.base == 0) break i;
    } else return error.SystemResources;
    var buffer: posix.iovec = .{ .base = memory.ptr, .len = memory.len };
    try update(ring.fd, @intCast(index), &buffer);
    b.registered += 1;
    b.slots[index] = .{ .base = @intFromPtr(memory.ptr), .length = memory.len }; // safe: an address range only, owned by the pool
    return @intCast(index);
}

pub fn unregister(b: *Buffers, ring: *linux.IoUring, index: u16) void {
    std.debug.assert(b.slots[index].users == 0);
    const Empty = extern struct { base: ?[*]u8 = null, length: usize = 0 };
    var empty: Empty = .{};
    update(ring.fd, index, @ptrCast(&empty)) catch |err| std.debug.panic("reactor: unregistering a fixed buffer failed: {t}", .{err}); // safe: Empty has the iovec ABI, including its null base
    b.slots[index] = .{};
    b.registered -= 1;
}

fn update(fd: linux.fd_t, index: u16, buffer: *const posix.iovec) Error!void {
    const request: linux.io_uring_rsrc_update2 = .{ .offset = index, .resv = 0, .data = @intFromPtr(buffer), .tags = 0, .nr = 1, .resv2 = 0 }; // safe: register reads one iovec during this call
    return switch (linux.errno(linux.io_uring_register(fd, .REGISTER_BUFFERS_UPDATE, &request, @sizeOf(@TypeOf(request))))) {
        .SUCCESS => {},
        .NOMEM, .AGAIN, .BUSY => error.SystemResources,
        .INVAL, .NOSYS, .OPNOTSUPP => error.Unsupported,
        else => error.Unexpected,
    };
}

pub fn use(b: *Buffers, sqe: *linux.io_uring_sqe) ?u16 {
    if (!b.enabled or b.registered == 0 or (sqe.opcode != .READ and sqe.opcode != .WRITE)) return null;
    for (b.slots, 0..) |*slot, i| {
        if (slot.base == 0 or sqe.addr < slot.base) continue;
        const offset = sqe.addr - slot.base;
        if (offset > slot.length or sqe.len > slot.length - offset) continue;
        sqe.opcode = if (sqe.opcode == .READ) .READ_FIXED else .WRITE_FIXED;
        sqe.buf_index = @intCast(i);
        slot.users += 1;
        return @intCast(i);
    }
    return null;
}

pub fn release(b: *Buffers, index: u16) void {
    std.debug.assert(b.slots[index].users > 0);
    b.slots[index].users -= 1;
}
