//! reactor: an evented `std.Io` for Zig, and the loop under it.
//!
//! `Runtime` is a complete `std.Io` on each kernel's own completion queue,
//! with stackful tasks on a work-stealing scheduler; it can run with no
//! thread of its own, driven by a host's loop. `Loop` is one thread's
//! completion engine, usable alone inside any host loop.
//!
//! The extensions take any `Io` and say what `std.Io` cannot: waits on
//! kernel objects, blocking calls off the workers, signals, and the
//! networking calls `std.Io` cannot keep everywhere. On a runtime they are
//! native; on any other `Io` they take the best path its slots allow.
const ext = @import("ext.zig");

/// One thread's completion engine: no threads, no allocation after `init`.
pub const Loop = @import("Loop.zig");
/// N loops plus stackful tasks: the `std.Io`.
pub const Runtime = @import("Runtime.zig");

/// What `wait` and `waitAny` wait on.
pub const Waitable = ext.wait.Waitable;
pub const WaitError = ext.wait.WaitError;
pub const wait = ext.wait.wait;
pub const waitAny = ext.wait.waitAny;
/// A wake-up any thread can send to a task waiting on it.
pub const Wake = ext.Wake;
/// A process a wait reports once it has ended; it never reaps.
pub const Process = ext.Process;
/// A Windows job object's messages.
pub const Job = ext.Job;
/// Calls that can take milliseconds, off the workers.
pub const blocking = ext.blocking.blocking;
/// Signals and console control events, to several listeners each.
pub const Signals = ext.Signals;
/// Connect with a timeout, bounded lookups, aborts, deadlines, receivers.
pub const net = ext.net;
/// Times an extension took the path for an `Io` that is not a runtime.
pub const fallbacks = ext.native.fallbacks;
