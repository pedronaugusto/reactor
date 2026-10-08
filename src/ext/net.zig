//! Networking over any `Io`: what `std.Io` cannot say, or cannot keep on
//! every `Io` — a connect with a timeout, a bounded lookup, ending a
//! socket's operations from another task, per-operation deadlines, and
//! receives that hold no buffer while idle. Native on a runtime; on any
//! other `Io`, the best its slots allow.
const connect_file = @import("net/connect.zig");
const resolve_file = @import("net/resolve.zig");

pub const ConnectOptions = connect_file.Options;
pub const Connected = connect_file.Connected;
pub const ConnectError = connect_file.Error;
pub const connect = connect_file.connect;

pub const ResolveOptions = resolve_file.Options;
pub const ResolveError = resolve_file.Error;
pub const resolve = resolve_file.resolve;

pub const abort = @import("net/abort.zig").abort;
pub const Deadlines = @import("net/Deadlines.zig");
pub const Receiver = @import("net/Receiver.zig");
