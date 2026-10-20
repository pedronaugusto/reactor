//! A socket's messages with their control data, made now and never waited
//! for: `recvmsg` and `sendmsg` with `MSG_DONTWAIT`, every errno the kernel
//! answers kept as its own error. POSIX.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Io = std.Io;

/// What the kernel can answer a message with, beside what any socket call
/// meets. `BadMessage` (`EBADMSG`), `KeyExpired` (`EKEYEXPIRED`, Linux) and
/// `InputOutput` (`EIO`) are a kernel layer under the socket speaking:
/// Linux's record layer says with them that a record failed to open, that
/// its receive path has stopped until new keys are installed, and that the
/// next record is not data and the read gave no control room to say its type.
pub const Error = error{
    BadMessage,
    KeyExpired,
    InputOutput,
    MessageTooBig,
    ConnectionResetByPeer,
    SocketUnconnected,
    ConnectionTimedOut,
    NetworkDown,
    SystemResources,
    AccessDenied,
} || Io.UnexpectedError;

pub const Received = struct {
    /// Bytes of data; 0 at the end of the stream when there was room for any.
    data_len: usize,
    /// Bytes of control data the kernel wrote into the caller's room.
    control_len: usize,
    /// The control data was more than the room, and was cut (`MSG_CTRUNC`).
    control_truncated: bool,
};

/// A send never raises `SIGPIPE` where the flag exists; Darwin has none, and
/// its sockets say so themselves (`SO_NOSIGPIPE`).
const no_signal: u32 = if (@hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0;

/// What one `recvmsg` takes now; null when nothing is there.
pub fn receive(socket: posix.socket_t, data: []const []u8, control: []u8) Error!?Received {
    var iovecs: [max_pieces]posix.iovec = undefined;
    const count = gather(posix.iovec, &iovecs, data);
    var msg: posix.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = @intCast(count),
        .control = if (control.len == 0) null else control.ptr,
        .controllen = @intCast(control.len),
        .flags = 0,
    };
    while (true) {
        const rc = posix.system.recvmsg(socket, &msg, posix.MSG.DONTWAIT);
        switch (posix.errno(rc)) {
            .SUCCESS => return .{
                .data_len = @intCast(rc),
                .control_len = if (control.len == 0) 0 else @intCast(msg.controllen),
                .control_truncated = msg.flags & posix.MSG.CTRUNC != 0,
            },
            .INTR => continue,
            .AGAIN => return null,
            else => |e| return failed(e),
        }
    }
}

/// What one `sendmsg` takes now, in bytes of data; null when the socket has
/// no room. Control data goes with the first byte sent, or alone when
/// `data` is empty.
pub fn send(socket: posix.socket_t, data: []const []const u8, control: []const u8) Error!?usize {
    var iovecs: [max_pieces]posix.iovec_const = undefined;
    const count = gather(posix.iovec_const, &iovecs, data);
    const msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = @intCast(count),
        .control = if (control.len == 0) null else control.ptr,
        .controllen = @intCast(control.len),
        .flags = 0,
    };
    while (true) {
        const rc = posix.system.sendmsg(socket, &msg, posix.MSG.DONTWAIT | no_signal);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return null,
            .PIPE => return error.SocketUnconnected,
            else => |e| return failed(e),
        }
    }
}

/// The most pieces of data one call takes; the rest wait for the next.
pub const max_pieces = 16;

fn gather(comptime Vec: type, out: *[max_pieces]Vec, data: anytype) usize {
    var count: usize = 0;
    for (data) |piece| {
        if (piece.len == 0) continue;
        if (count == max_pieces) break;
        out[count] = .{ .base = piece.ptr, .len = piece.len };
        count += 1;
    }
    return count;
}

fn failed(e: posix.E) Error {
    if (comptime @hasField(posix.E, "KEYEXPIRED")) {
        if (e == .KEYEXPIRED) return error.KeyExpired;
    }
    return switch (e) {
        .BADMSG => error.BadMessage,
        .IO => error.InputOutput,
        .MSGSIZE => error.MessageTooBig,
        .NOBUFS, .NOMEM => error.SystemResources,
        .NOTCONN => error.SocketUnconnected,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NETDOWN => error.NetworkDown,
        .ACCES, .PERM => error.AccessDenied,
        else => posix.unexpectedErrno(e),
    };
}

test "the kernel's answers keep their names" {
    try std.testing.expectEqual(error.BadMessage, failed(.BADMSG));
    try std.testing.expectEqual(error.InputOutput, failed(.IO));
    if (builtin.os.tag == .linux) try std.testing.expectEqual(error.KeyExpired, failed(.KEYEXPIRED));
}
