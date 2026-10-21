//! A stream socket's messages with their control data, over any `Io`, with
//! what the kernel answers kept apart.
//!
//! std carries control data on a stream's read and write
//! (`Io.Operation.net_read` and `net_write`), but their errors are std's, and
//! a layer the kernel runs under a socket answers in errnos std has no name
//! for. Linux's record layer (kTLS) takes a record's type as a control
//! message on a send (`TLS_SET_RECORD_TYPE`) and gives one back on a receive
//! (`TLS_GET_RECORD_TYPE`), and says a record failed to open (`BadMessage`),
//! that its receive path has stopped until new keys are installed
//! (`KeyExpired`), or that the next record is not data and the read gave no
//! control room to name its type (`InputOutput`). Its owner must tell those
//! apart from a failure, so these make the call themselves, never waiting in
//! it, and wait for the socket's readiness through `wait`: native on a
//! runtime, a cancelable wait on any other `Io`.
//!
//! A receive given a `Wake` (`Receive.rekey`) waits through a stop for new
//! keys: the record layer's owner signals it once they are in. Linux stops
//! after giving out a TLS 1.3 KeyUpdate, and until the next keys a stopped
//! socket polls as not readable though records wait behind it; one that
//! polls readable then has ended or failed, which the stop hides, so the
//! receive answers `KeyExpired` and leaves it to the owner.
//!
//! The control data is the caller's to build and read (`cmsghdr`); reactor
//! knows no record layer. POSIX: on Windows these are a compile error. On
//! Darwin a send to a socket in blocking mode can wait in the kernel, which
//! takes no `MSG_DONTWAIT` there.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const sys = @import("../../sys/message.zig");
const wait = @import("../wait.zig");

const is_windows = builtin.os.tag == .windows;

pub const Received = sys.Received;

pub const Error = sys.Error || wait.WaitError;

pub const Receive = struct {
    /// When the receive gives up waiting for the socket, and for new keys.
    timeout: Io.Timeout = .none,
    /// Where the kernel's record layer stops its receive path for new keys
    /// (`KeyExpired`), a wake its owner signals once they are installed, which
    /// the receive waits for; null: `KeyExpired` is answered at once. A signal
    /// with no receive stopped is kept and costs the next stop one more try.
    rekey: ?*wait.Wake = null,
};

/// One receive: data into `data`, control data into `control`, waiting
/// until the socket has something or the timeout passes. `data_len` 0 is the
/// end of the stream when `data` had room. At most `max_pieces` of `data`
/// are filled.
pub const receive = if (is_windows) @compileError("socket messages are POSIX's") else receivePosix;

/// One send: as much of `data` as the socket takes, with `control` going
/// with its first byte, or alone when `data` is empty; waits for room until
/// `timeout` passes. Returns the bytes of data sent: a stream may take less
/// than all, and the rest goes in another send, with no control data again.
pub const send = if (is_windows) @compileError("socket messages are POSIX's") else sendPosix;

pub const max_pieces = sys.max_pieces;

fn receivePosix(io: Io, socket: Io.net.Socket.Handle, data: []const []u8, control: []u8, options: Receive) Error!Received {
    const deadline = options.timeout.toDeadline(io);
    // The socket ended the last wait for new keys: a stop found again then
    // hides the socket's end or a failure.
    var socket_first = false;
    while (true) {
        const result = sys.receive(socket, data, control) catch |err| switch (err) {
            error.KeyExpired => {
                const keys = options.rekey orelse return err;
                if (socket_first) return err;
                socket_first = try wait.waitAny(io, &.{ .{ .wake = keys }, .{ .readable = socket } }, deadline) == 1;
                continue;
            },
            else => return err,
        };
        socket_first = false;
        if (result) |received| return received;
        try wait.wait(io, .{ .readable = socket }, deadline);
    }
}

fn sendPosix(io: Io, socket: Io.net.Socket.Handle, data: []const []const u8, control: []const u8, timeout: Io.Timeout) Error!usize {
    const deadline = timeout.toDeadline(io);
    while (true) {
        if (try sys.send(socket, data, control)) |sent| return sent;
        try wait.wait(io, .{ .writable = socket }, deadline);
    }
}
