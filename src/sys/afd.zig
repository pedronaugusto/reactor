//! AFD, the driver under Windows sockets: making an endpoint, and the
//! control calls around an evented connect or accept that complete at once
//! (options, bind, the local address). The calls that wait go through a
//! completion port, issued by the IOCP backend with the requests defined
//! here. Errors are std's, as `Io.Threaded` reports them.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const Threaded = Io.Threaded;
const Handle = windows.HANDLE;
const Status = windows.NTSTATUS;

pub const OpenError = error{
    AddressFamilyUnsupported,
    ProtocolUnsupportedByAddressFamily,
    SocketModeUnsupported,
    OptionUnsupported,
    SystemResources,
    Unexpected,
};

/// A socket of `family`, opened for overlapped calls and bound to no port.
pub fn open(family: posix.sa_family_t, mode: net.Socket.Mode, protocol: ?net.Protocol) OpenError!Handle {
    const kind, const proto = try Threaded.posixSocketModeProtocol(family, mode, protocol);
    var handle: Handle = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    while (true) switch (windows.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .RIGHTS = .{ .WRITE_DAC = true }, .SYNCHRONIZE = true },
            .GENERIC = .{ .WRITE = true, .READ = true },
        },
        &.{ .ObjectName = @constCast(&windows.UNICODE_STRING.init(windows.AFD.DEVICE_NAME ++ .{ '\\', 'E', 'n', 'd', 'p', 'o', 'i', 'n', 't' })) }, // safe: the system only reads the name
        &iosb,
        null,
        .{},
        .{ .READ = true, .WRITE = true },
        .OPEN_IF,
        .{ .IO = .ASYNCHRONOUS },
        &windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION{ .Value = .{
            .EndpointType = .{
                .CONNECTIONLESS = switch (mode) {
                    .stream, .seqpacket, .rdm => false,
                    .dgram, .raw => true,
                },
                .MESSAGEMODE = mode != .stream,
                .RAW = mode == .raw,
            },
            .GroupID = 0,
            .AddressFamily = family,
            .SocketType = @bitCast(kind),
            .Protocol = @bitCast(proto),
            .TransportDeviceNameLength = 0,
            .TransportDeviceName = undefined,
        } },
        @sizeOf(windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION),
    )) {
        .SUCCESS => return handle,
        .CANCELLED => continue,
        .PROTOCOL_NOT_SUPPORTED => return error.AddressFamilyUnsupported,
        .NO_SUCH_FILE => return error.ProtocolUnsupportedByAddressFamily,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    };
}

/// A control call the driver answers at once (options, bind, an address):
/// its status. It names no context, so a socket bound to a port gets no
/// entry for it. Should the driver ever pend one, the call waits for the
/// status block, which the system writes when it is done.
pub fn control(handle: Handle, code: windows.CTL_CODE, in: []const u8, out: []u8) Status {
    return answered(handle, code, in, out).status;
}

/// What a control call answered: its status, and how many bytes of the
/// output buffer it wrote.
pub const Answer = struct { status: Status, len: usize };

fn answered(handle: Handle, code: windows.CTL_CODE, in: []const u8, out: []u8) Answer {
    var iosb: windows.IO_STATUS_BLOCK = .{ .u = .{ .Status = .PENDING }, .Information = 0 };
    const status = windows.ntdll.NtDeviceIoControlFile(handle, null, null, null, &iosb, code, if (in.len > 0) in.ptr else null, @intCast(in.len), if (out.len > 0) out.ptr else null, @intCast(out.len));
    if (status != .PENDING) return .{ .status = status, .len = iosb.Information };
    const status_word: *const u32 = @ptrCast(&iosb.u.Status); // safe: the status is a 32-bit word the kernel writes
    while (@atomicLoad(u32, status_word, .acquire) == @backingInt(Status.PENDING)) _ = windows.ntdll.NtYieldExecution();
    return .{ .status = iosb.u.Status, .len = iosb.Information };
}

/// AFD's `SOCKOPT` call, which the transport answers. A set reads `value`.
/// A get answers in the call's output buffer, not at the info's value
/// pointer (with none, `BUFFER_TOO_SMALL`), and a boolean in one byte: so
/// `value` is that buffer too, and the answer says how much of it was
/// written. Options AFD keeps itself (`SO_SNDBUF`) are not the
/// transport's: `NOT_SUPPORTED` here, `information` there.
pub fn option(handle: Handle, mode: windows.AFD.SOCKOPT_INFO.Mode, level: i32, name: u32, value: []u8) Answer {
    const info: windows.AFD.SOCKOPT_INFO = .{ .mode = mode, .level = level, .optname = name, .optval = value.ptr, .optlen = value.len };
    return answered(handle, windows.IOCTL.AFD.SOCKOPT, std.mem.asBytes(&info), if (mode == .get) value else &.{});
}

/// Sets a socket option, as `setsockopt` would.
pub fn setOption(handle: Handle, level: i32, name: u32, value: anytype) error{ SystemResources, Unexpected }!void {
    var v = value;
    return switch (option(handle, .set, level, name, std.mem.asBytes(&v)).status) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

/// Sets one of AFD's own settings, such as the send buffer
/// (`SEND_WINDOW_SIZE`, Winsock's `SO_SNDBUF`).
pub fn setInformation(handle: Handle, kind: windows.AFD.INFORMATION.TYPE, value: u32) Status {
    var info: windows.AFD.INFORMATION = .{ .InformationType = kind, .Information = .{ .LargeInteger = 0 } };
    info.Information.Ulong = value;
    return control(handle, windows.IOCTL.AFD.SET_INFORMATION, std.mem.asBytes(&info), &.{});
}

/// Reads one of AFD's own settings into `value`.
pub fn getInformation(handle: Handle, kind: windows.AFD.INFORMATION.TYPE, value: *u32) Status {
    const query: windows.AFD.INFORMATION = .{ .InformationType = kind, .Information = .{ .LargeInteger = 0 } };
    var info: windows.AFD.INFORMATION = query;
    const status = control(handle, windows.IOCTL.AFD.GET_INFORMATION, std.mem.asBytes(&query), std.mem.asBytes(&info));
    value.* = info.Information.Ulong;
    return status;
}

/// How a bind shares its port with later binds: the first word of AFD's
/// bind, which std 0.17 calls a mode (its `Passive` is `reuse`, its
/// `Active` `wildcard`). A later bind of a port held `reuse` is let
/// through when it reuses too; one held any other way refuses it
/// (`SHARING_VIOLATION`, or `ACCESS_DENIED` for a bind that asked to
/// reuse). Winsock's `SO_EXCLUSIVEADDRUSE` is `exclusive` here: as an
/// option AFD takes it and does nothing.
pub const Share = enum(u32) {
    unique = 0,
    reuse = 1,
    wildcard = 2,
    exclusive = 3,

    /// The share Winsock gives a bind of `address`: `wildcard` for an
    /// unspecified address at port 0 (an end for a connect), `reuse` when
    /// the caller asked for `SO_REUSEADDR`, `unique` otherwise.
    pub fn of(address: *const net.IpAddress, reuse: bool) Share {
        if (address.getPort() == 0 and isUnspecified(address)) return .wildcard;
        return if (reuse) .reuse else .unique;
    }

    fn isUnspecified(address: *const net.IpAddress) bool {
        return switch (address.*) {
            .ip4 => |a| std.mem.allEqual(u8, &a.bytes, 0),
            .ip6 => |a| std.mem.allEqual(u8, &a.bytes, 0),
        };
    }
};

pub const BindError = error{ AccessDenied, AddressInUse, AddressUnavailable, SystemResources, Unexpected };

/// Binds the socket's own end to `address` (an unspecified one picks a
/// free port); returns the address bound. The refusals are named as
/// Winsock names them: `ACCESS_DENIED` (`WSAEACCES`: a port another socket
/// holds exclusively, or one in a range the system reserves) is
/// `AccessDenied`, the sharing statuses (`WSAEADDRINUSE`) `AddressInUse`,
/// `INVALID_ADDRESS_COMPONENT` (`WSAEADDRNOTAVAIL`: an address that is not
/// this machine's) `AddressUnavailable`.
pub fn bind(handle: Handle, address: *const net.IpAddress, share: Share) BindError!net.IpAddress {
    const Storage = extern struct { share: Share, address: Threaded.PosixAddress };
    var storage: Storage = .{ .share = share, .address = undefined };
    const len = Threaded.addressToPosix(address, &storage.address);
    const in = std.mem.asBytes(&storage)[0 .. @offsetOf(Storage, "address") + len];
    return switch (control(handle, windows.IOCTL.AFD.BIND, in, std.mem.asBytes(&storage.address)[0..len])) {
        .SUCCESS => Threaded.addressFromPosix(&storage.address),
        .ACCESS_DENIED => error.AccessDenied,
        .SHARING_VIOLATION, .ADDRESS_ALREADY_EXISTS => error.AddressInUse,
        .INVALID_ADDRESS_COMPONENT => error.AddressUnavailable,
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

/// Starts a bound stream socket listening, `backlog` connections held by
/// the kernel.
pub fn listen(handle: Handle, backlog: u31) error{ SystemResources, Unexpected }!void {
    const info: windows.AFD.LISTEN_INFO = .{ .UseSAN = .FALSE, .MaximumConnectionQueue = backlog, .UseDelayedAcceptance = .FALSE };
    return switch (control(handle, windows.IOCTL.AFD.START_LISTEN, std.mem.asBytes(&info), &.{})) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES, .NO_MEMORY => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

/// The Unix socket bound to no path, as std binds one before connecting.
pub fn bindUnixUnnamed(handle: Handle) error{ SystemResources, Unexpected }!void {
    const Storage = extern struct { share: Share, address: ws2_32.sockaddr.un };
    var storage: Storage = .{ .share = .unique, .address = .{ .path = @splat(0) } };
    return switch (control(handle, windows.IOCTL.AFD.BIND, std.mem.asBytes(&storage), std.mem.asBytes(&storage.address))) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

/// What `CONNECT` reads: three reserved words, then the peer's address.
pub fn ConnectInfo(comptime Address: type) type {
    return extern struct {
        reserved: [3]usize = @splat(0),
        address: Address,
    };
}

/// What `WAIT_FOR_LISTEN` fills: the pending connection's sequence and
/// its peer's address.
pub const ListenResponse = extern struct {
    info: windows.AFD.LISTEN_RESPONSE_INFO,
    address: extern union { ip: Threaded.PosixAddress, unix: ws2_32.sockaddr.un },
};

/// Puts a connection `WAIT_FOR_LISTEN` reported back in the listener's
/// queue, for the next accept.
pub fn deferAccept(listener: Handle, sequence: u32) void {
    const info: windows.AFD.DEFER_ACCEPT_INFO = .{ .Sequence = sequence, .Reject = .FALSE };
    _ = control(listener, windows.IOCTL.AFD.DEFER_ACCEPT, std.mem.asBytes(&info), &.{});
}

/// `AFD_POLL`'s events: what makes a socket ready.
pub const events = struct {
    pub const receive: u32 = 0x0001;
    pub const receive_expedited: u32 = 0x0002;
    pub const send: u32 = 0x0004;
    pub const disconnect: u32 = 0x0008;
    pub const abort: u32 = 0x0010;
    pub const local_close: u32 = 0x0020;
    pub const accept: u32 = 0x0080;
    pub const connect_fail: u32 = 0x0100;

    /// Data, end of stream, a pending connection, or an error.
    pub const readable = receive | disconnect | abort | local_close | accept | connect_fail;
    /// Room to send, or an error.
    pub const writable = send | abort | local_close | connect_fail;
};

/// `AFD_POLL_INFO` for one socket: in, the events asked for; out, those
/// that are ready.
pub const PollInfo = extern struct {
    timeout: i64,
    count: u32,
    exclusive: u32,
    handles: [1]PollHandle,
};

pub const PollHandle = extern struct {
    handle: Handle,
    events: u32,
    status: Status,
};
