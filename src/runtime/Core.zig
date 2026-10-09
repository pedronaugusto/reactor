//! A runtime's state and how it is built: the processors and their loops,
//! the scheduler, the futex table, the lanes, the root task. `Runtime` is
//! its public face; the vtable's slots reach it through `of`.
const Core = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const backend = @import("../backend.zig");
const fiber = @import("../fiber.zig");
const Stacks = @import("../fiber/Stacks.zig");
const memory = @import("../sys/memory.zig");
const clock = @import("../clock.zig");
const Lanes = @import("../Lanes.zig");
const Lookup = @import("../ops/Lookup.zig");
const Loop = @import("../Loop.zig");
const loop_internal = @import("../loop/internal.zig");
const Task = @import("../scheduler/Task.zig");
const Scheduler = @import("../Scheduler.zig");
const Records = @import("../scheduler/Records.zig");
const Trims = @import("../scheduler/Trims.zig");
const Notifications = @import("../backend/iocp/Notifications.zig");
const Processor = Scheduler.Processor;
const futexes = @import("../ops/futex.zig");
const batch = @import("../ops/batch.zig");
const options_ = @import("options.zig");

pub const Options = options_.Options;
pub const InitError = Loop.InitError || error{TooManyTasks};
pub const StartError = error{ SystemResources, Unexpected };

gpa: Allocator,
options: Options,
/// The `Io` this core is handed out as.
vtable: *const Io.VTable,
scheduler: Scheduler,
processors: []Processor,
root: Task,
futex: futexes.Table = .{},
lanes: Lanes,
lookup: Lookup,
jobs: if (builtin.os.tag == .windows) Notifications else void,
/// The home processor's scheduler runs here while the root waits.
home_stack: []align(memory.page_size_min) u8,
started: std.atomic.Value(bool) = .init(false),
stderr: Stderr = .{},
csprngs: []Io.Threaded.Csprng,

const home_stack_size = 256 << 10;

/// Standard error, held by a task (which may move between threads) or a
/// thread outside the runtime; its writer runs on the runtime's `Io`.
pub const Stderr = struct {
    mutex: Io.Mutex = .init,
    holder: usize = 0,
    depth: u32 = 0,
    /// Filled when first locked: `File.stderr` is a call on some systems.
    writer: Io.File.Writer = .{
        .io = undefined,
        .interface = Io.File.Writer.initInterface(&.{}),
        .file = undefined,
        .mode = .streaming,
    },
    ready: bool = false,
    mode: Io.Terminal.Mode = .no_color,
};

/// How a runtime's loops are built: the system's backend, or one given
/// per processor (reactor's tests: the seeded fake and a virtual clock).
pub const Construction = union(enum) {
    native,
    custom: struct {
        context: *anyopaque,
        backendFor: *const fn (context: *anyopaque, processor: u16) backend.Custom,
        clock: clock.Source,
    },
};

/// Builds everything: stacks reserved, tables, loops, lanes; starts no
/// thread. The calling thread becomes the home thread. `c` must not move.
pub fn init(c: *Core, gpa: Allocator, options: Options, how: Construction, vtable: *const Io.VTable) InitError!void {
    if (comptime !fiber.supported) return error.BackendUnavailable;
    const workers: u16 = options.workers orelse @intCast(std.math.clamp((std.Thread.getCpuCount() catch 1) -| 1, 0, 255));
    const count: u16 = workers + 1;
    c.* = .{
        .gpa = gpa,
        .options = options,
        .vtable = vtable,
        .scheduler = undefined,
        .processors = try gpa.alloc(Processor, count),
        .root = .{ .kind = .root, .policy = .{ .home = true } },
        .lanes = undefined,
        .lookup = undefined,
        .jobs = undefined,
        .home_stack = undefined,
        .csprngs = undefined,
    };
    errdefer gpa.free(c.processors);
    c.csprngs = try gpa.alloc(Io.Threaded.Csprng, count);
    errdefer gpa.free(c.csprngs);
    @memset(c.csprngs, .uninitialized);

    var stacks: Stacks = undefined;
    stacks.init(gpa, .{ .count = options.max_tasks, .size = options.stack_size, .classes = options.stack_classes }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyTasks => error.TooManyTasks,
        error.SystemResources => error.SystemResources,
    };
    errdefer stacks.deinit(gpa);
    var records = try Records.init(gpa, options.max_tasks);
    errdefer records.deinit(gpa);
    var trims = try Trims.init(gpa, options.max_tasks, count);
    errdefer trims.deinit(gpa);
    c.scheduler = .{
        .processors = c.processors,
        .root = &c.root,
        .stacks = stacks,
        .records = records,
        .trims = trims,
        .scheduling = if (workers == 0) .per_core else options.scheduling,
        .measure_stacks = options.measure_stacks,
        .budget_ops = options.budget_ops,
        .budget_ns = @intCast(@max(options.budget_time.nanoseconds, 0)),
        .home_thread = std.Thread.getCurrentId(),
    };

    var made: usize = 0;
    if (builtin.os.tag == .windows) c.jobs = try Notifications.init(gpa, options.max_jobs);
    errdefer if (builtin.os.tag == .windows) c.jobs.deinit(gpa);
    errdefer for (c.processors[0..made]) |*p| p.loop.backend.deinit(gpa);
    for (c.processors, 0..) |*p, i| {
        p.* = .{ .scheduler = &c.scheduler, .index = @intCast(i), .loop = undefined };
        try c.buildLoop(p, how);
        if (comptime builtin.os.tag == .windows and fiber.supported) if (p.loop.backend == .iocp) {
            p.loop.backend.iocp.notifications = &c.jobs;
        };
        loop_internal.setBatchSink(&p.loop, .{ .context = c, .complete = batch.completed });
        made += 1;
    }

    try c.lanes.init(gpa, options.offload, .{ .environ = options.environ, .argv0 = options.argv0 });
    errdefer c.lanes.deinit(gpa);

    try c.initMonitor(workers);
    errdefer c.deinitMonitor();
    c.lookup = try Lookup.init(gpa, options.max_lookups);
    errdefer c.lookup.deinit(gpa, &c.lanes);

    c.home_stack = memory.reserve(home_stack_size) catch return error.SystemResources;
    errdefer memory.release(c.home_stack);
    memory.protect(c.home_stack[0..memory.pageSize()]) catch return error.SystemResources;

    const home = &c.processors[0];
    const bottom = @intFromPtr(c.home_stack.ptr); // safe: the start of the mapping, for the stack's bounds
    const top = bottom + c.home_stack.len;
    home.sched_context = fiber.initial(.{ .top = top, .limit = bottom + memory.pageSize(), .bottom = bottom }, top, schedulerEntry, home);
    c.root.processor = home;
    home.current = &c.root;
    Scheduler.enter(home);
}

/// The monitor, as the options ask, and the spare pool handoff draws on.
/// Handoff needs a poller any thread may wait on (epoll, kqueue, IOCP), workers
/// to hand from, and tasks free to move (`stealing`).
fn initMonitor(c: *Core, workers: u16) InitError!void {
    const kind = c.backendKind();
    const handable = kind == .epoll or kind == .kqueue or kind == .iocp;
    const on = c.options.monitor orelse (workers > 0 and handable);
    if (!on) return;
    const handoff = handable and workers > 0 and c.scheduler.scheduling == .stealing;
    const cap: u16 = if (handoff) c.options.spares orelse @max(workers / 2, 1) else 0;
    c.scheduler.spares = try .init(c.gpa, c.processors.len, cap);
    errdefer c.scheduler.spares.deinit(c.gpa);
    const monitor = try c.gpa.create(Scheduler.Monitor);
    errdefer c.gpa.destroy(monitor);
    monitor.* = try .init(c.gpa, c.processors.len, handoff, c.options.handoff_after, c.options.report_after);
    c.scheduler.monitor = monitor;
}

fn deinitMonitor(c: *Core) void {
    if (c.scheduler.monitor) |m| {
        m.deinit(c.gpa);
        c.gpa.destroy(m);
        c.scheduler.spares.deinit(c.gpa);
        c.scheduler.monitor = null;
    }
}

fn buildLoop(c: *Core, p: *Processor, how: Construction) InitError!void {
    switch (how) {
        // Workers' rings are built here, owned by their threads.
        .native => try p.loop.init(c.gpa, .{
            .backend = c.options.backend,
            .max_ops = @max(2 * c.options.max_tasks / @as(u32, @intCast(c.processors.len)), 256),
            .submission_entries = c.options.ring_entries,
            .uring_off = c.options.uring_off,
            .sqpoll = c.options.sqpoll,
            .zero_copy_min = c.options.zero_copy_min,
            .registered_pools = c.options.registered_pools,
            .owner = if (p.index == 0) .caller else .adopter,
        }),
        .custom => |custom| loop_internal.initWith(&p.loop, .{ .custom = custom.backendFor(custom.context, p.index) }, custom.clock, 1 << 16),
    }
}

/// The home processor's scheduler, entered the first time the root waits.
fn schedulerEntry(arg: *anyopaque, message: *const fiber.Switch) callconv(.c) noreturn {
    const home: *Processor = @ptrCast(@alignCast(arg)); // safe: `init` passed the home processor
    home.afterSwitch(home.scheduler.root, message);
    while (true) {
        home.schedule();
        // The home processor went to another thread while a task here sat
        // in a blocking call: it comes back when the root runs again.
        Scheduler.reclaim(home);
    }
}

pub fn start(c: *Core) StartError!void {
    assert(!c.started.load(.acquire));
    // Publish startup before adoption: native setup must go to each owner.
    c.started.store(true, .release);
    // TSan’s thread-local storage needs more than the small normal OS stack.
    for (c.processors[1..]) |*p| {
        p.thread = std.Thread.spawn(.{ .stack_size = if (builtin.sanitize_thread) (std.Thread.SpawnConfig{}).stack_size else 512 << 10 }, Processor.work, .{p}) catch return error.SystemResources;
    }
    if (c.scheduler.monitor) |m| {
        m.thread = std.Thread.spawn(.{ .stack_size = if (builtin.sanitize_thread) (std.Thread.SpawnConfig{}).stack_size else 256 << 10 }, Scheduler.watch, .{&c.scheduler}) catch return error.SystemResources;
    }
}

pub fn run(c: *Core, mode: Loop.RunMode) void {
    assert(Scheduler.current() == &c.root);
    const Serve = struct {
        fn after(context: *anyopaque, t: *Task) void {
            const m: *const Loop.RunMode = @ptrCast(@alignCast(context)); // safe: `run` passed its mode
            const home: *Processor = @ptrCast(@alignCast(t.processor.?)); // safe: the root's processor is the home one
            home.serving = .{ .mode = m.* };
        }
    };
    var m = mode;
    Scheduler.park(.{ .func = Serve.after, .context = &m });
    // Back to the host, which may now wait on the loop's handle: work
    // handed to the home processor from here on wakes the loop, and work
    // handed to it before this was set makes the handle ready now.
    const home = c.root.processor.?;
    const p: *Processor = @ptrCast(@alignCast(home)); // safe: the root's processor is the home one
    p.away.store(true, .seq_cst);
    if (p.hasWork()) p.loop.wake();
}

pub fn stop(c: *Core) void {
    if (!c.started.load(.acquire)) return;
    assert(c.scheduler.stacks.inUse(.acquire) == 0);
    c.scheduler.stopping.store(true, .release);
    c.scheduler.wakeAll();
    if (c.scheduler.monitor) |m| {
        m.stop();
        // Spares, and workers waiting as spares, see the stop.
        c.scheduler.spares.stop();
    }
    for (c.processors[1..]) |*p| if (p.thread) |t| t.join();
    c.started.store(false, .release);
}

pub fn deinit(c: *Core) void {
    c.stop();
    assert(c.scheduler.stacks.inUse(.acquire) == 0);
    Scheduler.leave();
    c.deinitMonitor();
    c.lookup.deinit(c.gpa, &c.lanes);
    c.lanes.deinit(c.gpa);
    fiber.deinit(&c.processors[0].sched_context);
    c.scheduler.trims.deinit(c.gpa);
    for (c.processors) |*p| p.loop.deinit(c.gpa);
    memory.release(c.home_stack);
    c.scheduler.stacks.deinit(c.gpa);
    c.scheduler.records.deinit(c.gpa);
    if (builtin.os.tag == .windows) c.jobs.deinit(c.gpa);
    c.gpa.free(c.csprngs);
    c.gpa.free(c.processors);
    c.* = undefined;
}

pub fn io(c: *Core) Io {
    return .{ .userdata = c, .vtable = c.vtable };
}

/// The core an `Io.userdata` is.
pub fn of(userdata: ?*anyopaque) *Core {
    return @ptrCast(@alignCast(userdata.?)); // safe: only `io` hands the vtable out, with a `Core`
}

/// The kernel mechanism under this runtime; null for a test's own backend.
pub fn backendKind(c: *const Core) ?backend.Kind {
    return c.processors[0].loop.kind();
}
