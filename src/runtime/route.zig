//! Slots that run std's own `Threaded` code: on a lane, per `files`, or
//! borrowed on the worker. Each generator makes a function with the slot's
//! exact signature from the slot's name.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const Core = @import("Core.zig");
const native_files = @import("files.zig");
const Lanes = @import("../Lanes.zig");
const lane_call = @import("../ops/lane_call.zig");

fn SlotFn(comptime name: []const u8) type {
    return @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
}

fn paramsOf(comptime name: []const u8) []const ?type {
    return @typeInfo(SlotFn(name)).@"fn".param_types;
}

fn Return(comptime name: []const u8) type {
    return @typeInfo(SlotFn(name)).@"fn".return_type.?;
}

/// `name` on `lane`'s executor, the calling task parked meanwhile.
pub fn onLane(comptime lane: Lanes.Lane, comptime name: []const u8) *const SlotFn(name) {
    const Impl = struct {
        fn go(userdata: ?*anyopaque, rest: anytype) Return(name) {
            const r = Core.running(userdata);
            const io = r.lanes.executor(lane);
            return lane_call.call(&r.lanes, lane, @field(io.vtable, name), .{io.userdata} ++ rest);
        }
    };
    return generate(Impl, name);
}

/// Whether std's file calls may run on the calling task's stack. Not on
/// Windows: std makes each path an NT path in buffers of 32 Ki UTF-16 units,
/// and the frames it takes outgrow a task's stack (an open by path 1.3 MiB
/// in a Debug build, `wToPrefixedFileW` alone 1 MiB; a rename 512 KiB in
/// ReleaseSafe), so there they run on a lane's thread.
const files_on_task = builtin.os.tag != .windows;

/// A file call per `Options.files`: std's code on the worker inside a
/// blocking bracket, where the monitor can hand the worker's processor on
/// should it block (epoll, kqueue); on the `general` lane otherwise, and
/// always on Windows, where std's file calls need more stack than a task
/// has. For calls that never call back into their own `Io`.
pub fn files(comptime name: []const u8) *const SlotFn(name) {
    const Impl = struct {
        fn go(userdata: ?*anyopaque, rest: anytype) Return(name) {
            const r = Core.running(userdata);
            if (native_files.call(name, r, rest)) |result| return result;
            if (files_on_task and r.options.files == .auto) {
                const b = r.lanes.borrowedIo();
                if (lane_call.onWorker(@field(b.vtable, name), .{b.userdata} ++ rest)) |result| return result;
            }
            const io = r.lanes.executor(.general);
            return lane_call.call(&r.lanes, .general, @field(io.vtable, name), .{io.userdata} ++ rest);
        }
    };
    return generate(Impl, name);
}

/// `slot`, a call that opens a file, with the file it opened recorded as
/// the runtime's (`Core.kept`): its rings may hold it as a fixed file until
/// `fileClose` forgets it.
pub fn opening(comptime name: []const u8, comptime slot: *const SlotFn(name)) *const SlotFn(name) {
    const Impl = struct {
        fn go(userdata: ?*anyopaque, rest: anytype) Return(name) {
            const opened = try @call(.auto, slot, .{userdata} ++ rest);
            if (comptime builtin.os.tag == .linux) Core.running(userdata).kept.record(fileOf(opened).handle);
            return opened;
        }
        fn fileOf(opened: anytype) Io.File {
            return if (@TypeOf(opened) == Io.File) opened else opened.file;
        }
    };
    return generate(Impl, name);
}

/// `name`'s std code on the calling worker: for calls that never block
/// and never call back into their own `Io`.
pub fn borrowed(comptime name: []const u8) *const SlotFn(name) {
    const Impl = struct {
        fn go(userdata: ?*anyopaque, rest: anytype) Return(name) {
            const r = Core.running(userdata);
            const io = r.lanes.borrowedIo();
            return lane_call.borrow(@field(io.vtable, name), .{io.userdata} ++ rest);
        }
    };
    return generate(Impl, name);
}

/// A function with the slot's signature that passes its arguments, after
/// `userdata`, to `Impl.go` as a tuple.
fn generate(comptime Impl: type, comptime name: []const u8) *const SlotFn(name) {
    const params = comptime paramsOf(name);
    const R = Return(name);
    return switch (comptime params.len) {
        1 => &struct {
            fn f(u: ?*anyopaque) R {
                return Impl.go(u, .{});
            }
        }.f,
        2 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?) R {
                return Impl.go(u, .{a});
            }
        }.f,
        3 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?) R {
                return Impl.go(u, .{ a, b });
            }
        }.f,
        4 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?, c: params[3].?) R {
                return Impl.go(u, .{ a, b, c });
            }
        }.f,
        5 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?, c: params[3].?, d: params[4].?) R {
                return Impl.go(u, .{ a, b, c, d });
            }
        }.f,
        6 => &struct {
            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?, c: params[3].?, d: params[4].?, e: params[5].?) R {
                return Impl.go(u, .{ a, b, c, d, e });
            }
        }.f,
        else => @compileError("a slot with more arguments than expected: " ++ name),
    };
}
