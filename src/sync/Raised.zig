//! A flag one side raises and another takes or clears: a wake under way,
//! a message to another ring, a task started, a handshake's side. Every
//! read and write names its ordering: some are plain hand-offs
//! (acquire and release), some sequentially consistent handshakes.
const Raised = @This();

const std = @import("std");
const aegis = @import("aegis");

const Order = std.builtin.AtomicOrder;

const State = enum(u8) { clear, raised };

cell: aegis.Atomic(State) = .init(.clear),

/// Raises it; true when it was raised already, and the caller need do
/// nothing more.
pub fn raise(p: *Raised, comptime order: Order) bool {
    return p.cell.swap(.raised, order) == .raised;
}

/// Whether it was raised, cleared in the same step.
pub fn take(p: *Raised, comptime order: Order) bool {
    return p.cell.swap(.clear, order) == .raised;
}

/// Whether it is raised.
pub fn raised(p: *const Raised, comptime order: Order) bool {
    return p.cell.load(order) == .raised;
}

/// Cleared: the next `raise` acts again.
pub fn clear(p: *Raised, comptime order: Order) void {
    p.cell.store(.clear, order);
}
