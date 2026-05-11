//! Typed TOML parser: maps a TOML document directly onto a Zig struct
//! via comptime reflection. Struct field names must match TOML keys exactly.
//!
//! Supported field types: bool, integers, f32/f64, []const u8, []T,
//! nested structs, ?T (optional), enum, and all datetime structs.
//! See `src/root.zig` for the public `parseInto` entry point.

const std = @import("std");
const types = @import("value.zig");
const parser_mod = @import("parser.zig");

const Allocator = std.mem.Allocator;
const Value = types.Value;
const Table = types.Table;

/// Errors that can arise during typed parsing.
pub const ParseIntoError = parser_mod.ParseError || error{ TypeMismatch, MissingField };

// ─── Public API ──────────────────────────────────────────────────────────────

/// Parse `input` as TOML v1.1.0 and map the root table onto a value of type `T`.
///
/// `T` must be a struct whose field names correspond to TOML keys.
/// Nested structs map to TOML tables; `?T` fields yield `null` for absent keys.
///
/// All strings and slices are allocated with `gpa`.
/// Wrapping `gpa` in an `std.heap.ArenaAllocator` is the simplest way to
/// free everything in one call.
///
/// Returns `error.MissingField` if a required (non-optional, no default) key
/// is absent.  Returns `error.TypeMismatch` if a TOML value's type does not
/// match the Zig field type.
pub fn parseInto(
    comptime T: type,
    gpa: Allocator,
    input: []const u8,
    err_info: ?*parser_mod.ErrorInfo,
) ParseIntoError!T {
    // Build the dynamic tree in a temporary arena and discard it after mapping.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const root = try parser_mod.parseSlice(arena.allocator(), input, err_info);
    return mapTable(T, root, gpa);
}

// ─── Internal mapping ────────────────────────────────────────────────────────

fn mapTable(comptime T: type, table: *Table, gpa: Allocator) ParseIntoError!T {
    if (@typeInfo(T) != .@"struct") {
        @compileError("parseInto: T must be a struct, got " ++ @typeName(T));
    }

    if (comptime isContainer(T)) if (@hasDecl(T, "fromToml"))
        return T.fromToml(.{ .table = table }, gpa) catch |err| switch (err) {
            else => error.TypeMismatch,
        };

    var result: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (table.get(field.name)) |v| {
            @field(result, field.name) = try mapValue(field.type, v, gpa);
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else if (field.defaultValue()) |def| {
            @field(result, field.name) = def;
        } else {
            return error.MissingField;
        }
    }

    return result;
}

fn mapValue(comptime T: type, value: Value, gpa: Allocator) ParseIntoError!T {
    if (comptime isContainer(T)) if (@hasDecl(T, "fromToml"))
        return T.fromToml(value, gpa) catch |err| switch (err) {
            else => error.TypeMismatch,
        };

    // Datetime structs are matched by type identity before the generic struct branch.
    if (T == types.OffsetDateTime) {
        return if (value == .offset_datetime) value.offset_datetime else error.TypeMismatch;
    }
    if (T == types.LocalDateTime) {
        return if (value == .local_datetime) value.local_datetime else error.TypeMismatch;
    }
    if (T == types.LocalDate) {
        return if (value == .local_date) value.local_date else error.TypeMismatch;
    }
    if (T == types.LocalTime) {
        return if (value == .local_time) value.local_time else error.TypeMismatch;
    }

    switch (@typeInfo(T)) {
        .bool => {
            if (value != .boolean) return error.TypeMismatch;
            return value.boolean;
        },
        .int => {
            if (value != .integer) return error.TypeMismatch;
            return std.math.cast(T, value.integer.value) orelse error.TypeMismatch;
        },
        .float => {
            return switch (value) {
                .float => @floatCast(value.float),
                .integer => @floatFromInt(value.integer.value),
                else => error.TypeMismatch,
            };
        },
        .optional => |opt| {
            return try mapValue(opt.child, value, gpa);
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) {
                @compileError("parseInto: unsupported pointer type " ++ @typeName(T));
            }
            if (ptr.child == u8) {
                // []const u8: copy the string into gpa
                if (value != .string) return error.TypeMismatch;
                return try gpa.dupe(u8, value.string);
            } else {
                // []Child: allocate a gpa-owned slice
                if (value != .array) return error.TypeMismatch;
                const items = value.array.items;
                const out = try gpa.alloc(ptr.child, items.len);
                for (items, 0..) |item, i| {
                    out[i] = try mapValue(ptr.child, item, gpa);
                }
                return out;
            }
        },
        .@"enum" => {
            if (value != .string) return error.TypeMismatch;
            return std.meta.stringToEnum(T, value.string) orelse error.TypeMismatch;
        },
        .@"struct" => {
            if (value != .table) return error.TypeMismatch;
            return mapTable(T, value.table, gpa);
        },
        else => @compileError("parseInto: unsupported type " ++ @typeName(T)),
    }
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}
