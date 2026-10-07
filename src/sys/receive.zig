//! A receive that never waits: what a reader that waited for readiness
//! itself makes, so a socket that turned out not to be ready costs no
//! blocked thread. Errors are std's, as `Io.Threaded` reports them.
const std = @import("std");
const posix = std.posix;
const Io = std.Io;

pub const Error = Io.Operation.NetRead.Error;

/// The bytes received now, 0 at end of stream; null when none are there.
pub fn now(socket: posix.socket_t, buffer: []u8) Error!?usize {
    while (true) {
        const rc = posix.system.recvfrom(socket, buffer.ptr, buffer.len, posix.MSG.DONTWAIT, null, null);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return null,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN, .PIPE => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NETDOWN => return error.NetworkDown,
            .ACCES => return error.AccessDenied,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}
