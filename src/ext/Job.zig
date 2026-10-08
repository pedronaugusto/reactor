//! A Windows job object's messages: a process joined or left the job, the
//! job emptied, a limit was hit. The job reports them on a completion port
//! associated with it, so attach before the first process joins: the
//! job emptying is reported on the transition only. Elsewhere `attach`
//! returns `Unsupported`.
//!
//! A runtime receives messages on its own completion port and wakes the
//! waiting task. Other backends use the wait lane; any other `Io` waits
//! on the calling thread, checking cancellation between short waits.
const Job = @This();

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const windows = std.os.windows;

const fiber = @import("../fiber.zig");
const Notifications = @import("../backend/iocp/Notifications.zig");
const lane_call = @import("../ops/lane_call.zig");
const win32 = @import("../sys/win32.zig");
const native = @import("native.zig");
const wait = @import("wait.zig");

const is_windows = builtin.os.tag == .windows;

/// The port the job reports on; not to be touched.
port: if (is_windows) windows.HANDLE else void,
job: if (is_windows) windows.HANDLE else void,
record: ?*Notifications.Record = null,

pub const Message = union(enum) {
    /// A process joined the job: its id.
    new_process: u32,
    exit_process: u32,
    abnormal_exit_process: u32,
    /// The job has no process left.
    active_process_zero,
    active_process_limit,
    process_memory_limit: u32,
    job_memory_limit,
    end_of_job_time,
};

pub const AttachError = error{ AlreadyAttached, Unsupported, SystemResources, Unexpected };

/// Associates the job with a completion port. The attachment owns a duplicate
/// of the job handle. Detach after the last `next` has finished.
pub fn attach(io: Io, job: windows.HANDLE) AttachError!Job {
    if (!is_windows) return error.Unsupported;
    var duplicate: windows.HANDLE = undefined;
    const process = win32.GetCurrentProcess();
    if (win32.DuplicateHandle(process, job, process, &duplicate, 0, .FALSE, 2) == .FALSE) return error.SystemResources;
    errdefer windows.CloseHandle(duplicate);
    if (comptime is_windows and fiber.supported) {
        if (native.runtimeOf(io)) |core| {
            if (core.backendKind() == .iocp) {
                const record = core.jobs.acquire(io) orelse return error.SystemResources;
                errdefer record.release();
                const port = core.processors[0].loop.backend.iocp.port;
                try associate(duplicate, @ptrFromInt(record.key()), port); // safe: the kernel carries this integer key without dereferencing it
                return .{ .port = port, .job = duplicate, .record = record };
            }
        }
    }
    const port = win32.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 1) orelse return error.SystemResources;
    errdefer windows.CloseHandle(port);
    try associate(duplicate, duplicate, port);
    return .{ .port = port, .job = duplicate };
}

fn associate(job: windows.HANDLE, key: ?*anyopaque, port: ?windows.HANDLE) AttachError!void {
    const association: win32.JobObjectAssociateCompletionPort = .{ .CompletionKey = key, .CompletionPort = port };
    if (win32.SetInformationJobObject(job, win32.job_object_associate_completion_port_information, &association, @sizeOf(win32.JobObjectAssociateCompletionPort)) == .FALSE) return switch (win32.GetLastError()) {
        win32.error_invalid_parameter => error.AlreadyAttached,
        else => error.Unexpected,
    };
}

/// Detaches the port and drops messages not yet read. Queued native messages
/// carry the attachment's generation and cannot reach a reused record.
pub fn detach(j: *Job, io: Io) void {
    _ = io;
    if (is_windows) {
        associate(j.job, null, null) catch |err| std.debug.panic("reactor: detaching a job failed: {t}", .{err});
        if (j.record) |record| record.release() else windows.CloseHandle(j.port);
        windows.CloseHandle(j.job);
    }
    j.* = undefined;
}

pub const NextError = error{ Timeout, SystemResources, Unexpected } || Io.Cancelable;

/// The next message, waiting until `timeout` for one.
pub fn next(j: *Job, io: Io, timeout: Io.Timeout) NextError!Message {
    if (!is_windows) unreachable; // unreachable: `attach` makes no job here
    const deadline = timeout.toDeadline(io);
    if (j.record) |record| {
        while (true) {
            const message = try record.next(io, deadline);
            if (messageOf(message.code, message.process)) |message_value| return message_value;
        }
    }
    const core = native.runtimeOf(io) orelse return take(io, j.port, deadline);
    if (!native.taskRuntime(core)) return take(io, j.port, deadline);
    return lane_call.call(&core.scheduler, &core.lanes, .wait, &take, .{ core.lanes.executor(.wait), j.port, deadline });
}

fn take(io: Io, port: windows.HANDLE, deadline: Io.Timeout) NextError!Message {
    while (true) {
        try io.checkCancel();
        const left = deadline.toDurationFromNow(io);
        const ms: u32 = if (left) |d| ms: {
            if (d.raw.nanoseconds <= 0) break :ms 0;
            break :ms @intCast(@min(std.math.divCeil(i96, d.raw.nanoseconds, std.time.ns_per_ms) catch unreachable, wait.slice_ms)); // unreachable: the divisor is a positive constant
        } else wait.slice_ms;
        var bytes: windows.DWORD = 0;
        var key: usize = 0;
        var overlapped: ?*anyopaque = null;
        if (win32.GetQueuedCompletionStatus(port, &bytes, &key, &overlapped, ms) == .FALSE) {
            if (overlapped == null) {
                if (left) |d| if (d.raw.nanoseconds <= 0) return error.Timeout;
                continue;
            }
            return error.Unexpected;
        }
        const id: u32 = @truncate(@intFromPtr(overlapped)); // safe: a job's message carries a process id here, not an address
        if (messageOf(bytes, id)) |message| return message;
    }
}

fn messageOf(code: u32, id: u32) ?Message {
    const m = win32.job_msg;
    return switch (code) {
        m.new_process => .{ .new_process = id },
        m.exit_process => .{ .exit_process = id },
        m.abnormal_exit_process => .{ .abnormal_exit_process = id },
        m.active_process_zero => .active_process_zero,
        m.active_process_limit => .active_process_limit,
        m.process_memory_limit => .{ .process_memory_limit = id },
        m.job_memory_limit => .job_memory_limit,
        m.end_of_job_time => .end_of_job_time,
        else => null,
    };
}
