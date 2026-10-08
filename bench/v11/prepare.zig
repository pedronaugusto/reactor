//! Adapt an owned copy of an immutable published suite. Replacements operate
//! on Zig tokens, never strings/comments; only selection of the test Io changes.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--smoke")) return;
    if (args.len != 4) return error.ExpectedReactorSourceFixture;
    const reactor = args[1];
    const source = args[2];
    const fixture = args[3];
    const clone = try std.process.run(gpa, io, .{ .argv = &.{ "git", "clone", "--no-hardlinks", source, fixture } });
    if (clone.term != .exited or clone.term.exited != 0) return error.CloneFailed;
    var dir = try Io.Dir.cwd().openDir(io, fixture, .{ .iterate = true });
    defer dir.close(io);
    var sources = try dir.openDir(io, "src", .{ .iterate = true });
    defer sources.close(io);
    var walker = try sources.walk(gpa);
    defer walker.deinit();
    var sites: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const bytes = try sources.readFileAlloc(io, entry.path, gpa, .limited(8 << 20));
        const adapted = try replaceIo(gpa, bytes, &sites);
        try sources.writeFile(io, .{ .sub_path = entry.path, .data = adapted });
    }
    const build = try dir.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20));
    const call = "    v11(b, tests, target, optimize);\n";
    const at = if (std.mem.indexOf(u8, build, "    return needed;")) |pos| pos else try buildEnd(gpa, build);
    const helper = try std.fmt.allocPrint(gpa,
        \\fn v11(b: *std.Build, tests: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {{
        \\    const reactor = b.createModule(.{{ .root_source_file = .{{ .cwd_relative = "{s}/src/reactor.zig" }}, .target = target, .optimize = optimize }});
        \\    const state = b.createModule(.{{ .root_source_file = .{{ .cwd_relative = "{s}/bench/v11/state.zig" }}, .target = target, .optimize = optimize, .imports = &.{{.{{ .name = "reactor", .module = reactor }}}} }});
        \\    var seen: std.AutoHashMap(*std.Build.Module, void) = .init(b.allocator);
        \\    v11Imports(tests.root_module, state, &seen);
        \\    tests.test_runner = .{{ .path = .{{ .cwd_relative = "{s}/bench/v11/runner.zig" }}, .mode = .simple }};
        \\    const run = b.addRunArtifact(tests);
        \\    run.setCwd(b.path("."));
        \\    b.step("v11", "Measure the actual suite on reactor task stacks").dependOn(&run.step);
        \\}}
        \\fn v11Imports(module: *std.Build.Module, state: *std.Build.Module, seen: *std.AutoHashMap(*std.Build.Module, void)) void {{
        \\    const found = seen.getOrPut(module) catch @panic("OOM");
        \\    if (found.found_existing) return;
        \\    var children = module.import_table.iterator();
        \\    while (children.next()) |child| v11Imports(child.value_ptr.*, state, seen);
        \\    module.addImport("v11", state);
        \\}}
        \\
    , .{ reactor, reactor, reactor });
    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = try std.mem.concat(gpa, u8, &.{ build[0..at], call, build[at..], "\n", helper }) });
    var buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writer(io, &buffer);
    try output.interface.print("V11 adapted {d} test Io selections in {s}; original {s} untouched\n", .{ sites, fixture, source });
    try output.interface.flush();
}

fn replaceIo(gpa: std.mem.Allocator, bytes: []const u8, sites: *usize) ![]const u8 {
    const input = try gpa.dupeSentinel(u8, bytes, 0);
    var tokenizer: std.zig.Tokenizer = .init(input);
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(gpa, token);
    }
    var output: std.ArrayList(u8) = .empty;
    var copied: usize = 0;
    for (tokens.items, 0..) |token, i| {
        if (i < 2 or token.tag != .identifier or !std.mem.eql(u8, input[token.loc.start..token.loc.end], "io")) continue;
        const before = tokens.items[i - 2];
        if (before.tag != .identifier or tokens.items[i - 1].tag != .period or !std.mem.eql(u8, input[before.loc.start..before.loc.end], "testing")) continue;
        var start = before.loc.start;
        if (i >= 4 and tokens.items[i - 3].tag == .period and std.mem.eql(u8, input[tokens.items[i - 4].loc.start..tokens.items[i - 4].loc.end], "std")) start = tokens.items[i - 4].loc.start;
        try output.appendSlice(gpa, input[copied..start]);
        try output.appendSlice(gpa, "@import(\"v11\").io");
        copied = token.loc.end;
        sites.* += 1;
    }
    try output.appendSlice(gpa, input[copied..bytes.len]);
    return output.items;
}

fn buildEnd(gpa: std.mem.Allocator, build: []const u8) !usize {
    const start = std.mem.indexOf(u8, build, "pub fn build(") orelse return error.NoBuild;
    var tokenizer: std.zig.Tokenizer = .init(try gpa.dupeSentinel(u8, build[start..], 0));
    var depth: usize = 0;
    var entered = false;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return error.NoBuildEnd;
        if (token.tag == .l_brace) {
            depth += 1;
            entered = true;
        }
        if (token.tag == .r_brace) {
            depth -= 1;
            if (entered and depth == 0) return start + token.loc.start;
        }
    }
}
