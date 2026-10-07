const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("reactor", .{ .root_source_file = b.path("src/reactor.zig"), .target = target, .optimize = optimize });
    const library = b.addLibrary(.{ .name = "reactor", .root_module = module });
    b.installArtifact(library);
    // Everything below is this repository's own: a project depending on
    // reactor builds the module and nothing else, and fetches nothing for it.
    if (b.pkg_hash.len != 0) return;

    const filters = if (b.option([]const u8, "test-filter", "Select tests by name")) |filter| &.{filter} else &.{};
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
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
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "reactor", .module = module }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);

    // The test doubles and the conformance suite are shakedown's, a lazy
    // dependency only the tests import. Its error is returned last, so one
    // configure pass asks for it and for preflight together.
    var needed: error{LazyDependencyNeeded}!void = {};
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        test_module.addImport("shakedown", shakedown.module("shakedown"));
    } else |err| needed = err;
    // CI wiring. preflight is lazy and only the root build asks for it.
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{
            .tests = test_step,
            .portable_tests = true,
            .bench = .{
                .programs = &.{.{ .name = "bench", .source = "bench/main.zig" }},
                .imports = benchImports,
                .target = target,
                .optimize = optimize,
            },
        });
        // A project that depends on reactor by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "reactor", .program = b.path("ci/consumer.zig") });
    }
    return needed;
}

/// reactor again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would
/// time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const reactor = b.createModule(.{ .root_source_file = b.path("src/reactor.zig"), .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "reactor", .module = reactor }}) catch @panic("OOM");
}
