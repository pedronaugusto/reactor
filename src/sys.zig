//! Raw calls and platform probes used by reactor's completion engines.
pub const memory = @import("sys/memory.zig");
pub const socket = @import("sys/socket.zig");
pub const file = @import("sys/file.zig");
pub const windows = @import("sys/windows.zig");
pub const afd = @import("sys/afd.zig");
pub const Notify = @import("sys/Notify.zig");
pub const poll = @import("sys/poll.zig");
pub const process = @import("sys/process.zig");
pub const receive = @import("sys/receive.zig");
pub const getaddrinfo = @import("sys/getaddrinfo.zig");
pub const win32 = @import("sys/win32.zig");
