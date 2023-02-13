const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    b.addModule(.{
        .name = "zlr",
        .source_file = .{ .path = "src/zlr.zig" },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/zlr.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&tests.step);
}
