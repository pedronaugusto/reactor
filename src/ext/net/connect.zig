//! A connection with a timeout on any `Io`. A runtime keeps the timeout
//! itself: the connect is the kernel's, ended there at the deadline. Any
//! other `Io` races the connect, as a task of its own, against a sleep,
//! and cancels the loser; with no task to spare the connect runs on the
//! caller unbounded, and the result says so. (`Io.Threaded` cannot be
//! given the timeout itself: Zig 0.17's panics on one.)
const std = @import("std");
const builtin = @import("builtin");
const dial = @import("../../sys/dial.zig");
const Loop = @import("../../Loop.zig");
const Scheduler = @import("../../Scheduler.zig");
const perform = @import("../../ops/perform.zig");
const wait = @import("../wait.zig");
const Io = std.Io;
const net = Io.net;

const native = @import("../native.zig");

pub const Options = struct {
    mode: net.Socket.Mode = .stream,
    protocol: ?net.Protocol = null,
    timeout: Io.Timeout = .none,
    /// Bind the local endpoint before connecting.
    local_address: ?net.IpAddress = null,
    /// Restrict outgoing traffic to this interface.
    interface: net.Interface = .none,
};

pub const Connected = struct {
    stream: net.Stream,
    /// False when a timeout was asked for and this `Io` could not keep it.
    timeout_enforced: bool = true,
};

/// `error.Timeout` when the timeout passed first.
pub const Error = net.IpAddress.ConnectError;

pub fn connect(io: Io, address: *const net.IpAddress, options: Options) Error!Connected {
    if (options.local_address != null or !options.interface.isNone()) return bound(io, address, options);
    const plain: net.IpAddress.ConnectOptions = .{ .mode = options.mode, .protocol = options.protocol };
    if (options.timeout == .none) return .{ .stream = try address.connect(io, plain) };
    if (native.runtimeOf(io)) |core| if (native.taskRuntime(core)) {
        var timed = plain;
        timed.timeout = options.timeout;
        return .{ .stream = try address.connect(io, timed) };
    };
    const deadline = options.timeout.toDeadline(io);
    const Race = union(enum) {
        connected: Error!net.Stream,
        expired: Io.Cancelable!void,
    };
    var buffer: [2]Race = undefined;
    var race: Io.Select(Race) = .init(io, &buffer);
    defer while (race.cancel()) |late| switch (late) {
        .connected => |result| if (result) |stream| stream.close(io) else |_| {},
        .expired => {},
    };
    race.concurrent(.connected, net.IpAddress.connect, .{ address, io, plain }) catch
        return .{ .stream = try address.connect(io, plain), .timeout_enforced = false };
    race.concurrent(.expired, Io.Timeout.sleep, .{ deadline, io }) catch {
        // The connect runs already: wait for it, unbounded.
        return switch (try race.await()) {
            .connected => |result| .{ .stream = try result, .timeout_enforced = false },
            .expired => unreachable, // unreachable: no timer task was started
        };
    };
    return switch (try race.await()) {
        .connected => |result| .{ .stream = try result },
        .expired => |result| expired: {
            try result;
            // A connection already made remains the caller's, even if the
            // timer's result reached the select first.
            while (race.cancel()) |late| switch (late) {
                .connected => |connected| if (connected) |stream| break :expired .{ .stream = stream } else |_| {},
                .expired => {},
            };
            break :expired error.Timeout;
        },
    };
}

fn bound(io: Io, address: *const net.IpAddress, options: Options) Error!Connected {
    const local = options.local_address orelse switch (address.*) {
        .ip4 => net.IpAddress{ .ip4 = .unspecified(0) },
        .ip6 => net.IpAddress{ .ip6 = .unspecified(0) },
    };
    if (@as(net.IpAddress.Family, local) != @as(net.IpAddress.Family, address.*)) return error.AddressFamilyUnsupported;
    const socket = local.bind(io, .{ .mode = options.mode, .protocol = options.protocol }) catch |err| return switch (err) {
        error.AddressInUse => error.AddressUnavailable,
        else => |e| e,
    };
    errdefer socket.close(io);
    try dial.interface(io, socket.handle, address.*, options.interface);
    if (native.runtimeOf(io)) |core| if (native.taskRuntime(core) and core.backendKind() != null) {
        const p = Scheduler.processor().?;
        var op: Loop.Op = .{ .kind = .{ .connect = .{ .socket = socket.handle, .address = .{ .ip = address.* } } } };
        perform.run(&core.scheduler, &op, .{ .deadline = perform.deadline(p, options.timeout) }) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.Timeout => error.Timeout,
            error.SystemResources => error.SystemResources,
        };
        op.result.connect catch |err| return switch (err) {
            inline else => |e| narrow: {
                inline for (@typeInfo(Error).error_set.error_names.?) |name| if (comptime std.mem.eql(u8, name, @errorName(e))) break :narrow @field(Error, name);
                break :narrow error.Unexpected;
            },
        };
        return .{ .stream = .{ .socket = .{ .handle = socket.handle, .address = try dial.local(io, socket.handle) } } };
    };
    if (builtin.os.tag == .windows) {
        const Race = union(enum) { connected: Error!void, expired: Io.Cancelable!void };
        var buffer: [2]Race = undefined;
        var race: Io.Select(Race) = .init(io, &buffer);
        defer while (race.cancel()) |_| {};
        race.concurrent(.connected, dial.windowsConnect, .{ io, socket.handle, address }) catch {
            try dial.windowsConnect(io, socket.handle, address);
            return .{ .stream = .{ .socket = socket }, .timeout_enforced = options.timeout == .none };
        };
        if (options.timeout != .none) race.concurrent(.expired, Io.Timeout.sleep, .{ options.timeout.toDeadline(io), io }) catch {
            const outcome = try race.await();
            try outcome.connected;
            return .{ .stream = .{ .socket = socket }, .timeout_enforced = false };
        };
        switch (try race.await()) {
            .connected => |result| try result,
            .expired => |result| {
                try result;
                while (race.cancel()) |late| switch (late) {
                    .connected => |connected| if (connected) |_| return .{ .stream = .{ .socket = .{ .handle = socket.handle, .address = try dial.local(io, socket.handle) } } } else |_| {},
                    .expired => {},
                };
                return error.Timeout;
            },
        }
    } else {
        try dial.nonblocking(socket.handle, true);
        if (!try dial.start(socket.handle, address)) {
            wait.wait(io, .{ .writable = socket.handle }, options.timeout) catch |err| return switch (err) {
                error.Canceled => error.Canceled,
                error.Timeout => error.Timeout,
                else => error.Unexpected,
            };
            try dial.finish(socket.handle);
        }
        try dial.nonblocking(socket.handle, false);
    }
    return .{ .stream = .{ .socket = .{ .handle = socket.handle, .address = try dial.local(io, socket.handle) } } };
}
