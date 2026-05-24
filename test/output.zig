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

fn writeProfileOwned(
    gpa: std.mem.Allocator,
    value: toml.Value,
    profile: toml.OutputProfile,
    hints: ?*toml.FormatHints,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.writeTomlWithProfile(value, &out.writer, profile, hints, gpa);
    return try out.toOwnedSlice();
}

fn expectReparseMatches(gpa: std.mem.Allocator, root: *toml.Table, written: []const u8) !void {
    var err: toml.ErrorInfo = .{};
    const reparsed = try toml.parseSlice(gpa, written, &err);
    defer toml.deinit(reparsed, gpa);
    try std.testing.expect(tablesEqual(root, reparsed));
}

test "writeToml: corpus edge fixtures roundtrip" {
    const gpa = std.testing.allocator;
    const fixtures = [_][]const u8{
        "test/valid/key/quoted-dots.toml",
        "test/valid/string/escape-tricky.toml",
        "test/valid/table/with-single-quotes.toml",
        "test/valid/table/array-implicit-and-explicit-after.toml",
        "test/valid/table/array-table-array.toml",
    };

    for (fixtures) |fixture| {
        const src = try support.readTestFile(gpa, fixture);
        defer gpa.free(src);
        try roundtrip(gpa, src);
    }
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

fn tomlString(value: toml.Value, buf: *[65536]u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try toml.writeToml(value, &w);
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
    const out1 = try tomlString(.{ .table = root }, &buf1);
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
    const out = try tomlString(.{ .table = root }, &buf);
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

test "profile: compact produces semantic delta on spec-example fixture" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "test/valid/spec-example-1.toml");
    defer gpa.free(src);

    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    const written = try writeProfileOwned(gpa, .{ .table = root }, .compact, null);
    defer gpa.free(written);

    try std.testing.expect(!std.mem.eql(u8, src, written));
    try std.testing.expect(std.mem.indexOf(u8, written, "[owner]") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "owner = {name = \"Lance Uppercut\", dob = 1979-05-27T07:32:00-08:00}") != null);
    try expectReparseMatches(gpa, root, written);
}

test "profile: compact inlines scalar-only tables while preserve keeps headers" {
    const gpa = std.testing.allocator;
    const src =
        \\[owner]
        \\name = "Tom"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var compact_buf: [256]u8 = undefined;
    var compact_writer = std.Io.Writer.fixed(&compact_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &compact_writer, .compact, null, gpa);
    try std.testing.expectEqualStrings("owner = {name = \"Tom\"}\n", compact_writer.buffered());

    var preserve_buf: [256]u8 = undefined;
    var preserve_writer = std.Io.Writer.fixed(&preserve_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &preserve_writer, .preserve, null, gpa);
    try std.testing.expectEqualStrings("\n[owner]\nname = \"Tom\"\n", preserve_writer.buffered());
}

test "profile: canonical sorts keys and uses escape-e" {
    const gpa = std.testing.allocator;
    const src =
        \\z = 1
        \\s = "\e[31m"
        \\a = 2
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .canonical, null, gpa);
    try std.testing.expectEqualStrings("a = 2\ns = \"\\e[31m\"\nz = 1\n", w.buffered());
}

test "profile: canonical sorts real fixture sections without changing tree" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "test/valid/spec-example-1.toml");
    defer gpa.free(src);

    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    const written = try writeProfileOwned(gpa, .{ .table = root }, .canonical, null);
    defer gpa.free(written);

    try std.testing.expect(!std.mem.eql(u8, src, written));
    const owner_pos = std.mem.indexOf(u8, written, "[owner]\n") orelse return error.TestUnexpectedResult;
    const dob_pos = std.mem.indexOf(u8, written, "dob = 1979-05-27T07:32:00-08:00") orelse return error.TestUnexpectedResult;
    const name_pos = std.mem.indexOf(u8, written, "name = \"Lance Uppercut\"") orelse return error.TestUnexpectedResult;
    const db_connection_pos = std.mem.indexOf(u8, written, "connection_max = 5000") orelse return error.TestUnexpectedResult;
    const db_server_pos = std.mem.indexOf(u8, written, "server = \"192.168.1.1\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(owner_pos < dob_pos);
    try std.testing.expect(dob_pos < name_pos);
    try std.testing.expect(db_connection_pos < db_server_pos);
    try expectReparseMatches(gpa, root, written);
}

test "profile: compact keeps nested array-table ancestry on corpus fixture" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "test/valid/table/array-table-array.toml");
    defer gpa.free(src);

    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    const written = try writeProfileOwned(gpa, .{ .table = root }, .compact, null);
    defer gpa.free(written);

    try std.testing.expect(std.mem.indexOf(u8, written, "[[a]]") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, written, "[[a.b]]"));
    try std.testing.expect(std.mem.indexOf(u8, written, "[a.b.c]") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "c = {d = \"val0\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "c = {d = \"val1\"}") != null);
    try expectReparseMatches(gpa, root, written);
}

test "profile: preserve honors captured string styles" {
    const gpa = std.testing.allocator;
    const src = "note = '''\nline one\nline two\n'''\n";

    var string_styles: toml.HintMap(toml.StringStyle) = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{ .string_styles = &string_styles, .document = &document };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    var preserve_buf: [256]u8 = undefined;
    var preserve_writer = std.Io.Writer.fixed(&preserve_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &preserve_writer, .preserve, &hints, gpa);
    try std.testing.expectEqualStrings(src, preserve_writer.buffered());
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

test "profile: faithful preserves leading and trailing entry comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src =
        \\# lead
        \\key = "value" # trail
    ;

    var comments: toml.CommentMap = .empty;
    var hints: toml.FormatHints = .{ .comments = &comments };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    const expected = src ++ "\n";

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "profile: faithful preserves multiple leading comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src =
        \\# first
        \\# second
        \\key = "value"
    ;

    var comments: toml.CommentMap = .empty;
    var hints: toml.FormatHints = .{ .comments = &comments };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    const expected = src ++ "\n";

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "profile: faithful keeps quoted-dot and nested path hints distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src =
        \\"a.b" = "flat"
        \\
        \\[a]
        \\b = 'nested'
    ;

    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var hints: toml.FormatHints = .{ .string_styles = &styles };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    const flat_segments = [_]toml.PathSegment{.{ .key = "a.b" }};
    const nested_segments = [_]toml.PathSegment{ .{ .key = "a" }, .{ .key = "b" } };
    try std.testing.expectEqual(toml.StringStyle.basic, styles.get(.{ .segments = &flat_segments }).?);
    try std.testing.expectEqual(toml.StringStyle.literal, styles.get(.{ .segments = &nested_segments }).?);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "= \"flat\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "= 'nested'"));
}

test "profile: faithful preserves table header comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src =
        \\title = "root"
        \\
        \\# lead
        \\[section] # trail
        \\key = "value"
    ;
    const expected = src ++ "\n";

    var comments: toml.CommentMap = .empty;
    var hints: toml.FormatHints = .{ .comments = &comments };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "profile: faithful preserves AOT header comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src =
        \\title = "root"
        \\
        \\# lead
        \\[[items]] # trail
        \\name = "value"
    ;
    const expected = src ++ "\n";

    var comments: toml.CommentMap = .empty;
    var hints: toml.FormatHints = .{ .comments = &comments };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "profile: faithful preserves multiline basic string style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src =
        \\mb = """
        \\line1
        \\line2
        \\"""
    ;
    const expected = src ++ "\n";

    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var hints: toml.FormatHints = .{ .string_styles = &styles };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "profile: faithful preserves multiline literal string style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src =
        \\ml = '''
        \\line1
        \\line2
        \\'''
    ;
    const expected = src ++ "\n";

    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var hints: toml.FormatHints = .{ .string_styles = &styles };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "profile: faithful preserves string styles in inline tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = "cfg = { literal = 'lit', basic = \"basic\" }\n";

    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var hints: toml.FormatHints = .{ .string_styles = &styles };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "literal = 'lit'"));
    try std.testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "basic = \"basic\""));
}

test "profile: faithful preserves string styles in arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = "arr = ['lit', \"basic\"]\n";

    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var hints: toml.FormatHints = .{ .string_styles = &styles };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(src, w.buffered());
}

test "profile: faithful preserves key quote styles and inline table syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = "\"a.b\" = \"flat\"\n" ++
        "cfg = { \"nested.key\" = \"value\" }\n" ++
        "\n" ++
        "[\"table.part\"]\n" ++
        "\"child.key\" = \"value\"";
    const expected = src ++ "\n";

    var key_styles: toml.KeyStyleMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var hints: toml.FormatHints = .{ .key_styles = &key_styles, .table_syntax = &table_syntax };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "profile: faithful preserves CRLF line endings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = "title = \"root\"\r\n\r\n[section]\r\nkey = \"value\"\r\n";

    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{ .document = &document };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(src, w.buffered());
}

test "profile: faithful preserves UTF-8 BOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = "\xEF\xBB\xBFkey = \"value\"\n";

    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{ .document = &document };
    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(src, w.buffered());
}

fn expectFaithfulExactRoundtrip(gpa: std.mem.Allocator, src: []const u8) !void {
    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .string_styles = &styles,
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    const out_buf = try gpa.alloc(u8, src.len * 16 + 4096);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings(src, w.buffered());
}

fn expectFaithfulExactRoundtripFixture(gpa: std.mem.Allocator, path: []const u8) !void {
    const src = try support.readTestFile(gpa, path);
    defer gpa.free(src);
    try expectFaithfulExactRoundtrip(gpa, src);
}

test "profile: faithful exact roundtrip comment fixture everywhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectFaithfulExactRoundtrip(arena.allocator(), @embedFile("valid/comment/everywhere.toml"));
}

test "profile: faithful exact roundtrip comment fixture without eol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectFaithfulExactRoundtrip(arena.allocator(), @embedFile("valid/comment/noeol.toml"));
}

test "profile: faithful exact roundtrip extra comment fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const fixtures = [_][]const u8{
        "test/valid/comment/at-eof.toml",
        "test/valid/comment/at-eof2.toml",
        "test/valid/comment/after-literal-no-ws.toml",
        "test/valid/comment/nonascii.toml",
    };

    for (fixtures) |fixture| try expectFaithfulExactRoundtripFixture(gpa, fixture);
}

test "profile: faithful exact roundtrip quoted dotted keys fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectFaithfulExactRoundtrip(arena.allocator(), @embedFile("valid/key/quoted-dots.toml"));
}

test "writeToml: layout corpus fixtures normalize safely" {
    const gpa = std.testing.allocator;
    const fixtures = [_][]const u8{
        "test/valid/table/no-eol-01.toml",
        "test/valid/table/no-eol-02.toml",
        "test/valid/table/whitespace.toml",
    };

    for (fixtures) |fixture| {
        const src = try support.readTestFile(gpa, fixture);
        defer gpa.free(src);
        try roundtrip(gpa, src);
    }
}

test "writeToml: without-super-with-values normalizes to parent-first headers" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "test/valid/table/without-super-with-values.toml");
    defer gpa.free(src);

    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.writeToml(.{ .table = root }, &out.writer);
    const written = try out.toOwnedSlice();
    defer gpa.free(written);

    try std.testing.expect(!std.mem.eql(u8, src, written));
    try std.testing.expect(std.mem.indexOf(u8, written, "[x]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[x.y.z.w]\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "c = 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "d = 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "a = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "b = 2") != null);
    try expectReparseMatches(gpa, root, written);
}

test "writeToml: array-within-dotted expands dotted member into explicit table header" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "test/valid/table/array-within-dotted.toml");
    defer gpa.free(src);

    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.writeToml(.{ .table = root }, &out.writer);
    const written = try out.toOwnedSlice();
    defer gpa.free(written);

    try std.testing.expect(std.mem.indexOf(u8, written, "apple.color = \"red\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[fruit.apple]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "color = \"red\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[[fruit.apple.seeds]]\n") != null);
    try expectReparseMatches(gpa, root, written);
}

test "profile: faithful does not replay stale source after mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = "answer = 41\n";

    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .string_styles = &styles,
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("answer").?.* = .{ .integer = .{ .value = 42 } };

    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);
    try std.testing.expectEqualStrings("answer = 42\n", w.buffered());
}

test "profile: faithful mutation preserves dotted header origin and escaped key spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = @embedFile("valid/key/quoted-dots.toml");

    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .string_styles = &styles,
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("plain").?.* = .{ .integer = .{ .value = 9 } };

    const out_buf = try gpa.alloc(u8, src.len * 16 + 4096);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);

    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\n[table]\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[table.withdot]") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"escaped\\u002edot\" = 7") != null);
}

test "profile: faithful mutation preserves escaped header segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = @embedFile("valid/key/escapes.toml");

    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .string_styles = &styles,
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("\n").?.* = .{ .string = try gpa.dupe(u8, "changed") };

    const out_buf = try gpa.alloc(u8, src.len * 16 + 4096);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);

    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[\"a.b\".\"\\u00c0\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[\"\\\"quoted\\\"\"]") != null);
}

test "profile: faithful mutation preserves trailing comment spacing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = @embedFile("valid/comment/everywhere.toml");

    var styles: toml.HintMap(toml.StringStyle) = .empty;
    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .string_styles = &styles,
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("group").?.table.getPtr("answer").?.* = .{ .integer = .{ .value = 77 } };

    const out_buf = try gpa.alloc(u8, src.len * 16 + 4096);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);

    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "  # Top comment.") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[group] # Comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "answer = 77 # Comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "dt = 1979-05-27T07:32:12-07:00  # c") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[[aot]]# Comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "k = 99# Comment") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "more ="));
}

test "profile: faithful mutation preserves float lexemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = @embedFile("valid/float/exponent.toml");

    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var value_lexemes: toml.ValueLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .value_lexemes = &value_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("lower").?.* = .{ .float = 301.0 };

    const out_buf = try gpa.alloc(u8, src.len * 8 + 1024);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);

    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "upper = 3E2") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "pos = 3E+2") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "pointupper = 3.1E2") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "minustenth = -1E-1") != null);
}

test "profile: faithful mutation preserves float underscore lexemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = @embedFile("valid/float/underscore.toml");

    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var value_lexemes: toml.ValueLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .value_lexemes = &value_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("before").?.* = .{ .float = 1.0 };

    const out_buf = try gpa.alloc(u8, src.len * 8 + 1024);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);

    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "after = 3141.592_7") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "exponent = 3e1_4") != null);
}

test "profile: faithful mutation preserves special float lexemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = @embedFile("valid/float/inf-and-nan.toml");

    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var value_lexemes: toml.ValueLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .value_lexemes = &value_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("nan").?.* = .{ .float = 0.0 };

    const out_buf = try gpa.alloc(u8, src.len * 8 + 1024);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);

    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "nan_plus = +nan") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "infinity_plus = +inf") != null);
}

test "profile: faithful mutation preserves datetime lexemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = @embedFile("valid/datetime/no-seconds.toml");

    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var value_lexemes: toml.ValueLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .value_lexemes = &value_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("without-seconds-1").?.* = .{ .local_time = .{ .hour = 1, .minute = 2, .second = 3, .nanosecond = 0 } };

    const out_buf = try gpa.alloc(u8, src.len * 8 + 1024);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);

    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "without-seconds-2 = 1979-05-27 07:32Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "without-seconds-3 = 1979-05-27 07:32-07:00") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "without-seconds-4 = 1979-05-27T07:32") != null);
}

test "profile: faithful mutation preserves datetime fractional lexemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = @embedFile("valid/datetime/milliseconds.toml");

    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var value_lexemes: toml.ValueLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .value_lexemes = &value_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("utc1").?.* = .{ .offset_datetime = .{
        .date = .{ .year = 2000, .month = 1, .day = 2 },
        .time = .{ .hour = 3, .minute = 4, .second = 5, .nanosecond = 0 },
        .offset_minutes = 0,
    } };

    const out_buf = try gpa.alloc(u8, src.len * 8 + 1024);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);

    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "1987-07-05T17:45:56.6Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "1987-07-05T17:45:56.6+08:00") != null);
}

test "profile: faithful mutation ignores internal comment trivia without duplicating keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src = @embedFile("valid/comment/tricky.toml");

    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var value_lexemes: toml.ValueLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .value_lexemes = &value_lexemes,
        .table_syntax = &table_syntax,
        .comments = &comments,
        .document = &document,
    };
    defer hints.deinit(gpa);

    const root = try toml.parseSliceWithHints(gpa, src, null, &hints);
    defer toml.deinit(root, gpa);

    root.getPtr("section").?.table.getPtr("8").?.* = .{ .string = try gpa.dupe(u8, "changed") };

    const out_buf = try gpa.alloc(u8, src.len * 8 + 4096);
    defer gpa.free(out_buf);
    var w = std.Io.Writer.fixed(out_buf);
    try toml.writeTomlWithProfile(.{ .table = root }, &w, .faithful, &hints, gpa);

    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[section]#attached comment") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "arr4 ="));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "arr5 ="));
}

test "writeToml: basic quoted key escapes control characters" {
    const gpa = std.testing.allocator;
    const src = "\"\\n\" = 1\n";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    try toml.writeToml(.{ .table = root }, &w);
    try std.testing.expectEqualStrings(src, w.buffered());
}

// ─── Phase 6 test coverage ─────────────────────────────────────────────────────

test "writeToml: integer hex base roundtrips as 0x" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "h = 0xDEAD\n", null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqual(.hex, root.get("h").?.integer.base);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeToml(.{ .table = root }, &w);
    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(gpa, w.buffered(), &err);
    defer toml.deinit(root2, gpa);
    try std.testing.expectEqual(.hex, root2.get("h").?.integer.base);
}

test "writeToml: integer octal base roundtrips as 0o" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "o = 0o755\n", null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqual(.octal, root.get("o").?.integer.base);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeToml(.{ .table = root }, &w);
    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(gpa, w.buffered(), &err);
    defer toml.deinit(root2, gpa);
    try std.testing.expectEqual(.octal, root2.get("o").?.integer.base);
}

test "writeToml: integer binary base roundtrips as 0b" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "b = 0b1010\n", null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqual(.binary, root.get("b").?.integer.base);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeToml(.{ .table = root }, &w);
    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(gpa, w.buffered(), &err);
    defer toml.deinit(root2, gpa);
    try std.testing.expectEqual(.binary, root2.get("b").?.integer.base);
}

test "writeToml: empty array of tables roundtrips" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "[[products]]\n", null);
    defer toml.deinit(root, gpa);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeToml(.{ .table = root }, &w);
    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(gpa, w.buffered(), &err);
    defer toml.deinit(root2, gpa);
    try std.testing.expect(root2.get("products").? == .array);
}

test "toJson: nested array in array" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "x = [[1, 2], [3]]\n", null);
    defer toml.deinit(root, gpa);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.toJson(.{ .table = root }, &w);
    try std.testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "[[1,2],[3]]"));
}

test "toJson: nested table produces nested JSON" {
    const gpa = std.testing.allocator;
    const src = "[a]\nb = 1\n[a.c]\nd = 2\n";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.toJson(.{ .table = root }, &w);
    try std.testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "\"c\":{\"d\":2}"));
}

test "toJson: control chars produce \\uXXXX" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "s = \"a\\x01b\"\n", null);
    defer toml.deinit(root, gpa);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.toJson(.{ .table = root }, &w);
    try std.testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "\\u0001"));
}

test "writeToml: key with single quote uses basic" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "\"it's\" = \"val\"\n", null);
    defer toml.deinit(root, gpa);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeToml(.{ .table = root }, &w);
    try std.testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "\"it's\""));
}

test "writeToml: key with hash roundtrips" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "\"key#1\" = \"val\"\n", null);
    defer toml.deinit(root, gpa);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeToml(.{ .table = root }, &w);
    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(gpa, w.buffered(), &err);
    defer toml.deinit(root2, gpa);
    try std.testing.expectEqualStrings("val", root2.get("key#1").?.string);
}

test "writeToml: key with equals roundtrips" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "\"a=b\" = \"val\"\n", null);
    defer toml.deinit(root, gpa);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeToml(.{ .table = root }, &w);
    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(gpa, w.buffered(), &err);
    defer toml.deinit(root2, gpa);
    try std.testing.expectEqualStrings("val", root2.get("a=b").?.string);
}

test "writeToml: key with brackets roundtrips" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "\"a[b]\" = \"val\"\n", null);
    defer toml.deinit(root, gpa);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try toml.writeToml(.{ .table = root }, &w);
    var err: toml.ErrorInfo = .{};
    const root2 = try toml.parseSlice(gpa, w.buffered(), &err);
    defer toml.deinit(root2, gpa);
    try std.testing.expectEqualStrings("val", root2.get("a[b]").?.string);
}
