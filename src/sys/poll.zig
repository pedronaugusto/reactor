//! Readiness of several descriptors (`poll`) or Windows objects
//! (`WaitForMultipleObjects`), waited for on the calling thread for at most
//! a given time: what the extensions' waits fall back to on an `Io` that is
//! not a runtime.
const std = @import("std");
const aegis = @import("aegis");
const posix = std.posix;
const Io = std.Io;
const win32 = @import("win32.zig");

/// The most members one wait takes.
pub const max = 64;

pub const Interest = enum { readable, writable, priority };

pub const Entry = struct { handle: Io.File.Handle, interest: Interest };

pub const Error = error{ SystemResources, Unexpected };

/// How long a wait may last: the kernel counts it in whole milliseconds.
pub const Millis = aegis.units.Duration(.millisecond, u32);

/// A wait that only looks.
pub const look: Millis = .fromRaw(0);

/// The lowest index of an entry ready within `wait`; null when
/// none was. An error or a hang-up counts as ready: a read or write then
/// reports it, and so does a number no descriptor has, which `poll` itself
/// skips. A signal ends the wait early, as a timeout.
pub fn descriptors(entries: []const Entry, wait: Millis) Error!?usize {
    std.debug.assert(entries.len <= max);
    for (entries, 0..) |e, i| if (e.handle < 0) return i;
    var fds: [max]posix.pollfd = undefined;
    for (entries, fds[0..entries.len]) |e, *f| f.* = .{
        .fd = e.handle,
        .events = switch (e.interest) {
            .readable => posix.POLL.IN,
            .writable => posix.POLL.OUT,
            .priority => posix.POLL.PRI,
        },
        .revents = 0,
    };
    // glint-ignore: A004 -- c-os-boundary: docs/design.md#safety-types; poll counts in an i32 of milliseconds
    const timeout: i32 = @intCast(@min(wait.raw(), std.math.maxInt(i32)));
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

/// The lowest index of a signaled object within `wait`; null
/// when none was.
pub fn objects(handles: []const std.os.windows.HANDLE, wait: Millis) Error!?usize {
    std.debug.assert(handles.len <= win32.maximum_wait_objects);
    const rc = win32.WaitForMultipleObjects(@intCast(handles.len), handles.ptr, .FALSE, wait.raw());
    if (rc == win32.wait_timeout) return null;
    if (rc == win32.wait_failed) return error.Unexpected;
    // WAIT_OBJECT_0 + i; an abandoned mutex (WAIT_ABANDONED_0 + i) is
    // signaled too.
    const index = if (rc >= 0x80) rc - 0x80 else rc;
    if (index >= handles.len) return error.Unexpected;
    return index;
}
