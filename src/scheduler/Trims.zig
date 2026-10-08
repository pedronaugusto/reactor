//! Idle stack trimming on the parked task's owning loop. The timer pins
//! the task there until resume, so no scanner can touch a resumable stack.
const Trims = @This();
const std = @import("std");
const Io = std.Io;
const Task = @import("Task.zig");
const Loop = @import("../Loop.zig");
const Stacks = @import("../fiber/Stacks.zig");

const Record = struct {
    op: Loop.Op = .{ .kind = .{ .timer = .{ .raw = .zero, .clock = .awake } }, .callback = fired },
    task: ?*Task = null,
    stacks: *Stacks = undefined,
    counter: *std.atomic.Value(u64) = undefined,
    keep_from: usize = 0,
    live: usize = 0,
};
records: []Record,

pub fn init(gpa: std.mem.Allocator, count: u32) std.mem.Allocator.Error!Trims {
    const records = try gpa.alloc(Record, count);
    for (records) |*record| record.* = .{};
    return .{ .records = records };
}
pub fn deinit(trims: *Trims, gpa: std.mem.Allocator) void {
    for (trims.records) |*record| std.debug.assert(record.task == null);
    gpa.free(trims.records);
    trims.* = undefined;
}

/// Called off-stack before publishing the task's wake hook. Timers are
/// best effort when the loop is full; retaining pages is always safe.
pub fn arm(trims: *Trims, loop: *Loop, task: *Task, stacks: *Stacks, counter: *std.atomic.Value(u64), sp: usize) void {
    const record = &trims.records[task.stack.?];
    std.debug.assert(record.task == null);
    record.task = task;
    record.stacks = stacks;
    record.counter = counter;
    record.keep_from = sp -| 256;
    record.live = task.stack_top - sp;
    record.op.kind = .{ .timer = .{ .raw = loop.clock.now(.awake).addDuration(.fromSeconds(1)), .clock = .awake } };
    task.pins += 1;
    task.trim_pending = true;
    loop.submit(&record.op) catch {
        record.task = null;
        task.pins -= 1;
        task.trim_pending = false;
    };
}

/// On the same loop, before the task resumes. Remove the pointer before
/// canceling, because wheel cancellation delivers its callback immediately.
pub fn beforeRun(trims: *Trims, loop: *Loop, task: *Task) void {
    const record = &trims.records[task.stack.?];
    std.debug.assert(record.task == task);
    record.task = null;
    loop.cancel(&record.op);
    task.pins -= 1;
    task.trim_pending = false;
}

fn fired(_: *Loop, op: *Loop.Op) void {
    const record: *Record = @alignCast(@fieldParentPtr("op", op)); // safe: the init-reserved record owns this timer
    const task = record.task orelse return;
    op.result.timer catch return;
    record.stacks.trim(task.stack.?, record.keep_from);
    task.resident_water = record.live;
    _ = record.counter.fetchAdd(1, .monotonic);
    // Keep the pin until resume: foreign wakes must route to this loop,
    // and the task's timer record cannot be reused on another processor.
}
