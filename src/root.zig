//! z-toml: TOML v1.1.0 parser for Zig 0.16.
//!
//! Single-pass, zero-dependency, corpus-validated.
//! Use `parseSlice` for dynamic access or `parseInto` for typed struct mapping.
//!
//! Memory: pass an `ArenaAllocator` and discard the arena, or call
//! `deinit(root, gpa)` to free the tree manually.
const std = @import("std");
const types = @import("value.zig");
const parser_mod = @import("parser.zig");
const typed_mod = @import("static.zig");
pub const temporal = @import("temporal.zig");
const spans_mod = @import("span.zig");
const json_output = @import("output/json.zig");
const output_toml = @import("output/toml.zig");
const hints_mod = @import("output/hints.zig");

// ─── Re-export public types ───────────────────────────────────────────────────

pub const Value = types.Value;
pub const Table = types.Table;
pub const Array = types.Array;
pub const Base = types.Base;
pub const IntValue = types.IntValue;
pub const LocalDate = types.LocalDate;
pub const LocalTime = types.LocalTime;
pub const LocalDateTime = types.LocalDateTime;
pub const OffsetDateTime = types.OffsetDateTime;

// ─── Re-export error info ─────────────────────────────────────────────────────

pub const ParseError = parser_mod.ParseError;
pub const ErrorInfo = parser_mod.ErrorInfo;
pub const ParseOptions = parser_mod.ParseOptions;
pub const ParseIntoError = typed_mod.ParseIntoError;
pub const RewriteError = ParseError || std.mem.Allocator.Error || error{ PathNotFound, PathConflict, UnsupportedRewritePath };
pub const ByteSpan = spans_mod.ByteSpan;
pub const EntrySpan = spans_mod.EntrySpan;
pub const HeaderKind = spans_mod.HeaderKind;
pub const HeaderSpan = spans_mod.HeaderSpan;
pub const EntrySpanMap = spans_mod.EntrySpanMap;
pub const HeaderSpanMap = spans_mod.HeaderSpanMap;
pub const ParseSpans = spans_mod.ParseSpans;

// ─── Public API ───────────────────────────────────────────────────────────────

/// Parse `input` as TOML v1.1.0 and return the root table.
///
/// `gpa`      Allocator for all output memory (recommend ArenaAllocator).
/// `input`    UTF-8 TOML text.
/// `err_info` Optional; filled with line/col/message on failure.
///
/// Free the result with `deinit(root, gpa)` or destroy the arena.
pub fn parseSlice(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
) ParseError!*Table {
    return parser_mod.parseSlice(gpa, input, err_info);
}

/// Recursively free all memory owned by `table` and destroy the table itself.
pub fn deinit(table: *Table, gpa: std.mem.Allocator) void {
    parser_mod.deinitTable(table, gpa);
    gpa.destroy(table);
}

/// Parse `input` and map the root table onto a struct of type `T`.
///
/// Field names must match TOML keys exactly. Supports nested structs,
/// slices, optional fields, enums, and all datetime types.
/// All strings and slices are allocated with `gpa`.
pub fn parseInto(
    comptime T: type,
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
) ParseIntoError!T {
    return typed_mod.parseInto(T, gpa, input, err_info);
}

/// Serialize a parsed `Value` tree as JSON to `w`.
///
/// NaN/Inf floats become JSON `null`. Datetimes are ISO 8601 strings.
/// Table key order matches TOML insertion order.
pub const toJson = json_output.toJson;

/// Serialize a parsed `Value` tree as TOML text to `w`.
///
/// Nested tables use `[header]` syntax and arrays of tables use `[[...]]`
/// headers. Scalar-only table values may still be emitted inline when the
/// chosen options allow it. Output is always valid TOML v1.1.0.
///
/// The default path uses `std.heap.smp_allocator` for temporary serializer
/// allocations, so callers must still handle `error.OutOfMemory`.
pub const writeToml = output_toml.writeToml;

/// Serialize `value` with formatting options.
///
/// `opts.sort_keys` sorts keys alphabetically for canonical output.
/// `gpa` is used for key-sort allocation.
pub const writeTomlOpts = output_toml.writeTomlOpts;
pub const writeTomlValueOpts = output_toml.writeTomlValueOpts;
pub const writeTomlValue = output_toml.writeTomlValue;
pub const WriteOptions = output_toml.WriteOptions;
pub const RewriteMode = enum {
    replace_only,
    create_or_replace,
};

pub const RewriteOptions = struct {
    mode: RewriteMode = .replace_only,
    write: WriteOptions = .{},
    preserve_existing_styles: bool = true,
};

pub const RewriteOperation = struct {
    path: []const PathSegment,
    value: Value,
};

// ─── Format hints ──────────────────────────────────────────────────────────────

pub const FormatHints = hints_mod.FormatHints;
pub const StringStyle = hints_mod.StringStyle;
pub const KeyStyle = hints_mod.KeyStyle;
pub const TableSyntax = hints_mod.TableSyntax;
pub const LineEnding = hints_mod.LineEnding;
pub const DocumentHints = hints_mod.DocumentHints;
pub const PathSegment = hints_mod.PathSegment;
pub const HintPath = hints_mod.HintPath;
pub const HintMap = hints_mod.HintMap;
pub const KeyStyleMap = hints_mod.KeyStyleMap;
pub const KeyLexemeMap = hints_mod.KeyLexemeMap;
pub const ValueLexemeMap = hints_mod.ValueLexemeMap;
pub const TableSyntaxMap = hints_mod.TableSyntaxMap;
pub const CommentAttachment = hints_mod.CommentAttachment;
pub const CommentRecord = hints_mod.CommentRecord;
pub const CommentList = hints_mod.CommentList;
pub const CommentMap = hints_mod.CommentMap;

/// Parse `input` with format hints collection.
///
/// Same as `parseSlice` but also populates `hints` with string styles,
/// entry order, and comments captured during parsing. Pass null for
/// no hint collection (identical to `parseSlice`).
///
/// The caller owns the pointed-to hint storage. Parsing inserts owned entries
/// into whichever maps or document record are provided. Call `hints.deinit(gpa)`
/// when done to free those entries and reset the populated stores in place.
pub fn parseSliceWithHints(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    hints: ?*FormatHints,
) ParseError!*Table {
    return parser_mod.parseSliceWithHints(gpa, input, err_info, hints);
}

/// Parse `input` while collecting rewrite-ready spans on structured paths.
///
/// The optional `spans` store is caller-owned. Parsing fills it with value
/// spans, full statement spans, and table or array-of-tables header spans.
pub fn parseSliceWithSpans(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    spans: ?*ParseSpans,
) ParseError!*Table {
    return parser_mod.parseSliceWithSpans(gpa, input, err_info, spans);
}

/// Parse with explicit parse-time extensions.
///
/// Use this when you need both fidelity hints and rewrite spans from one parse.
/// `options.hints`, when present, follows the same ownership model as
/// `parseSliceWithHints`: the caller owns the storage container, while the parse
/// operation owns the inserted entries until `deinit(gpa)` is called on that
/// hint set.
pub fn parseSliceWithOptions(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    options: ParseOptions,
) ParseError!*Table {
    return parser_mod.parseSliceWithOptions(gpa, input, err_info, options);
}

/// Rewrite one existing value in `input` by structured path and write the result to `w`.
///
/// Bytes outside the replaced value span are copied through unchanged.
/// The replacement may be any TOML value expression, including inline tables.
pub fn rewriteValueAtPath(
    input: []const u8,
    path: []const PathSegment,
    new_value: Value,
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void {
    return rewriteValueAtPathOpts(input, path, new_value, w, .{}, gpa);
}

/// Rewrite one existing value in `input` by structured path using custom TOML
/// value-expression formatting for the replacement.
pub fn rewriteValueAtPathOpts(
    input: []const u8,
    path: []const PathSegment,
    new_value: Value,
    w: *std.Io.Writer,
    opts: WriteOptions,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void {
    return rewriteValues(
        input,
        &[_]RewriteOperation{.{ .path = path, .value = new_value }},
        w,
        .{ .write = opts },
        gpa,
    );
}

pub fn setValueAtPath(
    input: []const u8,
    path: []const PathSegment,
    new_value: Value,
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void {
    return setValueAtPathOpts(input, path, new_value, w, .{}, gpa);
}

pub fn setValueAtPathOpts(
    input: []const u8,
    path: []const PathSegment,
    new_value: Value,
    w: *std.Io.Writer,
    options: RewriteOptions,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void {
    var resolved = options;
    resolved.mode = .create_or_replace;
    return rewriteValues(
        input,
        &[_]RewriteOperation{.{ .path = path, .value = new_value }},
        w,
        resolved,
        gpa,
    );
}

pub fn rewriteValues(
    input: []const u8,
    operations: []const RewriteOperation,
    w: *std.Io.Writer,
    options: RewriteOptions,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void {
    if (operations.len == 0) {
        try w.writeAll(input);
        try w.flush();
        return;
    }

    var current = try gpa.dupe(u8, input);
    errdefer gpa.free(current);

    for (operations, 0..) |operation, index| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try rewriteOne(current, operation, &out.writer, options, gpa);
        const next = try out.toOwnedSlice();
        if (index > 0 or input.ptr != current.ptr) gpa.free(current);
        current = next;
    }
    defer gpa.free(current);

    try w.writeAll(current);
    try w.flush();
}

const Splice = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

const ParentResolution = struct {
    semantic_parent_len: usize,
    section_owner_len: usize,
};

fn rewriteOne(
    input: []const u8,
    operation: RewriteOperation,
    w: *std.Io.Writer,
    options: RewriteOptions,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void {
    var entry_spans: EntrySpanMap = .empty;
    var header_spans: HeaderSpanMap = .empty;
    var string_styles: HintMap(StringStyle) = .empty;
    var key_styles: KeyStyleMap = .empty;
    var key_lexemes: KeyLexemeMap = .empty;
    var table_syntax: TableSyntaxMap = .empty;
    var value_lexemes: ValueLexemeMap = .empty;
    var document: DocumentHints = .{};
    var hints: FormatHints = .{
        .string_styles = &string_styles,
        .key_styles = &key_styles,
        .key_lexemes = &key_lexemes,
        .table_syntax = &table_syntax,
        .value_lexemes = &value_lexemes,
        .document = &document,
    };
    defer hints.deinit(gpa);
    var spans: ParseSpans = .{ .entries = &entry_spans, .headers = &header_spans };
    defer spans.deinit(gpa);

    const root = try parseSliceWithOptions(gpa, input, null, .{ .hints = &hints, .spans = &spans });
    defer deinit(root, gpa);

    var line_hints: FormatHints = .{ .document = &document };
    const fragment_hints = if (options.preserve_existing_styles) &hints else &line_hints;
    const path_hint = HintPath{ .segments = operation.path };

    if (entry_spans.get(path_hint)) |entry| {
        const replacement = if (useHeaderFragment(operation.value, options.write))
            try renderStructuredFragment(operation.path, operation.value, options.write, fragment_hints, gpa)
        else
            try renderReplacementValue(operation.path, operation.value, options, &hints, root, gpa);
        defer gpa.free(replacement);

        if (useHeaderFragment(operation.value, options.write)) {
            const parent_path = operation.path[0 .. operation.path.len - 1];
            const insert_at = headerInsertPos(input, &entry_spans, &header_spans, parent_path);
            const splices = [_]Splice{
                .{ .start = entry.statement.start, .end = entry.statement.end, .replacement = "" },
                .{ .start = insert_at, .end = insert_at, .replacement = replacement },
            };
            try applySplices(input, &splices, w);
            return;
        }

        const splices = [_]Splice{.{ .start = entry.value.start, .end = entry.value.end, .replacement = replacement }};
        try applySplices(input, &splices, w);
        return;
    }

    if (options.mode == .replace_only) return error.PathNotFound;

    const resolution = try resolveParentForCreate(root, &header_spans, operation.path);
    var path_buf: [128][]const u8 = undefined;
    var full_keys_buf: [128][]const u8 = undefined;
    const relative_keys = keysFromPath(operation.path[resolution.section_owner_len..], &path_buf);
    const full_keys = keysFromPath(operation.path, &full_keys_buf);

    const fragment = blk: {
        if (relative_keys.len == 0) return error.UnsupportedRewritePath;
        if (useHeaderFragment(operation.value, options.write)) {
            break :blk try renderStructuredFragment(operation.path, operation.value, options.write, fragment_hints, gpa);
        }
        if (options.write.prefer_headers and relative_keys.len > 1) {
            break :blk try renderHeaderValueFragment(full_keys[0 .. full_keys.len - 1], full_keys[full_keys.len - 1], operation.value, options.write, fragment_hints, gpa);
        }
        break :blk try renderPathValueFragment(relative_keys, operation.value, options.write, fragment_hints, gpa);
    };
    defer gpa.free(fragment);

    const insert_at = if (useHeaderFragment(operation.value, options.write) or (options.write.prefer_headers and relative_keys.len > 1))
        headerInsertPos(input, &entry_spans, &header_spans, operation.path[0..resolution.semantic_parent_len])
    else
        sectionPlainInsertPos(input, &entry_spans, &header_spans, operation.path[0..resolution.section_owner_len]);

    const splices = [_]Splice{.{ .start = insert_at, .end = insert_at, .replacement = fragment }};
    try applySplices(input, &splices, w);
}

fn renderReplacementValue(
    path: []const PathSegment,
    value: Value,
    options: RewriteOptions,
    hints: ?*FormatHints,
    original_root: ?*const Table,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try output_toml.writeTomlRewriteValueOpts(
        value,
        &out.writer,
        options.write,
        if (options.preserve_existing_styles) hints else null,
        if (options.preserve_existing_styles) .{ .segments = path } else null,
        if (options.preserve_existing_styles) original_root else null,
        gpa,
    );
    return try out.toOwnedSlice();
}

fn renderPathValueFragment(
    path: []const []const u8,
    value: Value,
    write_options: WriteOptions,
    hints: ?*FormatHints,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try output_toml.writeTomlPathValueOpts(path, value, &out.writer, write_options, hints, gpa);
    return try out.toOwnedSlice();
}

fn renderStructuredFragment(
    path: []const PathSegment,
    value: Value,
    write_options: WriteOptions,
    hints: ?*FormatHints,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)![]u8 {
    var display_path_buf: [128][]const u8 = undefined;
    const display_path = keysFromPath(path, &display_path_buf);
    if (display_path.len == 0) return error.UnsupportedRewritePath;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    switch (value) {
        .table => |tbl| try output_toml.writeTomlTableFragmentOpts(display_path, tbl, &out.writer, write_options, hints, gpa),
        .array => |arr| {
            if (!isArrayOfTables(value)) return error.UnsupportedRewritePath;
            try output_toml.writeTomlArrayOfTablesFragmentOpts(display_path, arr, &out.writer, write_options, hints, gpa);
        },
        else => return error.UnsupportedRewritePath,
    }
    return try out.toOwnedSlice();
}

fn renderHeaderValueFragment(
    header_path: []const []const u8,
    leaf_key: []const u8,
    value: Value,
    write_options: WriteOptions,
    hints: ?*FormatHints,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)![]u8 {
    const tmp = try gpa.create(Table);
    tmp.* = .empty;
    defer {
        for (tmp.keys()) |key| gpa.free(key);
        tmp.deinit(gpa);
        gpa.destroy(tmp);
    }
    try tmp.put(gpa, try gpa.dupe(u8, leaf_key), value);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try output_toml.writeTomlTableFragmentOpts(header_path, tmp, &out.writer, write_options, hints, gpa);
    return try out.toOwnedSlice();
}

fn applySplices(input: []const u8, splices: []const Splice, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var ordered: [4]Splice = undefined;
    std.debug.assert(splices.len <= ordered.len);
    @memcpy(ordered[0..splices.len], splices);
    std.sort.block(Splice, ordered[0..splices.len], {}, struct {
        fn lessThan(_: void, lhs: Splice, rhs: Splice) bool {
            return if (lhs.start == rhs.start) lhs.end < rhs.end else lhs.start < rhs.start;
        }
    }.lessThan);

    var cursor: usize = 0;
    for (ordered[0..splices.len]) |splice| {
        std.debug.assert(splice.start >= cursor);
        std.debug.assert(splice.end >= splice.start);
        try w.writeAll(input[cursor..splice.start]);
        try w.writeAll(splice.replacement);
        cursor = splice.end;
    }
    try w.writeAll(input[cursor..]);
    try w.flush();
}

fn resolveParentForCreate(root: *Table, headers: *const HeaderSpanMap, path: []const PathSegment) RewriteError!ParentResolution {
    if (path.len == 0) return error.UnsupportedRewritePath;
    switch (path[path.len - 1]) {
        .key => {},
        .index => return error.UnsupportedRewritePath,
    }

    var current: *Table = root;
    var matched: usize = 0;
    while (matched + 1 < path.len) {
        switch (path[matched]) {
            .index => return error.UnsupportedRewritePath,
            .key => |key| {
                const existing = current.get(key) orelse break;
                switch (existing) {
                    .table => |tbl| {
                        current = tbl;
                        matched += 1;
                    },
                    .array => |arr| {
                        if (matched + 1 >= path.len - 1) return error.PathConflict;
                        switch (path[matched + 1]) {
                            .key => return error.PathConflict,
                            .index => |item_index| {
                                if (item_index >= arr.items.len) return error.UnsupportedRewritePath;
                                const item = arr.items[item_index];
                                if (item != .table) return error.PathConflict;
                                current = item.table;
                                matched += 2;
                            },
                        }
                    },
                    else => return error.PathConflict,
                }
            },
        }
    }

    for (path[matched .. path.len - 1]) |segment| switch (segment) {
        .key => {},
        .index => return error.UnsupportedRewritePath,
    };

    return .{
        .semantic_parent_len = matched,
        .section_owner_len = longestHeaderPrefixLen(headers, path[0..matched]),
    };
}

fn longestHeaderPrefixLen(headers: *const HeaderSpanMap, path: []const PathSegment) usize {
    var best: usize = 0;
    var it = headers.iterator();
    while (it.next()) |entry| {
        const header_path = entry.key_ptr.segments;
        if (header_path.len > best and pathHasPrefix(header_path, path)) best = header_path.len;
    }
    return best;
}

fn sectionPlainInsertPos(
    input: []const u8,
    entries: *const EntrySpanMap,
    headers: *const HeaderSpanMap,
    section_owner_path: []const PathSegment,
) usize {
    var found_entry = false;
    var max_end: usize = 0;
    var it = entries.iterator();
    while (it.next()) |entry| {
        const entry_path = entry.key_ptr.segments;
        if (!pathHasPrefix(section_owner_path, entry_path)) continue;
        if (longestHeaderPrefixLen(headers, entry_path) != section_owner_path.len) continue;
        found_entry = true;
        max_end = @max(max_end, entry.value_ptr.statement.end);
    }
    if (found_entry) return max_end;

    if (section_owner_path.len > 0) {
        if (headers.get(.{ .segments = section_owner_path })) |header| return header.header.end;
    }

    var first_header_start = input.len;
    var header_it = headers.iterator();
    while (header_it.next()) |entry| {
        first_header_start = @min(first_header_start, entry.value_ptr.header.start);
    }
    return first_header_start;
}

fn subtreeEnd(
    input: []const u8,
    entries: *const EntrySpanMap,
    headers: *const HeaderSpanMap,
    path: []const PathSegment,
) usize {
    if (path.len == 0) return input.len;

    var end: usize = 0;
    if (headers.get(.{ .segments = path })) |header| end = header.header.end;

    var entry_it = entries.iterator();
    while (entry_it.next()) |entry| {
        if (pathHasPrefix(path, entry.key_ptr.segments)) {
            end = @max(end, entry.value_ptr.statement.end);
        }
    }

    var header_it = headers.iterator();
    while (header_it.next()) |entry| {
        if (pathHasPrefix(path, entry.key_ptr.segments)) {
            end = @max(end, entry.value_ptr.header.end);
        }
    }
    return if (end == 0) input.len else end;
}

fn headerInsertPos(
    input: []const u8,
    entries: *const EntrySpanMap,
    headers: *const HeaderSpanMap,
    parent_path: []const PathSegment,
) usize {
    if (parent_path.len == 0) return sectionPlainInsertPos(input, entries, headers, parent_path);
    return subtreeEnd(input, entries, headers, parent_path);
}

fn useHeaderFragment(value: Value, write_options: WriteOptions) bool {
    return write_options.prefer_headers and (value == .table or isArrayOfTables(value));
}

fn isArrayOfTables(value: Value) bool {
    if (value != .array) return false;
    const arr = value.array;
    if (arr.items.len == 0) return false;
    for (arr.items) |item| {
        if (item != .table) return false;
    }
    return true;
}

fn keysFromPath(path: []const PathSegment, buf: *[128][]const u8) []const []const u8 {
    var len: usize = 0;
    for (path) |segment| switch (segment) {
        .key => |key| {
            buf[len] = key;
            len += 1;
        },
        .index => {},
    };
    return buf[0..len];
}

fn pathHasPrefix(prefix: []const PathSegment, path: []const PathSegment) bool {
    if (prefix.len > path.len) return false;
    for (prefix, path[0..prefix.len]) |lhs, rhs| {
        switch (lhs) {
            .key => |lhs_key| switch (rhs) {
                .key => |rhs_key| if (!std.mem.eql(u8, lhs_key, rhs_key)) return false,
                .index => return false,
            },
            .index => |lhs_index| switch (rhs) {
                .key => return false,
                .index => |rhs_index| if (lhs_index != rhs_index) return false,
            },
        }
    }
    return true;
}

// ─── Zero-copy view API ────────────────────────────────────────────────────────

const view_mod = @import("view.zig");

pub const ValueView = view_mod.ValueView;
pub const TableView = view_mod.TableView;
pub const ArrayListView = view_mod.ArrayListView;

/// Parse without allocating string copies. Output borrows from `input`.
/// Caller must keep `input` alive while the view tree is in use.
/// Free with `deinitViewTable(root, gpa, input)`.
pub fn parseSliceView(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
) ParseError!*TableView {
    return parser_mod.parseSliceView(gpa, input, err_info);
}

/// Free a view tree (containers and owned string allocations, but not
/// borrowed strings that point into `input`).
pub fn deinitViewTable(tbl: *TableView, gpa: std.mem.Allocator, input: []const u8) void {
    view_mod.deinitViewTable(tbl, gpa, input);
}

/// Deep-copy a view subtree into an owned Value tree.
pub fn cloneValue(gpa: std.mem.Allocator, view: ValueView, input: []const u8) std.mem.Allocator.Error!Value {
    return view_mod.cloneValue(gpa, view, input);
}

/// Serialize a ValueView tree to TOML text. Internally clones to Value.
pub fn writeTomlView(
    view: ValueView,
    w: *std.Io.Writer,
    opts: WriteOptions,
    gpa: std.mem.Allocator,
    input: []const u8,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const val = try cloneValue(gpa, view, input);
    defer switch (val) {
        .table => |tbl| {
            deinit(tbl, gpa);
        },
        else => parser_mod.deinitValue(val, gpa),
    };
    try writeTomlOpts(val, w, opts, gpa);
}

// ─── Output profiles ────────────────────────────────────────────────────────────

pub const OutputProfile = hints_mod.OutputProfile;

/// Serialize `value` as TOML with a named profile.
///
/// Profiles set multiple `WriteOptions` at once and optionally
/// consume `hints` for string-style, comment, lexeme, table-syntax, and
/// document-level fidelity. With `.faithful` and matching hints, unchanged
/// parsed documents can be replayed byte-for-byte.
pub fn writeTomlWithProfile(
    value: Value,
    w: *std.Io.Writer,
    profile: OutputProfile,
    hints: ?*FormatHints,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    return output_toml.writeTomlWithProfile(value, w, profile, hints, gpa);
}
