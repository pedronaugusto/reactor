//! Raw system calls reactor makes itself, beside the kernel queues: stack
//! address space, and the plain socket calls around an evented connect.
pub const memory = @import("sys/memory.zig");
pub const socket = @import("sys/socket.zig");
