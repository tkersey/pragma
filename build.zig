const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ymlz_module = b.createModule(.{
        .root_source_file = b.path("deps/ymlz/src/root.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "pragma",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ymlz", .module = ymlz_module }},
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the pragma CLI");
    run_step.dependOn(&run_cmd.step);

    const scorecard_exe = b.addExecutable(.{
        .name = "pragma-scorecard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scorecard.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(scorecard_exe);

    const scorecard_cmd = b.addRunArtifact(scorecard_exe);
    if (b.args) |args| {
        scorecard_cmd.addArgs(args);
    }

    const scorecard_step = b.step("scorecard", "Generate a rubric scorecard from a JSONL log");
    scorecard_step.dependOn(&scorecard_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ymlz", .module = ymlz_module }},
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const scorecard_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scorecard.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_scorecard_tests = b.addRunArtifact(scorecard_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_scorecard_tests.step);
}
