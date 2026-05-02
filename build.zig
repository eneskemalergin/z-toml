const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose the library module to downstream packages via:
    //   b.dependency("z_toml", .{}).module("toml")
    const toml_module = b.addModule("toml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_module },
            },
        }),
    });

    const example_exe = b.addExecutable(.{
        .name = "parse-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parse_example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_module },
            },
        }),
    });

    const run_example = b.addRunArtifact(example_exe);
    run_example.addArg("examples/example.toml");

    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
    b.step("example", "Run the example TOML parser").dependOn(&run_example.step);
}
