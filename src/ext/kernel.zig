//! Native request escapes. The loop owns the completion token; callers
//! own the prepared arguments, which remain pinned until completion.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Loop = @import("../Loop.zig");
const Scheduler = @import("../Scheduler.zig");
const perform = @import("../ops/perform.zig");
const native = @import("native.zig");

pub const Error = error{ Unsupported, Timeout, SystemResources } || Io.Cancelable;

/// Prepare one SQE; the loop replaces its user_data with its own token.
/// Multishot and notification requests use a dedicated owner API instead.
pub fn submit(io: Io, comptime prepare: anytype, context: anytype, timeout: Io.Timeout) Error!i32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const core = native.runtimeOf(io) orelse return error.Unsupported;
    if (!native.taskRuntime(core) or core.backendKind() != .io_uring) return error.Unsupported;
    var prepared = std.mem.zeroInit(std.os.linux.io_uring_sqe, .{});
    prepare(context, &prepared);
    if (!singleCompletion(prepared)) return error.Unsupported;
    const Thunk = struct {
        fn prep(raw: *anyopaque, sqe: *std.os.linux.io_uring_sqe) void {
            const c: *const std.os.linux.io_uring_sqe = @ptrCast(@alignCast(raw)); // safe: submit passed its prepared SQE
            sqe.* = c.*;
        }
    };
    var op: Loop.Op = .{ .kind = .{ .raw = .{ .uring = .{ .context = &prepared, .prepare = Thunk.prep } } } };
    try perform.run(&core.scheduler, &op, .{ .deadline = perform.deadline(Scheduler.processor().?, timeout) });
    return (try op.result.raw).uring;
}

/// These requests cannot fit a task-owned, one-completion lifetime.
fn singleCompletion(sqe: std.os.linux.io_uring_sqe) bool {
    const linux = std.os.linux;
    if (sqe.flags & (linux.IOSQE_FIXED_FILE | linux.IOSQE_IO_LINK | linux.IOSQE_IO_HARDLINK | linux.IOSQE_CQE_SKIP_SUCCESS | linux.IOSQE_BUFFER_SELECT) != 0) return false;
    return switch (sqe.opcode) {
        .SEND_ZC, .SENDMSG_ZC, .READ_MULTISHOT, .RECV_ZC, .URING_CMD, .FILES_UPDATE, .FIXED_FD_INSTALL, .LINK_TIMEOUT => false,
        .ACCEPT => sqe.ioprio & linux.IORING_ACCEPT_MULTISHOT == 0,
        .RECV, .RECVMSG => sqe.ioprio & linux.IORING_RECV_MULTISHOT == 0,
        .POLL_ADD => sqe.len & linux.IORING_POLL_ADD_MULTI == 0,
        .TIMEOUT => sqe.rw_flags & (1 << 6) == 0,
        else => @backingInt(sqe.opcode) < @backingInt(linux.IORING_OP.RECV_ZC),
    };
}

/// Issue an NT overlapped call on handle. Pass completion_context as the
/// NT call's APC context and iosb as its status block. Reactor binds the
/// handle to its port and retains both through cancellation and completion.
pub fn overlapped(io: Io, comptime start: anytype, handle: std.os.windows.HANDLE, context: anytype, timeout: Io.Timeout) Error!std.os.windows.IO_STATUS_BLOCK {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const core = native.runtimeOf(io) orelse return error.Unsupported;
    if (!native.taskRuntime(core) or core.backendKind() != .iocp) return error.Unsupported;
    const Thunk = struct {
        fn begin(raw: *anyopaque, iosb: *std.os.windows.IO_STATUS_BLOCK, completion: *anyopaque) std.os.windows.NTSTATUS {
            const c: *@TypeOf(context) = @ptrCast(@alignCast(raw)); // safe: overlapped passed the context's address
            return start(c.*, iosb, completion);
        }
    };
    // The context value (including a pointer value) stays pinned in this frame.
    var c = context;
    var op: Loop.Op = .{ .kind = .{ .raw = .{ .windows = .{ .handle = handle, .context = @ptrCast(&c), .start = Thunk.begin } } } }; // safe: Thunk.begin reads this pinned context value back with its original type
    try perform.run(&core.scheduler, &op, .{ .deadline = perform.deadline(Scheduler.processor().?, timeout) });
    return (try op.result.raw).windows;
}
