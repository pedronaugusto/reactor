//! One constant Io selection, so the actual suites' global aliases compile.
//! Its test-only layer forwards every call to the currently measured runtime.
const std = @import("std");
const shakedown = @import("shakedown");
pub const reactor = @import("reactor");
const Proxy = shakedown.Layer(u8, .{});
var proxy: Proxy = .{ .state = 0, .base = undefined };
pub const io: std.Io = .{ .userdata = &proxy.state, .vtable = &Proxy.vtable };

pub fn select(actual: std.Io) void {
    proxy.base = actual;
}
