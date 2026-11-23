//! A stream socket's read or write ended at its deadline with no task to
//! race it in, on an `Io` that is not a runtime: what `Deadlines.operate`
//! does when no task can be had, where `Io.Threaded` cannot bound the
//! operation itself (it refuses a timed socket operation on Windows, and on
//! POSIX a timed write waits only for room, then blocks in `sendmsg`).
//!
//! A read waits on the calling thread for the socket to be readable, until
//! the deadline, and then reads, which finds bytes, the end or an error at
//! once. A write on POSIX waits for room the same way and sends what the
//! socket takes without waiting (`MSG_DONTWAIT`; on Darwin, whose send
//! ignores it, under a send timeout of one wait slice), again while it takes
//! no bytes; a write is allowed to be short, and the caller writes the rest
//! under its own deadline. On Windows a write is an overlapped AFD send the
//! deadline cancels. A wait sees a cancel within reactor's `wait.slice`.
//! Either way the operation never runs past its deadline: `Timeout` then,
//! and the caller poisons the socket.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const windows = std.os.windows;

const wait = @import("../wait.zig");
const kernel = @import("../kernel.zig");
const sys_socket = @import("../../sys/socket.zig");
const poll = @import("../../sys/poll.zig");
const aegis = @import("aegis");

const is_windows = builtin.os.tag == .windows;

/// `Timeout` when the deadline came first. `ConcurrencyUnavailable` for an
/// operation this cannot bound (a datagram send, a file's), or a socket a
/// wait cannot watch: it was not started.
pub const Error = Io.Cancelable || error{ Timeout, ConcurrencyUnavailable };

/// `operation` on the stream socket `socket`, ended at `deadline`.
pub fn operate(io: Io, socket: Io.net.Socket.Handle, operation: Io.Operation, deadline: Io.Clock.Timestamp) Error!Io.Operation.Result {
    switch (operation) {
        .net_read, .net_receive => {
            try ready(io, .{ .readable = socket }, deadline);
            return io.operate(operation);
        },
        .net_write => |w| return if (is_windows) writeWindows(io, socket, w, deadline) else writePosix(io, socket, w, deadline),
        else => return error.ConcurrencyUnavailable,
    }
}

/// Wait for `what` until `deadline`.
fn ready(io: Io, what: wait.Waitable, deadline: Io.Clock.Timestamp) Error!void {
    wait.wait(io, what, .{ .deadline = deadline }) catch |err| return switch (err) {
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        // Nothing here can watch the socket: the operation is not started.
        error.Unsupported, error.Unexpected => error.ConcurrencyUnavailable,
    };
}

/// The first bytes a write would send, as one buffer: a write may be short.
fn firstChunk(w: Io.Operation.NetWrite) []const u8 {
    if (w.header.len > 0) return w.header;
    for (w.data[0 .. w.data.len - 1]) |d| if (d.len > 0) return d;
    const last = w.data[w.data.len - 1];
    if (w.splat > 0 and last.len > 0) return last;
    return &.{};
}

fn writePosix(io: Io, socket: Io.net.Socket.Handle, w: Io.Operation.NetWrite, deadline: Io.Clock.Timestamp) Error!Io.Operation.Result {
    const chunk = firstChunk(w);
    if (chunk.len == 0) return .{ .net_write = 0 };
    // Darwin's send waits for room even under `MSG_DONTWAIT`: there it is
    // held to a send timeout of one wait slice, after which it returns what
    // it took, or `EAGAIN` with nothing taken.
    if (!sys_socket.send_honors_dontwait) try holdSends(socket, wait.slice);
    defer if (!sys_socket.send_honors_dontwait) holdSends(socket, .fromRaw(0)) catch aegis.assert.never("a socket that took a send timeout takes it back");
    while (true) {
        try ready(io, .{ .writable = socket }, deadline);
        const rc = posix.system.send(socket, chunk.ptr, chunk.len, posix.MSG.NOSIGNAL | if (sys_socket.send_honors_dontwait) posix.MSG.DONTWAIT else 0);
        return .{
            .net_write = switch (posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                // Room seen and taken by then, or a signal: wait again.
                .AGAIN, .INTR => continue,
                .CONNRESET => error.ConnectionResetByPeer,
                .NOBUFS, .NOMEM => error.SystemResources,
                .PIPE, .NOTCONN => error.SocketUnconnected,
                .HOSTUNREACH => error.HostUnreachable,
                .NETUNREACH => error.NetworkUnreachable,
                .TIMEDOUT => error.ConnectionTimedOut,
                .NETDOWN => error.NetworkDown,
                else => |e| posix.unexpectedErrno(e),
            },
        };
    }
}

/// Sets the socket's send timeout (`SO_SNDTIMEO`), under a second; zero
/// waits as long as a send takes. A socket whose sends cannot be held is one
/// this cannot bound.
fn holdSends(socket: Io.net.Socket.Handle, held: poll.Millis) error{ConcurrencyUnavailable}!void {
    aegis.assert.invariant(held.compare(.fromRaw(1000)) == .lt, "a held send waits under a second");
    const value: posix.timeval = .{ .sec = 0, .usec = @intCast(held.convert(.microsecond, u64, .exact).raw()) };
    const bytes = std.mem.asBytes(&value);
    while (true) switch (posix.errno(posix.system.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, bytes.ptr, @intCast(bytes.len)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.ConcurrencyUnavailable,
    };
}

fn writeWindows(io: Io, socket: Io.net.Socket.Handle, w: Io.Operation.NetWrite, deadline: Io.Clock.Timestamp) Error!Io.Operation.Result {
    const chunk = firstChunk(w);
    if (chunk.len == 0) return .{ .net_write = 0 };
    var buffers: [1]windows.AFD.WSABUF(.@"const") = .{.{ .buf = chunk.ptr, .len = @intCast(@min(chunk.len, std.math.maxInt(u32))) }};
    const info: windows.AFD.SEND_INFO = .{
        .BufferArray = &buffers,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{},
    };
    const Send = struct {
        socket: windows.HANDLE,
        info: *const windows.AFD.SEND_INFO,
        fn begin(s: @This(), iosb: *windows.IO_STATUS_BLOCK, completion: kernel.Completion) windows.NTSTATUS {
            return windows.ntdll.NtDeviceIoControlFile(s.socket, completion.event, null, completion.context, iosb, windows.IOCTL.AFD.SEND, @ptrCast(s.info), @sizeOf(windows.AFD.SEND_INFO), null, 0);
        }
    };
    const iosb = kernel.overlapped(io, Send.begin, socket, Send{ .socket = socket, .info = &info }, .{ .deadline = deadline }) catch |err| return switch (err) {
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        error.Unsupported => error.ConcurrencyUnavailable,
        error.SystemResources => .{ .net_write = error.SystemResources },
    };
    return .{ .net_write = switch (iosb.u.Status) {
        .SUCCESS => iosb.Information,
        .INSUFFICIENT_RESOURCES => error.SystemResources,
        .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionResetByPeer,
        .IO_TIMEOUT => error.ConnectionTimedOut,
        .CONNECTION_DISCONNECTED, .LOCAL_DISCONNECT => error.SocketUnconnected,
        else => |status| windows.unexpectedStatus(status),
    } };
}
