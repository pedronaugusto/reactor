//! A batch's operation while the kernel holds it. It lives in the batch's
//! own storage, as a `Pending` entry whose `userdata` keeps the operation
//! itself, packed, so that an operation a timeout cancelled can go back to
//! `submitted` whole. The kernel identifies it by a token: the batch's
//! address and the operation's index, with three low bits left for the
//! backend's own tags.
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;

pub const Pending = Io.Operation.Storage.Pending;

const is_windows = builtin.os.tag == .windows;

/// A batch on a runtime holds at most this many operations.
pub const max_operations = 1 << 16;

/// Where a completion belongs: a batch and an index in its storage.
pub const Token = enum(u64) {
    _,

    pub fn of(b: *Io.Batch, at: u32) Token {
        assert(at < max_operations);
        const address: u64 = @intFromPtr(b); // safe: packed into a token, unpacked by `batch`
        assert(address & 7 == 0);
        assert(address >> 48 == 0);
        return @fromBackingInt(@intCast((address >> 3) << 19 | @as(u64, at) << 3));
    }

    pub fn batch(t: Token) *Io.Batch {
        return @ptrFromInt((@backingInt(t) >> 19) << 3);
    }

    pub fn index(t: Token) u32 {
        return @intCast((@backingInt(t) >> 3) & (max_operations - 1));
    }

    pub fn pending(t: Token) *Pending {
        return &t.batch().storage[t.index()].pending;
    }
};

/// How a batch's operation ended in the kernel.
pub const Outcome = union(enum) {
    result: Io.Operation.Result,
    /// The kernel cancelled it: the batch's own cancel, or someone
    /// closing its descriptor.
    canceled,
};

/// The operation as it waits in the storage's words. POSIX descriptors are
/// small enough to sit beside a word of flags. Windows handles are a word
/// each, so counts and the header's length there are 32-bit, clamped: a
/// longer header makes a short write, which a write may always be.
const Packed = if (is_windows) extern union {
    file_read: extern struct { handle: Io.File.Handle, flags: u32, data_len: u32, data_ptr: [*]const []u8 },
    file_write: extern struct { handle: Io.File.Handle, flags: u32, splat: u32, header_ptr: [*]const u8, header_len: usize, data_ptr: [*]const []const u8, data_len: usize },
    net_receive: extern struct { handle: net.Socket.Handle, flags: u32, messages_len: u32, messages_ptr: [*]net.IncomingMessage, data_ptr: [*]u8, data_len: usize },
    net_send: extern struct { handle: net.Socket.Handle, flags: u32, messages_len: u32, messages_ptr: [*]net.OutgoingMessage },
    net_read: extern struct { handle: net.Socket.Handle, data_len: u32, control_len: u32, data_ptr: [*][]u8, control_ptr: [*]u8 },
    net_write: extern struct { handle: net.Socket.Handle, splat: u32, header_len: u32, header_ptr: [*]const u8, data_ptr: [*]const []const u8, data_len: u32, control_len: u32, control_ptr: [*]const u8 },
    device_io_control: extern struct { handle: Io.File.Handle, flags: u32, code: u32, in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_len: usize },

    comptime {
        // The last word is the backend's (`backendWord`).
        assert(@sizeOf(Packed) <= @sizeOf(Pending.Userdata) - @sizeOf(usize));
    }
} else extern union {
    file_read: extern struct { handle: Io.File.Handle, flags: u32, data_ptr: [*]const []u8, data_len: usize },
    file_write: extern struct { handle: Io.File.Handle, flags: u32, header_ptr: [*]const u8, header_len: usize, data_ptr: [*]const []const u8, data_len: usize, splat: usize },
    net_receive: extern struct { handle: net.Socket.Handle, flags: u32, messages_ptr: [*]net.IncomingMessage, messages_len: usize, data_ptr: [*]u8, data_len: usize },
    net_send: extern struct { handle: net.Socket.Handle, flags: u32, messages_ptr: [*]net.OutgoingMessage, messages_len: usize },
    net_read: extern struct { handle: net.Socket.Handle, pad: u32, data_ptr: [*][]u8, data_len: usize, control_ptr: [*]u8, control_len: usize },
    net_write: extern struct { handle: net.Socket.Handle, splat: u32, header_ptr: [*]const u8, header_len: usize, data_ptr: [*]const []const u8, data_len: usize, control_ptr: [*]const u8, control_len: usize },

    comptime {
        assert(@sizeOf(Packed) <= @sizeOf(Pending.Userdata));
    }
};

fn packedOf(p: *Pending) *Packed {
    return @ptrCast(&p.userdata); // safe: `Packed` fits in, and is no more aligned than, the userdata words
}

fn packedOfConst(p: *const Pending) *const Packed {
    return @ptrCast(&p.userdata); // safe: `Packed` fits in, and is no more aligned than, the userdata words
}

/// Keeps `operation` in `p`. A splat beyond 2^32 - 1 is clamped: the
/// write is then a short one, which a write may always be.
pub fn pack(p: *Pending, operation: Io.Operation) void {
    p.tag = operation;
    if (is_windows) return packWindows(packedOf(p), operation);
    const d = packedOf(p);
    switch (operation) {
        .file_read_streaming => |o| d.* = .{ .file_read = .{ .handle = o.file.handle, .flags = @intFromBool(o.file.flags.nonblocking), .data_ptr = o.data.ptr, .data_len = o.data.len } },
        .file_write_streaming => |o| d.* = .{ .file_write = .{ .handle = o.file.handle, .flags = @intFromBool(o.file.flags.nonblocking), .header_ptr = o.header.ptr, .header_len = o.header.len, .data_ptr = o.data.ptr, .data_len = o.data.len, .splat = o.splat } },
        .net_receive => |o| d.* = .{ .net_receive = .{ .handle = o.socket_handle, .flags = @as(u8, @bitCast(o.flags)), .messages_ptr = o.message_buffer.ptr, .messages_len = o.message_buffer.len, .data_ptr = o.data_buffer.ptr, .data_len = o.data_buffer.len } },
        .net_send => |o| d.* = .{ .net_send = .{ .handle = o.socket_handle, .flags = @as(u8, @bitCast(o.flags)), .messages_ptr = o.messages.ptr, .messages_len = o.messages.len } },
        .net_read => |o| d.* = .{ .net_read = .{ .handle = o.socket_handle, .pad = 0, .data_ptr = o.data.ptr, .data_len = o.data.len, .control_ptr = o.control.ptr, .control_len = o.control.len } },
        .net_write => |o| d.* = .{ .net_write = .{ .handle = o.socket_handle, .splat = @intCast(@min(o.splat, std.math.maxInt(u32))), .header_ptr = o.header.ptr, .header_len = o.header.len, .data_ptr = o.data.ptr, .data_len = o.data.len, .control_ptr = o.control.ptr, .control_len = o.control.len } },
        .device_io_control => unreachable, // unreachable: device control waits in a batch only on Windows
    }
}

/// The operation `pack` kept.
pub fn unpack(p: *const Pending) Io.Operation {
    const d = packedOfConst(p);
    if (is_windows) return unpackWindows(p.tag, d);
    return switch (p.tag) {
        .file_read_streaming => .{ .file_read_streaming = .{ .file = .{ .handle = d.file_read.handle, .flags = .{ .nonblocking = d.file_read.flags != 0 } }, .data = d.file_read.data_ptr[0..d.file_read.data_len] } },
        .file_write_streaming => .{ .file_write_streaming = .{ .file = .{ .handle = d.file_write.handle, .flags = .{ .nonblocking = d.file_write.flags != 0 } }, .header = d.file_write.header_ptr[0..d.file_write.header_len], .data = d.file_write.data_ptr[0..d.file_write.data_len], .splat = d.file_write.splat } },
        .net_receive => .{ .net_receive = .{ .socket_handle = d.net_receive.handle, .flags = @bitCast(@as(u8, @intCast(d.net_receive.flags))), .message_buffer = d.net_receive.messages_ptr[0..d.net_receive.messages_len], .data_buffer = d.net_receive.data_ptr[0..d.net_receive.data_len] } },
        .net_send => .{ .net_send = .{ .socket_handle = d.net_send.handle, .flags = @bitCast(@as(u8, @intCast(d.net_send.flags))), .messages = d.net_send.messages_ptr[0..d.net_send.messages_len] } },
        .net_read => .{ .net_read = .{ .socket_handle = d.net_read.handle, .data = d.net_read.data_ptr[0..d.net_read.data_len], .control = d.net_read.control_ptr[0..d.net_read.control_len] } },
        .net_write => .{ .net_write = .{ .socket_handle = d.net_write.handle, .splat = d.net_write.splat, .header = d.net_write.header_ptr[0..d.net_write.header_len], .data = d.net_write.data_ptr[0..d.net_write.data_len], .control = d.net_write.control_ptr[0..d.net_write.control_len] } },
        .device_io_control => unreachable, // unreachable: device control waits in a batch only on Windows
    };
}

fn short(n: usize) u32 {
    return @intCast(@min(n, std.math.maxInt(u32)));
}

fn packWindows(d: *Packed, operation: Io.Operation) void {
    switch (operation) {
        .file_read_streaming => |o| d.* = .{ .file_read = .{ .handle = o.file.handle, .flags = @intFromBool(o.file.flags.nonblocking), .data_len = short(o.data.len), .data_ptr = o.data.ptr } },
        .file_write_streaming => |o| d.* = .{ .file_write = .{ .handle = o.file.handle, .flags = @intFromBool(o.file.flags.nonblocking), .splat = short(o.splat), .header_ptr = o.header.ptr, .header_len = o.header.len, .data_ptr = o.data.ptr, .data_len = o.data.len } },
        .net_receive => |o| d.* = .{ .net_receive = .{ .handle = o.socket_handle, .flags = @as(u8, @bitCast(o.flags)), .messages_len = short(o.message_buffer.len), .messages_ptr = o.message_buffer.ptr, .data_ptr = o.data_buffer.ptr, .data_len = o.data_buffer.len } },
        .net_send => |o| d.* = .{ .net_send = .{ .handle = o.socket_handle, .flags = @as(u8, @bitCast(o.flags)), .messages_len = short(o.messages.len), .messages_ptr = o.messages.ptr } },
        .net_read => |o| d.* = .{ .net_read = .{ .handle = o.socket_handle, .data_len = short(o.data.len), .control_len = short(o.control.len), .data_ptr = o.data.ptr, .control_ptr = o.control.ptr } },
        .net_write => |o| d.* = .{ .net_write = .{ .handle = o.socket_handle, .splat = short(o.splat), .header_len = short(o.header.len), .header_ptr = o.header.ptr, .data_ptr = o.data.ptr, .data_len = short(o.data.len), .control_len = short(o.control.len), .control_ptr = o.control.ptr } },
        .device_io_control => |o| d.* = .{ .device_io_control = .{ .handle = o.file.handle, .flags = @intFromBool(o.file.flags.nonblocking), .code = @bitCast(o.code), .in_ptr = o.in.ptr, .in_len = o.in.len, .out_ptr = o.out.ptr, .out_len = o.out.len } },
    }
}

fn unpackWindows(tag: Io.Operation.Tag, d: *const Packed) Io.Operation {
    return switch (tag) {
        .file_read_streaming => .{ .file_read_streaming = .{ .file = .{ .handle = d.file_read.handle, .flags = .{ .nonblocking = d.file_read.flags != 0 } }, .data = d.file_read.data_ptr[0..d.file_read.data_len] } },
        .file_write_streaming => .{ .file_write_streaming = .{ .file = .{ .handle = d.file_write.handle, .flags = .{ .nonblocking = d.file_write.flags != 0 } }, .header = d.file_write.header_ptr[0..d.file_write.header_len], .data = d.file_write.data_ptr[0..d.file_write.data_len], .splat = d.file_write.splat } },
        .net_receive => .{ .net_receive = .{ .socket_handle = d.net_receive.handle, .flags = @bitCast(@as(u8, @intCast(d.net_receive.flags))), .message_buffer = d.net_receive.messages_ptr[0..d.net_receive.messages_len], .data_buffer = d.net_receive.data_ptr[0..d.net_receive.data_len] } },
        .net_send => .{ .net_send = .{ .socket_handle = d.net_send.handle, .flags = @bitCast(@as(u8, @intCast(d.net_send.flags))), .messages = d.net_send.messages_ptr[0..d.net_send.messages_len] } },
        .net_read => .{ .net_read = .{ .socket_handle = d.net_read.handle, .data = d.net_read.data_ptr[0..d.net_read.data_len], .control = d.net_read.control_ptr[0..d.net_read.control_len] } },
        .net_write => .{ .net_write = .{ .socket_handle = d.net_write.handle, .splat = d.net_write.splat, .header = d.net_write.header_ptr[0..d.net_write.header_len], .data = d.net_write.data_ptr[0..d.net_write.data_len], .control = d.net_write.control_ptr[0..d.net_write.control_len] } },
        .device_io_control => .{ .device_io_control = .{ .file = .{ .handle = d.device_io_control.handle, .flags = .{ .nonblocking = d.device_io_control.flags != 0 } }, .code = @bitCast(d.device_io_control.code), .in = d.device_io_control.in_ptr[0..d.device_io_control.in_len], .out = d.device_io_control.out_ptr[0..d.device_io_control.out_len] } },
    };
}

/// Windows: the word after the packed operation, the backend's own (its
/// record of the call while the kernel holds it).
pub fn backendWord(p: *Pending) *usize {
    comptime assert(is_windows);
    return &p.userdata[p.userdata.len - 1];
}
