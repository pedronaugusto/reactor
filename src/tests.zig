//! Every test of reactor, reached from here.
test {
    _ = @import("reactor.zig");
    _ = @import("ext/tasks_test.zig");
    _ = @import("wheel_test.zig");
    _ = @import("scheduler/run_queue_test.zig");
    _ = @import("runtime_test.zig");
    _ = @import("lanes_test.zig");
    _ = @import("r1_regression_test.zig");
    _ = @import("later_test.zig");
    _ = @import("testing/overflow_test.zig");
    _ = @import("testing/seh_test.zig");
    _ = @import("uring_test.zig");
    _ = @import("backends_test.zig");
    _ = @import("handoff_test.zig");
    _ = @import("backend/readiness/records_test.zig");
    _ = @import("iocp_test.zig");
    _ = @import("threaded_test.zig");
    _ = @import("ext_test.zig");
    _ = @import("offload_test.zig");
    _ = @import("net_test.zig");
    _ = @import("resolve_test.zig");
    _ = @import("accept_test.zig");
    _ = @import("files_test.zig");
    _ = @import("uring_ext_test.zig");
}
