//! Address space for task stacks: reserve, guard, commit, release, and give
//! pages back.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;

const is_windows = builtin.os.tag == .windows;

pub const page_size_min = std.heap.page_size_min;

pub fn pageSize() usize {
    return std.heap.pageSize();
}

pub const ReserveError = error{SystemResources};

/// `len` bytes of zeroed, readable and writable address space, committed
/// as it is touched (no swap reserved on Linux; Windows charges the commit
/// at once).
pub fn reserve(len: usize) ReserveError![]align(page_size_min) u8 {
    if (is_windows) return allocate(len, .{ .RESERVE = true, .COMMIT = true }, .{ .READWRITE = true });
    var flags: posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    if (builtin.os.tag == .linux and @hasField(posix.MAP, "NORESERVE")) flags.NORESERVE = true;
    return posix.mmap(null, len, .{ .READ = true, .WRITE = true }, flags, -1, 0) catch error.SystemResources;
}

/// `len` bytes of address space nothing may touch until `commit`ted
/// (Windows); elsewhere the same as `reserve`, whose pages need no commit.
pub fn reserveSpace(len: usize) ReserveError![]align(page_size_min) u8 {
    if (is_windows) return allocate(len, .{ .RESERVE = true }, .{ .NOACCESS = true });
    return reserve(len);
}

fn allocate(len: usize, kind: windows.MEM.ALLOCATE, protection: windows.PAGE) ReserveError![]align(page_size_min) u8 {
    var base: windows.PVOID = undefined;
    var size: windows.SIZE_T = len;
    switch (windows.ntdll.NtAllocateVirtualMemory(windows.current_process, &base, 0, &size, kind, protection)) {
        .SUCCESS => {},
        else => return error.SystemResources,
    }
    const start: [*]align(page_size_min) u8 = @ptrCast(@alignCast(base)); // safe: the system hands out whole pages
    return start[0..len];
}

pub fn release(memory: []align(page_size_min) u8) void {
    if (is_windows) {
        var base: windows.PVOID = memory.ptr;
        var size: windows.SIZE_T = 0;
        _ = windows.ntdll.NtFreeVirtualMemory(windows.current_process, &base, &size, .{ .RELEASE = true });
        return;
    }
    posix.munmap(memory);
}

/// Makes `memory` fault on any access: a guard page. On Linux this splits
/// the mapping, costing one more entry against `vm.max_map_count`.
pub fn protect(memory: []align(page_size_min) u8) error{SystemResources}!void {
    if (is_windows) return setProtection(memory, .{ .NOACCESS = true });
    switch (posix.errno(posix.system.mprotect(memory.ptr, memory.len, .{}))) {
        .SUCCESS => {},
        else => return error.SystemResources,
    }
}

fn setProtection(memory: []align(page_size_min) u8, protection: windows.PAGE) error{SystemResources}!void {
    var base: ?windows.PVOID = memory.ptr;
    var size: windows.SIZE_T = memory.len;
    var old: windows.PAGE = undefined;
    switch (windows.ntdll.NtProtectVirtualMemory(windows.current_process, &base, &size, protection, &old)) {
        .SUCCESS => {},
        else => return error.SystemResources,
    }
}

/// Windows: makes reserved `memory` usable; with `guard`, as a guard page,
/// which the system turns usable on first touch and which grows a thread's
/// stack by one page when it lies in that stack's bounds.
pub fn commit(memory: []align(page_size_min) u8, guard: bool) error{SystemResources}!void {
    if (!is_windows) return;
    var base: windows.PVOID = memory.ptr;
    var size: windows.SIZE_T = memory.len;
    switch (windows.ntdll.NtAllocateVirtualMemory(windows.current_process, &base, 0, &size, .{ .COMMIT = true }, .{ .READWRITE = true, .GUARD = guard })) {
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
/// or as whatever was there (elsewhere, until reused) afterwards. Windows
/// keeps them: its stacks grow by guard page, and a page given back below
/// the guard would never be committed again.
pub fn discard(memory: []align(page_size_min) u8) void {
    if (is_windows) return;
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
