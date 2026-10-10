//! Kernel-owned provided buffer rings avoid user-page pinning restrictions.
const BufferRing = @This();
const std = @import("std");
const aegis = @import("aegis");
const posix = std.posix;
const linux = std.os.linux;

br: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
entries: Entries,
id: Id,
fd: linux.fd_t,

/// A provided-buffer group of one ring: the number a receive names to take its buffer from.
pub const Id = aegis.id.Id(struct {}, u16);
/// How many buffers a group's ring holds.
pub const Entries = aegis.units.Count(struct {}, u16);

pub const Error = error{ Unsupported, SystemResources, Unexpected };

pub fn init(fd: linux.fd_t, entries: Entries, id: Id) Error!BufferRing {
    const reg: linux.io_uring_buf_reg = .{
        .ring_addr = 0,
        .ring_entries = entries.raw(), // c-os-boundary: the kernel's registration record
        .bgid = id.raw(), // c-os-boundary: the kernel's registration record
        .flags = .{ ._0 = 1, .inc = false },
        .resv = @splat(0),
    };
    switch (linux.errno(linux.io_uring_register(fd, .REGISTER_PBUF_RING, &reg, 1))) {
        .SUCCESS => {},
        .INVAL => {
            const br = linux.IoUring.setup_buf_ring(fd, entries.raw(), id.raw(), .{ .inc = false }) catch return error.Unsupported; // c-os-boundary: std's wrapper of the kernel call
            return .{ .br = br, .entries = entries, .id = id, .fd = fd };
        },
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    errdefer unregister(fd, id);
    const bytes = ringBytes(entries);
    // glint-ignore: A004 -- c-os-boundary: docs/design.md#safety-types; the mmap offset that names the group
    const offset: u64 = 0x80000000 | (@as(u64, id.raw()) << 16);
    const memory = posix.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, offset) catch return error.SystemResources;
    return .{ .br = @ptrCast(memory.ptr), .entries = entries, .id = id, .fd = fd }; // safe: the kernel maps an array of io_uring_buf entries here
}

pub fn deinit(ring: *BufferRing) void {
    unregister(ring.fd, ring.id);
    const memory: [*]align(std.heap.page_size_min) u8 = @ptrCast(ring.br); // safe: init mapped this buffer ring
    posix.munmap(memory[0..ringBytes(ring.entries)]);
    ring.* = undefined;
}

/// The bytes of the shared array that holds `entries` buffer descriptions.
fn ringBytes(entries: Entries) usize {
    return @as(usize, entries.raw()) * @sizeOf(linux.io_uring_buf); // safe: 65,535 entries of 16 bytes
}

fn unregister(fd: linux.fd_t, id: Id) void {
    const reg: linux.io_uring_buf_reg = .{
        .ring_addr = 0,
        .ring_entries = 0,
        .bgid = id.raw(), // c-os-boundary: the kernel's registration record
        .flags = .{ .inc = false },
        .resv = @splat(0),
    };
    _ = linux.io_uring_register(fd, .UNREGISTER_PBUF_RING, &reg, 1);
}
