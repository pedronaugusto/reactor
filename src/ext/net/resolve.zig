//! A name's addresses, bounded, on any `Io`.
//!
//! std's lookup puts its answers one at a time into a queue, and run
//! inline it waits on itself forever once a name has more answers than the
//! queue holds: the `getaddrinfo` path puts every result libc gives, the
//! DNS client one per record, whatever the documented bound of 16 says. A
//! runtime's lookup never puts more than its queue holds, so it runs
//! inline. On any other `Io` the lookup runs as a task of its own, drained
//! here; with no task to spare a libc target calls `getaddrinfo` on this
//! one, and any other returns `ConcurrencyUnavailable`. An address needs
//! no lookup.
const std = @import("std");
const Io = std.Io;
const IpAddress = Io.net.IpAddress;
const HostName = Io.net.HostName;

const getaddrinfo = @import("../../sys/getaddrinfo.zig");
const native = @import("../native.zig");

/// The most addresses one lookup keeps.
pub const max_addresses = 32;

pub const Options = struct {
    /// Only addresses of this family.
    family: ?IpAddress.Family = null,
};

pub const Error = error{
    /// The name is not a host name.
    InvalidHostName,
    /// The name has no address, or the resolver failed.
    NameNotResolved,
    /// No task could run the lookup beside this one, and this target has no
    /// lookup that runs without one.
    ConcurrencyUnavailable,
} || Io.Cancelable;

/// `host`'s addresses on `port`, at most `out.len` (and `max_addresses`),
/// in the resolver's order: the address itself when `host` is one, IPv6
/// brackets allowed.
pub fn resolve(io: Io, host: []const u8, port: u16, options: Options, out: []IpAddress) Error![]IpAddress {
    std.debug.assert(out.len != 0);
    if (literal(host, port)) |address| {
        if (options.family) |f| if (address != f) return error.NameNotResolved;
        out[0] = address;
        return out[0..1];
    }
    const name = HostName.init(host) catch return error.InvalidHostName;
    var buffer: [max_addresses + 1]HostName.LookupResult = undefined;
    const lookup_options: HostName.LookupOptions = .{ .port = port, .family = options.family };
    if (native.runtimeOf(io) != null) {
        // Bounded by the runtime: never more than the queue holds.
        var queue: Io.Queue(HostName.LookupResult) = .init(buffer[0 .. @min(out.len, max_addresses) + 1]);
        HostName.lookup(name, io, &queue, lookup_options) catch |err| return mapLookup(err);
        return drain(io, &queue, options.family, out);
    }
    var queue: Io.Queue(HostName.LookupResult) = .init(&buffer);
    var future = io.concurrent(HostName.lookup, .{ name, io, &queue, lookup_options }) catch {
        if (getaddrinfo.available) return (getaddrinfo.lookup(host, port, options.family, out, null) catch return error.NameNotResolved).addresses;
        return error.ConcurrencyUnavailable;
    };
    defer future.cancel(io) catch {};
    const found = try drain(io, &queue, options.family, out);
    future.await(io) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.NameNotResolved,
    };
    return found;
}

/// Everything the queue gives until it is closed, at most `out.len`
/// addresses of `family`.
fn drain(io: Io, queue: *Io.Queue(HostName.LookupResult), family: ?IpAddress.Family, out: []IpAddress) Error![]IpAddress {
    var count: usize = 0;
    while (queue.getOne(io)) |result| switch (result) {
        .address => |a| if (count < out.len and (family == null or a == family.?)) {
            out[count] = a;
            count += 1;
        },
        .canonical_name => {},
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {},
    }
    if (count == 0) return error.NameNotResolved;
    return out[0..count];
}

fn mapLookup(err: HostName.LookupError) Error {
    return switch (err) {
        error.Canceled => error.Canceled,
        else => error.NameNotResolved,
    };
}

/// `host` as an address, IPv6 brackets allowed, or null when it is a name.
pub fn literal(host: []const u8, port: u16) ?IpAddress {
    const bare = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    return IpAddress.parse(bare, port) catch null;
}
