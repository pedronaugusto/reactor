//! A flag one thread raises and its owner clears: a wake, or a message to
//! another ring, under way, of which one is enough until it is taken.
const Raised = @This();

const aegis = @import("aegis");

const State = enum(u8) { clear, raised };

cell: aegis.Atomic(State) = .init(.clear),

/// Raises it; true when it was raised already, and the caller need do
/// nothing more.
pub fn raise(p: *Raised) bool {
    return p.cell.swap(.raised, .acq_rel) == .raised;
}

/// Whether it is raised.
pub fn raised(p: *const Raised) bool {
    return p.cell.load(.acquire) == .raised;
}

/// Taken: the next `raise` acts again.
pub fn clear(p: *Raised) void {
    p.cell.store(.clear, .release);
}
