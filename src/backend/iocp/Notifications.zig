//! Bounded job notifications. Integer keys include the record's generation,
//! so queued messages after detach cannot reach a later attachment.
const Notifications = @This();
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

const prefix: usize = 0xf000000000000000;
const generation_mask: usize = (1 << 20) - 1;
const capacity = 32;

pub const Message = struct { code: u32, process: u32 };

/// What a record's lock guards: the owner's identity, and the messages that
/// have arrived for it.
const Mailbox = struct {
    generation: u32 = 0,
    io: Io = undefined,
    messages: aegis.bounded.Ring(Message, capacity) = .init,
    overflow: bool = false,
};

pub const Record = struct {
    occupied: std.atomic.Value(bool) align(256) = .init(false),
    ready: Io.Event = .unset,
    mailbox: aegis.BlockingGuarded(Mailbox) = .init(.{}),

    pub fn key(record: *Record) usize {
        const address = @intFromPtr(record); // safe: encoded as an integer, decoded only after a table range check
        std.debug.assert(address >> 48 == 0);
        std.debug.assert(address & 255 == 0);
        var held = record.mailbox.acquireUncancelable(system());
        defer held.deinit(system());
        return prefix | ((address >> 8) << 20) | held.value().generation;
    }

    pub fn release(record: *Record) void {
        var held = record.mailbox.acquireUncancelable(system());
        defer held.deinit(system());
        record.occupied.store(false, .release);
        record.ready.set(held.value().io);
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
        var held = record.mailbox.acquireUncancelable(system());
        defer held.deinit(system());
        const mailbox = held.value();
        if (!record.occupied.load(.acquire)) return error.Unexpected;
        var message: Message = undefined;
        if (mailbox.messages.pop(&message)) |_| return message else |_| {}
        if (mailbox.overflow) {
            mailbox.overflow = false;
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
        var held = record.mailbox.acquireUncancelable(system());
        const mailbox = held.value();
        if (mailbox.generation == generation_mask) {
            held.deinit(system());
            record.occupied.store(false, .release);
            continue;
        }
        mailbox.generation += 1;
        mailbox.io = io;
        mailbox.messages = .init;
        mailbox.overflow = false;
        record.ready.reset();
        held.deinit(system());
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
    var held = record.mailbox.acquireUncancelable(system());
    defer held.deinit(system());
    const mailbox = held.value();
    if (!record.occupied.load(.acquire) or key & generation_mask != mailbox.generation) return true;
    var message: Message = .{ .code = @truncate(code), .process = @truncate(process) };
    mailbox.messages.push(&message) catch {
        mailbox.overflow = true;
    };
    record.ready.set(mailbox.io);
    return true;
}

fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}
