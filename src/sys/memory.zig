//! Address space for task stacks: reserve, guard, release, and give pages
//! back. POSIX only until Windows has fibers.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

pub const page_size_min = std.heap.page_size_min;

pub fn pageSize() usize {
    return std.heap.pageSize();
}

pub const ReserveError = error{SystemResources};

/// `len` bytes of zeroed, readable and writable address space, committed
/// as it is touched (no swap reserved on Linux).
pub fn reserve(len: usize) ReserveError![]align(page_size_min) u8 {
    var flags: posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    if (builtin.os.tag == .linux) flags.NORESERVE = true;
    return posix.mmap(null, len, .{ .READ = true, .WRITE = true }, flags, -1, 0) catch error.SystemResources;
}

pub fn release(memory: []align(page_size_min) u8) void {
    posix.munmap(memory);
}

/// Makes `memory` fault on any access: a guard page. On Linux this splits
/// the mapping, costing one more entry against `vm.max_map_count`.
pub fn protect(memory: []align(page_size_min) u8) error{SystemResources}!void {
    switch (posix.errno(posix.system.mprotect(memory.ptr, memory.len, .{}))) {
        .SUCCESS => {},
        else => return error.SystemResources,
    }
}

/// Linux 6.13+: a guard region that faults like a guard page without
/// splitting the mapping. False where the kernel lacks it.
pub fn installGuard(memory: []align(page_size_min) u8) bool {
    if (builtin.os.tag != .linux) return false;
    const madv_guard_install = 102;
    return std.os.linux.errno(std.os.linux.madvise(memory.ptr, memory.len, madv_guard_install)) == .SUCCESS;
}

/// Gives `memory`'s pages back to the system; they read as zero (Linux)
/// or as whatever was there (elsewhere, until reused) afterwards.
pub fn discard(memory: []align(page_size_min) u8) void {
    const advice: u32 = if (builtin.os.tag == .linux) std.os.linux.MADV.DONTNEED else posix.MADV.FREE;
    // Pages not given back stay usable: nothing to report.
    posix.madvise(memory.ptr, memory.len, advice) catch return;
}

/// Linux: the most mappings a process may hold (`vm.max_map_count`), or
/// null when it cannot be read.
pub fn maxMapCount() ?u64 {
    if (builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    const rc = linux.open("/proc/sys/vm/max_map_count", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buffer: [32]u8 = undefined;
    const n = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(n) != .SUCCESS) return null;
    const text = std.mem.trim(u8, buffer[0..n], " \n");
    return std.fmt.parseInt(u64, text, 10) catch null;
}
