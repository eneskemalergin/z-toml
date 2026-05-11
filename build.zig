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

    const proteomics_exe = b.addExecutable(.{
        .name = "parse-proteomics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/parse_proteomics.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_module },
            },
        }),
    });

    const run_proteomics = b.addRunArtifact(proteomics_exe);

    const pyproject_exe = b.addExecutable(.{
        .name = "pyproject-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/pyproject_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_module },
            },
        }),
    });

    const run_pyproject = b.addRunArtifact(pyproject_exe);
    b.step("pyproject", "Parse pyproject.toml, output JSON + TOML").dependOn(&run_pyproject.step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_module },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    b.step("bench", "Run benchmarks").dependOn(&run_bench.step);

    const bench_runner = b.addExecutable(.{
        .name = "bench-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_module },
            },
        }),
    });
    const install_runner = b.addInstallArtifact(bench_runner, .{});
    b.step("install-bench", "Install bench-runner to zig-out/bin").dependOn(&install_runner.step);

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_module },
            },
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
    b.step("fuzz", "Run fuzz harness (5,000 random inputs)").dependOn(&run_fuzz.step);
    b.step("example", "Run the example TOML parser").dependOn(&run_example.step);
    b.step("proteomics", "Parse and print proteomics.toml").dependOn(&run_proteomics.step);
}
