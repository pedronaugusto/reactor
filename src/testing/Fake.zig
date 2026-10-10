//! A backend that touches no kernel: what reactor's tests run the loop and
//! the runtime on.
//!
//! - **Seeded** (`Driver`): every operation completes at a later poll the
//!   seed picks, its result made by the test's script; a cancel lands or
//!   loses to the completion as the seed says; time is virtual and moves
//!   only when every task waits, straight to the next deadline.
//! - **Idle**: operations never complete on their own (they end when
//!   cancelled), time is the system's, and a poll waits on a futex that
//!   `wake` sets: real threads, real time, no kernel queue. The
//!   scheduler's multi-threaded tests run on it on every system.
const Fake = @This();

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const backend = @import("../backend.zig");
const pending = backend.pending;
const Loop = @import("../Loop.zig");
const Source = @import("shakedown").Source;
const clock = @import("../clock.zig");

pub const Mode = union(enum) {
    seeded: struct { seed: u64, virtual: *clock.Virtual },
    idle,
};

/// Makes the result of an operation the seed decided to complete; null
/// leaves it in flight. The default completes reads with nothing and
/// writes in full.
pub const Script = *const fn (context: ?*anyopaque, o: *Loop.Op, random: *Source) ?Loop.Op.Result;

gpa: Allocator,
mode: Mode,
source: Source,
/// Shared with check so scheduling and script choices shrink together.
shared_source: ?*Source = null,
script: Script = defaultScript,
script_context: ?*anyopaque = null,
ops: std.ArrayList(*Loop.Op) = .empty,
batch: std.ArrayList(Entry) = .empty,
woken: std.atomic.Value(u32) = .init(0),
/// One-based failing submission, shared by ordinary and batch operations.
/// Null is clean; each site can be swept independently without a kernel.
fail_submit_at: ?usize = null,
submissions: usize = 0,
/// Polls that delivered nothing and waited.
waits: u64 = 0,

const Entry = struct { token: pending.Token, operation: Io.Operation, canceled: bool = false };

pub fn init(gpa: Allocator, mode: Mode) Fake {
    const seed = switch (mode) {
        .seeded => |s| s.seed,
        .idle => 0,
    };
    return .{ .gpa = gpa, .mode = mode, .source = Source.init(gpa, .{ .prng = seed }) catch unreachable }; // unreachable: a non-recording source allocates nothing
}

pub fn deinit(f: *Fake) void {
    f.source.deinit();
    f.ops.deinit(f.gpa);
    f.batch.deinit(f.gpa);
    f.* = undefined;
}

pub fn custom(f: *Fake) backend.Custom {
    return .{ .context = f, .vtable = &.{
        .submit = submit,
        .cancel = cancel,
        .submitPending = submitPending,
        .cancelPending = cancelPending,
        .poll = poll,
        .wake = wake,
    } };
}

fn of(context: *anyopaque) *Fake {
    return @ptrCast(@alignCast(context)); // safe: the context is the fake, as `custom` made it
}

fn opOf(o: *anyopaque) *Loop.Op {
    return @ptrCast(@alignCast(o)); // safe: the loop hands a custom backend its own `Op`s
}

fn submit(context: *anyopaque, o: *anyopaque) error{ SystemResources, Unexpected }!void {
    const f = of(context);
    try f.submitting();
    f.ops.append(f.gpa, opOf(o)) catch @panic("reactor's fake: out of memory");
}

fn cancel(context: *anyopaque, o: *anyopaque) void {
    _ = context;
    _ = o; // `Loop.cancel` marked it; the next poll decides.
}

fn submitPending(context: *anyopaque, token: pending.Token, operation: Io.Operation) error{ SystemResources, Unexpected }!void {
    const f = of(context);
    try f.submitting();
    f.batch.append(f.gpa, .{ .token = token, .operation = operation }) catch @panic("reactor's fake: out of memory");
}

fn cancelPending(context: *anyopaque, token: pending.Token) void {
    const f = of(context);
    for (f.batch.items) |*e| if (e.token == token) {
        e.canceled = true;
    };
}

fn wake(context: *anyopaque) void {
    const f = of(context);
    f.woken.store(1, .release);
    Io.Threaded.global_single_threaded.io().futexWake(u32, &f.woken.raw, 1);
}

fn poll(context: *anyopaque, wait: backend.Wait, sink: backend.Custom.Sink) void {
    const f = of(context);
    switch (f.mode) {
        .seeded => |s| f.pollSeeded(wait, sink, s.virtual),
        .idle => f.pollIdle(wait, sink),
    }
}

/// Completes a seeded share of what is in flight, in a seeded order; when
/// it completes nothing and may wait, moves virtual time to the deadline.
fn pollSeeded(f: *Fake, wait: backend.Wait, sink: backend.Custom.Sink, virtual: *clock.Virtual) void {
    const random = f.shared_source orelse &f.source;
    var delivered: usize = 0;
    var i: usize = 0;
    while (i < f.ops.items.len) {
        const o = f.ops.items[i];
        const decide = random.below(3);
        if (o.state.canceled and decide != 3) {
            _ = f.ops.swapRemove(i);
            o.result = canceledResult(o);
            sink.complete(sink.context, o);
            delivered += 1;
            continue;
        }
        if (decide == 0 or decide == 1) if (f.script(f.script_context, o, random)) |result| {
            _ = f.ops.swapRemove(i);
            o.result = result;
            sink.complete(sink.context, o);
            delivered += 1;
            continue;
        };
        i += 1;
    }
    delivered += f.pollBatch(sink, random);
    if (delivered > 0) return;
    switch (wait) {
        .nowait => {},
        .up_to => |span| {
            f.waits += 1;
            virtual.advance(span.toIoDuration());
        },
        .forever => if (f.woken.swap(0, .acq_rel) == 0 and f.ops.items.len == 0 and f.batch.items.len == 0)
            @panic("reactor's fake: every task waits and nothing can wake one"),
    }
}

fn pollBatch(f: *Fake, sink: backend.Custom.Sink, random: *Source) usize {
    var delivered: usize = 0;
    var i: usize = 0;
    while (i < f.batch.items.len) {
        const e = f.batch.items[i];
        if (e.canceled and random.below(1) == 0) {
            _ = f.batch.swapRemove(i);
            sink.completePending(sink.context, e.token, .canceled);
            delivered += 1;
            continue;
        }
        if (random.below(2) == 0) {
            var o: Loop.Op = .{ .kind = .{ .io = e.operation } };
            if (f.script(f.script_context, &o, random)) |result| {
                _ = f.batch.swapRemove(i);
                const r = result.io catch unreachable; // unreachable: a script completes an operation, it never cancels it
                sink.completePending(sink.context, e.token, .{ .result = r });
                delivered += 1;
                continue;
            }
        }
        i += 1;
    }
    return delivered;
}

/// Delivers cancelled operations; otherwise waits for a wake or the time.
fn pollIdle(f: *Fake, wait: backend.Wait, sink: backend.Custom.Sink) void {
    var delivered: usize = 0;
    var i: usize = 0;
    while (i < f.ops.items.len) {
        const o = f.ops.items[i];
        if (o.state.canceled) {
            _ = f.ops.swapRemove(i);
            o.result = canceledResult(o);
            sink.complete(sink.context, o);
            delivered += 1;
            continue;
        }
        i += 1;
    }
    i = 0;
    while (i < f.batch.items.len) {
        const e = f.batch.items[i];
        if (e.canceled) {
            _ = f.batch.swapRemove(i);
            sink.completePending(sink.context, e.token, .canceled);
            delivered += 1;
            continue;
        }
        i += 1;
    }
    if (delivered > 0) return;
    const sys = Io.Threaded.global_single_threaded.io();
    switch (wait) {
        .nowait => {},
        .up_to => |span| sys.futexWaitTimeout(u32, &f.woken.raw, 0, .{ .duration = .{ .raw = span.toIoDuration(), .clock = .awake } }) catch unreachable, // unreachable: a scheduler's thread is no `Threaded` task, so nothing cancels it
        .forever => sys.futexWaitUncancelable(u32, &f.woken.raw, 0),
    }
    f.woken.store(0, .release);
}

fn canceledResult(o: *const Loop.Op) Loop.Op.Result {
    return switch (o.kind) {
        .io => .{ .io = error.Canceled },
        .accept => .{ .accept = error.Canceled },
        .connect => .{ .connect = error.Canceled },
        .read_at => .{ .read_at = error.Canceled },
        .write_at => .{ .write_at = error.Canceled },
        .sync => .{ .sync = error.Canceled },
        .close => .{ .close = {} },
        .abort => .{ .abort = 0 },
        .timer => .{ .timer = error.Canceled },
        .wait => .{ .wait = error.Canceled },
        .raw => .{ .raw = error.Canceled },
    };
}

/// Reads complete with nothing (end of stream), writes in full, the rest
/// with success.
pub fn defaultScript(context: ?*anyopaque, o: *Loop.Op, random: *Source) ?Loop.Op.Result {
    _ = context;
    _ = random;
    return switch (o.kind) {
        .io => |operation| .{
            .io = switch (operation) {
                .file_read_streaming => .{ .file_read_streaming = error.EndOfStream },
                .file_write_streaming => |w| .{ .file_write_streaming = w.header.len + total(w.data, w.splat) },
                .net_read => .{ .net_read = .{ .data_len = 0 } },
                .net_write => |w| .{ .net_write = w.header.len + total(w.data, w.splat) },
                .net_receive => .{ .net_receive = .{ null, 0 } },
                .net_send => |s| .{ .net_send = .{ null, s.messages.len } },
                .device_io_control => unreachable, // unreachable: runs borrowed, never here
            },
        },
        .accept => .{ .accept = error.SocketNotListening },
        .connect => .{ .connect = error.ConnectionRefused },
        .read_at => .{ .read_at = 0 },
        .write_at => |w| .{ .write_at = w.bytes.len },
        .sync => .{ .sync = {} },
        .close => .{ .close = {} },
        .abort => .{ .abort = 0 },
        .timer => .{ .timer = {} },
        .wait => .{ .wait = {} },
        .raw => .{ .raw = .{ .uring = 0 } },
    };
}

fn total(data: []const []const u8, splat: usize) usize {
    if (data.len == 0) return 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| n += d.len;
    return n + data[data.len - 1].len * splat;
}

fn submitting(f: *Fake) error{SystemResources}!void {
    f.submissions += 1;
    if (f.fail_submit_at == f.submissions) return error.SystemResources;
}
