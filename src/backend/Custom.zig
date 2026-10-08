//! A backend given as an interface: reactor's seeded fake in its tests.
//! Operations cross it as untyped pointers to the loop's `Op` and to batch
//! storage; the implementation knows their types.
const Custom = @This();

const std = @import("std");
const Io = std.Io;
const Wait = @import("wait.zig").Wait;
const pending = @import("pending.zig");

context: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    submit: *const fn (context: *anyopaque, op: *anyopaque) error{ SystemResources, Unexpected }!void,
    cancel: *const fn (context: *anyopaque, op: *anyopaque) void,
    submitPending: *const fn (context: *anyopaque, token: pending.Token, operation: Io.Operation) error{ SystemResources, Unexpected }!void,
    cancelPending: *const fn (context: *anyopaque, token: pending.Token) void,
    /// Delivers completions to `sink`, waiting as `wait` allows.
    poll: *const fn (context: *anyopaque, wait: Wait, sink: Sink) void,
    /// From any thread: ends a `poll` that waits.
    wake: *const fn (context: *anyopaque) void,
};

/// Where `poll` delivers.
pub const Sink = struct {
    context: *anyopaque,
    complete: *const fn (context: *anyopaque, op: *anyopaque) void,
    completePending: *const fn (context: *anyopaque, token: pending.Token, outcome: pending.Outcome) void,
};

/// A custom backend keeps nothing in an operation.
pub const Scratch = void;
