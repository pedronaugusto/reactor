//! Persistent multishot receive storage, owned by a Receiver rather than a task.
const Receive = @This();
const std = @import("std");
const linux = std.os.linux;
const BufferRing = @import("../../sys/BufferRing.zig");

socket: linux.fd_t,
group: BufferRing.Id,
/// Given each completion; its owner finds itself from the record, which
/// it holds (`@fieldParentPtr`).
complete: *const fn (*Receive, linux.io_uring_cqe) void,
active: bool = false,
ending: bool = false,
/// Its `user_data` while armed: the key of its entry in the ring's table.
key: u64 = 0,

/// Called only by the thread owning the ring. `SystemResources` when the
/// ring's table has no room for it.
pub fn arm(r: *Receive, u: anytype) error{SystemResources}!void {
    std.debug.assert(!r.active);
    r.key = u.register(.receiver, .{ .receiver = r }) orelse return error.SystemResources;
    const sqe = u.entry();
    sqe.prep_recv(r.socket, &.{}, 0);
    sqe.flags |= linux.IOSQE_BUFFER_SELECT;
    sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
    sqe.buf_index = r.group.raw(); // c-os-boundary: the submission entry names the group
    sqe.user_data = r.key;
    r.active = true;
    u.active += 1;
    r.ending = false;
}

/// The terminal receive completion still follows.
pub fn cancel(r: *Receive, u: anytype) void {
    if (!r.active or r.ending) return;
    r.ending = true;
    const sqe = u.entry();
    sqe.prep_cancel(r.key, 0);
    sqe.user_data = @TypeOf(u.*).Key.ignored;
}

pub fn deliver(r: *Receive, cqe: linux.io_uring_cqe) void {
    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) r.active = false;
    r.complete(r, cqe);
}
