//! Raw system calls reactor makes itself, beside the kernel queues: stack
//! address space, the plain socket calls around an evented connect, and
//! the Windows calls std does not declare.
pub const memory = @import("sys/memory.zig");
pub const socket = @import("sys/socket.zig");
pub const windows = @import("sys/windows.zig");
pub const afd = @import("sys/afd.zig");
