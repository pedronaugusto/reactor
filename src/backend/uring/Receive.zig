//! Persistent multishot receive storage, owned by a Receiver rather than a task.
const Receive = @This();
const std = @import("std");
const linux = std.os.linux;
const BufferRing = @import("../../sys/BufferRing.zig");

socket: linux.fd_t,
group: BufferRing.Id,
context: *anyopaque,
complete: *const fn (*anyopaque, linux.io_uring_cqe) void,
active: bool = false,
ending: bool = false,

/// Called only by the thread owning the ring.
pub fn arm(r: *Receive, u: anytype) void {
    std.debug.assert(!r.active);
    const sqe = u.entry();
    sqe.prep_recv(r.socket, &.{}, 0);
    sqe.flags |= linux.IOSQE_BUFFER_SELECT;
    sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
    sqe.buf_index = r.group.raw(); // c-os-boundary: the submission entry names the group
    sqe.user_data = @intFromPtr(r) | 6; // safe: the receiver retains this record through the terminal completion
    r.active = true;
    u.active += 1;
    r.ending = false;
}

/// The terminal receive completion still follows.
pub fn cancel(r: *Receive, u: anytype) void {
    if (!r.active or r.ending) return;
    r.ending = true;
    const sqe = u.entry();
    sqe.prep_cancel(@intFromPtr(r) | 6, 0); // safe: the receive's own completion token
    sqe.user_data = 4; // ignored cancel acknowledgement
}

pub fn deliver(r: *Receive, cqe: linux.io_uring_cqe) void {
    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) r.active = false;
    r.complete(r.context, cqe);
}
