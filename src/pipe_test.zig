//! Named pipes against the real kernel, on std's `Io.Threaded` and on the
//! IOCP runtime: a server's listener and accept, a client's connect, bytes
//! both ways, the refusals by name, a read bounded on a runtime, and
//! deadlines that say where they cannot be kept. Off Windows, each call
//! says the system has none.
const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const reactor = @import("reactor.zig");
const net = reactor.net;
const pipe = net.pipe;
const Runtime = @import("Runtime.zig");
const supported = @import("Scheduler.zig").supported;

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

/// A pipe name of this run's own, so runs side by side do not meet.
fn uniqueName(io: Io, buffer: []u8) []const u8 {
    var random: [8]u8 = undefined;
    io.random(&random);
    return std.mem.print(buffer, "\\\\.\\pipe\\reactor-test-{x}", .{&random}) catch unreachable; // unreachable: the buffer holds the name
}

test "off Windows a named pipe is NamedPipeUnsupported, and a read of one unbounded" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    try testing.expectError(error.NamedPipeUnsupported, net.connectPipe(io, "\\\\.\\pipe\\x", .{}));
    try testing.expectError(error.NamedPipeUnsupported, net.listenPipe("\\\\.\\pipe\\x", .{ .security = .token_default }));
}

const Served = struct {
    fn echoOnce(io: Io, listener: *net.PipeListener, out: *anyerror!void) void {
        out.* = serve(io, listener);
    }

    /// Accept one client, read its line, answer with the line reversed.
    fn serve(io: Io, listener: *net.PipeListener) !void {
        const conn = try listener.accept(io);
        defer conn.close(io);
        var buffer: [64]u8 = undefined;
        var r = conn.readerStreaming(io, &buffer);
        const line = try r.interface.takeDelimiterInclusive('\n');
        var reversed: [64]u8 = undefined;
        for (line[0 .. line.len - 1], 0..) |c, i| reversed[line.len - 2 - i] = c;
        reversed[line.len - 1] = '\n';
        try conn.writeStreamingAll(io, reversed[0..line.len]);
    }
};

/// A client and a server on `io`: a line each way.
fn roundTrip(io: Io, security: pipe.Security) !void {
    var name_buffer: [64]u8 = undefined;
    const name = uniqueName(io, &name_buffer);
    var listener = try net.listenPipe(name, .{ .security = security });
    defer listener.deinit(io);
    // A second server for the same name is refused.
    try testing.expectError(error.AddressInUse, net.listenPipe(name, .{ .security = .token_default }));
    var served: anyerror!void = {};
    var task = io.concurrent(Served.echoOnce, .{ io, &listener, &served }) catch return error.SkipZigTest;
    const client = try net.connectPipe(io, name, .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    defer client.close(io);
    try client.writeStreamingAll(io, "named pipe\n");
    var buffer: [64]u8 = undefined;
    var r = client.readerStreaming(io, &buffer);
    try testing.expectEqualStrings("epip deman\n", try r.interface.takeDelimiterInclusive('\n'));
    task.await(io);
    try served;
}

test "a client and a server speak over a named pipe on Threaded, its security named" {
    try skipOffWindows();
    try roundTrip(testing.io, .{ .sddl = "D:P(A;;GA;;;OW)(A;;GA;;;SY)" });
    try roundTrip(testing.io, .token_default);
}

test "a pipe nobody made, a name outside the pipe namespace and SDDL the system cannot read are refused by name" {
    try skipOffWindows();
    const io = testing.io;
    try testing.expectError(error.FileNotFound, net.connectPipe(io, "\\\\.\\pipe\\reactor-test-nobody-made-this", .{}));
    try testing.expectError(error.InvalidPipeName, net.connectPipe(io, "C:\\not\\a\\pipe", .{}));
    try testing.expectError(error.InvalidSecurityDescriptor, net.listenPipe("\\\\.\\pipe\\reactor-test-bad-sddl", .{ .security = .{ .sddl = "not sddl" } }));
}

test "a server's disconnect ends its client's read under way" {
    try skipOffWindows();
    const io = testing.io;
    var name_buffer: [64]u8 = undefined;
    const name = uniqueName(io, &name_buffer);
    var listener = try net.listenPipe(name, .{ .security = .token_default });
    defer listener.deinit(io);
    const Accepted = struct {
        fn run(task_io: Io, l: *net.PipeListener, out: *?Io.File) void {
            out.* = l.accept(task_io) catch null;
        }
    };
    var server: ?Io.File = null;
    var accepting = io.concurrent(Accepted.run, .{ io, &listener, &server }) catch return error.SkipZigTest;
    const client = try net.connectPipe(io, name, .{});
    defer client.close(io);
    accepting.await(io);
    const conn = server orelse return error.AcceptFailed;
    defer conn.close(io);
    // The server's own read under way ends when it disconnects.
    const Reading = struct {
        fn run(task_io: Io, file: Io.File) anyerror!usize {
            var buf: [8]u8 = undefined;
            return file.readStreaming(task_io, &.{&buf});
        }
    };
    var reading = io.concurrent(Reading.run, .{ io, conn }) catch return error.SkipZigTest;
    try io.sleep(.fromMilliseconds(50), .awake);
    pipe.disconnect(io, conn);
    try testing.expect(std.meta.isError(reading.await(io)));
}

test "off a runtime a pipe's deadlines are refused, and its reads unbounded" {
    try skipOffWindows();
    const io = testing.io;
    var name_buffer: [64]u8 = undefined;
    const name = uniqueName(io, &name_buffer);
    var listener = try net.listenPipe(name, .{ .security = .token_default });
    defer listener.deinit(io);
    const client = try net.connectPipe(io, name, .{});
    defer client.close(io);
    var deadlines: net.Deadlines = .init(.fromMilliseconds(100));
    defer deadlines.deinit(io);
    var watch: net.Deadlines.Watch = .initPipe(client);
    try testing.expect(!deadlines.add(io, &watch));
    deadlines.remove(io, &watch);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(pipe.Readiness.unbounded, try pipe.readPipeWithin(io, client, &buffer, .fromMilliseconds(10)));
}

fn runtime(r: *Runtime) !void {
    try skipOffWindows();
    if (!supported) return error.SkipZigTest;
    try r.init(testing.allocator, .{ .workers = 2, .max_tasks = 64, .stack_size = .fromRaw(256 << 10), .environ = testing.environ });
    errdefer r.deinit();
    try r.start();
}

test "on the IOCP runtime a pipe speaks, and a read waits a bounded time without taking anything" {
    var r: Runtime = undefined;
    try runtime(&r);
    defer r.deinit();
    const io = r.io();
    try roundTrip(io, .{ .sddl = "D:P(A;;GA;;;OW)(A;;GA;;;SY)" });

    var name_buffer: [64]u8 = undefined;
    const name = uniqueName(io, &name_buffer);
    var listener = try net.listenPipe(name, .{ .security = .token_default });
    defer listener.deinit(io);
    const Accepted = struct {
        fn run(task_io: Io, l: *net.PipeListener, out: *?Io.File) void {
            out.* = l.accept(task_io) catch null;
        }
    };
    var server: ?Io.File = null;
    var accepting = io.concurrent(Accepted.run, .{ io, &listener, &server }) catch return error.SkipZigTest;
    const client = try net.connectPipe(io, name, .{});
    defer client.close(io);
    accepting.await(io);
    const conn = server orelse return error.AcceptFailed;
    defer conn.close(io);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(pipe.Readiness.timed_out, try pipe.readPipeWithin(io, client, &buffer, .fromMilliseconds(20)));
    try conn.writeStreamingAll(io, "ok");
    const got = try pipe.readPipeWithin(io, client, &buffer, .fromSeconds(5));
    try testing.expectEqualStrings("ok", buffer[0..got.ready]);
}
