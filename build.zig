const std = @import("std");

pub fn build(b: *std.Build) void {
    const zacc = b.addModule("zacc", .{
        .source_file = .{ .path = "src/zacc.zig" },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/zacc.zig" },
    });
    b.step("test", "Run library tests").dependOn(&tests.step);

    const exe = b.addExecutable(.{
        .name = "arithmetic",
        .root_source_file = .{ .path = "example/arithmetic.zig" },
    });
    exe.addModule("zacc", zacc);
    b.step("run", "Run the arithmetic example").dependOn(&exe.run().step);
}
