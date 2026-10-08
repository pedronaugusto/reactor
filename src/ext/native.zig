//! How an extension tells reactor's runtime from any other `Io`, and how
//! often it could not: an `Io` wrapping a runtime (a tracing layer,
//! shakedown's `Layer`) takes the path every other `Io` takes.
const std = @import("std");
const Io = std.Io;

const Core = @import("../runtime/Core.zig");
const slots = @import("../runtime/slots.zig");
const Scheduler = @import("../Scheduler.zig");

var taken: std.atomic.Value(u64) = .init(0);

/// The runtime `io` is; null for any other `Io`, which is counted.
pub fn runtimeOf(io: Io) ?*Core {
    if (io.vtable == &slots.vtable) return Core.of(io.userdata);
    _ = taken.fetchAdd(1, .monotonic);
    return null;
}

/// The runtime `io` is when the calling thread is running one of its
/// tasks, which the native paths need: they wait on the task's processor.
pub fn taskRuntime(core: *Core) bool {
    const p = Scheduler.processor() orelse return false;
    return p.scheduler == &core.scheduler and p.current != null;
}

/// Times an extension took the path for an `Io` that is not a runtime,
/// process-wide.
pub fn fallbacks() u64 {
    return taken.load(.monotonic);
}
