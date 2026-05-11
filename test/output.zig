//! Output-focused tests for JSON and TOML serialization.

const std = @import("std");
const toml = @import("toml");
const support = @import("support.zig");

fn toJsonInBuf(value: toml.Value, buf: *[4096]u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    toml.toJson(value, &w) catch unreachable;
    return w.buffered();
}

test "toJson: string" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("\"hello\"", toJsonInBuf(.{ .string = "hello" }, &buf));
}

test "toJson: string with escapes" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\"", toJsonInBuf(.{ .string = "a\"b\\c\nd\te" }, &buf));
}

test "toJson: integer" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("42", toJsonInBuf(.{ .integer = .{ .value = 42 } }, &buf));
    try std.testing.expectEqualStrings("-7", toJsonInBuf(.{ .integer = .{ .value = -7 } }, &buf));
}

test "toJson: float" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("3.14", toJsonInBuf(.{ .float = 3.14 }, &buf));
}

test "toJson: float nan becomes null" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("null", toJsonInBuf(.{ .float = std.math.nan(f64) }, &buf));
}

test "toJson: float inf becomes null" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("null", toJsonInBuf(.{ .float = std.math.inf(f64) }, &buf));
    try std.testing.expectEqualStrings("null", toJsonInBuf(.{ .float = -std.math.inf(f64) }, &buf));
}

test "toJson: boolean" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("true", toJsonInBuf(.{ .boolean = true }, &buf));
    try std.testing.expectEqualStrings("false", toJsonInBuf(.{ .boolean = false }, &buf));
}

test "toJson: offset datetime" {
    var buf: [4096]u8 = undefined;
    const dt = toml.OffsetDateTime{
        .date = .{ .year = 1979, .month = 5, .day = 27 },
        .time = .{ .hour = 7, .minute = 32, .second = 0, .nanosecond = 0 },
        .offset_minutes = 0,
    };
    try std.testing.expectEqualStrings("\"1979-05-27T07:32:00Z\"", toJsonInBuf(.{ .offset_datetime = dt }, &buf));
}

test "toJson: offset datetime with non-zero offset" {
    var buf: [4096]u8 = undefined;
    const dt = toml.OffsetDateTime{
        .date = .{ .year = 1979, .month = 5, .day = 27 },
        .time = .{ .hour = 7, .minute = 32, .second = 0, .nanosecond = 0 },
        .offset_minutes = -420,
    };
    try std.testing.expectEqualStrings("\"1979-05-27T07:32:00-07:00\"", toJsonInBuf(.{ .offset_datetime = dt }, &buf));
}

test "toJson: local datetime" {
    var buf: [4096]u8 = undefined;
    const dt = toml.LocalDateTime{
        .date = .{ .year = 2024, .month = 1, .day = 15 },
        .time = .{ .hour = 14, .minute = 30, .second = 0, .nanosecond = 0 },
    };
    try std.testing.expectEqualStrings("\"2024-01-15T14:30:00\"", toJsonInBuf(.{ .local_datetime = dt }, &buf));
}

test "toJson: local date" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("\"2024-01-15\"", toJsonInBuf(.{ .local_date = .{ .year = 2024, .month = 1, .day = 15 } }, &buf));
}

test "toJson: local time" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("\"07:32:00\"", toJsonInBuf(.{ .local_time = .{ .hour = 7, .minute = 32, .second = 0, .nanosecond = 0 } }, &buf));
}

test "toJson: local time with nanoseconds" {
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("\"07:32:00.5\"", toJsonInBuf(.{ .local_time = .{ .hour = 7, .minute = 32, .second = 0, .nanosecond = 500_000_000 } }, &buf));
}

test "toJson: empty array" {
    var buf: [4096]u8 = undefined;
    const gpa = std.testing.allocator;
    const heap_arr = try gpa.create(std.ArrayList(toml.Value));
    heap_arr.* = .empty;
    defer {
        heap_arr.deinit(gpa);
        gpa.destroy(heap_arr);
    }
    try std.testing.expectEqualStrings("[]", toJsonInBuf(.{ .array = heap_arr }, &buf));
}

test "toJson: integer array" {
    var buf: [4096]u8 = undefined;
    const gpa = std.testing.allocator;
    const heap_arr = try gpa.create(std.ArrayList(toml.Value));
    heap_arr.* = .empty;
    defer {
        heap_arr.deinit(gpa);
        gpa.destroy(heap_arr);
    }
    try heap_arr.append(gpa, .{ .integer = .{ .value = 1 } });
    try heap_arr.append(gpa, .{ .integer = .{ .value = 2 } });
    try heap_arr.append(gpa, .{ .integer = .{ .value = 3 } });
    try std.testing.expectEqualStrings("[1,2,3]", toJsonInBuf(.{ .array = heap_arr }, &buf));
}

test "toJson: empty table" {
    var buf: [4096]u8 = undefined;
    const gpa = std.testing.allocator;
    const heap_tbl = try gpa.create(std.array_hash_map.String(toml.Value));
    heap_tbl.* = .empty;
    defer {
        heap_tbl.deinit(gpa);
        gpa.destroy(heap_tbl);
    }
    try std.testing.expectEqualStrings("{}", toJsonInBuf(.{ .table = heap_tbl }, &buf));
}

test "toJson: table with values" {
    var buf: [4096]u8 = undefined;
    const gpa = std.testing.allocator;
    const heap_tbl = try gpa.create(std.array_hash_map.String(toml.Value));
    heap_tbl.* = .empty;
    defer {
        heap_tbl.deinit(gpa);
        gpa.destroy(heap_tbl);
    }
    try heap_tbl.put(gpa, "name", .{ .string = "test" });
    try heap_tbl.put(gpa, "count", .{ .integer = .{ .value = 99 } });
    try std.testing.expectEqualStrings("{\"name\":\"test\",\"count\":99}", toJsonInBuf(.{ .table = heap_tbl }, &buf));
}

test "toJson: round trip parseSlice -> toJson" {
    const gpa = std.testing.allocator;
    const src = "title = \"hello\"\ncount = 42\nenabled = true\npi = 3.14";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [4096]u8 = undefined;
    const json = toJsonInBuf(.{ .table = root }, &buf);
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"title\":\"hello\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"count\":42"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"enabled\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"pi\":3.14"));
}

fn valuesEqual(a: toml.Value, b: toml.Value) bool {
    switch (a) {
        .string => return b == .string and std.mem.eql(u8, a.string, b.string),
        .integer => return b == .integer and a.integer.value == b.integer.value,
        .float => {
            if (b != .float) return false;
            if (std.math.isNan(a.float)) return std.math.isNan(b.float);
            return a.float == b.float;
        },
        .boolean => return b == .boolean and a.boolean == b.boolean,
        .offset_datetime => {
            if (b != .offset_datetime) return false;
            const da = a.offset_datetime;
            const db = b.offset_datetime;
            return da.date.year == db.date.year and da.date.month == db.date.month and
                da.date.day == db.date.day and da.time.hour == db.time.hour and
                da.time.minute == db.time.minute and da.time.second == db.time.second and
                da.time.nanosecond == db.time.nanosecond and
                da.offset_minutes == db.offset_minutes;
        },
        .local_datetime => {
            if (b != .local_datetime) return false;
            const da = a.local_datetime;
            const db = b.local_datetime;
            return da.date.year == db.date.year and da.date.month == db.date.month and
                da.date.day == db.date.day and da.time.hour == db.time.hour and
                da.time.minute == db.time.minute and da.time.second == db.time.second and
                da.time.nanosecond == db.time.nanosecond;
        },
        .local_date => {
            if (b != .local_date) return false;
            const da = a.local_date;
            const db = b.local_date;
            return da.year == db.year and da.month == db.month and da.day == db.day;
        },
        .local_time => {
            if (b != .local_time) return false;
            const ta = a.local_time;
            const tb = b.local_time;
            return ta.hour == tb.hour and ta.minute == tb.minute and
                ta.second == tb.second and ta.nanosecond == tb.nanosecond;
        },
        .array => {
            if (b != .array) return false;
            const aa = a.array;
            const ba = b.array;
            if (aa.items.len != ba.items.len) return false;
            for (aa.items, ba.items) |ae, be| {
                if (!valuesEqual(ae, be)) return false;
            }
            return true;
        },
        .table => {
            if (b != .table) return false;
            return tablesEqual(a.table, b.table);
        },
    }
}

fn tablesEqual(a: *toml.Table, b: *toml.Table) bool {
    if (a.count() != b.count()) return false;
    var it = a.iterator();
    while (it.next()) |entry| {
        const bv = b.get(entry.key_ptr.*) orelse return false;
        if (!valuesEqual(entry.value_ptr.*, bv)) return false;
    }
    return true;
}

fn roundtrip(gpa: std.mem.Allocator, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const root = try toml.parseSlice(aa, src, null);
    var buf: [262144]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeToml(.{ .table = root }, &w);
    const written = w.buffered();

    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(aa, written, &err);
    if (!tablesEqual(root, root2)) {
        std.debug.print("roundtrip tree mismatch. first parse:\n{s}\n---\noutput:\n{s}\n", .{ src, written });
        return error.TestUnexpectedResult;
    }
}

test "writeToml: simple scalars roundtrip" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa, "key = \"value\"\n");
    try roundtrip(gpa, "count = 42\n");
    try roundtrip(gpa, "pi = 3.14\n");
    try roundtrip(gpa, "flag = true\n");
}

test "writeToml: special floats" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa, "a = inf\n");
    try roundtrip(gpa, "a = -inf\n");
    try roundtrip(gpa, "a = nan\n");
}

test "writeToml: arrays" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa, "arr = [1, 2, 3]\n");
    try roundtrip(gpa, "arr = []\n");
    try roundtrip(gpa, "arr = [\"a\", \"b\"]\n");
    try roundtrip(gpa, "arr = [[1, 2], [3]]\n");
}

test "writeToml: inline table" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa, "pt = {x = 1, y = 2}\n");
}

test "writeToml: dotted keys for nested tables" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa,
        \\[owner]
        \\name = "Tom"
        \\[owner.details]
        \\age = 30
    );
}

test "writeToml: array of tables" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa,
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
    );
}

test "writeToml: nested AOT with sub-table" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa,
        \\[[fruits]]
        \\name = "apple"
        \\[fruits.physical]
        \\color = "red"
        \\
        \\[[fruits]]
        \\name = "banana"
        \\[fruits.physical]
        \\color = "yellow"
    );
}

test "writeToml: nested AOT with sub-AOT" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa,
        \\[[fruits]]
        \\name = "apple"
        \\[[fruits.varieties]]
        \\name = "red delicious"
        \\[[fruits.varieties]]
        \\name = "granny smith"
        \\
        \\[[fruits]]
        \\name = "banana"
        \\[[fruits.varieties]]
        \\name = "plantain"
    );
}

test "writeToml: all datetime types" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa, "dt = 1979-05-27T07:32:00Z\n");
    try roundtrip(gpa, "dt = 1979-05-27T07:32:00.5Z\n");
    try roundtrip(gpa, "dt = 1979-05-27T07:32:00-07:00\n");
    try roundtrip(gpa, "dt = 1979-05-27T07:32:00\n");
    try roundtrip(gpa, "d = 1979-05-27\n");
    try roundtrip(gpa, "t = 07:32:00\n");
    try roundtrip(gpa, "t = 07:32:00.5\n");
}

test "writeToml: empty document" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa, "");
}

test "writeToml: quoted keys" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa, "\"127.0.0.1\" = \"localhost\"\n");
    try roundtrip(gpa, "'quoted key' = true\n");
}

test "writeToml: dotted key at root creates implicit tables" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa,
        \\server.host = "example.com"
        \\server.port = 443
    );
}

test "writeToml: mixed root and dotted" {
    const gpa = std.testing.allocator;
    try roundtrip(gpa,
        \\title = "My App"
        \\[database]
        \\host = "localhost"
        \\port = 5432
    );
}

test "writeToml: proteomics file roundtrip" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "examples/proteomics.toml");
    defer gpa.free(src);
    try roundtrip(gpa, src);
}

test "writeToml: spec-example-1 roundtrip" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "test/valid/spec-example-1.toml");
    defer gpa.free(src);
    try roundtrip(gpa, src);
}

fn tomlString(value: toml.Value, buf: *[65536]u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    toml.writeToml(value, &w) catch unreachable;
    return w.buffered();
}

fn tomlStringSorted(value: toml.Value, buf: *[65536]u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    toml.writeTomlOpts(value, &w, .{ .sort_keys = true }, std.testing.allocator) catch unreachable;
    return w.buffered();
}

fn tomlStringDefault(value: toml.Value, buf: *[65536]u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    toml.writeTomlOpts(value, &w, .{}, std.testing.allocator) catch unreachable;
    return w.buffered();
}

test "formatter: default opts matches writeToml" {
    const gpa = std.testing.allocator;
    const src = "b = 1\na = 2\n";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf1: [65536]u8 = undefined;
    var buf2: [65536]u8 = undefined;
    const out1 = tomlString(.{ .table = root }, &buf1);
    const out2 = tomlStringDefault(.{ .table = root }, &buf2);
    try std.testing.expectEqualStrings(out1, out2);
}

test "formatter: insertion order preserved by default" {
    const gpa = std.testing.allocator;
    const src =
        \\z = "last"
        \\a = "first"
        \\m = "middle"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [65536]u8 = undefined;
    const out = tomlString(.{ .table = root }, &buf);
    try std.testing.expect(std.mem.startsWith(u8, out, "z = \"last\"\na = \"first\"\nm = \"middle\""));
}

test "formatter: sort_keys produces alphabetical order" {
    const gpa = std.testing.allocator;
    const src =
        \\z = "last"
        \\a = "first"
        \\m = "middle"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [65536]u8 = undefined;
    const out = tomlStringSorted(.{ .table = root }, &buf);
    try std.testing.expect(std.mem.startsWith(u8, out, "a = \"first\"\nm = \"middle\"\nz = \"last\""));
}

test "formatter: sorted output is deterministic" {
    const gpa = std.testing.allocator;
    const src =
        \\c = 3
        \\a = 1
        \\b = 2
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf1: [65536]u8 = undefined;
    var buf2: [65536]u8 = undefined;
    const out1 = tomlStringSorted(.{ .table = root }, &buf1);
    const out2 = tomlStringSorted(.{ .table = root }, &buf2);
    try std.testing.expectEqualStrings(out1, out2);
}

test "formatter: sort_keys round-trips correctly" {
    const gpa = std.testing.allocator;
    const src = "c = 3\na = 1\nb = 2\n";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlOpts(.{ .table = root }, &w, .{ .sort_keys = true }, gpa);
    const written = w.buffered();

    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(gpa, written, &err);
    defer toml.deinit(root2, gpa);
    try std.testing.expect(tablesEqual(root, root2));
}

test "formatter: sort_keys works on nested tables" {
    const gpa = std.testing.allocator;
    const src =
        \\[z_last]
        \\z = "last"
        \\a = "first"
        \\[z_last.sub]
        \\v = 1
        \\
        \\[a_first]
        \\m = "only"
        \\[a_first.sub]
        \\v = 2
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    const a_tbl = root.get("a_first").?.table;
    try std.testing.expectEqual(@as(usize, 2), a_tbl.count());
    try std.testing.expect(a_tbl.contains("m"));
    try std.testing.expect(a_tbl.contains("sub"));

    var buf: [65536]u8 = undefined;
    const out = tomlStringSorted(.{ .table = root }, &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "[a_first]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[z_last]") != null);
    const a_pos = std.mem.indexOf(u8, out, "[a_first]") orelse unreachable;
    const z_pos = std.mem.indexOf(u8, out, "[z_last]") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < z_pos);
    const inside_a = std.mem.indexOf(u8, out, "a = \"first\"") orelse return error.TestUnexpectedResult;
    const inside_z = std.mem.indexOf(u8, out, "z = \"last\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(inside_a < inside_z);
}

test "formatter: prefer_headers uses [header] for scalar-only sub-tables" {
    const gpa = std.testing.allocator;
    const src =
        \\[owner]
        \\name = "Tom"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlOpts(.{ .table = root }, &w, .{ .prefer_headers = true }, gpa);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[owner]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name = \"Tom\"") != null);
}

test "formatter: default emits inline for scalar-only sub-tables" {
    const gpa = std.testing.allocator;
    const src =
        \\[owner]
        \\name = "Tom"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlOpts(.{ .table = root }, &w, .{}, gpa);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "owner = {name = \"Tom\"}") != null);
}

test "formatter: use_escape_e emits \\e" {
    const gpa = std.testing.allocator;
    const src = "s = \"\\e[31m\"\n";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlOpts(.{ .table = root }, &w, .{ .use_escape_e = true }, gpa);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\\e[31m") != null);
}

test "formatter: default escape uses \\u001B for ESC" {
    const gpa = std.testing.allocator;
    const src = "s = \"\\e[31m\"\n";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlOpts(.{ .table = root }, &w, .{}, gpa);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\\u001B[31m") != null);
}

test "formatter: prefer_headers round-trips correctly" {
    const gpa = std.testing.allocator;
    const src = "name = \"x\"\n[database]\nport = 5432\n";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlOpts(.{ .table = root }, &w, .{ .prefer_headers = true }, gpa);
    const written = w.buffered();

    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(gpa, written, &err);
    defer toml.deinit(root2, gpa);
    try std.testing.expect(tablesEqual(root, root2));
}
