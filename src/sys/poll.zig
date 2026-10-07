//! Readiness of several descriptors (`poll`) or Windows objects
//! (`WaitForMultipleObjects`), waited for on the calling thread for at most
//! a given time: what the extensions' waits fall back to on an `Io` that is
//! not a runtime.
const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const win32 = @import("win32.zig");

/// The most members one wait takes.
pub const max = 64;

pub const Interest = enum { readable, writable };

pub const Entry = struct { handle: Io.File.Handle, interest: Interest };

pub const Error = error{ SystemResources, Unexpected };

/// The lowest index of an entry ready within `ms` milliseconds; null when
/// none was. An error or a hang-up counts as ready: a read or write then
/// reports it. A signal ends the wait early, as a timeout.
pub fn descriptors(entries: []const Entry, ms: u32) Error!?usize {
    std.debug.assert(entries.len <= max);
    var fds: [max]posix.pollfd = undefined;
    for (entries, fds[0..entries.len]) |e, *f| f.* = .{
        .fd = e.handle,
        .events = switch (e.interest) {
            .readable => posix.POLL.IN,
            .writable => posix.POLL.OUT,
        },
        .revents = 0,
    };
    const timeout: i32 = @intCast(@min(ms, std.math.maxInt(i32)));
    const rc = posix.system.poll(&fds, @intCast(entries.len), timeout);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .INTR => return null,
        .NOMEM => return error.SystemResources,
        else => |e| return posix.unexpectedErrno(e),
    }
    if (rc == 0) return null;
    for (fds[0..entries.len], 0..) |f, i| if (f.revents != 0) return i;
    return null;
}

/// The lowest index of a signaled object within `ms` milliseconds; null
/// when none was.
pub fn objects(handles: []const std.os.windows.HANDLE, ms: u32) Error!?usize {
    std.debug.assert(handles.len <= win32.maximum_wait_objects);
    const rc = win32.WaitForMultipleObjects(@intCast(handles.len), handles.ptr, .FALSE, ms);
    if (rc == win32.wait_timeout) return null;
    if (rc == win32.wait_failed) return error.Unexpected;
    // WAIT_OBJECT_0 + i; an abandoned mutex (WAIT_ABANDONED_0 + i) is
    // signaled too.
    const index = if (rc >= 0x80) rc - 0x80 else rc;
    if (index >= handles.len) return error.Unexpected;
    return index;
}
