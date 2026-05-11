//! TOML serializer for z-toml. Serializes a parsed `Value` tree
//! back to `.toml` text. Uses `[header]` and `[[aot]]` syntax for
//! context navigation (not dotted keys), producing readable TOML
//! that always round-trips correctly.

const std = @import("std");
const types = @import("../value.zig");

const Value = types.Value;
const Table = types.Table;
const Allocator = std.mem.Allocator;

/// Options controlling writeToml output formatting.
pub const WriteOptions = struct {
    /// Sort keys alphabetically within each table (canonical order).
    sort_keys: bool = false,
    /// Use `[header]` syntax for sub-tables even when all values are scalars.
    /// Default (`false`) inlines scalar-only sub-tables as `key = { ... }`.
    prefer_headers: bool = false,
    /// Use `\e` escape for ESC (0x1B) instead of `\u001B`.
    use_escape_e: bool = false,
};

// ─── Key quoting ───────────────────────────────────────────────────────────────

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-')
            return false;
    }
    return true;
}

fn writeQuoted(w: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    if (isBareKey(key)) return w.writeAll(key);
    if (std.mem.indexOfScalar(u8, key, '\'') == null) {
        try w.writeByte('\'');
        try w.writeAll(key);
        return w.writeByte('\'');
    }
    try w.writeByte('"');
    for (key) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeDottedPrefix(w: *std.Io.Writer, path: [][]const u8) std.Io.Writer.Error!void {
    for (path, 0..) |part, i| {
        if (i > 0) try w.writeByte('.');
        try writeQuoted(w, part);
    }
}

// ─── Value writers ─────────────────────────────────────────────────────────────

fn writeBasicString(w: *std.Io.Writer, s: []const u8, opts: WriteOptions) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0x08 => try w.writeAll("\\b"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        0x0C => try w.writeAll("\\f"),
        '\r' => try w.writeAll("\\r"),
        0x1B => {
            if (opts.use_escape_e) {
                try w.writeAll("\\e");
            } else {
                try w.writeAll("\\u001B");
            }
        },
        0...7, 0xB, 0xE...0x1A, 0x1C...0x1F, 0x7F => {
            try w.writeAll("\\u00");
            try w.print("{X:0>2}", .{c});
        },
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
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
        const digits = std.fmt.bufPrint(&digits_buf, "{d:0>9}", .{t.nanosecond}) catch return;
        var end = digits.len;
        while (end > 0 and digits[end - 1] == '0') end -= 1;
        try w.print(".{s}", .{digits[0..end]});
    }
}

fn writeValue(w: *std.Io.Writer, val: Value, opts: WriteOptions) std.Io.Writer.Error!void {
    switch (val) {
        .string => |s| try writeBasicString(w, s, opts),
        .integer => |i| try w.print("{}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) return w.writeAll("nan");
            if (std.math.isInf(f)) {
                if (f < 0.0) return w.writeAll("-inf");
                return w.writeAll("inf");
            }
            var buf: [64]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "0.0";
            if (std.mem.indexOfAny(u8, formatted, ".eE") == null) {
                try w.writeAll(formatted);
                try w.writeAll(".0");
            } else {
                try w.writeAll(formatted);
            }
        },
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .offset_datetime => |dt| {
            try writeLocalDate(w, dt.date);
            try w.writeByte('T');
            try writeLocalTime(w, dt.time);
            try writeOffset(w, dt.offset_minutes);
        },
        .local_datetime => |dt| {
            try writeLocalDate(w, dt.date);
            try w.writeByte('T');
            try writeLocalTime(w, dt.time);
        },
        .local_date => |d| try writeLocalDate(w, d),
        .local_time => |t| try writeLocalTime(w, t),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try writeValue(w, item, opts);
            }
            try w.writeByte(']');
        },
        .table => |tbl| {
            try w.writeByte('{');
            var first = true;
            var it = tbl.iterator();
            while (it.next()) |entry| {
                if (!first) try w.writeAll(", ");
                first = false;
                try writeQuoted(w, entry.key_ptr.*);
                try w.writeAll(" = ");
                try writeValue(w, entry.value_ptr.*, opts);
            }
            try w.writeByte('}');
        },
    }
}

// ─── Table introspection ───────────────────────────────────────────────────────

fn isInlineTable(tbl: *Table) bool {
    var it = tbl.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .table, .array => return false,
            else => {},
        }
    }
    return true;
}

fn isArrayOfTables(val: Value) bool {
    if (val != .array) return false;
    const arr = val.array;
    if (arr.items.len == 0) return false;
    for (arr.items) |item| {
        if (item != .table) return false;
    }
    return true;
}

// ─── Key ordering ──────────────────────────────────────────────────────────────

fn keyLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Collect all keys from `tbl`. Sorts alphabetically when `sort_keys`.
fn keysOf(tbl: *Table, opts: WriteOptions, gpa: Allocator) Allocator.Error![][]const u8 {
    const count = tbl.count();
    if (count == 0) return &.{};
    const keys = try gpa.alloc([]const u8, count);
    var i: usize = 0;
    var it = tbl.iterator();
    while (it.next()) |entry| {
        keys[i] = entry.key_ptr.*;
        i += 1;
    }
    if (opts.sort_keys) std.sort.block([]const u8, keys, {}, keyLessThan);
    return keys;
}

// ─── Core serialization ────────────────────────────────────────────────────────

fn writeKV(w: *std.Io.Writer, key: []const u8, val: Value, opts: WriteOptions) std.Io.Writer.Error!void {
    try writeQuoted(w, key);
    try w.writeAll(" = ");
    try writeValue(w, val, opts);
    try w.writeByte('\n');
}

/// Write the contents of `tbl`. When `header` is true and `path` is
/// non-empty, emit `[path]` before content. AOT element content is
/// written with `header = false` (already in context from `[[header]]`).
fn writeTableInner(
    w: *std.Io.Writer,
    tbl: *Table,
    path: [][]const u8,
    emit_header: bool,
    opts: WriteOptions,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    var path_buf: [128][]const u8 = undefined;
    const keys = try keysOf(tbl, opts, gpa);
    defer if (keys.len > 0) gpa.free(keys);

    if (emit_header and path.len > 0) {
        try w.writeByte('[');
        try writeDottedPrefix(w, path);
        try w.writeAll("]\n");
    }

    // Pass 1: scalars, arrays, and inline tables
    for (keys) |key| {
        const val = tbl.get(key).?;
        switch (val) {
            .string, .integer, .float, .boolean,
            .offset_datetime, .local_datetime, .local_date, .local_time => {
                try writeKV(w, key, val, opts);
            },
            .array => {
                if (!isArrayOfTables(val)) {
                    try writeKV(w, key, val, opts);
                }
            },
            .table => |sub_tbl| {
                if (!opts.prefer_headers and isInlineTable(sub_tbl)) {
                    try writeKV(w, key, val, opts);
                }
            },
        }
    }

    // Pass 2: nested tables (emit as [path.key] headers)
    for (keys) |key| {
        const val = tbl.get(key).?;
        if (val == .table and (opts.prefer_headers or !isInlineTable(val.table))) {
            try w.writeByte('\n');
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = key;
            const child_path = path_buf[0 .. path.len + 1];
            try writeTableInner(w, val.table, child_path, true, opts, gpa);
        }
    }

    // Pass 3: arrays of tables
    for (keys) |key| {
        const val = tbl.get(key).?;
        if (isArrayOfTables(val)) {
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = key;
            const aot_path = path_buf[0 .. path.len + 1];
            const arr = val.array;
            for (arr.items) |item| {
                try w.writeByte('\n');
                try w.writeAll("[[");
                try writeDottedPrefix(w, aot_path);
                try w.writeAll("]]\n");
                try writeTableInner(w, item.table, aot_path, false, opts, gpa);
            }
        }
    }
}

fn writeTable(
    w: *std.Io.Writer,
    tbl: *Table,
    path: [][]const u8,
    opts: WriteOptions,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    return writeTableInner(w, tbl, path, true, opts, gpa);
}

/// Serialize `value` as TOML text to `w`. Default formatting.
///
/// Uses `[header]` syntax for sub-tables and `[[...]]` for arrays of
/// tables. All output is valid TOML v1.1.0.
pub fn writeToml(value: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return writeTomlOpts(value, w, .{}, std.heap.page_allocator) catch |e| switch (e) {
        error.OutOfMemory => unreachable, // page allocator won't fail for small keys
        else => |other| return other,
    };
}

/// Serialize `value` as TOML text with custom `opts`.
///
/// `gpa` is used for key-sort allocation (a no-op arena allocator
/// or page_allocator suffice).
pub fn writeTomlOpts(
    value: Value,
    w: *std.Io.Writer,
    opts: WriteOptions,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    switch (value) {
        .table => |tbl| try writeTable(w, tbl, &.{}, opts, gpa),
        else => try writeValue(w, value, opts),
    }
    try w.flush();
}
