//! Bounded job notifications. Integer keys include the record's generation,
//! so queued messages after detach cannot reach a later attachment.
const Notifications = @This();
const std = @import("std");
const Io = std.Io;

const prefix: usize = 0xf000000000000000;
const generation_mask: usize = (1 << 20) - 1;
const capacity = 32;

pub const Message = struct { code: u32, process: u32 };

pub const Record = struct {
    occupied: std.atomic.Value(bool) align(256) = .init(false),
    lock: Io.Mutex = .init,
    ready: Io.Event = .unset,
    generation: u32 = 0,
    io: Io = undefined,
    messages: [capacity]Message = undefined,
    first: usize = 0,
    count: usize = 0,
    overflow: bool = false,

    pub fn key(record: *Record) usize {
        const address = @intFromPtr(record); // safe: encoded as an integer, decoded only after a table range check
        std.debug.assert(address >> 48 == 0);
        std.debug.assert(address & 255 == 0);
        return prefix | ((address >> 8) << 20) | record.generation;
    }

    pub fn release(record: *Record) void {
        record.lock.lockUncancelable(system());
        record.occupied.store(false, .release);
        record.ready.set(record.io);
        record.lock.unlock(system());
    }

    pub const NextError = error{ Timeout, SystemResources, Unexpected } || Io.Cancelable;

    pub fn next(record: *Record, io: Io, timeout: Io.Timeout) NextError!Message {
        const deadline = timeout.toDeadline(io);
        while (true) {
            if (try record.take()) |message| return message;
            record.ready.waitTimeout(io, deadline) catch |err| {
                if (try record.take()) |message| return message;
                if (err == error.Canceled) return error.Canceled;
                if (deadline.toDurationFromNow(io)) |remaining| if (remaining.raw.nanoseconds <= 0) return error.Timeout;
                continue;
            };
        }
    }

    fn take(record: *Record) NextError!?Message {
        record.lock.lockUncancelable(system());
        defer record.lock.unlock(system());
        if (!record.occupied.load(.acquire)) return error.Unexpected;
        if (record.count != 0) {
            const message = record.messages[record.first];
            record.first = (record.first + 1) % capacity;
            record.count -= 1;
            return message;
        }
        if (record.overflow) {
            record.overflow = false;
            return error.SystemResources;
        }
        record.ready.reset();
        return null;
    }
};

records: []Record,

pub fn init(gpa: std.mem.Allocator, count: u16) std.mem.Allocator.Error!Notifications {
    const records = try gpa.alloc(Record, count);
    for (records) |*record| record.* = .{};
    return .{ .records = records };
}

pub fn deinit(table: *Notifications, gpa: std.mem.Allocator) void {
    for (table.records) |*record| std.debug.assert(!record.occupied.load(.acquire));
    gpa.free(table.records);
    table.* = undefined;
}

pub fn acquire(table: *Notifications, io: Io) ?*Record {
    for (table.records) |*record| {
        if (record.occupied.cmpxchgStrong(false, true, .acquire, .monotonic) != null) continue;
        record.lock.lockUncancelable(system());
        if (record.generation == generation_mask) {
            record.lock.unlock(system());
            record.occupied.store(false, .release);
            continue;
        }
        record.generation += 1;
        record.io = io;
        record.first = 0;
        record.count = 0;
        record.overflow = false;
        record.ready.reset();
        record.lock.unlock(system());
        return record;
    }
    return null;
}

/// Returns true for this table's key, including a retired generation.
pub fn dispatch(table: *Notifications, key: usize, process: usize, code: usize) bool {
    if (key & prefix != prefix) return false;
    const address = ((key & ~prefix) >> 20) << 8;
    const start = @intFromPtr(table.records.ptr); // safe: bounds for the encoded record address
    if (address < start or address - start >= table.records.len * @sizeOf(Record)) return false;
    if ((address - start) % @sizeOf(Record) != 0) return false;
    const record = &table.records[(address - start) / @sizeOf(Record)];
    record.lock.lockUncancelable(system());
    defer record.lock.unlock(system());
    if (!record.occupied.load(.acquire) or key & generation_mask != record.generation) return true;
    if (record.count == capacity) {
        record.overflow = true;
    } else {
        record.messages[(record.first + record.count) % capacity] = .{ .code = @truncate(code), .process = @truncate(process) };
        record.count += 1;
    }
    record.ready.set(record.io);
    return true;
}

fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}
