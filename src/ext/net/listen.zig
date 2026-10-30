//! A listener with socket options set before it listens, when the buffers
//! count: an accepted connection's window scale is fixed from the
//! listener's (tcp(7): "must be set prior to the listen(2) or connect(2)
//! calls"), and its other options are the listener's, inherited.
const builtin = @import("builtin");
const std = @import("std");
const sys_socket = @import("../../sys/socket.zig");
const afd = @import("../../sys/afd.zig");
const options_file = @import("options.zig");
const Io = std.Io;
const net = Io.net;
const owned = @import("owned.zig");

/// std's `ListenOptions`, and the socket options.
pub const Options = struct {
    kernel_backlog: u31 = net.default_kernel_backlog,
    /// `SO_REUSEADDR`, and `SO_REUSEPORT` on POSIX, as std sets them.
    reuse_address: bool = false,
    mode: net.Socket.Mode = .stream,
    protocol: net.Protocol = .tcp,
    /// Set before the bind and the listen. A refused one fails the listen,
    /// named.
    socket: options_file.Options = .{},
};

pub const Error = net.IpAddress.ListenError;

/// A listener at `address`. With no socket option asked for it is std's
/// `IpAddress.listen` on `io`; with any, reactor makes the socket itself,
/// sets them, binds and listens. The listener is the caller's, closed with
/// `deinit(io)`.
pub fn listen(io: Io, address: *const net.IpAddress, options: Options) Error!owned.Server {
    const plain: net.IpAddress.ListenOptions = .{ .kernel_backlog = options.kernel_backlog, .reuse_address = options.reuse_address, .mode = options.mode, .protocol = options.protocol };
    if (!options.socket.any()) return .init(try address.listen(io, plain));
    // A listener's send buffer would be dropped, unsaid (see the flag).
    if (options_file.send_buffer_when_connected and options.socket.send_buffer != null) return error.OptionUnsupported;
    try io.checkCancel();
    const family = Io.Threaded.posixAddressFamily(address);
    const handle = if (builtin.os.tag == .windows) try afd.open(family, options.mode, options.protocol) else try sys_socket.open(family, options.mode, options.protocol, .blocking);
    errdefer sys_socket.close(handle);
    if (options.reuse_address) try options_file.reuse(handle);
    try options_file.apply(handle, address.*, options.socket);
    const bound = if (builtin.os.tag == .windows) bound: {
        const at = try afd.bind(handle, address, .of(address, options.reuse_address));
        try afd.listen(handle, options.kernel_backlog);
        break :bound at;
    } else try sys_socket.bindListen(handle, address, options.kernel_backlog);
    return .init(.{
        .socket = .{ .handle = handle, .address = bound },
        .options = if (net.Server.AcceptOptions != void) .{ .mode = options.mode, .protocol = options.protocol },
    });
}
