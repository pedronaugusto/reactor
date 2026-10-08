//! Raw calls and platform probes used by reactor's completion engines.
pub const memory = @import("sys/memory.zig");
pub const socket = @import("sys/socket.zig");
pub const file = @import("sys/file.zig");
pub const windows = @import("sys/windows.zig");
pub const afd = @import("sys/afd.zig");
