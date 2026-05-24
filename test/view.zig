const std = @import("std");
const toml = @import("toml");

fn cloneViewRoot(ally: std.mem.Allocator, src: []const u8) !void {
    const view_root = try toml.parseSliceView(ally, src, null);
    defer toml.deinitViewTable(view_root, ally, src);

    const cloned = try toml.cloneValue(ally, .{ .table = view_root }, src);
    defer toml.deinit(cloned.table, ally);
}

test "parseSliceView: borrowed strings roundtrip through writeTomlView" {
    const gpa = std.testing.allocator;
    const src = "title = \"hello\"\n";

    const root = try toml.parseSliceView(gpa, src, null);
    defer toml.deinitViewTable(root, gpa, src);

    const title = root.get("title").?.string;
    const title_addr = @intFromPtr(title.ptr);
    const input_start = @intFromPtr(src.ptr);
    const input_end = input_start + src.len;

    try std.testing.expect(title_addr >= input_start);
    try std.testing.expect(title_addr < input_end);

    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    try toml.writeTomlView(.{ .table = root }, &w, .{}, gpa, src);
    try std.testing.expectEqualStrings(src, w.buffered());
}

test "cloneValue: deep copy is independent from borrowed input" {
    const gpa = std.testing.allocator;
    var src_buf = [_]u8{ 't', 'i', 't', 'l', 'e', ' ', '=', ' ', '"', 'h', 'e', 'l', 'l', 'o', '"', '\n' };
    const src = src_buf[0..];

    const root = try toml.parseSliceView(gpa, src, null);
    defer toml.deinitViewTable(root, gpa, src);

    const cloned = try toml.cloneValue(gpa, .{ .table = root }, src);
    defer toml.deinit(cloned.table, gpa);

    src_buf[9] = 'j';

    var owned_buf: [256]u8 = undefined;
    var owned_writer = std.Io.Writer.fixed(&owned_buf);
    try toml.writeToml(cloned, &owned_writer);
    try std.testing.expectEqualStrings("title = \"hello\"\n", owned_writer.buffered());

    var view_buf: [256]u8 = undefined;
    var view_writer = std.Io.Writer.fixed(&view_buf);
    try toml.writeTomlView(.{ .table = root }, &view_writer, .{}, gpa, src);
    try std.testing.expectEqualStrings("title = \"jello\"\n", view_writer.buffered());
}

test "cloneValue: nested structures survive allocation failures" {
    const src =
        \\title = "demo"
        \\items = [{ name = "hammer" }, { name = "nail" }]
        \\[owner]
        \\tags = ["a", "b"]
    ;

    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneViewRoot, .{src});
}
