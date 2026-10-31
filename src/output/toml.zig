//! TOML serializer for z-toml. Serializes a parsed `Value` tree
//! back to `.toml` text. Uses `[header]` and `[[aot]]` syntax for
//! context navigation (not dotted keys), producing readable TOML
//! that always round-trips correctly.

const std = @import("std");
const parser_mod = @import("../parser.zig");
const types = @import("../value.zig");
const temporal = @import("../temporal.zig");
const hints_mod = @import("hints.zig");

const Value = types.Value;
const Table = types.Table;
const Allocator = std.mem.Allocator;

fn tablesEqual(a: *const Table, b: *const Table) bool {
    if (a.count() != b.count()) return false;
    const a_keys = a.keys();
    const b_keys = b.keys();
    const a_vals = a.values();
    const b_vals = b.values();
    for (a_keys, b_keys, a_vals, b_vals) |a_key, b_key, a_val, b_val| {
        if (!std.mem.eql(u8, a_key, b_key)) return false;
        if (!valuesEqual(a_val, b_val)) return false;
    }
    return true;
}

fn arraysEqual(a: *const types.Array, b: *const types.Array) bool {
    if (a.items.len != b.items.len) return false;
    for (a.items, b.items) |lhs, rhs| {
        if (!valuesEqual(lhs, rhs)) return false;
    }
    return true;
}

fn floatsEqual(a: f64, b: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    return a == b;
}

fn valuesEqual(a: Value, b: Value) bool {
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
        .array => |lhs| arraysEqual(lhs, b.array),
        .table => |lhs| tablesEqual(lhs, b.table),
    };
}

fn tryWriteOriginalFaithfulSource(
    value: Value,
    w: *std.Io.Writer,
    hints: ?*hints_mod.FormatHints,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!bool {
    const h = hints orelse return false;
    const document = h.document orelse return false;
    const source = document.original_source orelse return false;

    if (value != .table) return false;

    const original = parser_mod.parseSlice(gpa, source, null) catch return false;
    defer {
        parser_mod.deinitTable(original, gpa);
        gpa.destroy(original);
    }

    if (!tablesEqual(value.table, original)) return false;
    try w.writeAll(source);
    return true;
}

fn lookupOriginalValue(root: *const Table, path: hints_mod.HintPath) ?Value {
    if (path.segments.len == 0) return null;

    var current_table: ?*const Table = root;
    var current_value: ?Value = null;

    for (path.segments, 0..) |segment, index| {
        const is_last = index + 1 == path.segments.len;
        switch (segment) {
            .key => |key| {
                const value = if (current_value) |active| switch (active) {
                    .table => |tbl| tbl.get(key),
                    else => null,
                } else if (current_table) |tbl|
                    tbl.get(key)
                else
                    null;

                const resolved = value orelse return null;
                if (is_last) return resolved;
                current_value = resolved;
                current_table = switch (resolved) {
                    .table => |tbl| tbl,
                    else => null,
                };
            },
            .index => |item_index| {
                const active = current_value orelse return null;
                const arr = switch (active) {
                    .array => |items| items,
                    else => return null,
                };
                if (item_index >= arr.items.len) return null;
                const resolved = arr.items[item_index];
                if (is_last) return resolved;
                current_value = resolved;
                current_table = switch (resolved) {
                    .table => |tbl| tbl,
                    else => null,
                };
            },
        }
    }

    return null;
}

fn tryWritePreservedScalarLexeme(
    w: *std.Io.Writer,
    val: Value,
    hints: ?*hints_mod.FormatHints,
    key_path: ?hints_mod.HintPath,
    original_root: ?*const Table,
) std.Io.Writer.Error!bool {
    const path = key_path orelse return false;
    const root = original_root orelse return false;
    const h = hints orelse return false;
    const value_lexemes = h.value_lexemes orelse return false;
    const raw = value_lexemes.get(path) orelse return false;
    const original_val = lookupOriginalValue(root, path) orelse return false;
    if (!valuesEqual(val, original_val)) return false;
    try w.writeAll(raw);
    return true;
}

/// Options controlling writeToml output formatting.
pub const WriteOptions = struct {
    /// Sort keys alphabetically within each table (canonical order).
    sort_keys: bool = false,
    /// Use `[header]` syntax for sub-tables even when all values are scalars.
    /// Default (`false`) inlines scalar-only sub-tables as `key = { ... }`.
    prefer_headers: bool = false,
    /// Use `\e` escape for ESC (0x1B) instead of `\u001B`.
    use_escape_e: bool = false,
    /// Preserve original entry order within tables (single-pass writer).
    /// When false, writer uses three-pass (scalars, tables, AOTs).
    preserve_order: bool = false,
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

fn lineEnding(hints: ?*hints_mod.FormatHints) []const u8 {
    if (hints) |h| if (h.document) |document| {
        return switch (document.line_ending) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    };
    return "\n";
}

fn writeNewline(w: *std.Io.Writer, hints: ?*hints_mod.FormatHints) std.Io.Writer.Error!void {
    try w.writeAll(lineEnding(hints));
}

fn writeBasicQuotedKey(w: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (key, 0..) |c, i| {
        if (!needsEscape(c)) continue;
        if (i > start) try w.writeAll(key[start..i]);
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            '\t' => try w.writeAll("\\t"),
            '\n' => try w.writeAll("\\n"),
            0x0C => try w.writeAll("\\f"),
            '\r' => try w.writeAll("\\r"),
            0x1B => try w.writeAll("\\u001B"),
            0...7, 0xB, 0xE...0x1A, 0x1C...0x1F, 0x7F => {
                try w.writeAll("\\u00");
                try w.print("{X:0>2}", .{c});
            },
            else => unreachable,
        }
        start = i + 1;
    }
    if (start < key.len) try w.writeAll(key[start..]);
    try w.writeByte('"');
}

fn writeLiteralQuotedKey(w: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('\'');
    try w.writeAll(key);
    try w.writeByte('\'');
}

fn writeQuotedWithStyle(
    w: *std.Io.Writer,
    key: []const u8,
    style: ?hints_mod.KeyStyle,
) std.Io.Writer.Error!void {
    if (style) |explicit_style| switch (explicit_style) {
        .bare => if (isBareKey(key)) return w.writeAll(key),
        .literal => return writeLiteralQuotedKey(w, key),
        .basic => return writeBasicQuotedKey(w, key),
    };

    if (isBareKey(key)) return w.writeAll(key);
    const requires_basic = for (key) |c| {
        if (needsEscape(c)) break true;
    } else false;
    if (!requires_basic and std.mem.indexOfScalar(u8, key, '\'') == null) {
        return writeLiteralQuotedKey(w, key);
    }
    return writeBasicQuotedKey(w, key);
}

fn writeQuotedWithHints(
    w: *std.Io.Writer,
    key: []const u8,
    hints: ?*hints_mod.FormatHints,
    path: hints_mod.HintPath,
) std.Io.Writer.Error!void {
    if (hints) |h| if (h.key_lexemes) |key_lexemes| {
        if (key_lexemes.get(path)) |raw| return w.writeAll(raw);
    };
    return writeQuotedWithStyle(w, key, findKeyStyle(hints, path));
}

fn findKeyStyle(hints: ?*hints_mod.FormatHints, path: hints_mod.HintPath) ?hints_mod.KeyStyle {
    if (hints) |h| if (h.key_styles) |styles| return styles.get(path);
    return null;
}

fn findTableSyntax(hints: ?*hints_mod.FormatHints, path: hints_mod.HintPath) ?hints_mod.TableSyntax {
    if (hints) |h| if (h.table_syntax) |table_syntax| return table_syntax.get(path);
    return null;
}

fn isInlineSyntax(syntax: ?hints_mod.TableSyntax) bool {
    return switch (syntax orelse return false) {
        .inline_compact, .inline_spaced => true,
        else => false,
    };
}

fn writeDottedPrefix(
    w: *std.Io.Writer,
    path: [][]const u8,
    hints: ?*hints_mod.FormatHints,
) std.Io.Writer.Error!void {
    var prefix_buf: [128]hints_mod.PathSegment = undefined;
    for (path, 0..) |part, i| {
        if (i > 0) try w.writeByte('.');
        prefix_buf[i] = .{ .key = part };
        try writeQuotedWithHints(w, part, hints, .{ .segments = prefix_buf[0 .. i + 1] });
    }
}

// ─── Value writers ─────────────────────────────────────────────────────────────

fn needsEscape(c: u8) bool {
    return switch (c) {
        '"', '\\', 0x08, '\t', '\n', 0x0C, '\r', 0x1B => true,
        0...7, 0xB, 0xE...0x1A, 0x1C...0x1F, 0x7F => true,
        else => false,
    };
}

fn writeBasicString(w: *std.Io.Writer, s: []const u8, opts: WriteOptions) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (!needsEscape(c)) continue;
        // Emit unescaped characters as a batch to reduce write call count.
        if (i > start) try w.writeAll(s[start..i]);
        switch (c) {
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
            else => {},
        }
        start = i + 1;
    }
    if (s.len > start) try w.writeAll(s[start..]);
    try w.writeByte('"');
}

fn writeMultilineBasicString(
    w: *std.Io.Writer,
    s: []const u8,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
) std.Io.Writer.Error!void {
    try w.writeAll("\"\"\"");
    if (s.len == 0 or s[0] != '\n') try writeNewline(w, hints);

    var start: usize = 0;
    for (s, 0..) |c, i| {
        switch (c) {
            '\n' => {
                if (i > start) try w.writeAll(s[start..i]);
                try writeNewline(w, hints);
                start = i + 1;
            },
            '"' => {
                if (i > start) try w.writeAll(s[start..i]);
                try w.writeAll("\\\"");
                start = i + 1;
            },
            '\\' => {
                if (i > start) try w.writeAll(s[start..i]);
                try w.writeAll("\\\\");
                start = i + 1;
            },
            0x08 => {
                if (i > start) try w.writeAll(s[start..i]);
                try w.writeAll("\\b");
                start = i + 1;
            },
            0x0C => {
                if (i > start) try w.writeAll(s[start..i]);
                try w.writeAll("\\f");
                start = i + 1;
            },
            '\r' => {
                if (i > start) try w.writeAll(s[start..i]);
                try w.writeAll("\\r");
                start = i + 1;
            },
            0x1B => {
                if (i > start) try w.writeAll(s[start..i]);
                try w.writeAll(if (opts.use_escape_e) "\\e" else "\\u001B");
                start = i + 1;
            },
            0...7, 0xB, 0xE...0x1A, 0x1C...0x1F, 0x7F => {
                if (i > start) try w.writeAll(s[start..i]);
                try w.writeAll("\\u00");
                try w.print("{X:0>2}", .{c});
                start = i + 1;
            },
            else => {},
        }
    }
    if (s.len > start) try w.writeAll(s[start..]);
    try w.writeAll("\"\"\"");
}

fn writeMultilineLiteralString(
    w: *std.Io.Writer,
    s: []const u8,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
) std.Io.Writer.Error!void {
    if (std.mem.indexOf(u8, s, "'''") != null) {
        return writeMultilineBasicString(w, s, opts, hints);
    }

    try w.writeAll("'''");
    if (s.len == 0 or s[0] != '\n') try writeNewline(w, hints);

    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c != '\n') continue;
        if (i > start) try w.writeAll(s[start..i]);
        try writeNewline(w, hints);
        start = i + 1;
    }
    if (s.len > start) try w.writeAll(s[start..]);
    try w.writeAll("'''");
}

fn extendHintPath(
    buf: []hints_mod.PathSegment,
    path: hints_mod.HintPath,
    segment: hints_mod.PathSegment,
) hints_mod.HintPath {
    std.debug.assert(path.segments.len + 1 <= buf.len);
    @memcpy(buf[0..path.segments.len], path.segments);
    buf[path.segments.len] = segment;
    return .{ .segments = buf[0 .. path.segments.len + 1] };
}

const InlineValueEntry = struct {
    key: []const u8,
    value: Value,
};

fn inlineValueEntryLessThan(_: void, a: InlineValueEntry, b: InlineValueEntry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn writeInlineEntry(
    w: *std.Io.Writer,
    key: []const u8,
    value: Value,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    key_path: ?hints_mod.HintPath,
    original_root: ?*const Table,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    if (key_path) |kp| {
        var child_path_buf: [129]hints_mod.PathSegment = undefined;
        const child_path = extendHintPath(&child_path_buf, kp, .{ .key = key });
        try writeQuotedWithHints(w, key, hints, child_path);
        try w.writeAll(" = ");
        try writeValue(w, value, opts, hints, child_path, original_root, gpa);
    } else {
        try writeQuotedWithStyle(w, key, null);
        try w.writeAll(" = ");
        try writeValue(w, value, opts, hints, null, original_root, gpa);
    }
}

fn writeValue(
    w: *std.Io.Writer,
    val: Value,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    key_path: ?hints_mod.HintPath,
    original_root: ?*const Table,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    switch (val) {
        .float, .offset_datetime, .local_datetime, .local_date, .local_time => {
            if (try tryWritePreservedScalarLexeme(w, val, hints, key_path, original_root)) return;
        },
        else => {},
    }

    switch (val) {
        .string => |s| {
            if (hints) |h| if (h.string_styles) |styles| if (key_path) |kp| {
                if (styles.get(kp)) |style| switch (style) {
                    .basic => {
                        try writeBasicString(w, s, opts);
                        return;
                    },
                    .literal => {
                        try w.writeByte('\'');
                        try w.writeAll(s);
                        try w.writeByte('\'');
                        return;
                    },
                    .multiline_basic => {
                        try writeMultilineBasicString(w, s, opts, hints);
                        return;
                    },
                    .multiline_literal => {
                        try writeMultilineLiteralString(w, s, opts, hints);
                        return;
                    },
                };
            };
            try writeBasicString(w, s, opts);
        },
        .integer => |iv| {
            switch (iv.base) {
                .decimal => try w.print("{}", .{iv.value}),
                .hex => try w.print("0x{X}", .{@as(u64, @bitCast(iv.value))}),
                .octal => try w.print("0o{o}", .{@as(u64, @bitCast(iv.value))}),
                .binary => try w.print("0b{b}", .{@as(u64, @bitCast(iv.value))}),
            }
        },
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
            try temporal.writeLocalDate(w, dt.date);
            try w.writeByte('T');
            try temporal.writeLocalTime(w, dt.time);
            try temporal.writeOffset(w, dt.offset_minutes);
        },
        .local_datetime => |dt| {
            try temporal.writeLocalDate(w, dt.date);
            try w.writeByte('T');
            try temporal.writeLocalTime(w, dt.time);
        },
        .local_date => |d| try temporal.writeLocalDate(w, d),
        .local_time => |t| try temporal.writeLocalTime(w, t),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                if (key_path) |kp| {
                    var child_path_buf: [129]hints_mod.PathSegment = undefined;
                    const child_path = extendHintPath(&child_path_buf, kp, .{ .index = i });
                    try writeValue(w, item, opts, hints, child_path, original_root, gpa);
                } else {
                    try writeValue(w, item, opts, hints, null, original_root, gpa);
                }
            }
            try w.writeByte(']');
        },
        .table => |tbl| {
            const inline_spaced = if (key_path) |kp|
                findTableSyntax(hints, kp) == .inline_spaced
            else
                false;

            try w.writeByte('{');
            if (inline_spaced and tbl.count() > 0) try w.writeByte(' ');
            var first = true;

            if (opts.sort_keys and tbl.count() > 1) {
                const entries = try gpa.alloc(InlineValueEntry, tbl.count());
                defer gpa.free(entries);

                var it = tbl.iterator();
                var index: usize = 0;
                while (it.next()) |entry| {
                    entries[index] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
                    index += 1;
                }
                std.sort.block(InlineValueEntry, entries, {}, inlineValueEntryLessThan);

                for (entries) |entry| {
                    if (!first) try w.writeAll(", ");
                    first = false;
                    try writeInlineEntry(w, entry.key, entry.value, opts, hints, key_path, original_root, gpa);
                }
            } else {
                var it = tbl.iterator();
                while (it.next()) |entry| {
                    if (!first) try w.writeAll(", ");
                    first = false;
                    try writeInlineEntry(w, entry.key_ptr.*, entry.value_ptr.*, opts, hints, key_path, original_root, gpa);
                }
            }
            if (inline_spaced and !first) try w.writeByte(' ');
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

const EntryKind = enum(u2) {
    /// String, integer, float, boolean, datetime, or non-AOT array.
    plain,
    /// Table where all values are scalars (inline-eligible).
    inline_table,
    /// Table with at least one non-scalar value.
    table,
    /// Array where all elements are tables.
    aot,
};

const KeyValue = struct {
    key: []const u8,
    val: Value,
    kind: EntryKind,
};

fn kvLessThan(_: void, a: KeyValue, b: KeyValue) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

// Collect key-value pairs from `tbl` with pre-computed entry kinds.
// Avoids hash lookups and duplicate `isInlineTable` calls during iteration.
fn kvsOf(
    tbl: *Table,
    path: [][]const u8,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    gpa: Allocator,
) Allocator.Error![]KeyValue {
    const count = tbl.count();
    if (count == 0) return &.{};
    const kvs = try gpa.alloc(KeyValue, count);
    var i: usize = 0;
    var it = tbl.iterator();
    while (it.next()) |entry| {
        const val = entry.value_ptr.*;
        const kind: EntryKind = switch (val) {
            .string, .integer, .float, .boolean, .offset_datetime, .local_datetime, .local_date, .local_time => .plain,
            .array => if (isArrayOfTables(val)) .aot else .plain,
            .table => |tbl2| blk: {
                var child_path_buf: [129]hints_mod.PathSegment = undefined;
                const child_path = buildHintPath(&child_path_buf, path, entry.key_ptr.*);
                if (isInlineSyntax(findTableSyntax(hints, child_path))) break :blk .inline_table;
                break :blk if (!opts.prefer_headers and !opts.preserve_order and isInlineTable(tbl2)) .inline_table else .table;
            },
        };
        kvs[i] = .{ .key = entry.key_ptr.*, .val = val, .kind = kind };
        i += 1;
    }
    if (opts.sort_keys) std.sort.block(KeyValue, kvs, {}, kvLessThan);
    return kvs;
}

// ─── Core serialization ────────────────────────────────────────────────────────

const CommentCursorMap = hints_mod.HintMap(usize);

const CommentCursorState = struct {
    positions: CommentCursorMap = .empty,

    fn deinit(self: *CommentCursorState, gpa: Allocator) void {
        var it = self.positions.iterator();
        while (it.next()) |entry| entry.key_ptr.deinit(gpa);
        self.positions.deinit(gpa);
    }

    fn cursorForPath(self: *CommentCursorState, gpa: Allocator, path: hints_mod.HintPath) !*usize {
        if (self.positions.getPtr(path)) |cursor| return cursor;

        var owned = try path.clone(gpa);
        errdefer owned.deinit(gpa);
        try self.positions.put(gpa, owned, 0);
        return self.positions.getPtr(path).?;
    }
};

fn writeStoredComment(w: *std.Io.Writer, comment: hints_mod.CommentRecord) std.Io.Writer.Error!void {
    if (comment.raw) |raw| {
        try w.writeAll(raw);
        return;
    }
    try w.writeAll("# ");
    try w.writeAll(comment.text);
}

fn writeTrailingComment(w: *std.Io.Writer, comment: hints_mod.CommentRecord) std.Io.Writer.Error!void {
    if (comment.raw) |raw| {
        try w.writeAll(raw);
        return;
    }
    try w.writeAll(" # ");
    try w.writeAll(comment.text);
}

fn emitComments(
    w: *std.Io.Writer,
    path: hints_mod.HintPath,
    comments: hints_mod.CommentList,
    attachment: hints_mod.CommentAttachment,
    hints: ?*hints_mod.FormatHints,
    comment_state: ?*CommentCursorState,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    var start_index: usize = 0;
    var cursor: ?*usize = null;
    if (comment_state) |state| {
        cursor = try state.cursorForPath(gpa, path);
        start_index = cursor.?.*;
    }

    var index = start_index;
    while (index < comments.items.len and comments.items[index].attachment == attachment) : (index += 1) {
        const comment = comments.items[index];
        try writeStoredComment(w, comment);
        try writeNewline(w, hints);
    }
    if (cursor) |value| value.* = index;
}

fn findComment(
    gpa: Allocator,
    path: hints_mod.HintPath,
    comments: hints_mod.CommentList,
    attachment: hints_mod.CommentAttachment,
    comment_state: ?*CommentCursorState,
) Allocator.Error!?hints_mod.CommentRecord {
    if (comment_state) |state| {
        const cursor = try state.cursorForPath(gpa, path);
        if (cursor.* < comments.items.len and comments.items[cursor.*].attachment == attachment) {
            const comment = comments.items[cursor.*];
            cursor.* += 1;
            return comment;
        }
        return null;
    }

    for (comments.items) |comment| {
        if (comment.attachment == attachment) return comment;
    }
    return null;
}

fn buildHintPath(
    buf: []hints_mod.PathSegment,
    parent_path: [][]const u8,
    key: ?[]const u8,
) hints_mod.HintPath {
    var len: usize = 0;
    for (parent_path) |segment| {
        std.debug.assert(len < buf.len);
        buf[len] = .{ .key = segment };
        len += 1;
    }
    if (key) |segment| {
        std.debug.assert(len < buf.len);
        buf[len] = .{ .key = segment };
        len += 1;
    }
    return .{ .segments = buf[0..len] };
}

fn writeHeaderWithComments(
    w: *std.Io.Writer,
    path: [][]const u8,
    is_aot: bool,
    hints: ?*hints_mod.FormatHints,
    comment_state: ?*CommentCursorState,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    var header_path_buf: [128]hints_mod.PathSegment = undefined;
    const header_path = buildHintPath(&header_path_buf, path, null);
    var trailing_comment: ?hints_mod.CommentRecord = null;

    if (hints) |h| if (h.comments) |comments| {
        if (comments.get(header_path)) |records| {
            try emitComments(w, header_path, records, if (is_aot) .before_aot else .before_table, hints, comment_state, gpa);
            trailing_comment = try findComment(gpa, header_path, records, if (is_aot) .trailing_aot else .trailing_table, comment_state);
        }
    };

    if (is_aot) {
        try w.writeAll("[[");
        try writeDottedPrefix(w, path, hints);
        try w.writeAll("]]");
    } else {
        try w.writeByte('[');
        try writeDottedPrefix(w, path, hints);
        try w.writeByte(']');
    }
    if (trailing_comment) |comment| {
        try writeTrailingComment(w, comment);
    }
    try writeNewline(w, hints);
}

fn writeKV(
    w: *std.Io.Writer,
    key: []const u8,
    val: Value,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    parent_path: [][]const u8,
    comment_state: ?*CommentCursorState,
    original_root: ?*const Table,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    var full_path_buf: [129]hints_mod.PathSegment = undefined;
    const full_path = buildHintPath(&full_path_buf, parent_path, key);
    var trailing_comment: ?hints_mod.CommentRecord = null;
    if (hints) |h| if (h.comments) |comments| {
        if (comments.get(full_path)) |records| {
            try emitComments(w, full_path, records, .before_entry, hints, comment_state, gpa);
            trailing_comment = try findComment(gpa, full_path, records, .trailing_entry, comment_state);
        }
    };
    try writeQuotedWithHints(w, key, hints, full_path);
    try w.writeAll(" = ");
    try writeValue(w, val, opts, hints, full_path, original_root, gpa);
    if (trailing_comment) |comment| {
        try writeTrailingComment(w, comment);
    }
    try writeNewline(w, hints);
}

fn writeChildTableBody(
    w: *std.Io.Writer,
    child_path: [][]const u8,
    child_table: *Table,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    comment_state: ?*CommentCursorState,
    original_root: ?*const Table,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    var child_path_buf: [129]hints_mod.PathSegment = undefined;
    const child_syntax = findTableSyntax(hints, buildHintPath(&child_path_buf, child_path, null));
    if (child_syntax != .dotted) {
        try writeNewline(w, hints);
    }
    try writeTableInner(w, child_table, child_path, true, opts, hints, comment_state, original_root, gpa);
}

fn writeAotBodies(
    w: *std.Io.Writer,
    aot_path: [][]const u8,
    arr: *types.Array,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    comment_state: ?*CommentCursorState,
    original_root: ?*const Table,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    for (arr.items) |item| {
        try writeNewline(w, hints);
        try writeHeaderWithComments(w, aot_path, true, hints, comment_state, gpa);
        try writeTableInner(w, item.table, aot_path, false, opts, hints, comment_state, original_root, gpa);
    }
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
    hints: ?*hints_mod.FormatHints,
    comment_state: ?*CommentCursorState,
    original_root: ?*const Table,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    var path_buf: [128][]const u8 = undefined;
    const kvs = try kvsOf(tbl, path, opts, hints, gpa);
    defer if (kvs.len > 0) gpa.free(kvs);

    var table_path_buf: [128]hints_mod.PathSegment = undefined;
    const table_syntax = if (path.len > 0)
        findTableSyntax(hints, buildHintPath(&table_path_buf, path, null))
    else
        null;

    if (emit_header and path.len > 0 and table_syntax != .dotted) {
        try writeHeaderWithComments(w, path, false, hints, comment_state, gpa);
    }

    if (opts.preserve_order) {
        try writePreserveOrder(w, tbl, kvs, path, &path_buf, opts, hints, comment_state, original_root, gpa);
        return;
    }

    // Three-pass dispatch: scalars first so they appear before table headers.
    for (kvs) |kv| {
        switch (kv.kind) {
            .plain, .inline_table => try writeKV(w, kv.key, kv.val, opts, hints, path, comment_state, original_root, gpa),
            else => {},
        }
    }

    // Tables come second: each one emits a [header] and recurses.
    for (kvs) |kv| {
        if (kv.kind == .table) {
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = kv.key;
            const child_path = path_buf[0 .. path.len + 1];
            try writeChildTableBody(w, child_path, kv.val.table, opts, hints, comment_state, original_root, gpa);
        }
    }

    // AOTs last: each element gets a [[header]] and recurses with emit=false.
    for (kvs) |kv| {
        if (kv.kind == .aot) {
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = kv.key;
            const aot_path = path_buf[0 .. path.len + 1];
            try writeAotBodies(w, aot_path, kv.val.array, opts, hints, comment_state, original_root, gpa);
        }
    }
}

fn writePreserveOrder(
    w: *std.Io.Writer,
    tbl: *Table,
    kvs: []KeyValue,
    path: [][]const u8,
    path_buf: *[128][]const u8,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    comment_state: ?*CommentCursorState,
    original_root: ?*const Table,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    _ = tbl;
    var table_path_buf: [128]hints_mod.PathSegment = undefined;
    const table_is_dotted = path.len > 0 and findTableSyntax(hints, buildHintPath(&table_path_buf, path, null)) == .dotted;
    var use_dotted = table_is_dotted;
    var needs_blank_before_dotted = false;
    var hoisted_plain_suffix = false;
    var crossed_child_boundary = false;
    for (kvs, 0..) |kv, index| {
        switch (kv.kind) {
            .plain, .inline_table => {
                if (!table_is_dotted and crossed_child_boundary) continue;
                if (use_dotted and path.len > 0) {
                    var full_path_buf: [129]hints_mod.PathSegment = undefined;
                    const full_path = buildHintPath(&full_path_buf, path, kv.key);
                    if (needs_blank_before_dotted) {
                        try writeNewline(w, hints);
                        needs_blank_before_dotted = false;
                    }
                    try writeDottedPrefix(w, path, hints);
                    try w.writeByte('.');
                    try writeQuotedWithHints(w, kv.key, hints, full_path);
                    try w.writeAll(" = ");
                    try writeValue(w, kv.val, opts, hints, full_path, original_root, gpa);
                    try writeNewline(w, hints);
                } else {
                    try writeKV(w, kv.key, kv.val, opts, hints, path, comment_state, original_root, gpa);
                }
            },
            .table => {
                if (!table_is_dotted and !hoisted_plain_suffix) {
                    crossed_child_boundary = true;
                    hoisted_plain_suffix = true;
                    for (kvs[index + 1 ..]) |later| {
                        switch (later.kind) {
                            .plain, .inline_table => try writeKV(w, later.key, later.val, opts, hints, path, comment_state, original_root, gpa),
                            else => {},
                        }
                    }
                }
                use_dotted = false;
                @memcpy(path_buf[0..path.len], path);
                path_buf[path.len] = kv.key;
                const child_path = path_buf[0 .. path.len + 1];
                try writeChildTableBody(w, child_path, kv.val.table, opts, hints, comment_state, original_root, gpa);
                use_dotted = table_is_dotted;
                needs_blank_before_dotted = table_is_dotted;
            },
            .aot => {
                if (!table_is_dotted and !hoisted_plain_suffix) {
                    crossed_child_boundary = true;
                    hoisted_plain_suffix = true;
                    for (kvs[index + 1 ..]) |later| {
                        switch (later.kind) {
                            .plain, .inline_table => try writeKV(w, later.key, later.val, opts, hints, path, comment_state, original_root, gpa),
                            else => {},
                        }
                    }
                }
                use_dotted = false;
                @memcpy(path_buf[0..path.len], path);
                path_buf[path.len] = kv.key;
                const aot_path = path_buf[0 .. path.len + 1];
                try writeAotBodies(w, aot_path, kv.val.array, opts, hints, comment_state, original_root, gpa);
                use_dotted = table_is_dotted;
                needs_blank_before_dotted = table_is_dotted;
            },
        }
    }
}

fn writeTable(
    w: *std.Io.Writer,
    tbl: *Table,
    path: [][]const u8,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    comment_state: ?*CommentCursorState,
    original_root: ?*const Table,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    return writeTableInner(w, tbl, path, true, opts, hints, comment_state, original_root, gpa);
}

/// Serialize `value` as TOML text to `w`. Default formatting.
///
/// Uses `[header]` syntax for sub-tables and `[[...]]` for arrays of
/// tables. All output is valid TOML v1.1.0.
pub fn writeToml(value: Value, w: *std.Io.Writer) (std.Io.Writer.Error || Allocator.Error)!void {
    return writeTomlOpts(value, w, .{}, std.heap.smp_allocator);
}

/// Serialize `value` as TOML text with custom `opts`.
///
/// `gpa` is used for the per-table scratch buffers (key ordering and inline
/// entries). Any allocator works; a general-purpose allocator that reuses freed
/// memory keeps the scratch cost low.
pub fn writeTomlOpts(
    value: Value,
    w: *std.Io.Writer,
    opts: WriteOptions,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    switch (value) {
        .table => |tbl| try writeTable(w, tbl, &.{}, opts, null, null, null, gpa),
        else => try writeValue(w, value, opts, null, null, null, gpa),
    }
    try w.flush();
}

pub fn writeTomlRewriteValueOpts(
    value: Value,
    w: *std.Io.Writer,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    key_path: ?hints_mod.HintPath,
    original_root: ?*const Table,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    try writeValue(w, value, opts, hints, key_path, original_root, gpa);
    try w.flush();
}

/// Serialize `value` as a TOML value expression with custom `opts`.
///
/// `prefer_headers` has no effect here because value expressions cannot emit
/// table headers. `gpa` is used when `opts.sort_keys` needs temporary storage.
pub fn writeTomlValueOpts(
    value: Value,
    w: *std.Io.Writer,
    opts: WriteOptions,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    return writeTomlRewriteValueOpts(value, w, opts, null, null, null, gpa);
}

/// Serialize `value` as a TOML value expression.
///
/// Tables are emitted as inline-table expressions so the output remains valid
/// anywhere a TOML value can appear.
pub fn writeTomlValue(
    value: Value,
    w: *std.Io.Writer,
) (std.Io.Writer.Error || Allocator.Error)!void {
    return writeTomlValueOpts(value, w, .{}, std.heap.smp_allocator);
}

pub fn writeTomlPathValueOpts(
    path: []const []const u8,
    value: Value,
    w: *std.Io.Writer,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    std.debug.assert(path.len > 0);
    if (path.len > 1) {
        try writeDottedPrefix(w, @constCast(path[0 .. path.len - 1]), hints);
        try w.writeByte('.');
    }
    try writeQuotedWithStyle(w, path[path.len - 1], null);
    try w.writeAll(" = ");
    try writeValue(w, value, opts, hints, null, null, gpa);
    try writeNewline(w, hints);
    try w.flush();
}

pub fn writeTomlTableFragmentOpts(
    path: []const []const u8,
    table: *Table,
    w: *std.Io.Writer,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    std.debug.assert(path.len > 0);
    try writeHeaderWithComments(w, @constCast(path), false, hints, null, gpa);
    try writeTableInner(w, table, @constCast(path), false, opts, hints, null, null, gpa);
    try w.flush();
}

pub fn writeTomlArrayOfTablesFragmentOpts(
    path: []const []const u8,
    arr: *types.Array,
    w: *std.Io.Writer,
    opts: WriteOptions,
    hints: ?*hints_mod.FormatHints,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    std.debug.assert(path.len > 0);
    for (arr.items, 0..) |item, index| {
        std.debug.assert(item == .table);
        if (index > 0) try writeNewline(w, hints);
        try writeHeaderWithComments(w, @constCast(path), true, hints, null, gpa);
        try writeTableInner(w, item.table, @constCast(path), false, opts, hints, null, null, gpa);
    }
    try w.flush();
}

pub fn writeTomlWithProfile(
    value: Value,
    w: *std.Io.Writer,
    profile: hints_mod.OutputProfile,
    hints: ?*hints_mod.FormatHints,
    gpa: Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void {
    if (profile == .faithful and try tryWriteOriginalFaithfulSource(value, w, hints, gpa)) {
        try w.flush();
        return;
    }

    if (hints) |h| if (h.document) |document| {
        if (document.has_bom) try w.writeAll("\xEF\xBB\xBF");
    };
    const opts: WriteOptions = switch (profile) {
        .compact => .{},
        .preserve => .{ .preserve_order = true, .prefer_headers = true },
        .canonical => .{ .sort_keys = true, .prefer_headers = true, .use_escape_e = true },
        .faithful => .{ .preserve_order = true, .prefer_headers = true, .use_escape_e = true },
    };
    var comment_state: CommentCursorState = .{};
    defer comment_state.deinit(gpa);
    const active_comment_state = if (hints != null and hints.?.comments != null) &comment_state else null;
    const original_root = blk: {
        if (profile != .faithful) break :blk null;
        const h = hints orelse break :blk null;
        _ = h.value_lexemes orelse break :blk null;
        const document = h.document orelse break :blk null;
        const source = document.original_source orelse break :blk null;
        const original = parser_mod.parseSlice(gpa, source, null) catch break :blk null;
        break :blk original;
    };
    defer if (original_root) |root| {
        parser_mod.deinitTable(root, gpa);
        gpa.destroy(root);
    };
    switch (value) {
        .table => |tbl| try writeTable(w, tbl, &.{}, opts, hints, active_comment_state, if (original_root) |root| root else null, gpa),
        else => try writeValue(w, value, opts, hints, null, if (original_root) |root| root else null, gpa),
    }
    try w.flush();
}
