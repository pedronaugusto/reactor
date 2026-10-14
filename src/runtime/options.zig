//! What a runtime is built with.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

const Loop = @import("../Loop.zig");
const Lanes = @import("../Lanes.zig");
const Scheduler = @import("../Scheduler.zig");

pub const Backend = Loop.Backend;
pub const Scheduling = Scheduler.Scheduling;
pub const Lane = Lanes.Lane;

pub const Files = enum {
    /// io_uring: ring operations, calls with no ring operation on a lane.
    /// epoll, kqueue, IOCP: std's own calls on the worker, which the monitor
    /// rescues by handing its processor on should one block; on a lane
    /// where there is no handoff (no monitor, or io_uring). On Windows all
    /// but a read or write of an open file run on a lane: std's frames for a
    /// path outgrow a task's stack.
    auto,
    /// Every file call on a lane: no worker ever waits on a disk.
    pool,
};

pub const Offload = Lanes.Config;

pub const StackClass = @import("../scheduler/stacks.zig").Class;

/// The workers a runtime starts when `Options.workers` is null: the logical
/// CPUs less the home thread's, and on Darwin a quarter of them (at least
/// one). Darwin's kernel spends more time on each loopback message the more
/// threads are in it (a raw thread per socket plateaus at ~165k 64-byte round
/// trips a second however many there are, and a runtime on 4 workers of 16
/// CPUs reaches 225k where 15 reach 155k), and tasks that talk to each other
/// through the kernel gain nothing from more threads than that; work that is
/// all arithmetic still scales to every CPU, so a host that wants that sets
/// `workers`.
pub fn defaultWorkers(os: std.Target.Os.Tag, cpus: usize) u16 {
    const all = cpus -| 1;
    const wanted = if (os.isDarwin()) @max(cpus / 4, 1) else all;
    return @intCast(@min(wanted, all, 255));
}

pub const Options = struct {
    backend: Backend = .auto,
    /// Worker threads `start` spawns beside the home thread. null: the
    /// logical CPUs less one, and on Darwin a quarter of them (at least
    /// one), for the reason `defaultWorkers` gives. 0: none; tasks run on the
    /// home thread whenever it waits in the `Io` or calls `run`.
    workers: ?u16 = null,
    scheduling: Scheduling = .stealing,
    /// A task that has not parked for this many cancelation points yields
    /// at the next one.
    budget_ops: u16 = 64,
    /// The same budget in time.
    budget_time: std.Io.Duration = .fromMilliseconds(1),
    /// Each task's stack reservation; what a task costs is the pages it
    /// touches.
    stack_size: aegis.units.Bytes(usize) = .fromRaw(1 << 20),
    /// Paint and scan task stacks to measure overall touched depth. This
    /// commits diagnostic pages and suspends trimming; leave off when timing.
    measure_stacks: bool = false,
    /// Additional size classes, counted within max_tasks; reserved at init.
    stack_classes: []const StackClass = &.{},
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
    sqpoll: ?Loop.SqPoll = null,
    zero_copy_min: ?aegis.units.Bytes(usize) = null,
    /// Sparse fixed-buffer pools per ring, reserved at init.
    registered_pools: u16 = 64,
    /// Linux: worker n on CPU n.
    pin_workers: bool = false,
    /// The monitor thread: stall reports, and on epoll, kqueue and IOCP,
    /// handoff of a processor whose task runs its own code or sits in a
    /// blocking call past `handoff_after`. null: on when there are workers
    /// and the backend is epoll, kqueue or IOCP.
    monitor: ?bool = null,
    /// Spare threads handoff may start, on demand. null: one per processor
    /// (workers + 1), so every processor can go to a spare while the thread
    /// that lent it still runs its task.
    spares: ?u16 = null,
    /// How long a worker lends its processor, while its task runs its own
    /// code or sits in a blocking call, before the processor is handed to a
    /// spare thread, if it has tasks queued or operations in its loop.
    handoff_after: Io.Duration = .fromMicroseconds(200),
    /// A task holding its processor this long without switching out is
    /// recorded as a stall; null: never.
    report_after: ?Io.Duration = .fromMilliseconds(10),
    /// As `Io.Threaded`'s.
    environ: std.process.Environ = .empty,
    argv0: Io.Threaded.Argv0 = .empty,
};
