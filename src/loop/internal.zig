//! What reactor's runtime does to a loop beyond its public interface:
//! build one over a given backend and clock, and hand a batch's
//! operations to its backend.
const std = @import("std");
const Io = std.Io;

const Loop = @import("../Loop.zig");
const backend = @import("../backend.zig");
const clock = @import("../clock.zig");

/// A loop over `b` and `source`: the runtime's tests give it the seeded
/// fake and a virtual clock.
pub fn initWith(l: *Loop, b: backend.Backend, source: clock.Source, max_ops: u32) void {
    l.* = .{
        .backend = b,
        .clock = source,
        .wheel = .init(source.ticks()),
        .max_ops = max_ops,
        .owner = std.Thread.getCurrentId(),
    };
}

/// Where the loop's batch completions go.
pub fn setBatchSink(l: *Loop, sink: Loop.BatchSink) void {
    l.batch_sink = sink;
}

/// One operation of a batch, kept in the batch's own storage.
pub fn submitPending(l: *Loop, token: backend.pending.Token, operation: Io.Operation) backend.SubmitError!void {
    l.in_flight += 1;
    errdefer l.in_flight -= 1;
    try l.backend.submitPending(token, operation);
}

pub fn cancelPending(l: *Loop, token: backend.pending.Token) void {
    l.backend.cancelPending(token);
}
