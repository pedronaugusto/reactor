//! What an IOCP operation keeps while the kernel holds it: where the kernel
//! writes the outcome, and the memory a request is read from or written to
//! after the call.
const std = @import("std");
const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const Handle = windows.HANDLE;
const Threaded = std.Io.Threaded;

const afd = @import("../../sys/afd.zig");

pub const Scratch = struct {
    /// Where the kernel writes the outcome.
    iosb: windows.IO_STATUS_BLOCK = undefined,
    /// The port of the loop that submitted it, which finishes it: the
    /// loop's own field, so its address tells the loops apart where they
    /// share a host's port.
    owner: *const Handle,
    /// The handle the kernel holds the call on.
    target: Handle = undefined,
    stage: Stage = .main,
    /// A multi-message send: messages sent so far.
    sent: u32 = 0,
    request: Request = .{ .none = {} },
};

pub const Stage = enum(u8) {
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
pub const Request = union {
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

pub const DatagramIn = struct {
    info: windows.AFD.RECV_DATAGRAM_INFO,
    buffer: [1]windows.AFD.WSABUF(.@"var"),
    address: Threaded.PosixAddress,
    address_len: windows.ULONG,
};

pub const DatagramOut = struct {
    info: windows.AFD.SEND_DATAGRAM_INFO,
    buffer: [1]windows.AFD.WSABUF(.@"const"),
    address: Threaded.PosixAddress,
};
