//! Raw system calls reactor makes itself, beside the kernel queues: stack
//! address space, the plain socket calls around an evented connect, and
//! what the extensions wait on and with.
pub const memory = @import("sys/memory.zig");
pub const socket = @import("sys/socket.zig");
pub const Notify = @import("sys/Notify.zig");
pub const poll = @import("sys/poll.zig");
pub const process = @import("sys/process.zig");
pub const receive = @import("sys/receive.zig");
pub const getaddrinfo = @import("sys/getaddrinfo.zig");
pub const win32 = @import("sys/win32.zig");
