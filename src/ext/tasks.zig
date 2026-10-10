//! Spawn options std.Io cannot express. A foreign Io supports only defaults.
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const native = @import("native.zig");
const tasks = @import("../ops/tasks.zig");

pub const Priority = @import("../scheduler/Task.zig").Priority;
pub const Options = struct { stack_size: ?aegis.units.Bytes(usize) = null, priority: Priority = .normal };
pub const ConcurrentError = Io.ConcurrentError;

pub fn concurrentWith(io: Io, options: Options, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) ConcurrentError!Io.Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    if (options.stack_size == null and options.priority == .normal) return io.concurrent(function, args);
    const core = native.runtimeOf(io) orelse return error.ConcurrencyUnavailable;
    const result_type = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Args = @TypeOf(args);
    const Entry = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const a: *const Args = @ptrCast(@alignCast(context)); // safe: the task copied Args with its alignment
            const r: *result_type = @ptrCast(@alignCast(result)); // safe: the task reserved Result with its alignment
            r.* = @call(.auto, function, a.*);
        }
    };
    const task = try tasks.concurrentWith(&core.scheduler, @sizeOf(result_type), .of(result_type), std.mem.asBytes(&args), .of(Args), Entry.start, @returnAddress(), options.stack_size, options.priority);
    return .{ .any_future = @ptrCast(task), .result = undefined }; // safe: reactor's await/cancel slots interpret the token as Task
}
