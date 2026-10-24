//! A Unix stream socket connected through Winsock, as Git for Windows and
//! every Winsock program connect one: `socket` and `connect` with the path
//! as given. AFD driven directly (std 0.17's `Io.Threaded`) is refused by
//! the system in ways Winsock is not: the endpoint will not open in a
//! process that has not used AF_UNIX through Winsock, and its unnamed bind
//! fails once a listener is there. The handle is a socket std's streams
//! read, write and close.
const std = @import("std");
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const net = std.Io.net;

const Socket = windows.HANDLE;
const invalid_socket: Socket = @ptrFromInt(std.math.maxInt(usize));

extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
extern "ws2_32" fn socket(family: c_int, kind: c_int, protocol: c_int) callconv(.winapi) Socket;
extern "ws2_32" fn connect(s: Socket, name: *const anyopaque, len: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn closesocket(s: Socket) callconv(.winapi) c_int;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;

/// Winsock started once for the process and left running: a socket made
/// here outlives the call, and `WSACleanup` would reset it.
var started: std.atomic.Value(bool) = .init(false);

fn start() net.UnixAddress.ConnectError!void {
    if (started.load(.acquire)) return;
    var data: [512]u8 align(8) = undefined;
    if (WSAStartup(0x202, &data) != 0) return error.SystemResources;
    // A second start from a racing thread only counts Winsock up once more.
    started.store(true, .release);
}

/// `address` connected. AF_UNIX through Winsock names a socket file with
/// nothing listening, and a file that is no socket, `WSAECONNREFUSED`, and
/// a directory missing on the way `WSAENETDOWN`, which Git for Windows also
/// takes for no daemon: here `ConnectionRefused` and `FileNotFound`. A path
/// longer than `sockaddr_un` holds is `FileNotFound`, as std names a path it
/// cannot convert.
pub fn connectUnix(address: *const net.UnixAddress) net.UnixAddress.ConnectError!Socket {
    var name: ws2_32.sockaddr.un = .{ .path = @splat(0) };
    if (address.path.len >= name.path.len) return error.FileNotFound;
    @memcpy(name.path[0..address.path.len], address.path);
    try start();
    const handle = socket(ws2_32.AF.UNIX, ws2_32.SOCK.STREAM, 0);
    if (handle == invalid_socket) return switch (WSAGetLastError()) {
        10047 => error.AddressFamilyUnsupported, // WSAEAFNOSUPPORT
        10024 => error.ProcessFdQuotaExceeded, // WSAEMFILE
        10055 => error.SystemResources, // WSAENOBUFS
        else => error.Unexpected,
    };
    errdefer _ = closesocket(handle);
    const len: c_int = @intCast(@offsetOf(ws2_32.sockaddr.un, "path") + address.path.len + 1);
    if (connect(handle, &name, len) != 0) return switch (WSAGetLastError()) {
        10061 => error.ConnectionRefused, // WSAECONNREFUSED
        10050 => error.FileNotFound, // WSAENETDOWN
        10013 => error.AccessDenied, // WSAEACCES
        10055 => error.SystemResources, // WSAENOBUFS
        else => error.Unexpected,
    };
    return handle;
}
