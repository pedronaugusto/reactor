//! Crash output bypasses Io scheduling, allocation and stderr locks.
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

extern "kernel32" fn WriteFile(handle: windows.HANDLE, buffer: [*]const u8, length: windows.DWORD, written: *windows.DWORD, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;

pub fn write(bytes: []const u8) void {
    if (builtin.os.tag == .windows) {
        var written: windows.DWORD = 0;
        _ = WriteFile(std.Io.File.stderr().handle, bytes.ptr, @intCast(bytes.len), &written, null);
        return;
    }
    var left = bytes;
    while (left.len != 0) {
        const result = std.posix.system.write(std.posix.STDERR_FILENO, left.ptr, left.len);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return;
                left = left[@intCast(result)..];
            },
            .INTR => continue,
            else => return,
        }
    }
}
