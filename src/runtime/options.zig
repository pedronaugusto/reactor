//! What a runtime is built with.
const std = @import("std");
const Io = std.Io;

const Loop = @import("../Loop.zig");
const Lanes = @import("../Lanes.zig");
const Scheduler = @import("../Scheduler.zig");

pub const Backend = Loop.Backend;
pub const Scheduling = Scheduler.Scheduling;
pub const Lane = Lanes.Lane;

pub const Files = enum {
    /// io_uring: ring operations, calls with no ring operation on a lane.
    /// Elsewhere: on a lane.
    auto,
    /// Every file call on a lane: no worker ever waits on a disk.
    pool,
};

pub const Offload = Lanes.Config;

pub const Options = struct {
    backend: Backend = .auto,
    /// Worker threads `start` spawns beside the home thread. null: logical
    /// CPUs - 1. 0: none; tasks run on the home thread whenever it waits in
    /// the `Io` or calls `run`.
    workers: ?u16 = null,
    scheduling: Scheduling = .stealing,
    /// A task that has not parked for this many cancelation points yields
    /// at the next one.
    budget_ops: u16 = 64,
    /// The same budget in time.
    budget_time: std.Io.Duration = .fromMilliseconds(1),
    /// Each task's stack reservation; what a task costs is the pages it
    /// touches.
    stack_size: usize = 1 << 20,
    /// Past this, `concurrent` fails with `ConcurrencyUnavailable` and
    /// `async` runs the function inline (both legal for `std.Io`).
    max_tasks: u32 = 16 << 10,
    /// Includes libc requests detached from canceled callers.
    max_lookups: u32 = 64,
    /// Windows jobs attached to the runtime's completion ports at once.
    max_jobs: u16 = 64,
    files: Files = .auto,
    offload: Offload = .{ .owned = .{} },
    /// Submission queue entries per ring.
    ring_entries: u16 = 256,
    uring_off: Loop.UringFeatures = .{},
    /// Linux: worker n on CPU n.
    pin_workers: bool = false,
    /// As `Io.Threaded`'s.
    environ: std.process.Environ = .empty,
    argv0: Io.Threaded.Argv0 = .empty,
};
