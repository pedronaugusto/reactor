//! A backend given as an interface: reactor's seeded fake in its tests.
//! Operations cross it as the backends' `op.Op`, batch operations by token.
//! The implementation keeps a `Custom` in its own record and finds the
//! record from it by `@fieldParentPtr`, as std's interfaces do.
const Custom = @This();

const std = @import("std");
const Io = std.Io;
const Wait = @import("wait.zig").Wait;
const pending = @import("pending.zig");
const op = @import("op.zig");

vtable: *const VTable,

pub const VTable = struct {
    submit: *const fn (c: *Custom, o: *op.Op) error{ SystemResources, Unexpected }!void,
    cancel: *const fn (c: *Custom, o: *op.Op) void,
    submitPending: *const fn (c: *Custom, token: pending.Token, operation: Io.Operation) error{ SystemResources, Unexpected }!void,
    cancelPending: *const fn (c: *Custom, token: pending.Token) void,
    /// Delivers completions to `sink`, waiting as `wait` allows.
    poll: *const fn (c: *Custom, wait: Wait, sink: *Sink) void,
    /// From any thread: ends a `poll` that waits.
    wake: *const fn (c: *Custom) void,
};

/// Where `poll` delivers, kept in the record that takes the completions.
pub const Sink = struct {
    complete: *const fn (s: *Sink, o: *op.Op) void,
    completePending: *const fn (s: *Sink, token: pending.Token, outcome: pending.Outcome) void,
};
