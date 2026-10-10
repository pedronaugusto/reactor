//! Threads without a processor: workers whose processor was handed on while
//! they sat in a blocking call, and the spares the monitor starts on demand
//! to take such a processor. A handed processor waits here until a thread
//! takes it; a thread waits here until a processor comes or the runtime
//! stops. Everything is sized at `init`; threads are the system's, started
//! with no allocator.
const Spares = @This();

const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// What the lock guards.
const State = struct {
    /// The processors waiting for a thread (opaque `*Processor`s), the last
    /// posted taken first.
    waiting: aegis.bounded.Buffer(*anyopaque),
    /// Threads waiting here for a processor.
    idle: u32 = 0,
    /// Threads started that have not come to wait yet.
    starting: u32 = 0,
    /// The spares started, joined at stop.
    threads: aegis.bounded.Buffer(std.Thread),
};

state: aegis.BlockingGuarded(State),
/// The most spares that may be started.
cap: u32,
/// Moves on every post and at stop: what waiting threads wait on.
signal: std.atomic.Value(u32) = .init(0),

pub fn init(gpa: Allocator, processors: usize, cap: u16) Allocator.Error!Spares {
    var waiting = try fixed(*anyopaque, gpa, processors);
    errdefer waiting.deinit(noCleanup(*anyopaque));
    var threads = try fixed(std.Thread, gpa, cap);
    errdefer threads.deinit(noCleanup(std.Thread));
    return .{ .state = .init(.{ .waiting = waiting, .threads = threads }), .cap = cap };
}

pub fn deinit(sp: *Spares) void {
    const state = sp.state.teardown();
    assert(state.threads.len() == 0);
    state.waiting.deinit(noCleanup(*anyopaque));
    state.threads.deinit(noCleanup(std.Thread));
    sp.* = undefined;
}

/// A buffer of exactly `n` entries, which never grows.
fn fixed(comptime T: type, gpa: Allocator, n: usize) Allocator.Error!aegis.bounded.Buffer(T) {
    return aegis.bounded.Buffer(T).initAllocated(gpa, n, n) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CapacityExceeded => unreachable, // unreachable: the capacity is its own maximum
    };
}

/// What `Buffer` runs on each element it still holds when it is cleared: nothing, since a
/// processor is borrowed and a joined thread is spent.
fn noCleanup(comptime T: type) fn (*T) void {
    return struct {
        fn run(_: *T) void {}
    }.run;
}

fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Whether a thread will take a processor posted now: one waits here and
/// is not promised already, or is on its way, or one could be started
/// (`start` then starts it, running `body(context)`).
pub fn reserve(sp: *Spares, body: anytype, context: anytype) bool {
    var held = sp.state.acquireUncancelable(system());
    defer held.deinit(system());
    const state = held.value();
    if (state.idle + state.starting > state.waiting.len()) return true;
    if (state.threads.len() == sp.cap) return false;
    var thread = std.Thread.spawn(.{ .stack_size = if (builtin.sanitize_thread) (std.Thread.SpawnConfig{}).stack_size else 512 << 10 }, body, .{ context, null }) catch return false;
    state.threads.append(&thread) catch unreachable; // unreachable: fewer threads than `cap`, checked above
    state.starting += 1;
    return true;
}

/// Hands processor `p` to the next thread that waits; `reserve` promised one.
pub fn post(sp: *Spares, p: *anyopaque) void {
    var pointer = p;
    var held = sp.state.acquireUncancelable(system());
    held.value().waiting.append(&pointer) catch aegis.assert.invariant(false, "a processor was posted that no spare was promised for");
    _ = sp.signal.fetchAdd(1, .release);
    held.deinit(system());
    system().futexWake(u32, &sp.signal.raw, 1);
}

/// A processor for the calling thread, or null once `stopping` is set.
/// `fresh`: the thread was just started as a spare.
pub fn wait(sp: *Spares, stopping: *const std.atomic.Value(bool), fresh: bool) ?*anyopaque {
    var held = sp.state.acquireUncancelable(system());
    const state = held.value();
    if (fresh) state.starting -= 1;
    state.idle += 1;
    while (true) {
        var p: *anyopaque = undefined;
        if (state.waiting.pop(&p)) {
            state.idle -= 1;
            held.deinit(system());
            return p;
        } else |_| {}
        if (stopping.load(.acquire)) {
            state.idle -= 1;
            held.deinit(system());
            return null;
        }
        const seen = sp.signal.load(.acquire);
        held.deinit(system());
        system().futexWaitUncancelable(u32, &sp.signal.raw, seen);
        held = sp.state.acquireUncancelable(system());
    }
}

/// At stop: every waiting thread returns, and every started spare is joined.
pub fn stop(sp: *Spares) void {
    _ = sp.signal.fetchAdd(1, .release);
    system().futexWake(u32, &sp.signal.raw, std.math.maxInt(u32));
    while (true) {
        var thread: std.Thread = undefined;
        {
            // Joined outside the lock: a spare leaving needs it to see the stop.
            var held = sp.state.acquireUncancelable(system());
            defer held.deinit(system());
            held.value().threads.pop(&thread) catch return;
        }
        thread.join();
    }
}
