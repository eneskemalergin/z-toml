const std = @import("std");
const toml = @import("toml");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);
    const smoke_mode = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");

    // Read pyproject.toml
    const dir = std.Io.Dir.cwd();
    const src = try dir.readFileAlloc(io, "examples/pyproject.toml", alloc, .limited(1 << 20));

    // Parse
    var err: toml.ErrorInfo = .{};
    const root = try toml.parseSlice(alloc, src, &err);
    std.debug.print("Parsed successfully.\n", .{});

    // Write JSON
    var json_buf: [65536]u8 = undefined;
    var json_w = std.Io.Writer.fixed(&json_buf);
    try toml.toJson(.{ .table = root }, &json_w);
    try json_w.flush();
    const json_out = json_w.buffered();

    // Write TOML (default)
    var toml_buf: [65536]u8 = undefined;
    var toml_w = std.Io.Writer.fixed(&toml_buf);
    try toml.writeToml(.{ .table = root }, &toml_w);
    const toml_out = toml_w.buffered();

    // Write TOML (sorted keys, headers, escape-e)
    var canon_buf: [65536]u8 = undefined;
    var canon_w = std.Io.Writer.fixed(&canon_buf);
    try toml.writeTomlOpts(.{ .table = root }, &canon_w, .{
        .sort_keys = true,
        .prefer_headers = true,
        .use_escape_e = true,
    }, alloc);
    const canon_out = canon_w.buffered();

    if (smoke_mode) {
        std.debug.print(
            "Validated pyproject.toml in memory. json={d} bytes toml={d} bytes canonical={d} bytes\n",
            .{ json_out.len, toml_out.len, canon_out.len },
        );
        return;
    }

    try dir.writeFile(io, .{ .sub_path = "examples/pyproject.json", .data = json_out });
    std.debug.print("Wrote examples/pyproject.json ({d} bytes)\n", .{json_out.len});
    try dir.writeFile(io, .{ .sub_path = "examples/pyproject_roundtrip.toml", .data = toml_out });
    std.debug.print("Wrote examples/pyproject_roundtrip.toml ({d} bytes)\n", .{toml_out.len});
    try dir.writeFile(io, .{ .sub_path = "examples/pyproject_canonical.toml", .data = canon_out });
    std.debug.print("Wrote examples/pyproject_canonical.toml ({d} bytes)\n", .{canon_out.len});
}
