const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const inotify_root = b.addModule("inotify", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = inotify_root,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    run_lib_unit_tests.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const check_dummy_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "inotify-zig",
        .root_module = inotify_root,
    });

    const check = b.step("check", "Check step for usage with zls");
    check.dependOn(&check_dummy_lib.step);
}
