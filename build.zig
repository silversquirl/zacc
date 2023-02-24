const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    b.addModule(.{
        .name = "zacc",
        .source_file = .{ .path = "src/zacc.zig" },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/zacc.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&tests.step);
}
