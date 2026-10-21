//! The runtime's `netWriteFile`: a file's bytes sent to a socket by the
//! kernel (`sendfile`, Linux and Darwin), where std's `Io.Threaded` has none
//! and a `Writer` copies through memory. A kernel record layer under the
//! socket (Linux's kTLS) seals what it sends.
//!
//! Each send waits first for the socket to be writable, through the task's
//! loop (no thread, a cancelation point), and asks for no more than a
//! writable socket has room for (`sendfile.room`). A send cut short by a
//! full socket holds its last piece back (Linux sends every piece but a
//! call's last as more to come), and sends made before the socket had room
//! went as badly as plain writes: over loopback with a 16 KiB send and
//! receive buffer, a MiB took 6 s either way, and 0.1 to 1.2 s waiting
//! first. The call takes no flag that keeps it from waiting, so the
//! socket's mode decides where it runs: in non-blocking mode on the worker,
//! a socket that has no room after all waited for again; in blocking mode
//! (a runtime's sockets are, on Linux) in a blocking bracket or on a lane,
//! so a slow peer holds up no processor. What the writer and the reader
//! hold in memory goes first, as a write of its own.
const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Core = @import("Core.zig");
const io_ops = @import("io_ops.zig");
const Scheduler = @import("../Scheduler.zig");
const readiness = @import("../ops/readiness.zig");
const lane_call = @import("../ops/lane_call.zig");
const sendfile = @import("../sys/sendfile.zig");
const poll = @import("../sys/poll.zig");

pub const Error = net.Stream.Writer.WriteFileError;

pub fn netWriteFile(userdata: ?*anyopaque, socket: net.Socket.Handle, header: []const u8, file_reader: *Io.File.Reader, limit: Io.Limit) Error!usize {
    if (comptime !sendfile.supported) return error.Unimplemented;
    const buffered = file_reader.interface.buffered();
    if (header.len != 0 or buffered.len != 0) {
        const result = try io_ops.operate(userdata, .{ .net_write = .{
            .socket_handle = socket,
            .header = header,
            .data = &.{limit.slice(buffered)},
        } });
        const n = try result.net_write;
        file_reader.interface.toss(n -| header.len);
        return n;
    }
    if (limit == .nothing) return 0;
    const offset: ?u64 = switch (file_reader.mode) {
        .positional => file_reader.pos,
        .streaming => if (sendfile.needs_offset) return error.Unimplemented else null,
        .positional_simple, .streaming_simple => return error.Unimplemented,
        .failure => return error.ReadFailed,
    };
    var count = limit.minInt(sendfile.max_count);
    if (file_reader.size) |size| {
        if (size <= file_reader.pos) return error.EndOfStream;
        count = @min(count, size - file_reader.pos);
    }
    const r = Core.running(userdata);
    const in_blocking_mode = try sendfile.blocking(socket);
    const handle = file_reader.file.handle;
    while (true) {
        try writable(r, socket);
        const asked = @min(count, try sendfile.room(socket));
        const sent = try sendFailed(file_reader, if (in_blocking_mode)
            sendBlocking(r, socket, handle, offset, asked)
        else
            sendfile.send(socket, handle, offset, asked));
        switch (sent) {
            .sent => |n| {
                if (n == 0) {
                    file_reader.size = file_reader.pos;
                    return error.EndOfStream;
                }
                file_reader.pos += n;
                return n;
            },
            .would_block => continue,
            .unsupported => return error.Unimplemented,
        }
    }
}

/// A send to a socket in blocking mode, where it may wait: on the worker
/// inside a blocking bracket, where the monitor hands the processor on
/// should it wait; on the `general` lane where no bracket can be had; on the
/// calling thread when it is outside the runtime.
fn sendBlocking(r: *Core, socket: net.Socket.Handle, file: Io.File.Handle, offset: ?u64, count: usize) sendfile.Error!sendfile.Sent {
    const args = .{ socket, file, offset, count };
    if (Scheduler.processor() == null) return @call(.auto, sendfile.send, args);
    if (lane_call.onWorker(&sendfile.send, args)) |result| return result;
    return lane_call.call(&r.lanes, .general, &sendfile.send, args);
}

/// A send's failure as the writer reports it: a failed read of the file is
/// the reader's, on the reader.
fn sendFailed(file_reader: *Io.File.Reader, result: sendfile.Error!sendfile.Sent) Error!sendfile.Sent {
    return result catch |err| switch (err) {
        error.InputOutput => {
            file_reader.err = error.InputOutput;
            return error.ReadFailed;
        },
        else => |e| return e,
    };
}

/// Waits until `socket` is writable: through the task's loop on a task of
/// this runtime, else on the calling thread.
fn writable(r: *Core, socket: net.Socket.Handle) Error!void {
    if (Scheduler.processor()) |p| if (p.scheduler == &r.scheduler and p.current != null) {
        _ = readiness.first(&r.scheduler, &.{.{ .writable = socket }}, null) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.SystemResources => error.SystemResources,
            error.Timeout => unreachable, // unreachable: no deadline given
            error.Unsupported, error.Unexpected => error.Unexpected,
        };
        return;
    };
    const entry: poll.Entry = .{ .handle = socket, .interest = .writable };
    while (true) {
        if (poll.descriptors(&.{entry}, .fromRaw(std.math.maxInt(u32))) catch |err| return switch (err) {
            error.SystemResources => error.SystemResources,
            error.Unexpected => error.Unexpected,
        }) |_| return;
    }
}
