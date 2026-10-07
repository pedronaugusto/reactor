//! Which descriptors have been closed since a loop registered them. A
//! readiness backend keeps a descriptor registered with its kernel poller
//! from its first wait until it is closed, across waits; the kernel drops a
//! registration when the descriptor closes, and the number may then come
//! back for another file. A close made through any loop (or announced with
//! `Loop.closing`) moves its descriptor's epoch, and a loop that finds a
//! record's epoch behind registers the descriptor afresh.
//!
//! Descriptors are the process's, so this table is too: a close through one
//! loop is seen by every loop. Descriptors share a slot when their numbers
//! do modulo its size, which only makes a loop register one again.
const std = @import("std");
const Io = std.Io;

const slots = 4096;

var epochs: [slots]std.atomic.Value(u32) = @splat(.init(0));

fn slot(fd: Io.File.Handle) usize {
    const key: u64 = switch (@typeInfo(Io.File.Handle)) {
        .pointer => @intFromPtr(fd) >> 2, // safe: a handle's value, hashed
        else => @as(u32, @bitCast(fd)),
    };
    return @intCast(key % slots);
}

/// Before `fd` is closed: every loop's record of it becomes stale.
pub fn bump(fd: Io.File.Handle) void {
    _ = epochs[slot(fd)].fetchAdd(1, .release);
}

/// The epoch a registration of `fd` made now belongs to.
pub fn epoch(fd: Io.File.Handle) u32 {
    return epochs[slot(fd)].load(.acquire);
}
