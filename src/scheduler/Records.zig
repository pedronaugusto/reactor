//! Atomic task summaries. Dump readers never dereference a live task's
//! stack, and each stack index has one writer while its task runs.
const Records = @This();
const std = @import("std");
const Io = std.Io;
const Task = @import("Task.zig");
const op = @import("../backend/op.zig");
const Lanes = @import("../Lanes.zig");

pub const State = enum(u3) { free, ready, running, waiting, finished };
const no_operation = 15;
const no_lane = 7;
const Summary = packed struct(u64) {
    state: State = .free,
    processor: u16 = 0,
    kind: u2 = 0,
    operation: u4 = no_operation,
    lane: u3 = no_lane,
    high_water: u36 = 0,
};

pub const Record = struct {
    summary: std.atomic.Value(u64) = .init(@bitCast(Summary{})),
    spawned_at: std.atomic.Value(usize) = .init(0),

    pub fn highWater(record: *const Record) usize {
        const summary: Summary = @bitCast(record.summary.load(.monotonic));
        return summary.high_water;
    }
};

items: []Record,
/// The deepest park of every task that has ended or been trimmed.
retained: std.atomic.Value(usize) = .init(0),

pub fn init(gpa: std.mem.Allocator, count: u32) std.mem.Allocator.Error!Records {
    const items = try gpa.alloc(Record, count);
    for (items) |*record| record.* = .{};
    return .{ .items = items };
}

pub fn deinit(records: *Records, gpa: std.mem.Allocator) void {
    gpa.free(records.items);
    records.* = undefined;
}

pub inline fn created(records: *Records, task: *Task) void {
    const record = &records.items[task.stack.?];
    record.summary.store(@bitCast(Summary{ .kind = @intCast(@backingInt(task.kind)) }), .monotonic);
    record.spawned_at.store(task.spawned_at, .monotonic);
}

pub inline fn publish(records: *Records, task: *Task, processor: u16, state: State) void {
    const record = &records.items[task.stack orelse return];
    var summary: Summary = @bitCast(record.summary.load(.monotonic));
    summary.processor = processor;
    summary.state = state;
    record.summary.store(@bitCast(summary), .monotonic);
}

/// Notes a park `bytes` deep and returns the deepest park of this task since
/// its stack was last trimmed.
pub inline fn parked(records: *Records, task: *Task, processor: u16, bytes: usize) usize {
    const record = &records.items[task.stack.?];
    var summary: Summary = @bitCast(record.summary.load(.monotonic));
    summary.state = .waiting;
    summary.processor = processor;
    summary.operation = if (task.operation) |operation| @intCast(@backingInt(operation)) else no_operation;
    summary.lane = if (task.lane) |lane| @intCast(@backingInt(lane)) else no_lane;
    // Stack watermarks saturate at 64 GiB, far above a task's usual mapping.
    summary.high_water = @max(summary.high_water, @min(bytes, std.math.maxInt(u36)));
    record.summary.store(@bitCast(summary), .monotonic);
    return summary.high_water;
}

/// The task is forgotten: its deepest park stays in `deepest`.
pub inline fn release(records: *Records, task: *Task) void {
    const record = &records.items[task.stack.?];
    const summary: Summary = @bitCast(record.summary.load(.monotonic));
    if (summary.high_water > records.retained.load(.monotonic)) records.retain(summary.high_water);
    record.summary.store(@bitCast(Summary{}), .monotonic);
}

/// Pages below `resident` bytes from the top of the task's stack were given
/// back: its deepest park counts from there.
pub fn trimmed(records: *Records, task: *Task, resident: usize) void {
    const record = &records.items[task.stack.?];
    var summary: Summary = @bitCast(record.summary.load(.monotonic));
    records.retain(summary.high_water);
    summary.high_water = @min(summary.high_water, @min(resident, std.math.maxInt(u36)));
    record.summary.store(@bitCast(summary), .monotonic);
}

fn retain(records: *Records, bytes: usize) void {
    _ = records.retained.fetchMax(bytes, .monotonic);
}

/// The deepest park any task has made, ended or live.
pub fn deepest(records: *const Records) usize {
    var deepest_: usize = records.retained.load(.monotonic);
    for (records.items) |*record| deepest_ = @max(deepest_, record.highWater());
    return deepest_;
}

/// A streaming observation; tasks may change state while it is printed.
pub fn dump(records: *const Records, writer: *Io.Writer) Io.Writer.Error!void {
    for (records.items, 0..) |*record, i| {
        const summary: Summary = @bitCast(record.summary.load(.monotonic));
        if (summary.state == .free) continue;
        const operation = summary.operation;
        const lane = summary.lane;
        try writer.print("task={d} kind={s} state={s} worker={d} start=0x{x} parked_operation={s} lane={s} parked_stack={d}\n", .{
            i,
            @tagName(@as(Task.Kind, @fromBackingInt(summary.kind))),
            @tagName(summary.state),
            summary.processor,
            record.spawned_at.load(.monotonic),
            if (operation == no_operation) "none" else @tagName(@as(std.meta.Tag(op.Kind), @fromBackingInt(@intCast(operation)))),
            if (lane == no_lane) "none" else @tagName(@as(Lanes.Lane, @fromBackingInt(@intCast(lane)))),
            summary.high_water,
        });
    }
}
