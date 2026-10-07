//! A connection with a timeout on any `Io`. A runtime keeps the timeout
//! itself: the connect is the kernel's, ended there at the deadline. Any
//! other `Io` races the connect, as a task of its own, against a sleep,
//! and cancels the loser; with no task to spare the connect runs on the
//! caller unbounded, and the result says so. (`Io.Threaded` cannot be
//! given the timeout itself: Zig 0.17's panics on one.)
const std = @import("std");
const Io = std.Io;
const net = Io.net;

const native = @import("../native.zig");

pub const Options = struct {
    mode: net.Socket.Mode = .stream,
    protocol: ?net.Protocol = null,
    timeout: Io.Timeout = .none,
};

pub const Connected = struct {
    stream: net.Stream,
    /// False when a timeout was asked for and this `Io` could not keep it.
    timeout_enforced: bool = true,
};

/// `error.Timeout` when the timeout passed first.
pub const Error = net.IpAddress.ConnectError;

pub fn connect(io: Io, address: *const net.IpAddress, options: Options) Error!Connected {
    const plain: net.IpAddress.ConnectOptions = .{ .mode = options.mode, .protocol = options.protocol };
    if (options.timeout == .none) return .{ .stream = try address.connect(io, plain) };
    if (native.runtimeOf(io) != null) {
        var timed = plain;
        timed.timeout = options.timeout;
        return .{ .stream = try address.connect(io, timed) };
    }
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
        while (race.cancel()) |late| switch (late) {
            .connected => |result| return .{ .stream = try result, .timeout_enforced = false },
            .expired => {},
        };
        unreachable; // unreachable: the connecting task was started above
    };
    return switch (try race.await()) {
        .connected => |result| .{ .stream = try result },
        .expired => |result| if (result) |_| error.Timeout else |err| err,
    };
}
