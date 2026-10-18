//! Native request escapes. The loop owns the completion token; callers
//! own the prepared arguments, which remain pinned until completion.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Loop = @import("../Loop.zig");
const Scheduler = @import("../Scheduler.zig");
const perform = @import("../ops/perform.zig");
const native = @import("native.zig");
const wait = @import("wait.zig");
const win32 = @import("../sys/win32.zig");
const assert = std.debug.assert;
const windows = std.os.windows;

const is_windows = builtin.os.tag == .windows;

pub const Error = error{ Unsupported, Timeout, SystemResources } || Io.Cancelable;

/// Prepare one SQE; the loop replaces its user_data with its own token.
/// Multishot and notification requests use a dedicated owner API instead.
pub fn submit(io: Io, comptime prepare: anytype, context: anytype, timeout: Io.Timeout) Error!i32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const core = native.runtimeOf(io) orelse return error.Unsupported;
    const entered = native.enter();
    defer native.leave(entered);
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
    var op: Loop.Op = .{ .backend = .{ .kind = .{ .raw = .{ .uring = .{ .context = &prepared, .prepare = Thunk.prep } } } } };
    try perform.run(&core.scheduler, &op, .{ .deadline = perform.deadline(Scheduler.processor().?, timeout) });
    return (try op.backend.result.raw).uring;
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

pub const Completion = Overlapped.Completion;
pub const Overlapped = @import("Overlapped.zig");

/// Issue an NT overlapped call on `handle`, `start(context, iosb,
/// completion)`, and wait for it to end or `timeout` to pass. Any `Io`:
/// on a runtime's task reactor binds the handle to its port and retains
/// the status block through cancelation and completion; elsewhere the call
/// is an `Overlapped`'s, waited on the calling thread. A call that the
/// timeout or a cancel ends but that completed first is handed back as
/// completed, so a read's bytes are never lost to its cancel.
pub fn overlapped(io: Io, comptime start: anytype, handle: windows.HANDLE, context: anytype, timeout: Io.Timeout) Error!windows.IO_STATUS_BLOCK {
    if (!is_windows) return error.Unsupported;
    if (native.runtimeOf(io)) |core| {
        const entered = native.enter();
        defer native.leave(entered);
        if (native.taskRuntime(core) and core.backendKind() == .iocp) {
            const Thunk = struct {
                fn begin(raw: *anyopaque, iosb: *windows.IO_STATUS_BLOCK, completion: *anyopaque) windows.NTSTATUS {
                    const c: *const @TypeOf(context) = @ptrCast(@alignCast(raw)); // safe: overlapped passed the context's address
                    return start(c.*, iosb, Completion{ .event = null, .context = completion });
                }
            };
            // The context parameter (a pointer value included) stays in this frame until the call ends;
            // the kernel's start reads it through its address, never writes it.
            var op: Loop.Op = .{ .backend = .{ .kind = .{ .raw = .{ .windows = .{ .handle = handle, .context = @ptrCast(@constCast(&context)), .start = Thunk.begin } } } } }; // safe: Thunk.begin reads this parameter back, const, with its original type
            try perform.run(&core.scheduler, &op, .{ .deadline = perform.deadline(Scheduler.processor().?, timeout) });
            return (try op.backend.result.raw).windows;
        }
    }
    var request = try Overlapped.init();
    defer request.deinit();
    if (request.start(start, handle, context)) |ended| return ended;
    wait.wait(io, .{ .overlapped = &request }, timeout) catch |err| {
        request.cancel();
        // Its end is at once; the frame holds what the kernel writes until it.
        assert(win32.WaitForSingleObject(request.event, win32.infinite) == win32.wait_object_0);
        const ended = request.take();
        if (ended.u.Status != .CANCELLED) {
            // It completed as it was canceled: the cancel is still asked.
            if (err == error.Canceled) io.recancel();
            return ended;
        }
        return switch (err) {
            error.Timeout => error.Timeout,
            error.Canceled => error.Canceled,
            error.Unsupported => unreachable, // unreachable: an `Overlapped` is an event, which every wait takes
            error.Unexpected => error.SystemResources,
        };
    };
    return request.take();
}
