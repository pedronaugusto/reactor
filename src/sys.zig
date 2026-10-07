//! Raw system calls reactor makes itself, beside the kernel queues: stack
//! address space, the plain socket calls around an evented connect, and
//! positional file reads and writes made in place.
pub const memory = @import("sys/memory.zig");
pub const socket = @import("sys/socket.zig");
pub const file = @import("sys/file.zig");
