//! The slots that are operations on the kernel's own queue: reads and
//! writes of sockets and files, accept, connect, close, sync, process
//! waits, and the resolver's bounded lane path. On a backend without an
//! evented form of a call, the call goes to a lane (or std's code,
//! borrowed, where it never blocks).
//!
//! On IOCP a socket is bound to a runtime's port for its life, and std's
//! own socket calls, which complete by APC, are refused on a bound handle:
//! every call on one goes through a port, a thread outside the runtime's
//! too (a processor runs it), and closes and process cleanups forget the
//! handles' bindings.
const builtin = @import("builtin");
const std = @import("std");
const getaddrinfo = @import("../sys/getaddrinfo.zig");
const stub = @import("../ops/resolve.zig");
const lookup_windows = @import("../ops/lookup/windows.zig");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;

const child_ops = @import("child.zig");
const Core = @import("Core.zig");
const Lanes = @import("../Lanes.zig");
const Loop = @import("../Loop.zig");
const Scheduler = @import("../Scheduler.zig");
const Processor = Scheduler.Processor;
const Task = @import("../scheduler/Task.zig");
const perform = @import("../ops/perform.zig");
const lane_call = @import("../ops/lane_call.zig");
const socket = @import("../sys/socket.zig");
const sys_file = @import("../sys/file.zig");
const sys_windows = @import("../sys/windows.zig");

/// Whether `r`'s loops are the kernel's, which run file and socket calls
/// as operations of their own (else a test's fake, which runs only the
/// operations it simulates).
fn native(r: *Core) bool {
    return r.backendKind() != null;
}

fn iocp(r: *Core) bool {
    return builtin.os.tag == .windows and r.backendKind() == .iocp;
}

fn onLane(r: *Core, comptime lane: Lanes.Lane, comptime name: []const u8, args: anytype) @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.? {
    const lane_io = r.lanes.executor(lane);
    return lane_call.call(&r.scheduler, &r.lanes, lane, @field(lane_io.vtable, name), .{lane_io.userdata} ++ args);
}

/// A file call per `Options.files` where it is no ring operation: on the
/// worker inside a blocking bracket where handoff can rescue it, else on
/// the `general` lane.
fn perFiles(r: *Core, comptime name: []const u8, args: anytype) @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.? {
    if (r.options.files == .auto) {
        const b = r.lanes.borrowedIo();
        if (lane_call.onWorker(@field(b.vtable, name), .{b.userdata} ++ args)) |result| return result;
    }
    return onLane(r, .general, name, args);
}

fn borrowed(r: *Core, comptime name: []const u8, args: anytype) @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn".return_type.? {
    const b = r.lanes.borrowedIo();
    return lane_call.borrow(@field(b.vtable, name), .{b.userdata} ++ args);
}

/// Whether the calling thread is outside the runtime and the call runs as
/// std's own code there; on IOCP it runs on a processor instead.
fn outsideBorrowed(r: *Core) bool {
    return Scheduler.processor() == null and !iocp(r);
}

/// Runs `o` for the caller and waits for it: a task on its own processor;
/// a thread outside the runtime, on a processor it hands the operation to.
fn run(r: *Core, o: *Loop.Op, options: perform.Options) perform.Error!void {
    if (Scheduler.processor() != null) return perform.run(&r.scheduler, o, options);
    return perform.runElsewhere(elsewhere(r), o, options.deadline);
}

/// The processor a thread outside the runtime has run its operations:
/// the workers in turn, or the home processor when there are none.
fn elsewhere(r: *Core) *Processor {
    if (r.processors.len == 1) return &r.processors[0];
    const n = r.scheduler.shared.placement.fetchAdd(1, .monotonic);
    return &r.processors[1 + n % (r.processors.len - 1)];
}

/// `timeout` as a deadline on the runtime's clocks.
fn deadlineOf(r: *Core, timeout: Io.Timeout) ?Io.Clock.Timestamp {
    return perform.deadline(Scheduler.processor() orelse &r.processors[0], timeout);
}

pub fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    const r = Core.running(userdata);
    if (outsideBorrowed(r)) return borrowed(r, "operate", .{operation});
    switch (operation) {
        // On IOCP, device control on a handle opened for overlapped calls
        // goes through the port; else std's call, which completes at once
        // or waits on the handle.
        .device_io_control => |d| if (!(iocp(r) and deviceOverlapped(d))) return borrowed(r, "operate", .{operation}),
        .file_read_streaming => |f| if (fileOnLane(r, f.file)) return perFiles(r, "operate", .{operation}),
        .file_write_streaming => |f| if (fileOnLane(r, f.file)) return perFiles(r, "operate", .{operation}),
        else => {},
    }
    var o: Loop.Op = .{ .kind = .{ .io = operation } };
    run(r, &o, .{}) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => failure(operation),
        error.Timeout => unreachable, // unreachable: no deadline given
    };
    return o.result.io;
}

fn deviceOverlapped(d: Io.Operation.DeviceIoControl) bool {
    if (builtin.os.tag != .windows) return false;
    return d.file.flags.nonblocking;
}

/// Whether a streaming call on `file` goes to a lane: every one under
/// `files = .pool`; on IOCP, those on a handle opened for synchronous
/// calls, which no port can finish.
fn fileOnLane(r: *Core, file: Io.File) bool {
    return !native(r) or r.options.files == .pool or (iocp(r) and !file.flags.nonblocking);
}

/// The result of an operation the kernel's queue had no room for.
fn failure(operation: Io.Operation) Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => .{ .file_read_streaming = error.SystemResources },
        .file_write_streaming => .{ .file_write_streaming = error.SystemResources },
        .net_read => .{ .net_read = error.SystemResources },
        .net_write => .{ .net_write = error.SystemResources },
        .net_receive => .{ .net_receive = .{ error.SystemResources, 0 } },
        .net_send => .{ .net_send = .{ error.SystemResources, 0 } },
        .device_io_control => if (builtin.os.tag == .windows) .{ .device_io_control = .{ .u = .{ .Status = .INSUFFICIENT_RESOURCES }, .Information = 0 } } else unreachable, // unreachable: off Windows device control runs borrowed
    };
}

/// Whether `r`'s loops are epoll's or kqueue's.
fn readiness(r: *Core) bool {
    const kind = r.backendKind();
    return kind == .epoll or kind == .kqueue;
}

/// Whether file calls are ring operations: io_uring's, with `files = .auto`.
fn fileOnRing(r: *Core) bool {
    return r.backendKind() == .io_uring and r.options.files == .auto and Scheduler.processor() != null;
}

/// Whether a positional call on `file` is a loop operation: on io_uring
/// for a task (a thread outside reads on a lane, inline); on IOCP for a
/// handle opened for overlapped calls, from any thread.
fn positionalOnLoop(r: *Core, file: Io.File) bool {
    if (!native(r) or r.options.files != .auto) return false;
    if (iocp(r)) return file.flags.nonblocking;
    return fileOnRing(r);
}

pub fn fileReadPositional(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    const r = Core.running(userdata);
    if (!positionalOnLoop(r, file)) {
        // The read itself inside the worker's blocking bracket: std's path
        // around the same call costs ~10% of a cached read.
        if (r.options.files == .auto and readiness(r)) if (Scheduler.enterBlocking()) |blocking| {
            var b = blocking;
            if (b.task.takeCancel()) {
                Scheduler.leaveBlocking(&b);
                return error.Canceled;
            }
            const result = sys_file.readAt(file.handle, data, offset);
            Scheduler.leaveBlocking(&b);
            return result;
        };
        return perFiles(r, "fileReadPositional", .{ file, data, offset });
    }
    // A positional read may be short: the first buffer with room.
    const buffer = for (data) |d| {
        if (d.len > 0) break d;
    } else return 0;
    if (cachedRead(file.handle, buffer, offset)) |n| return n;
    var o: Loop.Op = .{ .kind = .{ .read_at = .{ .file = file.handle, .buffer = buffer, .offset = offset } } };
    run(r, &o, .{}) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => error.SystemResources,
        error.Timeout => unreachable, // unreachable: no deadline given
    };
    return o.result.read_at;
}

/// A read the page cache can answer, answered now: one syscall that never
/// waits on a disk (`RWF_NOWAIT`), instead of a trip through the ring.
/// Null when the data is not cached or the call fails otherwise, which the
/// ring then reports as std would.
fn cachedRead(fd: Io.File.Handle, buffer: []u8, offset: u64) ?usize {
    if (builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    var iov: posix.iovec = .{ .base = buffer.ptr, .len = buffer.len };
    const rc = linux.preadv2(fd, @ptrCast(&iov), 1, @bitCast(offset), linux.RWF.NOWAIT); // safe: one iovec as an array of one
    if (linux.errno(rc) != .SUCCESS) return null;
    return rc;
}

pub fn fileWritePositional(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
    const r = Core.running(userdata);
    if (!positionalOnLoop(r, file)) return perFiles(r, "fileWritePositional", .{ file, header, data, splat, offset });
    // A positional write may be short: the first bytes there are.
    const bytes = first: {
        if (header.len > 0) break :first header;
        for (data[0 .. data.len - 1]) |d| if (d.len > 0) break :first d;
        if (splat > 0 and data[data.len - 1].len > 0) break :first data[data.len - 1];
        return 0;
    };
    var o: Loop.Op = .{ .kind = .{ .write_at = .{ .file = file.handle, .bytes = bytes, .offset = offset } } };
    run(r, &o, .{}) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => error.SystemResources,
        error.Timeout => unreachable, // unreachable: no deadline given
    };
    return o.result.write_at;
}

/// A sync is a ring operation on io_uring; elsewhere no kernel queue
/// flushes (IOCP's flush is synchronous): the `sync` lane.
pub fn fileSync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    const r = Core.running(userdata);
    const on_ring = r.backendKind() == .io_uring and r.options.files == .auto and Scheduler.processor() != null;
    if (!on_ring) return onLane(r, .sync, "fileSync", .{file});
    var o: Loop.Op = .{ .kind = .{ .sync = file.handle } };
    perform.run(&r.scheduler, &o, .{}) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => onLane(r, .sync, "fileSync", .{file}),
        error.Timeout => unreachable, // unreachable: no deadline given
    };
    return o.result.sync;
}

pub fn fileClose(userdata: ?*anyopaque, files: []const Io.File) void {
    const r = Core.running(userdata);
    if (iocp(r)) {
        for (files) |f| closeBound(f.handle);
        return;
    }
    if (native(r)) for (files) |f| abortElsewhere(r, f.handle);
    if (!native(r) or Scheduler.processor() == null) {
        for (files) |f| Loop.closing(f.handle);
        return borrowed(r, "fileClose", .{files});
    }
    for (files) |f| closeOnRing(r, f.handle);
}

/// Closes `handle` through the loop, which first ends every operation this
/// processor's kernel queue holds on it (and on epoll and kqueue lets go of
/// its registration).
fn closeOnRing(r: *Core, handle: Io.File.Handle) void {
    var o: Loop.Op = .{ .kind = .{ .close = handle } };
    perform.run(&r.scheduler, &o, .{ .cancelable = false }) catch socket.close(handle);
}

/// IOCP: ends every call on `handle`, from any thread of the process, and
/// closes it, forgetting its binding. The calls' entries still arrive at
/// the ports of the loops that made them.
fn closeBound(handle: Io.File.Handle) void {
    if (builtin.os.tag != .windows) unreachable; // unreachable: IOCP is Windows'
    sys_windows.cancel(handle, null);
    sys_windows.close(handle);
}

pub fn netClose(userdata: ?*anyopaque, sockets: []const net.Socket) void {
    const r = Core.running(userdata);
    if (iocp(r)) {
        for (sockets) |s| closeBound(s.handle);
        return;
    }
    if (native(r)) for (sockets) |s| abortElsewhere(r, s.handle);
    if (!native(r) or Scheduler.processor() == null) {
        for (sockets) |s| Loop.closing(s.handle);
        return borrowed(r, "netClose", .{sockets});
    }
    for (sockets) |s| {
        abortElsewhere(r, s.handle);
        if (Scheduler.processor() != null) closeOnRing(r, s.handle) else borrowed(r, "netClose", .{&[_]net.Socket{s}});
    }
}

/// Another processor's kernel queue may hold an operation on `fd`, which
/// would keep the socket open past its close: each such processor ends
/// its operations on `fd` first, and the close waits until it has, so the
/// number cannot be reused under a cancel still on its way.
fn abortElsewhere(r: *Core, fd: Io.File.Handle) void {
    const me = Scheduler.processor();
    const t = Scheduler.current();
    for (r.processors) |*other| {
        if (other == me or !r.scheduler.holds(other.index, fd)) continue;
        var a: Abort = .{ .op = .{ .kind = .{ .abort = fd } }, .task = t, .scheduler = &r.scheduler, .target = other };
        if (t != null) {
            Scheduler.park(.{ .func = Abort.send, .context = &a });
        } else {
            other.send(&a.errand);
            const system = Scheduler.system();
            while (a.finished.load(.acquire) != 2) {
                if (a.finished.load(.acquire) == 0) system.futexWaitUncancelable(u32, &a.finished.raw, 0) else std.atomic.spinLoopHint();
            }
        }
    }
}

/// An abort of a descriptor's operations, run on the processor holding them.
const Abort = struct {
    errand: Scheduler.Errand = .{ .run = start },
    op: Loop.Op,
    task: ?*Task,
    finished: std.atomic.Value(u32) = .init(0),
    scheduler: *Scheduler,
    target: *Processor = undefined,

    /// Off the closing task's stack: hand the abort to the processor.
    fn send(context: *anyopaque, t: *Task) void {
        _ = t;
        const a: *Abort = @ptrCast(@alignCast(context)); // safe: `abortElsewhere` passed its `Abort`
        a.target.send(&a.errand);
    }

    fn start(e: *Scheduler.Errand, p: *Processor) void {
        const a: *Abort = @alignCast(@fieldParentPtr("errand", e)); // safe: the field belongs to this record
        a.op.callback = done;
        a.op.user_data = @intFromPtr(a); // safe: read back by `done` while the closing task waits
        p.loop.submit(&a.op) catch a.finish();
    }

    fn done(l: *Loop, o: *Loop.Op) void {
        _ = l;
        const a: *Abort = @ptrFromInt(o.user_data); // safe: `run` stored it
        a.finish();
    }

    fn finish(a: *Abort) void {
        if (a.task) |task| return a.scheduler.ready(task, .completed);
        a.finished.store(1, .release);
        Scheduler.system().futexWake(u32, &a.finished.raw, 1);
        a.finished.store(2, .release);
    }
};

pub fn netAccept(userdata: ?*anyopaque, server: net.Socket.Handle, options: net.Server.AcceptOptions) net.Server.AcceptError!net.Socket {
    const r = Core.running(userdata);
    if (outsideBorrowed(r)) return borrowed(r, "netAccept", .{ server, options });
    // On Windows the options name the accepted socket's mode: a listener is
    // a stream socket there, and its connections are opened as stream
    // sockets of the peer's family.
    var o: Loop.Op = .{ .kind = .{ .accept = server } };
    runAccept(r, &o) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => error.SystemResources,
        error.Timeout => unreachable, // unreachable: no deadline given
    };
    return o.result.accept;
}

pub fn netConnectIp(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Socket {
    const r = Core.running(userdata);
    if (outsideBorrowed(r)) return borrowed(r, "netConnectIp", .{ address, options });
    // On epoll and kqueue the socket connects in non-blocking mode, made so
    // at its creation, and is put back once connected, except where a send
    // ignores `MSG_DONTWAIT` (Darwin): there it stays so.
    const start: socket.Start = if (readiness(r)) .nonblocking else .blocking;
    const fd = socket.open(Io.Threaded.posixAddressFamily(address), options.mode, options.protocol, start) catch |err| return narrow(net.IpAddress.ConnectError, err);
    errdefer {
        // The unpublished socket may already have a readiness registration.
        // Its failed operation is drained; invalidate caches before reuse.
        Loop.closing(fd);
        socket.close(fd);
    }
    var o: Loop.Op = .{ .kind = .{ .connect = .{ .socket = fd, .address = .{ .ip = address.* }, .nonblocking = start == .nonblocking } } };
    run(r, &o, .{ .deadline = deadlineOf(r, options.timeout) }) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.Timeout => error.Timeout,
        error.SystemResources => error.SystemResources,
    };
    o.result.connect catch |err| return narrow(net.IpAddress.ConnectError, err);
    if (start == .nonblocking and socket.send_honors_dontwait) socket.setBlocking(fd) catch |err| return narrow(net.IpAddress.ConnectError, err);
    return .{ .handle = fd, .address = socket.localAddress(fd) catch |err| return narrow(net.IpAddress.ConnectError, err) };
}

/// `err` in the set `E`, or `Unexpected` when `E` has no such error.
fn narrow(comptime E: type, err: anytype) E {
    switch (err) {
        inline else => |e| {
            const name = @errorName(e);
            inline for (@typeInfo(E).error_set.error_names.?) |member| {
                if (comptime std.mem.eql(u8, member, name)) return @field(E, name);
            }
            return error.Unexpected;
        },
    }
}

pub fn netConnectUnix(userdata: ?*anyopaque, address: *const net.UnixAddress) net.UnixAddress.ConnectError!net.Socket.Handle {
    const r = Core.running(userdata);
    if (outsideBorrowed(r)) return borrowed(r, "netConnectUnix", .{address});
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const start: socket.Start = if (readiness(r)) .nonblocking else .blocking;
    const fd = socket.openUnix(address, start) catch |err| return switch (err) {
        error.ProtocolUnsupportedByAddressFamily, error.ProtocolUnsupportedBySystem => error.AddressFamilyUnsupported,
        else => |e| narrow(net.UnixAddress.ConnectError, e),
    };
    errdefer {
        // The unpublished socket may already have a readiness registration.
        // Its failed operation is drained; invalidate caches before reuse.
        Loop.closing(fd);
        socket.close(fd);
    }
    var o: Loop.Op = .{ .kind = .{ .connect = .{ .socket = fd, .address = .{ .unix = address }, .nonblocking = start == .nonblocking } } };
    run(r, &o, .{}) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        error.SystemResources => error.SystemResources,
        error.Timeout => unreachable, // unreachable: no deadline given
    };
    o.result.connect catch |err| return narrow(net.UnixAddress.ConnectError, err);
    if (start == .nonblocking and socket.send_honors_dontwait) socket.setBlocking(fd) catch |err| return narrow(net.UnixAddress.ConnectError, err);
    return fd;
}

// Child processes. On IOCP a wait is the process handle's wait packet,
// then std's own wait, which finds the process ended; Linux and kqueue
// systems use their process watches. Missing watches use the wait lane.
// POSIX pipes close through this runtime before their numbers can be reused:
// their bindings are forgotten first.

pub fn childWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    const r = Core.running(userdata);
    if (builtin.os.tag != .windows) {
        const pipes = takePipes(child);
        defer closePipes(r, pipes);
        return child_ops.childWait(userdata, child);
    }
    if (!iocp(r)) return onLane(r, .wait, "childWait", .{child});
    if (builtin.os.tag != .windows) unreachable; // unreachable: IOCP is Windows'
    var o: Loop.Op = .{ .kind = .{ .wait = .{ .object = child.id.? } } };
    run(r, &o, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // No packet to be had: std's own wait, on the lane.
        error.SystemResources => return onLane(r, .wait, "childWait", .{child}),
        error.Timeout => unreachable, // unreachable: no deadline given
    };
    o.result.wait catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Unsupported, error.Unexpected => return onLane(r, .wait, "childWait", .{child}),
    };
    forgetPipes(child);
    return borrowed(r, "childWait", .{child});
}

pub fn childKill(userdata: ?*anyopaque, child: *std.process.Child) void {
    const r = Core.running(userdata);
    if (builtin.os.tag != .windows) {
        const pipes = takePipes(child);
        defer closePipes(r, pipes);
        const executor = r.lanes.executor(.wait);
        return lane_call.control(&r.scheduler, &r.lanes, .wait, executor.vtable.childKill, .{ executor.userdata, child });
    }
    if (iocp(r)) forgetPipes(child);
    const executor = r.lanes.executor(.wait);
    lane_call.control(&r.scheduler, &r.lanes, .wait, executor.vtable.childKill, .{ executor.userdata, child });
}

/// Transfer pipe cleanup from std's direct close to the runtime's close path.
/// The wait/kill owns the child exclusively; each detached pipe stays live
/// until std has finished with the child, then native pending work is drained
/// and readiness registrations are invalidated before its number is reusable.
fn takePipes(child: *std.process.Child) [3]?Io.File {
    const pipes = .{ child.stdin, child.stdout, child.stderr };
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    return pipes;
}

fn closePipes(r: *Core, pipes: [3]?Io.File) void {
    for (pipes) |pipe| if (pipe) |file| file.close(r.io());
}

fn forgetPipes(child: *const std.process.Child) void {
    if (builtin.os.tag != .windows) return;
    inline for (.{ child.stdin, child.stdout, child.stderr }) |pipe| if (pipe) |file| sys_windows.forget(file.handle);
}

// The resolver's lane path: std's own lookup runs on the lookup lane into
// memory of its own, and only then are the results put into the caller's
// queue, never more than it has room for, so a lookup never waits on its
// own consumer.

const max_kept = 64;

const Kept = struct {
    results: [max_kept]net.HostName.LookupResult = undefined,
    len: usize = 0,
    canonical: ?net.HostName = null,
};

/// On the lookup lane: std's lookup into a private queue, drained here by
/// a second call, keeping at most `max_kept` addresses.
fn lookupOnLane(lane_io: Io, host_name: net.HostName, options: net.HostName.LookupOptions, kept: *Kept) net.HostName.LookupError!void {
    var addresses: [max_kept]net.IpAddress = undefined;
    var canonical: stub.Name = .{};
    const n = if (builtin.os.tag == .windows) windows: {
        const result = lookup_windows.resolve(lane_io, host_name.bytes, options.port, options.family, &addresses, options.canonical_name_buffer) catch |err| return if (err == error.Canceled) error.Canceled else error.UnknownHostName;
        kept.canonical = result.canonical;
        break :windows result.count;
    } else if (getaddrinfo.available)
        (getaddrinfo.lookup(host_name.bytes, options.port, options.family, &addresses, options.canonical_name_buffer) catch return error.UnknownHostName).addresses.len
    else
        stub.lookupNamed(lane_io, host_name, options.port, options.family, &addresses, &canonical) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.UnknownHostName,
        };
    if (canonical.len != 0) if (options.canonical_name_buffer) |buffer| {
        @memcpy(buffer[0..canonical.len], canonical.bytes[0..canonical.len]);
        kept.canonical = net.HostName.init(buffer[0..canonical.len]) catch return error.UnknownHostName;
    };
    for (addresses[0..n]) |address| keep(kept, .{ .address = address });
}

fn keep(kept: *Kept, item: net.HostName.LookupResult) void {
    switch (item) {
        .canonical_name => |name| kept.canonical = name,
        .address => if (kept.len < max_kept) {
            kept.results[kept.len] = item;
            kept.len += 1;
        },
    }
}

pub fn netLookup(userdata: ?*anyopaque, host_name: net.HostName, resolved: *Io.Queue(net.HostName.LookupResult), options: net.HostName.LookupOptions) net.HostName.LookupError!void {
    const r = Core.running(userdata);
    const io = r.io();
    defer resolved.close(io);
    var kept: Kept = .{};
    if (builtin.os.tag == .windows or !getaddrinfo.available) {
        try lookupOnLane(io, host_name, options, &kept);
    } else {
        var addresses: [max_kept]net.IpAddress = undefined;
        const result = try r.lookup.resolve(&r.scheduler, &r.lanes, getaddrinfo.lookup, host_name, options, &addresses);
        kept.canonical = result.canonical;
        for (addresses[0..result.count]) |address| keep(&kept, .{ .address = address });
    }
    // Room for the addresses but one, and the canonical name: never more
    // than the queue holds, so a caller that drains it later loses nothing
    // it had room for, and one that never drains it never waits.
    const room = resolved.capacity() -| 1;
    const addresses = kept.results[0..@min(kept.len, room)];
    _ = resolved.put(io, addresses, 0) catch |err| switch (err) {
        error.Closed => unreachable, // unreachable: only this call closes it
        error.Canceled => return error.Canceled,
    };
    const canonical = kept.canonical orelse host_name;
    _ = resolved.put(io, &.{.{ .canonical_name = canonical }}, 0) catch |err| switch (err) {
        error.Closed => unreachable, // unreachable: only this call closes it
        error.Canceled => return error.Canceled,
    };
}

fn runAccept(r: *Core, o: *Loop.Op) perform.Error!void {
    if (Scheduler.processor()) |p| {
        const owner = r.scheduler.listenerOwner(o.kind.accept, p);
        return perform.accept(&r.scheduler, owner, o);
    }
    return run(r, o, .{});
}
