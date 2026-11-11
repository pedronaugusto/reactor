//! A look at a socket that neither waits nor takes anything: the one call
//! on a socket no `Io` slot makes, behind reactor's seam.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const seam = @import("seam");

const os = builtin.target.os.tag;

/// What a look at an idle socket finds.
pub const Peek = seam.Peek;

/// Look at a socket without waiting and without taking anything from it:
/// one `recv` with `MSG_PEEK` and `MSG_DONTWAIT`, a few times cheaper than
/// a readiness check through the `Io`. Null where there is no answer: on
/// Windows and WASI, which have no such call, and under an `Io` whose
/// sockets are not the system's (a test's hook answers then, null by
/// default). A caller takes null as its cue to read through the `Io`.
pub fn peek(io: Io, handle: Io.net.Socket.Handle) ?Peek {
    if (seam.hookOf(io)) |hook| return hook.peek(hook.ctx, handle);
    if (os == .windows or os == .wasi) return null;
    var byte: [1]u8 = undefined;
    while (true) {
        // recvfrom(2) writes the peeked byte; only its count is read
        const rc = std.posix.system.recvfrom(handle, &byte, byte.len, std.posix.MSG.PEEK | std.posix.MSG.DONTWAIT, null, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return if (rc == 0) .closed else .readable,
            .AGAIN => return .idle,
            .INTR => continue,
            else => return .closed,
        }
    }
}
