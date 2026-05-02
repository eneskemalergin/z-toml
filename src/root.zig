/// z-toml — TOML v1.1.0 parser for Zig 0.16
///
/// Quick start
/// ───────────
///   const toml = @import("toml");
///
///   var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
///   defer arena.deinit();
///
///   var err: toml.ErrorInfo = .{};
///   const root = toml.parseSlice(arena.allocator(), toml_text, &err) catch |e| {
///       std.debug.print("parse error at {}:{} — {s}\n",
///                       .{ err.line, err.col, err.message() });
///       return e;
///   };
///
///   // Access values:
///   if (root.get("title")) |v| {
///       std.debug.print("title = {s}\n", .{v.string});
///   }
///
/// Memory management
/// ─────────────────
///   • Use an ArenaAllocator and let it handle everything, or
///   • call `toml.deinit(root, gpa)` to free the tree manually.
const std = @import("std");
const types = @import("types.zig");
const parser_mod = @import("parser.zig");

// ─── Re-export public types ───────────────────────────────────────────────────

pub const Value = types.Value;
pub const Table = types.Table;
pub const Array = types.Array;
pub const LocalDate = types.LocalDate;
pub const LocalTime = types.LocalTime;
pub const LocalDateTime = types.LocalDateTime;
pub const OffsetDateTime = types.OffsetDateTime;

// ─── Re-export error info ─────────────────────────────────────────────────────

pub const ParseError = parser_mod.ParseError;
pub const ErrorInfo = parser_mod.ErrorInfo;

// ─── Public API ───────────────────────────────────────────────────────────────

/// Parse `input` as TOML v1.1.0 and return the root table.
///
/// `gpa`      — Allocator for all output memory (recommend ArenaAllocator).
/// `input`    — UTF-8 TOML text.
/// `err_info` — Optional; filled with line/col/message on failure.
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
    types.deinitTable(table, gpa);
    gpa.destroy(table);
}
