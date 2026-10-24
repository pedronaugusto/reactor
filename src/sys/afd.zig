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

test "probe: a Unix connect through Winsock, read and written as std's stream (Windows)" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const ws = struct {
        const Socket = windows.HANDLE;
        extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
        extern "ws2_32" fn socket(family: i32, kind: i32, protocol: i32) callconv(.winapi) Socket;
        extern "ws2_32" fn bind(s: Socket, name: *const anyopaque, len: i32) callconv(.winapi) i32;
        extern "ws2_32" fn listen(s: Socket, backlog: i32) callconv(.winapi) i32;
        extern "ws2_32" fn accept(s: Socket, name: ?*anyopaque, len: ?*i32) callconv(.winapi) Socket;
        extern "ws2_32" fn connect(s: Socket, name: *const anyopaque, len: i32) callconv(.winapi) i32;
        extern "ws2_32" fn recv(s: Socket, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
        extern "ws2_32" fn closesocket(s: Socket) callconv(.winapi) i32;
        extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
    };
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(gpa);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    std.mem.replaceScalar(u8, root, '\\', '/');
    {
        const early = try gpa.print("{s}/early", .{root});
        defer gpa.free(early);
        const a = try net.UnixAddress.init(early);
        if (a.listen(io, .{})) |sv| {
            var server = sv;
            server.deinit(io);
            try report.print(gpa, "std listen before WSAStartup: ok\n", .{});
        } else |err| try report.print(gpa, "std listen before WSAStartup: {t}\n", .{err});
    }
    var data: [512]u8 = undefined;
    try report.print(gpa, "WSAStartup {d}\n", .{ws.WSAStartup(0x0202, &data)});
    const Un = ws2_32.sockaddr.un;
    const sockaddr = struct {
        fn of(path: []const u8) struct { Un, i32 } {
            var un: Un = .{ .path = @splat(0) };
            @memcpy(un.path[0..path.len], path);
            return .{ un, @intCast(@offsetOf(Un, "path") + path.len + 1) };
        }
    }.of;
    const name = try gpa.print("{s}/socket", .{root});
    defer gpa.free(name);
    const listener = ws.socket(ws2_32.AF.UNIX, ws2_32.SOCK.STREAM, 0);
    defer _ = ws.closesocket(listener);
    {
        const un, const len = sockaddr(name);
        try report.print(gpa, "listener bind {d} listen {d}\n", .{ ws.bind(listener, &un, len), ws.listen(listener, 4) });
    }
    {
        const client = ws.socket(ws2_32.AF.UNIX, ws2_32.SOCK.STREAM, 0);
        const un, const len = sockaddr(name);
        const rc = ws.connect(client, &un, len);
        try report.print(gpa, "connect {d} ({d})\n", .{ rc, if (rc != 0) ws.WSAGetLastError() else 0 });
        const stream: net.Stream = .{ .socket = .{ .handle = client, .address = .{ .ip4 = .loopback(0) } } };
        var buf: [16]u8 = undefined;
        var w = stream.writer(io, &buf);
        if (w.interface.writeAll("hello")) |_| {
            if (w.interface.flush()) |_| try report.print(gpa, "std write: ok\n", .{}) else |err| try report.print(gpa, "std flush: {t} {?t}\n", .{ err, w.err });
        } else |err| try report.print(gpa, "std write: {t} {?t}\n", .{ err, w.err });
        const peer = ws.accept(listener, null, null);
        var got: [16]u8 = undefined;
        const n = ws.recv(peer, &got, got.len, 0);
        try report.print(gpa, "peer got {d}: {s}\n", .{ n, if (n > 0) got[0..@intCast(n)] else "" });
        _ = ws.closesocket(peer);
        stream.close(io);
        try report.print(gpa, "std close: ok\n", .{});
    }
    {
        const after = try gpa.print("{s}/after", .{root});
        defer gpa.free(after);
        const a = try net.UnixAddress.init(after);
        if (a.listen(io, .{})) |sv| {
            var server = sv;
            server.deinit(io);
            try report.print(gpa, "std listen after WSAStartup: ok\n", .{});
        } else |err| try report.print(gpa, "std listen after WSAStartup: {t}\n", .{err});
    }
    const missing_dir = try gpa.print("{s}/nowhere/socket", .{root});
    defer gpa.free(missing_dir);
    const missing_file = try gpa.print("{s}/none", .{root});
    defer gpa.free(missing_file);
    try tmp.dir.writeFile(io, .{ .sub_path = "plain", .data = "x" });
    const plain = try gpa.print("{s}/plain", .{root});
    defer gpa.free(plain);
    // A socket file whose listener is gone.
    const stale = try gpa.print("{s}/stale", .{root});
    defer gpa.free(stale);
    {
        const s = ws.socket(ws2_32.AF.UNIX, ws2_32.SOCK.STREAM, 0);
        const un, const len = sockaddr(stale);
        _ = ws.bind(s, &un, len);
        _ = ws.listen(s, 1);
        _ = ws.closesocket(s);
    }
    for ([_][]const u8{ missing_dir, missing_file, plain, stale }) |target| {
        const client = ws.socket(ws2_32.AF.UNIX, ws2_32.SOCK.STREAM, 0);
        defer _ = ws.closesocket(client);
        const un, const len = sockaddr(target);
        const rc = ws.connect(client, &un, len);
        try report.print(gpa, "connect {s}: {d} ({d})\n", .{ target[root.len..], rc, if (rc != 0) ws.WSAGetLastError() else 0 });
    }
    std.debug.print("{s}", .{report.items});
    return error.ProbeReport;
}

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
    var started = false;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const Listener = enum { std_slash, std_backslash, winsock_slash, winsock_backslash };
    const Bind = enum { none, family, family_nul, whole };
    const Target = enum { nt_normalized, win32_raw, nt_raw };
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
            .std_slash, .std_backslash => server = address.listen(io, .{}) catch |err| {
                try report.print(gpa, "{t}: std listen {t}\n", .{ l, err });
                continue;
            },
            .winsock_slash, .winsock_backslash => {
                if (!started) {
                    try report.print(gpa, "WSAStartup {d}\n", .{ws.WSAStartup(0x0202, &data)});
                    started = true;
                }
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
        for (std.enums.values(Target)) |t| for (std.enums.values(Bind)) |b| {
            const handle = open(ws2_32.AF.UNIX, .stream, null) catch |err| {
                try report.print(gpa, "{t} {t} {t}: open {t}\n", .{ l, t, b, err });
                continue;
            };
            defer windows.CloseHandle(handle);
            var target: windows.AFD.SOCKOPT_INFO.UNIX_PATH = undefined;
            const len: usize = switch (t) {
                .nt_normalized => len: {
                    const path = try Threaded.sliceToPrefixedFileW(null, name, .{ .allow_relative = false });
                    target.Path = path.data;
                    break :len path.len;
                },
                .win32_raw => try std.unicode.wtf8ToWtf16Le(&target.Path, name),
                .nt_raw => len: {
                    target.Path[0..4].* = .{ '\\', '?', '?', '\\' };
                    break :len 4 + try std.unicode.wtf8ToWtf16Le(target.Path[4..], name);
                },
            };
            target.Path[len] = 0;
            const bytes = std.mem.asBytes(&target)[0 .. @offsetOf(windows.AFD.SOCKOPT_INFO.UNIX_PATH, "Path") + @sizeOf(windows.WCHAR) * len];
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
            try report.print(gpa, "{t} {t} {t}: option {t} bind {t} connect {t}\n", .{ l, t, b, opt, bound, connected });
        };
    }
    std.debug.print("{s}", .{report.items});
    return error.ProbeReport;
}
