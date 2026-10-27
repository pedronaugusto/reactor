//! A file's bytes sent to a socket by the kernel, never through the
//! program's memory: one `sendfile`, made now. Linux and Darwin; `supported`
//! is false elsewhere.
//!
//! No call takes a flag to keep it from waiting, so whether one waits is the
//! socket's mode: in non-blocking mode a socket with no room answers
//! `would_block`, in blocking mode the call waits for the room it needs
//! (`room` bounds it).
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Io = std.Io;

const is_darwin = builtin.os.tag.isDarwin();

pub const supported = builtin.os.tag == .linux or is_darwin;

/// Whether a send must name where in the file it starts: Darwin's call
/// never moves the file's own position, so only a positional reader is sent
/// there.
pub const needs_offset = builtin.os.tag.isDarwin();

/// The most one call is asked to send: what Linux moves at most in one call
/// (and Darwin's length is an `off_t` its kernel checks against `INT_MAX`).
pub const max_count: usize = 0x7ffff000;

/// What the kernel answers beside what a write to a socket meets.
pub const Error = error{
    ConnectionResetByPeer,
    SocketUnconnected,
    ConnectionTimedOut,
    NetworkDown,
    SystemResources,
    /// Reading the file failed.
    InputOutput,
} || Io.UnexpectedError;

pub const Sent = union(enum) {
    /// Bytes of the file sent; 0 when the file had none left at the offset.
    sent: usize,
    /// The socket, in non-blocking mode, had no room.
    would_block,
    /// The kernel sends no file to this socket this way, or not this file
    /// (a pipe, a terminal, a socket that is not a stream); the caller
    /// copies through memory instead.
    unsupported,
};

/// One `sendfile` of up to `count` bytes of `file` to `socket`, from
/// `offset` or, with null (Linux only), from the file's own position, which
/// the kernel moves past what it sent.
pub fn send(socket: Io.net.Socket.Handle, file: Io.File.Handle, offset: ?u64, count: usize) Error!Sent {
    if (comptime !supported) @compileError("sendfile is Linux's and Darwin's");
    std.debug.assert(count > 0);
    std.debug.assert(count <= max_count);
    if (comptime is_darwin) return sendDarwin(socket, file, offset.?, count);
    return sendLinux(socket, file, offset, count);
}

fn sendLinux(socket: Io.net.Socket.Handle, file: Io.File.Handle, offset: ?u64, count: usize) Error!Sent {
    var off: posix.off_t = if (offset) |o| std.math.cast(posix.off_t, o) orelse return .unsupported else 0;
    const at: ?*posix.off_t = if (offset != null) &off else null;
    while (true) {
        const rc = posix.system.sendfile(socket, file, at, count);
        switch (posix.errno(rc)) {
            .SUCCESS => return .{ .sent = @intCast(rc) },
            .INTR => continue,
            .AGAIN => return .would_block,
            // The file cannot be mapped for it, or is no file at an offset
            // (a pipe, a terminal), or the socket takes no spliced pages.
            .INVAL, .NOSYS, .SPIPE, .NXIO, .OPNOTSUPP => return .unsupported,
            else => |e| return failed(e),
        }
    }
}

fn sendDarwin(socket: Io.net.Socket.Handle, file: Io.File.Handle, offset: u64, count: usize) Error!Sent {
    const off = std.math.cast(posix.off_t, offset) orelse return .unsupported;
    while (true) {
        // On return `len` holds what was sent, also when the call was cut
        // short by a signal or by the socket's room.
        var len: posix.off_t = @intCast(count);
        const rc = std.c.sendfile(file, socket, off, &len, null, 0);
        const e = posix.errno(rc);
        if (e != .SUCCESS and len > 0 and (e == .INTR or e == .AGAIN)) return .{ .sent = @intCast(len) };
        switch (e) {
            .SUCCESS => return .{ .sent = @intCast(len) },
            .INTR => continue,
            .AGAIN => return .would_block,
            // Not a regular file, not a stream socket, or a file system
            // that has no such path.
            .INVAL, .NOTSOCK, .OPNOTSUPP, .NOSYS => return .unsupported,
            else => return failed(e),
        }
    }
}

fn failed(e: posix.E) Error {
    return switch (e) {
        .PIPE, .NOTCONN => error.SocketUnconnected,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NETDOWN => error.NetworkDown,
        .NOBUFS, .NOMEM => error.SystemResources,
        .IO => error.InputOutput,
        else => posix.unexpectedErrno(e),
    };
}

/// Whether `socket` is in blocking mode.
pub fn blocking(socket: Io.net.Socket.Handle) error{Unexpected}!bool {
    const nonblock: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    while (true) {
        const rc = posix.system.fcntl(socket, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @as(usize, @intCast(rc)) & nonblock == 0,
            .INTR => continue,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

/// The most a send to `socket` in blocking mode is asked for once the
/// socket is writable, so that it does not wait on the peer: a quarter of
/// the send buffer as the kernel counts it, at least a page. A writable
/// socket has a third of its buffer free on Linux (half of what is queued);
/// Linux counts the buffer doubled, its own bookkeeping included.
pub fn room(socket: Io.net.Socket.Handle) error{Unexpected}!usize {
    var size: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    switch (posix.errno(posix.system.getsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDBUF, @ptrCast(&size), &len))) { // aegis: boundary: SO_SNDBUF writes one int
        .SUCCESS => {},
        else => |e| return posix.unexpectedErrno(e),
    }
    return @max(@as(usize, @intCast(@max(size, 0))) / 4, 4096);
}
