//! N loops plus stackful tasks on a work-stealing scheduler: a complete
//! `std.Io`. `init` builds everything and starts nothing; the thread that
//! calls it is the home thread, where root code runs on its own stack and
//! never migrates. `start` spawns the workers the options name; with
//! `workers = 0` the runtime has no thread of its own and the host calls
//! `run(mode)`, once per frame or when `backendHandle` is readable.
const Runtime = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const backend = @import("backend.zig");
const Lanes = @import("Lanes.zig");
const Loop = @import("Loop.zig");
const Core = @import("runtime/Core.zig");
const options = @import("runtime/options.zig");
const slots = @import("runtime/slots.zig");

pub const Backend = options.Backend;
pub const Scheduling = options.Scheduling;
pub const Lane = options.Lane;
pub const Files = options.Files;
pub const Offload = options.Offload;
pub const Options = options.Options;
pub const InitError = Core.InitError;
pub const StartError = Core.StartError;

/// The runtime's; not to be touched.
core: Core,

/// Builds everything (stacks reserved, tables, rings, lane pools); starts
/// no thread. The calling thread becomes the home thread. `r` must not
/// move after this.
pub fn init(r: *Runtime, gpa: Allocator, o: Options) InitError!void {
    return r.core.init(gpa, o, .native, &slots.vtable);
}

/// Spawns the workers the options name. Lanes start threads on demand.
pub fn start(r: *Runtime) StartError!void {
    return r.core.start();
}

/// From the home thread: runs ready tasks and completions there as `mode`
/// allows. A host loop calls it per frame or when `backendHandle` is
/// readable; with `workers = 0` it is how tasks run.
pub fn run(r: *Runtime, mode: Loop.RunMode) void {
    r.core.run(mode);
}

/// The home loop's: readable when `run(.nowait)` has work.
pub fn backendHandle(r: *Runtime) error{ Unsupported, SystemResources, Unexpected }!Io.File.Handle {
    return r.core.processors[0].loop.backendHandle();
}

/// The longest the host may wait before calling `run(.nowait)`: zero
/// while the home processor has a task ready or a message to serve.
pub fn nextTimeout(r: *const Runtime) ?Io.Duration {
    const home = &r.core.processors[0];
    if (home.hasWork()) return .zero;
    return home.loop.nextTimeout();
}

/// From the home thread, after every task has ended: joins every thread.
pub fn stop(r: *Runtime) void {
    r.core.stop();
}

pub fn deinit(r: *Runtime) void {
    r.core.deinit();
    r.* = undefined;
}

pub fn io(r: *Runtime) Io {
    return r.core.io();
}

/// The kernel mechanism under this runtime.
pub fn backendKind(r: *const Runtime) ?backend.Kind {
    return r.core.backendKind();
}

/// The runtime an `Io` is, unless it is another `Io` (or one wrapping a
/// runtime, which takes the other `Io`s' path).
pub fn recognize(any: Io) ?*Runtime {
    if (any.vtable != &slots.vtable) return null;
    const c = Core.of(any.userdata);
    return @fieldParentPtr("core", c);
}

pub const Stats = struct {
    workers: u16,
    tasks: u32,
    max_tasks: u32,
    steals: u64,
    forced_yields: u64,
    lanes: [Lanes.count]Lanes.Stats,
    /// Processors the monitor handed from a worker stuck in a blocking call
    /// to a spare thread.
    handoffs: u64,
    /// Tasks that held their processor past `report_after`.
    stalls: u64,
    /// Deep idle parked stacks whose unused pages were discarded.
    stack_trims: u64,
    /// Deepest task frame observed at a park, retained after task release.
    parked_high_water: usize,
    /// Deepest touched task storage; null unless measure_stacks is on.
    stack_high_water: ?usize,
};

pub fn stats(r: *Runtime) Stats {
    var lanes: [Lanes.count]Lanes.Stats = undefined;
    for (&lanes, 0..) |*l, i| l.* = r.core.lanes.stats(@fromBackingInt(@intCast(i)));
    var parked: usize = 0;
    var overall: usize = 0;
    for (r.core.processors) |*processor| {
        parked = @max(parked, processor.parked_high_water.load(.monotonic));
        overall = @max(overall, processor.stack_high_water.load(.monotonic));
    }
    return .{
        .parked_high_water = parked,
        .stack_high_water = if (r.core.options.measure_stacks) overall else null,
        .stack_trims = r.core.scheduler.stack_trims.load(.monotonic),
        .workers = @intCast(r.core.processors.len - 1),
        .tasks = r.core.scheduler.stacks.inUse(.monotonic),
        .max_tasks = r.core.options.max_tasks,
        .steals = r.core.scheduler.steals.load(.monotonic),
        .forced_yields = r.core.scheduler.forced_yields.load(.monotonic),
        .lanes = lanes,
        .handoffs = if (r.core.scheduler.monitor) |m| m.handoffs.load(.monotonic) else 0,
        .stalls = if (r.core.scheduler.monitor) |m| m.stalls.load(.monotonic) else 0,
    };
}

/// Stream counters and live task summaries without allocating or stopping workers.
pub fn dump(r: *Runtime, writer: *Io.Writer) Io.Writer.Error!void {
    const snapshot = r.stats();
    try writer.print("workers={d} tasks={d}/{d} steals={d} forced_yields={d}\n", .{ snapshot.workers, snapshot.tasks, snapshot.max_tasks, snapshot.steals, snapshot.forced_yields });
    for (std.enums.values(Lane), snapshot.lanes) |lane, status| {
        try writer.print("lane={s} running={d} queued={d} threads={d} inline={d}\n", .{ @tagName(lane), status.running, status.queued, status.threads, status.@"inline" });
    }
    try r.core.scheduler.records.dump(writer);
}
