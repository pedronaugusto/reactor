//! IOCP over AFD: each socket call is AFD's own request, issued overlapped
//! on the socket and finished through a completion port; files and pipes
//! opened for overlapped calls the same way; waits on kernel objects and
//! timers through wait completion packets.
//!
//! - **One port per loop**, or the host's (`Options.port`), whose entries
//!   the host hands back through `complete`. A handle is bound to the port
//!   of the first loop that uses it, for the handle's life: an entry that
//!   reaches a loop for another loop's operation is posted on to that
//!   loop's port, so a task may use a socket from any processor.
//! - **Skip on success**: a handle is bound with the port skipped for calls
//!   that complete at once, so a receive with data waiting is one call and
//!   no entry; `submit` reports it finished. A call that fails at once
//!   queues no entry either; a pending one, or one finished with a warning
//!   (a datagram too long), queues one.
//! - **Precise waits**: a wait with a deadline arms a high-resolution
//!   waitable timer whose wait packet wakes the port; the port's own
//!   timeout has the system tick's resolution (15.6 ms by default).
//! - `real` and `boot` timers are waitable timers of their own: an absolute
//!   one for `real`, so a wall-clock change moves it.
//!
//! An entry's context is an operation's address, or a batch slot's, with a
//! tag in its three low bits; its key is reactor's on every port.
const Iocp = @This();

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const Handle = windows.HANDLE;
const Status = windows.NTSTATUS;
const Threaded = Io.Threaded;

const pending = @import("pending.zig");
const Wait = @import("wait.zig").Wait;
const results = @import("iocp/results.zig");
const sys = @import("../sys/windows.zig");
const afd = @import("../sys/afd.zig");

pub const Options = struct {
    /// The host's port: entries reach the loop through `complete`, and the
    /// loop never waits on the port itself.
    port: ?Handle = null,
    /// Batch operations in flight at once.
    slots: u32,
};

pub const InitError = error{ SystemResources, Unexpected } || Allocator.Error;

/// reactor's completion key on any port: an address no key of a host's can
/// be.
const key_anchor: u8 = 0;

/// One entry taken from a port: Win32's `OVERLAPPED_ENTRY`.
pub const Entry = sys.Entry;

pub fn key() usize {
    return @intFromPtr(&key_anchor); // safe: an address used as a number nobody else can have
}

const Tag = enum(u3) {
    /// An operation: the address of its `Op`.
    op = 0,
    /// A batch operation: the address of its slot.
    slot = 1,
    /// A `wake`.
    wake = 2,
    /// The precise timer of a wait with a deadline.
    timer = 3,
};

fn contextOf(address: usize, tag: Tag) usize {
    assert(address & 7 == 0);
    return address | @backingInt(tag);
}

/// What an operation keeps while the kernel holds it.
pub const Scratch = struct {
    /// Where the kernel writes the outcome.
    iosb: windows.IO_STATUS_BLOCK = undefined,
    /// The loop that submitted it, which finishes it.
    owner: *Iocp,
    /// The handle the kernel holds the call on.
    target: Handle = undefined,
    stage: Stage = .main,
    /// A multi-message send: messages sent so far.
    sent: u32 = 0,
    request: Request = .{ .none = {} },
};

const Stage = enum(u8) {
    /// One request, whose outcome is the result.
    main,
    /// An accept waiting for a connection.
    listen,
    /// An accept taking the connection the wait reported.
    accept,
    /// A send of several datagrams, one request each.
    send,
    /// A wait packet: an object's signal, or a timer of its own.
    packet,
    /// Readiness of a socket.
    poll,
};

/// The memory a request is read from or written to after the call.
const Request = union {
    none: void,
    receive: struct { info: windows.AFD.RECV_INFO, buffers: [Threaded.max_iovecs_len]windows.AFD.WSABUF(.@"var") },
    send: struct { info: windows.AFD.SEND_INFO, buffers: [Threaded.max_iovecs_len]windows.AFD.WSABUF(.@"const"), splat: [Threaded.splat_buffer_size]u8 },
    datagram_in: DatagramIn,
    datagram_out: DatagramOut,
    connect_ip: afd.ConnectInfo(Threaded.PosixAddress),
    connect_unix: afd.ConnectInfo(ws2_32.sockaddr.un),
    accept: struct { response: afd.ListenResponse, info: windows.AFD.ACCEPT_INFO, socket: Handle },
    poll: afd.PollInfo,
    offset: i64,
    packet: struct { packet: Handle, timer: ?Handle },
};

const DatagramIn = struct {
    info: windows.AFD.RECV_DATAGRAM_INFO,
    buffer: [1]windows.AFD.WSABUF(.@"var"),
    address: Threaded.PosixAddress,
    address_len: windows.ULONG,
};

const DatagramOut = struct {
    info: windows.AFD.SEND_DATAGRAM_INFO,
    buffer: [1]windows.AFD.WSABUF(.@"const"),
    address: Threaded.PosixAddress,
};

/// A batch operation while the kernel holds it: the batch's storage has
/// no room for a status block beside the operation it keeps.
const Slot = struct {
    iosb: windows.IO_STATUS_BLOCK = undefined,
    owner: *Iocp,
    token: pending.Token = undefined,
    target: Handle = undefined,
    next: ?*Slot = null,
    request: SlotRequest = .{ .none = {} },
};

const SlotRequest = union {
    none: void,
    receive: struct { info: windows.AFD.RECV_INFO, buffer: [1]windows.AFD.WSABUF(.@"var") },
    send: struct { info: windows.AFD.SEND_INFO, buffer: [1]windows.AFD.WSABUF(.@"const") },
    datagram_in: DatagramIn,
    datagram_out: DatagramOut,
};

port: Handle,
/// The port is the host's: never waited on, never closed here.
hosted: bool,
/// The precise timer a wait with a deadline arms, and its packet.
timer: Handle,
precise: bool,
timer_packet: Handle,
/// The timer's packet is armed and its entry not taken yet.
timer_armed: bool = false,
/// When the armed timer fires, on the awake clock (ns).
timer_at: u64 = 0,
/// Set by `wake` until its entry is taken: later wakes post nothing.
wake_pending: std.atomic.Value(bool) = .init(false),
slots: []Slot,
free: ?*Slot = null,

pub fn init(gpa: Allocator, options: Options) InitError!Iocp {
    const port = options.port orelse try sys.createPort();
    errdefer if (options.port == null) sys.close(port);
    const timer, const precise = try sys.createTimer();
    errdefer sys.close(timer);
    const timer_packet = try sys.createWaitPacket();
    errdefer sys.close(timer_packet);
    var b: Iocp = .{
        .port = port,
        .hosted = options.port != null,
        .timer = timer,
        .precise = precise,
        .timer_packet = timer_packet,
        .slots = try gpa.alloc(Slot, options.slots),
    };
    // Every slot free, the first one first out.
    var i = b.slots.len;
    while (i > 0) {
        i -= 1;
        b.slots[i] = .{ .owner = undefined, .next = b.free };
        b.free = &b.slots[i];
    }
    return b;
}

pub fn deinit(b: *Iocp, gpa: Allocator) void {
    if (b.timer_armed) _ = sys.disarmWaitPacket(b.timer_packet);
    sys.close(b.timer_packet);
    sys.close(b.timer);
    if (!b.hosted) sys.close(b.port);
    gpa.free(b.slots);
    b.* = undefined;
}

/// The `Op` type a sink completes.
fn OpOf(comptime SinkPtr: type) type {
    const Sink = @typeInfo(SinkPtr).pointer.child;
    return @typeInfo(@typeInfo(@TypeOf(Sink.complete)).@"fn".param_types[1].?).pointer.child;
}

/// Binds `handle` to this loop's port unless it is bound already.
fn bindHandle(b: *Iocp, handle: Handle) bool {
    return sys.bindOnce(handle, b.port, key());
}

// Submission.

/// Hands `o` to the kernel. True when it finished at once: its result is
/// set, and no entry follows.
pub fn submit(b: *Iocp, o: anytype) error{ SystemResources, Unexpected }!bool {
    o.state.scratch = .{ .iocp = .{ .owner = b } };
    const s = &o.state.scratch.iocp;
    const context: ?*anyopaque = @ptrFromInt(contextOf(@intFromPtr(o), .op)); // safe: read back as the `Op` in `dispatch`
    switch (o.kind) {
        .io => |*operation| return b.submitIo(o, operation, context),
        .accept => |listener| {
            if (!b.bindHandle(listener)) return b.refuse(o);
            s.target = listener;
            s.stage = .listen;
            s.request = .{ .accept = .{ .response = undefined, .info = undefined, .socket = undefined } };
            const a = &s.request.accept;
            const status = windows.ntdll.NtDeviceIoControlFile(listener, null, null, context, &s.iosb, windows.IOCTL.AFD.WAIT_FOR_LISTEN, null, 0, &a.response, @sizeOf(afd.ListenResponse));
            return b.settle(o, status);
        },
        .connect => |c| {
            if (!b.bindHandle(c.socket)) return b.refuse(o);
            s.target = c.socket;
            const status = switch (c.address) {
                .ip => |*ip| status: {
                    s.request = .{ .connect_ip = .{ .address = undefined } };
                    const info = &s.request.connect_ip;
                    const len = Threaded.addressToPosix(ip, &info.address);
                    break :status windows.ntdll.NtDeviceIoControlFile(c.socket, null, null, context, &s.iosb, windows.IOCTL.AFD.CONNECT, info, @intCast(@offsetOf(@TypeOf(info.*), "address") + len), null, 0);
                },
                .unix => |unix| status: {
                    s.request = .{ .connect_unix = .{ .address = .{ .path = @splat(0) } } };
                    const info = &s.request.connect_unix;
                    // The path is informational to AFD: its socket option
                    // named the target already. As std, a suffix.
                    const n = @min(unix.path.len, info.address.path.len - 1);
                    @memcpy(info.address.path[0..n], unix.path[unix.path.len - n ..]);
                    break :status windows.ntdll.NtDeviceIoControlFile(c.socket, null, null, context, &s.iosb, windows.IOCTL.AFD.CONNECT, info, @sizeOf(@TypeOf(info.*)), null, 0);
                },
            };
            return b.settle(o, status);
        },
        .read_at => |r| {
            const len: u32 = @intCast(@min(r.buffer.len, std.math.maxInt(u32)));
            s.request = .{ .offset = @intCast(r.offset) };
            if (!b.bindHandle(r.file)) {
                // A handle opened for synchronous calls: the call waits here.
                const status = windows.ntdll.NtReadFile(r.file, null, null, null, &s.iosb, r.buffer.ptr, len, &s.request.offset, null);
                return b.advance(o, status, s.iosb.Information);
            }
            s.target = r.file;
            return b.settle(o, windows.ntdll.NtReadFile(r.file, null, null, context, &s.iosb, r.buffer.ptr, len, &s.request.offset, null));
        },
        .write_at => |w| {
            const len: u32 = @intCast(@min(w.bytes.len, std.math.maxInt(u32)));
            s.request = .{ .offset = @intCast(w.offset) };
            if (!b.bindHandle(w.file)) {
                const status = windows.ntdll.NtWriteFile(w.file, null, null, null, &s.iosb, w.bytes.ptr, len, &s.request.offset, null);
                return b.advance(o, status, s.iosb.Information);
            }
            s.target = w.file;
            return b.settle(o, windows.ntdll.NtWriteFile(w.file, null, null, context, &s.iosb, w.bytes.ptr, len, &s.request.offset, null));
        },
        .sync => |file| {
            // No flush is overlapped: it waits here (the runtime sends file
            // syncs to its `sync` lane instead).
            const status = windows.ntdll.NtFlushBuffersFile(file, &s.iosb);
            return b.advance(o, status, 0);
        },
        .close => |handle| {
            sys.cancel(handle, null);
            sys.close(handle);
            o.result = .{ .close = {} };
            return true;
        },
        .abort => |handle| {
            sys.cancel(handle, null);
            o.result = .{ .abort = 0 };
            return true;
        },
        .timer => |deadline| return b.submitTimer(o, deadline, context),
        .wait => |w| switch (w) {
            .readable, .writable => |socket| {
                if (!b.bindHandle(socket)) {
                    o.result = .{ .wait = error.Unsupported };
                    return true;
                }
                s.target = socket;
                s.stage = .poll;
                const wanted = if (w == .readable) afd.events.readable else afd.events.writable;
                s.request = .{ .poll = .{ .timeout = std.math.maxInt(i64), .count = 1, .exclusive = 0, .handles = .{.{ .handle = socket, .events = wanted, .status = .SUCCESS }} } };
                const info = &s.request.poll;
                const status = windows.ntdll.NtDeviceIoControlFile(socket, null, null, context, &s.iosb, windows.IOCTL.AFD.POLL, info, @sizeOf(afd.PollInfo), info, @sizeOf(afd.PollInfo));
                return b.settle(o, status);
            },
            .object => |object| {
                const packet = try sys.createWaitPacket();
                s.stage = .packet;
                s.request = .{ .packet = .{ .packet = packet, .timer = null } };
                sys.armWaitPacket(packet, b.port, object, key(), @intFromPtr(context)) catch |err| { // safe: the context, as a number
                    sys.close(packet);
                    return err;
                };
                return false;
            },
        },
    }
}

fn submitIo(b: *Iocp, o: anytype, operation: *const Io.Operation, context: ?*anyopaque) error{ SystemResources, Unexpected }!bool {
    const s = &o.state.scratch.iocp;
    switch (operation.*) {
        .net_read => |r| {
            if (!b.bindHandle(r.socket_handle)) return b.refuse(o);
            s.target = r.socket_handle;
            s.request = .{ .receive = .{ .info = undefined, .buffers = undefined } };
            const q = &s.request.receive;
            var n: u32 = 0;
            for (r.data) |d| addBuffer(.@"var", &q.buffers, &n, d);
            q.info = .{ .BufferArray = &q.buffers, .BufferCount = n, .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true }, .TdiFlags = .{ .NORMAL = true } };
            return b.settle(o, windows.ntdll.NtDeviceIoControlFile(r.socket_handle, null, null, context, &s.iosb, windows.IOCTL.AFD.RECEIVE, &q.info, @sizeOf(windows.AFD.RECV_INFO), null, 0));
        },
        .net_write => |w| {
            if (!b.bindHandle(w.socket_handle)) return b.refuse(o);
            s.target = w.socket_handle;
            s.request = .{ .send = .{ .info = undefined, .buffers = undefined, .splat = undefined } };
            const q = &s.request.send;
            const n = gatherWrite(&q.buffers, &q.splat, w.header, w.data, w.splat);
            q.info = .{ .BufferArray = &q.buffers, .BufferCount = n, .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true }, .TdiFlags = .{} };
            return b.settle(o, windows.ntdll.NtDeviceIoControlFile(w.socket_handle, null, null, context, &s.iosb, windows.IOCTL.AFD.SEND, &q.info, @sizeOf(windows.AFD.SEND_INFO), null, 0));
        },
        .net_receive => |r| {
            if (!b.bindHandle(r.socket_handle)) return b.refuse(o);
            s.target = r.socket_handle;
            s.request = .{ .datagram_in = undefined };
            const q = &s.request.datagram_in;
            const status = receiveDatagram(r.socket_handle, q, r.data_buffer, r.flags, &s.iosb, context);
            return b.settle(o, status);
        },
        .net_send => |m| {
            if (!b.bindHandle(m.socket_handle)) return b.refuse(o);
            s.target = m.socket_handle;
            s.stage = .send;
            s.request = .{ .datagram_out = undefined };
            return b.settle(o, sendDatagram(m.socket_handle, &s.request.datagram_out, &m.messages[0], &s.iosb, context));
        },
        .file_read_streaming => |f| {
            const buffer = firstBuffer(f.data);
            if (!b.bindHandle(f.file.handle)) {
                const status = windows.ntdll.NtReadFile(f.file.handle, null, null, null, &s.iosb, buffer.ptr, @intCast(buffer.len), null, null);
                return b.advance(o, status, s.iosb.Information);
            }
            s.target = f.file.handle;
            return b.settle(o, windows.ntdll.NtReadFile(f.file.handle, null, null, context, &s.iosb, buffer.ptr, @intCast(buffer.len), null, null));
        },
        .file_write_streaming => |f| {
            const bytes = firstChunk(f.header, f.data, f.splat);
            if (!b.bindHandle(f.file.handle)) {
                const status = windows.ntdll.NtWriteFile(f.file.handle, null, null, null, &s.iosb, bytes.ptr, @intCast(bytes.len), null, null);
                return b.advance(o, status, s.iosb.Information);
            }
            s.target = f.file.handle;
            return b.settle(o, windows.ntdll.NtWriteFile(f.file.handle, null, null, context, &s.iosb, bytes.ptr, @intCast(bytes.len), null, null));
        },
        .device_io_control => |d| {
            const control = switch (d.code.DeviceType) {
                .FILE_SYSTEM, .NAMED_PIPE => &windows.ntdll.NtFsControlFile,
                else => &windows.ntdll.NtDeviceIoControlFile,
            };
            const in: ?*const anyopaque = if (d.in.len > 0) d.in.ptr else null;
            const out: ?*anyopaque = if (d.out.len > 0) d.out.ptr else null;
            if (!b.bindHandle(d.file.handle)) {
                const status = control(d.file.handle, null, null, null, &s.iosb, d.code, in, @intCast(d.in.len), out, @intCast(d.out.len));
                return b.advance(o, status, s.iosb.Information);
            }
            s.target = d.file.handle;
            return b.settle(o, control(d.file.handle, null, null, context, &s.iosb, d.code, in, @intCast(d.in.len), out, @intCast(d.out.len)));
        },
    }
}

/// A `real` or `boot` timer: a waitable timer of its own, absolute for
/// `real`, whose packet completes the operation.
fn submitTimer(b: *Iocp, o: anytype, deadline: Io.Clock.Timestamp, context: ?*anyopaque) error{ SystemResources, Unexpected }!bool {
    const s = &o.state.scratch.iocp;
    const timer, _ = try sys.createTimer();
    errdefer sys.close(timer);
    const packet = try sys.createWaitPacket();
    errdefer sys.close(packet);
    const due: i64 = switch (deadline.clock) {
        // 100 ns since 1601: the timer follows changes to the clock.
        .real => @intCast(std.math.clamp(@divTrunc(deadline.raw.nanoseconds - std.time.epoch.windows * std.time.ns_per_s, 100), 1, std.math.maxInt(i64))),
        else => due: {
            const now = deadline.clock.now(system()).nanoseconds;
            break :due -@as(i64, @intCast(std.math.clamp(@divTrunc(deadline.raw.nanoseconds - now + 99, 100), 1, std.math.maxInt(i64))));
        },
    };
    try sys.setTimer(timer, due);
    try sys.armWaitPacket(packet, b.port, timer, key(), @intFromPtr(context)); // safe: the context, as a number
    s.stage = .packet;
    s.request = .{ .packet = .{ .packet = packet, .timer = timer } };
    return false;
}

fn system() Io {
    return Threaded.global_single_threaded.io();
}

/// A handle that cannot be bound to the port: the operation ends at once.
fn refuse(b: *Iocp, o: anytype) bool {
    _ = b;
    o.result = results.of(o, .INVALID_HANDLE, 0);
    return true;
}

/// After a call returned `status`: true when the operation is over (its
/// result set); false when an entry follows.
fn settle(b: *Iocp, o: anytype, status: Status) bool {
    if (results.entryFollows(status)) return false;
    // The status block is written for a call that succeeded at once, and
    // left alone for one that failed at once.
    const information = if (status == .SUCCESS or @backingInt(status) >> 30 == 0b01) o.state.scratch.iocp.iosb.Information else 0;
    return b.advance(o, status, information);
}

/// The current request of `o` ended with `status`: true when the
/// operation is over (its result set); false when its next request is
/// under way.
fn advance(b: *Iocp, o: anytype, first_status: Status, first_information: usize) bool {
    const s = &o.state.scratch.iocp;
    const context: ?*anyopaque = @ptrFromInt(contextOf(@intFromPtr(o), .op)); // safe: read back as the `Op` in `dispatch`
    var status = first_status;
    var information = first_information;
    while (true) switch (s.stage) {
        .main, .poll => {
            o.result = results.of(o, status, information);
            return true;
        },
        .packet => {
            const p = s.request.packet;
            sys.close(p.packet);
            if (p.timer) |timer| sys.close(timer);
            o.result = results.of(o, status, 0);
            return true;
        },
        .listen => {
            const a = &s.request.accept;
            if (status != .SUCCESS) {
                o.result = results.of(o, status, 0);
                return true;
            }
            // Reported, not taken yet: a cancel puts it back for the next
            // accept, so nothing is lost.
            if (o.state.canceled) {
                afd.deferAccept(s.target, a.response.info.Sequence);
                o.result = .{ .accept = error.Canceled };
                return true;
            }
            const family = a.response.address.ip.any.family;
            a.socket = afd.open(family, .stream, null) catch |err| {
                afd.deferAccept(s.target, a.response.info.Sequence);
                o.result = .{ .accept = switch (err) {
                    error.SystemResources => error.SystemResources,
                    else => error.Unexpected,
                } };
                return true;
            };
            a.info = .{ .UseSAN = .FALSE, .Sequence = a.response.info.Sequence, .AcceptHandle = a.socket };
            s.stage = .accept;
            status = windows.ntdll.NtDeviceIoControlFile(s.target, null, null, context, &s.iosb, windows.IOCTL.AFD.ACCEPT, &a.info, @sizeOf(windows.AFD.ACCEPT_INFO), null, 0);
            if (results.entryFollows(status)) return false;
            information = 0;
        },
        .accept => {
            const a = &s.request.accept;
            if (status != .SUCCESS) {
                sys.close(a.socket);
                afd.deferAccept(s.target, a.response.info.Sequence);
                o.result = results.of(o, status, 0);
                return true;
            }
            // The new socket's calls finish on the port of the loop that
            // accepted it.
            _ = b.bindHandle(a.socket);
            o.result = .{ .accept = .{ .handle = a.socket, .address = Threaded.addressFromPosix(&a.response.address.ip) } };
            return true;
        },
        .send => {
            const m = o.kind.io.net_send;
            if (status != .SUCCESS) {
                o.result = .{ .io = sendEnded(o, status) };
                return true;
            }
            m.messages[s.sent].data_len = information;
            s.sent += 1;
            // The rest one by one; a cancel keeps what was sent.
            if (s.sent == m.messages.len or o.state.canceled) {
                o.result = .{ .io = .{ .net_send = .{ null, s.sent } } };
                return true;
            }
            status = sendDatagram(m.socket_handle, &s.request.datagram_out, &m.messages[s.sent], &s.iosb, context);
            if (results.entryFollows(status)) return false;
            information = if (status == .SUCCESS) s.iosb.Information else 0;
        },
    };
}

/// A multi-message send whose current message ended with `status`: what
/// went is kept. A cancel that ended it before any went is the
/// cancelation point's; after some went, the send reports them and the
/// cancel stays for the next point, as std's does.
fn sendEnded(o: anytype, status: Status) Io.Cancelable!Io.Operation.Result {
    const sent = o.state.scratch.iocp.sent;
    const ended = results.ended(status);
    if (ended and o.state.canceled) {
        if (sent == 0) return error.Canceled;
        return .{ .net_send = .{ null, sent } };
    }
    return .{ .net_send = .{ if (ended) error.SocketUnconnected else results.send(status), sent } };
}

/// Asks the kernel to end `o`. True when it ended here: its result is set
/// and no entry follows.
pub fn cancel(b: *Iocp, o: anytype) bool {
    _ = b;
    const s = &o.state.scratch.iocp;
    switch (s.stage) {
        .packet => switch (sys.disarmWaitPacket(s.request.packet.packet)) {
            .removed => {
                const p = s.request.packet;
                sys.close(p.packet);
                if (p.timer) |timer| sys.close(timer);
                o.result = results.of(o, .CANCELLED, 0);
                return true;
            },
            .delivered, .arriving => return false,
        },
        else => {
            sys.cancel(s.target, &s.iosb);
            return false;
        },
    }
}

// Batches.

/// Whether a batch operation can wait in the kernel here: the rest run
/// as std's own code.
pub fn canPend(operation: Io.Operation) bool {
    return switch (operation) {
        .file_read_streaming => |f| f.file.flags.nonblocking,
        .file_write_streaming => |f| f.file.flags.nonblocking,
        .device_io_control => |d| d.file.flags.nonblocking,
        .net_read, .net_write, .net_receive, .net_send => true,
    };
}

/// A batch's operation: null when the kernel holds it (its outcome comes
/// to the sink under `token`), else its outcome now.
pub fn submitPending(b: *Iocp, token: pending.Token, operation: Io.Operation) error{ SystemResources, Unexpected }!?pending.Outcome {
    const handle = handleOf(operation);
    if (!b.bindHandle(handle)) return error.Unexpected;
    const slot = b.free orelse return error.SystemResources;
    b.free = slot.next;
    slot.* = .{ .owner = b, .token = token, .target = handle };
    pending.backendWord(token.pending()).* = @intFromPtr(slot); // safe: read back as the slot by `cancelPending`
    const context: ?*anyopaque = @ptrFromInt(contextOf(@intFromPtr(slot), .slot)); // safe: read back as the slot in `dispatch`
    const status = switch (operation) {
        .net_read => |r| status: {
            slot.request = .{ .receive = .{ .info = undefined, .buffer = .{toBuffer(.@"var", firstBuffer(r.data))} } };
            const q = &slot.request.receive;
            q.info = .{ .BufferArray = &q.buffer, .BufferCount = 1, .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true }, .TdiFlags = .{ .NORMAL = true } };
            break :status windows.ntdll.NtDeviceIoControlFile(handle, null, null, context, &slot.iosb, windows.IOCTL.AFD.RECEIVE, &q.info, @sizeOf(windows.AFD.RECV_INFO), null, 0);
        },
        .net_write => |w| status: {
            slot.request = .{ .send = .{ .info = undefined, .buffer = .{toBuffer(.@"const", firstChunk(w.header, w.data, w.splat))} } };
            const q = &slot.request.send;
            q.info = .{ .BufferArray = &q.buffer, .BufferCount = 1, .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true }, .TdiFlags = .{} };
            break :status windows.ntdll.NtDeviceIoControlFile(handle, null, null, context, &slot.iosb, windows.IOCTL.AFD.SEND, &q.info, @sizeOf(windows.AFD.SEND_INFO), null, 0);
        },
        .net_receive => |r| status: {
            slot.request = .{ .datagram_in = undefined };
            break :status receiveDatagram(handle, &slot.request.datagram_in, r.data_buffer, r.flags, &slot.iosb, context);
        },
        .net_send => |m| status: {
            slot.request = .{ .datagram_out = undefined };
            break :status sendDatagram(handle, &slot.request.datagram_out, &m.messages[0], &slot.iosb, context);
        },
        .file_read_streaming => |f| status: {
            const buffer = firstBuffer(f.data);
            break :status windows.ntdll.NtReadFile(handle, null, null, context, &slot.iosb, buffer.ptr, @intCast(buffer.len), null, null);
        },
        .file_write_streaming => |f| status: {
            const bytes = firstChunk(f.header, f.data, f.splat);
            break :status windows.ntdll.NtWriteFile(handle, null, null, context, &slot.iosb, bytes.ptr, @intCast(bytes.len), null, null);
        },
        .device_io_control => |d| status: {
            const control = switch (d.code.DeviceType) {
                .FILE_SYSTEM, .NAMED_PIPE => &windows.ntdll.NtFsControlFile,
                else => &windows.ntdll.NtDeviceIoControlFile,
            };
            break :status control(handle, null, null, context, &slot.iosb, d.code, if (d.in.len > 0) d.in.ptr else null, @intCast(d.in.len), if (d.out.len > 0) d.out.ptr else null, @intCast(d.out.len));
        },
    };
    if (results.entryFollows(status)) return null;
    const information = if (status == .SUCCESS or @backingInt(status) >> 30 == 0b01) slot.iosb.Information else 0;
    const done = outcome(slot, operation, status, information);
    b.release(slot);
    return done;
}

pub fn cancelPending(b: *Iocp, token: pending.Token) void {
    _ = b;
    const slot: *Slot = @ptrFromInt(pending.backendWord(token.pending()).*);
    sys.cancel(slot.target, &slot.iosb);
}

fn release(b: *Iocp, slot: *Slot) void {
    slot.next = b.free;
    b.free = slot;
}

fn outcome(slot: *Slot, operation: Io.Operation, status: Status, information: usize) pending.Outcome {
    const address: ?*const Threaded.PosixAddress = if (operation == .net_receive) &slot.request.datagram_in.address else null;
    return results.ofPending(operation, status, information, address);
}

fn handleOf(operation: Io.Operation) Handle {
    return switch (operation) {
        .net_read => |r| r.socket_handle,
        .net_write => |w| w.socket_handle,
        .net_receive => |r| r.socket_handle,
        .net_send => |s| s.socket_handle,
        .file_read_streaming => |f| f.file.handle,
        .file_write_streaming => |f| f.file.handle,
        .device_io_control => |d| d.file.handle,
    };
}

// Completion.

pub fn poll(b: *Iocp, wait: Wait, sink: anytype) error{ SystemResources, Unexpected }!void {
    // A host's port: the host takes its entries and hands reactor's to
    // `complete`.
    if (b.hosted) return;
    var timeout: ?u64 = switch (wait) {
        .nowait => 0,
        .forever => null,
        .ns => |ns| b.timeoutFor(ns),
    };
    var entries: [64]sys.Entry = undefined;
    while (true) {
        const taken = try sys.remove(b.port, &entries, timeout);
        for (taken) |e| b.dispatch(e, sink);
        if (taken.len < entries.len) return;
        timeout = 0;
    }
}

/// The entries a host took from its own port that carry reactor's key.
pub fn complete(b: *Iocp, entries: []const sys.Entry, sink: anytype) void {
    for (entries) |e| b.dispatch(e, sink);
}

/// How long the port's own wait may last for a wait of `ns`, in 100 ns
/// units: none when the precise timer's entry ends it.
fn timeoutFor(b: *Iocp, ns: u64) ?u64 {
    if (ns == 0) return 0;
    const units = std.math.divCeil(u64, ns, 100) catch unreachable; // unreachable: the divisor is a constant
    if (b.precise and b.armTimer(ns)) return null;
    return units;
}

/// A timer armed this close before the deadline asked for is kept: the
/// early wake costs a pass, re-arming costs two calls.
const timer_slack_ns = 50 * std.time.ns_per_us;

/// Arms the precise timer to fire in `ns`; false when it cannot be now
/// (its last entry is on its way).
fn armTimer(b: *Iocp, ns: u64) bool {
    const now: u64 = @intCast(@max(Io.Clock.awake.now(system()).nanoseconds, 0));
    const at = now + ns;
    if (b.timer_armed) {
        if (b.timer_at <= at and at - b.timer_at <= timer_slack_ns) return true;
        switch (sys.disarmWaitPacket(b.timer_packet)) {
            .removed, .delivered => b.timer_armed = false,
            .arriving => return false,
        }
    }
    const due = -@as(i64, @intCast(@min(std.math.divCeil(u64, ns, 100) catch unreachable, std.math.maxInt(i63)))); // unreachable: the divisor is a constant
    sys.setTimer(b.timer, due) catch return false;
    sys.armWaitPacket(b.timer_packet, b.port, b.timer, key(), contextOf(0, .timer)) catch return false;
    b.timer_armed = true;
    b.timer_at = at;
    return true;
}

fn dispatch(b: *Iocp, e: sys.Entry, sink: anytype) void {
    if (e.key != key()) return;
    const address = e.context & ~@as(usize, 7);
    switch (@as(Tag, @fromBackingInt(@as(u3, @truncate(e.context))))) {
        .op => {
            const o: *OpOf(@TypeOf(sink)) = @ptrFromInt(address);
            const s = &o.state.scratch.iocp;
            if (s.owner != b) return s.owner.forward(e);
            if (b.advance(o, e.iosb.u.Status, e.iosb.Information)) sink.complete(o);
        },
        .slot => {
            const slot: *Slot = @ptrFromInt(address);
            if (slot.owner != b) return slot.owner.forward(e);
            const token = slot.token;
            const result = outcome(slot, pending.unpack(token.pending()), e.iosb.u.Status, e.iosb.Information);
            b.release(slot);
            sink.completePending(token, result);
        },
        .wake => b.wake_pending.store(false, .release),
        .timer => b.timer_armed = false,
    }
}

/// An entry for an operation this loop did not submit: its handle is bound
/// to this loop's port. It goes to the loop that did.
fn forward(owner: *Iocp, e: sys.Entry) void {
    sys.post(owner.port, e.key, e.context, e.iosb.u.Status, e.iosb.Information) catch |err|
        std.debug.panic("reactor: an entry could not be passed on to its loop: {t}", .{err});
}

/// From any thread: ends a waiting `poll`.
pub fn wake(b: *Iocp) void {
    if (b.wake_pending.swap(true, .acq_rel)) return;
    sys.post(b.port, key(), contextOf(0, .wake), .SUCCESS, 0) catch b.wake_pending.store(false, .release);
}

/// The port: what a host waits on, or its own.
pub fn waitHandle(b: *Iocp) Handle {
    return b.port;
}

// Requests.

fn receiveDatagram(socket: Handle, q: *DatagramIn, buffer: []u8, flags: net.ReceiveFlags, iosb: *windows.IO_STATUS_BLOCK, context: ?*anyopaque) Status {
    q.* = .{ .info = undefined, .buffer = .{toBuffer(.@"var", buffer)}, .address = undefined, .address_len = @sizeOf(Threaded.PosixAddress) };
    q.info = .{
        .BufferArray = &q.buffer,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{ .NORMAL = !flags.oob, .EXPEDITED = flags.oob, .PEEK = flags.peek },
        .Address = &q.address,
        .AddressLength = &q.address_len,
    };
    return windows.ntdll.NtDeviceIoControlFile(socket, null, null, context, iosb, windows.IOCTL.AFD.RECEIVE_DATAGRAM, &q.info, @sizeOf(windows.AFD.RECV_DATAGRAM_INFO), null, 0);
}

fn sendDatagram(socket: Handle, q: *DatagramOut, message: *const net.OutgoingMessage, iosb: *windows.IO_STATUS_BLOCK, context: ?*anyopaque) Status {
    q.* = .{ .info = undefined, .buffer = .{.{ .buf = message.data_ptr, .len = @intCast(@min(message.data_len, std.math.maxInt(u32))) }}, .address = undefined };
    const len = Threaded.addressToPosix(message.address, &q.address);
    q.info = .{
        .BufferArray = &q.buffer,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiRequest = undefined,
        .TdiConnInfo = .{
            .UserDataLength = undefined,
            .UserData = undefined,
            .OptionsLength = undefined,
            .Options = undefined,
            .RemoteAddressLength = @bitCast(len),
            .RemoteAddress = &q.address,
        },
    };
    return windows.ntdll.NtDeviceIoControlFile(socket, null, null, context, iosb, windows.IOCTL.AFD.SEND_DATAGRAM, &q.info, @sizeOf(windows.AFD.SEND_DATAGRAM_INFO), null, 0);
}

fn toBuffer(comptime mutability: windows.AFD.Mutability, bytes: switch (mutability) {
    .@"const" => []const u8,
    .@"var" => []u8,
}) windows.AFD.WSABUF(mutability) {
    return .{ .buf = bytes.ptr, .len = @intCast(@min(bytes.len, std.math.maxInt(u32))) };
}

fn addBuffer(comptime mutability: windows.AFD.Mutability, buffers: []windows.AFD.WSABUF(mutability), n: *u32, bytes: switch (mutability) {
    .@"const" => []const u8,
    .@"var" => []u8,
}) void {
    if (bytes.len == 0 or n.* == buffers.len) return;
    buffers[n.*] = toBuffer(mutability, bytes);
    n.* += 1;
}

/// A write's buffers as `Threaded` lays them out: the header, the data,
/// and the splat (a one-byte pattern expanded through `splat_buffer`).
fn gatherWrite(buffers: []windows.AFD.WSABUF(.@"const"), splat_buffer: *[Threaded.splat_buffer_size]u8, header: []const u8, data: []const []const u8, splat: usize) u32 {
    var n: u32 = 0;
    addBuffer(.@"const", buffers, &n, header);
    for (data[0 .. data.len - 1]) |d| addBuffer(.@"const", buffers, &n, d);
    const pattern = data[data.len - 1];
    switch (splat) {
        0 => {},
        1 => addBuffer(.@"const", buffers, &n, pattern),
        else => if (pattern.len == 1) {
            const len = @min(splat, splat_buffer.len);
            @memset(splat_buffer[0..len], pattern[0]);
            var remaining = splat;
            while (remaining > 0 and n < buffers.len) {
                const chunk = @min(remaining, len);
                addBuffer(.@"const", buffers, &n, splat_buffer[0..chunk]);
                remaining -= chunk;
            }
        } else for (0..@min(splat, buffers.len)) |_| addBuffer(.@"const", buffers, &n, pattern),
    }
    return n;
}

fn firstBuffer(data: []const []u8) []u8 {
    for (data) |d| if (d.len > 0) return d[0..@min(d.len, std.math.maxInt(u32))];
    return &.{};
}

/// The first bytes a streaming write would send: a write may be short.
fn firstChunk(header: []const u8, data: []const []const u8, splat: usize) []const u8 {
    if (header.len > 0) return header[0..@min(header.len, std.math.maxInt(u32))];
    for (data[0 .. data.len - 1]) |d| if (d.len > 0) return d[0..@min(d.len, std.math.maxInt(u32))];
    const last = data[data.len - 1];
    if (splat > 0 and last.len > 0) return last[0..@min(last.len, std.math.maxInt(u32))];
    return &.{};
}
