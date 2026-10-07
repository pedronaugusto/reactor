//! Batches: `batchAwaitAsync`, `batchAwaitConcurrent` and `batchCancel`.
//!
//! A submitted operation goes to the kernel and its storage becomes a
//! `pending` entry that keeps the operation packed (backend/pending.zig).
//! Completions arrive on the processor whose kernel queue holds them; the
//! task that owns the batch is held on that processor while any are
//! pending, so the processor is the only one touching the batch's lists
//! then, and the task is never running when it does.
//!
//! The timeout rule: `batchAwaitConcurrent` never returns `Timeout` while
//! the kernel holds an operation. It cancels every pending one and waits
//! for each to come back first; one that completed meanwhile is moved to
//! `completed` and the call succeeds; cancelled ones return to `submitted`,
//! whole, so a second await submits them again.
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const backend = @import("../backend.zig");
const pending = backend.pending;
const Loop = @import("../Loop.zig");
const loop_internal = @import("../loop/internal.zig");
const Task = @import("../scheduler/Task.zig");
const Processor = @import("../Scheduler.zig").Processor;
const Scheduler = @import("../Scheduler.zig");
const perform = @import("perform.zig");

const Index = Io.Operation.OptionalIndex;

/// What `Batch.userdata` holds while operations are pending: the owning
/// task, or, while it waits, its `Waiter`; and where cancelled operations go.
const Owner = packed struct(usize) {
    waiting: bool = false,
    to_submitted: bool = false,
    to_unused: bool = false,
    address: @Int(.unsigned, @bitSizeOf(usize) - 3) = 0,

    fn of(batch: *Io.Batch) Owner {
        return @bitCast(@intFromPtr(batch.userdata)); // safe: only this file stores there, an `Owner`
    }

    fn store(o: Owner, batch: *Io.Batch) void {
        batch.userdata = @ptrFromInt(@as(usize, @bitCast(o)));
    }

    fn pointer(o: Owner) usize {
        return @as(usize, o.address) << 3;
    }

    fn task(o: Owner) *Task {
        if (o.waiting) {
            const w: *Waiter = @ptrFromInt(o.pointer());
            return w.task;
        }
        return @ptrFromInt(o.pointer());
    }

    fn at(address: usize) @Int(.unsigned, @bitSizeOf(usize) - 3) {
        assert(address & 7 == 0);
        return @intCast(address >> 3);
    }
};

const Until = enum { any, empty };

const Waiter = struct {
    hook: Task.Hook = .{ .cancel = cancelHook },
    task: *Task,
    processor: *Processor,
    scheduler: *Scheduler,
    batch: *Io.Batch,
    until: Until,
    woken: bool = false,
    outcome: enum { completed, canceled, timed_out } = .completed,
    timer: Loop.Op = .{ .kind = .{ .timer = undefined } },
    timed: bool = false,

    fn wake(w: *Waiter, outcome: @FieldType(Waiter, "outcome")) void {
        if (w.woken) return;
        w.woken = true;
        w.outcome = outcome;
        w.scheduler.ready(w.task, .completed);
    }

    /// From any thread; acts on the batch's processor.
    fn cancelHook(hook: *Task.Hook, t: *Task) void {
        const w: *Waiter = @alignCast(@fieldParentPtr("hook", hook)); // safe: the field belongs to this record
        if (Scheduler.processor() == w.processor) return w.wake(.canceled);
        w.processor.pushCancel(t);
    }

    fn timedOut(l: *Loop, o: *Loop.Op) void {
        _ = l;
        const w: *Waiter = @alignCast(@fieldParentPtr("timer", o)); // safe: the field belongs to this record
        if (o.result.timer) |_| w.wake(.timed_out) else |_| {}
    }
};

pub fn awaitAsync(s: *Scheduler, borrowed: Io, batch: *Io.Batch) Io.Cancelable!void {
    _ = Scheduler.current() orelse return borrowed.vtable.batchAwaitAsync(borrowed.userdata, batch);
    drain(s, borrowed, batch, false) catch |err| switch (err) {
        error.ConcurrencyUnavailable => unreachable, // unreachable: only asked for concurrency
        error.Canceled => |e| return e,
    };
    if (ready(batch)) return;
    switch (try wait(s, batch, .any, null)) {
        .completed => {},
        .timed_out => unreachable, // unreachable: no timer armed
    }
}

pub fn awaitConcurrent(s: *Scheduler, borrowed: Io, batch: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    _ = Scheduler.current() orelse return borrowed.vtable.batchAwaitConcurrent(borrowed.userdata, batch, timeout);
    try drain(s, borrowed, batch, true);
    if (ready(batch)) return;
    const p = Scheduler.processor().?;
    switch (try wait(s, batch, .any, perform.deadline(p, timeout))) {
        .completed => return,
        .timed_out => {},
    }
    // Nothing completed in time: take every pending operation back from
    // the kernel before reporting it.
    drainAll(s, batch, .to_submitted);
    if (batch.completed.head != .none) return;
    return error.Timeout;
}

pub fn cancel(s: *Scheduler, borrowed: Io, batch: *Io.Batch) void {
    _ = Scheduler.current() orelse return borrowed.vtable.batchCancel(borrowed.userdata, batch);
    if (batch.pending.head != .none) drainAll(s, batch, .to_unused);
    batch.userdata = null;
}

fn ready(batch: *const Io.Batch) bool {
    return batch.completed.head != .none or batch.pending.head == .none;
}

/// Cancels every pending operation and waits until the kernel has given
/// all of them back.
fn drainAll(s: *Scheduler, batch: *Io.Batch, where: enum { to_submitted, to_unused }) void {
    const p = Scheduler.processor().?;
    var owner = Owner.of(batch);
    switch (where) {
        .to_submitted => owner.to_submitted = true,
        .to_unused => owner.to_unused = true,
    }
    owner.store(batch);
    var index = batch.pending.head;
    while (index != .none) : (index = batch.storage[index.toIndex()].pending.node.next) {
        loop_internal.cancelPending(&p.loop, .of(batch, index.toIndex()));
    }
    while (batch.pending.head != .none) _ = wait(s, batch, .empty, null) catch unreachable; // unreachable: not cancelable
    batch.userdata = null;
}

/// Parks until the batch has a completion (`any`) or nothing pending
/// (`empty`); `any` waits are cancelable, and end at `deadline`.
fn wait(s: *Scheduler, batch: *Io.Batch, until: Until, deadline: ?Io.Clock.Timestamp) error{Canceled}!enum { completed, timed_out } {
    const p = Scheduler.processor().?;
    const t = p.current.?;
    var w: Waiter = .{ .task = t, .processor = p, .scheduler = s, .batch = batch, .until = until };
    if (until == .any) try t.enterWait(&w.hook);
    var owner = Owner.of(batch);
    const saved = owner;
    owner.waiting = true;
    owner.address = Owner.at(@intFromPtr(&w)); // safe: read back by the processor's completions while this frame waits
    owner.store(batch);
    if (deadline) |d| {
        w.timer.kind = .{ .timer = d };
        w.timer.callback = Waiter.timedOut;
        if (p.loop.submit(&w.timer)) |_| w.timed = true else |_| w.wake(.timed_out);
    }
    if (!w.woken) Scheduler.park(null);
    if (w.timed) p.loop.cancel(&w.timer);
    t.leaveWait();
    // The task owns the batch again, unless nothing is pending any more
    // (the completions have let go of the task already).
    if (batch.pending.head == .none) {
        batch.userdata = null;
    } else {
        var after = Owner.of(batch);
        after.waiting = false;
        after.address = saved.address;
        after.store(batch);
    }
    return switch (w.outcome) {
        .completed => .completed,
        .timed_out => .timed_out,
        .canceled => t.acknowledge(),
    };
}

/// Hands every submitted operation to the kernel, or completes it at
/// once (nothing to move; device control, which has no evented form).
fn drain(s: *Scheduler, borrowed: Io, batch: *Io.Batch, concurrency: bool) (Io.ConcurrentError || Io.Cancelable)!void {
    _ = s;
    const p = Scheduler.processor().?;
    const t = p.current.?;
    var index = batch.submitted.head;
    errdefer batch.submitted.head = index;
    while (index != .none) {
        const i = index.toIndex();
        const storage = &batch.storage[i];
        const next = storage.submission.node.next;
        const operation = storage.submission.operation;
        if (trivial(operation)) |result| {
            complete(batch, index, result);
        } else if (!loop_internal.canPend(&p.loop, operation)) {
            // No evented form here (device control; on IOCP a handle opened
            // for synchronous calls): std's own call, which may wait.
            if (concurrency) return error.ConcurrencyUnavailable;
            const result = try borrowed.vtable.operate(borrowed.userdata, operation);
            complete(batch, index, result);
        } else {
            toPending(batch, t, index, operation);
            const fd = perform.descriptorOf(.{ .io = operation }).?;
            p.hold(fd);
            const now: ?pending.Outcome = loop_internal.submitPending(&p.loop, .of(batch, i), operation) catch .{ .result = failure(operation) };
            // Finished at once (IOCP's skip on success), or refused.
            if (now) |outcome| {
                p.release(fd);
                removePending(batch, index);
                complete(batch, index, switch (outcome) {
                    .result => |result| result,
                    .canceled => closedUnder(operation),
                });
                release(batch);
            }
        }
        index = next;
    }
    batch.submitted = .{ .head = .none, .tail = .none };
}

fn trivial(operation: Io.Operation) ?Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => |o| if (total(o.data) == 0) .{ .file_read_streaming = 0 } else null,
        else => null,
    };
}

fn total(data: []const []u8) usize {
    var n: usize = 0;
    for (data) |d| n += d.len;
    return n;
}

/// The result of an operation the kernel could not take.
fn failure(operation: Io.Operation) Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => .{ .file_read_streaming = error.SystemResources },
        .file_write_streaming => .{ .file_write_streaming = error.SystemResources },
        .net_read => .{ .net_read = error.SystemResources },
        .net_write => .{ .net_write = error.SystemResources },
        .net_receive => .{ .net_receive = .{ error.SystemResources, 0 } },
        .net_send => .{ .net_send = .{ error.SystemResources, 0 } },
        .device_io_control => device("INSUFFICIENT_RESOURCES"),
    };
}

/// The result of an operation the kernel cancelled although nobody asked
/// this batch to: its descriptor was closed under it.
fn closedUnder(tag: Io.Operation.Tag) Io.Operation.Result {
    return switch (tag) {
        .file_read_streaming => .{ .file_read_streaming = error.SocketUnconnected },
        .file_write_streaming => .{ .file_write_streaming = error.BrokenPipe },
        .net_read => .{ .net_read = error.SocketUnconnected },
        .net_write => .{ .net_write = error.SocketUnconnected },
        .net_receive => .{ .net_receive = .{ error.SocketUnconnected, 0 } },
        .net_send => .{ .net_send = .{ error.SocketUnconnected, 0 } },
        .device_io_control => device("CANCELLED"),
    };
}

/// Windows: device control's result, a status block. Elsewhere device
/// control never waits in a batch.
fn device(comptime status: []const u8) Io.Operation.Result {
    if (builtin.os.tag == .windows) return .{ .device_io_control = .{ .u = .{ .Status = @field(std.os.windows.NTSTATUS, status) }, .Information = 0 } };
    unreachable; // unreachable: device control waits in a batch only on Windows
}

// The batch's lists.

fn toPending(batch: *Io.Batch, t: *Task, index: Index, operation: Io.Operation) void {
    const storage = &batch.storage[index.toIndex()];
    const was_empty = batch.pending.head == .none;
    storage.* = .{ .pending = .{ .node = .{ .prev = batch.pending.tail, .next = .none }, .tag = operation, .userdata = undefined } };
    pending.pack(&storage.pending, operation);
    switch (batch.pending.tail) {
        .none => batch.pending.head = index,
        else => |tail| batch.storage[tail.toIndex()].pending.node.next = index,
    }
    batch.pending.tail = index;
    if (was_empty) {
        // Held on this processor until the kernel has given everything back.
        t.pins += 1;
        const owner: Owner = .{ .address = Owner.at(@intFromPtr(t)) }; // safe: read back by `Owner.task`
        owner.store(batch);
    }
}

fn removePending(batch: *Io.Batch, index: Index) void {
    const node = batch.storage[index.toIndex()].pending.node;
    switch (node.prev) {
        .none => batch.pending.head = node.next,
        else => |prev| batch.storage[prev.toIndex()].pending.node.next = node.next,
    }
    switch (node.next) {
        .none => batch.pending.tail = node.prev,
        else => |next| batch.storage[next.toIndex()].pending.node.prev = node.prev,
    }
}

fn complete(batch: *Io.Batch, index: Index, result: Io.Operation.Result) void {
    switch (batch.completed.tail) {
        .none => batch.completed.head = index,
        else => |tail| batch.storage[tail.toIndex()].completion.node.next = index,
    }
    batch.storage[index.toIndex()] = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
    batch.completed.tail = index;
}

fn resubmit(batch: *Io.Batch, index: Index, operation: Io.Operation) void {
    switch (batch.submitted.tail) {
        .none => batch.submitted.head = index,
        else => |tail| batch.storage[tail.toIndex()].submission.node.next = index,
    }
    batch.storage[index.toIndex()] = .{ .submission = .{ .node = .{ .next = .none }, .operation = operation } };
    batch.submitted.tail = index;
}

fn unuse(batch: *Io.Batch, index: Index) void {
    const tail = batch.unused.tail;
    switch (tail) {
        .none => batch.unused.head = index,
        else => batch.storage[tail.toIndex()].unused.next = index,
    }
    batch.storage[index.toIndex()] = .{ .unused = .{ .prev = tail, .next = .none } };
    batch.unused.tail = index;
}

/// The batch has nothing pending: let go of its task.
fn release(batch: *Io.Batch) void {
    if (batch.pending.head != .none) return;
    const owner = Owner.of(batch);
    if (owner.address == 0) return;
    owner.task().pins -= 1;
    if (!owner.waiting) batch.userdata = null;
}

/// A completion from the kernel, on the batch's processor: the sink every
/// processor's loop delivers batch completions to.
pub fn completed(context: *anyopaque, token: pending.Token, outcome: pending.Outcome) void {
    _ = context;
    const batch = token.batch();
    const index: Index = .fromIndex(token.index());
    const owner = Owner.of(batch);
    const entry = batch.storage[index.toIndex()].pending;
    Scheduler.processor().?.release(perform.descriptorOf(.{ .io = pending.unpack(&entry) }).?);
    removePending(batch, index);
    switch (outcome) {
        .result => |result| complete(batch, index, result),
        .canceled => if (owner.to_submitted) {
            resubmit(batch, index, pending.unpack(&entry));
        } else if (owner.to_unused) {
            unuse(batch, index);
        } else {
            complete(batch, index, closedUnder(entry.tag));
        },
    }
    release(batch);
    if (!owner.waiting) return;
    const w: *Waiter = @ptrFromInt(owner.pointer());
    switch (w.until) {
        .any => if (ready(batch)) w.wake(.completed),
        .empty => if (batch.pending.head == .none) w.wake(.completed),
    }
}
