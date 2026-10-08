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
