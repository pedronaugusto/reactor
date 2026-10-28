//! The runtime's own synchronization, each on aegis cells: a flag one side
//! raises and another takes (`Raised`), and a lock-free stack of a table's
//! free entries (`FreeList`). A signal set once that the other side waits
//! for is std's `Io.Event`.
pub const Raised = @import("sync/Raised.zig");
pub const FreeList = @import("sync/FreeList.zig");
