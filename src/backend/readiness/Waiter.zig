//! Who waits on a readiness backend: an operation (a waiter lives in its
//! scratch) or a batch entry, and how it waits.
const Waiter = @This();

const records = @import("records.zig");
const KernelTime = @import("../kernel_time.zig").KernelTime;
const Direction = records.Direction;

prev: ?*Waiter = null,
next: ?*Waiter = null,
/// Who holds this waiter: an operation (in its scratch, where the backend
/// finds the operation again by the waiter's place in it), or a batch
/// entry.
owner: Owner = .batch,
record: u32 = records.none,
place: Place = .none,
direction: Direction = .read,
how: How = .call,
/// A connect that put its socket in non-blocking mode puts it back.
restore: bool = false,
clock: Clock = .real,
/// A timer's deadline on its clock.
deadline: KernelTime = .fromRaw(0),

pub const Place = enum(u2) { none, record, timer, done };

pub const Owner = enum(u1) { batch, operation };

/// The clocks with a kernel timer of their own.
pub const Clock = enum(u1) { real, boot };

/// How an operation is made on a descriptor that is not ready yet.
pub const How = enum(u2) {
    /// A call that never waits (a socket's): made at once, and again on
    /// each readiness until it does not report `EAGAIN`.
    call,
    /// A descriptor in blocking mode: called only once it is ready.
    ready_then_call,
    /// Readiness alone (a `wait`).
    readiness,
    /// A connect under way: its outcome once the socket is writable.
    connect,
};
