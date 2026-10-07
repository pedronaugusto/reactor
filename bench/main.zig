//! reactor's own workloads, timed: `zig build bench [-- --smoke] [-- --json]
//! [-- --io threaded] [-- --only <workload>]`.
//!
//! - spawn: `concurrent` + `await` of an empty task; a group of 10,000.
//! - wake: two tasks handing a futex word back and forth, on one worker and
//!   across workers.
//! - timers: a million loop timers armed, 99% cancelled before they fire;
//!   the overshoot of 1 ms sleeps.
//! - echo: 64-byte messages over loopback TCP, one connection and 32.
//! - files: cached 4 KiB positional reads.
//! - loop: `run(.nowait)` with nothing to do.
//! - waits: two tasks handing a turn back and forth through `reactor.wait`
//!   on pipes, and through two `Wake`s.
//! - lanes: `reactor.blocking` of an empty call on the `general` lane.
//! - deadlines: 64-byte round trips on one connection, each read under
//!   `net.Deadlines`.
//!
//! `--io threaded` runs the `Io` workloads on std's `Io.Threaded` instead,
//! for the same numbers on the interface's baseline. Timings are wall-clock
//! on this machine; CI only compiles this file.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const reactor = @import("reactor");

const Report = struct {
    w: *Io.Writer,
    json: bool,
    io_name: []const u8,

    fn line(r: Report, workload: []const u8, name: []const u8, value: f64, unit: []const u8) !void {
        if (r.json) {
            try r.w.print("{{\"io\":\"{s}\",\"workload\":\"{s}\",\"name\":\"{s}\",\"value\":{d:.3},\"unit\":\"{s}\"}}\n", .{ r.io_name, workload, name, value, unit });
        } else {
            try r.w.print("{s:<9} {s:<8} {s:<34} {d:>14.2} {s}\n", .{ r.io_name, workload, name, value, unit });
        }
        try r.w.flush();
    }
};

const Config = struct {
    smoke: bool = false,
    json: bool = false,
    threaded: bool = false,
    only: ?[]const u8 = null,
    workers: ?u16 = null,

    fn wants(c: Config, workload: []const u8) bool {
        const o = c.only orelse return true;
        return std.mem.eql(u8, o, workload);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    var c: Config = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--smoke")) c.smoke = true else if (std.mem.eql(u8, arg, "--json")) c.json = true else if (std.mem.eql(u8, arg, "--io")) {
            i += 1;
            c.threaded = std.mem.eql(u8, args[i], "threaded");
        } else if (std.mem.eql(u8, arg, "--only")) {
            i += 1;
            c.only = args[i];
        } else if (std.mem.eql(u8, arg, "--workers")) {
            i += 1;
            c.workers = try std.fmt.parseInt(u16, args[i], 10);
        } else return error.UnknownArgument;
    }
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    const r: Report = .{ .w = &stdout.interface, .json = c.json, .io_name = if (c.threaded) "threaded" else "reactor" };

    if (c.wants("timers") and !c.threaded) try loopTimers(r, gpa, c);
    if (c.wants("loop") and !c.threaded) try loopIdle(r, gpa, c);

    if (c.threaded) {
        var threaded: Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        try ioWorkloads(r, gpa, threaded.io(), c, null);
        return;
    }
    var runtime: reactor.Runtime = undefined;
    runtime.init(gpa, .{ .workers = c.workers }) catch |err| switch (err) {
        error.BackendUnavailable => {
            try r.line("runtime", "no evented backend on this system", 0, "-");
            return;
        },
        else => |e| return e,
    };
    defer runtime.deinit();
    try runtime.start();
    try ioWorkloads(r, gpa, runtime.io(), c, &runtime);
}

fn ioWorkloads(r: Report, gpa: std.mem.Allocator, io: Io, c: Config, runtime: ?*reactor.Runtime) !void {
    if (c.wants("spawn")) try spawn(r, io, c);
    if (c.wants("wake")) try wake(r, io, c);
    if (c.wants("timers")) try sleeps(r, io, c);
    if (c.wants("echo")) try echo(r, gpa, io, c);
    if (c.wants("files")) try files(r, io, c);
    if (c.wants("waits")) try waits(r, io, c);
    if (c.wants("lanes")) try lanes(r, io, c);
    if (c.wants("deadlines")) try deadlines(r, io, c);
    _ = runtime;
}

fn now(io: Io) Io.Timestamp {
    return Io.Clock.awake.now(io);
}

fn nsBetween(a: Io.Timestamp, b: Io.Timestamp) f64 {
    return @floatFromInt(a.durationTo(b).nanoseconds);
}

// spawn

fn nothing() void {}

fn member(n: *std.atomic.Value(u32)) Io.Cancelable!void {
    _ = n.fetchAdd(1, .monotonic);
}

fn spawn(r: Report, io: Io, c: Config) !void {
    const n: usize = if (c.smoke) 100 else 200_000;
    const t0 = now(io);
    for (0..n) |_| {
        var f = try io.concurrent(nothing, .{});
        f.await(io);
    }
    const t1 = now(io);
    try r.line("spawn", "concurrent + await, empty", nsBetween(t0, t1) / @as(f64, @floatFromInt(n)), "ns/task");

    const members: usize = if (c.smoke) 100 else 10_000;
    var count: std.atomic.Value(u32) = .init(0);
    const rounds: usize = if (c.smoke) 1 else 10;
    const t2 = now(io);
    for (0..rounds) |_| {
        var group: Io.Group = .init;
        for (0..members) |_| try group.concurrent(io, member, .{&count});
        try group.await(io);
    }
    const t3 = now(io);
    try r.line("spawn", "group of 10k, concurrent + await", nsBetween(t2, t3) / @as(f64, @floatFromInt(members * rounds)), "ns/task");
}

// wake

const PingPong = struct {
    word: std.atomic.Value(u32) = .init(0),
    rounds: u32,

    /// Waits for its turn (`me`), passes it on, `rounds` times.
    fn player(p: *PingPong, io: Io, me: u32) Io.Cancelable!void {
        var k: u32 = 0;
        while (k < p.rounds) : (k += 1) {
            while (p.word.load(.acquire) != me) try io.futexWait(u32, &p.word.raw, me ^ 1);
            p.word.store(me ^ 1, .release);
            io.futexWake(u32, &p.word.raw, 1);
        }
    }
};

fn wake(r: Report, io: Io, c: Config) !void {
    const rounds: u32 = if (c.smoke) 100 else 200_000;
    var p: PingPong = .{ .rounds = rounds };
    const t0 = now(io);
    var a = try io.concurrent(PingPong.player, .{ &p, io, 0 });
    var b = try io.concurrent(PingPong.player, .{ &p, io, 1 });
    try a.await(io);
    try b.await(io);
    const t1 = now(io);
    try r.line("wake", "ping-pong between two tasks", nsBetween(t0, t1) / @as(f64, @floatFromInt(rounds * 2)), "ns/wake");
}

// timers

fn loopTimers(r: Report, gpa: std.mem.Allocator, c: Config) !void {
    var l: reactor.Loop = undefined;
    const n: usize = if (c.smoke) 1000 else 1_000_000;
    l.init(gpa, .{ .max_ops = @intCast(n) }) catch |err| switch (err) {
        error.BackendUnavailable => return,
        else => |e| return e,
    };
    defer l.deinit(gpa);
    const ops = try gpa.alloc(reactor.Loop.Op, n);
    defer gpa.free(ops);
    const io = Io.Threaded.global_single_threaded.io();
    const start = Io.Clock.Timestamp.now(io, .awake);
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    const t0 = now(io);
    for (ops) |*o| {
        const at = start.addDuration(.{ .raw = .fromMicroseconds(@intCast(random.uintLessThan(u32, 50_000) + 1000)), .clock = .awake });
        o.* = .{ .kind = .{ .timer = at } };
        try l.submit(o);
    }
    const t1 = now(io);
    for (ops, 0..) |*o, k| if (k % 100 != 0) l.cancel(o);
    const t2 = now(io);
    var reaped: [256]*reactor.Loop.Op = undefined;
    var fired: usize = 0;
    while (fired < n) {
        _ = try l.run(.once);
        while (true) {
            const got = l.reap(&reaped);
            if (got.len == 0) break;
            fired += got.len;
        }
    }
    const count: f64 = @floatFromInt(n);
    try r.line("timers", "timer, arm", nsBetween(t0, t1) / count, "ns/timer");
    try r.line("timers", "timer, cancel", nsBetween(t1, t2) / (count * 0.99), "ns/timer");
}

fn sleeps(r: Report, io: Io, c: Config) !void {
    const n: usize = if (c.smoke) 5 else 500;
    var overshoot: std.ArrayList(i96) = .empty;
    defer overshoot.deinit(std.heap.page_allocator);
    for (0..n) |_| {
        const t0 = now(io);
        try io.sleep(.fromMilliseconds(1), .awake);
        const t1 = now(io);
        try overshoot.append(std.heap.page_allocator, t0.durationTo(t1).nanoseconds - std.time.ns_per_ms);
    }
    std.mem.sort(i96, overshoot.items, {}, std.sort.asc(i96));
    const p50: f64 = @floatFromInt(overshoot.items[n / 2]);
    const p99: f64 = @floatFromInt(overshoot.items[n * 99 / 100]);
    try r.line("timers", "1 ms sleep overshoot p50", p50 / 1000, "us");
    try r.line("timers", "1 ms sleep overshoot p99", p99 / 1000, "us");
}

// echo

fn echoConnection(io: Io, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(io);
    var buffer: [64]u8 = undefined;
    while (true) {
        var data: [1][]u8 = .{&buffer};
        const got = (io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } }) catch return).net_read catch return;
        if (got.data_len == 0) return;
        var sent: usize = 0;
        while (sent < got.data_len) {
            var out: [1][]const u8 = .{buffer[sent..got.data_len]};
            sent += (io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &out } }) catch return).net_write catch return;
        }
    }
}

fn acceptAll(io: Io, server: *Io.net.Server, count: usize, group: *Io.Group) Io.Cancelable!void {
    for (0..count) |_| {
        const stream = server.accept(io) catch return;
        group.concurrent(io, echoConnection, .{ io, stream }) catch return;
    }
}

fn client(io: Io, address: Io.net.IpAddress, messages: usize) Io.Cancelable!void {
    const stream = address.connect(io, .{ .mode = .stream }) catch return;
    defer stream.close(io);
    var message: [64]u8 = @splat('x');
    for (0..messages) |_| {
        var out: [1][]const u8 = .{&message};
        _ = (io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &out } }) catch return).net_write catch return;
        var got: usize = 0;
        while (got < message.len) {
            var data: [1][]u8 = .{message[got..]};
            const n = ((io.operate(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } }) catch return).net_read catch return).data_len;
            if (n == 0) return;
            got += n;
        }
    }
}

fn echo(r: Report, gpa: std.mem.Allocator, io: Io, c: Config) !void {
    _ = gpa;
    for ([_]usize{ 1, 32 }) |connections| {
        const total: usize = if (c.smoke) 100 else 200_000;
        const per = total / connections;
        const listen: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try listen.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);
        var servers: Io.Group = .init;
        var acceptor = try io.concurrent(acceptAll, .{ io, &server, connections, &servers });
        const t0 = now(io);
        var clients: Io.Group = .init;
        for (0..connections) |_| try clients.concurrent(io, client, .{ io, server.socket.address, per });
        try clients.await(io);
        const t1 = now(io);
        try acceptor.await(io);
        try servers.await(io);
        const name = if (connections == 1) "64 B round trips, 1 connection" else "64 B round trips, 32 connections";
        try r.line("echo", name, @as(f64, @floatFromInt(per * connections)) / (nsBetween(t0, t1) / std.time.ns_per_s), "msg/s");
    }
}

// files

fn files(r: Report, io: Io, c: Config) !void {
    var tmp = Io.Dir.cwd();
    const path = "reactor-bench-file.bin";
    const file = try tmp.createFile(io, path, .{ .read = true });
    defer {
        file.close(io);
        tmp.deleteFile(io, path) catch {};
    }
    var block: [4096]u8 = @splat(1);
    for (0..256) |k| try file.writePositionalAll(io, &block, k * block.len);
    const n: usize = if (c.smoke) 100 else 200_000;
    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();
    const t0 = now(io);
    for (0..n) |_| _ = try file.readPositional(io, &.{&block}, random.uintLessThan(u64, 256) * block.len);
    const t1 = now(io);
    try r.line("files", "cached 4 KiB positional read", nsBetween(t0, t1) / @as(f64, @floatFromInt(n)), "ns/read");
}

// loop

/// What a host pays to ask a loop for work when there is none.
fn loopIdle(r: Report, gpa: std.mem.Allocator, c: Config) !void {
    var l: reactor.Loop = undefined;
    l.init(gpa, .{}) catch |err| switch (err) {
        error.BackendUnavailable => return,
        else => |e| return e,
    };
    defer l.deinit(gpa);
    const io = Io.Threaded.global_single_threaded.io();
    const n: usize = if (c.smoke) 100 else 1_000_000;
    const t0 = now(io);
    for (0..n) |_| _ = try l.run(.nowait);
    const t1 = now(io);
    try r.line("loop", "run(.nowait) with nothing ready", nsBetween(t0, t1) / @as(f64, @floatFromInt(n)), "ns/run");
}

// waits

const PipeTurns = struct {
    /// a: to the second player; b: back to the first.
    a: [2]std.posix.fd_t,
    b: [2]std.posix.fd_t,
    rounds: u32,

    fn first(t: *PipeTurns, io: Io) !void {
        var byte: [1]u8 = .{0};
        for (0..t.rounds) |_| {
            _ = std.posix.system.write(t.a[1], &byte, 1);
            try reactor.wait(io, .{ .readable = t.b[0] }, .none);
            _ = std.posix.system.read(t.b[0], &byte, 1);
        }
    }

    fn second(t: *PipeTurns, io: Io) !void {
        var byte: [1]u8 = .{0};
        for (0..t.rounds) |_| {
            try reactor.wait(io, .{ .readable = t.a[0] }, .none);
            _ = std.posix.system.read(t.a[0], &byte, 1);
            _ = std.posix.system.write(t.b[1], &byte, 1);
        }
    }
};

const WakeTurns = struct {
    a: reactor.Wake,
    b: reactor.Wake,
    rounds: u32,

    fn first(t: *WakeTurns, io: Io) !void {
        for (0..t.rounds) |_| {
            t.a.signal();
            try reactor.wait(io, .{ .wake = &t.b }, .none);
        }
    }

    fn second(t: *WakeTurns, io: Io) !void {
        for (0..t.rounds) |_| {
            try reactor.wait(io, .{ .wake = &t.a }, .none);
            t.b.signal();
        }
    }
};

fn waits(r: Report, io: Io, c: Config) !void {
    if (builtin.os.tag == .windows) return;
    const rounds: u32 = if (c.smoke) 100 else 100_000;
    var p: PipeTurns = .{ .a = try Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true }), .b = try Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true }), .rounds = rounds };
    defer for (p.a ++ p.b) |fd| {
        _ = std.posix.system.close(fd);
    };
    const t0 = now(io);
    var second = try io.concurrent(PipeTurns.second, .{ &p, io });
    try p.first(io);
    try second.await(io);
    const t1 = now(io);
    try r.line("waits", "wait on pipes, round trip", nsBetween(t0, t1) / @as(f64, @floatFromInt(rounds)), "ns/round");

    var w: WakeTurns = .{ .a = try .init(io), .b = try .init(io), .rounds = rounds };
    defer w.a.deinit(io);
    defer w.b.deinit(io);
    const t2 = now(io);
    var other = try io.concurrent(WakeTurns.second, .{ &w, io });
    try w.first(io);
    try other.await(io);
    const t3 = now(io);
    try r.line("waits", "Wake signal and wait, round trip", nsBetween(t2, t3) / @as(f64, @floatFromInt(rounds)), "ns/round");
}

// lanes

fn emptyCall() u32 {
    return 1;
}

fn lanes(r: Report, io: Io, c: Config) !void {
    const n: usize = if (c.smoke) 100 else 20_000;
    var total: u32 = 0;
    const t0 = now(io);
    for (0..n) |_| total += reactor.blocking(io, .general, emptyCall, .{});
    const t1 = now(io);
    std.debug.assert(total == n);
    try r.line("lanes", "blocking, empty call on general", nsBetween(t0, t1) / @as(f64, @floatFromInt(n)), "ns/call");
}

// deadlines

fn deadlineClient(io: Io, address: Io.net.IpAddress, messages: usize) !void {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var d: reactor.net.Deadlines = .init(.fromSeconds(10));
    defer d.deinit(io);
    var watch: reactor.net.Deadlines.Watch = .init(stream.socket.handle);
    _ = d.add(io, &watch);
    defer d.remove(io, &watch);
    var message: [64]u8 = @splat('x');
    for (0..messages) |_| {
        var out: [1][]const u8 = .{&message};
        _ = try (try io.operate(.{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &out } })).net_write;
        var got: usize = 0;
        while (got < message.len) {
            var data: [1][]u8 = .{message[got..]};
            const at = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(10), .clock = .awake });
            const result = try d.operate(io, &watch, .{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } }, at);
            const n = (try result.net_read).data_len;
            if (n == 0) return error.EndOfStream;
            got += n;
        }
    }
}

fn deadlines(r: Report, io: Io, c: Config) !void {
    const total: usize = if (c.smoke) 100 else 100_000;
    const listen: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try listen.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var servers: Io.Group = .init;
    var acceptor = try io.concurrent(acceptAll, .{ io, &server, 1, &servers });
    const t0 = now(io);
    try deadlineClient(io, server.socket.address, total);
    const t1 = now(io);
    try acceptor.await(io);
    try servers.await(io);
    try r.line("deadlines", "64 B round trips, reads under a deadline", @as(f64, @floatFromInt(total)) / (nsBetween(t0, t1) / std.time.ns_per_s), "msg/s");
}
