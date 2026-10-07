//! The runtime's `std.Io.VTable`: every slot native where the kernel has
//! an evented form, std's own code on a lane where a call may block, and
//! std's own code borrowed on the worker where it never blocks and never
//! calls back into its `Io` (vtable/route.zig).
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Alignment = std.mem.Alignment;

const Core = @import("Core.zig");
const route = @import("route.zig");
const clock = @import("../clock.zig");
const Task = @import("../scheduler/Task.zig");
const Scheduler = @import("../Scheduler.zig");
const tasks = @import("../ops/tasks.zig");
const futex = @import("../ops/futex.zig");
const batch = @import("../ops/batch.zig");
const perform = @import("../ops/perform.zig");
const lane_call = @import("../ops/lane_call.zig");
const io_ops = @import("io_ops.zig");

const general = .general;

pub const vtable: Io.VTable = .{
    .crashHandler = crashHandler,

    .async = async,
    .concurrent = concurrent,
    .await = await,
    .cancel = cancel,

    .groupAsync = groupAsync,
    .groupConcurrent = groupConcurrent,
    .groupAwait = groupAwait,
    .groupCancel = groupCancel,

    .recancel = recancel,
    .swapCancelProtection = swapCancelProtection,
    .checkCancel = checkCancel,

    .futexWait = futexWait,
    .futexWaitUncancelable = futexWaitUncancelable,
    .futexWake = futexWake,

    .operate = io_ops.operate,
    .batchAwaitAsync = batchAwaitAsync,
    .batchAwaitConcurrent = batchAwaitConcurrent,
    .batchCancel = batchCancel,

    .dirCreateDir = route.onLane(general, "dirCreateDir"),
    .dirCreateDirPath = route.onLane(general, "dirCreateDirPath"),
    .dirCreateDirPathOpen = route.onLane(general, "dirCreateDirPathOpen"),
    .dirOpenDir = route.onLane(general, "dirOpenDir"),
    .dirStat = route.onLane(general, "dirStat"),
    .dirStatFile = route.onLane(general, "dirStatFile"),
    .dirAccess = route.onLane(general, "dirAccess"),
    .dirCreateFile = route.onLane(general, "dirCreateFile"),
    .dirCreateFileAtomic = route.onLane(general, "dirCreateFileAtomic"),
    .dirOpenFile = route.onLane(general, "dirOpenFile"),
    .dirClose = route.borrowed("dirClose"),
    .dirRead = route.onLane(general, "dirRead"),
    .dirRealPath = route.onLane(general, "dirRealPath"),
    .dirRealPathFile = route.onLane(general, "dirRealPathFile"),
    .dirDeleteFile = route.onLane(general, "dirDeleteFile"),
    .dirDeleteDir = route.onLane(general, "dirDeleteDir"),
    .dirRename = route.onLane(general, "dirRename"),
    .dirRenamePreserve = route.onLane(general, "dirRenamePreserve"),
    .dirSymLink = route.onLane(general, "dirSymLink"),
    .dirReadLink = route.onLane(general, "dirReadLink"),
    .dirSetOwner = route.onLane(general, "dirSetOwner"),
    .dirSetFileOwner = route.onLane(general, "dirSetFileOwner"),
    .dirSetPermissions = route.onLane(general, "dirSetPermissions"),
    .dirSetFilePermissions = route.onLane(general, "dirSetFilePermissions"),
    .dirSetTimestamps = route.onLane(general, "dirSetTimestamps"),
    .dirHardLink = route.onLane(general, "dirHardLink"),

    .fileStat = route.onLane(general, "fileStat"),
    .fileLength = route.onLane(general, "fileLength"),
    .fileClose = io_ops.fileClose,
    .fileWritePositional = io_ops.fileWritePositional,
    .fileWriteFileStreaming = route.onLane(general, "fileWriteFileStreaming"),
    .fileWriteFilePositional = route.onLane(general, "fileWriteFilePositional"),
    .fileReadPositional = io_ops.fileReadPositional,
    .fileSeekBy = route.borrowed("fileSeekBy"),
    .fileSeekTo = route.borrowed("fileSeekTo"),
    .fileSync = io_ops.fileSync,
    .fileIsTty = route.borrowed("fileIsTty"),
    .fileEnableAnsiEscapeCodes = route.borrowed("fileEnableAnsiEscapeCodes"),
    .fileSupportsAnsiEscapeCodes = route.borrowed("fileSupportsAnsiEscapeCodes"),
    .fileSetLength = route.onLane(general, "fileSetLength"),
    .fileSetOwner = route.onLane(general, "fileSetOwner"),
    .fileSetPermissions = route.onLane(general, "fileSetPermissions"),
    .fileSetTimestamps = route.onLane(general, "fileSetTimestamps"),
    .fileLock = route.onLane(.wait, "fileLock"),
    .fileTryLock = route.borrowed("fileTryLock"),
    .fileUnlock = route.borrowed("fileUnlock"),
    .fileDowngradeLock = route.borrowed("fileDowngradeLock"),
    .fileRealPath = route.onLane(general, "fileRealPath"),
    .fileHardLink = route.onLane(general, "fileHardLink"),

    .fileMemoryMapCreate = route.onLane(general, "fileMemoryMapCreate"),
    .fileMemoryMapDestroy = route.borrowed("fileMemoryMapDestroy"),
    .fileMemoryMapSetLength = route.onLane(general, "fileMemoryMapSetLength"),
    .fileMemoryMapRead = route.onLane(general, "fileMemoryMapRead"),
    .fileMemoryMapWrite = route.onLane(general, "fileMemoryMapWrite"),

    .processExecutableOpen = route.onLane(general, "processExecutableOpen"),
    .processExecutablePath = route.onLane(general, "processExecutablePath"),
    .lockStderr = lockStderr,
    .tryLockStderr = tryLockStderr,
    .unlockStderr = unlockStderr,
    .processCurrentPath = route.borrowed("processCurrentPath"),
    .processSetCurrentDir = route.borrowed("processSetCurrentDir"),
    .processSetCurrentPath = route.borrowed("processSetCurrentPath"),
    .processReplace = route.borrowed("processReplace"),
    .processSpawn = route.onLane(general, "processSpawn"),
    .childWait = route.onLane(.wait, "childWait"),
    .childKill = route.onLane(.wait, "childKill"),

    .progressParentFile = route.borrowed("progressParentFile"),
    .inheritParentDir = route.borrowed("inheritParentDir"),
    .inheritParentFile = route.borrowed("inheritParentFile"),

    .now = now,
    .clockResolution = clockResolution,
    .sleep = sleep,

    .random = random,
    .randomSecure = route.borrowed("randomSecure"),

    .netListenIp = route.borrowed("netListenIp"),
    .netAccept = io_ops.netAccept,
    .netBindIp = route.borrowed("netBindIp"),
    .netConnectIp = io_ops.netConnectIp,
    .netListenUnix = route.borrowed("netListenUnix"),
    .netConnectUnix = io_ops.netConnectUnix,
    .netSocketCreatePair = route.borrowed("netSocketCreatePair"),
    .netWriteFile = route.onLane(general, "netWriteFile"),
    .netClose = io_ops.netClose,
    .netShutdown = route.borrowed("netShutdown"),
    .netInterfaceNameResolve = route.borrowed("netInterfaceNameResolve"),
    .netInterfaceName = route.borrowed("netInterfaceName"),
    .netLookup = io_ops.netLookup,
};

// Tasks.

fn crashHandler(userdata: ?*anyopaque) void {
    _ = userdata;
    // The crashing task may call the Io again while the panic is printed:
    // nothing it waits on may be cancelled under it.
    const t = Scheduler.current() orelse return;
    t.protection = .{ .user = .blocked, .acknowledged = true };
}

fn async(userdata: ?*anyopaque, result: []u8, result_alignment: Alignment, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque, *anyopaque) void) ?*Io.AnyFuture {
    const r = Core.of(userdata);
    const t = tasks.concurrent(&r.scheduler, result.len, result_alignment, context, context_alignment, start, @returnAddress()) catch {
        start(context.ptr, result.ptr);
        return null;
    };
    return @ptrCast(t); // safe: a future is its task
}

fn concurrent(userdata: ?*anyopaque, result_len: usize, result_alignment: Alignment, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque, *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
    const r = Core.of(userdata);
    return @ptrCast(try tasks.concurrent(&r.scheduler, result_len, result_alignment, context, context_alignment, start, @returnAddress())); // safe: a future is its task
}

fn taskOf(future: *Io.AnyFuture) *Task {
    return @ptrCast(@alignCast(future)); // safe: `concurrent` hands out tasks as futures
}

fn await(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
    _ = result_alignment;
    tasks.await(&Core.of(userdata).scheduler, taskOf(future), result);
}

fn cancel(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
    _ = result_alignment;
    tasks.cancel(&Core.of(userdata).scheduler, taskOf(future), result);
}

fn groupAsync(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque) void) void {
    const r = Core.of(userdata);
    tasks.groupConcurrent(&r.scheduler, group, context, context_alignment, start, @returnAddress()) catch start(context.ptr);
}

fn groupConcurrent(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: Alignment, start: *const fn (*const anyopaque) void) Io.ConcurrentError!void {
    const r = Core.of(userdata);
    return tasks.groupConcurrent(&r.scheduler, group, context, context_alignment, start, @returnAddress());
}

fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
    _ = token;
    return tasks.groupAwait(&Core.of(userdata).scheduler, group);
}

fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    _ = token;
    tasks.groupCancel(&Core.of(userdata).scheduler, group);
}

fn recancel(userdata: ?*anyopaque) void {
    _ = userdata;
    tasks.recancel();
}

fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    _ = userdata;
    return tasks.swapCancelProtection(new);
}

fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    return tasks.checkCancel(&Core.of(userdata).scheduler);
}

// Futexes.

fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const r = Core.of(userdata);
    return futex.wait(&r.scheduler, &r.futex, ptr, expected, timeout, true);
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    const r = Core.of(userdata);
    futex.wait(&r.scheduler, &r.futex, ptr, expected, .none, false) catch unreachable; // unreachable: not cancelable
}

fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    futex.wake(&Core.of(userdata).futex, ptr, max_waiters);
}

// Batches.

fn batchAwaitAsync(userdata: ?*anyopaque, b: *Io.Batch) Io.Cancelable!void {
    const r = Core.of(userdata);
    return batch.awaitAsync(&r.scheduler, r.lanes.borrowedIo(), b);
}

fn batchAwaitConcurrent(userdata: ?*anyopaque, b: *Io.Batch, timeout: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    const r = Core.of(userdata);
    return batch.awaitConcurrent(&r.scheduler, r.lanes.borrowedIo(), b, timeout);
}

fn batchCancel(userdata: ?*anyopaque, b: *Io.Batch) void {
    const r = Core.of(userdata);
    batch.cancel(&r.scheduler, r.lanes.borrowedIo(), b);
}

// Time.

fn now(userdata: ?*anyopaque, c: Io.Clock) Io.Timestamp {
    const r = Core.of(userdata);
    return r.processors[0].loop.clock.now(c);
}

fn clockResolution(userdata: ?*anyopaque, c: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    const r = Core.of(userdata);
    return switch (r.processors[0].loop.clock) {
        .system => clock.resolution(c),
        .virtual => .fromNanoseconds(1),
    };
}

fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const r = Core.of(userdata);
    const p = Scheduler.processor() orelse return r.lanes.borrowedIo().vtable.sleep(r.lanes.borrowedIo().userdata, timeout);
    const deadline = perform.deadline(p, timeout) orelse return futexWaitForever(r);
    switch (deadline.clock) {
        .cpu_process, .cpu_thread => {
            const lane_io = r.lanes.executor(.wait);
            return lane_call.call(&r.scheduler, &r.lanes, .wait, lane_io.vtable.sleep, .{ lane_io.userdata, timeout });
        },
        else => perform.sleep(&r.scheduler, deadline) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // No room on the loop: a sleep may always end early.
            error.SystemResources => return,
        },
    }
}

/// `sleep(.none)`: until cancelled.
fn futexWaitForever(r: *Core) Io.Cancelable!void {
    var word: u32 = 0;
    while (true) try futex.wait(&r.scheduler, &r.futex, &word, 0, .none, true);
}

// Randomness: a CSPRNG per processor, seeded from the system's.

fn random(userdata: ?*anyopaque, buffer: []u8) void {
    const r = Core.of(userdata);
    const borrowed = r.lanes.borrowedIo();
    const p = Scheduler.processor() orelse return borrowed.vtable.random(borrowed.userdata, buffer);
    const csprng = &r.csprngs[p.index];
    if (!csprng.isInitialized()) {
        var seed: [Io.Threaded.Csprng.seed_len]u8 = undefined;
        borrowed.vtable.random(borrowed.userdata, &seed);
        csprng.rng = .init(seed);
    }
    csprng.rng.fill(buffer);
}

// Standard error: a mutex tasks wait on, and a writer over the runtime's
// own `Io`. The holder is a task, which may move between threads.

fn holderId() usize {
    if (Scheduler.current()) |t| return @intFromPtr(t); // safe: an identity, never dereferenced
    return @as(usize, std.Thread.getCurrentId()) << 1 | 1;
}

fn lockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    const r = Core.of(userdata);
    const me = holderId();
    if (@atomicLoad(usize, &r.stderr.holder, .acquire) != me) {
        try r.stderr.mutex.lock(r.io());
        @atomicStore(usize, &r.stderr.holder, me, .release);
    }
    r.stderr.depth += 1;
    return lockedStderr(r, mode);
}

fn tryLockStderr(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    const r = Core.of(userdata);
    const me = holderId();
    if (@atomicLoad(usize, &r.stderr.holder, .acquire) != me) {
        if (!r.stderr.mutex.tryLock()) return null;
        @atomicStore(usize, &r.stderr.holder, me, .release);
    }
    r.stderr.depth += 1;
    const locked = try lockedStderr(r, mode);
    return locked;
}

fn lockedStderr(r: *Core, mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    const s = &r.stderr;
    if (!s.ready) {
        s.writer.io = r.io();
        s.writer.file = .stderr();
        s.ready = true;
        const environ = r.options.environ;
        s.mode = mode orelse try .detect(r.io(), s.writer.file, environ.containsConstant("NO_COLOR"), environ.containsConstant("CLICOLOR_FORCE"));
    }
    return .{ .file_writer = &s.writer, .terminal_mode = mode orelse s.mode };
}

fn unlockStderr(userdata: ?*anyopaque) void {
    const r = Core.of(userdata);
    const s = &r.stderr;
    if (s.writer.err == null) s.writer.interface.flush() catch |err| switch (err) {
        // The file writer keeps the cause in `err`, read next.
        error.WriteFailed => {},
    };
    if (s.writer.err) |err| {
        if (err == error.Canceled) tasks.recancel();
        s.writer.err = null;
    }
    s.writer.interface.end = 0;
    s.writer.interface.buffer = &.{};
    s.depth -= 1;
    if (s.depth == 0) {
        @atomicStore(usize, &s.holder, 0, .release);
        s.mutex.unlock(r.io());
    }
}
