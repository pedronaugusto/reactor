//! Where a loop reads the time: the system's clocks, or a virtual clock
//! that moves only when a test moves it.
//!
//! A loop keeps one timeline, the awake clock, and names its points and
//! spans by what they count. `Awake` is a point in nanoseconds, `Tick` the
//! same timeline in the wheel's microseconds, `Span` a length of it. They do
//! not mix without a conversion that says how it rounds.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

/// A point on the loop's timeline: the awake clock, in nanoseconds.
pub const Awake = aegis.units.Instant(.awake, .nanosecond, u64);
/// The same timeline in the wheel's tick, one microsecond.
pub const Tick = aegis.units.Instant(.awake, .microsecond, u64);
/// A length of the loop's timeline, in nanoseconds.
pub const Span = aegis.units.Duration(.nanosecond, u64);

/// A point of the awake timeline from std's timestamp. The loop's timeline
/// starts at zero and ends 584 years on: a negative stamp is the start and
/// one beyond the end is the end, which no wait reaches.
pub fn awakeOf(t: Io.Timestamp) Awake {
    return .fromRaw(@intCast(std.math.clamp(t.nanoseconds, 0, std.math.maxInt(u64)))); // safe: clamped into u64 above
}

/// A span from std's duration, on the same terms: negative is zero and
/// beyond the end is the end.
pub fn spanOf(d: Io.Duration) Span {
    return .fromRaw(@intCast(std.math.clamp(d.nanoseconds, 0, std.math.maxInt(u64)))); // safe: clamped into u64 above
}

/// How long ago `then` was at `now`: nothing when the clock stepped back.
pub fn since(then: Awake, now: Awake) Span {
    return then.saturatingDurationTo(now);
}

/// `at` in the wheel's tick, rounded up: a timer never fires early.
pub fn tickUp(at: Awake) Tick {
    return at.convert(.microsecond, u64, .up);
}

/// `at` in the wheel's tick, rounded down: the last tick that has begun.
pub fn tickDown(at: Awake) Tick {
    return at.convert(.microsecond, u64, .down);
}

/// The nanoseconds a tick begins at, or the end of the timeline when the
/// tick lies beyond it.
pub fn awakeAt(tick: Tick) Awake {
    return tick.convert(.nanosecond, u64, .exact) catch .fromRaw(std.math.maxInt(u64));
}

/// A span as the two fields of a C `timespec`: whole seconds, then the
/// nanoseconds left over. The one place a kernel call's time is cut.
pub const Parts = struct { sec: u64, nsec: u32 };

pub fn parts(span: Span) Parts {
    const ns = span.raw(); // c-os-boundary: the timespec of a kernel call
    return .{ .sec = ns / std.time.ns_per_s, .nsec = @intCast(ns % std.time.ns_per_s) }; // safe: a remainder below a second
}

pub const Source = union(enum) {
    system,
    virtual: *Virtual,

    pub fn now(s: Source, clock: Io.Clock) Io.Timestamp {
        return switch (s) {
            .system => clock.now(system()),
            .virtual => |v| v.now(clock),
        };
    }

    /// The awake clock, the loop's timeline.
    pub fn awake(s: Source) Awake {
        return awakeOf(s.now(.awake));
    }

    /// The awake clock in the wheel's ticks, rounded down.
    pub fn ticks(s: Source) Tick {
        return tickDown(s.awake());
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
        _ = v.ns.fetchAdd(spanOf(by).raw(), .acq_rel);
    }

    pub fn set(v: *Virtual, at: Awake) void {
        v.ns.store(at.raw(), .release);
    }

    /// Moves `real` by `by` without moving the timeline.
    pub fn jump(v: *Virtual, by: Io.Duration) void {
        _ = v.real_offset.fetchAdd(@intCast(by.nanoseconds), .acq_rel);
    }
};
