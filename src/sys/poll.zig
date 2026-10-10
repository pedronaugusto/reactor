//! Readiness of several descriptors (`poll`) or Windows objects
//! (`WaitForMultipleObjects`), waited for on the calling thread for at most
//! a given time: what the extensions' waits fall back to on an `Io` that is
//! not a runtime.
const builtin = @import("builtin");
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
    if (comptime darwin) if (wait.compare(look) == .eq) if (selected(entries)) |ready| return ready;
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

const darwin = builtin.os.tag.isDarwin();

/// The descriptors `select` takes in its default sets.
const select_limit = 1024;

extern "c" fn select(nfds: c_int, readfds: ?*[select_limit / 32]u32, writefds: ?*[select_limit / 32]u32, errorfds: ?*[select_limit / 32]u32, timeout: ?*posix.timeval) c_int;

/// A look on Darwin through `select`, whose `poll(2)` waits off the CPU for
/// ~6 us when nothing is ready, even with no timeout (`select` answers in
/// ~0.2). Null when `select` cannot answer it alike: a priority interest,
/// a descriptor past its sets, or one that is not open (`poll` reports
/// that one alone, as ready; `select` fails the whole call).
fn selected(entries: []const Entry) ?(Error!?usize) {
    var read_set: [select_limit / 32]u32 = @splat(0);
    var write_set: [select_limit / 32]u32 = @splat(0);
    var top: posix.fd_t = 0;
    for (entries) |e| {
        if (e.handle >= select_limit) return null;
        const word: usize = @intCast(@divFloor(e.handle, 32));
        const bit = @as(u32, 1) << @intCast(@mod(e.handle, 32));
        switch (e.interest) {
            .readable => read_set[word] |= bit,
            .writable => write_set[word] |= bit,
            .priority => return null,
        }
        top = @max(top, e.handle);
    }
    var zero: posix.timeval = .{ .sec = 0, .usec = 0 };
    const rc = select(top + 1, &read_set, &write_set, null, &zero);
    if (rc < 0) return switch (posix.errno(rc)) {
        .INTR => null,
        .BADF, .INVAL => null,
        .AGAIN, .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
    if (rc == 0) return @as(?usize, null);
    for (entries, 0..) |e, i| {
        const word: usize = @intCast(@divFloor(e.handle, 32));
        const bit = @as(u32, 1) << @intCast(@mod(e.handle, 32));
        const set = switch (e.interest) {
            .readable => read_set,
            .writable => write_set,
            .priority => unreachable, // unreachable: refused above
        };
        if (set[word] & bit != 0) return i;
    }
    return @as(?usize, null);
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
