//! A process that a wait reports once it has ended, without reaping it:
//! whoever holds the reap (`std.process.Child`, conduit's reaper) still
//! collects the status. Open it while the child is unreaped, so its id
//! cannot belong to another process yet. A pidfd on Linux, a kqueue with
//! one `EVFILT_PROC` registration on Darwin and the BSDs, the process
//! handle on Windows. Where there is no such descriptor (none on this
//! system, or none to spare), a wait on a child asks `waitid` with
//! `WNOWAIT` between slices. A wait reports a child once `waitpid` will:
//! a kqueue posts `NOTE_EXIT` a moment before that, and the wait then
//! waits for the `SIGCHLD` that follows.
const Process = @This();

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;
const poll = @import("../sys/poll.zig");
const process = @import("../sys/process.zig");
const win32 = @import("../sys/win32.zig");

const is_windows = builtin.os.tag == .windows;

/// What a wait waits on; not to be touched.
watch: if (is_windows) windows.HANDLE else process.Watch,
/// The process's id.
id: std.process.Child.Id,

pub const OpenError = error{ ProcessNotFound, SystemResources, Unexpected };

/// POSIX: `id` is a child of this process, not yet reaped; with no
/// descriptor to spare the watch asks about it, so `SystemResources` is
/// the answer only for a process that is not a child, which a descriptor
/// alone can watch. Windows: a process handle, duplicated here with the
/// right to wait on it.
pub fn open(io: Io, id: std.process.Child.Id) OpenError!Process {
    _ = io;
    if (is_windows) {
        const me = win32.GetCurrentProcess();
        var copy: windows.HANDLE = undefined;
        if (win32.DuplicateHandle(me, id, me, &copy, win32.synchronize, .FALSE, 0) == .FALSE) return switch (win32.GetLastError()) {
            win32.error_invalid_parameter, win32.error_access_denied => error.ProcessNotFound,
            else => error.Unexpected,
        };
        return .{ .watch = copy, .id = id };
    }
    return .{ .watch = try process.open(id), .id = id };
}

/// Whether the process has ended, asked without waiting and without
/// reaping it: the answer a wait for it would be ready on. A watch that
/// cannot be asked counts as ended, as a wait counts it ready: the reap
/// says what became of the process.
pub fn ended(p: *const Process) bool {
    if (is_windows) return win32.WaitForSingleObject(p.watch, 0) != win32.wait_timeout;
    return switch (p.watch) {
        .ended => true,
        .descriptor => |h| (poll.descriptors(&.{.{ .handle = h, .interest = .readable }}, poll.look) catch return true) != null and
            (!process.is_bsd or process.endedUnreaped(p.id) != .running),
        .exiting, .asking => process.endedUnreaped(p.id) != .running,
    };
}

pub fn close(p: *Process, io: Io) void {
    if (is_windows) {
        const file: Io.File = .{ .handle = p.watch, .flags = .{ .nonblocking = false } };
        file.close(io);
    } else process.close(p.watch, io);
    p.* = undefined;
}
