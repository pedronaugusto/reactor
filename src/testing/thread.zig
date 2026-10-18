//! The calling thread, read where the read happens.
const std = @import("std");

/// The calling thread's id, read on the thread that calls. std keeps it in a
/// thread-local on Linux, and within one function an optimized build computes
/// a thread-local's address once (on aarch64 a register read it merges
/// freely), so a task that an `Io` call moved to another thread would read the
/// thread it left. Never inlined: each call computes the address on its own
/// thread, and the value it returns is a load, which no caller can assume.
pub noinline fn now() std.Thread.Id {
    return std.Thread.getCurrentId();
}
