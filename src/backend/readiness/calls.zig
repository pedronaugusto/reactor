//! The calls a readiness backend makes: at once, in case the descriptor is
//! ready already, and again each time the kernel says it became ready.
//! None of them waits. Each errno is mapped as `Io.Threaded` maps it for
//! the same call, so a program sees the same errors on either `Io`.
//!
//! Sockets are read and written with `MSG_DONTWAIT`, whatever their mode.
//! Other descriptors are called only once `ready` says they are, in their
//! own mode: one read takes what is there, and one write is kept within
//! what a pipe takes whole (a write may always be short).
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const Threaded = Io.Threaded;
const E = posix.E;

const op = @import("../op.zig");
const file = @import("../../sys/file.zig");

pub const Direction = enum(u1) { read, write };

const bug = Threaded.errnoBug;

fn unexpected(e: E) error{Unexpected} {
    return posix.unexpectedErrno(e);
}

/// The most one write to a descriptor in blocking mode moves once it is
/// writable: what a pipe takes whole (POSIX's `PIPE_BUF`; a page on Linux).
pub const atomic_write: usize = if (builtin.os.tag == .linux) 4096 else 512;

const have_accept4 = !Threaded.socket_flags_unsupported;
const have_sendmmsg = builtin.os.tag == .linux;
const nonblock_flag: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");

/// The descriptor an operation waits on, and which way.
pub fn subject(operation: Io.Operation) struct { Io.File.Handle, Direction } {
    return switch (operation) {
        .file_read_streaming => |o| .{ o.file.handle, .read },
        .file_write_streaming => |o| .{ o.file.handle, .write },
        .net_read => |o| .{ o.socket_handle, .read },
        .net_write => |o| .{ o.socket_handle, .write },
        .net_receive => |o| .{ o.socket_handle, .read },
        .net_send => |o| .{ o.socket_handle, .write },
        .device_io_control => |o| .{ o.file.handle, .read },
    };
}

/// How an operation is made on a descriptor that is not ready yet.
pub const How = enum(u2) {
    /// A call that never waits (a socket's): made at once, and again on
    /// each readiness until it does not report `EAGAIN`.
    call,
    /// A descriptor in blocking mode: called only once it is ready.
    ready_then_call,
    /// Readiness alone (a `wait`).
    readiness,
    /// A connect under way: its outcome once the socket is writable.
    connect,
};

pub fn howOf(operation: Io.Operation) How {
    return switch (operation) {
        .file_read_streaming => |o| if (o.file.flags.nonblocking) .call else .ready_then_call,
        .file_write_streaming => |o| if (o.file.flags.nonblocking) .call else .ready_then_call,
        else => .call,
    };
}

/// `operation` made now. Null when it would wait: only a socket's call,
/// which passes `MSG_DONTWAIT`; a file in non-blocking mode reports
/// `WouldBlock`, as std's own `Io` does.
pub fn make(operation: Io.Operation) ?Io.Operation.Result {
    return switch (operation) {
        .net_read => |r| if (netRead(r)) |result| .{ .net_read = result } else null,
        .net_write => |w| if (netWrite(w)) |result| .{ .net_write = result } else null,
        .net_receive => |r| if (netReceive(r)) |result| .{ .net_receive = result } else null,
        .net_send => |s| if (netSend(s)) |result| .{ .net_send = result } else null,
        .file_read_streaming => |r| .{ .file_read_streaming = fileRead(r) },
        .file_write_streaming => |w| .{ .file_write_streaming = fileWrite(w) },
        .device_io_control => unreachable, // unreachable: device control runs borrowed, never on a loop
    };
}

/// What a completed call says of what is left: a stream read reports how
/// much it took of what it asked for (less means it took all there was), a
/// stream write that sent less than it was given filled the socket. The
/// readiness core keeps a descriptor it knows to be drained from being
/// called again before its next event (tokio clears its readiness the same
/// way). Datagram receives say nothing of what remains.
pub const Progress = union(enum) {
    other,
    read: struct { got: usize, asked: usize },
    short_write,
};

pub fn progress(operation: Io.Operation, result: Io.Operation.Result) Progress {
    return switch (operation) {
        .net_read => |r| if (result.net_read) |got| .{ .read = .{ .got = got.data_len, .asked = total(r.data) } } else |_| .other,
        .net_write => |w| if (result.net_write) |n| (if (n < w.header.len + writeTotal(w.data, w.splat)) .short_write else .other) else |_| .other,
        else => .other,
    };
}

fn total(data: []const []u8) usize {
    var n: usize = 0;
    for (data) |d| n += d.len;
    return n;
}

fn writeTotal(data: []const []const u8, splat: usize) usize {
    if (data.len == 0) return 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| n += d.len;
    return n + data[data.len - 1].len * splat;
}

/// Whether `fd` is a byte-stream socket, whose short read means it is
/// drained.
pub fn isStream(fd: posix.fd_t) bool {
    var kind: i32 = 0;
    var len: posix.socklen_t = @sizeOf(i32);
    const rc = posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.TYPE, @ptrCast(&kind), &len); // safe: the option is an int, its length given
    return posix.errno(rc) == .SUCCESS and kind == posix.SOCK.STREAM;
}

/// Whether `fd` is ready `direction`'s way now (an error or a hang-up
/// counts: the call then reports it).
pub fn ready(fd: posix.fd_t, direction: Direction) bool {
    const events: i16 = switch (direction) {
        .read => posix.POLL.IN,
        .write => posix.POLL.OUT,
    };
    var fds = [1]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    while (true) {
        const rc = posix.system.poll(&fds, 1, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return rc > 0,
            .INTR => continue,
            // No room to ask: let the call answer.
            else => return true,
        }
    }
}

// Sockets.

fn gather(iovecs: []posix.iovec, data: []const []u8) usize {
    var n: usize = 0;
    for (data) |d| {
        if (n == iovecs.len) break;
        if (d.len == 0) continue;
        iovecs[n] = .{ .base = d.ptr, .len = d.len };
        n += 1;
    }
    return n;
}

/// A write's buffers as `Threaded` lays them out: the header, the data,
/// and the splat (a one-byte pattern expanded through `splat_buffer`), at
/// most `limit` bytes.
fn scatter(iovecs: []posix.iovec_const, splat_buffer: *[Threaded.splat_buffer_size]u8, header: []const u8, data: []const []const u8, splat: usize, limit: usize) usize {
    var n: usize = 0;
    var room = limit;
    const add = struct {
        fn f(v: []posix.iovec_const, count: *usize, left: *usize, bytes: []const u8) void {
            if (bytes.len == 0 or count.* == v.len or left.* == 0) return;
            const len = @min(bytes.len, left.*);
            v[count.*] = .{ .base = bytes.ptr, .len = len };
            count.* += 1;
            left.* -= len;
        }
    }.f;
    add(iovecs, &n, &room, header);
    for (data[0 .. data.len - 1]) |d| add(iovecs, &n, &room, d);
    const pattern = data[data.len - 1];
    switch (splat) {
        0 => {},
        1 => add(iovecs, &n, &room, pattern),
        else => if (pattern.len == 1) {
            const len = @min(splat, splat_buffer.len);
            @memset(splat_buffer[0..len], pattern[0]);
            var remaining = splat;
            while (remaining > 0 and n < iovecs.len and room > 0) {
                const chunk = @min(remaining, len);
                add(iovecs, &n, &room, splat_buffer[0..chunk]);
                remaining -= chunk;
            }
        } else for (0..@min(splat, iovecs.len)) |_| add(iovecs, &n, &room, pattern),
    }
    return n;
}

fn netRead(r: Io.Operation.NetRead) ?Io.Operation.NetRead.Error!net.Stream.ReadResult {
    var iovecs: [Threaded.max_iovecs_len]posix.iovec = undefined;
    const count = gather(&iovecs, r.data);
    var msg: posix.msghdr = .{ .name = null, .namelen = 0, .iov = &iovecs, .iovlen = @intCast(count), .control = if (r.control.len == 0) null else r.control.ptr, .controllen = @intCast(r.control.len), .flags = 0 };
    const flags: u32 = posix.MSG.DONTWAIT | @as(u32, if (@hasDecl(posix.MSG, "CMSG_CLOEXEC")) posix.MSG.CMSG_CLOEXEC else 0);
    // One buffer and no control messages: `recv`, which costs less than
    // `recvmsg` (~7% on Darwin for a 64-byte message).
    const simple = count == 1 and r.control.len == 0;
    while (true) {
        const rc = if (simple)
            posix.system.recvfrom(r.socket_handle, iovecs[0].base, iovecs[0].len, posix.MSG.DONTWAIT, null, null)
        else
            posix.system.recvmsg(r.socket_handle, &msg, flags);
        return switch (posix.errno(rc)) {
            .SUCCESS => if (simple) .{ .data_len = @intCast(rc) } else .{ .data_len = @intCast(rc), .control_len = @intCast(msg.controllen), .control_truncated = msg.flags & posix.MSG.CTRUNC != 0 },
            .INTR => continue,
            .AGAIN => null,
            .NOBUFS, .NOMEM => error.SystemResources,
            .NOTCONN, .PIPE => error.SocketUnconnected,
            .CONNRESET => error.ConnectionResetByPeer,
            .TIMEDOUT => error.ConnectionTimedOut,
            .NETDOWN => error.NetworkDown,
            .INVAL, .FAULT, .BADF => |e| bug(e),
            else => |e| unexpected(e),
        };
    }
}

fn netWrite(w: Io.Operation.NetWrite) ?Io.Operation.NetWrite.Error!usize {
    var iovecs: [Threaded.max_iovecs_len]posix.iovec_const = undefined;
    var splat: [Threaded.splat_buffer_size]u8 = undefined;
    const count = scatter(&iovecs, &splat, w.header, w.data, w.splat, std.math.maxInt(usize));
    if (count == 0 and w.control.len == 0) return 0;
    const msg: posix.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iovecs, .iovlen = @intCast(count), .control = if (w.control.len == 0) null else w.control.ptr, .controllen = @intCast(w.control.len), .flags = 0 };
    // One piece and no control messages: `send`, cheaper than `sendmsg`.
    const simple = count == 1 and w.control.len == 0;
    while (true) {
        const rc = if (simple)
            posix.system.sendto(w.socket_handle, iovecs[0].base, iovecs[0].len, posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL, null, 0)
        else
            posix.system.sendmsg(w.socket_handle, &msg, posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL);
        return switch (posix.errno(rc)) {
            .SUCCESS => @as(usize, @intCast(rc)),
            .INTR => continue,
            .AGAIN => null,
            .ALREADY => error.FastOpenAlreadyInProgress,
            .CONNRESET => error.ConnectionResetByPeer,
            .NOBUFS, .NOMEM => error.SystemResources,
            .PIPE, .NOTCONN => error.SocketUnconnected,
            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .HOSTUNREACH => error.HostUnreachable,
            .NETUNREACH => error.NetworkUnreachable,
            .TIMEDOUT => error.ConnectionTimedOut,
            .NETDOWN => error.NetworkDown,
            .ACCES, .BADF, .DESTADDRREQ, .FAULT, .INVAL, .ISCONN, .MSGSIZE, .NOTSOCK, .OPNOTSUPP => |e| bug(e),
            else => |e| unexpected(e),
        };
    }
}

fn receiveFlags(flags: net.ReceiveFlags) u32 {
    return @as(u32, if (flags.oob) posix.MSG.OOB else 0) |
        @as(u32, if (flags.peek) posix.MSG.PEEK else 0) |
        @as(u32, if (flags.trunc) posix.MSG.TRUNC else 0);
}

/// One datagram into the first message: a receive may always fill fewer.
fn netReceive(r: Io.Operation.NetReceive) ?struct { ?net.Socket.ReceiveError, usize } {
    var storage: Threaded.PosixAddress = undefined;
    var iov: posix.iovec = .{ .base = r.data_buffer.ptr, .len = r.data_buffer.len };
    const message = &r.message_buffer[0];
    var msg: posix.msghdr = .{ .name = &storage.any, .namelen = @sizeOf(Threaded.PosixAddress), .iov = (&iov)[0..1], .iovlen = 1, .control = message.control.ptr, .controllen = @intCast(message.control.len), .flags = 0 };
    while (true) {
        const rc = posix.system.recvmsg(r.socket_handle, &msg, receiveFlags(r.flags) | posix.MSG.DONTWAIT);
        const err: net.Socket.ReceiveError = switch (posix.errno(rc)) {
            .SUCCESS => {
                message.* = .{
                    .from = Threaded.addressFromPosix(&storage),
                    .data = r.data_buffer[0..@intCast(rc)],
                    .control = if (msg.control) |ptr| @as([*]u8, @ptrCast(ptr))[0..msg.controllen] else message.control, // safe: the caller's control buffer, as the kernel filled it
                    .flags = .{
                        .eor = msg.flags & posix.MSG.EOR != 0,
                        .trunc = msg.flags & posix.MSG.TRUNC != 0,
                        .ctrunc = msg.flags & posix.MSG.CTRUNC != 0,
                        .oob = msg.flags & posix.MSG.OOB != 0,
                        .errqueue = if (@hasDecl(posix.MSG, "ERRQUEUE")) msg.flags & posix.MSG.ERRQUEUE != 0 else false,
                    },
                };
                return .{ null, 1 };
            },
            .INTR => continue,
            .AGAIN => return null,
            .NFILE => error.SystemFdQuotaExceeded,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NOBUFS, .NOMEM => error.SystemResources,
            .NOTCONN, .PIPE => error.SocketUnconnected,
            .MSGSIZE => error.MessageOversize,
            .CONNRESET => error.ConnectionResetByPeer,
            .TIMEDOUT => error.ConnectionTimedOut,
            .NETDOWN => error.NetworkDown,
            .CONNREFUSED => error.PortUnreachable,
            .BADF, .FAULT, .INVAL, .NOTSOCK, .OPNOTSUPP => |e| bug(e),
            else => |e| unexpected(e),
        };
        return .{ err, 0 };
    }
}

/// std's send flags as the kernel's, never raising `SIGPIPE`.
fn sendFlags(flags: net.SendFlags) u32 {
    return @as(u32, if (@hasDecl(posix.MSG, "CONFIRM") and flags.confirm) posix.MSG.CONFIRM else 0) |
        @as(u32, if (flags.dont_route) posix.MSG.DONTROUTE else 0) |
        @as(u32, if (flags.eor) posix.MSG.EOR else 0) |
        @as(u32, if (flags.oob) posix.MSG.OOB else 0) |
        @as(u32, if (@hasDecl(posix.MSG, "FASTOPEN") and flags.fastopen) posix.MSG.FASTOPEN else 0) |
        posix.MSG.NOSIGNAL | posix.MSG.DONTWAIT;
}

fn sendError(e: E) net.Socket.SendError {
    return switch (e) {
        .ACCES => error.AccessDenied,
        .ALREADY => error.FastOpenAlreadyInProgress,
        .CONNRESET => error.ConnectionResetByPeer,
        .MSGSIZE => error.MessageOversize,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PIPE, .NOTCONN => error.SocketUnconnected,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NETDOWN => error.NetworkDown,
        .CONNREFUSED => error.ConnectionRefused,
        .BADF, .DESTADDRREQ, .FAULT, .INVAL, .ISCONN, .NOTSOCK, .OPNOTSUPP => bug(e),
        else => unexpected(e),
    };
}

/// As many messages as the socket takes now; null when it takes none.
fn netSend(s: Io.Operation.NetSend) ?struct { ?net.Socket.SendError, usize } {
    var done: usize = 0;
    while (done < s.messages.len) {
        const n = (if (have_sendmmsg) sendMany(s.socket_handle, s.messages[done..], sendFlags(s.flags)) else sendOne(s.socket_handle, &s.messages[done], sendFlags(s.flags))) catch |err| switch (err) {
            error.WouldBlock => break,
            else => |e| return .{ e, done },
        };
        done += n;
    }
    if (done == 0 and s.messages.len > 0) return null;
    return .{ null, done };
}

fn sendOne(fd: posix.fd_t, message: *net.OutgoingMessage, flags: u32) (net.Socket.SendError || error{WouldBlock})!usize {
    var address: Threaded.PosixAddress = undefined;
    var iov: posix.iovec_const = .{ .base = message.data_ptr, .len = message.data_len };
    const msg: posix.msghdr_const = .{ .name = &address.any, .namelen = Threaded.addressToPosix(message.address, &address), .iov = (&iov)[0..1], .iovlen = 1, .control = if (message.control.len == 0) null else message.control.ptr, .controllen = @intCast(message.control.len), .flags = 0 };
    while (true) {
        const rc = posix.system.sendmsg(fd, &msg, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                message.data_len = @intCast(rc);
                return 1;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |e| return sendError(e),
        }
    }
}

fn sendMany(fd: posix.fd_t, messages: []net.OutgoingMessage, flags: u32) (net.Socket.SendError || error{WouldBlock})!usize {
    if (comptime !have_sendmmsg) unreachable; // unreachable: only where the kernel has sendmmsg
    var headers: [64]posix.system.mmsghdr = undefined;
    var addresses: [64]Threaded.PosixAddress = undefined;
    var iovecs: [64]posix.iovec = undefined;
    const n = @min(messages.len, headers.len);
    for (messages[0..n], headers[0..n], addresses[0..n], iovecs[0..n]) |*m, *h, *a, *v| {
        v.* = .{ .base = @constCast(m.data_ptr), .len = m.data_len }; // safe: the kernel only reads what a send gives it
        h.* = .{ .hdr = .{ .name = &a.any, .namelen = Threaded.addressToPosix(m.address, a), .iov = v[0..1], .iovlen = 1, .control = @constCast(m.control.ptr), .controllen = m.control.len, .flags = 0 }, .len = undefined }; // safe: the kernel only reads what a send gives it
    }
    while (true) {
        const rc = posix.system.sendmmsg(fd, &headers, @intCast(n), flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                for (messages[0..sent], headers[0..sent]) |*m, h| m.data_len = h.len;
                return sent;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |e| return sendError(e),
        }
    }
}

// Files in streaming mode.

fn fileRead(r: Io.Operation.FileReadStreaming) Io.Operation.FileReadStreaming.Error!usize {
    var iovecs: [Threaded.max_iovecs_len]posix.iovec = undefined;
    const count = gather(&iovecs, r.data);
    if (count == 0) return 0;
    while (true) {
        const rc = posix.system.readv(r.file.handle, &iovecs, @intCast(count));
        return switch (posix.errno(rc)) {
            .SUCCESS => if (rc == 0) error.EndOfStream else @as(usize, @intCast(rc)),
            .INTR => continue,
            .BADF => error.NotOpenForReading,
            .AGAIN => error.WouldBlock,
            .IO => error.InputOutput,
            .ISDIR => error.IsDir,
            .NOBUFS, .NOMEM => error.SystemResources,
            .NOTCONN => error.SocketUnconnected,
            .CONNRESET => error.ConnectionResetByPeer,
            .INVAL, .FAULT => |e| bug(e),
            else => |e| unexpected(e),
        };
    }
}

fn fileWrite(w: Io.Operation.FileWriteStreaming) Io.Operation.FileWriteStreaming.Error!usize {
    var iovecs: [Threaded.max_iovecs_len]posix.iovec_const = undefined;
    var splat: [Threaded.splat_buffer_size]u8 = undefined;
    const limit = if (w.file.flags.nonblocking) std.math.maxInt(usize) else atomic_write;
    const count = scatter(&iovecs, &splat, w.header, w.data, w.splat, limit);
    if (count == 0) return 0;
    while (true) {
        const rc = posix.system.writev(w.file.handle, &iovecs, @intCast(count));
        return switch (posix.errno(rc)) {
            .SUCCESS => @as(usize, @intCast(rc)),
            .INTR => continue,
            .AGAIN => error.WouldBlock,
            .BADF => error.NotOpenForWriting,
            .DQUOT => error.DiskQuota,
            .FBIG => error.FileTooBig,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .PERM => error.PermissionDenied,
            .PIPE => error.BrokenPipe,
            .BUSY => error.DeviceBusy,
            .NXIO => error.NoDevice,
            .ACCES => error.AccessDenied,
            .INVAL, .FAULT, .DESTADDRREQ, .CONNRESET => |e| bug(e),
            else => |e| unexpected(e),
        };
    }
}

// Accept and connect.

/// A connection from a listening socket in non-blocking mode; null when
/// none is waiting.
pub fn accept(fd: posix.fd_t) ?net.Server.AcceptError!net.Socket {
    var storage: Threaded.PosixAddress = undefined;
    var len: posix.socklen_t = @sizeOf(Threaded.PosixAddress);
    while (true) {
        const rc = if (have_accept4)
            posix.system.accept4(fd, &storage.any, &len, posix.SOCK.CLOEXEC)
        else
            posix.system.accept(fd, &storage.any, &len);
        const err: net.Server.AcceptError = switch (posix.errno(rc)) {
            .SUCCESS => {
                const accepted: posix.fd_t = @intCast(rc);
                if (!have_accept4) setCloexec(accepted) catch |e| {
                    close(accepted);
                    return e;
                };
                return .{ .handle = accepted, .address = Threaded.addressFromPosix(&storage) };
            },
            .INTR => continue,
            .AGAIN => return null,
            .CONNABORTED => error.ConnectionAborted,
            .INVAL => error.SocketNotListening,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => error.SystemResources,
            .PROTO => error.ProtocolFailure,
            .PERM => error.BlockedByFirewall,
            .BADF, .FAULT, .NOTSOCK, .OPNOTSUPP => |e| bug(e),
            else => |e| unexpected(e),
        };
        return err;
    }
}

fn setCloexec(fd: posix.fd_t) error{Unexpected}!void {
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |e| return unexpected(e),
    };
}

fn statusFlags(fd: posix.fd_t) error{Unexpected}!usize {
    while (true) {
        const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |e| return unexpected(e),
        }
    }
}

fn setStatusFlags(fd: posix.fd_t, flags: usize) error{Unexpected}!void {
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, flags))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |e| return unexpected(e),
    };
}

/// Puts `fd` in non-blocking mode; true when it was in blocking mode.
pub fn makeNonblocking(fd: posix.fd_t) error{Unexpected}!bool {
    const flags = try statusFlags(fd);
    if (flags & nonblock_flag != 0) return false;
    try setStatusFlags(fd, flags | nonblock_flag);
    return true;
}

/// Puts `fd` back in blocking mode; a descriptor that refuses stays as it
/// is, which reactor's own calls never mind (they pass `MSG_DONTWAIT`).
pub fn makeBlocking(fd: posix.fd_t) void {
    const flags = statusFlags(fd) catch return;
    setStatusFlags(fd, flags & ~nonblock_flag) catch |err| switch (err) {
        error.Unexpected => {},
    };
}

pub const ConnectError = op.ConnectError;

/// Starts a connect on a socket in non-blocking mode; null while it is
/// under way, which ends when the socket is writable (`connected`).
pub fn connect(fd: posix.fd_t, address: op.Connect.Address) ?ConnectError!void {
    var storage: extern union { ip: Threaded.PosixAddress, unix: posix.sockaddr.un } = undefined;
    const len: posix.socklen_t = switch (address) {
        .ip => |*ip| Threaded.addressToPosix(ip, &storage.ip),
        .unix => |unix| unixToPosix(unix, &storage.unix),
    };
    const rc = posix.system.connect(fd, @ptrCast(&storage), len); // safe: the storage is a socket address of the length given
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        // Interrupted, a connect goes on by itself.
        .INPROGRESS, .INTR => null,
        else => |e| connectError(e),
    };
}

/// How a connect that went on in the background ended.
pub fn connected(fd: posix.fd_t) ConnectError!void {
    var err: i32 = 0;
    var len: posix.socklen_t = @sizeOf(i32);
    while (true) {
        const rc = posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err), &len); // safe: the option is an int, its length given
        switch (posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => |e| return unexpected(e),
        }
    }
    if (err == 0) return;
    return connectError(@fromBackingInt(@intCast(err)));
}

fn connectError(e: E) ConnectError {
    return switch (e) {
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .ALREADY => error.ConnectionPending,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.Timeout,
        .ACCES => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        .LOOP => error.SymLinkLoop,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ROFS => error.ReadOnlyFileSystem,
        .PERM => error.PermissionDenied,
        .BADF, .CONNABORTED, .FAULT, .ISCONN, .NOTSOCK, .PROTOTYPE => bug(e),
        else => unexpected(e),
    };
}

fn unixToPosix(a: *const net.UnixAddress, storage: *posix.sockaddr.un) posix.socklen_t {
    storage.* = std.mem.zeroes(posix.sockaddr.un);
    storage.family = posix.AF.UNIX;
    const n = @min(a.path.len, storage.path.len - 1);
    @memcpy(storage.path[0..n], a.path[0..n]);
    return @intCast(@offsetOf(posix.sockaddr.un, "path") + n + 1);
}

// Positional file calls, made in place: a regular file has no readiness.

pub fn readAt(fd: posix.fd_t, buffer: []u8, offset: u64) (Io.File.ReadPositionalError || Io.Cancelable)!usize {
    return file.readAt(fd, &.{buffer}, offset);
}

pub const writeAt = file.writeAt;

pub fn sync(fd: posix.fd_t) Io.File.SyncError!void {
    while (true) {
        return switch (posix.errno(posix.system.fsync(fd))) {
            .SUCCESS => {},
            .INTR => continue,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .DQUOT => error.DiskQuota,
            .BADF, .INVAL, .ROFS => |e| bug(e),
            else => |e| unexpected(e),
        };
    }
}

/// Closes `fd`; an interrupted close counts as closed.
pub fn close(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}
