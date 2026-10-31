//! TOML v1.1.0 single-pass recursive-descent parser.
const std = @import("std");
const types = @import("value.zig");
const hints_mod = @import("output/hints.zig");
const spans_mod = @import("span.zig");
const view_mod = @import("view.zig");

pub const Value = types.Value;
pub const Table = types.Table;
pub const LocalDate = types.LocalDate;
pub const LocalTime = types.LocalTime;

const Allocator = std.mem.Allocator;

/// Extra bytes reserved beyond an unescaped prefix when a string needs the
/// decoding buffer. Longer strings grow the buffer by doubling.
const string_buffer_slack = 64;

pub const ParseError = error{ ParseFailed, OutOfMemory };

// ─── Memory management (owned Value tree) ─────────────────────────────────────

/// Recursively free all memory owned by `value`.
pub fn deinitValue(value: Value, gpa: Allocator) void {
    switch (value) {
        .string => |s| gpa.free(s),
        .array => |arr| {
            for (arr.items) |item| deinitValue(item, gpa);
            arr.deinit(gpa);
            gpa.destroy(arr);
        },
        .table => |tbl| {
            deinitTable(tbl, gpa);
            gpa.destroy(tbl);
        },
        else => {},
    }
}

/// Free all keys, values and the table's own storage.
pub fn deinitTable(tbl: *Table, gpa: Allocator) void {
    for (tbl.keys()) |k| gpa.free(k);
    for (tbl.values()) |v| deinitValue(v, gpa);
    tbl.deinit(gpa);
}

pub const ErrorInfo = struct {
    line: u32 = 0,
    col: u32 = 0,
    _buf: [256]u8 = @splat(0),
    _len: usize = 0,

    pub fn message(self: *const ErrorInfo) []const u8 {
        return self._buf[0..self._len];
    }
};

const TableKind = enum(u3) { root, implicit, dotted, header, inline_t, aot_array };
const KeyKind = enum(u3) { value, implicit_table, dotted_table, header_table, inline_table, aot_array };

const TableMeta = struct {
    kind: TableKind,
    key_kinds: std.StringHashMapUnmanaged(KeyKind),
};

const ParseConfig = struct {
    track_spans: bool = false,
};

fn ParserTy(comptime V: type, comptime config: ParseConfig) type {
    const TableT = std.array_hash_map.String(V);
    const ArrayT = std.ArrayList(V);
    const track_spans = config.track_spans;

    return struct {
        const TableType = TableT;
        const ArrayType = ArrayT;
        const Self = @This();
        const SpanHandle = if (track_spans) ?*spans_mod.ParseSpans else void;
        const SpanPathList = if (track_spans) std.ArrayListUnmanaged(hints_mod.PathSegment) else void;
        const PendingSpanPath = if (track_spans) ?hints_mod.HintPath else void;
        const PendingValueSpan = if (track_spans) ?spans_mod.ByteSpan else void;
        const PendingStatementStart = if (track_spans) ?usize else void;
        const ParsedKeyPath = struct {
            parts: std.ArrayList([]u8),
            /// Filled only when hints are collected.
            styles: std.ArrayList(hints_mod.KeyStyle),
            /// Borrowed from the input. Filled only when hints are collected.
            raw_parts: std.ArrayList([]const u8),

            fn deinit(self: *ParsedKeyPath, gpa: Allocator) void {
                for (self.parts.items) |part| gpa.free(part);
                self.parts.deinit(gpa);
                self.styles.deinit(gpa);
                self.raw_parts.deinit(gpa);
            }
        };
        const AOTElementResult = struct {
            tbl: *TableType,
            index: usize,
        };

        const PendingComment = struct {
            text: []const u8,
            raw: []const u8,
        };

        gpa: Allocator,
        input: []const u8,
        pos: usize,
        line: u32,
        line_start: usize,
        root: *TableType,
        cur: *TableType,
        meta_arena: std.heap.ArenaAllocator,
        table_metas: std.AutoHashMapUnmanaged(*TableType, *TableMeta),
        err_info: ErrorInfo,
        hints: ?*hints_mod.FormatHints,
        spans: SpanHandle,
        table_path: std.ArrayListUnmanaged([]const u8),
        span_table_path: SpanPathList,
        current_value_path: std.ArrayListUnmanaged(hints_mod.PathSegment),
        current_span_path: SpanPathList,
        pending_comments: std.ArrayListUnmanaged(PendingComment),
        trailing_path: ?hints_mod.HintPath,
        pending_entry_span_path: PendingSpanPath,
        pending_entry_value_span: PendingValueSpan,
        pending_entry_statement_start: PendingStatementStart,

        fn init(
            gpa: Allocator,
            input: []const u8,
            hints: ?*hints_mod.FormatHints,
            spans: ?*spans_mod.ParseSpans,
        ) Allocator.Error!Self {
            const root = try gpa.create(TableType);
            root.* = .empty;
            errdefer {
                root.deinit(gpa);
                gpa.destroy(root);
            }

            var p = Self{
                .gpa = gpa,
                .input = input,
                .pos = 0,
                .line = 1,
                .line_start = 0,
                .root = root,
                .cur = root,
                .meta_arena = std.heap.ArenaAllocator.init(gpa),
                .table_metas = .empty,
                .err_info = .{},
                .hints = hints,
                .spans = if (track_spans) spans else {},
                .table_path = .empty,
                .span_table_path = if (track_spans) .empty else {},
                .current_value_path = .empty,
                .current_span_path = if (track_spans) .empty else {},
                .pending_comments = .empty,
                .trailing_path = null,
                .pending_entry_span_path = if (track_spans) null else {},
                .pending_entry_value_span = if (track_spans) null else {},
                .pending_entry_statement_start = if (track_spans) null else {},
            };
            errdefer p.meta_arena.deinit();
            if (hints) |h| if (h.document) |document| {
                if (document.original_source) |source| gpa.free(source);
                document.* = .{
                    .has_bom = std.mem.startsWith(u8, input, "\xEF\xBB\xBF"),
                    .line_ending = if (std.mem.indexOf(u8, input, "\r\n") != null) .crlf else .lf,
                    .original_source = try gpa.dupe(u8, input),
                };
            };
            if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) {
                p.pos = 3;
                p.line_start = 3;
            }
            _ = try p.createMeta(root, .root);
            return p;
        }

        fn deinit(self: *Self) void {
            self.table_path.deinit(self.meta_arena.allocator());
            self.current_value_path.deinit(self.gpa);
            self.pending_comments.deinit(self.gpa);
            if (self.trailing_path) |*path| path.deinit(self.gpa);
            if (track_spans) {
                self.span_table_path.deinit(self.meta_arena.allocator());
                self.current_span_path.deinit(self.gpa);
                if (self.pending_entry_span_path) |*path| path.deinit(self.gpa);
            }
            self.meta_arena.deinit();
        }

        fn dropValue(self: *Self, value: V) void {
            if (comptime V == types.Value) {
                deinitValue(value, self.gpa);
            } else {
                var v = value;
                view_mod.deinitViewValue(&v, self.gpa, self.input);
            }
        }

        fn dropTable(self: *Self, tbl: *TableType) void {
            if (comptime V == types.Value) {
                deinitTable(tbl, self.gpa);
            } else {
                view_mod.deinitViewTable(tbl, self.gpa, self.input);
            }
        }

        fn setTablePath(self: *Self, parts: [][]u8) Allocator.Error!void {
            const ma = self.meta_arena.allocator();
            self.table_path.clearRetainingCapacity();
            try self.table_path.ensureTotalCapacity(ma, parts.len);
            for (parts) |part| {
                const duped = try ma.dupe(u8, part);
                self.table_path.appendAssumeCapacity(duped);
            }
        }

        fn setSpanTablePath(self: *Self, parts: [][]u8) Allocator.Error!void {
            if (!track_spans) return;
            const ma = self.meta_arena.allocator();
            self.span_table_path.clearRetainingCapacity();
            try self.span_table_path.ensureTotalCapacity(ma, parts.len);
            for (parts) |part| {
                const duped = try ma.dupe(u8, part);
                self.span_table_path.appendAssumeCapacity(.{ .key = duped });
            }
        }

        fn setAOTSpanTablePath(self: *Self, parts: [][]u8, index: usize) Allocator.Error!void {
            if (!track_spans) return;
            const ma = self.meta_arena.allocator();
            self.span_table_path.clearRetainingCapacity();
            try self.span_table_path.ensureTotalCapacity(ma, parts.len + 1);
            for (parts) |part| {
                const duped = try ma.dupe(u8, part);
                self.span_table_path.appendAssumeCapacity(.{ .key = duped });
            }
            self.span_table_path.appendAssumeCapacity(.{ .index = index });
        }

        fn buildPath(self: *Self, key_parts: [][]u8, out: *std.ArrayList(hints_mod.PathSegment)) !void {
            out.clearRetainingCapacity();
            try out.ensureTotalCapacity(self.gpa, self.table_path.items.len + key_parts.len);
            for (self.table_path.items) |part| {
                out.appendAssumeCapacity(.{ .key = part });
            }
            for (key_parts) |part| {
                out.appendAssumeCapacity(.{ .key = part });
            }
        }

        fn pathForKey(self: *Self, key_parts: [][]u8, out: *std.ArrayList(hints_mod.PathSegment)) !hints_mod.HintPath {
            try self.buildPath(key_parts, out);
            return .{ .segments = out.items };
        }

        fn dupedPath(self: *Self, key_parts: [][]u8) Allocator.Error!hints_mod.HintPath {
            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            const path = try self.pathForKey(key_parts, &path_buf);
            return path.clone(self.gpa);
        }

        fn setCurrentValuePath(self: *Self, key_parts: [][]u8) !void {
            self.current_value_path.clearRetainingCapacity();
            try self.current_value_path.ensureTotalCapacity(self.gpa, self.table_path.items.len + key_parts.len);
            for (self.table_path.items) |part| {
                self.current_value_path.appendAssumeCapacity(.{ .key = part });
            }
            for (key_parts) |part| {
                self.current_value_path.appendAssumeCapacity(.{ .key = part });
            }
        }

        fn setCurrentSpanPath(self: *Self, key_parts: [][]u8) !void {
            if (!track_spans) return;
            self.current_span_path.clearRetainingCapacity();
            try self.current_span_path.ensureTotalCapacity(self.gpa, self.span_table_path.items.len + key_parts.len);
            for (self.span_table_path.items) |segment| {
                self.current_span_path.appendAssumeCapacity(segment);
            }
            for (key_parts) |part| {
                self.current_span_path.appendAssumeCapacity(.{ .key = part });
            }
        }

        fn pushCurrentValueKeys(self: *Self, parts: [][]u8) !usize {
            const base_len = self.current_value_path.items.len;
            try self.current_value_path.ensureTotalCapacity(self.gpa, base_len + parts.len);
            for (parts) |part| {
                self.current_value_path.appendAssumeCapacity(.{ .key = part });
            }
            return base_len;
        }

        fn pushCurrentValueIndex(self: *Self, index: usize) !usize {
            const base_len = self.current_value_path.items.len;
            try self.current_value_path.ensureTotalCapacity(self.gpa, base_len + 1);
            self.current_value_path.appendAssumeCapacity(.{ .index = index });
            return base_len;
        }

        fn pushCurrentSpanKeys(self: *Self, parts: [][]u8) !usize {
            if (!track_spans) return 0;
            const base_len = self.current_span_path.items.len;
            try self.current_span_path.ensureTotalCapacity(self.gpa, base_len + parts.len);
            for (parts) |part| {
                self.current_span_path.appendAssumeCapacity(.{ .key = part });
            }
            return base_len;
        }

        fn pushCurrentSpanIndex(self: *Self, index: usize) !usize {
            if (!track_spans) return 0;
            const base_len = self.current_span_path.items.len;
            try self.current_span_path.ensureTotalCapacity(self.gpa, base_len + 1);
            self.current_span_path.appendAssumeCapacity(.{ .index = index });
            return base_len;
        }

        fn restoreCurrentValuePath(self: *Self, len: usize) void {
            self.current_value_path.items.len = len;
        }

        fn restoreCurrentSpanPath(self: *Self, len: usize) void {
            if (!track_spans) return;
            self.current_span_path.items.len = len;
        }

        fn clearCurrentSpanPath(self: *Self) void {
            if (!track_spans) return;
            self.current_span_path.clearRetainingCapacity();
        }

        fn recordEntrySpanByPath(self: *Self, path: hints_mod.HintPath, span: spans_mod.EntrySpan) !void {
            if (!track_spans) return;
            const spans = self.spans orelse return;
            const entries = spans.entries orelse return;

            if (entries.getPtr(path)) |existing| {
                existing.* = span;
                return;
            }

            var owned = try path.clone(self.gpa);
            errdefer owned.deinit(self.gpa);
            try entries.put(self.gpa, owned, span);
        }

        fn recordHeaderSpanByPath(self: *Self, path: hints_mod.HintPath, span: spans_mod.HeaderSpan) !void {
            if (!track_spans) return;
            const spans = self.spans orelse return;
            const headers = spans.headers orelse return;

            if (headers.getPtr(path)) |existing| {
                existing.* = span;
                return;
            }

            var owned = try path.clone(self.gpa);
            errdefer owned.deinit(self.gpa);
            try headers.put(self.gpa, owned, span);
        }

        fn stagePendingEntrySpan(self: *Self, statement_start: usize, value_span: spans_mod.ByteSpan) !void {
            if (!track_spans) return;
            _ = self.spans orelse return;
            if (self.current_span_path.items.len == 0) return;
            if (self.pending_entry_span_path) |*path| path.deinit(self.gpa);
            const path = hints_mod.HintPath{ .segments = self.current_span_path.items };
            self.pending_entry_span_path = try path.clone(self.gpa);
            self.pending_entry_value_span = value_span;
            self.pending_entry_statement_start = statement_start;
        }

        fn finalizePendingEntrySpan(self: *Self, statement_end: usize) !void {
            if (!track_spans) return;
            const path = self.pending_entry_span_path orelse return;
            const value_span = self.pending_entry_value_span orelse return;
            const statement_start = self.pending_entry_statement_start orelse return;
            try self.recordEntrySpanByPath(path, .{
                .value = value_span,
                .statement = .{ .start = statement_start, .end = statement_end },
            });
            var owned = path;
            owned.deinit(self.gpa);
            self.pending_entry_span_path = null;
            self.pending_entry_value_span = null;
            self.pending_entry_statement_start = null;
        }

        fn recordCurrentEntrySpan(self: *Self, statement_start: usize, value_span: spans_mod.ByteSpan) !void {
            if (!track_spans) return;
            if (self.current_span_path.items.len == 0) return;
            try self.recordEntrySpanByPath(.{ .segments = self.current_span_path.items }, .{
                .value = value_span,
                .statement = .{ .start = statement_start, .end = value_span.end },
            });
        }

        fn recordCurrentHeaderSpan(self: *Self, header_start: usize, header_end: usize, kind: spans_mod.HeaderKind) !void {
            if (!track_spans) return;
            if (self.span_table_path.items.len == 0) return;
            try self.recordHeaderSpanByPath(.{ .segments = self.span_table_path.items }, .{
                .header = .{ .start = header_start, .end = header_end },
                .kind = kind,
            });
        }

        fn recordStringHint(self: *Self, style: hints_mod.StringStyle) !void {
            const hints = self.hints orelse return;
            const styles = hints.string_styles orelse return;
            if (self.current_value_path.items.len == 0) return;
            const path = hints_mod.HintPath{ .segments = self.current_value_path.items };

            if (styles.getPtr(path)) |existing| {
                existing.* = style;
                return;
            }

            var owned = try path.clone(self.gpa);
            errdefer owned.deinit(self.gpa);
            try styles.put(self.gpa, owned, style);
        }

        fn recordScalarLexeme(self: *Self, raw: []const u8) !void {
            const hints = self.hints orelse return;
            _ = hints.value_lexemes orelse return;
            if (self.current_value_path.items.len == 0) return;
            try self.recordValueLexemeByPath(.{ .segments = self.current_value_path.items }, raw);
        }

        fn recordKeyStyleByPath(self: *Self, path: hints_mod.HintPath, style: hints_mod.KeyStyle) !void {
            const hints = self.hints orelse return;
            const key_styles = hints.key_styles orelse return;

            if (key_styles.getPtr(path)) |existing| {
                existing.* = style;
                return;
            }

            var owned = try path.clone(self.gpa);
            errdefer owned.deinit(self.gpa);
            try key_styles.put(self.gpa, owned, style);
        }

        fn recordKeyLexemeByPath(self: *Self, path: hints_mod.HintPath, raw: []const u8) !void {
            const hints = self.hints orelse return;
            const key_lexemes = hints.key_lexemes orelse return;

            if (key_lexemes.contains(path)) return;

            var owned = try path.clone(self.gpa);
            errdefer owned.deinit(self.gpa);
            const raw_owned = try self.gpa.dupe(u8, raw);
            errdefer self.gpa.free(raw_owned);
            try key_lexemes.put(self.gpa, owned, raw_owned);
        }

        fn recordValueLexemeByPath(self: *Self, path: hints_mod.HintPath, raw: []const u8) !void {
            const hints = self.hints orelse return;
            const value_lexemes = hints.value_lexemes orelse return;

            if (value_lexemes.contains(path)) return;

            var owned = try path.clone(self.gpa);
            errdefer owned.deinit(self.gpa);
            const raw_owned = try self.gpa.dupe(u8, raw);
            errdefer self.gpa.free(raw_owned);
            try value_lexemes.put(self.gpa, owned, raw_owned);
        }

        fn recordKeyStylesForTablePath(
            self: *Self,
            key_parts: [][]u8,
            key_styles: []const hints_mod.KeyStyle,
        ) !void {
            const hints = self.hints orelse return;
            _ = hints.key_styles orelse return;
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, self.table_path.items.len + key_parts.len);
            for (self.table_path.items) |part| {
                path_buf.appendAssumeCapacity(.{ .key = part });
            }
            for (key_parts, key_styles) |part, style| {
                path_buf.appendAssumeCapacity(.{ .key = part });
                try self.recordKeyStyleByPath(.{ .segments = path_buf.items }, style);
            }
        }

        fn recordKeyLexemesForTablePath(
            self: *Self,
            key_parts: [][]u8,
            raw_parts: []const []const u8,
        ) !void {
            const hints = self.hints orelse return;
            _ = hints.key_lexemes orelse return;
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, self.table_path.items.len + key_parts.len);
            for (self.table_path.items) |part| {
                path_buf.appendAssumeCapacity(.{ .key = part });
            }
            for (key_parts, raw_parts) |part, raw| {
                path_buf.appendAssumeCapacity(.{ .key = part });
                try self.recordKeyLexemeByPath(.{ .segments = path_buf.items }, raw);
            }
        }

        fn recordKeyStylesForCurrentValuePath(
            self: *Self,
            key_parts: [][]u8,
            key_styles: []const hints_mod.KeyStyle,
        ) !void {
            const hints = self.hints orelse return;
            _ = hints.key_styles orelse return;
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, self.current_value_path.items.len + key_parts.len);
            for (self.current_value_path.items) |segment| {
                path_buf.appendAssumeCapacity(segment);
            }
            for (key_parts, key_styles) |part, style| {
                path_buf.appendAssumeCapacity(.{ .key = part });
                try self.recordKeyStyleByPath(.{ .segments = path_buf.items }, style);
            }
        }

        fn recordKeyStylesForAbsolutePath(
            self: *Self,
            key_parts: [][]u8,
            key_styles: []const hints_mod.KeyStyle,
        ) !void {
            const hints = self.hints orelse return;
            _ = hints.key_styles orelse return;
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, key_parts.len);
            for (key_parts, key_styles) |part, style| {
                path_buf.appendAssumeCapacity(.{ .key = part });
                try self.recordKeyStyleByPath(.{ .segments = path_buf.items }, style);
            }
        }

        fn recordKeyLexemesForCurrentValuePath(
            self: *Self,
            key_parts: [][]u8,
            raw_parts: []const []const u8,
        ) !void {
            const hints = self.hints orelse return;
            _ = hints.key_lexemes orelse return;
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, self.current_value_path.items.len + key_parts.len);
            for (self.current_value_path.items) |segment| {
                path_buf.appendAssumeCapacity(segment);
            }
            for (key_parts, raw_parts) |part, raw| {
                path_buf.appendAssumeCapacity(.{ .key = part });
                try self.recordKeyLexemeByPath(.{ .segments = path_buf.items }, raw);
            }
        }

        fn recordKeyLexemesForAbsolutePath(
            self: *Self,
            key_parts: [][]u8,
            raw_parts: []const []const u8,
        ) !void {
            const hints = self.hints orelse return;
            _ = hints.key_lexemes orelse return;
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, key_parts.len);
            for (key_parts, raw_parts) |part, raw| {
                path_buf.appendAssumeCapacity(.{ .key = part });
                try self.recordKeyLexemeByPath(.{ .segments = path_buf.items }, raw);
            }
        }

        fn recordTableSyntaxByPath(self: *Self, path: hints_mod.HintPath, syntax: hints_mod.TableSyntax) !void {
            const hints = self.hints orelse return;
            const table_syntax = hints.table_syntax orelse return;

            if (table_syntax.getPtr(path)) |existing| {
                existing.* = syntax;
                return;
            }

            var owned = try path.clone(self.gpa);
            errdefer owned.deinit(self.gpa);
            try table_syntax.put(self.gpa, owned, syntax);
        }

        fn recordTableSyntaxForKeyParts(self: *Self, key_parts: [][]u8, syntax: hints_mod.TableSyntax) !void {
            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            const path = try self.pathForKey(key_parts, &path_buf);
            try self.recordTableSyntaxByPath(path, syntax);
        }

        fn recordIntermediateTableSyntaxForTablePath(
            self: *Self,
            key_parts: [][]u8,
            syntax: hints_mod.TableSyntax,
        ) !void {
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, self.table_path.items.len + key_parts.len);
            for (self.table_path.items) |part| {
                path_buf.appendAssumeCapacity(.{ .key = part });
            }
            for (key_parts) |part| {
                path_buf.appendAssumeCapacity(.{ .key = part });
                try self.recordTableSyntaxByPath(.{ .segments = path_buf.items }, syntax);
            }
        }

        fn recordTableSyntaxForCurrentValuePath(self: *Self, syntax: hints_mod.TableSyntax) !void {
            if (self.current_value_path.items.len == 0) return;
            try self.recordTableSyntaxByPath(.{ .segments = self.current_value_path.items }, syntax);
        }

        fn recordTableSyntaxForAbsoluteKeyParts(self: *Self, key_parts: [][]u8, syntax: hints_mod.TableSyntax) !void {
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, key_parts.len);
            for (key_parts) |part| {
                path_buf.appendAssumeCapacity(.{ .key = part });
            }
            try self.recordTableSyntaxByPath(.{ .segments = path_buf.items }, syntax);
        }

        fn recordIntermediateTableSyntaxForCurrentValuePath(
            self: *Self,
            key_parts: [][]u8,
            syntax: hints_mod.TableSyntax,
        ) !void {
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, self.current_value_path.items.len + key_parts.len);
            for (self.current_value_path.items) |segment| {
                path_buf.appendAssumeCapacity(segment);
            }
            for (key_parts) |part| {
                path_buf.appendAssumeCapacity(.{ .key = part });
                try self.recordTableSyntaxByPath(.{ .segments = path_buf.items }, syntax);
            }
        }

        fn recordIntermediateTableSyntaxForAbsolutePath(
            self: *Self,
            key_parts: [][]u8,
            syntax: hints_mod.TableSyntax,
        ) !void {
            if (key_parts.len == 0) return;

            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, key_parts.len);
            for (key_parts) |part| {
                path_buf.appendAssumeCapacity(.{ .key = part });
                try self.recordTableSyntaxByPath(.{ .segments = path_buf.items }, syntax);
            }
        }

        fn appendCommentRecordByPath(
            self: *Self,
            path: hints_mod.HintPath,
            attachment: hints_mod.CommentAttachment,
            text: []const u8,
            raw: ?[]const u8,
        ) !void {
            const hints = self.hints orelse return;
            const comments = hints.comments orelse return;

            if (comments.getPtr(path)) |records| {
                try records.append(self.gpa, .{ .attachment = attachment, .text = text, .raw = raw });
                return;
            }

            var owned = try path.clone(self.gpa);
            errdefer owned.deinit(self.gpa);

            var records: hints_mod.CommentList = .empty;
            errdefer records.deinit(self.gpa);
            try records.append(self.gpa, .{ .attachment = attachment, .text = text, .raw = raw });
            try comments.put(self.gpa, owned, records);
        }

        fn appendCommentRecordForKey(
            self: *Self,
            key_parts: [][]u8,
            attachment: hints_mod.CommentAttachment,
            text: []const u8,
            raw: ?[]const u8,
        ) !void {
            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            const path = try self.pathForKey(key_parts, &path_buf);
            try self.appendCommentRecordByPath(path, attachment, text, raw);
        }

        fn appendCommentRecordForAbsoluteKey(
            self: *Self,
            key_parts: [][]u8,
            attachment: hints_mod.CommentAttachment,
            text: []const u8,
            raw: ?[]const u8,
        ) !void {
            var path_buf: std.ArrayList(hints_mod.PathSegment) = .empty;
            defer path_buf.deinit(self.gpa);
            try path_buf.ensureTotalCapacity(self.gpa, key_parts.len);
            for (key_parts) |part| {
                path_buf.appendAssumeCapacity(.{ .key = part });
            }
            try self.appendCommentRecordByPath(.{ .segments = path_buf.items }, attachment, text, raw);
        }

        fn flushPendingComments(
            self: *Self,
            key_parts: [][]u8,
            attachment: hints_mod.CommentAttachment,
        ) !void {
            for (self.pending_comments.items) |comment| {
                try self.appendCommentRecordForKey(key_parts, attachment, comment.text, comment.raw);
            }
            self.pending_comments.clearRetainingCapacity();
        }

        fn flushPendingCommentsAbsolute(
            self: *Self,
            key_parts: [][]u8,
            attachment: hints_mod.CommentAttachment,
        ) !void {
            for (self.pending_comments.items) |comment| {
                try self.appendCommentRecordForAbsoluteKey(key_parts, attachment, comment.text, comment.raw);
            }
            self.pending_comments.clearRetainingCapacity();
        }

        fn captureAttachedComment(
            self: *Self,
            key_parts: [][]u8,
            attachment: hints_mod.CommentAttachment,
            raw_start: usize,
        ) ParseError!void {
            self.advance();
            const start = self.pos;
            while (self.peek()) |c| {
                if (c == '\n' or c == '\r') break;
                if (c != '\t' and (c < 0x20 or c == 0x7F))
                    return self.fail("control character U+{X:0>4} not allowed in comment", .{c});
                self.advance();
            }
            const trimmed = std.mem.trim(u8, self.input[start..self.pos], " \t");
            try self.appendCommentRecordForKey(key_parts, attachment, trimmed, self.input[raw_start..self.pos]);
        }

        fn captureAttachedCommentAbsolute(
            self: *Self,
            key_parts: [][]u8,
            attachment: hints_mod.CommentAttachment,
            raw_start: usize,
        ) ParseError!void {
            self.advance();
            const start = self.pos;
            while (self.peek()) |c| {
                if (c == '\n' or c == '\r') break;
                if (c != '\t' and (c < 0x20 or c == 0x7F))
                    return self.fail("control character U+{X:0>4} not allowed in comment", .{c});
                self.advance();
            }
            const trimmed = std.mem.trim(u8, self.input[start..self.pos], " \t");
            try self.appendCommentRecordForAbsoluteKey(key_parts, attachment, trimmed, self.input[raw_start..self.pos]);
        }

        fn createMeta(self: *Self, tbl: *TableType, kind: TableKind) Allocator.Error!*TableMeta {
            const ma = self.meta_arena.allocator();
            const m = try ma.create(TableMeta);
            m.* = .{ .kind = kind, .key_kinds = .empty };
            try self.table_metas.put(ma, tbl, m);
            return m;
        }

        fn getMeta(self: *Self, tbl: *TableType) *TableMeta {
            return self.table_metas.get(tbl).?;
        }

        fn fail(self: *Self, comptime fmt: []const u8, args: anytype) ParseError {
            self.err_info.line = self.line;
            self.err_info.col = @intCast(if (self.pos >= self.line_start) self.pos - self.line_start + 1 else 1);
            const msg = std.fmt.bufPrint(&self.err_info._buf, fmt, args) catch blk: {
                const s = "error message too long";
                @memcpy(self.err_info._buf[0..s.len], s);
                break :blk self.err_info._buf[0..s.len];
            };
            self.err_info._len = msg.len;
            return error.ParseFailed;
        }

        inline fn peek(self: *const Self) ?u8 {
            if (self.pos >= self.input.len) return null;
            return self.input[self.pos];
        }

        inline fn peekAt(self: *const Self, offset: usize) ?u8 {
            const i = self.pos + offset;
            if (i >= self.input.len) return null;
            return self.input[i];
        }

        inline fn advance(self: *Self) void {
            if (self.pos < self.input.len) {
                if (self.input[self.pos] == '\n') {
                    self.line += 1;
                    self.line_start = self.pos + 1;
                }
                self.pos += 1;
            }
        }

        inline fn eat(self: *Self, ch: u8) bool {
            if (self.peek() == ch) {
                self.advance();
                return true;
            }
            return false;
        }

        fn expect(self: *Self, ch: u8) ParseError!void {
            if (!self.eat(ch)) return self.fail("expected '{c}', found '{?c}'", .{ ch, self.peek() });
        }

        fn skipInlineWs(self: *Self) void {
            while (self.peek()) |c| {
                if (c == ' ' or c == '\t') self.advance() else break;
            }
        }

        fn skipTrivia(self: *Self) ParseError!void {
            while (self.peek()) |c| switch (c) {
                ' ', '\t', '\n' => self.advance(),
                '\r' => if (self.peekAt(1) == '\n') {
                    self.advance();
                    self.advance();
                } else return self.fail("bare CR not allowed", .{}),
                '#' => try self.skipComment(null),
                else => break,
            };
        }

        fn skipComment(self: *Self, raw_start: ?usize) ParseError!void {
            const comment_raw_start = raw_start orelse self.line_start;
            self.advance();
            const start = self.pos;
            while (self.peek()) |c| {
                if (c == '\n' or c == '\r') break;
                if (c != '\t' and (c < 0x20 or c == 0x7F))
                    return self.fail("control character U+{X:0>4} not allowed in comment", .{c});
                self.advance();
            }
            const trimmed = std.mem.trim(u8, self.input[start..self.pos], " \t");
            const hints = self.hints orelse return;
            const comments = hints.comments orelse return;

            if (self.trailing_path) |path| {
                _ = comments;
                try self.appendCommentRecordByPath(path, .trailing_entry, trimmed, self.input[comment_raw_start..self.pos]);
                var owned = self.trailing_path.?;
                owned.deinit(self.gpa);
                self.trailing_path = null;
            } else if (self.current_value_path.items.len == 0) {
                try self.pending_comments.append(self.gpa, .{ .text = trimmed, .raw = self.input[comment_raw_start..self.pos] });
            }
        }

        fn skipToEOL(self: *Self) ParseError!void {
            while (self.peek()) |c| {
                if (c == '\n') {
                    self.advance();
                    return;
                }
                if (c == '\r') {
                    if (self.peekAt(1) != '\n') return self.fail("bare CR not allowed", .{});
                    self.advance();
                    self.advance();
                    return;
                }
                self.advance();
            }
        }

        inline fn isEOL(self: *const Self) bool {
            const c = self.peek() orelse return true;
            return switch (c) {
                '\n' => true,
                '\r' => self.peekAt(1) == '\n',
                else => false,
            };
        }

        fn eatNewline(self: *Self) ParseError!void {
            if (self.peek()) |c| switch (c) {
                '\n' => self.advance(),
                '\r' => {
                    self.advance();
                    if (self.peek() != '\n') return self.fail("bare CR not allowed", .{});
                    self.advance();
                },
                else => {},
            };
        }

        // ─── key parsing ─────────────────────────────────────────────────────────

        fn parseKeyPart(self: *Self) ParseError!struct { text: []u8, style: hints_mod.KeyStyle, raw: []const u8 } {
            const ParsedKeyPart = struct {
                text: []u8,
                style: hints_mod.KeyStyle,
            };
            const start = self.pos;
            const parsed: ParsedKeyPart = switch (self.peek() orelse 0) {
                '"' => .{ .text = try self.parseBasicStringRaw(), .style = .basic },
                '\'' => .{ .text = try self.parseLiteralStringRaw(), .style = .literal },
                else => .{ .text = try self.parseBareKey(), .style = .bare },
            };
            errdefer self.gpa.free(parsed.text);
            return .{
                .text = parsed.text,
                .style = parsed.style,
                .raw = self.input[start..self.pos],
            };
        }

        fn parseBareKey(self: *Self) ParseError![]u8 {
            const start = self.pos;
            while (self.peek()) |c| {
                if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') self.advance() else break;
            }
            if (self.pos == start) return self.fail("expected a key", .{});
            return try self.gpa.dupe(u8, self.input[start..self.pos]);
        }

        fn parseDottedKey(self: *Self) ParseError!ParsedKeyPath {
            var parts: std.ArrayList([]u8) = .empty;
            var styles: std.ArrayList(hints_mod.KeyStyle) = .empty;
            var raw_parts: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (parts.items) |p| self.gpa.free(p);
                parts.deinit(self.gpa);
                styles.deinit(self.gpa);
                raw_parts.deinit(self.gpa);
            }
            // Styles and raw text feed only the hint recorders, which ignore them
            // when no hints are collected.
            const collect = self.hints != null;
            const first = try self.parseKeyPart();
            var first_owned = true;
            errdefer if (first_owned) self.gpa.free(first.text);
            try parts.append(self.gpa, first.text);
            first_owned = false;
            if (collect) {
                try styles.append(self.gpa, first.style);
                try raw_parts.append(self.gpa, first.raw);
            }
            while (true) {
                self.skipInlineWs();
                if (!self.eat('.')) break;
                self.skipInlineWs();
                const next_key = try self.parseKeyPart();
                var next_owned = true;
                errdefer if (next_owned) self.gpa.free(next_key.text);
                try parts.append(self.gpa, next_key.text);
                next_owned = false;
                if (collect) {
                    try styles.append(self.gpa, next_key.style);
                    try raw_parts.append(self.gpa, next_key.raw);
                }
            }
            return .{ .parts = parts, .styles = styles, .raw_parts = raw_parts };
        }

        // ─── string parsing ───────────────────────────────────────────────────────

        fn parseBasicStringRaw(self: *Self) ParseError![]u8 {
            try self.expect('"');
            const start = self.pos;
            var i: usize = 0;
            while (true) {
                const c = self.peekAt(i) orelse return self.fail("unterminated string", .{});
                if (c == '"') {
                    self.pos += i;
                    try self.expect('"');
                    return try self.gpa.dupe(u8, self.input[start .. self.pos - 1]);
                }
                if (c == '\\' or c == '\r' or c == '\n' or (c < 0x20 and c != '\t') or c == 0x7F) break;
                i += 1;
            }
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(self.gpa);
            try buf.ensureTotalCapacity(self.gpa, i + string_buffer_slack);
            try self.parseBasicStringContents(&buf);
            try self.expect('"');
            return buf.toOwnedSlice(self.gpa) catch error.OutOfMemory;
        }

        // ValueView-aware: returns borrowed `[]const u8` for fast path
        // (no allocation) when V is ValueView. Keys are always allocated.
        fn parseViewString(self: *Self) ParseError![]const u8 {
            try self.expect('"');
            const start = self.pos;
            var i: usize = 0;
            while (true) {
                const c = self.peekAt(i) orelse return self.fail("unterminated string", .{});
                if (c == '"') {
                    self.pos += i;
                    try self.expect('"');
                    return self.input[start .. self.pos - 1];
                }
                if (c == '\\' or c == '\r' or c == '\n' or (c < 0x20 and c != '\t') or c == 0x7F) break;
                i += 1;
            }
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(self.gpa);
            try buf.ensureTotalCapacity(self.gpa, i + string_buffer_slack);
            try self.parseBasicStringContents(&buf);
            try self.expect('"');
            return buf.toOwnedSlice(self.gpa) catch error.OutOfMemory;
        }

        fn parseMLString(self: *Self, comptime basic: bool) ParseError!V {
            const delim: u8 = if (basic) '"' else '\'';
            try self.expect(delim);
            try self.expect(delim);
            try self.expect(delim);
            _ = self.eat('\r');
            _ = self.eat('\n');
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(self.gpa);
            outer: while (true) {
                const c = self.peek() orelse return self.fail("unterminated multi-line {s} string", .{if (basic) "basic" else "literal"});
                if (c == delim) {
                    var q: usize = 0;
                    while (self.peek() == delim and q < 5) {
                        self.advance();
                        q += 1;
                    }
                    if (q >= 3) {
                        for (0..q - 3) |_| try buf.append(self.gpa, delim);
                        break :outer;
                    }
                    for (0..q) |_| try buf.append(self.gpa, delim);
                    continue;
                }
                if (basic and c == '\\') {
                    self.advance();
                    try self.processEscape(&buf, true);
                    continue;
                }
                if (c == '\r') {
                    self.advance();
                    if (self.peek() != '\n') return self.fail("bare CR not allowed in string", .{});
                    try buf.append(self.gpa, '\n');
                    self.advance();
                    continue;
                }
                if (c != '\t' and c != '\n' and (c < 0x20 or c == 0x7F))
                    return self.fail("control character U+{X:0>4} not allowed in string", .{c});
                self.advance();
                try buf.append(self.gpa, c);
            }
            return .{ .string = try buf.toOwnedSlice(self.gpa) };
        }

        fn parseMLBasicString(self: *Self) ParseError!V {
            return self.parseMLString(true);
        }
        fn parseMLLiteralString(self: *Self) ParseError!V {
            return self.parseMLString(false);
        }

        fn parseBasicStringContents(self: *Self, buf: *std.ArrayList(u8)) ParseError!void {
            while (true) {
                const c = self.peek() orelse return self.fail("unterminated string", .{});
                if (c == '"') return;
                if (c == '\\') {
                    self.advance();
                    try self.processEscape(buf, false);
                    continue;
                }
                if (c == '\r') return self.fail("newline in single-line string", .{});
                if (c == '\n') return self.fail("newline in single-line string", .{});
                if (c != '\t' and (c < 0x20 or c == 0x7F))
                    return self.fail("control character U+{X:0>4} not allowed in string", .{c});
                self.advance();
                try buf.append(self.gpa, c);
            }
        }

        fn processEscape(self: *Self, buf: *std.ArrayList(u8), multiline: bool) ParseError!void {
            const c = self.peek() orelse return self.fail("unterminated escape sequence", .{});
            switch (c) {
                'b' => {
                    self.advance();
                    try buf.append(self.gpa, '\x08');
                },
                't' => {
                    self.advance();
                    try buf.append(self.gpa, '\t');
                },
                'n' => {
                    self.advance();
                    try buf.append(self.gpa, '\n');
                },
                'f' => {
                    self.advance();
                    try buf.append(self.gpa, '\x0C');
                },
                'r' => {
                    self.advance();
                    try buf.append(self.gpa, '\r');
                },
                'e' => {
                    self.advance();
                    try buf.append(self.gpa, '\x1B');
                },
                '"' => {
                    self.advance();
                    try buf.append(self.gpa, '"');
                },
                '\\' => {
                    self.advance();
                    try buf.append(self.gpa, '\\');
                },
                'x' => {
                    self.advance();
                    const cp = try self.parseHexEscape(2);
                    try appendCodepoint(self, buf, cp);
                },
                'u' => {
                    self.advance();
                    const cp = try self.parseHexEscape(4);
                    try appendCodepoint(self, buf, cp);
                },
                'U' => {
                    self.advance();
                    const cp = try self.parseHexEscape(8);
                    try appendCodepoint(self, buf, cp);
                },
                '\n', '\r' => {
                    if (!multiline) return self.fail("line-ending backslash only in multi-line strings", .{});
                    while (self.peek()) |ch| {
                        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') self.advance() else break;
                    }
                },
                ' ', '\t' => {
                    if (!multiline) return self.fail("invalid escape sequence '\\{c}'", .{c});
                    while (self.peek()) |ch| {
                        if (ch == ' ' or ch == '\t') self.advance() else break;
                    }
                    if (self.peek() != '\n' and self.peek() != '\r')
                        return self.fail("backslash-whitespace only valid before newline in multi-line strings", .{});
                    while (self.peek()) |ch| {
                        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') self.advance() else break;
                    }
                },
                else => return self.fail("invalid escape sequence '\\{c}'", .{c}),
            }
        }

        fn appendCodepoint(self: *Self, buf: *std.ArrayList(u8), cp: u32) ParseError!void {
            if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF))
                return self.fail("invalid unicode scalar U+{X:0>6}", .{cp});
            var tmp: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(cp), &tmp) catch
                return self.fail("invalid unicode scalar U+{X:0>6}", .{cp});
            try buf.appendSlice(self.gpa, tmp[0..len]);
        }

        fn parseHexEscape(self: *Self, digits: usize) ParseError!u32 {
            var val: u32 = 0;
            for (0..digits) |_| {
                const c = self.peek() orelse return self.fail("incomplete hex escape", .{});
                const d: u32 = switch (c) {
                    '0'...'9' => c - '0',
                    'a'...'f' => c - 'a' + 10,
                    'A'...'F' => c - 'A' + 10,
                    else => return self.fail("invalid hex digit '{c}'", .{c}),
                };
                val = (val << 4) | d;
                self.advance();
            }
            return val;
        }

        fn parseLiteralStringRaw(self: *Self) ParseError![]u8 {
            try self.expect('\'');
            const start = self.pos;
            while (true) {
                const c = self.peek() orelse return self.fail("unterminated literal string", .{});
                if (c == '\'') break;
                if (c == '\n' or c == '\r') return self.fail("newline in single-line literal string", .{});
                if (c != '\t' and (c < 0x20 or c == 0x7F)) return self.fail("control character U+{X:0>4} not allowed in literal string", .{c});
                self.advance();
            }
            const s = try self.gpa.dupe(u8, self.input[start..self.pos]);
            try self.expect('\'');
            return s;
        }

        // View-optimized: returns borrowed `[]const u8` for fast path
        // (literal strings have no escapes, so always fast).
        fn parseViewLiteralString(self: *Self) ParseError![]const u8 {
            try self.expect('\'');
            const start = self.pos;
            while (true) {
                const c = self.peek() orelse return self.fail("unterminated literal string", .{});
                if (c == '\'') break;
                if (c == '\n' or c == '\r') return self.fail("newline in single-line literal string", .{});
                if (c != '\t' and (c < 0x20 or c == 0x7F)) return self.fail("control character U+{X:0>4} not allowed in literal string", .{c});
                self.advance();
            }
            const s = self.input[start..self.pos];
            try self.expect('\'');
            return s;
        }

        // ─── value parsing ────────────────────────────────────────────────────────

        fn parseValue(self: *Self) ParseError!V {
            const start = self.pos;
            const c = self.peek() orelse return self.fail("expected a value", .{});
            const value: V = try switch (c) {
                '"' => if (self.peekAt(1) == '"' and self.peekAt(2) == '"') blk: {
                    const v = try self.parseMLBasicString();
                    try self.recordStringHint(.multiline_basic);
                    break :blk v;
                } else blk: {
                    if (comptime V == types.Value) {
                        const s = try self.parseBasicStringRaw();
                        try self.recordStringHint(.basic);
                        break :blk V{ .string = s };
                    } else {
                        const s = try self.parseViewString();
                        try self.recordStringHint(.basic);
                        break :blk V{ .string = s };
                    }
                },
                '\'' => if (self.peekAt(1) == '\'' and self.peekAt(2) == '\'') blk: {
                    const v = try self.parseMLLiteralString();
                    try self.recordStringHint(.multiline_literal);
                    break :blk v;
                } else blk: {
                    if (comptime V == types.Value) {
                        const s = try self.parseLiteralStringRaw();
                        try self.recordStringHint(.literal);
                        break :blk V{ .string = s };
                    } else {
                        const s = try self.parseViewLiteralString();
                        try self.recordStringHint(.literal);
                        break :blk V{ .string = s };
                    }
                },
                't' => self.parseTrue(),
                'f' => self.parseFalse(),
                '[' => self.parseArray(),
                '{' => self.parseInlineTable(),
                '+', '-', '0'...'9' => self.parseNumericOrDatetime(),
                'i', 'n' => self.parseInfOrNan(),
                else => self.fail("unexpected character '{c}' while parsing value", .{c}),
            };
            switch (value) {
                .float, .offset_datetime, .local_datetime, .local_date, .local_time => try self.recordScalarLexeme(self.input[start..self.pos]),
                else => {},
            }
            return value;
        }

        fn parseTrue(self: *Self) ParseError!V {
            if (self.input.len - self.pos >= 4 and std.mem.eql(u8, self.input[self.pos .. self.pos + 4], "true")) {
                self.pos += 4;
                return .{ .boolean = true };
            }
            return self.fail("expected 'true'", .{});
        }

        fn parseFalse(self: *Self) ParseError!V {
            if (self.input.len - self.pos >= 5 and std.mem.eql(u8, self.input[self.pos .. self.pos + 5], "false")) {
                self.pos += 5;
                return .{ .boolean = false };
            }
            return self.fail("expected 'false'", .{});
        }

        fn parseInfOrNan(self: *Self) ParseError!V {
            const sign: f64 = if (self.peek() == '+') blk: {
                self.advance();
                break :blk 1.0;
            } else if (self.peek() == '-') blk: {
                self.advance();
                break :blk -1.0;
            } else 1.0;
            const rem = self.input[self.pos..];
            if (rem.len >= 3 and std.mem.eql(u8, rem[0..3], "inf")) {
                self.pos += 3;
                return .{ .float = sign * std.math.inf(f64) };
            }
            if (rem.len >= 3 and std.mem.eql(u8, rem[0..3], "nan")) {
                self.pos += 3;
                return .{ .float = std.math.nan(f64) };
            }
            return self.fail("expected 'inf' or 'nan'", .{});
        }

        fn parseNumericOrDatetime(self: *Self) ParseError!V {
            const sign_offset: usize = if (self.peek() == '+' or self.peek() == '-') 1 else 0;
            if (sign_offset == 1) {
                const rest = self.input[self.pos + 1 ..];
                if (rest.len >= 3 and (std.mem.startsWith(u8, rest, "inf") or std.mem.startsWith(u8, rest, "nan")))
                    return self.parseInfOrNan();
            }
            // Starts with HH:MM — must be a local time, not a date.
            if (sign_offset == 0 and isDigit(self.peek()) and isDigit(self.peekAt(1)) and self.peekAt(2) == ':')
                return self.parseDatetimeOrTime();
            // Four digits then a dash: must be a date, not a number or time.
            if (sign_offset == 0 and self.peekAt(4) == '-' and
                isDigit(self.peek()) and isDigit(self.peekAt(1)) and
                isDigit(self.peekAt(2)) and isDigit(self.peekAt(3)))
                return self.parseDatetimeOrTime();
            return self.parseIntOrFloat();
        }

        fn parseDatetimeOrTime(self: *Self) ParseError!V {
            if (isDigit(self.peek()) and isDigit(self.peekAt(1)) and
                self.peekAt(2) == ':' and self.peekAt(4) != '-')
            {
                return .{ .local_time = try self.parseLocalTime() };
            }
            const date = try self.parseLocalDate();
            const sep = self.peek();
            if (sep == 'T' or sep == 't' or (sep == ' ' and isDigit(self.peekAt(1)))) {
                self.advance();
                const time = try self.parseLocalTime();
                const off_ch = self.peek();
                if (off_ch == 'Z' or off_ch == 'z' or off_ch == '+' or off_ch == '-') {
                    return .{ .offset_datetime = .{ .date = date, .time = time, .offset_minutes = try self.parseOffset() } };
                }
                return .{ .local_datetime = .{ .date = date, .time = time } };
            }
            return .{ .local_date = date };
        }

        fn parseLocalDate(self: *Self) ParseError!LocalDate {
            const y = try self.parseNDigits(4);
            try self.expect('-');
            const mo = try self.parseNDigits(2);
            try self.expect('-');
            const d = try self.parseNDigits(2);
            if (mo < 1 or mo > 12) return self.fail("invalid month {d}", .{mo});
            const max_day = daysInMonth(y, mo);
            if (d < 1 or d > max_day) return self.fail("invalid day {d}", .{d});
            return .{ .year = @intCast(y), .month = @intCast(mo), .day = @intCast(d) };
        }

        fn parseLocalTime(self: *Self) ParseError!LocalTime {
            const h = try self.parseNDigits(2);
            try self.expect(':');
            const m = try self.parseNDigits(2);
            if (h > 23) return self.fail("invalid hour {d}", .{h});
            if (m > 59) return self.fail("invalid minute {d}", .{m});
            var s: u32 = 0;
            if (self.peek() == ':') {
                self.advance();
                s = try self.parseNDigits(2);
                if (s > 60) return self.fail("invalid second {d}", .{s});
            }
            var ns: u32 = 0;
            if (self.eat('.')) {
                const start = self.pos;
                while (isDigit(self.peek())) self.advance();
                const frac = self.input[start..self.pos];
                if (frac.len == 0) return self.fail("expected digits after decimal point in time", .{});
                var v: u32 = 0;
                var used: usize = 0;
                for (frac) |dc| {
                    if (used >= 9) break;
                    v = v * 10 + (dc - '0');
                    used += 1;
                }
                var scale: u32 = 1;
                var rem2: usize = 9 - used;
                while (rem2 > 0) : (rem2 -= 1) scale *= 10;
                ns = v * scale;
            }
            return .{ .hour = @intCast(h), .minute = @intCast(m), .second = @intCast(s), .nanosecond = ns };
        }

        fn parseOffset(self: *Self) ParseError!i16 {
            const c = self.peek() orelse return self.fail("expected offset", .{});
            if (c == 'Z' or c == 'z') {
                self.advance();
                return 0;
            }
            const neg = c == '-';
            self.advance();
            const h = try self.parseNDigits(2);
            try self.expect(':');
            const m = try self.parseNDigits(2);
            if (h > 23 or m > 59) return self.fail("invalid UTC offset", .{});
            const tot: i16 = @intCast(h * 60 + m);
            return if (neg) -tot else tot;
        }

        // ─── number parsing helpers ────────────────────────────────────────────────

        fn parseNDigits(self: *Self, n: usize) ParseError!u32 {
            var v: u32 = 0;
            for (0..n) |_| {
                const c = self.peek() orelse return self.fail("expected {d} digits", .{n});
                if (!isDigit(c)) return self.fail("expected digit, found '{c}'", .{c});
                v = v * 10 + (c - '0');
                self.advance();
            }
            return v;
        }

        fn consumeDigitsWithUnderscores(self: *Self) ParseError!usize {
            const start = self.pos;
            var saw_digit = false;
            var last_was_underscore = false;

            while (self.peek()) |c| switch (c) {
                '0'...'9' => {
                    saw_digit = true;
                    last_was_underscore = false;
                    self.advance();
                },
                '_' => {
                    if (!saw_digit or last_was_underscore) return self.fail("invalid underscore in number", .{});
                    const next = self.peekAt(1) orelse return self.fail("invalid underscore in number", .{});
                    if (!isDigit(next)) return self.fail("invalid underscore in number", .{});
                    last_was_underscore = true;
                    self.advance();
                },
                else => break,
            };

            if (!saw_digit or last_was_underscore) return self.fail("expected digits", .{});
            return start;
        }

        fn sanitizedNumber(self: *Self, start: usize, end: usize, buf: []u8) ParseError![]const u8 {
            var len: usize = 0;
            for (self.input[start..end]) |c| {
                if (c == '_') continue;
                if (len >= buf.len) return self.fail("number literal too long", .{});
                buf[len] = c;
                len += 1;
            }
            return buf[0..len];
        }

        fn parsePrefixedInt(self: *Self, comptime base: u8, comptime prefix: []const u8) ParseError!V {
            std.debug.assert(self.peek() == '0');
            std.debug.assert(self.peekAt(1) != null and self.peekAt(1).? == prefix[1]);

            self.pos += 2;
            const start = self.pos;
            var saw_digit = false;
            var last_was_underscore = false;

            while (self.peek()) |c| {
                if (isBaseDigit(c, base)) {
                    saw_digit = true;
                    last_was_underscore = false;
                    self.advance();
                    continue;
                }

                if (c == '_') {
                    if (!saw_digit or last_was_underscore) return self.fail("invalid underscore in integer", .{});
                    const next = self.peekAt(1) orelse return self.fail("invalid underscore in integer", .{});
                    if (!isBaseDigit(next, base)) return self.fail("invalid underscore in integer", .{});
                    last_was_underscore = true;
                    self.advance();
                    continue;
                }

                break;
            }

            if (!saw_digit or last_was_underscore) return self.fail("invalid {s} integer", .{prefix});

            var buf: [72]u8 = undefined;
            const numstr = try self.sanitizedNumber(start, self.pos, &buf);
            const v = std.fmt.parseInt(i64, numstr, base) catch return self.fail("invalid {s} integer", .{prefix});
            const int_base: types.Base = if (prefix[1] == 'x') .hex else if (prefix[1] == 'o') .octal else .binary;
            return .{ .integer = .{ .value = v, .base = int_base } };
        }

        fn parseIntOrFloat(self: *Self) ParseError!V {
            const start = self.pos;
            const has_sign = self.peek() == '+' or self.peek() == '-';
            if (has_sign) self.advance();
            if (self.peek() == '0') {
                if (self.peekAt(1) == 'X') return self.fail("uppercase hexadecimal prefix is not allowed", .{});
                if (self.peekAt(1) == 'x') {
                    if (has_sign) return self.fail("sign not allowed for hexadecimal integer", .{});
                    return self.parsePrefixedInt(16, "0x");
                }
                if (self.peekAt(1) == 'o') {
                    if (has_sign) return self.fail("sign not allowed for octal integer", .{});
                    return self.parsePrefixedInt(8, "0o");
                }
                if (self.peekAt(1) == 'b') {
                    if (has_sign) return self.fail("sign not allowed for binary integer", .{});
                    return self.parsePrefixedInt(2, "0b");
                }
            }

            const int_start = try self.consumeDigitsWithUnderscores();
            const int_end = self.pos;
            var is_float = false;

            const integer_digits = self.input[int_start..int_end];
            const integer_starts_with_zero = integer_digits.len > 0 and integer_digits[0] == '0';
            const integer_is_zero = std.mem.eql(u8, integer_digits, "0");

            if (self.peek() == '.') {
                is_float = true;
                self.advance();
                _ = try self.consumeDigitsWithUnderscores();
            }

            if (self.peek() == 'e' or self.peek() == 'E') {
                is_float = true;
                self.advance();
                if (self.peek() == '+' or self.peek() == '-') self.advance();
                _ = try self.consumeDigitsWithUnderscores();
            }

            if (is_float and integer_starts_with_zero and !integer_is_zero)
                return self.fail("leading zeros in float", .{});

            var buf: [64]u8 = undefined;
            const numstr = try self.sanitizedNumber(start, self.pos, &buf);
            if (is_float) {
                return .{ .float = std.fmt.parseFloat(f64, numstr) catch return self.fail("invalid float '{s}'", .{numstr}) };
            } else {
                const s = if (numstr[0] == '+' or numstr[0] == '-') numstr[1..] else numstr;
                if (s.len > 1 and s[0] == '0') return self.fail("leading zeros in integer", .{});
                const dec = std.fmt.parseInt(i64, numstr, 10) catch return self.fail("invalid integer '{s}'", .{numstr});
                return .{ .integer = .{ .value = dec } };
            }
        }

        fn parseArray(self: *Self) ParseError!V {
            try self.expect('[');
            const arr = try self.gpa.create(ArrayType);
            arr.* = .empty;
            errdefer {
                for (arr.items) |*item| self.dropValue(item.*);
                arr.deinit(self.gpa);
                self.gpa.destroy(arr);
            }
            try self.skipTrivia();
            var next_index: usize = 0;
            while (self.peek() != ']') {
                if (self.peek() == null) return self.fail("unterminated array", .{});
                const path_len = try self.pushCurrentValueIndex(next_index);
                const span_path_len = try self.pushCurrentSpanIndex(next_index);
                errdefer self.restoreCurrentValuePath(path_len);
                errdefer self.restoreCurrentSpanPath(span_path_len);
                const v = try self.parseValue();
                errdefer self.dropValue(v);
                self.restoreCurrentValuePath(path_len);
                self.restoreCurrentSpanPath(span_path_len);
                try arr.append(self.gpa, v);
                next_index += 1;
                try self.skipTrivia();
                if (!self.eat(',')) {
                    try self.skipTrivia();
                    break;
                }
                try self.skipTrivia();
            }
            try self.expect(']');
            return .{ .array = arr };
        }

        fn parseInlineTable(self: *Self) ParseError!V {
            try self.expect('{');
            const tbl = try self.gpa.create(TableType);
            tbl.* = .empty;
            errdefer {
                self.dropTable(tbl);
                if (comptime V == types.Value) self.gpa.destroy(tbl);
            }
            _ = try self.createMeta(tbl, .inline_t);
            const open_pos = self.pos;
            try self.skipTrivia();
            const padded_after_open = self.pos != open_pos;
            var padded_before_close = false;
            while (self.peek() != '}') {
                if (self.peek() == null) return self.fail("unterminated inline table", .{});
                const statement_start = self.pos;
                var key_parts = try self.parseDottedKey();
                defer key_parts.deinit(self.gpa);
                try self.recordKeyStylesForCurrentValuePath(key_parts.parts.items, key_parts.styles.items);
                try self.recordKeyLexemesForCurrentValuePath(key_parts.parts.items, key_parts.raw_parts.items);
                if (key_parts.parts.items.len > 1) {
                    try self.recordIntermediateTableSyntaxForCurrentValuePath(key_parts.parts.items[0 .. key_parts.parts.items.len - 1], .dotted);
                }
                self.skipInlineWs();
                try self.expect('=');
                self.skipInlineWs();
                const path_len = try self.pushCurrentValueKeys(key_parts.parts.items);
                const span_path_len = try self.pushCurrentSpanKeys(key_parts.parts.items);
                errdefer self.restoreCurrentValuePath(path_len);
                errdefer self.restoreCurrentSpanPath(span_path_len);
                const value_start = self.pos;
                const val = try self.parseValue();
                errdefer self.dropValue(val);
                try self.setNestedKey(tbl, key_parts.parts.items, val, true);
                try self.recordCurrentEntrySpan(statement_start, .{ .start = value_start, .end = self.pos });
                self.restoreCurrentValuePath(path_len);
                self.restoreCurrentSpanPath(span_path_len);
                const trivia_start = self.pos;
                try self.skipTrivia();
                if (self.peek() == '}' and self.pos != trivia_start) padded_before_close = true;
                if (!self.eat(',')) {
                    try self.skipTrivia();
                    break;
                }
                try self.skipTrivia();
            }
            try self.expect('}');
            try self.recordTableSyntaxForCurrentValuePath(if (padded_after_open or padded_before_close) .inline_spaced else .inline_compact);
            return .{ .table = tbl };
        }

        // ─── nested key assignment ────────────────────────────────────────────────

        fn setNestedKey(self: *Self, base: *TableType, parts: [][]u8, value: V, inline_ctx: bool) ParseError!void {
            std.debug.assert(parts.len > 0);
            const ma = self.meta_arena.allocator();
            var tbl = base;
            var meta = self.getMeta(tbl);

            for (parts[0 .. parts.len - 1]) |part| {
                if (meta.kind == .inline_t and !inline_ctx)
                    return self.fail("cannot extend inline table", .{});
                const gop = tbl.getOrPut(self.gpa, part) catch return error.OutOfMemory;
                if (!gop.found_existing) {
                    // Initialize sentinels immediately: deinitTable is safe even if
                    // subsequent allocations fail (free of zero-len key = no-op,
                    // deinit of boolean = no-op; no errdefer needed).
                    gop.value_ptr.* = .{ .boolean = false };
                    gop.key_ptr.* = &.{};
                    const sub = try self.gpa.create(TableType);
                    sub.* = .empty;
                    gop.value_ptr.* = .{ .table = sub };
                    const sub_meta = try self.createMeta(sub, .implicit);
                    const key_copy = try self.gpa.dupe(u8, part);
                    gop.key_ptr.* = key_copy;
                    sub_meta.kind = .dotted;
                    try meta.key_kinds.put(ma, gop.key_ptr.*, .dotted_table);
                    tbl = sub;
                    meta = self.getMeta(tbl);
                } else {
                    const kk = meta.key_kinds.get(gop.key_ptr.*) orelse .value;
                    switch (kk) {
                        .value, .inline_table => return self.fail("key '{s}' is already defined as a non-table value", .{part}),
                        .aot_array => return self.fail("cannot assign dotted key through array of tables '{s}'", .{part}),
                        .header_table => return self.fail("cannot append to explicitly defined table '{s}' with dotted keys", .{part}),
                        .implicit_table => {
                            try meta.key_kinds.put(ma, gop.key_ptr.*, .dotted_table);
                            tbl = gop.value_ptr.*.table;
                            const sm = self.getMeta(tbl);
                            if (sm.kind == .implicit) sm.kind = .dotted;
                            meta = self.getMeta(tbl);
                        },
                        .dotted_table => {
                            tbl = gop.value_ptr.*.table;
                            meta = self.getMeta(tbl);
                        },
                    }
                }
            }

            const last = parts[parts.len - 1];
            if (meta.kind == .inline_t and !inline_ctx)
                return self.fail("cannot add keys to inline table after definition", .{});
            if (tbl.contains(last)) return self.fail("key '{s}' is already defined", .{last});

            // Ensure capacity first so the table insertion below is infallible; this
            // prevents a partial-state slot that would corrupt deinitTable on OOM.
            try tbl.ensureUnusedCapacity(self.gpa, 1);
            const key_owned = try self.gpa.dupe(u8, last);
            var key_in_map = false;
            errdefer if (!key_in_map) self.gpa.free(key_owned);

            const kk: KeyKind = switch (value) {
                .table => |t| switch (self.getMeta(t).kind) {
                    .inline_t => .inline_table,
                    .implicit => .implicit_table,
                    .dotted => .dotted_table,
                    .header, .root => .header_table,
                    .aot_array => .aot_array,
                },
                else => .value,
            };
            // The metadata insert can fail. It runs before the table takes ownership
            // of `value`, so on failure the caller's errdefer still owns `value` alone.
            // Plain values are the default kind (see the lookups above), so they
            // need no entry of their own.
            if (kk != .value) try meta.key_kinds.put(ma, key_owned, kk);
            tbl.putAssumeCapacityNoClobber(key_owned, value);
            key_in_map = true; // table owns key_owned; deinitTable handles cleanup
        }

        // ─── table header parsing ─────────────────────────────────────────────────

        fn parseTableHeader(self: *Self) ParseError!void {
            const header_start = self.pos;
            try self.expect('[');
            self.skipInlineWs();
            var key_parts = try self.parseDottedKey();
            defer key_parts.deinit(self.gpa);
            try self.recordKeyStylesForAbsolutePath(key_parts.parts.items, key_parts.styles.items);
            try self.recordKeyLexemesForAbsolutePath(key_parts.parts.items, key_parts.raw_parts.items);
            if (key_parts.parts.items.len > 1) {
                try self.recordIntermediateTableSyntaxForAbsolutePath(key_parts.parts.items[0 .. key_parts.parts.items.len - 1], .dotted);
            }

            if (self.pending_comments.items.len > 0) {
                try self.flushPendingCommentsAbsolute(key_parts.parts.items, .before_table);
            }

            self.skipInlineWs();
            try self.expect(']');
            const trailing_comment_start = self.pos;
            self.skipInlineWs();
            if (!self.isEOL() and self.peek() != '#' and self.peek() != null)
                return self.fail("extra content after table header", .{});
            if (self.peek() == '#') try self.captureAttachedCommentAbsolute(key_parts.parts.items, .trailing_table, trailing_comment_start);
            try self.skipToEOL();
            try self.recordTableSyntaxForAbsoluteKeyParts(key_parts.parts.items, .header);
            self.cur = try self.navigateToHeaderTable(self.root, key_parts.parts.items);
            try self.setTablePath(key_parts.parts.items);
            try self.setSpanTablePath(key_parts.parts.items);
            try self.recordCurrentHeaderSpan(header_start, self.pos, .table);
        }

        fn parseAOTHeader(self: *Self) ParseError!void {
            const header_start = self.pos;
            try self.expect('[');
            try self.expect('[');
            self.skipInlineWs();
            var key_parts = try self.parseDottedKey();
            defer key_parts.deinit(self.gpa);
            try self.recordKeyStylesForAbsolutePath(key_parts.parts.items, key_parts.styles.items);
            try self.recordKeyLexemesForAbsolutePath(key_parts.parts.items, key_parts.raw_parts.items);
            if (key_parts.parts.items.len > 1) {
                try self.recordIntermediateTableSyntaxForAbsolutePath(key_parts.parts.items[0 .. key_parts.parts.items.len - 1], .dotted);
            }

            if (self.pending_comments.items.len > 0) {
                try self.flushPendingCommentsAbsolute(key_parts.parts.items, .before_aot);
            }

            self.skipInlineWs();
            try self.expect(']');
            try self.expect(']');
            const trailing_comment_start = self.pos;
            self.skipInlineWs();
            if (!self.isEOL() and self.peek() != '#' and self.peek() != null)
                return self.fail("extra content after array-of-tables header", .{});
            if (self.peek() == '#') try self.captureAttachedCommentAbsolute(key_parts.parts.items, .trailing_aot, trailing_comment_start);
            try self.skipToEOL();
            try self.recordTableSyntaxForAbsoluteKeyParts(key_parts.parts.items, .aot);
            const aot = try self.navigateToAOT(self.root, key_parts.parts.items);
            self.cur = aot.tbl;
            try self.setTablePath(key_parts.parts.items);
            try self.setAOTSpanTablePath(key_parts.parts.items, aot.index);
            try self.recordCurrentHeaderSpan(header_start, self.pos, .aot);
        }

        // Navigate intermediate path segments (all but the last), creating implicit
        // tables as needed. Shared by `navigateToHeaderTable` and `navigateToAOT`
        // whose intermediate-segment logic is identical.
        fn navigateIntermediate(
            self: *Self,
            start_tbl: *TableType,
            start_meta: *TableMeta,
            path: [][]u8,
        ) ParseError!struct { tbl: *TableType, meta: *TableMeta } {
            const ma = self.meta_arena.allocator();
            var tbl = start_tbl;
            var meta = start_meta;
            for (path[0 .. path.len - 1]) |part| {
                const gop = tbl.getOrPut(self.gpa, part) catch return error.OutOfMemory;
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .boolean = false };
                    gop.key_ptr.* = &.{};
                    const sub = try self.gpa.create(TableType);
                    sub.* = .empty;
                    gop.value_ptr.* = .{ .table = sub };
                    _ = try self.createMeta(sub, .implicit);
                    const key_copy = try self.gpa.dupe(u8, part);
                    gop.key_ptr.* = key_copy;
                    try meta.key_kinds.put(ma, gop.key_ptr.*, .implicit_table);
                    tbl = sub;
                    meta = self.getMeta(tbl);
                } else {
                    const kk = meta.key_kinds.get(gop.key_ptr.*) orelse .value;
                    switch (kk) {
                        .value, .inline_table => return self.fail("cannot use '{s}' as a table: already a non-table value", .{part}),
                        .aot_array => {
                            const arr = gop.value_ptr.*.array;
                            tbl = arr.items[arr.items.len - 1].table;
                            meta = self.getMeta(tbl);
                        },
                        .implicit_table, .dotted_table, .header_table => {
                            tbl = gop.value_ptr.*.table;
                            meta = self.getMeta(tbl);
                        },
                    }
                }
            }
            return .{ .tbl = tbl, .meta = meta };
        }

        fn navigateToHeaderTable(self: *Self, start_tbl: *TableType, path: [][]u8) ParseError!*TableType {
            std.debug.assert(path.len > 0);
            const ma = self.meta_arena.allocator();

            const intermediates = try self.navigateIntermediate(start_tbl, self.getMeta(start_tbl), path);
            var tbl = intermediates.tbl;
            var meta = intermediates.meta;

            const last = path[path.len - 1];
            const gop = tbl.getOrPut(self.gpa, last) catch return error.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .boolean = false };
                gop.key_ptr.* = &.{};
                const sub = try self.gpa.create(TableType);
                sub.* = .empty;
                gop.value_ptr.* = .{ .table = sub };
                _ = try self.createMeta(sub, .header);
                const key_copy = try self.gpa.dupe(u8, last);
                gop.key_ptr.* = key_copy;
                try meta.key_kinds.put(ma, gop.key_ptr.*, .header_table);
                return sub;
            }
            const kk = meta.key_kinds.get(gop.key_ptr.*) orelse .value;
            switch (kk) {
                .implicit_table => {
                    const sub = gop.value_ptr.*.table;
                    self.getMeta(sub).kind = .header;
                    try meta.key_kinds.put(ma, gop.key_ptr.*, .header_table);
                    return sub;
                },
                .header_table => return self.fail("table [{s}] already defined", .{last}),
                .dotted_table => return self.fail("table [{s}] already defined via dotted keys", .{last}),
                .inline_table => return self.fail("cannot reopen inline table [{s}]", .{last}),
                .value => return self.fail("key '{s}' is a non-table value", .{last}),
                .aot_array => return self.fail("key '{s}' is an array of tables; use [[{s}]] syntax", .{ last, last }),
            }
        }

        fn navigateToAOT(self: *Self, start_tbl: *TableType, path: [][]u8) ParseError!AOTElementResult {
            std.debug.assert(path.len > 0);
            const ma = self.meta_arena.allocator();

            const intermediates = try self.navigateIntermediate(start_tbl, self.getMeta(start_tbl), path);
            var tbl = intermediates.tbl;
            var meta = intermediates.meta;

            const last = path[path.len - 1];
            const gop = tbl.getOrPut(self.gpa, last) catch return error.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .boolean = false };
                gop.key_ptr.* = &.{};
                const arr = try self.gpa.create(ArrayType);
                arr.* = .empty;
                gop.value_ptr.* = .{ .array = arr };
                const key_copy = try self.gpa.dupe(u8, last);
                gop.key_ptr.* = key_copy;
                try meta.key_kinds.put(ma, gop.key_ptr.*, .aot_array);
                return self.appendAOTElement(arr);
            }
            const kk = meta.key_kinds.get(gop.key_ptr.*) orelse .value;
            if (kk != .aot_array) return self.fail("key '{s}' is not an array of tables", .{last});
            return self.appendAOTElement(gop.value_ptr.*.array);
        }

        fn appendAOTElement(self: *Self, arr: *ArrayType) ParseError!AOTElementResult {
            const elem = try self.gpa.create(TableType);
            elem.* = .empty;
            errdefer {
                elem.deinit(self.gpa);
                self.gpa.destroy(elem);
            }
            _ = try self.createMeta(elem, .header);
            arr.append(self.gpa, .{ .table = elem }) catch return error.OutOfMemory;
            return .{ .tbl = elem, .index = arr.items.len - 1 };
        }

        fn parseKeyVal(self: *Self) ParseError!void {
            const statement_start = self.pos;
            var key_parts = try self.parseDottedKey();
            defer key_parts.deinit(self.gpa);
            try self.recordKeyStylesForTablePath(key_parts.parts.items, key_parts.styles.items);
            try self.recordKeyLexemesForTablePath(key_parts.parts.items, key_parts.raw_parts.items);
            if (key_parts.parts.items.len > 1) {
                try self.recordIntermediateTableSyntaxForTablePath(key_parts.parts.items[0 .. key_parts.parts.items.len - 1], .dotted);
            }

            if (self.pending_comments.items.len > 0) {
                try self.flushPendingComments(key_parts.parts.items, .before_entry);
            }

            self.skipInlineWs();
            try self.expect('=');
            self.skipInlineWs();
            try self.setCurrentValuePath(key_parts.parts.items);
            try self.setCurrentSpanPath(key_parts.parts.items);
            defer self.current_value_path.clearRetainingCapacity();
            defer self.clearCurrentSpanPath();
            const value_start = self.pos;
            const val = try self.parseValue();
            errdefer self.dropValue(val);
            try self.setNestedKey(self.cur, key_parts.parts.items, val, false);
            try self.stagePendingEntrySpan(statement_start, .{ .start = value_start, .end = self.pos });

            // Save path so the upcoming trailing comment (parsed after this function
            // returns) can be stored under the right key in FormatHints.
            if (self.hints != null and self.hints.?.comments != null) {
                if (self.trailing_path) |*path| path.deinit(self.gpa);
                self.trailing_path = try self.dupedPath(key_parts.parts.items);
            }
        }

        fn parseDocument(self: *Self) ParseError!void {
            const doc_input = if (std.mem.startsWith(u8, self.input, "\xEF\xBB\xBF")) self.input[3..] else self.input;
            if (!std.unicode.utf8ValidateSlice(doc_input))
                return self.fail("document is not valid UTF-8", .{});
            while (true) {
                try self.skipTrivia();
                const c = self.peek() orelse break;
                switch (c) {
                    '[' => {
                        if (self.trailing_path) |*path| path.deinit(self.gpa);
                        self.trailing_path = null;
                        if (self.peekAt(1) == '[') try self.parseAOTHeader() else try self.parseTableHeader();
                    },
                    else => {
                        try self.parseKeyVal();
                        const trailing_comment_start = self.pos;
                        self.skipInlineWs();
                        const next = self.peek() orelse {
                            try self.finalizePendingEntrySpan(self.pos);
                            break;
                        };
                        switch (next) {
                            '\n', '\r' => {
                                if (self.trailing_path) |*path| path.deinit(self.gpa);
                                self.trailing_path = null;
                                try self.eatNewline();
                                try self.finalizePendingEntrySpan(self.pos);
                            },
                            '#' => {
                                try self.skipComment(trailing_comment_start);
                                try self.eatNewline();
                                try self.finalizePendingEntrySpan(self.pos);
                            },
                            else => return self.fail("expected newline after key/value pair, found '{c}'", .{self.peek().?}),
                        }
                    },
                }
            }
        }
    };
} // fn ParserTy(V)

inline fn isDigit(c: ?u8) bool {
    return if (c) |ch| ch >= '0' and ch <= '9' else false;
}

inline fn isBaseDigit(c: u8, base: u8) bool {
    return switch (base) {
        16 => std.ascii.isHex(c),
        8 => c >= '0' and c <= '7',
        2 => c == '0' or c == '1',
        else => false,
    };
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// Parse `input` as TOML v1.1.0. Returns a heap-allocated root `*Table`
/// on success. The caller owns all memory; free via `deinitTable(root, gpa)` + `gpa.destroy(root)`.
/// On failure `err_info` (if non-null) is populated with line/col/message.
/// Parser instance producing owned Value trees (current behavior).
pub const ParserVal = ParserTy(types.Value, .{});
pub const ParserValSpans = ParserTy(types.Value, .{ .track_spans = true });

/// Parser instance producing borrowed ValueView trees (zero-copy).
pub const ParserView = ParserTy(view_mod.ValueView, .{});

comptime {
    if (@sizeOf(ParserVal) >= @sizeOf(ParserValSpans)) {
        @compileError("ParserVal must remain smaller than the span-enabled specialization");
    }
}

pub const ParseOptions = struct {
    hints: ?*hints_mod.FormatHints = null,
    spans: ?*spans_mod.ParseSpans = null,
};

fn parseOwnedWithParser(
    comptime ParserType: type,
    gpa: Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    hints: ?*hints_mod.FormatHints,
    spans: ?*spans_mod.ParseSpans,
) ParseError!*Table {
    var parser = try ParserType.init(gpa, input, hints, spans);
    defer parser.deinit();
    parser.parseDocument() catch |e| {
        if (err_info) |ei| ei.* = parser.err_info;
        deinitTable(parser.root, gpa);
        gpa.destroy(parser.root);
        return e;
    };
    return parser.root;
}

pub fn parseSlice(gpa: Allocator, input: []const u8, err_info: ?*ErrorInfo) ParseError!*Table {
    return parseOwnedWithParser(ParserVal, gpa, input, err_info, null, null);
}

pub fn parseSliceWithOptions(
    gpa: Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    options: ParseOptions,
) ParseError!*Table {
    if (options.spans != null) {
        return parseOwnedWithParser(ParserValSpans, gpa, input, err_info, options.hints, options.spans);
    }
    return parseOwnedWithParser(ParserVal, gpa, input, err_info, options.hints, null);
}

pub fn parseSliceWithHints(
    gpa: Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    hints: ?*hints_mod.FormatHints,
) ParseError!*Table {
    return parseOwnedWithParser(ParserVal, gpa, input, err_info, hints, null);
}

pub fn parseSliceWithSpans(
    gpa: Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    spans: ?*spans_mod.ParseSpans,
) ParseError!*Table {
    return parseOwnedWithParser(ParserValSpans, gpa, input, err_info, null, spans);
}

/// Parse without allocating string copies.
/// Output borrows from `input` caller must keep `input` alive
/// while the view tree is in use. Free with `view_mod.deinitViewTable`.
pub fn parseSliceView(
    gpa: Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
) ParseError!*view_mod.TableView {
    var parser = try ParserView.init(gpa, input, null, null);
    defer parser.deinit();
    parser.parseDocument() catch |e| {
        if (err_info) |ei| ei.* = parser.err_info;
        view_mod.deinitViewTable(parser.root, gpa, input);
        return e;
    };
    return parser.root;
}
