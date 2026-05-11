//! JSON output for z-toml. Serializes a parsed `Value` tree
//! to JSON text via a recursive walker. Datetimes become ISO 8601
//! strings. NaN/Inf floats are written as `null` (JSON has no native
//! representation for them). Table key order matches TOML insertion order.

const std = @import("std");
const types = @import("../value.zig");

const Value = types.Value;

fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...7, 0xB, 0xE...0x1F => {
            try w.writeAll("\\u00");
            try w.print("{X:0>2}", .{c});
        },
        else => try w.writeByte(c),
    };
}

fn writeOffset(w: *std.Io.Writer, offset_minutes: i16) std.Io.Writer.Error!void {
    if (offset_minutes == 0) return w.writeByte('Z');
    const abs = if (offset_minutes < 0) @as(u16, @intCast(-offset_minutes)) else @as(u16, @intCast(offset_minutes));
    const sign: u8 = if (offset_minutes < 0) '-' else '+';
    try w.print("{c}{d:0>2}:{d:0>2}", .{ sign, abs / 60, abs % 60 });
}

fn writeLocalDate(w: *std.Io.Writer, d: types.LocalDate) std.Io.Writer.Error!void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}

fn writeLocalTime(w: *std.Io.Writer, t: types.LocalTime) std.Io.Writer.Error!void {
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
    if (t.nanosecond != 0) {
        var digits_buf: [9]u8 = undefined;
        const digits = std.fmt.bufPrint(&digits_buf, "{d:0>9}", .{t.nanosecond}) catch "";
        var end = digits.len;
        while (end > 0 and digits[end - 1] == '0') end -= 1;
        try w.print(".{s}", .{digits[0..end]});
    }
}

/// Serialize `value` as JSON to `w`.
///
/// NaN/Inf floats become JSON `null`.
/// Datetimes are RFC 3339 / ISO 8601 strings.
/// Table key order matches TOML insertion order.
pub fn toJson(value: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (value) {
        .string => |s| {
            try w.writeByte('"');
            try writeJsonString(w, s);
            try w.writeByte('"');
        },
        .integer => |iv| try w.print("{}", .{iv.value}),
        .float => |f| {
            if (std.math.isNan(f) or std.math.isInf(f))
                try w.writeAll("null")
            else
                try w.print("{}", .{f});
        },
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .offset_datetime => |dt| {
            try w.writeByte('"');
            try writeLocalDate(w, dt.date);
            try w.writeByte('T');
            try writeLocalTime(w, dt.time);
            try writeOffset(w, dt.offset_minutes);
            try w.writeByte('"');
        },
        .local_datetime => |dt| {
            try w.writeByte('"');
            try writeLocalDate(w, dt.date);
            try w.writeByte('T');
            try writeLocalTime(w, dt.time);
            try w.writeByte('"');
        },
        .local_date => |d| {
            try w.writeByte('"');
            try writeLocalDate(w, d);
            try w.writeByte('"');
        },
        .local_time => |t| {
            try w.writeByte('"');
            try writeLocalTime(w, t);
            try w.writeByte('"');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try toJson(item, w);
            }
            try w.writeByte(']');
        },
        .table => |tbl| {
            try w.writeByte('{');
            var first = true;
            var it = tbl.iterator();
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeByte('"');
                try writeJsonString(w, entry.key_ptr.*);
                try w.writeByte('"');
                try w.writeByte(':');
                try toJson(entry.value_ptr.*, w);
            }
            try w.writeByte('}');
        },
    }
}
