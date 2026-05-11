//! Corpus-backed tests: validates the parser against the toml-lang/toml-test
//! manifest (215 valid + 467 invalid files). Also runs `parseInto` sweeps and
//! an exact-field fixture test against spec-example-1.

const std = @import("std");
const toml = @import("toml");
const json = std.json;
const temporal = toml.temporal;
const support = @import("support.zig");

const manifest = @embedFile("files-toml-1.1.0");
const max_reported_failures = 20;
const CompareError = error{Mismatch};
const TypedScalar = struct {
    type_name: []const u8,
    value: []const u8,
};

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

fn normalizeTemporalValue(buf: []u8, value: []const u8) []const u8 {
    const dot_index = std.mem.indexOfScalar(u8, value, '.') orelse return value;

    var end = dot_index + 1;
    while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
    if (end == dot_index + 1) return value;

    var trimmed_end = end;
    while (trimmed_end > dot_index + 1 and value[trimmed_end - 1] == '0') : (trimmed_end -= 1) {}
    if (trimmed_end == end) return value;

    return std.fmt.bufPrint(buf, "{s}{s}", .{ value[0..trimmed_end], value[end..] }) catch value;
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
        if (actual != .integer or actual.integer.value != want) {
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
        if (actual != .offset_datetime or !std.mem.eql(u8, temporal.formatOffsetDateTime(&actual_buf, actual.offset_datetime), normalizeTemporalValue(&expected_buf, expected.value))) {
            std.debug.print("\nvalid corpus mismatch: {s} expected datetime {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "datetime-local")) {
        var actual_buf: [64]u8 = undefined;
        var expected_buf: [64]u8 = undefined;
        if (actual != .local_datetime or !std.mem.eql(u8, temporal.formatLocalDateTime(&actual_buf, actual.local_datetime), normalizeTemporalValue(&expected_buf, expected.value))) {
            std.debug.print("\nvalid corpus mismatch: {s} expected local datetime {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "date-local")) {
        var buf: [16]u8 = undefined;
        if (actual != .local_date or !std.mem.eql(u8, temporal.formatLocalDate(&buf, actual.local_date), expected.value)) {
            std.debug.print("\nvalid corpus mismatch: {s} expected local date {s}\n", .{ path, expected.value });
            return error.Mismatch;
        }
        return;
    }

    if (std.mem.eql(u8, expected.type_name, "time-local")) {
        var actual_buf: [24]u8 = undefined;
        var expected_buf: [24]u8 = undefined;
        if (actual != .local_time or !std.mem.eql(u8, temporal.formatLocalTime(&actual_buf, actual.local_time), normalizeTemporalValue(&expected_buf, expected.value))) {
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

        const src = try support.readTestFile(gpa, path);
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

        const json_src = support.readTestFile(gpa, json_path) catch |e| {
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

        const src = try support.readTestFile(gpa, path);
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

// ─── parseInto corpus sweeps ──────────────────────────────────────────────────
//
// These tests run the typed API across the full toml-test corpus, which is a
// much harder stress test than the handwritten unit tests:
//   * valid sweep: every valid file must not produce ParseFailed
//   * invalid sweep: every invalid file must produce ParseFailed (not MissingField
//     or TypeMismatch, which would mean the file parsed silently)
//
// We use an empty struct `struct {}` so mapTable immediately returns without
// field iteration. The goal is not to verify field values here but to verify
// that the temp-arena allocation/teardown inside parseInto is correct for all
// 215 valid inputs and that error propagation is correct for all 467 invalid
// inputs. A separate test below verifies actual field values on a real file.

fn runParseIntoValidSweep() !void {
    const Empty = struct {};
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

        const src = try support.readTestFile(gpa, path);
        defer gpa.free(src);

        var err: toml.ErrorInfo = .{};
        _ = toml.parseInto(Empty, gpa, src, &err) catch |e| {
            if (e == error.OutOfMemory) return e;
            // MissingField / TypeMismatch are fine: we have no fields.
            // ParseFailed on a valid file is a real failure.
            if (e == error.ParseFailed) {
                failures += 1;
                if (failures <= max_reported_failures) {
                    std.debug.print(
                        "\nparseInto valid sweep: ParseFailed on {s} at {d}:{d}: {s}\n",
                        .{ entry, err.line, err.col, err.message() },
                    );
                }
            }
        };
    }

    if (failures != 0) {
        std.debug.print(
            "\nparseInto valid sweep: checked={d}, failures={d}\n",
            .{ checked, failures },
        );
        return error.TestUnexpectedResult;
    }
}

fn runParseIntoInvalidSweep() !void {
    const Empty = struct {};
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

        const src = try support.readTestFile(gpa, path);
        defer gpa.free(src);

        var err: toml.ErrorInfo = .{};
        if (toml.parseInto(Empty, gpa, src, &err)) |_| {
            // Parsed successfully: invalid file was not rejected.
            failures += 1;
            if (failures <= max_reported_failures) {
                std.debug.print("\nparseInto invalid sweep: unexpectedly succeeded on {s}\n", .{entry});
            }
        } else |e| switch (e) {
            error.ParseFailed => {}, // correct
            error.MissingField, error.TypeMismatch => {
                // These come from the mapping layer, not the parser, which
                // means the invalid TOML was parsed without error. That is a
                // parser bug: same failure class as above.
                failures += 1;
                if (failures <= max_reported_failures) {
                    std.debug.print(
                        "\nparseInto invalid sweep: {s} on invalid file {s} (parser should have rejected it)\n",
                        .{ @errorName(e), entry },
                    );
                }
            },
            error.OutOfMemory => return e,
        }
    }

    if (failures != 0) {
        std.debug.print(
            "\nparseInto invalid sweep: checked={d}, failures={d}\n",
            .{ checked, failures },
        );
        return error.TestUnexpectedResult;
    }
}

test "parseInto valid corpus: no ParseFailed on any valid file" {
    try runParseIntoValidSweep();
}

test "parseInto invalid corpus: ParseFailed on every invalid file" {
    try runParseIntoInvalidSweep();
}

// ─── parseInto corpus fixture: spec-example-1 ────────────────────────────────
//
// Maps the canonical TOML spec example from disk onto a precisely-typed struct
// and asserts every field value. This exercises the full mapping layer:
// nested structs, slices, OffsetDateTime, bool, all against a real corpus file.

test "parseInto corpus fixture: spec-example-1 fields are correct" {
    const ServerInfo = struct { ip: []const u8, dc: []const u8 };
    const Servers = struct { alpha: ServerInfo, beta: ServerInfo };
    const Database = struct {
        server: []const u8,
        ports: []i64,
        connection_max: i64,
        enabled: bool,
    };
    const Owner = struct {
        name: []const u8,
        dob: toml.OffsetDateTime,
    };
    const Config = struct {
        title: []const u8,
        owner: Owner,
        database: Database,
        servers: Servers,
        // clients.data is a mixed-type nested array: not mappable to a typed
        // slice, so we skip it by making the whole section optional.
        clients: ?struct { hosts: [][]const u8 } = null,
    };

    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "test/valid/spec-example-1.toml");
    defer gpa.free(src);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var err: toml.ErrorInfo = .{};
    const cfg = toml.parseInto(Config, arena.allocator(), src, &err) catch |e| {
        std.debug.print("parseInto failed at {d}:{d}: {s}\n", .{ err.line, err.col, err.message() });
        return e;
    };

    try std.testing.expectEqualStrings("TOML Example", cfg.title);

    try std.testing.expectEqualStrings("Lance Uppercut", cfg.owner.name);
    try std.testing.expectEqual(@as(u16, 1979), cfg.owner.dob.date.year);
    try std.testing.expectEqual(@as(u8, 5), cfg.owner.dob.date.month);
    try std.testing.expectEqual(@as(u8, 27), cfg.owner.dob.date.day);
    try std.testing.expectEqual(@as(i16, -8 * 60), cfg.owner.dob.offset_minutes);

    try std.testing.expectEqualStrings("192.168.1.1", cfg.database.server);
    try std.testing.expectEqual(@as(usize, 3), cfg.database.ports.len);
    try std.testing.expectEqual(@as(i64, 8001), cfg.database.ports[0]);
    try std.testing.expectEqual(@as(i64, 8002), cfg.database.ports[2]);
    try std.testing.expectEqual(@as(i64, 5000), cfg.database.connection_max);
    try std.testing.expectEqual(true, cfg.database.enabled);

    try std.testing.expectEqualStrings("10.0.0.1", cfg.servers.alpha.ip);
    try std.testing.expectEqualStrings("eqdc10", cfg.servers.alpha.dc);
    try std.testing.expectEqualStrings("10.0.0.2", cfg.servers.beta.ip);
}
