//! What the runtime's slots are made of: a task waiting on one loop
//! operation (`perform`), the futex table, futures and groups (`tasks`),
//! batches and their timeout rule, calls on lanes (`lane_call`), and waits
//! for the first of several descriptors (`readiness`).
pub const perform = @import("ops/perform.zig");
pub const futex = @import("ops/futex.zig");
pub const tasks = @import("ops/tasks.zig");
pub const batch = @import("ops/batch.zig");
pub const lane_call = @import("ops/lane_call.zig");
pub const readiness = @import("ops/readiness.zig");
