//! What an io_uring operation keeps while the kernel holds it: the memory
//! the kernel reads a request from, or writes a result into, after the call.
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Threaded = std.Io.Threaded;

pub const Scratch = union {
    message: Message,
    address: Address,
    timespec: linux.kernel_timespec,
};

pub const Message = struct {
    header: linux.msghdr,
    iovecs: [Threaded.max_iovecs_len]posix.iovec,
    address: Threaded.PosixAddress,
    splat: [Threaded.splat_buffer_size]u8,
};

pub const Address = struct {
    storage: extern union { ip: Threaded.PosixAddress, unix: posix.sockaddr.un },
    len: posix.socklen_t,
};
