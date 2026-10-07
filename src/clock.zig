//! Where a loop reads the time: the system's clocks, or a virtual clock
//! that moves only when a test moves it.
const std = @import("std");
const Io = std.Io;

pub const Source = union(enum) {
    system,
    virtual: *Virtual,

    pub fn now(s: Source, clock: Io.Clock) Io.Timestamp {
        return switch (s) {
            .system => clock.now(system()),
            .virtual => |v| v.now(clock),
        };
    }

    /// The awake clock in nanoseconds, the loop's timeline.
    pub fn awake(s: Source) u64 {
        const t = s.now(.awake);
        return @intCast(@max(t.nanoseconds, 0));
    }

    /// The awake clock in the wheel's ticks (microseconds), rounded down.
    pub fn ticks(s: Source) u64 {
        return s.awake() / std.time.ns_per_us;
    }
};

/// The system's clocks, read through std's own code.
fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// The resolution of `clock` on this system.
pub fn resolution(clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    return clock.resolution(system());
}

/// A clock that only moves when told to. `awake`, `boot` and the CPU
/// clocks read the same timeline; `real` reads it shifted to an epoch,
/// and `jump` moves `real` alone, as a wall-clock change does.
pub const Virtual = struct {
    ns: std.atomic.Value(u64) = .init(0),
    /// `real` minus the timeline, in nanoseconds.
    real_offset: std.atomic.Value(i64) = .init(1_700_000_000 * std.time.ns_per_s),

    pub fn now(v: *const Virtual, clock: Io.Clock) Io.Timestamp {
        const ns: i96 = v.ns.load(.acquire);
        return switch (clock) {
            .real => .{ .nanoseconds = ns + v.real_offset.load(.acquire) },
            else => .{ .nanoseconds = ns },
        };
    }

    pub fn advance(v: *Virtual, by: Io.Duration) void {
        _ = v.ns.fetchAdd(@intCast(by.nanoseconds), .acq_rel);
    }

    pub fn set(v: *Virtual, ns: u64) void {
        v.ns.store(ns, .release);
    }

    /// Moves `real` by `by` without moving the timeline.
    pub fn jump(v: *Virtual, by: Io.Duration) void {
        _ = v.real_offset.fetchAdd(@intCast(by.nanoseconds), .acq_rel);
    }
};
