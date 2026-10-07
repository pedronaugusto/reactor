//! Every test of reactor, reached from here.
test {
    _ = @import("reactor.zig");
    _ = @import("wheel_test.zig");
    _ = @import("scheduler/run_queue_test.zig");
    _ = @import("runtime_test.zig");
    _ = @import("uring_test.zig");
    _ = @import("iocp_test.zig");
    _ = @import("threaded_test.zig");
}
