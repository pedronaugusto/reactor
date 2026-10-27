//! Idle stack trimming on each parked task's owning loop. One timer per
//! processor serves its candidates; quick reuse only unlinks a record.
const Trims = @This();
const std = @import("std");
const Io = std.Io;
const Task = @import("Task.zig");
const Loop = @import("../Loop.zig");
const Records = @import("Records.zig");
const shuttle = @import("shuttle");

const Record = struct {
    task: ?*Task = null,
    bucket: *Bucket = undefined,
    next: ?*Record = null,
    prev: ?*Record = null,
    queued: bool = false,
    deadline: Io.Timestamp = .zero,
    keep_from: usize = 0,
};
const Bucket = struct {
    op: Loop.Op = .{ .backend = .{ .kind = .{ .timer = .{ .raw = .zero, .clock = .awake } } } },
    completion: Loop.Completion = .{ .run = fired },
    loop: ?*Loop = null,
    head: ?*Record = null,
    tail: ?*Record = null,
    armed: bool = false,
    records: *Records = undefined,
    counter: *std.atomic.Value(u64) = undefined,
    /// The stacks, which a task names by its number.
    pool: *const shuttle.Pool = undefined,

    fn schedule(bucket: *Bucket) void {
        if (bucket.armed) return;
        const first = bucket.head orelse return;
        bucket.op.backend.kind = .{ .timer = .{ .raw = first.deadline, .clock = .awake } };
        bucket.op.completion = &bucket.completion;
        bucket.loop.?.submit(&bucket.op) catch return;
        bucket.armed = true;
    }
};
records: []Record,
buckets: []Bucket,

pub fn init(gpa: std.mem.Allocator, count: u32, processors: u16) std.mem.Allocator.Error!Trims {
    const records = try gpa.alloc(Record, count);
    errdefer gpa.free(records);
    const buckets = try gpa.alloc(Bucket, processors);
    for (records) |*record| record.* = .{};
    for (buckets) |*bucket| bucket.* = .{};
    return .{ .records = records, .buckets = buckets };
}
pub fn deinit(trims: *Trims, gpa: std.mem.Allocator) void {
    for (trims.records) |*record| std.debug.assert(record.task == null);
    // A shared timer can outlast its last candidate. Stop it while its
    // loop is still alive; canceled callbacks do not inspect any stack.
    for (trims.buckets) |*bucket| {
        std.debug.assert(bucket.head == null);
        if (bucket.armed) bucket.loop.?.cancel(&bucket.op);
    }
    gpa.free(trims.buckets);
    gpa.free(trims.records);
    trims.* = undefined;
}

/// Off-stack before publishing the wake hook: retain the task on its loop
/// and append in monotonic deadline order. Timer submission is best effort.
pub fn arm(trims: *Trims, loop: *Loop, processor: u16, task: *Task, records: *Records, pool: *const shuttle.Pool, counter: *std.atomic.Value(u64), sp: usize) void {
    const record = &trims.records[task.stack.?.raw()];
    const bucket = &trims.buckets[processor];
    std.debug.assert(record.task == null);
    bucket.loop = loop;
    bucket.records = records;
    bucket.pool = pool;
    bucket.counter = counter;
    record.* = .{
        .task = task,
        .bucket = bucket,
        .prev = bucket.tail,
        .queued = true,
        .deadline = loop.clock.now(.awake).addDuration(.fromSeconds(1)),
        .keep_from = sp -| 256,
    };
    if (bucket.tail) |tail| tail.next = record else bucket.head = record;
    bucket.tail = record;
    task.pins += 1;
    task.execution.trim_pending = true;
    bucket.schedule();
}

/// Before resume on the pinned loop: remove its candidate and release the
/// pin. The shared timer remains armed for its original deadline.
pub fn beforeRun(trims: *Trims, loop: *Loop, task: *Task) void {
    const record = &trims.records[task.stack.?.raw()];
    std.debug.assert(record.task == task);
    std.debug.assert(record.bucket.loop == loop);
    if (record.queued) unlink(record);
    record.task = null;
    task.pins -= 1;
    task.execution.trim_pending = false;
}

fn unlink(record: *Record) void {
    const bucket = record.bucket;
    if (record.prev) |prev| prev.next = record.next else bucket.head = record.next;
    if (record.next) |next| next.prev = record.prev else bucket.tail = record.prev;
    record.next = null;
    record.prev = null;
    record.queued = false;
}

fn fired(c: *Loop.Completion, loop: *Loop, op: *Loop.Op) void {
    const bucket: *Bucket = @alignCast(@fieldParentPtr("completion", c)); // safe: the init-reserved bucket owns this timer
    bucket.armed = false;
    op.backend.result.timer catch return;
    const now = loop.clock.now(.awake);
    while (bucket.head) |record| {
        if (record.deadline.nanoseconds > now.nanoseconds) break;
        unlink(record);
        const task = record.task.?;
        bucket.pool.stackOf(task.stack.?.raw()).discard(record.keep_from);
        bucket.records.trimmed(task, task.stack_top - record.keep_from);
        _ = bucket.counter.fetchAdd(1, .monotonic);
        // The pin survives trimming until resume: foreign wakes still
        // route here, and no other processor reuses this record.
    }
    bucket.schedule();
}
