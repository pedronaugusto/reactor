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
    var iosb: windows.IO_STATUS_BLOCK = .{ .u = .{ .Status = .PENDING }, .Information = 0 };
    const status = windows.ntdll.NtDeviceIoControlFile(handle, null, null, null, &iosb, code, if (in.len > 0) in.ptr else null, @intCast(in.len), if (out.len > 0) out.ptr else null, @intCast(out.len));
    if (status != .PENDING) return status;
    const status_word: *const u32 = @ptrCast(&iosb.u.Status); // safe: the status is a 32-bit word the kernel writes
    while (@atomicLoad(u32, status_word, .acquire) == @backingInt(Status.PENDING)) _ = windows.ntdll.NtYieldExecution();
    return iosb.u.Status;
}

/// Sets a socket option, as `setsockopt` would.
pub fn setOption(handle: Handle, level: i32, name: u32, value: anytype) error{ SystemResources, Unexpected }!void {
    var v = value;
    return option(handle, .set, level, name, std.mem.asBytes(&v));
}

/// A socket option call, its value as bytes.
pub fn option(handle: Handle, mode: windows.AFD.SOCKOPT_INFO.Mode, level: i32, name: u32, value: []u8) error{ SystemResources, Unexpected }!void {
    const info: windows.AFD.SOCKOPT_INFO = .{ .mode = mode, .level = level, .optname = name, .optval = value.ptr, .optlen = value.len };
    return switch (control(handle, windows.IOCTL.AFD.SOCKOPT, std.mem.asBytes(&info), &.{})) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

/// Binds the socket's own end to `address` (an unspecified one picks a
/// free port); returns the address bound.
pub fn bind(handle: Handle, address: *const net.IpAddress, mode: windows.AFD.BIND_INFO.MODE) error{ AddressInUse, SystemResources, Unexpected }!net.IpAddress {
    const Storage = extern struct { info: windows.AFD.BIND_INFO, address: Threaded.PosixAddress };
    var storage: Storage = .{ .info = .{ .Mode = mode }, .address = undefined };
    const len = Threaded.addressToPosix(address, &storage.address);
    const in = std.mem.asBytes(&storage)[0 .. @offsetOf(Storage, "address") + len];
    return switch (control(handle, windows.IOCTL.AFD.BIND, in, std.mem.asBytes(&storage.address)[0..len])) {
        .SUCCESS => Threaded.addressFromPosix(&storage.address),
        .SHARING_VIOLATION, .ADDRESS_ALREADY_EXISTS => error.AddressInUse,
        .INSUFFICIENT_RESOURCES => error.SystemResources,
        else => |status| windows.unexpectedStatus(status),
    };
}

/// The Unix socket bound to no path, as std binds one before connecting.
pub fn bindUnixUnnamed(handle: Handle) error{ SystemResources, Unexpected }!void {
    const Storage = extern struct { info: windows.AFD.BIND_INFO, address: ws2_32.sockaddr.un };
    var storage: Storage = .{ .info = .{ .Mode = .Unix }, .address = .{ .path = @splat(0) } };
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

test "probe: a Unix connect's statuses by bind and listener (Windows)" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const ws = struct {
        const Socket = windows.HANDLE;
        extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
        extern "ws2_32" fn socket(family: i32, kind: i32, protocol: i32) callconv(.winapi) Socket;
        extern "ws2_32" fn bind(s: Socket, name: *const anyopaque, len: i32) callconv(.winapi) i32;
        extern "ws2_32" fn listen(s: Socket, backlog: i32) callconv(.winapi) i32;
        extern "ws2_32" fn closesocket(s: Socket) callconv(.winapi) i32;
    };
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var data: [512]u8 = undefined;
    _ = ws.WSAStartup(0x0202, &data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const Listener = enum { std_slash, std_backslash, winsock_slash, winsock_backslash };
    const Bind = enum { none, family, family_nul, whole };
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(gpa);
    for (std.enums.values(Listener)) |l| {
        const name = try gpa.print("{s}\\{t}", .{ root, l });
        defer gpa.free(name);
        if (l == .std_slash or l == .winsock_slash) std.mem.replaceScalar(u8, name, '\\', '/');
        const address = try net.UnixAddress.init(name);
        var server: ?net.Server = null;
        var listener: ?ws.Socket = null;
        switch (l) {
            .std_slash, .std_backslash => server = try address.listen(io, .{}),
            .winsock_slash, .winsock_backslash => {
                const s = ws.socket(ws2_32.AF.UNIX, ws2_32.SOCK.STREAM, 0);
                var un: ws2_32.sockaddr.un = .{ .path = @splat(0) };
                @memcpy(un.path[0..name.len], name);
                const rb = ws.bind(s, &un, @intCast(@offsetOf(ws2_32.sockaddr.un, "path") + name.len + 1));
                const rl = ws.listen(s, 16);
                try report.print(gpa, "{t}: winsock bind {d} listen {d}\n", .{ l, rb, rl });
                listener = s;
            },
        }
        defer if (server) |*s| s.deinit(io);
        defer if (listener) |s| {
            _ = ws.closesocket(s);
        };
        for (std.enums.values(Bind)) |b| {
            const handle = try open(ws2_32.AF.UNIX, .stream, null);
            defer windows.CloseHandle(handle);
            const path = try Threaded.sliceToPrefixedFileW(null, name, .{ .allow_relative = false });
            var target: windows.AFD.SOCKOPT_INFO.UNIX_PATH = .{ .Path = path.data };
            const bytes = std.mem.asBytes(&target)[0 .. @offsetOf(windows.AFD.SOCKOPT_INFO.UNIX_PATH, "Path") + @sizeOf(windows.WCHAR) * path.len];
            const opt: Status = if (option(handle, .special, 0, ws2_32.SO.UNIX_PATH, bytes)) |_| .SUCCESS else |_| .UNSUCCESSFUL;
            const Storage = extern struct { info: windows.AFD.BIND_INFO, address: ws2_32.sockaddr.un };
            var storage: Storage = .{ .info = .{ .Mode = .Unix }, .address = .{ .path = @splat(0) } };
            const head = @offsetOf(Storage, "address");
            const fam = @offsetOf(ws2_32.sockaddr.un, "path");
            const bound: Status = switch (b) {
                .none => .SUCCESS,
                .family => control(handle, windows.IOCTL.AFD.BIND, std.mem.asBytes(&storage)[0 .. head + fam], std.mem.asBytes(&storage.address)),
                .family_nul => control(handle, windows.IOCTL.AFD.BIND, std.mem.asBytes(&storage)[0 .. head + fam + 1], std.mem.asBytes(&storage.address)),
                .whole => control(handle, windows.IOCTL.AFD.BIND, std.mem.asBytes(&storage), std.mem.asBytes(&storage.address)),
            };
            var request: ConnectInfo(ws2_32.sockaddr.un) = .{ .address = .{ .path = @splat(0) } };
            const n = @min(name.len, request.address.path.len - 1);
            @memcpy(request.address.path[0..n], name[name.len - n ..]);
            const connected = control(handle, windows.IOCTL.AFD.CONNECT, std.mem.asBytes(&request), &.{});
            try report.print(gpa, "{t} {t}: option {t} bind {t} connect {t}\n", .{ l, b, opt, bound, connected });
        }
    }
    std.debug.print("{s}", .{report.items});
    return error.ProbeReport;
}
