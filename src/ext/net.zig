//! Networking over any `Io`: what `std.Io` cannot say, or cannot keep on
//! every `Io` — socket options, a connect with a timeout, a bounded lookup, ending a
//! socket's operations from another task, per-operation deadlines, and
//! receives that hold no buffer while idle. Native on a runtime; on any
//! other `Io`, the best its slots allow.
const connect_file = @import("net/connect.zig");
const resolve_file = @import("net/resolve.zig");
const options_file = @import("net/options.zig");
const listen_file = @import("net/listen.zig");

/// The handles `connect`, `connectUnix`, `listen` and the pipes hand back,
/// each with its one owner: `deinit(io)` closes it.
pub const owned = @import("net/owned.zig");

pub const ConnectOptions = connect_file.Options;
pub const Connected = connect_file.Connected;
pub const ConnectError = connect_file.Error;
pub const connect = connect_file.connect;
pub const connectUnix = connect_file.connectUnix;

pub const SocketOptions = options_file.Options;
pub const Keepalive = options_file.Keepalive;
pub const KeepaliveSeconds = options_file.KeepaliveSeconds;
pub const KeepaliveCount = options_file.KeepaliveCount;
pub const OptionsError = options_file.Error;
pub const setOptions = options_file.setOptions;
pub const send_buffer_when_connected = options_file.send_buffer_when_connected;

pub const ListenOptions = listen_file.Options;
pub const ListenError = listen_file.Error;
pub const listen = listen_file.listen;

pub const ResolveOptions = resolve_file.Options;
pub const ResolveError = resolve_file.Error;
pub const resolve = resolve_file.resolve;
pub const max_addresses = resolve_file.max_addresses;
pub const literal = resolve_file.literal;

/// Windows named pipes: a client's connect, a server's listener.
pub const pipe = @import("net/pipe.zig");
pub const connectPipe = pipe.connectPipe;
pub const listenPipe = pipe.listenPipe;
pub const PipeListener = pipe.PipeListener;

pub const abort = @import("net/abort.zig").abort;
pub const Deadlines = @import("net/Deadlines.zig");
pub const Receiver = @import("net/Receiver.zig");
/// A stream socket's messages with their control data, the kernel's own
/// answers kept apart (`BadMessage`, `KeyExpired`, `InputOutput`). POSIX.
pub const message = @import("net/message.zig");
