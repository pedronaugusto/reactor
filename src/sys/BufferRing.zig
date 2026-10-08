//! Kernel-owned provided buffer rings avoid user-page pinning restrictions.
const BufferRing = @This();
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

br: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
entries: u16,
id: u16,
fd: linux.fd_t,

pub const Error = error{ Unsupported, SystemResources, Unexpected };

pub fn init(fd: linux.fd_t, entries: u16, id: u16) Error!BufferRing {
    const reg: linux.io_uring_buf_reg = .{
        .ring_addr = 0,
        .ring_entries = entries,
        .bgid = id,
        .flags = .{ ._0 = 1, .inc = false },
        .resv = @splat(0),
    };
    switch (linux.errno(linux.io_uring_register(fd, .REGISTER_PBUF_RING, &reg, 1))) {
        .SUCCESS => {},
        .INVAL => {
            const br = linux.IoUring.setup_buf_ring(fd, entries, id, .{ .inc = false }) catch return error.Unsupported;
            return .{ .br = br, .entries = entries, .id = id, .fd = fd };
        },
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    errdefer unregister(fd, id);
    const bytes = @as(usize, entries) * @sizeOf(linux.io_uring_buf);
    const offset: u64 = 0x80000000 | (@as(u64, id) << 16);
    const memory = posix.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, offset) catch return error.SystemResources;
    return .{ .br = @ptrCast(memory.ptr), .entries = entries, .id = id, .fd = fd }; // safe: the kernel maps an array of io_uring_buf entries here
}

pub fn deinit(ring: *BufferRing) void {
    unregister(ring.fd, ring.id);
    const memory: [*]align(std.heap.page_size_min) u8 = @ptrCast(ring.br); // safe: init mapped this buffer ring
    posix.munmap(memory[0 .. @as(usize, ring.entries) * @sizeOf(linux.io_uring_buf)]);
    ring.* = undefined;
}

fn unregister(fd: linux.fd_t, id: u16) void {
    const reg: linux.io_uring_buf_reg = .{ .ring_addr = 0, .ring_entries = 0, .bgid = id, .flags = .{ .inc = false }, .resv = @splat(0) };
    _ = linux.io_uring_register(fd, .UNREGISTER_PBUF_RING, &reg, 1);
}
