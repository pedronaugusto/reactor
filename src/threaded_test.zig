//! The slots the runtime runs as std's own code on its workers must never
//! call back into their own `Io` (`io(t)`): on a worker that would run
//! `Threaded`'s blocking futexes inside a task. Checked against the
//! `Threaded.zig` of the Zig that builds the tests: every function such a
//! slot can reach, by name, through the whole file.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Ast = std.zig.Ast;

const slots = @import("runtime/slots.zig");
const route = @import("runtime/route.zig");

const source: [:0]const u8 = @embedFile("threaded.source");

/// The slots the runtime runs as std's code on its workers. Moving a slot
/// between a lane and a worker is a decision: this list changes with it,
/// and the test below holds the vtable to it.
const borrowed = [_][]const u8{
    "dirClose",                    "fileSeekBy",           "fileSeekTo",            "fileIsTty",
    "fileEnableAnsiEscapeCodes",   "fileTryLock",          "fileUnlock",            "fileDowngradeLock",
    "fileSupportsAnsiEscapeCodes", "processSetCurrentDir", "processSetCurrentPath", "processReplace",
    "fileMemoryMapDestroy",        "processCurrentPath",   "progressParentFile",    "inheritParentDir",
    "inheritParentFile",           "randomSecure",         "netListenIp",           "netBindIp",
    "netListenUnix",               "netSocketCreatePair",  "netShutdown",           "netInterfaceNameResolve",
    "netInterfaceName",
};

/// Every function of `Threaded.zig` under its qualified name (`f`,
/// `Thread.f`, `Thread.Status.f`), and the calls in its body: `Q.f(` to a
/// container `Q` resolves into it, a bare `f(` to the caller's own
/// container or the file, a method call `x.f(` to every function named
/// `f` (the receiver's type is not tracked: this over-approximates).
const Graph = struct {
    tree: Ast,
    /// Qualified name -> its bodies' token ranges. A file-level constant
    /// that picks a function per system (`const x = switch (native_os)`)
    /// counts as a body naming each.
    bodies: std.StringHashMapUnmanaged(std.ArrayList([2]Ast.TokenIndex)) = .empty,
    arena: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator) !Graph {
        var g: Graph = .{ .tree = try Ast.parse(gpa, source, .{}), .arena = .init(gpa) };
        errdefer g.deinit(gpa);
        try g.collect(gpa, g.tree.rootDecls(), "");
        return g;
    }

    fn collect(g: *Graph, gpa: std.mem.Allocator, members: []const Ast.Node.Index, prefix: []const u8) !void {
        for (members) |member| {
            var buffer: [1]Ast.Node.Index = undefined;
            if (g.tree.nodeTag(member) == .fn_decl) {
                const proto = g.tree.fullFnProto(&buffer, member) orelse continue;
                const name = g.tree.tokenSlice(proto.name_token orelse continue);
                try g.add(gpa, prefix, name, member);
                continue;
            }
            const var_decl = g.tree.fullVarDecl(member) orelse continue;
            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            const name = g.tree.tokenSlice(var_decl.ast.mut_token + 1);
            switch (g.tree.nodeTag(init_node)) {
                .@"switch", .switch_comma => try g.add(gpa, prefix, name, init_node),
                else => {
                    var container: [2]Ast.Node.Index = undefined;
                    const decl = g.tree.fullContainerDecl(&container, init_node) orelse continue;
                    try g.collect(gpa, decl.ast.members, try g.arena.allocator().print("{s}{s}.", .{ prefix, name }));
                },
            }
        }
    }

    fn add(g: *Graph, gpa: std.mem.Allocator, prefix: []const u8, name: []const u8, node: Ast.Node.Index) !void {
        const key = try g.arena.allocator().print("{s}{s}", .{ prefix, name });
        const entry = try g.bodies.getOrPut(gpa, key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(gpa, .{ g.tree.firstToken(node), g.tree.lastToken(node) });
    }

    fn deinit(g: *Graph, gpa: std.mem.Allocator) void {
        var it = g.bodies.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        g.bodies.deinit(gpa);
        g.tree.deinit(gpa);
        g.arena.deinit();
        g.* = undefined;
    }

    /// The functions `Threaded.io` puts under slot `slot`.
    fn implementations(g: *const Graph, gpa: std.mem.Allocator, slot: []const u8) !std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        const range = (g.bodies.get("io") orelse return error.NoIoFunction).items[0];
        const tags = g.tree.tokens.items(.tag);
        var i = range[0];
        while (i < range[1]) : (i += 1) {
            if (tags[i] != .period or tags[i + 1] != .identifier or tags[i + 2] != .equal) continue;
            if (!std.mem.eql(u8, g.tree.tokenSlice(i + 1), slot)) continue;
            var depth: usize = 0;
            var j = i + 3;
            while (j < range[1]) : (j += 1) {
                switch (tags[j]) {
                    .l_brace, .l_paren => depth += 1,
                    .r_brace, .r_paren => if (depth == 0) break else {
                        depth -= 1;
                    },
                    .comma => if (depth == 0) break,
                    .identifier => if (g.bodies.getKey(g.tree.tokenSlice(j))) |key| try out.append(gpa, key),
                    else => {},
                }
            }
            return out;
        }
        return error.SlotNotFound;
    }

    /// The qualified names a call at token `i` in `caller`'s body may reach.
    fn resolve(g: *const Graph, gpa: std.mem.Allocator, caller: []const u8, i: Ast.TokenIndex, out: *std.ArrayList([]const u8)) !void {
        const tags = g.tree.tokens.items(.tag);
        const callee = g.tree.tokenSlice(i);
        if (i >= 2 and tags[i - 1] == .period and tags[i - 2] == .identifier) {
            const qualifier = g.tree.tokenSlice(i - 2);
            var any_container = false;
            var it = g.bodies.keyIterator();
            while (it.next()) |key| {
                const dot = std.mem.findScalarLast(u8, key.*, '.') orelse continue;
                const container = key.*[0..dot];
                const last_container = container[(std.mem.findScalarLast(u8, container, '.') orelse std.math.maxInt(usize)) +% 1 ..];
                if (!std.mem.eql(u8, key.*[dot + 1 ..], callee)) continue;
                if (std.mem.eql(u8, last_container, qualifier)) {
                    try out.append(gpa, key.*);
                    any_container = true;
                }
            }
            if (any_container) return;
            // A method call on a value: any function of that name.
            it = g.bodies.keyIterator();
            while (it.next()) |key| {
                const last = key.*[(std.mem.findScalarLast(u8, key.*, '.') orelse std.math.maxInt(usize)) +% 1 ..];
                if (std.mem.eql(u8, last, callee)) try out.append(gpa, key.*);
            }
            return;
        }
        if (tags[i - 1] == .period) return; // a call on an expression the walk does not follow
        // Bare: the caller's own container first, then the file.
        const own = caller[0..(std.mem.findScalarLast(u8, caller, '.') orelse 0)];
        if (own.len > 0) {
            const key = try gpa.print("{s}.{s}", .{ own, callee });
            defer gpa.free(key);
            if (g.bodies.getKey(key)) |k| return out.append(gpa, k);
        }
        if (g.bodies.getKey(callee)) |k| try out.append(gpa, k);
    }

    /// The first function reachable from `roots` that calls `io(...)`.
    fn reachesIo(g: *const Graph, gpa: std.mem.Allocator, roots: []const []const u8) !?[]const u8 {
        var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer seen.deinit(gpa);
        return g.search(gpa, roots, &seen);
    }

    fn search(g: *const Graph, gpa: std.mem.Allocator, roots: []const []const u8, seen: *std.StringHashMapUnmanaged([]const u8)) !?[]const u8 {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(gpa);
        var callees: std.ArrayList([]const u8) = .empty;
        defer callees.deinit(gpa);
        for (roots) |r| {
            try queue.append(gpa, r);
            try seen.put(gpa, r, "");
        }
        const tags = g.tree.tokens.items(.tag);
        while (queue.pop()) |name| {
            const ranges = g.bodies.get(name) orelse continue;
            for (ranges.items) |range| {
                var i = range[0];
                while (i < range[1]) : (i += 1) {
                    if (tags[i] != .identifier) continue;
                    const word = g.tree.tokenSlice(i);
                    callees.clearRetainingCapacity();
                    if (tags[i + 1] == .l_paren) {
                        if (tags[i - 1] != .period and (std.mem.eql(u8, word, "io") or std.mem.eql(u8, word, "ioBasic"))) return name;
                        if (tags[i - 1] == .period and tags[i - 2] == .identifier and std.mem.eql(u8, word, "io") and std.mem.eql(u8, g.tree.tokenSlice(i - 2), "t")) return name;
                        try g.resolve(gpa, name, i, &callees);
                    } else if (std.mem.endsWith(u8, word, "Posix") or std.mem.endsWith(u8, word, "Windows") or std.mem.endsWith(u8, word, "Wasi")) {
                        // A per-system alias names its functions without calling them.
                        if (g.bodies.getKey(word)) |k| try callees.append(gpa, k);
                    }
                    for (callees.items) |callee| {
                        if (seen.contains(callee)) continue;
                        try seen.put(gpa, callee, name);
                        try queue.append(gpa, callee);
                    }
                }
            }
        }
        return null;
    }
};

test "no slot the runtime borrows on a worker calls back into its own Io" {
    const gpa = testing.allocator;
    var g = try Graph.init(gpa);
    defer g.deinit(gpa);
    var bad: usize = 0;
    inline for (borrowed) |slot| {
        try testing.expect(@field(slots.vtable, slot) == route.borrowed(slot));
        var impls = try g.implementations(gpa, slot);
        defer impls.deinit(gpa);
        try testing.expect(impls.items.len > 0);
        var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer seen.deinit(gpa);
        if (try g.search(gpa, impls.items, &seen)) |culprit| {
            std.debug.print("{s}: reaches io(t):", .{slot});
            var at = culprit;
            while (at.len > 0) : (at = seen.get(at) orelse "") std.debug.print(" {s} <-", .{at});
            std.debug.print("\n", .{});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "the check finds the slots that do call back into their Io" {
    const gpa = testing.allocator;
    var g = try Graph.init(gpa);
    defer g.deinit(gpa);
    for ([_][]const u8{ "dirCreateDirPathOpen", "dirCreateFileAtomic", "netLookup", "lockStderr" }) |slot| {
        var impls = try g.implementations(gpa, slot);
        defer impls.deinit(gpa);
        try testing.expect(try g.reachesIo(gpa, impls.items) != null);
    }
}
