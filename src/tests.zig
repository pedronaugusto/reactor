//! Every test of reactor, reached from here.
test {
    _ = @import("reactor.zig");
    _ = @import("wheel_test.zig");
    _ = @import("scheduler/run_queue_test.zig");
    _ = @import("runtime_test.zig");
    _ = @import("uring_test.zig");
    _ = @import("backends_test.zig");
    _ = @import("handoff_test.zig");
    _ = @import("backend/readiness/records_test.zig");
    _ = @import("iocp_test.zig");
    _ = @import("threaded_test.zig");
    _ = @import("ext_test.zig");
    _ = @import("net_test.zig");
    _ = @import("resolve_test.zig");
    _ = @import("accept_test.zig");
    _ = @import("files_test.zig");
    _ = @import("uring_ext_test.zig");
}
