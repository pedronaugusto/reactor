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

pub inline fn parked(records: *Records, task: *Task, processor: u16, bytes: usize) void {
    const record = &records.items[task.stack orelse return];
    var summary: Summary = @bitCast(record.summary.load(.monotonic));
    summary.state = .waiting;
    summary.processor = processor;
    summary.operation = if (task.operation) |operation| @intCast(@backingInt(operation)) else no_operation;
    summary.lane = if (task.lane) |lane| @intCast(@backingInt(lane)) else no_lane;
    // Stack watermarks saturate at 64 GiB, far above a task's usual mapping.
    summary.high_water = @max(summary.high_water, @min(bytes, std.math.maxInt(u36)));
    record.summary.store(@bitCast(summary), .monotonic);
}

pub inline fn release(records: *Records, task: *Task) void {
    records.items[task.stack.?].summary.store(@bitCast(Summary{}), .monotonic);
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
