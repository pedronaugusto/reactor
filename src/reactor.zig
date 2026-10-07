//! reactor: an evented `std.Io` for Zig, and the loop under it.
//!
//! `Runtime` is a complete `std.Io` on each kernel's own completion queue,
//! with stackful tasks on a work-stealing scheduler; it can run with no
//! thread of its own, driven by a host's loop. `Loop` is one thread's
//! completion engine, usable alone inside any host loop.

/// One thread's completion engine: no threads, no allocation after `init`.
pub const Loop = @import("Loop.zig");
/// N loops plus stackful tasks: the `std.Io`.
pub const Runtime = @import("Runtime.zig");
