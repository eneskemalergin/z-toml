const std = @import("std");
const toml = @import("toml");
const json = std.json;

const manifest = @embedFile("files-toml-1.1.0");
const max_reported_failures = 20;
const CompareError = error{Mismatch};
const TypedScalar = struct {
    type_name: []const u8,
    value: []const u8,
};

fn readTestFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(std.math.maxInt(usize)));
}

fn makeChildPath(buf: []u8, base: []const u8, child: []const u8) []const u8 {
    if (base.len == 0) {
        return std.fmt.bufPrint(buf, "{s}", .{child}) catch base;
    }
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ base, child }) catch base;
}

fn makeIndexPath(buf: []u8, base: []const u8, index: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}[{d}]", .{ base, index }) catch base;
}

fn typedScalar(expected: json.Value) ?TypedScalar {
    if (expected != .object) return null;
    const obj = expected.object;
    if (obj.count() != 2) return null;

    const type_value = obj.get("type") orelse return null;
    const value_value = obj.get("value") orelse return null;
    if (type_value != .string or value_value != .string) return null;

    return .{ .type_name = type_value.string, .value = value_value.string };
}

fn appendFraction(buf: []u8, nanosecond: u32) []const u8 {
    if (nanosecond == 0) return "";

    var digits_buf: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&digits_buf, "{d:0>9}", .{nanosecond}) catch return "";
    var end = digits_buf.len;
    while (end > 0 and digits_buf[end - 1] == '0') : (end -= 1) {}
    return std.fmt.bufPrint(buf, ".{s}", .{digits_buf[0..end]}) catch "";
}

fn normalizeTemporalValue(buf: []u8, value: []const u8) []const u8 {
    const dot_index = std.mem.indexOfScalar(u8, value, '.') orelse return value;

    var end = dot_index + 1;
    while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
    if (end == dot_index + 1) return value;

    var trimmed_end = end;
    while (trimmed_end > dot_index + 1 and value[trimmed_end - 1] == '0') : (trimmed_end -= 1) {}
    if (trimmed_end == end) return value;

    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ value[0..trimmed_end], value[end..end], value[end..] }) catch value;
}

fn formatLocalDate(buf: []u8, value: toml.LocalDate) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ value.year, value.month, value.day }) catch "";
}

fn formatLocalTime(buf: []u8, value: toml.LocalTime) []const u8 {
    var fraction_buf: [16]u8 = undefined;
    const fraction = appendFraction(&fraction_buf, value.nanosecond);
    return std.fmt.bufPrint(
        buf,
        "{d:0>2}:{d:0>2}:{d:0>2}{s}",
        .{ value.hour, value.minute, value.second, fraction },
    ) catch "";
}

fn formatLocalDateTime(buf: []u8, value: toml.LocalDateTime) []const u8 {
    var date_buf: [16]u8 = undefined;
    var time_buf: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}T{s}", .{
        formatLocalDate(&date_buf, value.date),
        formatLocalTime(&time_buf, value.time),
    }) catch "";
}

fn formatOffsetDateTime(buf: []u8, value: toml.OffsetDateTime) []const u8 {
    var local_buf: [48]u8 = undefined;
    const local = formatLocalDateTime(&local_buf, .{ .date = value.date, .time = value.time });
    if (value.offset_minutes == 0) {
        return std.fmt.bufPrint(buf, "{s}Z", .{local}) catch "";
    }

    const total_minutes = @abs(value.offset_minutes);
    const offset_hours = @divTrunc(total_minutes, 60);
    const offset_minutes = @mod(total_minutes, 60);
    const sign: u8 = if (value.offset_minutes < 0) '-' else '+';
    return std.fmt.bufPrint(buf, "{s}{c}{d:0>2}:{d:0>2}", .{ local, sign, offset_hours, offset_minutes }) catch "";
}

fn compareScalar(actual: toml.Value, expected: TypedScalar, path: []const u8) CompareError!void {
    if (std.mem.eql(u8, expected.type_name, "string")) {
        if (actual != .string or !std.mem.eql(u8, actual.string, expected.value)) {
            std.debug.print("\nvalid corpus mismatch: {s} expected string {s}, got different value\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "bool")) {
        const want = std.mem.eql(u8, expected.value, "true");
        if (actual != .boolean or actual.boolean != want) {
            std.debug.print("\nvalid corpus mismatch: {s} expected bool {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "integer")) {
        const want = std.fmt.parseInt(i64, expected.value, 10) catch {
            std.debug.print("\nvalid corpus fixture error: {s} has invalid integer JSON {s}\n", .{ path, expected.value });
            return error.Mismatch;
        };
        if (actual != .integer or actual.integer != want) {
            std.debug.print("\nvalid corpus mismatch: {s} expected integer {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "float")) {
        if (actual != .float) {
            std.debug.print("\nvalid corpus mismatch: {s} expected float {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }

        if (std.mem.eql(u8, expected.value, "inf")) {
            if (!std.math.isInf(actual.float) or actual.float < 0) {
                std.debug.print("\nvalid corpus mismatch: {s} expected +inf\n", .{path});
                return error.Mismatch;
            }
            return;
        }
        if (std.mem.eql(u8, expected.value, "-inf")) {
            if (!std.math.isInf(actual.float) or actual.float > 0) {
                std.debug.print("\nvalid corpus mismatch: {s} expected -inf\n", .{path});
                return error.Mismatch;
            }
            return;
        }
        if (std.mem.eql(u8, expected.value, "nan")) {
            if (!std.math.isNan(actual.float)) {
                std.debug.print("\nvalid corpus mismatch: {s} expected nan\n", .{path});
                return error.Mismatch;
            }
            return;
        }

        const want = std.fmt.parseFloat(f64, expected.value) catch {
            std.debug.print("\nvalid corpus fixture error: {s} has invalid float JSON {s}\n", .{ path, expected.value });
            return error.Mismatch;
        };
        if (actual.float != want or std.math.signbit(actual.float) != std.math.signbit(want)) {
            std.debug.print("\nvalid corpus mismatch: {s} expected float {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "datetime")) {
        var actual_buf: [64]u8 = undefined;
        var expected_buf: [64]u8 = undefined;
        if (actual != .offset_datetime or !std.mem.eql(u8, formatOffsetDateTime(&actual_buf, actual.offset_datetime), normalizeTemporalValue(&expected_buf, expected.value))) {
            std.debug.print("\nvalid corpus mismatch: {s} expected datetime {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "datetime-local")) {
        var actual_buf: [64]u8 = undefined;
        var expected_buf: [64]u8 = undefined;
        if (actual != .local_datetime or !std.mem.eql(u8, formatLocalDateTime(&actual_buf, actual.local_datetime), normalizeTemporalValue(&expected_buf, expected.value))) {
            std.debug.print("\nvalid corpus mismatch: {s} expected local datetime {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "date-local")) {
        var buf: [16]u8 = undefined;
        if (actual != .local_date or !std.mem.eql(u8, formatLocalDate(&buf, actual.local_date), expected.value)) {
            std.debug.print("\nvalid corpus mismatch: {s} expected local date {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "time-local")) {
        var actual_buf: [24]u8 = undefined;
        var expected_buf: [24]u8 = undefined;
        if (actual != .local_time or !std.mem.eql(u8, formatLocalTime(&actual_buf, actual.local_time), normalizeTemporalValue(&expected_buf, expected.value))) {
            std.debug.print("\nvalid corpus mismatch: {s} expected local time {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    std.debug.print("\nvalid corpus fixture error: {s} has unsupported type {s}\n", .{ path, expected.type_name });
    return error.Mismatch;
}

fn compareValue(actual: toml.Value, expected: json.Value, path: []const u8) CompareError!void {
    if (typedScalar(expected)) |scalar| {
        return compareScalar(actual, scalar, path);
    }

    switch (expected) {
        .array => |expected_array| {
            if (actual != .array) {
                std.debug.print("\nvalid corpus mismatch: {s} expected array\n", .{path});
                return error.Mismatch;
            }
            if (actual.array.items.len != expected_array.items.len) {
                std.debug.print(
                    "\nvalid corpus mismatch: {s} expected array len {d}, got {d}\n",
                    .{ path, expected_array.items.len, actual.array.items.len },
                );
                return error.Mismatch;
            }

            for (expected_array.items, actual.array.items, 0..) |expected_item, actual_item, index| {
                var child_buf: [256]u8 = undefined;
                try compareValue(actual_item, expected_item, makeIndexPath(&child_buf, path, index));
            }
        },
        .object => |expected_object| {
            if (actual != .table) {
                std.debug.print("\nvalid corpus mismatch: {s} expected table/object\n", .{path});
                return error.Mismatch;
            }
            if (actual.table.count() != expected_object.count()) {
                std.debug.print(
                    "\nvalid corpus mismatch: {s} expected object field count {d}, got {d}\n",
                    .{ path, expected_object.count(), actual.table.count() },
                );
                return error.Mismatch;
            }

            var it = expected_object.iterator();
            while (it.next()) |entry| {
                const actual_value = actual.table.get(entry.key_ptr.*) orelse {
                    std.debug.print("\nvalid corpus mismatch: {s} missing key {s}\n", .{ path, entry.key_ptr.* });
                    return error.Mismatch;
                };
                var child_buf: [256]u8 = undefined;
                try compareValue(actual_value, entry.value_ptr.*, makeChildPath(&child_buf, path, entry.key_ptr.*));
            }
        },
        else => {
            std.debug.print("\nvalid corpus fixture error: {s} contains unsupported JSON shape\n", .{path});
            return error.Mismatch;
        },
    }
}

fn compareRootTable(root: *toml.Table, expected: json.Value, entry: []const u8) CompareError!void {
    return compareValue(.{ .table = root }, expected, entry);
}

fn runValidCorpus() !void {
    const gpa = std.testing.allocator;
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    var checked: usize = 0;
    var failures: usize = 0;

    while (lines.next()) |raw_line| {
        const entry = std.mem.trim(u8, raw_line, " \t\r");
        if (entry.len == 0 or !std.mem.endsWith(u8, entry, ".toml")) continue;
        if (!std.mem.startsWith(u8, entry, "valid/")) continue;
        checked += 1;

        const path = try std.fs.path.join(gpa, &.{ "test", entry });
        defer gpa.free(path);

        const src = try readTestFile(gpa, path);
        defer gpa.free(src);

        var err: toml.ErrorInfo = .{};
        const root = toml.parseSlice(gpa, src, &err) catch |e| {
            if (e == error.OutOfMemory) return e;
            failures += 1;
            if (failures <= max_reported_failures) {
                std.debug.print("\nvalid corpus failed: {s} at {d}:{d}: {s}\n", .{ entry, err.line, err.col, err.message() });
            }
            continue;
        };
        defer toml.deinit(root, gpa);

        const json_path = try std.fmt.allocPrint(gpa, "test/{s}.json", .{entry[0 .. entry.len - ".toml".len]});
        defer gpa.free(json_path);

        const json_src = readTestFile(gpa, json_path) catch |e| {
            if (e == error.OutOfMemory) return e;
            failures += 1;
            if (failures <= max_reported_failures) {
                std.debug.print("\nvalid corpus missing JSON fixture: {s}\n", .{entry});
            }
            continue;
        };
        defer gpa.free(json_src);

        var expected = json.parseFromSlice(json.Value, gpa, json_src, .{}) catch |e| {
            failures += 1;
            if (failures <= max_reported_failures) {
                std.debug.print("\nvalid corpus bad JSON fixture: {s} ({s})\n", .{ entry, @errorName(e) });
            }
            continue;
        };
        defer expected.deinit();

        compareRootTable(root, expected.value, entry) catch {
            failures += 1;
        };
    }

    if (failures != 0) {
        std.debug.print(
            "\ncorpus summary (valid): checked={d}, failures={d}, reported={d}\n",
            .{ checked, failures, @min(failures, max_reported_failures) },
        );
        return error.TestUnexpectedResult;
    }
}

fn runInvalidCorpus() !void {
    const gpa = std.testing.allocator;
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    var checked: usize = 0;
    var failures: usize = 0;

    while (lines.next()) |raw_line| {
        const entry = std.mem.trim(u8, raw_line, " \t\r");
        if (entry.len == 0 or !std.mem.endsWith(u8, entry, ".toml")) continue;
        if (!std.mem.startsWith(u8, entry, "invalid/")) continue;
        checked += 1;

        const path = try std.fs.path.join(gpa, &.{ "test", entry });
        defer gpa.free(path);

        const src = try readTestFile(gpa, path);
        defer gpa.free(src);

        var err: toml.ErrorInfo = .{};
        const parsed = toml.parseSlice(gpa, src, &err);

        if (parsed) |root| {
            toml.deinit(root, gpa);
            failures += 1;
            if (failures <= max_reported_failures) {
                std.debug.print("\ninvalid corpus unexpectedly parsed: {s}\n", .{entry});
            }
        } else |e| switch (e) {
            error.ParseFailed => {},
            error.OutOfMemory => return e,
        }
    }

    if (failures != 0) {
        std.debug.print(
            "\ncorpus summary (invalid): checked={d}, failures={d}, reported={d}\n",
            .{ checked, failures, @min(failures, max_reported_failures) },
        );
        return error.TestUnexpectedResult;
    }
}

test "toml-test valid corpus parses and matches json" {
    try runValidCorpus();
}

test "toml-test invalid corpus rejects" {
    try runInvalidCorpus();
}