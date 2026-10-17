//! A timer on the loop alone, run to its delivery as fast or as slow as the
//! host is.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Loop = @import("../Loop.zig");

/// Runs `l`, holding one timer due at `due`, until the timer is delivered,
/// and expects it delivered once and not before it was due: a run that ended
/// before `due` delivered nothing. A host slow enough to pass `due` before
/// the first run (an emulated CPU, a loaded runner) has it at once.
pub fn expectDelivered(l: *Loop, due: Io.Clock.Timestamp) !void {
    const sys = Io.Threaded.global_single_threaded.io();
    const early = try l.run(.nowait);
    if (Io.Clock.Timestamp.compare(.now(sys, .awake), .lt, due)) try testing.expectEqual(@as(u32, 0), early);
    if (early != 0) return testing.expectEqual(@as(u32, 1), early);
    try testing.expect(l.nextTimeout() != null);
    try testing.expectEqual(@as(u32, 1), try l.run(.once));
}
