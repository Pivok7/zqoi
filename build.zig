const std = @import("std");

pub fn build(b: *std.Build) void {

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("zqoi", .{
        .root_source_file = b.path("src/zqoi.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Test step
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
