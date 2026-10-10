//! Bounded, detachable libc lookups. Request storage belongs to the
//! runtime, so cancelling a caller never leaves libc using its stack.
const Lookup = @This();
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const Scheduler = @import("../Scheduler.zig");
const Task = @import("../scheduler/Task.zig");
const Lanes = @import("../Lanes.zig");
const getaddrinfo = @import("../sys/getaddrinfo.zig");

pub const capacity = 64;
pub const Provider = *const fn ([]const u8, u16, ?net.IpAddress.Family, []net.IpAddress, ?*[254]u8) getaddrinfo.Error!getaddrinfo.Result;
pub const Result = struct { count: usize, canonical: ?net.HostName = null };
const State = enum(u8) { pending, completed, canceled };

const Record = struct {
    occupied: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(u32) = .init(1),
    published: std.atomic.Value(bool) = .init(false),
    notified: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(State) = .init(.pending),
    hook: Task.Hook = .{ .cancel = cancel },
    job: Lanes.Job = .{ .run = run, .done = done, .lane = .lookup, .pending = .init(0) },
    scheduler: *Scheduler = undefined,
    task: *Task = undefined,
    provider: Provider = undefined,
    name: [254]u8 = undefined,
    name_len: usize = 0,
    port: u16 = 0,
    family: ?net.IpAddress.Family = null,
    addresses: [capacity]net.IpAddress = undefined,
    canonical_buffer: [254]u8 = undefined,
    result: net.HostName.LookupError!getaddrinfo.Result = undefined,
    lanes: *Lanes = undefined,

    fn notify(r: *Record) void {
        if (!r.published.load(.seq_cst)) return;
        if (!r.notified.swap(true, .seq_cst)) r.scheduler.ready(r.task, .completed);
    }

    fn cancel(hook: *Task.Hook, _: *Task) void {
        const r: *Record = @alignCast(@fieldParentPtr("hook", hook)); // safe: the hook belongs to this request
        if (r.state.cmpxchgStrong(.pending, .canceled, .seq_cst, .seq_cst) == null) r.notify();
    }

    fn submit(context: *anyopaque, _: *Task) void {
        const r: *Record = @ptrCast(@alignCast(context)); // safe: resolve passed its reserved record
        r.published.store(true, .seq_cst);
        if (r.state.load(.seq_cst) == .canceled) r.notify();
        r.lanes.submit(&r.job);
    }

    fn run(job: *Lanes.Job) void {
        const r: *Record = @alignCast(@fieldParentPtr("job", job)); // safe: the job belongs to this request
        r.result = if (r.state.load(.acquire) == .canceled) error.Canceled else result: {
            break :result r.provider(r.name[0..r.name_len], r.port, r.family, &r.addresses, &r.canonical_buffer) catch error.UnknownHostName;
        };
    }

    fn done(job: *Lanes.Job) void {
        const r: *Record = @alignCast(@fieldParentPtr("job", job)); // safe: the job belongs to this request
        const completed = r.state.cmpxchgStrong(.pending, .completed, .seq_cst, .seq_cst) == null;
        r.finished.store(1, .release);
        Io.Threaded.global_single_threaded.io().futexWake(u32, &r.finished.raw, 1);
        if (completed) r.notify();
    }
};

records: []Record,

pub fn init(gpa: Allocator, count: u32) Allocator.Error!Lookup {
    const records = try gpa.alloc(Record, count);
    @memset(records, .{});
    return .{ .records = records };
}

/// Detached calls must have ended before the lanes and storage are freed.
pub fn deinit(l: *Lookup, gpa: Allocator, lanes: *Lanes) void {
    const system = Io.Threaded.global_single_threaded.io();
    for (l.records) |*r| {
        while (r.finished.load(.acquire) == 0) system.futexWaitUncancelable(u32, &r.finished.raw, 0);
        r.job.group.await(lanes.executor(.lookup)) catch unreachable; // unreachable: shutdown runs outside a cancelable Threaded task
    }
    for (l.records) |*r| lanes.retire(&r.job);
    gpa.free(l.records);
    l.* = undefined;
}

fn acquire(l: *Lookup) ?*Record {
    for (l.records) |*r| {
        if (r.occupied.cmpxchgStrong(false, true, .acquire, .monotonic) != null) continue;
        if (r.finished.load(.acquire) == 0 or r.job.held()) {
            r.occupied.store(false, .release);
            continue;
        }
        if (r.job.admitted()) r.lanes.retire(&r.job);
        r.job = .{ .run = Record.run, .done = Record.done, .lane = .lookup, .pending = .init(0) };
        return r;
    }
    return null;
}

/// Completion wins a race with cancellation; an uninterruptible libc
/// call whose caller was canceled holds its slot until it actually ends.
pub fn resolve(l: *Lookup, s: *Scheduler, lanes: *Lanes, provider: Provider, name: net.HostName, options: net.HostName.LookupOptions, out: []net.IpAddress) net.HostName.LookupError!Result {
    const t = Scheduler.current() orelse return direct(lanes, provider, name, options, out);
    if (lanes.inlined()) return direct(lanes, provider, name, options, out);
    const r = l.acquire() orelse return error.SystemResources;
    defer r.occupied.store(false, .release);
    r.scheduler = s;
    r.task = t;
    r.lanes = lanes;
    r.provider = provider;
    @memcpy(r.name[0..name.bytes.len], name.bytes);
    r.name_len = name.bytes.len;
    r.port = options.port;
    r.family = options.family;
    r.published.store(false, .monotonic);
    r.notified.store(false, .monotonic);
    r.state.store(.pending, .monotonic);
    std.debug.assert(lanes.started);
    if (!lanes.admit(&r.job)) return error.SystemResources;
    t.enterWait(&r.hook) catch |err| {
        lanes.retire(&r.job);
        return err;
    };
    r.finished.store(0, .release);
    r.job.pending.store(1, .monotonic);
    Scheduler.park(.{ .func = Record.submit, .context = r });
    t.leaveWait();
    if (r.state.load(.acquire) == .canceled) return t.acknowledge();
    const result = try r.result;
    const n = @min(result.addresses.len, out.len);
    @memcpy(out[0..n], r.addresses[0..n]);
    var canonical: ?net.HostName = null;
    if (options.canonical_name_buffer) |buffer| if (result.canonical) |name_result| {
        @memcpy(buffer[0..name_result.bytes.len], name_result.bytes);
        canonical = net.HostName.init(buffer[0..name_result.bytes.len]) catch null;
    };
    return .{ .count = n, .canonical = canonical };
}

fn direct(lanes: *Lanes, provider: Provider, name: net.HostName, options: net.HostName.LookupOptions, out: []net.IpAddress) net.HostName.LookupError!Result {
    lanes.countInline(.lookup);
    const result = provider(name.bytes, options.port, options.family, out, options.canonical_name_buffer) catch return error.UnknownHostName;
    return .{ .count = result.addresses.len, .canonical = result.canonical };
}
