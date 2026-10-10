//! A wake-up any thread can send to a task waiting on it: a member of a
//! `waitAny` set beside descriptors, a process, a job. It stays set until
//! the wait that reports it, which clears it; a signal while nobody waits
//! is kept for the next wait. Any `Io`.
const Wake = @This();

const std = @import("std");
const Io = std.Io;
const Notify = @import("../sys/Notify.zig");

/// The kernel object waits include; not to be touched.
notify: Notify,

pub const InitError = Notify.OpenError;

pub fn init(io: Io) InitError!Wake {
    _ = io;
    return .{ .notify = try .open() };
}

/// Once nothing waits on it.
pub fn deinit(w: *Wake, io: Io) void {
    w.notify.close(io);
    w.* = undefined;
}

/// From any thread: the next wait that includes it returns it.
pub fn signal(w: *Wake) void {
    w.notify.set();
}

/// The kernel object a signal sets, for a program with a wait loop of its own
/// (`poll` for readability on POSIX, a wait on the handle on Windows). A wait
/// of reactor's clears the signal it reports; a program that waits on this
/// itself calls `clear`.
pub fn handle(w: *const Wake) Io.File.Handle {
    return w.notify.handle;
}

/// Clears a signal that a wait outside reactor saw.
pub fn clear(w: *Wake) void {
    w.notify.clear();
}
