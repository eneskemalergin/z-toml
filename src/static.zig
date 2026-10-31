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
    // The dynamic tree is freed as soon as the mapping is done. Mapped strings and
    // slices are copies, so nothing in the result refers to the tree.
    const root = try parser_mod.parseSlice(gpa, input, err_info);
    defer {
        parser_mod.deinitTable(root, gpa);
        gpa.destroy(root);
    }
    return mapTable(T, root, gpa);
}

// ─── Internal mapping ────────────────────────────────────────────────────────

fn mapTable(comptime T: type, table: *Table, gpa: Allocator) ParseIntoError!T {
    if (@typeInfo(T) != .@"struct") {
        @compileError("parseInto: T must be a struct, got " ++ @typeName(T));
    }

    if (comptime isContainer(T)) if (@hasDecl(T, "fromToml"))
        return T.fromToml(.{ .table = table }, gpa) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.TypeMismatch;
        };

    var result: T = undefined;

    inline for (0..comptime structFieldCount(T)) |i| {
        const name = comptime structFieldName(T, i);
        const FieldType = comptime structFieldType(T, i);
        if (table.get(name)) |v| {
            @field(result, name) = try mapValue(FieldType, v, gpa);
        } else if (@typeInfo(FieldType) == .optional) {
            @field(result, name) = null;
        } else if (structFieldDefault(T, i)) |def| {
            @field(result, name) = def;
        } else {
            return error.MissingField;
        }
    }

    return result;
}

// Zig 0.16 exposes struct fields as one `fields` array. Zig 0.17 exposes parallel
// `field_names`, `field_types` and `field_attrs` arrays. These helpers read either form.
const parallel_struct_info = @hasField(@TypeOf(@typeInfo(struct {}).@"struct"), "field_names");

fn structFieldCount(comptime T: type) usize {
    const info = @typeInfo(T).@"struct";
    return if (parallel_struct_info) info.field_names.len else info.fields.len;
}

fn structFieldName(comptime T: type, comptime i: usize) [:0]const u8 {
    const info = @typeInfo(T).@"struct";
    return if (parallel_struct_info) info.field_names[i] else info.fields[i].name;
}

fn structFieldType(comptime T: type, comptime i: usize) type {
    const info = @typeInfo(T).@"struct";
    return if (parallel_struct_info) info.field_types[i] else info.fields[i].type;
}

fn structFieldDefault(comptime T: type, comptime i: usize) ?structFieldType(T, i) {
    const info = @typeInfo(T).@"struct";
    if (parallel_struct_info) return info.field_attrs[i].defaultValue(structFieldType(T, i));
    return info.fields[i].defaultValue();
}

fn mapValue(comptime T: type, value: Value, gpa: Allocator) ParseIntoError!T {
    if (comptime isContainer(T)) if (@hasDecl(T, "fromToml"))
        return T.fromToml(value, gpa) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.TypeMismatch;
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
