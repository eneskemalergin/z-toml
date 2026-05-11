const std = @import("std");
const toml = @import("toml");

const File = struct { path: []const u8, label: []const u8 };

const files = [_]File{
    .{ .path = "examples/example.toml", .label = "example (small)" },
    .{ .path = "examples/proteomics.toml", .label = "proteomics (large)" },
    .{ .path = "test/valid/spec-example-1.toml", .label = "spec-example-1" },
};

fn getUs(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).toMicroseconds());
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    std.debug.print("{s:>25}  {s:>6}  {s:>7}  {s:>7}  {s:>7}  {s:>7}\n", .{ "file", "bytes", "parse", "write", "json", "rt" });

    inline for (files) |f| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const gpa = arena.allocator();

        const src = try std.Io.Dir.cwd().readFileAlloc(io, f.path, gpa, .limited(1 << 22));
        const src_len = src.len;

        // Parse
        const p0 = getUs(io);
        const root = try toml.parseSlice(gpa, src, null);
        const parse_us = getUs(io) - p0;

        // Write TOML
        var buf: [1 << 22]u8 = undefined;
        const w0 = getUs(io);
        {
            var w = std.Io.Writer.fixed(&buf);
            try toml.writeToml(.{ .table = root }, &w);
        }
        const write_us = getUs(io) - w0;

        // Write JSON
        const j0 = getUs(io);
        {
            var w = std.Io.Writer.fixed(&buf);
            try toml.toJson(.{ .table = root }, &w);
        }
        const json_us = getUs(io) - j0;

        // Round trip
        const r0 = getUs(io);
        {
            var w = std.Io.Writer.fixed(&buf);
            try toml.writeToml(.{ .table = root }, &w);
            _ = try toml.parseSlice(gpa, w.buffered(), null);
        }
        const rt_us = getUs(io) - r0;

        std.debug.print("{s:>25}  {d:>6}  {d:>7}  {d:>7}  {d:>7}  {d:>7}\n", .{ f.label, src_len, parse_us, write_us, json_us, rt_us });
    }
}
