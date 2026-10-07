//! Slots that run std's own `Threaded` code: on a lane, per `files`, or borrowed on the
//! worker. Each generator makes a function with the slot's exact
//! signature from the slot's name.
const std = @import("std");
const Io = std.Io;

const Core = @import("Core.zig");
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
            const r = Core.of(userdata);
            const io = r.lanes.executor(lane);
            return lane_call.call(&r.scheduler, &r.lanes, lane, @field(io.vtable, name), .{io.userdata} ++ rest);
        }
    };
    return generate(Impl, name);
}

/// A file call per `Options.files`: std's code on the worker inside a
/// blocking bracket, where the monitor can hand the worker's processor on
/// should it block (epoll, kqueue); on the `general` lane otherwise. For
/// calls that never call back into their own `Io`.
pub fn files(comptime name: []const u8) *const SlotFn(name) {
    const Impl = struct {
        fn go(userdata: ?*anyopaque, rest: anytype) Return(name) {
            const r = Core.of(userdata);
            if (r.options.files == .auto) {
                const b = r.lanes.borrowedIo();
                if (lane_call.onWorker(@field(b.vtable, name), .{b.userdata} ++ rest)) |result| return result;
            }
            const io = r.lanes.executor(.general);
            return lane_call.call(&r.scheduler, &r.lanes, .general, @field(io.vtable, name), .{io.userdata} ++ rest);
        }
    };
    return generate(Impl, name);
}

/// `name`'s std code on the calling worker: for calls that never block
/// and never call back into their own `Io`.
pub fn borrowed(comptime name: []const u8) *const SlotFn(name) {
    const Impl = struct {
        fn go(userdata: ?*anyopaque, rest: anytype) Return(name) {
            const r = Core.of(userdata);
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
