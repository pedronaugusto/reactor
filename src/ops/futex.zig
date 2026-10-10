//! The futex wait table: buckets of waiters keyed by address, one lock per
//! bucket. A waiter is a parked task or a thread outside the runtime (which
//! waits on a kernel futex of its own), so a wake from either side reaches
//! the other.
//!
//! A task inserts itself under the bucket lock and the lock is released
//! only once the task is off its stack, so a wake can never resume a task
//! still switching away. A timed wait arms a timer on the task's processor
//! and holds the task there until it has disarmed it.
const std = @import("std");
const aegis = @import("aegis");
const assert = std.debug.assert;
const Io = std.Io;

const Task = @import("../scheduler/Task.zig");
const Scheduler = @import("../Scheduler.zig");
const perform = @import("perform.zig");

pub const bucket_count = 1024;

pub const Table = struct {
    buckets: [bucket_count]Bucket = @splat(.init(.{})),

    fn bucket(table: *Table, ptr: *const u32) *Bucket {
        const address: usize = @intFromPtr(ptr); // safe: hashed, never dereferenced
        const h = (address >> 2) *% 0x9E3779B97F4A7C15;
        return &table.buckets[@intCast(h >> (@bitSizeOf(usize) - 10))];
    }
};

/// A bucket's waiters, oldest first. Its sections are a few link stores:
/// the spin lock never covers a park, a wake or a call out.
const Chain = struct {
    head: ?*Waiter = null,
    tail: ?*Waiter = null,

    fn append(c: *Chain, w: *Waiter) void {
        w.next = null;
        w.prev = c.tail;
        if (c.tail) |t| t.next = w else c.head = w;
        c.tail = w;
        w.linked = true;
    }

    fn remove(c: *Chain, w: *Waiter) void {
        if (w.prev) |p| p.next = w.next else c.head = w.next;
        if (w.next) |n| n.prev = w.prev else c.tail = w.prev;
        w.next = null;
        w.prev = null;
        w.linked = false;
    }
};

const Bucket = aegis.Guarded(Chain);

const Outcome = enum(u8) { waiting, woken, canceled, timed_out };

const Waiter = struct {
    next: ?*Waiter = null,
    prev: ?*Waiter = null,
    ptr: *const u32,
    linked: bool = false,
    outcome: Outcome = .waiting,
    /// The parked task, or null for a thread outside the runtime.
    task: ?*Task,
    /// A thread's: set to 1 when it is woken.
    word: std.atomic.Value(u32) = .init(0),
    bucket: *Bucket,
    scheduler: *Scheduler,
    hook: Task.Hook = .{ .cancel = cancelHook },
    deadline: perform.Deadline = .{ .fire = timedOut },

    /// A cancel of the waiting task: out of the bucket, and runnable.
    fn cancelHook(hook: *Task.Hook, t: *Task) void {
        const w: *Waiter = @alignCast(@fieldParentPtr("hook", hook)); // safe: the field belongs to this record
        var held = w.bucket.acquire();
        const was = w.linked;
        if (was) {
            held.value().remove(w);
            w.outcome = .canceled;
        }
        held.deinit();
        if (was) w.scheduler.ready(t, .woken);
    }

    fn timedOut(d: *perform.Deadline) void {
        const w: *Waiter = @alignCast(@fieldParentPtr("deadline", d)); // safe: the field belongs to this record
        var held = w.bucket.acquire();
        const was = w.linked;
        if (was) {
            held.value().remove(w);
            w.outcome = .timed_out;
        }
        held.deinit();
        if (was) w.scheduler.ready(w.task.?, .completed);
    }
};

/// The parked task's guard is released once it is off its stack, which still holds the guard.
fn unlockAfterPark(context: *anyopaque, t: *Task) void {
    _ = t;
    const held: *Bucket.Guard = @ptrCast(@alignCast(context)); // safe: `wait` passed its guard
    held.deinit();
}

/// Waits while `ptr.*` is `expected`, until a wake, `timeout`, a cancel
/// (when `cancelable`), or spuriously. Only `error.Canceled` is reported.
pub fn wait(s: *Scheduler, table: *Table, ptr: *const u32, expected: u32, timeout: Io.Timeout, cancelable: bool) error{Canceled}!void {
    const b = table.bucket(ptr);
    const p = Scheduler.processor() orelse return waitThread(s, b, ptr, expected, timeout, cancelable);
    const t = p.current orelse return waitThread(s, b, ptr, expected, timeout, cancelable);
    var w: Waiter = .{ .ptr = ptr, .task = t, .bucket = b, .scheduler = s };
    if (cancelable) try t.enterWait(&w.hook);
    var held = b.acquire();
    if (@atomicLoad(u32, ptr, .seq_cst) != expected) {
        held.deinit();
        t.leaveWait();
        s.spend();
        return;
    }
    held.value().append(&w);
    if (perform.deadline(p, timeout)) |deadline| {
        if (!w.deadline.arm(s, deadline)) {
            // No room for a timer: return at once, a spurious wake.
            held.value().remove(&w);
            held.deinit();
            t.leaveWait();
            return;
        }
    }
    Scheduler.park(.{ .func = unlockAfterPark, .context = &held });
    // Back on the processor that armed the timer: disarm it there.
    w.deadline.disarm();
    t.leaveWait();
    if (w.outcome == .canceled) return t.acknowledge();
}

/// A thread outside the runtime waits on a kernel futex of its own. A
/// thread `Io.Threaded` runs a task on (a lane's) is cancelled by
/// `Threaded`'s own mechanism.
fn waitThread(s: *Scheduler, b: *Bucket, ptr: *const u32, expected: u32, timeout: Io.Timeout, cancelable: bool) error{Canceled}!void {
    var w: Waiter = .{ .ptr = ptr, .task = null, .bucket = b, .scheduler = s };
    var held = b.acquire();
    if (@atomicLoad(u32, ptr, .seq_cst) != expected) {
        held.deinit();
        return;
    }
    held.value().append(&w);
    held.deinit();
    const sys = Scheduler.system();
    const outcome: error{Canceled}!void = if (cancelable)
        sys.futexWaitTimeout(u32, &w.word.raw, 0, timeout.toDeadline(sys))
    else
        sys.futexWaitUncancelable(u32, &w.word.raw, 0);
    held = b.acquire();
    const still = w.linked;
    if (still) held.value().remove(&w);
    held.deinit();
    // A waker unlinked it and will set the word: wait for that, so the
    // waker never writes to a frame that is gone.
    if (!still) while (w.word.load(.acquire) == 0) sys.futexWaitUncancelable(u32, &w.word.raw, 0);
    return outcome;
}

/// Wakes up to `max` waiters on `ptr`, oldest first.
pub fn wake(table: *Table, ptr: *const u32, max: u32) void {
    if (max == 0) return;
    const b = table.bucket(ptr);
    var woken: ?*Waiter = null;
    var last: ?*Waiter = null;
    var n: u32 = 0;
    var held = b.acquire();
    var it = held.value().head;
    while (it) |w| {
        it = w.next;
        if (w.ptr != ptr) continue;
        held.value().remove(w);
        w.outcome = .woken;
        if (last) |l| l.next = w else woken = w;
        last = w;
        n += 1;
        if (n == max) break;
    }
    held.deinit();
    // Off the bucket, each waiter is now ours alone until we wake it.
    while (woken) |w| {
        woken = w.next;
        if (w.task) |t| {
            w.scheduler.ready(t, .woken);
        } else {
            w.word.store(1, .release);
            Scheduler.system().futexWake(u32, &w.word.raw, 1);
        }
    }
}
