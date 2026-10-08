//! The monitor: one thread that samples the processors. A worker that has
//! sat in a blocking call (`Scheduler.enterBlocking`) for `handoff_after`
//! loses its processor to a spare thread, so the tasks queued there and the
//! loop's completions go on (Go's sysmon retaking a P from a syscall). A
//! task that has held its processor for `report_after` without switching
//! out is recorded as a stall: where it was started, and for how long.
//!
//! The samples cost the processors two stores per task switch (`passes`,
//! `site`) and nothing else: the monitor reads its own clock. It samples
//! every 20 µs while a worker sits in a blocking call or one task holds a
//! processor across samples, backing off to 10 ms while tasks come and go
//! (Go's sysmon backs off the same way), and parks when every processor
//! waits in its kernel. A blocking call that begins while it sleeps long
//! wakes it.
const Monitor = @This();

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// What the monitor remembers of one processor between samples.
const Sample = struct {
    blocking: u32 = 0,
    blocking_since: u64 = 0,
    passes: u32 = 0,
    passes_since: u64 = 0,
    reported: bool = false,
};

/// One recorded stall.
pub const Stall = struct {
    /// Where the task was started (`concurrent`, `async`, a group call);
    /// 0 for the root.
    site: usize,
    processor: u16,
    /// How long it had held the processor when recorded.
    duration: Io.Duration,
};

pub const records_kept = 32;
const sites_logged = 64;
const shortest_ns = 20 * std.time.ns_per_us;
const no_site = std.math.maxInt(usize);
const longest_ns = 10 * std.time.ns_per_ms;

samples: []Sample,
handoff_after_ns: u64,
report_after_ns: ?u64,
handoff: bool,
thread: ?std.Thread = null,
/// What the monitor sleeps on: moved to wake it early.
word: std.atomic.Value(u32) = .init(0),
/// Sleeping longer than the shortest interval, or parked: a blocking call
/// or a processor waking up wakes it.
slow: std.atomic.Value(bool) = .init(false),
parked: std.atomic.Value(bool) = .init(false),
stalls: std.atomic.Value(u64) = .init(0),
handoffs: std.atomic.Value(u64) = .init(0),
/// The latest stalls, a ring: `stalls` says how many were ever recorded.
records: [records_kept]Stall = undefined,
/// The sites a stall was logged for (safe builds log each site once).
logged: [sites_logged]usize = @splat(no_site),

pub fn init(gpa: Allocator, processors: usize, handoff: bool, handoff_after: Io.Duration, report_after: ?Io.Duration) Allocator.Error!Monitor {
    const samples = try gpa.alloc(Sample, processors);
    @memset(samples, .{});
    return .{
        .samples = samples,
        .handoff = handoff,
        .handoff_after_ns = @intCast(@max(handoff_after.nanoseconds, 0)),
        .report_after_ns = if (report_after) |d| @intCast(@max(d.nanoseconds, 0)) else null,
    };
}

pub fn deinit(m: *Monitor, gpa: Allocator) void {
    gpa.free(m.samples);
    m.* = undefined;
}

fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn now() u64 {
    return @intCast(@max(Io.Clock.awake.now(system()).nanoseconds, 0));
}

/// From a processor: something to watch began while the monitor sleeps long.
pub fn poke(m: *Monitor) void {
    if (!m.slow.load(.monotonic)) return;
    m.slow.store(false, .monotonic);
    _ = m.word.fetchAdd(1, .release);
    system().futexWake(u32, &m.word.raw, 1);
}

/// At stop.
pub fn stop(m: *Monitor) void {
    _ = m.word.fetchAdd(1, .release);
    system().futexWake(u32, &m.word.raw, 1);
    if (m.thread) |t| t.join();
    m.thread = null;
}

/// The monitor's body. `S` is the scheduler: its processors carry
/// `blocking`, `passes` and `site`; it answers `handOff` and `allIdle`.
pub fn run(m: *Monitor, s: anytype) void {
    var delay: u64 = shortest_ns;
    while (!s.stopping.load(.acquire)) {
        const t = now();
        var watching = false;
        for (s.processors, m.samples) |*p, *sample| {
            if (m.look(s, p, sample, t)) watching = true;
        }
        delay = if (watching) shortest_ns else @min(delay * 2, longest_ns);
        const seen = m.word.load(.acquire);
        if (!watching and s.allIdle()) {
            m.parked.store(true, .seq_cst);
            m.slow.store(true, .monotonic);
            // A processor that leaves its kernel wait after this check
            // sees `parked` and wakes the monitor.
            if (s.allIdle() and !s.stopping.load(.acquire)) system().futexWaitUncancelable(u32, &m.word.raw, seen);
            m.parked.store(false, .monotonic);
            delay = shortest_ns;
            continue;
        }
        m.slow.store(delay > shortest_ns, .monotonic);
        system().futexWaitTimeout(u32, &m.word.raw, seen, .{ .duration = .{ .raw = .fromNanoseconds(@intCast(delay)), .clock = .awake } }) catch unreachable; // unreachable: the monitor is no task: nothing cancels it
        if (m.word.load(.acquire) != seen) delay = shortest_ns;
    }
}

/// One processor's sample; true when it needs watching closely: a blocking
/// call under way, or one task holding it since the last sample.
fn look(m: *Monitor, s: anytype, p: anytype, sample: *Sample, t: u64) bool {
    var watching = false;
    const blocking = p.blocking.load(.acquire);
    if (blocking & 3 == 1) {
        watching = true;
        if (sample.blocking != blocking) {
            sample.blocking = blocking;
            sample.blocking_since = t;
        } else if (m.handoff and t - sample.blocking_since >= m.handoff_after_ns) {
            if (s.handOff(p, blocking)) _ = m.handoffs.fetchAdd(1, .monotonic);
        }
    }
    const passes = p.passes.load(.acquire);
    // Odd while a task runs.
    if (passes & 1 == 1) {
        if (sample.passes == passes) watching = true;
        if (sample.passes != passes) {
            sample.passes = passes;
            sample.passes_since = t;
            sample.reported = false;
        } else if (!sample.reported) {
            if (m.report_after_ns) |after| if (t - sample.passes_since >= after) {
                sample.reported = true;
                m.record(.{ .site = p.site.load(.monotonic), .processor = p.index, .duration = .fromNanoseconds(@intCast(t - sample.passes_since)) });
            };
        }
    } else sample.passes = passes;
    return watching;
}

fn record(m: *Monitor, stall: Stall) void {
    const n = m.stalls.load(.monotonic);
    m.records[n % records_kept] = stall;
    m.stalls.store(n + 1, .release);
    if (builtin.mode != .debug and builtin.mode != .safe) return;
    for (&m.logged) |*site| {
        if (site.* == stall.site) return;
        if (site.* == no_site) {
            site.* = stall.site;
            std.log.scoped(.reactor).warn("a task started at 0x{x} held processor {d} for {d} µs without switching out", .{ stall.site, stall.processor, @divFloor(stall.duration.nanoseconds, std.time.ns_per_us) });
            return;
        }
    }
}
