const std = @import("std");

/// What a project that depends on reactor builds: the `reactor` module and its
/// library. The tests, example, benchmarks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const module = b.addModule("reactor", .{ .root_source_file = b.path("src/reactor.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "aegis", .module = aegis }} });
    b.installArtifact(b.addLibrary(.{ .name = "reactor", .root_module = module }));
}

/// reactor's development: its tests, example and benchmarks under preflight's
/// gate, with shakedown bound to reactor's aegis. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const sanitize_thread = b.option(bool, "sanitize-thread", "Run focused native race tests with thread sanitizer") orelse false;
    const package = b.dependency("reactor", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("reactor");
    const library = package.artifact("reactor");
    const aegis_dependency = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const aegis = aegis_dependency.module("aegis");

    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const test_module = b.createModule(.{
        .root_source_file = p.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "aegis", .module = aegis }},
    });
    if (target.result.os.tag == .windows) {
        test_module.link_libc = true;
        test_module.addCSourceFile(.{ .file = p.path("src/testing/seh.c"), .flags = &.{"-fms-extensions"} });
    }
    test_module.sanitize_thread = sanitize_thread;
    // std's own Threaded.zig, read by the test that checks which slots may
    // run std's code on a worker.
    const threaded_source = b.addWriteFiles().addCopyFile(std.Build.LazyPath.zig_lib.path(b, "std/Io/Threaded.zig"), "Threaded.zig.txt");
    test_module.addAnonymousImport("threaded.source", .{ .root_source_file = threaded_source });
    const tests = b.addTest(.{ .name = "reactor-tests", .filters = filters, .root_module = test_module });
    const test_step = b.step("test", "Run the tests and example");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    check.dependOn(&tests.step);
    check.dependOn(&library.step);
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "reactor", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);

    // The test doubles and the conformance suite are shakedown's, bound to
    // reactor's own aegis, so the tests link one.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    tools.shakedown.useAegis(shakedown, aegis);
    test_module.addImport("shakedown", shakedown.module("shakedown"));
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        .bench = .{
            .programs = &.{ .{ .name = "bench", .source = "bench/main.zig" }, .{ .name = "costs", .source = "bench/costs.zig", .timed = false }, .{ .name = "v11-prepare", .source = "bench/v11/prepare.zig", .timed = false } },
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on reactor by path, with no packages to
    // fetch: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "reactor", .program = p.path("ci/consumer.zig"), .packages = &.{aegis_dependency} });
}

/// reactor again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would
/// time the Debug module. `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("reactor", .{ .target = target, .optimize = optimize }).builder;
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const reactor = b.createModule(.{ .root_source_file = p.path("src/reactor.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "aegis", .module = aegis }} });
    // The same binding as `useAegis`, which only a `dev` has the tools for: one aegis is linked.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    shakedown.module("shakedown").addImport("aegis", aegis);
    return b.allocator.dupe(std.Build.Module.Import, &.{ .{ .name = "reactor", .module = reactor }, .{ .name = "shakedown", .module = shakedown.module("shakedown") } }) catch @panic("OOM");
}
