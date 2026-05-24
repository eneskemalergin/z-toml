const std = @import("std");
const json = std.json;
const toml = @import("toml");
const support = @import("support.zig");

const AccessStep = union(enum) {
    key: []const u8,
    index: usize,
};

fn floatsEqual(a: f64, b: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    return a == b;
}

fn valuesEqual(a: toml.Value, b: toml.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |lhs| std.mem.eql(u8, lhs, b.string),
        .integer => |lhs| lhs.value == b.integer.value and lhs.base == b.integer.base,
        .float => |lhs| floatsEqual(lhs, b.float),
        .boolean => |lhs| lhs == b.boolean,
        .offset_datetime => |lhs| std.meta.eql(lhs, b.offset_datetime),
        .local_datetime => |lhs| std.meta.eql(lhs, b.local_datetime),
        .local_date => |lhs| std.meta.eql(lhs, b.local_date),
        .local_time => |lhs| std.meta.eql(lhs, b.local_time),
        .array => |lhs| blk: {
            if (lhs.items.len != b.array.items.len) break :blk false;
            for (lhs.items, b.array.items) |l_item, r_item| {
                if (!valuesEqual(l_item, r_item)) break :blk false;
            }
            break :blk true;
        },
        .table => |lhs| tablesEqual(lhs, b.table),
    };
}

fn tablesEqual(a: *const toml.Table, b: *const toml.Table) bool {
    if (a.count() != b.count()) return false;

    var it = a.iterator();
    while (it.next()) |entry| {
        const rhs = b.get(entry.key_ptr.*) orelse return false;
        if (!valuesEqual(entry.value_ptr.*, rhs)) return false;
    }
    return true;
}

fn getOwnedAtPath(root: *toml.Table, path: []const AccessStep) ?toml.Value {
    var current = toml.Value{ .table = root };

    for (path) |step| {
        switch (step) {
            .key => |key| switch (current) {
                .table => |tbl| current = tbl.get(key) orelse return null,
                else => return null,
            },
            .index => |index| switch (current) {
                .array => |arr| {
                    if (index >= arr.items.len) return null;
                    current = arr.items[index];
                },
                else => return null,
            },
        }
    }

    return current;
}

fn getJsonAtPath(root: json.Value, path: []const AccessStep) ?json.Value {
    var current = root;

    for (path) |step| {
        switch (step) {
            .key => |key| switch (current) {
                .object => |obj| current = obj.get(key) orelse return null,
                else => return null,
            },
            .index => |index| switch (current) {
                .array => |arr| {
                    if (index >= arr.items.len) return null;
                    current = arr.items[index];
                },
                else => return null,
            },
        }
    }

    return current;
}

fn getViewAtPath(root: *toml.TableView, path: []const AccessStep) ?toml.ValueView {
    var current = toml.ValueView{ .table = root };

    for (path) |step| {
        switch (step) {
            .key => |key| switch (current) {
                .table => |tbl| current = tbl.get(key) orelse return null,
                else => return null,
            },
            .index => |index| switch (current) {
                .array => |arr| {
                    if (index >= arr.items.len) return null;
                    current = arr.items[index];
                },
                else => return null,
            },
        }
    }

    return current;
}

fn expectOwnedString(root: *toml.Table, path: []const AccessStep, expected: []const u8) !void {
    const value = getOwnedAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectViewString(root: *toml.TableView, path: []const AccessStep, expected: []const u8) !void {
    const value = getViewAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectOwnedInt(root: *toml.Table, path: []const AccessStep, expected: i64) !void {
    const value = getOwnedAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .integer);
    try std.testing.expectEqual(expected, value.integer.value);
}

fn expectViewInt(root: *toml.TableView, path: []const AccessStep, expected: i64) !void {
    const value = getViewAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .integer);
    try std.testing.expectEqual(expected, value.integer.value);
}

fn expectOwnedBool(root: *toml.Table, path: []const AccessStep, expected: bool) !void {
    const value = getOwnedAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .boolean);
    try std.testing.expectEqual(expected, value.boolean);
}

fn expectOwnedFloat(root: *toml.Table, path: []const AccessStep, expected: f64) !void {
    const value = getOwnedAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .float);
    try std.testing.expectApproxEqAbs(expected, value.float, 1e-9);
}

fn expectViewFloat(root: *toml.TableView, path: []const AccessStep, expected: f64) !void {
    const value = getViewAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .float);
    try std.testing.expectApproxEqAbs(expected, value.float, 1e-9);
}

fn expectJsonString(root: json.Value, path: []const AccessStep, expected: []const u8) !void {
    const value = getJsonAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectJsonInt(root: json.Value, path: []const AccessStep, expected: i64) !void {
    const value = getJsonAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .integer);
    try std.testing.expectEqual(expected, value.integer);
}

fn expectJsonBool(root: json.Value, path: []const AccessStep, expected: bool) !void {
    const value = getJsonAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .bool);
    try std.testing.expectEqual(expected, value.bool);
}

fn expectJsonFloat(root: json.Value, path: []const AccessStep, expected: f64) !void {
    const value = getJsonAtPath(root, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value == .float);
    try std.testing.expectApproxEqAbs(expected, value.float, 1e-9);
}

fn toOwnedJson(gpa: std.mem.Allocator, root: *toml.Table) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.toJson(.{ .table = root }, &out.writer);
    return try out.toOwnedSlice();
}

fn writeTomlOwned(gpa: std.mem.Allocator, value: toml.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.writeToml(value, &out.writer);
    return try out.toOwnedSlice();
}

fn writeProfileOwned(gpa: std.mem.Allocator, value: toml.Value, profile: toml.OutputProfile, hints: ?*toml.FormatHints) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.writeTomlWithProfile(value, &out.writer, profile, hints, gpa);
    return try out.toOwnedSlice();
}

fn writeViewOwned(gpa: std.mem.Allocator, root: *toml.TableView, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.writeTomlView(.{ .table = root }, &out.writer, .{}, gpa, input);
    return try out.toOwnedSlice();
}

fn rewriteValueOwned(gpa: std.mem.Allocator, input: []const u8, path: []const toml.PathSegment, value: toml.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.rewriteValueAtPath(input, path, value, &out.writer, gpa);
    return try out.toOwnedSlice();
}

fn setValueOwned(gpa: std.mem.Allocator, input: []const u8, path: []const toml.PathSegment, value: toml.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.setValueAtPath(input, path, value, &out.writer, gpa);
    return try out.toOwnedSlice();
}

fn rewriteBatchOwned(gpa: std.mem.Allocator, input: []const u8, ops: []const toml.RewriteOperation, options: toml.RewriteOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try toml.rewriteValues(input, ops, &out.writer, options, gpa);
    return try out.toOwnedSlice();
}

fn expectJsonExportMatches(
    gpa: std.mem.Allocator,
    root: *toml.Table,
    comptime validate_json: fn (json.Value) anyerror!void,
) !void {
    const actual_json = try toOwnedJson(gpa, root);
    defer gpa.free(actual_json);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const actual = try json.parseFromSlice(json.Value, aa, actual_json, .{});
    try validate_json(actual.value);
}

fn expectReparseMatches(gpa: std.mem.Allocator, original: *toml.Table, written: []const u8) !void {
    const reparsed = try toml.parseSlice(gpa, written, null);
    defer toml.deinit(reparsed, gpa);
    try std.testing.expect(tablesEqual(original, reparsed));
}

fn expectAllProfilesRoundtrip(gpa: std.mem.Allocator, root: *toml.Table, label: []const u8) !void {
    inline for ([_]toml.OutputProfile{ .compact, .preserve, .canonical }) |profile| {
        const written = try writeProfileOwned(gpa, .{ .table = root }, profile, null);
        defer gpa.free(written);
        const reparsed = try toml.parseSlice(gpa, written, null);
        defer toml.deinit(reparsed, gpa);
        if (!tablesEqual(root, reparsed)) {
            std.debug.print("profile roundtrip mismatch: fixture={s} profile={s}\n{s}\n", .{ label, @tagName(profile), written });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectFaithfulExactRoundtrip(gpa: std.mem.Allocator, src: []const u8) !void {
    var string_styles: toml.HintMap(toml.StringStyle) = .empty;
    var key_styles: toml.KeyStyleMap = .empty;
    var key_lexemes: toml.KeyLexemeMap = .empty;
    var value_lexemes: toml.ValueLexemeMap = .empty;
    var table_syntax: toml.TableSyntaxMap = .empty;
    var comments: toml.CommentMap = .empty;
    var document: toml.DocumentHints = .{};
    var hints: toml.FormatHints = .{
        .string_styles = &string_styles,
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

    const written = try writeProfileOwned(gpa, .{ .table = root }, .faithful, &hints);
    defer gpa.free(written);
    try std.testing.expectEqualStrings(src, written);
}

fn validateExampleAccessOwned(root: *toml.Table) !void {
    try expectOwnedString(root, &[_]AccessStep{.{ .key = "title" }}, "Observatory Snapshot");
    try expectOwnedBool(root, &[_]AccessStep{.{ .key = "enabled" }}, true);
    try expectOwnedFloat(root, &[_]AccessStep{.{ .key = "sample_rate" }}, 0.125);
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "location" }, .{ .key = "site" } }, "ridge-17");
    try expectOwnedFloat(root, &[_]AccessStep{ .{ .key = "location" }, .{ .key = "coordinates" }, .{ .key = "lat" } }, 39.7392);
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "events" }, .{ .index = 1 }, .{ .key = "kind" } }, "observation");
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "events" }, .{ .index = 1 }, .{ .key = "tags" }, .{ .index = 1 } }, "northern-sky");
}

fn validateExampleAccessView(root: *toml.TableView) !void {
    try expectViewString(root, &[_]AccessStep{.{ .key = "title" }}, "Observatory Snapshot");
    try expectViewFloat(root, &[_]AccessStep{.{ .key = "sample_rate" }}, 0.125);
    try expectViewString(root, &[_]AccessStep{ .{ .key = "location" }, .{ .key = "site" } }, "ridge-17");
    try expectViewString(root, &[_]AccessStep{ .{ .key = "events" }, .{ .index = 1 }, .{ .key = "kind" } }, "observation");
}

fn validateExampleJson(root: json.Value) !void {
    try expectJsonString(root, &[_]AccessStep{.{ .key = "title" }}, "Observatory Snapshot");
    try expectJsonBool(root, &[_]AccessStep{.{ .key = "enabled" }}, true);
    try expectJsonFloat(root, &[_]AccessStep{.{ .key = "sample_rate" }}, 0.125);
    try expectJsonString(root, &[_]AccessStep{ .{ .key = "location" }, .{ .key = "site" } }, "ridge-17");
    try expectJsonString(root, &[_]AccessStep{ .{ .key = "events" }, .{ .index = 1 }, .{ .key = "kind" } }, "observation");
}

fn validateProteomicsAccessOwned(root: *toml.Table) !void {
    try expectOwnedString(root, &[_]AccessStep{.{ .key = "title" }}, "Quantitative Proteomics: Cellular Response to Thermal Stress");
    try expectOwnedInt(root, &[_]AccessStep{ .{ .key = "samples" }, .{ .key = "biological_replicates" } }, 24);
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "instrument" }, .{ .key = "settings" }, .{ .key = "ionization" }, .{ .key = "source" } }, "NSI");
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "instrument" }, .{ .key = "settings" }, .{ .key = "calibration_params" }, .{ .index = 2 } }, "linear");
    try expectOwnedFloat(root, &[_]AccessStep{ .{ .key = "samples" }, .{ .key = "groups" }, .{ .key = "conditions" }, .{ .index = 2 }, .{ .key = "temperature" } }, 45.0);
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "database" }, .{ .key = "search" }, .{ .key = "scoring" }, .{ .key = "algorithm" } }, "Percolator");
}

fn validateProteomicsAccessView(root: *toml.TableView) !void {
    try expectViewString(root, &[_]AccessStep{.{ .key = "title" }}, "Quantitative Proteomics: Cellular Response to Thermal Stress");
    try expectViewInt(root, &[_]AccessStep{ .{ .key = "samples" }, .{ .key = "biological_replicates" } }, 24);
    try expectViewString(root, &[_]AccessStep{ .{ .key = "instrument" }, .{ .key = "settings" }, .{ .key = "ionization" }, .{ .key = "source" } }, "NSI");
    try expectViewFloat(root, &[_]AccessStep{ .{ .key = "samples" }, .{ .key = "groups" }, .{ .key = "conditions" }, .{ .index = 2 }, .{ .key = "temperature" } }, 45.0);
}

fn validateProteomicsJson(root: json.Value) !void {
    try expectJsonString(root, &[_]AccessStep{.{ .key = "title" }}, "Quantitative Proteomics: Cellular Response to Thermal Stress");
    try expectJsonInt(root, &[_]AccessStep{ .{ .key = "samples" }, .{ .key = "biological_replicates" } }, 24);
    try expectJsonString(root, &[_]AccessStep{ .{ .key = "instrument" }, .{ .key = "settings" }, .{ .key = "ionization" }, .{ .key = "source" } }, "NSI");
    try expectJsonString(root, &[_]AccessStep{ .{ .key = "database" }, .{ .key = "search" }, .{ .key = "scoring" }, .{ .key = "algorithm" } }, "Percolator");
    try expectJsonString(root, &[_]AccessStep{.{ .key = "analysis_timestamp" }}, "2025-04-02T09:15:00Z");
}

fn validatePyprojectAccessOwned(root: *toml.Table) !void {
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "project" }, .{ .key = "name" } }, "tomli");
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "project" }, .{ .key = "urls" }, .{ .key = "Homepage" } }, "https://github.com/hukkin/tomli");
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "build-system" }, .{ .key = "requires" }, .{ .index = 0 } }, "flit_core>=3.12,<4");
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "tool" }, .{ .key = "tox" }, .{ .key = "env" }, .{ .key = "profile" }, .{ .key = "description" } }, "run profiler (use e.g. `firefox .tox/prof/output.svg` to open)");
    try expectOwnedBool(root, &[_]AccessStep{ .{ .key = "tool" }, .{ .key = "coverage" }, .{ .key = "run" }, .{ .key = "branch" } }, true);
}

fn validatePyprojectAccessView(root: *toml.TableView) !void {
    try expectViewString(root, &[_]AccessStep{ .{ .key = "project" }, .{ .key = "name" } }, "tomli");
    try expectViewString(root, &[_]AccessStep{ .{ .key = "project" }, .{ .key = "urls" }, .{ .key = "Homepage" } }, "https://github.com/hukkin/tomli");
    try expectViewString(root, &[_]AccessStep{ .{ .key = "tool" }, .{ .key = "tox" }, .{ .key = "env" }, .{ .key = "profile" }, .{ .key = "description" } }, "run profiler (use e.g. `firefox .tox/prof/output.svg` to open)");
}

fn validatePyprojectJson(root: json.Value) !void {
    try expectJsonString(root, &[_]AccessStep{ .{ .key = "project" }, .{ .key = "name" } }, "tomli");
    try expectJsonString(root, &[_]AccessStep{ .{ .key = "project" }, .{ .key = "urls" }, .{ .key = "Homepage" } }, "https://github.com/hukkin/tomli");
    try expectJsonString(root, &[_]AccessStep{ .{ .key = "build-system" }, .{ .key = "requires" }, .{ .index = 0 } }, "flit_core>=3.12,<4");
    try expectJsonBool(root, &[_]AccessStep{ .{ .key = "tool" }, .{ .key = "coverage" }, .{ .key = "run" }, .{ .key = "branch" } }, true);
}

fn validateDocumentEndToEnd(
    gpa: std.mem.Allocator,
    toml_path: []const u8,
    comptime validate_owned: fn (*toml.Table) anyerror!void,
    comptime validate_view: fn (*toml.TableView) anyerror!void,
    comptime validate_json: fn (json.Value) anyerror!void,
) !void {
    const src = try support.readTestFile(gpa, toml_path);
    defer gpa.free(src);

    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    try validate_owned(root);
    try expectJsonExportMatches(gpa, root, validate_json);

    const written = try writeTomlOwned(gpa, .{ .table = root });
    defer gpa.free(written);
    try expectReparseMatches(gpa, root, written);
    try expectAllProfilesRoundtrip(gpa, root, toml_path);

    const view_root = try toml.parseSliceView(gpa, src, null);
    defer toml.deinitViewTable(view_root, gpa, src);
    try validate_view(view_root);

    const cloned = try toml.cloneValue(gpa, .{ .table = view_root }, src);
    defer toml.deinit(cloned.table, gpa);
    try std.testing.expect(tablesEqual(root, cloned.table));

    const view_written = try writeViewOwned(gpa, view_root, src);
    defer gpa.free(view_written);
    try expectReparseMatches(gpa, root, view_written);

    try expectFaithfulExactRoundtrip(gpa, src);
}

test "validation: example fixture survives end-to-end document flows" {
    try validateDocumentEndToEnd(
        std.testing.allocator,
        "examples/example.toml",
        validateExampleAccessOwned,
        validateExampleAccessView,
        validateExampleJson,
    );
}

test "validation: proteomics fixture survives end-to-end document flows" {
    try validateDocumentEndToEnd(
        std.testing.allocator,
        "examples/proteomics.toml",
        validateProteomicsAccessOwned,
        validateProteomicsAccessView,
        validateProteomicsJson,
    );
}

test "validation: pyproject fixture survives end-to-end document flows" {
    try validateDocumentEndToEnd(
        std.testing.allocator,
        "examples/pyproject.toml",
        validatePyprojectAccessOwned,
        validatePyprojectAccessView,
        validatePyprojectJson,
    );
}

test "validation: rewrite workflow keeps real document data accessible and uncorrupted" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "examples/example.toml");
    defer gpa.free(src);

    const sample_rate_path = [_]toml.PathSegment{.{ .key = "sample_rate" }};
    const timezone_path = [_]toml.PathSegment{ .{ .key = "location" }, .{ .key = "timezone" } };
    const batch_ops = [_]toml.RewriteOperation{
        .{ .path = &[_]toml.PathSegment{ .{ .key = "thresholds" }, .{ .key = "warning" } }, .value = .{ .integer = .{ .value = 13 } } },
        .{ .path = &[_]toml.PathSegment{ .{ .key = "events" }, .{ .index = 1 }, .{ .key = "kind" } }, .value = .{ .string = "science" } },
    };

    const rewritten_once = try rewriteValueOwned(gpa, src, &sample_rate_path, .{ .float = 0.25 });
    defer gpa.free(rewritten_once);
    const rewritten_twice = try setValueOwned(gpa, rewritten_once, &timezone_path, .{ .string = "UTC" });
    defer gpa.free(rewritten_twice);
    const rewritten_final = try rewriteBatchOwned(gpa, rewritten_twice, &batch_ops, .{ .mode = .create_or_replace });
    defer gpa.free(rewritten_final);

    const root = try toml.parseSlice(gpa, rewritten_final, null);
    defer toml.deinit(root, gpa);

    try expectOwnedString(root, &[_]AccessStep{.{ .key = "title" }}, "Observatory Snapshot");
    try expectOwnedBool(root, &[_]AccessStep{.{ .key = "enabled" }}, true);
    try expectOwnedFloat(root, &[_]AccessStep{.{ .key = "sample_rate" }}, 0.25);
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "location" }, .{ .key = "site" } }, "ridge-17");
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "location" }, .{ .key = "timezone" } }, "UTC");
    try expectOwnedInt(root, &[_]AccessStep{ .{ .key = "thresholds" }, .{ .key = "warning" } }, 13);
    try expectOwnedInt(root, &[_]AccessStep{ .{ .key = "thresholds" }, .{ .key = "critical" } }, 18);
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "events" }, .{ .index = 0 }, .{ .key = "kind" } }, "calibration");
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "events" }, .{ .index = 1 }, .{ .key = "kind" } }, "science");
    try expectOwnedString(root, &[_]AccessStep{ .{ .key = "events" }, .{ .index = 1 }, .{ .key = "tags" }, .{ .index = 1 } }, "northern-sky");

    const written = try writeTomlOwned(gpa, .{ .table = root });
    defer gpa.free(written);
    try expectReparseMatches(gpa, root, written);
}
