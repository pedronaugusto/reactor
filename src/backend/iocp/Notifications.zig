//! Bounded job notifications. A record's key is its place in the table and
//! its generation, so queued messages after detach cannot reach a later
//! attachment.
const Notifications = @This();
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

const prefix: usize = 0xf000000000000000;
const generation_mask: usize = (1 << 20) - 1;
const capacity = 32;

pub const Message = struct { code: u32, process: u32 };

/// What a record's lock guards: whether it is attached, the owner's
/// identity, and the messages that have arrived for it.
const Mailbox = struct {
    occupied: bool = false,
    generation: u32 = 0,
    io: Io = undefined,
    messages: aegis.bounded.Ring(Message, capacity) = .init,
    overflow: bool = false,
};

pub const Record = struct {
    mailbox: aegis.BlockingGuarded(Mailbox) align(256) = .init(.{}),
    /// Signaled when a message arrives or the record is released.
    arrived: aegis.Condition = .init(),
    /// Its place in the table, which its key names.
    index: u32 = 0,

    /// What the kernel carries back with each of the job's messages: the
    /// record's place and its generation, so a message for an earlier
    /// attachment is told apart. No address is in it.
    pub fn key(record: *Record) usize {
        var held = record.mailbox.acquireUncancelable(system());
        defer held.deinit(system());
        return prefix | (@as(usize, record.index) << 20) | held.value().generation;
    }

    pub fn release(record: *Record) void {
        var held = record.mailbox.acquireUncancelable(system());
        defer held.deinit(system());
        held.value().occupied = false;
        record.arrived.broadcast(held.value().io);
    }

    pub const NextError = error{ Timeout, SystemResources, Unexpected } || Io.Cancelable;

    pub fn next(record: *Record, io: Io, timeout: Io.Timeout) NextError!Message {
        const deadline = timeout.toDeadline(io);
        var held = record.mailbox.acquireUncancelable(system());
        defer held.deinit(system());
        while (true) {
            if (try take(held.value())) |message| return message;
            record.arrived.wait(io, &held, deadline) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => return if (try take(held.value())) |message| message else error.Timeout,
                error.WaiterLimit => return error.SystemResources,
            };
        }
    }

    fn take(mailbox: *Mailbox) NextError!?Message {
        if (!mailbox.occupied) return error.Unexpected;
        var message: Message = undefined;
        if (mailbox.messages.pop(&message)) |_| return message else |_| {}
        if (mailbox.overflow) {
            mailbox.overflow = false;
            return error.SystemResources;
        }
        return null;
    }
};

records: []Record,

pub fn init(gpa: std.mem.Allocator, count: u16) std.mem.Allocator.Error!Notifications {
    const records = try gpa.alloc(Record, count);
    for (records, 0..) |*record, i| record.* = .{ .index = @intCast(i) };
    return .{ .records = records };
}

pub fn deinit(table: *Notifications, gpa: std.mem.Allocator) void {
    gpa.free(table.records);
    table.* = undefined;
}

pub fn acquire(table: *Notifications, io: Io) ?*Record {
    for (table.records) |*record| {
        var held = record.mailbox.acquireUncancelable(system());
        defer held.deinit(system());
        const mailbox = held.value();
        if (mailbox.occupied or mailbox.generation == generation_mask) continue;
        mailbox.* = .{ .occupied = true, .generation = mailbox.generation + 1, .io = io };
        return record;
    }
    return null;
}

/// Returns true for this table's key, including a retired generation.
pub fn dispatch(table: *Notifications, key: usize, process: usize, code: usize) bool {
    if (key & prefix != prefix) return false;
    const index = (key & ~prefix) >> 20;
    if (index >= table.records.len) return false;
    const record = &table.records[index];
    var held = record.mailbox.acquireUncancelable(system());
    defer held.deinit(system());
    const mailbox = held.value();
    if (!mailbox.occupied or key & generation_mask != mailbox.generation) return true;
    var message: Message = .{ .code = @truncate(code), .process = @truncate(process) };
    mailbox.messages.push(&message) catch {
        mailbox.overflow = true;
    };
    record.arrived.broadcast(mailbox.io);
    return true;
}

fn system() Io {
    return Io.Threaded.global_single_threaded.io();
}
