//! The seam in front of reactor's raw socket calls, the ones no `Io` slot
//! makes: setting a socket's options and peeking at it. What a test makes of
//! a call instead, and how a raw call finds the test's hook in the `Io` it
//! was given.
//!
//! A module of its own, imported by reactor and by `reactor.testing` and
//! exported by neither, as airlock's seam is: production reactor asks only
//! whether an `Io` carries a hook, and the test module is the one place
//! that builds one. The `Io` carries it as a layer whose `netShutdown` is
//! `hookedShutdown` and whose state is a `HookedState`. A layered vtable is
//! a copy per layer type, so a raw call compares the slot, never the
//! vtable's address.
const std = @import("std");
const Io = std.Io;

/// What a look at an idle socket finds (`reactor.net.peek`).
pub const Peek = enum {
    /// Nothing waiting: the peer has said nothing.
    idle,
    /// Bytes waiting.
    readable,
    /// The peer closed it, or it failed.
    closed,
};

/// The options asked of a socket, as the hook is told them: each null where
/// it was not asked; keepalive as on or off, its probes left out.
pub const Asked = struct {
    nodelay: ?bool = null,
    keepalive: ?bool = null,
    send_buffer: ?u32 = null,
    receive_buffer: ?u32 = null,
    traffic_class: ?u8 = null,
};

/// Routes reactor's raw socket calls to a test. Under a hooked `Io` no raw
/// call runs: a simulation's handles are not the system's.
pub const Hook = struct {
    ctx: *anyopaque,
    /// The options asked of a socket, for the test to record or check.
    options: *const fn (ctx: *anyopaque, handle: Io.net.Socket.Handle, asked: Asked) void,
    /// A look at a socket: null is no answer, and the caller reads through
    /// its `Io` instead.
    peek: *const fn (ctx: *anyopaque, handle: Io.net.Socket.Handle) ?Peek,
    /// The `Io` a std-level `netShutdown` through the hooked layer goes to.
    base: Io,
};

/// The state of the layer that carries a hook.
pub const HookedState = struct { hook: *const Hook };

/// The hooked layer's `netShutdown`: a std-level shutdown passes through to
/// the hook's base.
pub fn hookedShutdown(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    // std.Io hands its vtable's functions the userdata the Io was made with, and an Io whose netShutdown is hookedShutdown carries a HookedState
    const state: *HookedState = @ptrCast(@alignCast(userdata.?));
    const base = state.hook.base;
    return base.vtable.netShutdown(base.userdata, handle, how);
}

/// The hook `io` carries, if it carries one: one compare.
pub fn hookOf(io: Io) ?*const Hook {
    if (io.vtable.netShutdown != &hookedShutdown) return null;
    // as above, the netShutdown just compared being hookedShutdown
    const state: *const HookedState = @ptrCast(@alignCast(io.userdata.?));
    return state.hook;
}
