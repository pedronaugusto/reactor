//! Waits on kernel objects over any `Io`: descriptors readable or
//! writable, a process ending, a Windows object, a `Wake`.
//!
//! On a runtime's task every member that is a descriptor is a readiness
//! operation of the task's own loop, so the wait is a cancelation point
//! and costs no thread. Windows objects use native wait completion packets.
//! A process on a system with no descriptor for it goes to the runtime's
//! `wait` lane. Any other `Io` waits on the calling thread, in slices of
//! `slice` so a cancel is seen between them.
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const windows = std.os.windows;

const backend = @import("../backend.zig");
const Loop = @import("../Loop.zig");
const Scheduler = @import("../Scheduler.zig");
const perform = @import("../ops/perform.zig");
const readiness = @import("../ops/readiness.zig");
const lane_call = @import("../ops/lane_call.zig");
const poll = @import("../sys/poll.zig");
const process = @import("../sys/process.zig");
const win32 = @import("../sys/win32.zig");
const native = @import("native.zig");
const Process = @import("Process.zig");
const Wake = @import("Wake.zig");

const is_windows = builtin.os.tag == .windows;

/// The most members one wait takes.
pub const max = 64;

/// Whether this system can report a priority event: `poll` says `POLLPRI`.
pub const has_priority = switch (builtin.os.tag) {
    .windows, .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => false,
    else => true,
};

/// How long one wait on the calling thread lasts before it looks for a
/// cancel, on an `Io` that is not a runtime.
pub const slice: poll.Millis = .fromRaw(5);

pub const Waitable = union(enum) {
    /// A descriptor or socket has data, end of file, or an error (inotify,
    /// kqueue, pipes, eventfd).
    readable: Io.File.Handle,
    writable: Io.File.Handle,
    /// A priority event, which `poll` reports as `POLLPRI`: urgent data on
    /// a stream socket, a change of a `cgroup.events` or sysfs attribute
    /// file (read it, then wait: a change after that read is not lost).
    /// A runtime waits for it on the task's loop on io_uring and epoll, and
    /// on the `wait` lane under kqueue, which has no filter for it. Windows
    /// has no such event and Darwin's `poll` cannot report it (its urgent
    /// data is seen through `select` alone): a wait there is `Unsupported`.
    priority: Io.File.Handle,
    /// A process has ended. It is not reaped.
    process: *const Process,
    /// Windows: any waitable object (event, process, thread, timer).
    object: if (is_windows) windows.HANDLE else noreturn,
    /// Set by `Wake.signal`; the wait that reports it clears it.
    wake: *Wake,

    /// Readiness asked of a Windows handle that is not a socket.
    pub const Error = error{ Unsupported, Unexpected };
};

pub const WaitError = Waitable.Error || error{Timeout} || Io.Cancelable;

/// Waits until `what` is ready, or `timeout` passes.
pub fn wait(io: Io, what: Waitable, timeout: Io.Timeout) WaitError!void {
    _ = try waitAny(io, &.{what}, timeout);
}

/// The lowest index of a member that is ready, waiting until one is or
/// `timeout` passes. At most `max` members.
pub fn waitAny(io: Io, set: []const Waitable, timeout: Io.Timeout) WaitError!usize {
    assert(set.len > 0);
    assert(set.len <= max);
    const index = try waitFirst(io, set, timeout);
    switch (set[index]) {
        .wake => |w| w.notify.clear(),
        else => {},
    }
    return index;
}

fn waitFirst(io: Io, set: []const Waitable, timeout: Io.Timeout) WaitError!usize {
    if (!has_priority) for (set) |m| if (m == .priority) return error.Unsupported;
    if (timeout.toDurationFromNow(io)) |remaining| if (remaining.raw.nanoseconds <= 0) {
        return try once(io, set, poll.look) orelse error.Timeout;
    };
    // A process that had ended when it was opened needs no wait.
    if (!is_windows) for (set, 0..) |m, i| switch (m) {
        .process => |p| if (p.watch == .ended) {
            if (i > 0) if (try once(io, set[0..i], poll.look)) |earlier| return earlier;
            return i;
        },
        else => {},
    };
    const core = native.runtimeOf(io) orelse return sliced(io, set, timeout.toDeadline(io));
    if (!native.taskRuntime(core)) return sliced(io, set, timeout.toDeadline(io));
    var members: [max]Loop.Waitable = undefined;
    if (descriptors(set, &members, core.backendKind())) {
        const p = Scheduler.processor().?;
        const index = readiness.first(&core.scheduler, members[0..set.len], perform.deadline(p, timeout)) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.Timeout => error.Timeout,
            error.Unsupported => error.Unsupported,
            error.Unexpected, error.SystemResources => error.Unexpected,
        };
        if (index > 0) if (try once(io, set[0..index], poll.look)) |earlier| return earlier;
        return index;
    }
    const lane_io = core.lanes.executor(.wait);
    return lane_call.call(&core.scheduler, &core.lanes, .wait, &sliced, .{ lane_io, set, timeout.toDeadline(io) });
}

/// Each member as a descriptor the loop can wait on; false when one is
/// not, which `kind`, the loop's backend, decides for a priority event.
fn descriptors(set: []const Waitable, out: *[max]Loop.Waitable, kind: ?backend.Kind) bool {
    if (is_windows) {
        // Separate wait packets could consume several auto-reset events or
        // semaphore counts. A kernel wait-any consumes only its winner.
        if (set.len > 1) for (set) |m| if (m == .object) return false;
        for (set, out[0..set.len]) |m, *d| d.* = switch (m) {
            .readable => |h| .{ .readable = h },
            .writable => |h| .{ .writable = h },
            .priority => unreachable, // unreachable: `waitFirst` refused it, as Windows has no priority events
            .process => |p| .{ .object = p.watch },
            .wake => |w| .{ .object = w.notify.handle },
            .object => |h| .{ .object = h },
        };
        return true;
    }
    for (set, out[0..set.len]) |m, *d| d.* = switch (m) {
        .readable => |h| .{ .readable = h },
        .writable => |h| .{ .writable = h },
        .priority => |h| if (kind == .kqueue) return false else .{ .priority = h },
        .process => |p| switch (p.watch) {
            .descriptor => |h| .{ .readable = h },
            .ended, .asking, .exiting => return false,
        },
        .wake => |w| .{ .readable = w.notify.handle },
        .object => return false,
    };
    return true;
}

/// Waits on the calling thread until a member is ready or `deadline`
/// passes: through `io`'s own concurrent batch where every member is a
/// descriptor (`batched`), otherwise in slices between which `io` is asked
/// for a cancel.
fn sliced(io: Io, set: []const Waitable, deadline: Io.Timeout) WaitError!usize {
    if (try once(io, set, poll.look)) |i| return i;
    if (try batched(io, set, deadline)) |i| return i;
    while (true) {
        try io.checkCancel();
        const next = sliceFor(deadline.toDurationFromNow(io)) orelse return error.Timeout;
        if (try once(io, set, next)) |i| return i;
    }
}

/// The longest one batch wait lasts when the caller gave no deadline.
const batch_bound: Io.Clock.Duration = .{ .raw = .fromSeconds(3600), .clock = .awake };

/// A wait through `io`'s concurrent batch: a zero-length read for each
/// readable member and a zero-length write for each writable one, which an
/// `Io` completes once its descriptor is ready, moving no bytes. `Io.Threaded`
/// waits for them in one `poll` it can interrupt for a cancel, so a blocked
/// wait costs no wake at all where slices cost one every `slice` (2 s
/// blocked: 3 context switches against 341, lookout on reactor, 2026-10-10).
/// Null when it cannot be used, and the caller slices: a member that is not
/// a descriptor (a priority event, a process with no watch descriptor, a
/// Windows object), an `Io` without concurrent batches, or one that
/// completed a member that a look then found not ready (an `Io` whose
/// zero-length operation does not wait for readiness).
fn batched(io: Io, set: []const Waitable, deadline: Io.Timeout) WaitError!?usize {
    if (is_windows) return null;
    var storage: [max]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(storage[0..set.len]);
    for (set, 0..) |m, i| {
        const handle: Io.File.Handle, const write = switch (m) {
            .readable => |h| .{ h, false },
            .writable => |h| .{ h, true },
            .wake => |w| .{ w.notify.handle, false },
            .process => |p| switch (p.watch) {
                .descriptor => |h| .{ h, false },
                else => return null,
            },
            .priority, .object => return null,
        };
        const file: Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
        batch.addAt(@intCast(i), if (write)
            .{ .file_write_streaming = .{ .file = file, .data = &.{""} } }
        else
            .{ .file_read_streaming = .{ .file = file, .data = &.{} } });
    }
    defer batch.cancel(io);
    while (true) {
        // Never `.none`: with one member and no deadline `Io.Threaded`
        // makes the operation at once instead of polling for it.
        const bound: Io.Timeout = switch (deadline) {
            .none => .{ .deadline = .fromNow(io, batch_bound) },
            else => deadline,
        };
        batch.awaitConcurrent(io, bound) catch |err| switch (err) {
            error.Timeout => if (deadline == .none) continue else return error.Timeout,
            error.ConcurrencyUnavailable => return null,
            error.Canceled => return error.Canceled,
        };
        // `Io.Threaded` completes a member only once `poll` said it is
        // ready; another `Io` is asked again by a look, the lowest ready
        // index being the answer either way.
        if (io.vtable.batchAwaitConcurrent == threaded_batch) {
            var lowest: ?usize = null;
            while (batch.next()) |c| lowest = if (lowest) |l| @min(l, c.index) else c.index;
            if (lowest) |i| {
                if (i > 0) if (try once(io, set[0..i], poll.look)) |earlier| return earlier;
                return i;
            }
        }
        return try once(io, set, poll.look);
    }
}

const threaded_batch = Io.Threaded.global_single_threaded.io().vtable.batchAwaitConcurrent;

/// The next slice's length for what is `left` of a deadline (null: no
/// deadline): at most `slice`, rounded up to a millisecond; null once it
/// has passed.
pub fn sliceFor(left: ?Io.Clock.Duration) ?poll.Millis {
    const remaining = left orelse return slice;
    if (remaining.raw.nanoseconds <= 0) return null;
    // Beyond what a u32 of milliseconds holds is far past one slice.
    const ms = poll.Millis.fromIoDuration(remaining.raw, .up) catch return slice;
    return if (ms.compare(slice) == .gt) slice else ms;
}

/// One wait of at most `limit`: the ready member, or null.
fn once(io: Io, set: []const Waitable, limit: poll.Millis) WaitError!?usize {
    if (is_windows) return onceWindows(io, set, limit);
    var entries: [max]poll.Entry = undefined;
    var map: [max]usize = undefined;
    var n: usize = 0;
    var ended: ?usize = null;
    for (set, 0..) |m, i| {
        const entry: poll.Entry = switch (m) {
            .readable => |h| .{ .handle = h, .interest = .readable },
            .writable => |h| .{ .handle = h, .interest = .writable },
            .priority => |h| .{ .handle = h, .interest = .priority },
            .process => |p| switch (p.watch) {
                .descriptor => |h| .{ .handle = h, .interest = .readable },
                .ended => {
                    ended = i;
                    break;
                },
                .asking => {
                    if (process.endedUnreaped(p.id) != .running) {
                        ended = i;
                        break;
                    }
                    continue;
                },
                // Asked first; if it runs still, the kqueue's `SIGCHLD` says
                // when to ask again.
                .exiting => |h| if (process.endedUnreaped(p.id) != .running) {
                    ended = i;
                    break;
                } else .{ .handle = h, .interest = .readable },
            },
            .wake => |w| .{ .handle = w.notify.handle, .interest = .readable },
            .object => unreachable, // unreachable: Windows' alone, which waits in `onceWindows`
        };
        entries[n] = entry;
        map[n] = i;
        n += 1;
    }
    if (n == 0) {
        if (ended) |i| return i;
        // Nothing to wait on but processes asked about: wait the slice.
        try io.sleep(limit.toIoDuration(), .awake);
        return null;
    }
    var ready = poll.descriptors(entries[0..n], if (ended != null) poll.look else limit) catch return error.Unexpected;
    // A `SIGCHLD` is some child's: when it is not this one's, take it and
    // look again for the others.
    while (ready) |r| {
        const queue = switch (set[map[r]]) {
            .process => |p| switch (p.watch) {
                .exiting => |h| if (process.endedUnreaped(p.id) == .running) h else break,
                else => break,
            },
            else => break,
        };
        process.drain(queue);
        ready = poll.descriptors(entries[0..n], poll.look) catch return error.Unexpected;
    }
    return if (ready) |r| map[r] else ended;
}

fn onceWindows(io: Io, set: []const Waitable, limit: poll.Millis) WaitError!?usize {
    var handles: [max]windows.HANDLE = undefined;
    var map: [max]usize = undefined;
    var n: usize = 0;
    var sockets = false;
    for (set, 0..) |m, i| switch (m) {
        .readable, .writable => sockets = true,
        .priority => unreachable, // unreachable: `waitFirst` refused it, as Windows has no priority events
        .process => |p| {
            handles[n] = p.watch;
            map[n] = i;
            n += 1;
        },
        .object => |h| {
            handles[n] = h;
            map[n] = i;
            n += 1;
        },
        .wake => |w| {
            handles[n] = w.notify.handle;
            map[n] = i;
            n += 1;
        },
    };
    if (sockets) for (set, 0..) |m, i| switch (m) {
        .readable => |h| if (try socketReady(io, h, .readable)) return i,
        .writable => |h| if (try socketReady(io, h, .writable)) return i,
        .priority => unreachable, // unreachable: `waitFirst` refused it, as Windows has no priority events
        .process => |p| if (win32.WaitForSingleObject(p.watch, 0) == win32.wait_object_0) return i,
        .object => |h| if (win32.WaitForSingleObject(h, 0) == win32.wait_object_0) return i,
        .wake => |w| if (win32.WaitForSingleObject(w.notify.handle, 0) == win32.wait_object_0) return i,
    };
    if (n == 0) {
        try io.sleep(limit.toIoDuration(), .awake);
        return null;
    }
    const sooner: poll.Millis = .fromRaw(1);
    const ready = poll.objects(handles[0..n], if (sockets and limit.compare(sooner) == .gt) sooner else limit) catch return error.Unexpected;
    return if (ready) |r| map[r] else null;
}

/// Whether a Windows socket is ready now: AFD's own poll, with no wait.
fn socketReady(io: Io, socket: windows.HANDLE, interest: enum { readable, writable }) WaitError!bool {
    var info: win32.AfdPollInfo = .{ .Timeout = 0, .Handles = .{.{
        .Handle = socket,
        .Events = switch (interest) {
            .readable => win32.afd_poll.receive | win32.afd_poll.disconnect | win32.afd_poll.abort | win32.afd_poll.accept | win32.afd_poll.local_close,
            .writable => win32.afd_poll.send | win32.afd_poll.abort | win32.afd_poll.connect_fail | win32.afd_poll.local_close,
        },
        .Status = .SUCCESS,
    }} };
    const result = try io.operate(.{ .device_io_control = .{
        .file = .{ .handle = socket, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.POLL,
        .in = std.mem.asBytes(&info),
        .out = std.mem.asBytes(&info),
    } });
    const status = result.device_io_control.u.Status;
    if (status == .INVALID_HANDLE) return error.Unsupported;
    if (status != .SUCCESS) return error.Unexpected;
    return info.NumberOfHandles > 0 and info.Handles[0].Events != 0;
}
