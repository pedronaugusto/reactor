//! Threads without a processor: workers whose processor was handed on while
//! they sat in a blocking call, and the spares the monitor starts on demand
//! to take such a processor. A handed processor waits here until a thread
//! takes it; a thread waits here until a processor comes or the runtime
//! stops. Everything is sized at `init`; threads are the system's, started
//! with no allocator.
const Spares = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The processors waiting for a thread (opaque `*Processor`s).
queue: []*anyopaque,
queued: u32 = 0,
/// Threads waiting here for a processor.
idle: u32 = 0,
/// Threads started that have not come to wait yet.
starting: u32 = 0,
/// Spares started, of `threads.len`.
threads: []std.Thread,
started: u32 = 0,
lock: Io.Mutex = .init,
/// Moves on every post and at stop: what waiting threads wait on.
signal: std.atomic.Value(u32) = .init(0),

pub fn init(gpa: Allocator, processors: usize, cap: u16) Allocator.Error!Spares {
    const queue = try gpa.alloc(*anyopaque, processors);
    errdefer gpa.free(queue);
    return .{ .queue = queue, .threads = try gpa.alloc(std.Thread, cap) };
}

pub fn deinit(sp: *Spares, gpa: Allocator) void {
    assert(sp.started == 0);
    gpa.free(sp.threads);
    gpa.free(sp.queue);
    sp.* = undefined;
}

fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Whether a thread will take a processor posted now: one waits here and
/// is not promised already, or is on its way, or one could be started
/// (`start` then starts it, running `body(context)`).
pub fn reserve(sp: *Spares, body: anytype, context: anytype) bool {
    sp.lock.lockUncancelable(system());
    defer sp.lock.unlock(system());
    if (sp.idle + sp.starting > sp.queued) return true;
    if (sp.started == sp.threads.len) return false;
    const thread = std.Thread.spawn(.{ .stack_size = 512 << 10 }, body, .{ context, null }) catch return false;
    sp.threads[sp.started] = thread;
    sp.started += 1;
    sp.starting += 1;
    return true;
}

/// Hands processor `p` to the next thread that waits; `reserve` promised one.
pub fn post(sp: *Spares, p: *anyopaque) void {
    sp.lock.lockUncancelable(system());
    sp.queue[sp.queued] = p;
    sp.queued += 1;
    _ = sp.signal.fetchAdd(1, .release);
    sp.lock.unlock(system());
    system().futexWake(u32, &sp.signal.raw, 1);
}

/// A processor for the calling thread, or null once `stopping` is set.
/// `fresh`: the thread was just started as a spare.
pub fn wait(sp: *Spares, stopping: *const std.atomic.Value(bool), fresh: bool) ?*anyopaque {
    sp.lock.lockUncancelable(system());
    if (fresh) sp.starting -= 1;
    sp.idle += 1;
    while (true) {
        if (sp.queued > 0) {
            sp.queued -= 1;
            const p = sp.queue[sp.queued];
            sp.idle -= 1;
            sp.lock.unlock(system());
            return p;
        }
        if (stopping.load(.acquire)) {
            sp.idle -= 1;
            sp.lock.unlock(system());
            return null;
        }
        const seen = sp.signal.load(.acquire);
        sp.lock.unlock(system());
        system().futexWaitUncancelable(u32, &sp.signal.raw, seen);
        sp.lock.lockUncancelable(system());
    }
}

/// At stop: every waiting thread returns, and every started spare is joined.
pub fn stop(sp: *Spares) void {
    _ = sp.signal.fetchAdd(1, .release);
    system().futexWake(u32, &sp.signal.raw, std.math.maxInt(u32));
    for (sp.threads[0..sp.started]) |t| t.join();
    sp.started = 0;
}
