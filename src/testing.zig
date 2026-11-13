//! `reactor.testing`: an `Io` whose sockets are not the system's, as a
//! simulation's are not, for a test to run reactor's networking on. Over it
//! reactor's raw socket calls ask the seam: a socket's options are recorded
//! here, never set, a peek answers nothing, so the caller reads through its
//! `Io`, and a connect that would make its own socket (a bind, an option
//! before the connect) is made on the base's simulation. Every other call
//! goes to the base `Io` unchanged.
const std = @import("std");
const Io = std.Io;
const seam = @import("seam");
const aegis = @import("aegis");
const shakedown = @import("shakedown");

const Hooked = shakedown.Layer(seam.HookedState, .{ .netShutdown = seam.hookedShutdown });

/// A hooked `Io` over a base (a `Sim`'s, say). Made in place by `init`; it
/// must not move while its `io()` is in use.
pub const Seam = struct {
    hook: seam.Hook,
    hooked: Hooked,
    record: aegis.BlockingGuarded(Asked),

    /// What reactor asked of sockets: how many times options were set, and
    /// the last options asked.
    pub const Asked = struct { count: usize = 0, last: ?seam.Asked = null };

    pub fn init(s: *Seam, base: Io) void {
        s.* = .{ .hook = .{ .ctx = s, .options = options, .peek = peek, .connect = connect, .base = base }, .hooked = undefined, .record = .init(.{}) };
        s.hooked = .init(base, .{ .hook = &s.hook });
    }

    /// The `Io` the code under test runs on.
    pub fn io(s: *Seam) Io {
        return s.hooked.io();
    }

    /// What reactor asked of sockets so far.
    pub fn asked(s: *Seam) Asked {
        var held = s.record.acquireUncancelable(s.hook.base);
        defer held.deinit(s.hook.base);
        return held.value().*;
    }

    fn options(ctx: *anyopaque, _: Io.net.Socket.Handle, given: seam.Asked) void {
        const s: *Seam = @ptrCast(@alignCast(ctx)); // the hook's ctx is the Seam that made it
        s.told(given);
    }

    fn told(s: *Seam, given: seam.Asked) void {
        var held = s.record.acquireUncancelable(s.hook.base);
        defer held.deinit(s.hook.base);
        held.value().count += 1;
        held.value().last = given;
    }

    /// A connection reactor would make a socket of its own for: made on
    /// the simulation the base is of, bound as asked (`Sim.socketsOf`), its
    /// options recorded as `options`' are. A base that is not a
    /// simulation's has nothing to make it on.
    fn connect(ctx: *anyopaque, address: *const Io.net.IpAddress, made: seam.Made) Io.net.IpAddress.ConnectError!Io.net.Socket {
        const s: *Seam = @ptrCast(@alignCast(ctx)); // the hook's ctx is the Seam that made it
        const given = made.asked;
        if (given.nodelay != null or given.keepalive != null or given.send_buffer != null or given.receive_buffer != null or given.traffic_class != null) s.told(given);
        const sockets = shakedown.Sim.socketsOf(s.hook.base) orelse std.debug.panic("reactor.testing: a connect with a bind, an interface or an option before it, over a base that is not a simulation's: no system socket is made under a hooked Io, and the base has none to make", .{});
        return sockets.connect(address, .{
            .local = made.local_address,
            .reuse_address = made.reuse_address,
            .timeout = made.timeout,
            .interface = made.interface,
            .mode = made.mode,
            .protocol = made.protocol,
        });
    }

    fn peek(_: *anyopaque, _: Io.net.Socket.Handle) ?seam.Peek {
        return null;
    }
};
