//! The monitor: one thread that samples the processors. A worker that has
//! lent its processor for `handoff_after` (its task running its own code,
//! or sitting in a blocking call: its seat's `stage`) loses it to a spare
//! thread when it has work, so the tasks queued there and the loop's
//! completions go on. A
//! task that has held its processor for `report_after` without switching
//! out is recorded as a stall: where it was started, and for how long.
//!
//! The samples cost the processors two stores per task switch (`passes`,
//! `site`) and nothing else: the monitor reads its own clock. It samples
//! every 20 µs while a processor stays lent or one task holds it across
//! samples, backing off to 10 ms while tasks come and go, and parks when
//! every processor waits in its kernel. A blocking call that begins while
//! it sleeps long wakes it; a task computing is found within the sample
//! after its lending began, so 10 ms at most after the monitor last looked.
const Monitor = @This();

/// Stalls ever recorded.
const Stalls = aegis.units.Count(Stall, u64);
/// Processors' work handed to another thread.
const Handoffs = aegis.units.Count(Monitor, u64);

const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const clocks = @import("../clock.zig");
const Stage = @import("stage.zig").Stage;
const Raised = @import("../sync/Raised.zig");

/// What the monitor remembers of one processor between samples.
const Sample = struct {
    /// The owner's seat (an opaque `*Scheduler.Seat`) and its stage.
    owner: ?*const anyopaque = null,
    stage: Stage = .first,
    stage_since: clocks.Awake = .fromRaw(0),
    passes: u32 = 0,
    passes_since: clocks.Awake = .fromRaw(0),
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
const shortest: clocks.Span = .fromRaw(20 * std.time.ns_per_us);
const no_site = std.math.maxInt(usize);
const longest: clocks.Span = .fromRaw(10 * std.time.ns_per_ms);

samples: []Sample,
handoff_after: clocks.Span,
report_after: ?clocks.Span,
handoff: bool,
thread: ?std.Thread = null,
/// What the monitor sleeps on: moved to wake it early.
// aegis: boundary: a futex word: the kernel waits on this u32's address
word: std.atomic.Value(u32) = .init(0),
/// Sleeping longer than the shortest interval, or parked: a blocking call
/// or a processor waking up wakes it.
slow: Raised = .{},
parked: Raised = .{},
stalls: aegis.Atomic(Stalls) = .init(.fromRaw(0)),
/// Set by `stop`.
quit: Raised = .{},
handoffs: aegis.Atomic(Handoffs) = .init(.fromRaw(0)),
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
        .handoff_after = clocks.spanOf(handoff_after),
        .report_after = if (report_after) |d| clocks.spanOf(d) else null,
    };
}

pub fn deinit(m: *Monitor, gpa: Allocator) void {
    gpa.free(m.samples);
    m.* = undefined;
}

fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn now() clocks.Awake {
    return clocks.awakeOf(Io.Clock.awake.now(system()));
}

/// From a processor: something to watch began while the monitor sleeps long.
pub fn poke(m: *Monitor) void {
    if (!m.slow.raised(.monotonic)) return;
    m.slow.clear(.monotonic);
    _ = m.word.fetchAdd(1, .release);
    system().futexWake(u32, &m.word.raw, 1);
}

/// At stop, before any processor's thread may end: the monitor reads their
/// seats.
pub fn stop(m: *Monitor) void {
    _ = m.quit.raise(.release);
    _ = m.word.fetchAdd(1, .release);
    system().futexWake(u32, &m.word.raw, 1);
    if (m.thread) |t| t.join();
    m.thread = null;
}

/// The monitor's body. `S` is the scheduler: its processors carry
/// `owner` (a seat with its `stage`), `passes` and `site`; it answers
/// `isLent`, `isBlocked`, `handOff` and `allIdle`.
pub fn run(m: *Monitor, s: anytype) void {
    var delay = shortest;
    while (!m.quit.raised(.acquire)) {
        const t = now();
        var watching = false;
        for (s.processors, m.samples) |*p, *sample| {
            if (m.look(s, p, sample, t)) watching = true;
        }
        delay = if (watching) shortest else doubled(delay);
        const seen = m.word.load(.acquire);
        if (!watching and s.allIdle()) {
            _ = m.parked.raise(.seq_cst);
            _ = m.slow.raise(.monotonic);
            // A processor that leaves its kernel wait after this check
            // sees `parked` and wakes the monitor.
            if (s.allIdle() and !m.quit.raised(.acquire)) system().futexWaitUncancelable(u32, &m.word.raw, seen);
            m.parked.clear(.monotonic);
            delay = shortest;
            continue;
        }
        if (delay.compare(shortest) == .gt) {
            _ = m.slow.raise(.monotonic);
        } else m.slow.clear(.monotonic);
        system().futexWaitTimeout(u32, &m.word.raw, seen, .{ .duration = .{ .raw = delay.toIoDuration(), .clock = .awake } }) catch unreachable; // unreachable: the monitor is no task: nothing cancels it
        if (m.word.load(.acquire) != seen) delay = shortest;
    }
}

/// One processor's sample; true when it needs watching closely: one
/// lending, or one task holding it, since the last sample.
fn look(m: *Monitor, s: anytype, p: anytype, sample: *Sample, t: clocks.Awake) bool {
    var watching = false;
    // The word before the owner: the owner is stored first (`holdFrom`),
    // so the owner read is the word's or a later one's, and a stale pair
    // fails the claim.
    const word = p.lease.load(.acquire);
    if (p.owner.load(.acquire)) |owner| {
        const stage = owner.stage.load(.acquire);
        if (s.isLent(stage)) {
            // A blocking call is watched from its start, a task's own code
            // once it outlasts a sample: most are over long before.
            if (s.isBlocked(stage)) watching = true;
            if (sample.stage != stage or sample.owner != @as(*const anyopaque, owner)) {
                sample.stage = stage;
                sample.owner = owner;
                sample.stage_since = t;
            } else {
                watching = true;
                if (m.handoff and clocks.since(sample.stage_since, t).compare(m.handoff_after) != .lt) {
                    if (s.handOff(p, word, owner, stage)) _ = m.handoffs.fetchAddWrapping(.fromRaw(1), .monotonic);
                }
            }
        }
    }
    const passes = p.passes.load(.acquire).raw();
    // Odd while a task runs.
    if (passes & 1 == 1) {
        if (sample.passes == passes) watching = true;
        if (sample.passes != passes) {
            sample.passes = passes;
            sample.passes_since = t;
            sample.reported = false;
        } else if (!sample.reported) {
            if (m.report_after) |after| if (clocks.since(sample.passes_since, t).compare(after) != .lt) {
                sample.reported = true;
                m.record(.{ .site = p.site.load(.monotonic).raw(), .processor = p.index, .duration = clocks.since(sample.passes_since, t).toIoDuration() });
            };
        }
    } else sample.passes = passes;
    return watching;
}

/// Twice `delay`, at most `longest`.
fn doubled(delay: clocks.Span) clocks.Span {
    const twice = delay.mul(2) catch return longest;
    return if (twice.compare(longest) == .gt) longest else twice;
}

fn record(m: *Monitor, stall: Stall) void {
    // The monitor's thread alone records: a plain step, published.
    const n = m.stalls.load(.monotonic);
    m.records[n.raw() % records_kept] = stall;
    m.stalls.store(n.add(.fromRaw(1)) catch unreachable, .release); // unreachable: no program records 2^64 stalls
    if (builtin.mode != .debug and builtin.mode != .safe) return;
    for (&m.logged) |*site| {
        if (site.* == stall.site) return;
        if (site.* == no_site) {
            site.* = stall.site;
            const held = aegis.units.Duration(.microsecond, u64).fromIoDuration(stall.duration, .down) catch aegis.units.Duration(.microsecond, u64).fromRaw(std.math.maxInt(u64));
            std.log.scoped(.reactor).warn("a task started at 0x{x} held processor {d} for {f} without switching out", .{ stall.site, stall.processor, held });
            return;
        }
    }
}
