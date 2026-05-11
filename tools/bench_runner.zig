/// Benchmark runner for zebrac. Usage:
///   ./bench_runner <file.toml> <parse|write|json|rt>
/// Exits 0 on success, non-zero on failure.
/// Zebrac measures wall-clock time of the process.

const std = @import("std");
const toml = @import("toml");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var arg_iter = std.process.Args.iterate(init.minimal.args);
    defer arg_iter.deinit();
    _ = arg_iter.next(); // skip program name
    const path = arg_iter.next() orelse {
        std.debug.print("usage: bench-runner <file> <parse|write|json|rt>\n", .{});
        std.process.exit(1);
    };
    const mode = arg_iter.next() orelse {
        std.debug.print("usage: bench-runner <file> <parse|write|json|rt>\n", .{});
        std.process.exit(1);
    };

    const io = init.io;
    var buf: [1 << 22]u8 = undefined;

    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 22));

    if (std.mem.eql(u8, mode, "parse") or std.mem.eql(u8, mode, "rt")) {
        const root = try toml.parseSlice(gpa, src, null);
        if (std.mem.eql(u8, mode, "rt")) {
            var w = std.Io.Writer.fixed(&buf);
            try toml.writeToml(.{ .table = root }, &w);
        }
    } else if (std.mem.eql(u8, mode, "write")) {
        const root = try toml.parseSlice(gpa, src, null);
        var w = std.Io.Writer.fixed(&buf);
        try toml.writeToml(.{ .table = root }, &w);
    } else if (std.mem.eql(u8, mode, "json")) {
        const root = try toml.parseSlice(gpa, src, null);
        var w = std.Io.Writer.fixed(&buf);
        try toml.toJson(.{ .table = root }, &w);
    } else {
        std.debug.print("unknown mode: {s}\n", .{mode});
        std.process.exit(1);
    }
}
