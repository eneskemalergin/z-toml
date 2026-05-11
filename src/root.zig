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
const json_output = @import("output/json.zig");
const output_toml = @import("output/toml.zig");

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
pub const ParseIntoError = typed_mod.ParseIntoError;

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
/// Nested tables use dotted keys or inline tables; arrays of tables
/// use `[[...]]` headers. Output is always valid TOML v1.1.0.
pub const writeToml = output_toml.writeToml;

/// Serialize `value` with formatting options.
///
/// `opts.sort_keys` sorts keys alphabetically for canonical output.
/// `gpa` is used for key-sort allocation.
pub const writeTomlOpts = output_toml.writeTomlOpts;
pub const WriteOptions = output_toml.WriteOptions;
