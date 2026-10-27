//! The runtime's own synchronization, each on aegis cells: a flag one side
//! raises and another takes (`Raised`), a signal set once that the other
//! side waits for (`Done`), and a lock-free stack of a table's free entries
//! (`FreeList`).
pub const Raised = @import("sync/Raised.zig");
pub const Done = @import("sync/Done.zig");
pub const FreeList = @import("sync/FreeList.zig");
