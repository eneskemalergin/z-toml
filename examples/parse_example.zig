//! Parses a TOML file and prints it as typed JSON (toml-test format).
//!
//! Usage: zig build example        # parses examples/example.toml
const std = @import("std");
const toml = @import("toml");
const Io = std.Io;
const temporal = toml.temporal;

fn writeIndent(writer: anytype, depth: usize) anyerror!void {
    for (0..depth) |_| {
        try writer.writeAll("  ");
    }
}

fn writeTypedScalar(writer: anytype, type_name: []const u8, value: []const u8, depth: usize) anyerror!void {
    try writer.writeAll("{\n");
    try writeIndent(writer, depth + 1);
    try writer.print("\"type\": \"{s}\",\n", .{type_name});
    try writeIndent(writer, depth + 1);
    try writer.print("\"value\": \"{s}\"\n", .{value});
    try writeIndent(writer, depth);
    try writer.writeAll("}");
}

fn writeArray(writer: anytype, arr: *toml.Array, depth: usize) anyerror!void {
    if (arr.items.len == 0) {
        try writer.writeAll("[]");
        return;
    }

    try writer.writeAll("[\n");
    for (arr.items, 0..) |item, index| {
        try writeIndent(writer, depth + 1);
        try writeValue(writer, item, depth + 1);
        if (index + 1 != arr.items.len) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writeIndent(writer, depth);
    try writer.writeAll("]");
}

fn writeTable(writer: anytype, table: *toml.Table, depth: usize) anyerror!void {
    if (table.count() == 0) {
        try writer.writeAll("{}");
        return;
    }

    try writer.writeAll("{\n");
    for (table.keys(), table.values(), 0..) |key, value, index| {
        try writeIndent(writer, depth + 1);
        try writer.print("\"{s}\": ", .{key});
        try writeValue(writer, value, depth + 1);
        if (index + 1 != table.count()) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writeIndent(writer, depth);
    try writer.writeAll("}");
}

fn writeValue(writer: anytype, value: toml.Value, depth: usize) anyerror!void {
    switch (value) {
        .string => |s| try writeTypedScalar(writer, "string", s, depth),
        .integer => |v| {
            var buf: [32]u8 = undefined;
            try writeTypedScalar(writer, "integer", std.fmt.bufPrint(&buf, "{d}", .{v.value}) catch "", depth);
        },
        .float => |v| {
            if (std.math.isNan(v)) {
                try writeTypedScalar(writer, "float", "nan", depth);
            } else if (std.math.isInf(v)) {
                try writeTypedScalar(writer, "float", if (v < 0) "-inf" else "inf", depth);
            } else {
                var buf: [64]u8 = undefined;
                try writeTypedScalar(writer, "float", std.fmt.bufPrint(&buf, "{d}", .{v}) catch "", depth);
            }
        },
        .boolean => |v| try writeTypedScalar(writer, "bool", if (v) "true" else "false", depth),
        .local_date => |v| {
            var buf: [16]u8 = undefined;
            try writeTypedScalar(writer, "date-local", temporal.formatLocalDate(&buf, v), depth);
        },
        .local_time => |v| {
            var buf: [24]u8 = undefined;
            try writeTypedScalar(writer, "time-local", temporal.formatLocalTime(&buf, v), depth);
        },
        .local_datetime => |v| {
            var buf: [48]u8 = undefined;
            try writeTypedScalar(writer, "datetime-local", temporal.formatLocalDateTime(&buf, v), depth);
        },
        .offset_datetime => |v| {
            var buf: [64]u8 = undefined;
            try writeTypedScalar(writer, "datetime", temporal.formatOffsetDateTime(&buf, v), depth);
        },
        .array => |arr| try writeArray(writer, arr, depth),
        .table => |table| try writeTable(writer, table, depth),
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    const input_path = if (args.len > 1) args[1] else "examples/example.toml";

    const src = try std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .limited(std.math.maxInt(usize)));

    var err: toml.ErrorInfo = .{};
    const root = toml.parseSlice(allocator, src, &err) catch |parse_err| {
        std.debug.print("parse error at {d}:{d}: {s}\n", .{ err.line, err.col, err.message() });
        return parse_err;
    };
    defer toml.deinit(root, allocator);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try writeTable(stdout, root, 0);
    try stdout.writeAll("\n");
    try stdout.flush();
}
