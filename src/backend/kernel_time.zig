//! A deadline as a kernel's timer takes it: a point on one of its clocks,
//! in nanoseconds from that clock's zero.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const timeline = @import("../clock.zig");

/// A point on a kernel clock. The clock is the caller's to name.
pub const KernelTime = aegis.units.Instant(.any, .nanosecond, u64);

/// `t` on its clock: before the clock's zero is its zero, and past what
/// sixty-four bits hold is the end, which no timer reaches.
pub fn of(t: Io.Timestamp) KernelTime {
    return KernelTime.fromTimestamp(t, .exact) catch if (t.compare(.lt, .zero)) .fromRaw(0) else .fromRaw(std.math.maxInt(u64));
}

/// The time on `clock` now.
pub fn now(clock: Io.Clock, io: Io) KernelTime {
    return of(clock.now(io));
}

/// How far `t` is from its clock's zero: what an absolute `timespec` holds.
pub fn sinceZero(t: KernelTime) timeline.Span {
    return KernelTime.fromRaw(0).saturatingDurationTo(t);
}

/// How long from `from` until `t`: nothing when `t` is past.
pub fn until(from: KernelTime, t: KernelTime) timeline.Span {
    return from.saturatingDurationTo(t);
}
