//! `reactor.testing`: an `Io` whose sockets are not the system's, as a
//! simulation's are not, for a test to run reactor's networking on. Over it
//! reactor's raw socket calls ask the seam: a socket's options are recorded
//! here, never set, and a peek answers nothing, so the caller reads through
//! its `Io`. Every other call goes to the base `Io` unchanged.
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
        s.* = .{ .hook = .{ .ctx = s, .options = options, .peek = peek, .base = base }, .hooked = undefined, .record = .init(.{}) };
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
        var held = s.record.acquireUncancelable(s.hook.base);
        defer held.deinit(s.hook.base);
        held.value().count += 1;
        held.value().last = given;
    }

    fn peek(_: *anyopaque, _: Io.net.Socket.Handle) ?seam.Peek {
        return null;
    }
};
