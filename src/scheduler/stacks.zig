//! The runtime's task stacks: shuttle's pool, in the classes the options
//! ask for. The default class serves the tasks that ask no size and is kept
//! for them; an explicit size takes the smallest class that fits and has a
//! stack free. Diagnostic painting measures how deep a task's stack went.
const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const shuttle = @import("shuttle");

pub const Bytes = aegis.units.Bytes(usize);

/// A stack's number among the runtime's, which the tables kept beside the
/// pool (records, trims) are indexed by.
pub const Number = aegis.id.Id(struct {}, u32);

pub const Class = struct { size: Bytes, count: u32 };
pub const Options = struct { count: u32, size: Bytes, classes: []const Class = &.{} };
pub const InitError = error{ OutOfMemory, SystemResources, TooManyTasks };

/// The pool: `options.count` stacks in all, the explicit classes' counts
/// taken from the default class's. Classes of one size, the default's
/// included, are one class.
pub fn init(gpa: std.mem.Allocator, options: Options) InitError!shuttle.Pool {
    var extra: u64 = 0;
    for (options.classes) |class| extra += class.count;
    if (extra > options.count) return error.TooManyTasks;
    const classes = try gpa.alloc(shuttle.Pool.Class, options.classes.len + 1);
    defer gpa.free(classes);
    var n: usize = 0;
    add(classes, &n, .{ .size = pageRounded(options.size) orelse return error.SystemResources, .count = options.count - @as(u32, @intCast(extra)) }); // safe: not above `options.count`, checked above
    for (options.classes) |class| add(classes, &n, .{ .size = pageRounded(class.size) orelse return error.SystemResources, .count = class.count });
    return shuttle.Pool.init(gpa, .{ .classes = classes[0..n] }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyStacks => error.TooManyTasks,
        error.SystemResources, error.Overflow, error.InvalidClasses => error.SystemResources,
    };
}

/// `size` in whole pages, at least four; null past the address space.
fn pageRounded(size: Bytes) ?Bytes {
    const page = std.heap.pageSize();
    const up = aegis.int.Checked(usize).init(@max(size.raw(), 4 * page)).add(page - 1) catch return null;
    return .fromRaw(std.mem.alignBackward(usize, up.raw(), page));
}

fn add(classes: []shuttle.Pool.Class, n: *usize, class: shuttle.Pool.Class) void {
    for (classes[0..n.*]) |*c| if (c.size.eql(class.size)) {
        c.count += class.count;
        return;
    };
    classes[n.*] = class;
    n.* += 1;
}

/// A stack of the default class for a task that asks no size, or of the
/// smallest class that fits and has one free. Null when none is free, or
/// when the system refused to make a stack never handed out usable (its
/// memory or its guard, mid-run): either way the spawn is refused, as std's
/// `ConcurrencyUnavailable` names resource exhaustion, and the stack is
/// tried again by a later spawn.
pub inline fn take(pool: *shuttle.Pool, default: Bytes, size: ?Bytes) ?shuttle.Stack {
    const taken = if (size) |s| pool.take(s) else pool.takeExactly(default);
    return taken catch |err| switch (err) {
        error.SystemResources => null,
    };
}

const paint_byte = 0xa5;

/// The lowest byte a thread other than the stack's own can make usable:
/// on Windows the page below what is committed is the stack's guard page.
fn lowest(stack: shuttle.Stack) usize {
    return stack.bottom + if (builtin.os.tag == .windows) std.heap.pageSize() else @as(usize, 0);
}

/// Diagnostic painting: the stack below `until` filled with a pattern,
/// committed first. Opt-in and off in ordinary runs; no live frame is ever
/// painted. False when the stack cannot commit that far down.
pub fn paint(stack: *shuttle.Stack, until: usize) bool {
    const low = lowest(stack.*);
    stack.reach(low) catch return false;
    @memset(stack.usable()[low - stack.bottom .. until - stack.bottom], paint_byte);
    return true;
}

/// Called off-stack, before publishing a wake or an ended task: how deep
/// the stack's code reached, by the lowest byte no longer painted, work that
/// returned before the next park included.
pub fn highWater(stack: shuttle.Stack) usize {
    const low = lowest(stack);
    const bytes = stack.usable()[low - stack.bottom ..];
    for (bytes, 0..) |byte, at| if (byte != paint_byte) return bytes.len - at;
    return 0;
}
