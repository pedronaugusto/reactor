//! io_uring completions as std's results: each errno mapped as `Threaded`
//! maps it for the same call, so a program sees the same errors on either
//! `Io`. Also the calls a batch makes inline once a poll says the socket is
//! ready, without waiting.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const linux = std.os.linux;
const posix = std.posix;
const Threaded = Io.Threaded;
const E = linux.E;

const op = @import("../op.zig");
const pending = @import("../pending.zig");

const bug = Threaded.errnoBug;

fn unexpected(e: E) error{Unexpected} {
    return posix.unexpectedErrno(e);
}

/// The result of a completed operation.
pub fn of(o: anytype, cqe: linux.io_uring_cqe) op.Result {
    const e = cqe.err();
    const canceled = e == .CANCELED;
    const ours = canceled and o.state.canceled;
    return switch (o.kind) {
        .raw => .{ .raw = if (ours) error.Canceled else .{ .uring = cqe.res } },
        .io => |operation| .{ .io = if (ours) error.Canceled else io(o, operation, cqe) },
        .accept => .{ .accept = if (ours) error.Canceled else if (canceled) error.SocketNotListening else accept(o, cqe) },
        .connect => .{ .connect = if (ours) error.Canceled else if (canceled) error.ConnectionResetByPeer else if (e == .SUCCESS) {} else connect(e) },
        .read_at => .{ .read_at = if (ours) error.Canceled else if (e == .SUCCESS) @intCast(cqe.res) else readAt(e) },
        .write_at => .{ .write_at = if (ours) error.Canceled else if (e == .SUCCESS) @intCast(cqe.res) else writeAt(e) },
        .sync => .{ .sync = if (ours) error.Canceled else if (e == .SUCCESS) {} else sync(e) },
        .close => .{ .close = {} },
        .abort => .{ .abort = if (cqe.res > 0) @intCast(cqe.res) else 0 },
        .timer => .{ .timer = switch (e) {
            .TIME, .SUCCESS => {},
            else => error.Canceled,
        } },
        // A descriptor that is not open is ready, as a poll says: the call reports it.
        .wait => .{ .wait = if (canceled) error.Canceled else if (cqe.res >= 0 or e == .BADF) {} else error.Unexpected },
    };
}

/// A batch operation's result, or the kernel's cancel of it.
pub fn ofPending(tag: Io.Operation.Tag, cqe: linux.io_uring_cqe) pending.Outcome {
    const e = cqe.err();
    if (e == .CANCELED) return .canceled;
    const n: usize = if (cqe.res >= 0) @intCast(cqe.res) else 0;
    return .{
        .result = switch (tag) {
            .file_read_streaming => .{ .file_read_streaming = if (e == .SUCCESS) (if (n == 0) error.EndOfStream else n) else if (e == .INTR) 0 else fileRead(e) },
            .file_write_streaming => .{ .file_write_streaming = if (e == .SUCCESS) n else if (e == .INTR) 0 else fileWrite(e) },
            .net_read => .{ .net_read = if (e == .SUCCESS) .{ .data_len = n } else netRead(e) },
            .net_write => .{ .net_write = if (e == .SUCCESS) n else netWrite(e) },
            .net_receive, .net_send, .device_io_control => unreachable, // unreachable: these go by readiness or never pend
        },
    };
}

fn io(o: anytype, operation: Io.Operation, cqe: linux.io_uring_cqe) Io.Operation.Result {
    const e = cqe.err();
    const n: usize = if (cqe.res >= 0) @intCast(cqe.res) else 0;
    // Cancelled though nobody here asked: its descriptor was closed.
    const closed = e == .CANCELED;
    return switch (operation) {
        .file_read_streaming => .{ .file_read_streaming = if (e == .SUCCESS) (if (n == 0) error.EndOfStream else n) else if (e == .INTR) 0 else if (closed) error.SocketUnconnected else fileRead(e) },
        .file_write_streaming => .{ .file_write_streaming = if (e == .SUCCESS) n else if (e == .INTR) 0 else if (closed) error.BrokenPipe else fileWrite(e) },
        .net_read => |r| .{ .net_read = if (e == .SUCCESS) readResult(o, r, n) else if (closed) error.SocketUnconnected else netRead(e) },
        .net_write => .{ .net_write = if (e == .SUCCESS) n else if (closed) error.SocketUnconnected else netWrite(e) },
        .net_receive => |r| .{ .net_receive = if (e == .SUCCESS) received(o, r, n) else .{ if (closed) error.SocketUnconnected else receive(e), 0 } },
        .net_send => |s| .{ .net_send = if (e == .SUCCESS) sent(s, n) else .{ if (closed) error.SocketUnconnected else send(e), 0 } },
        .device_io_control => unreachable, // unreachable: device control runs borrowed
    };
}

fn readResult(o: anytype, r: Io.Operation.NetRead, n: usize) net.Stream.ReadResult {
    if (r.control.len == 0) return .{ .data_len = n };
    const header = &o.state.storage.scratch.io_uring.message.header;
    return .{ .data_len = n, .control_len = header.controllen, .control_truncated = header.flags & posix.MSG.CTRUNC != 0 };
}

fn received(o: anytype, r: Io.Operation.NetReceive, n: usize) struct { ?net.Socket.ReceiveError, usize } {
    const m = &o.state.storage.scratch.io_uring.message;
    fillMessage(&r.message_buffer[0], r.data_buffer[0..n], &m.address, &m.header);
    return .{ null, 1 };
}

fn fillMessage(message: *net.IncomingMessage, data: []u8, address: *const Threaded.PosixAddress, header: *const linux.msghdr) void {
    message.* = .{
        .from = Threaded.addressFromPosix(address),
        .data = data,
        .control = if (header.control) |ptr| @as([*]u8, @ptrCast(ptr))[0..header.controllen] else message.control, // safe: the control buffer the caller gave, as the kernel filled it
        .flags = .{
            .eor = header.flags & posix.MSG.EOR != 0,
            .trunc = header.flags & posix.MSG.TRUNC != 0,
            .ctrunc = header.flags & posix.MSG.CTRUNC != 0,
            .oob = header.flags & posix.MSG.OOB != 0,
            .errqueue = header.flags & posix.MSG.ERRQUEUE != 0,
        },
    };
}

fn sent(s: Io.Operation.NetSend, n: usize) struct { ?net.Socket.SendError, usize } {
    s.messages[0].data_len = n;
    return .{ null, 1 };
}

/// After the first message went through the ring: the rest, by one
/// non-blocking `sendmmsg`, as many as the socket takes now.
pub fn sendRest(s: Io.Operation.NetSend, from: usize) struct { ?net.Socket.SendError, usize } {
    var done = from;
    while (done < s.messages.len) {
        const n = sendMany(s.socket_handle, s.messages[done..], sendFlags(s.flags) | posix.MSG.DONTWAIT) catch |err| switch (err) {
            error.WouldBlock => break,
            else => |e| return .{ e, done },
        };
        if (n == 0) break;
        done += n;
    }
    return .{ null, done };
}

/// std's send flags as the kernel's, never raising `SIGPIPE`.
pub fn sendFlags(flags: net.SendFlags) u32 {
    return @as(u32, if (flags.confirm) posix.MSG.CONFIRM else 0) |
        @as(u32, if (flags.dont_route) posix.MSG.DONTROUTE else 0) |
        @as(u32, if (flags.eor) posix.MSG.EOR else 0) |
        @as(u32, if (flags.oob) posix.MSG.OOB else 0) |
        @as(u32, if (flags.fastopen) posix.MSG.FASTOPEN else 0) |
        posix.MSG.NOSIGNAL;
}

fn accept(o: anytype, cqe: linux.io_uring_cqe) net.Server.AcceptError!net.Socket {
    const e = cqe.err();
    if (e != .SUCCESS) return switch (e) {
        .AGAIN, .BADF, .FAULT, .NOTSOCK, .OPNOTSUPP => bug(e),
        .CONNABORTED => error.ConnectionAborted,
        .INVAL => error.SocketNotListening,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PROTO => error.ProtocolFailure,
        .PERM => error.BlockedByFirewall,
        else => unexpected(e),
    };
    const a = &o.state.storage.scratch.io_uring.address;
    return .{ .handle = cqe.res, .address = Threaded.addressFromPosix(&a.storage.ip) };
}

fn connect(e: E) op.ConnectError {
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

fn fileRead(e: E) Io.Operation.FileReadStreaming.Error {
    return switch (e) {
        .BADF => error.NotOpenForReading,
        .AGAIN => error.WouldBlock,
        .IO => error.InputOutput,
        .ISDIR => error.IsDir,
        .NOBUFS, .NOMEM => error.SystemResources,
        .NOTCONN => error.SocketUnconnected,
        .CONNRESET => error.ConnectionResetByPeer,
        .INVAL, .FAULT => bug(e),
        else => unexpected(e),
    };
}

fn fileWrite(e: E) Io.Operation.FileWriteStreaming.Error {
    return switch (e) {
        .AGAIN => error.WouldBlock,
        .BADF => error.NotOpenForWriting,
        .DQUOT => error.DiskQuota,
        .FBIG => error.FileTooBig,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .PERM => error.PermissionDenied,
        .PIPE => error.BrokenPipe,
        .BUSY => error.DeviceBusy,
        .ACCES => error.AccessDenied,
        .INVAL, .FAULT, .DESTADDRREQ, .CONNRESET => bug(e),
        else => unexpected(e),
    };
}

fn netRead(e: E) Io.Operation.NetRead.Error {
    return switch (e) {
        .NOBUFS, .NOMEM => error.SystemResources,
        .NOTCONN, .PIPE => error.SocketUnconnected,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NETDOWN => error.NetworkDown,
        .INVAL, .FAULT, .AGAIN, .BADF => bug(e),
        else => unexpected(e),
    };
}

fn netWrite(e: E) Io.Operation.NetWrite.Error {
    return switch (e) {
        .ALREADY => error.FastOpenAlreadyInProgress,
        .CONNRESET => error.ConnectionResetByPeer,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PIPE, .NOTCONN => error.SocketUnconnected,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NETDOWN => error.NetworkDown,
        .ACCES, .AGAIN, .BADF, .DESTADDRREQ, .FAULT, .INVAL, .ISCONN, .MSGSIZE, .NOTSOCK, .OPNOTSUPP => bug(e),
        else => unexpected(e),
    };
}

fn receive(e: E) net.Socket.ReceiveError {
    return switch (e) {
        .NFILE => error.SystemFdQuotaExceeded,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .NOTCONN, .PIPE => error.SocketUnconnected,
        .MSGSIZE => error.MessageOversize,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NETDOWN => error.NetworkDown,
        .CONNREFUSED => error.PortUnreachable,
        .BADF, .FAULT, .INVAL, .NOTSOCK, .OPNOTSUPP, .AGAIN => bug(e),
        else => unexpected(e),
    };
}

fn send(e: E) net.Socket.SendError {
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
        .BADF, .DESTADDRREQ, .FAULT, .INVAL, .ISCONN, .NOTSOCK, .OPNOTSUPP, .AGAIN => bug(e),
        else => unexpected(e),
    };
}

fn readAt(e: E) (Io.File.ReadPositionalError || Io.Cancelable) {
    return switch (e) {
        .NXIO, .SPIPE, .OVERFLOW => error.Unseekable,
        .NOBUFS, .NOMEM => error.SystemResources,
        .AGAIN => error.WouldBlock,
        .IO => error.InputOutput,
        .ISDIR => error.IsDir,
        .BADF => error.NotOpenForReading,
        .NOTCONN, .CONNRESET, .INVAL, .FAULT => bug(e),
        else => unexpected(e),
    };
}

fn writeAt(e: E) (Io.File.WritePositionalError || Io.Cancelable) {
    return switch (e) {
        .BADF => error.NotOpenForWriting,
        .DQUOT => error.DiskQuota,
        .FBIG => error.FileTooBig,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .PERM => error.PermissionDenied,
        .PIPE => error.BrokenPipe,
        .NXIO, .SPIPE, .OVERFLOW => error.Unseekable,
        .INVAL, .FAULT, .AGAIN, .DESTADDRREQ => bug(e),
        else => unexpected(e),
    };
}

fn sync(e: E) Io.File.SyncError {
    return switch (e) {
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        .BADF, .INVAL, .ROFS => bug(e),
        else => unexpected(e),
    };
}

// The calls a batch makes once a poll says the socket is ready.

/// The operation, done now without waiting; null when the socket turned
/// out not to be ready after all.
pub fn attempt(operation: Io.Operation) ?Io.Operation.Result {
    switch (operation) {
        .net_read => |r| {
            var iovecs: [Threaded.max_iovecs_len]posix.iovec = undefined;
            var n: usize = 0;
            for (r.data) |d| if (d.len > 0 and n < iovecs.len) {
                iovecs[n] = .{ .base = d.ptr, .len = d.len };
                n += 1;
            };
            var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iovecs, .iovlen = n, .control = r.control.ptr, .controllen = @intCast(r.control.len), .flags = 0 };
            const rc = linux.recvmsg(r.socket_handle, &msg, posix.MSG.DONTWAIT | posix.MSG.CMSG_CLOEXEC);
            const e = linux.errno(rc);
            if (e == .AGAIN) return null;
            return .{ .net_read = if (e == .SUCCESS) .{ .data_len = rc, .control_len = msg.controllen, .control_truncated = msg.flags & posix.MSG.CTRUNC != 0 } else netRead(e) };
        },
        .net_write => |w| {
            var iovecs: [Threaded.max_iovecs_len]posix.iovec = undefined;
            var splat: [Threaded.splat_buffer_size]u8 = undefined;
            const count = scatterWrite(&iovecs, &splat, w.header, w.data, w.splat);
            const msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = @ptrCast(&iovecs), .iovlen = count, .control = if (w.control.len == 0) null else @constCast(w.control.ptr), .controllen = @intCast(w.control.len), .flags = 0 }; // safe: the kernel only reads what a send gives it, through the same layout
            // One piece and no control messages: `send`, which copies no
            // message header in.
            const rc = if (count == 1 and w.control.len == 0)
                linux.sendto(w.socket_handle, @ptrCast(iovecs[0].base), iovecs[0].len, posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL, null, 0)
            else
                linux.sendmsg(w.socket_handle, &msg, posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL);
            const e = linux.errno(rc);
            if (e == .AGAIN) return null;
            return .{ .net_write = if (e == .SUCCESS) rc else netWrite(e) };
        },
        .net_receive => |r| {
            var address: Threaded.PosixAddress = undefined;
            var iov: posix.iovec = .{ .base = r.data_buffer.ptr, .len = r.data_buffer.len };
            const message = &r.message_buffer[0];
            var msg: linux.msghdr = .{ .name = &address.any, .namelen = @sizeOf(Threaded.PosixAddress), .iov = @ptrCast(&iov), .iovlen = 1, .control = message.control.ptr, .controllen = @intCast(message.control.len), .flags = 0 }; // safe: one iovec as an array of one
            const flags = @as(u32, if (r.flags.oob) posix.MSG.OOB else 0) | @as(u32, if (r.flags.peek) posix.MSG.PEEK else 0) | @as(u32, if (r.flags.trunc) posix.MSG.TRUNC else 0);
            const rc = linux.recvmsg(r.socket_handle, &msg, flags | posix.MSG.DONTWAIT);
            const e = linux.errno(rc);
            if (e == .AGAIN) return null;
            if (e != .SUCCESS) return .{ .net_receive = .{ receive(e), 0 } };
            fillMessage(message, r.data_buffer[0..rc], &address, &msg);
            return .{ .net_receive = .{ null, 1 } };
        },
        .net_send => |s| {
            const n = sendMany(s.socket_handle, s.messages, sendFlags(s.flags) | posix.MSG.DONTWAIT) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => |e| return .{ .net_send = .{ e, 0 } },
            };
            return .{ .net_send = .{ null, n } };
        },
        else => unreachable, // unreachable: only socket calls go by readiness
    }
}

fn sendMany(fd: linux.fd_t, messages: []net.OutgoingMessage, flags: u32) (net.Socket.SendError || error{WouldBlock})!usize {
    var headers: [64]linux.mmsghdr = undefined;
    var addresses: [64]Threaded.PosixAddress = undefined;
    var iovecs: [64]posix.iovec = undefined;
    const n = @min(messages.len, headers.len);
    for (messages[0..n], headers[0..n], addresses[0..n], iovecs[0..n]) |*m, *h, *a, *v| {
        v.* = .{ .base = @constCast(m.data_ptr), .len = m.data_len }; // safe: the kernel only reads what a send gives it
        h.* = .{ .hdr = .{ .name = &a.any, .namelen = Threaded.addressToPosix(m.address, a), .iov = v[0..1], .iovlen = 1, .control = @constCast(m.control.ptr), .controllen = m.control.len, .flags = 0 }, .len = undefined }; // safe: the kernel only reads what a send gives it
    }
    const rc = linux.sendmmsg(fd, &headers, @intCast(n), flags);
    const e = linux.errno(rc);
    if (e == .AGAIN) return error.WouldBlock;
    if (e != .SUCCESS) return send(e);
    for (messages[0..rc], headers[0..rc]) |*m, h| m.data_len = h.len;
    return rc;
}

fn scatterWrite(iovecs: []posix.iovec, splat_buffer: *[Threaded.splat_buffer_size]u8, header: []const u8, data: []const []const u8, splat: usize) usize {
    var n: usize = 0;
    const add = struct {
        fn f(v: []posix.iovec, count: *usize, bytes: []const u8) void {
            if (bytes.len == 0 or count.* == v.len) return;
            v[count.*] = .{ .base = @constCast(bytes.ptr), .len = bytes.len }; // safe: the kernel only reads what a send gives it
            count.* += 1;
        }
    }.f;
    add(iovecs, &n, header);
    for (data[0 .. data.len - 1]) |d| add(iovecs, &n, d);
    const pattern = data[data.len - 1];
    if (splat == 1) add(iovecs, &n, pattern) else if (splat > 1 and pattern.len == 1) {
        const len = @min(splat, splat_buffer.len);
        @memset(splat_buffer[0..len], pattern[0]);
        add(iovecs, &n, splat_buffer[0..len]);
    } else if (splat > 1) add(iovecs, &n, pattern);
    return n;
}

/// The result of a batch operation the ring had no room to wait on again.
pub fn failure(operation: Io.Operation) Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => .{ .file_read_streaming = error.SystemResources },
        .file_write_streaming => .{ .file_write_streaming = error.SystemResources },
        .net_read => .{ .net_read = error.SystemResources },
        .net_write => .{ .net_write = error.SystemResources },
        .net_receive => .{ .net_receive = .{ error.SystemResources, 0 } },
        .net_send => .{ .net_send = .{ error.SystemResources, 0 } },
        .device_io_control => unreachable, // unreachable: never pending
    };
}
