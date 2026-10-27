//! A signal set once, by one side, that the other waits for: an errand
//! sent to another processor, done.
const Done = @This();

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

state: aegis.BlockingGuarded(bool) = .init(false),
changed: aegis.Condition = .init(),

pub fn set(d: *Done, io: Io) void {
    var held = d.state.acquireUncancelable(io);
    defer held.deinit(io);
    held.value().* = true;
    d.changed.broadcast(io);
}

/// Waits until it is set, whatever a cancel says: the other side is sure
/// to set it.
pub fn waitUncancelable(d: *Done, io: Io) void {
    var held = d.state.acquireUncancelable(io);
    defer held.deinit(io);
    while (!held.value().*) d.changed.waitUncancelable(io, &held, .none) catch unreachable; // unreachable: one waiter, with no deadline
}
