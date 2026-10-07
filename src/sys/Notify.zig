//! A kernel object any thread can set, which stays set until it is
//! cleared: an eventfd on Linux, a non-blocking pipe on the other POSIX
//! systems, a manual-reset event on Windows. A wait on descriptors or
//! handles can include it beside the others. `set` makes one system call
//! and takes no lock, so a signal handler may call it.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const windows = std.os.windows;
const win32 = @import("win32.zig");

const os = builtin.os.tag;

/// Waited on: readable (POSIX) or signaled (Windows) while set.
handle: Io.File.Handle,
/// Written to set it: the pipe's write end, else `handle` itself.
set_end: Io.File.Handle,

const Notify = @This();

pub const OpenError = error{ SystemResources, Unexpected };

pub fn open() OpenError!Notify {
    switch (os) {
        .windows => {
            const event = win32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.SystemResources;
            return .{ .handle = event, .set_end = event };
        },
        .linux => {
            const linux = std.os.linux;
            const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            return switch (linux.errno(rc)) {
                .SUCCESS => .{ .handle = @intCast(rc), .set_end = @intCast(rc) },
                .MFILE, .NFILE, .NOMEM, .NODEV => error.SystemResources,
                else => |e| posix.unexpectedErrno(e),
            };
        },
        else => {
            const ends = Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true }) catch |err| return switch (err) {
                error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => error.SystemResources,
                error.Unexpected => error.Unexpected,
            };
            return .{ .handle = ends[0], .set_end = ends[1] };
        },
    }
}

pub fn close(n: Notify) void {
    switch (os) {
        .windows => windows.CloseHandle(n.handle),
        else => {
            _ = posix.system.close(n.handle);
            if (n.set_end != n.handle) _ = posix.system.close(n.set_end);
        },
    }
}

/// From any thread, or a signal handler: it stays set until `clear`.
pub fn set(n: Notify) void {
    switch (os) {
        .windows => _ = win32.SetEvent(n.set_end),
        .linux => {
            const one: u64 = 1;
            // A full counter is still readable: nothing is lost.
            _ = std.os.linux.write(n.set_end, @ptrCast(&one), 8); // safe: eight bytes, as an eventfd is written
        },
        else => {
            const byte: u8 = 1;
            // A full pipe is still readable: nothing is lost.
            _ = posix.system.write(n.set_end, @ptrCast(&byte), 1); // safe: one byte
        },
    }
}

/// Clears it: a wait that follows waits again.
pub fn clear(n: Notify) void {
    switch (os) {
        .windows => _ = win32.ResetEvent(n.handle),
        .linux => {
            var count: u64 = 0;
            _ = std.os.linux.read(n.handle, @ptrCast(&count), 8); // safe: eight bytes, as an eventfd reads
        },
        else => {
            var bytes: [64]u8 = undefined;
            while (posix.system.read(n.handle, &bytes, bytes.len) == bytes.len) {}
        },
    }
}

/// Whether it is set, without waiting or clearing it.
pub fn isSet(n: Notify) bool {
    switch (os) {
        .windows => return win32.WaitForSingleObject(n.handle, 0) == win32.wait_object_0,
        else => {
            var fds = [1]posix.pollfd{.{ .fd = n.handle, .events = posix.POLL.IN, .revents = 0 }};
            return (posix.poll(&fds, 0) catch 0) > 0;
        },
    }
}
