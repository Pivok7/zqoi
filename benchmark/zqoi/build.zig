const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = exe_mod,
    });

    const zstdbi_dep = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zstbi", zstdbi_dep.module("root"));

    const zqoi_dep = b.dependency("zqoi", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zqoi", zqoi_dep.module("zqoi"));

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
