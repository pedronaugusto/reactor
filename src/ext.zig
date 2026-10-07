//! The extensions: what `std.Io` cannot say, over any `Io`. Waits on
//! kernel objects (`wait`, `Wake`, `Process`, `Job`), blocking calls on
//! lanes, signals, and networking. Native on a runtime; on any other `Io`
//! the best path its slots allow, counted by `native.fallbacks`.
pub const native = @import("ext/native.zig");
pub const wait = @import("ext/wait.zig");
pub const Wake = @import("ext/Wake.zig");
pub const Process = @import("ext/Process.zig");
pub const Job = @import("ext/Job.zig");
pub const blocking = @import("ext/blocking.zig");
pub const Signals = @import("ext/Signals.zig");
pub const net = @import("ext/net.zig");
