/// TOML v1.1.0 value types.
///
/// All heap memory is owned by the allocator that was passed to the parser.
/// Use `Value.deinit(gpa)` / `deinitTable(tbl, gpa)` to free everything, or
/// wrap the call site in an `ArenaAllocator` and discard the arena.
const std = @import("std");
const Allocator = std.mem.Allocator;

// ─────────────────────────────────────────────────────────────────────────────
// Public container types
// ─────────────────────────────────────────────────────────────────────────────

/// Ordered string-keyed hash map (insertion order preserved).
/// All keys are allocator-owned copies.
pub const Table = std.array_hash_map.String(Value);

/// Growable list of Values.
pub const Array = std.ArrayList(Value);

// ─────────────────────────────────────────────────────────────────────────────
// Date / time helper types
// ─────────────────────────────────────────────────────────────────────────────

pub const LocalDate = struct {
    year: u16,
    month: u8, // 1–12
    day: u8, // 1–31
};

pub const LocalTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
    /// Sub-second precision stored as nanoseconds (0–999_999_999).
    nanosecond: u32,
};

pub const LocalDateTime = struct {
    date: LocalDate,
    time: LocalTime,
};

pub const OffsetDateTime = struct {
    date: LocalDate,
    time: LocalTime,
    /// UTC offset in minutes (e.g. −420 for −07:00, 0 for Z).
    offset_minutes: i16,
};

// ─────────────────────────────────────────────────────────────────────────────
// Core Value type
// ─────────────────────────────────────────────────────────────────────────────

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    offset_datetime: OffsetDateTime,
    local_datetime: LocalDateTime,
    local_date: LocalDate,
    local_time: LocalTime,
    /// Heap-allocated so its address is stable (needed during parse).
    array: *Array,
    /// Heap-allocated so its address is stable (needed during parse).
    table: *Table,

    /// Recursively free all memory owned by this value.
    pub fn deinit(self: Value, gpa: Allocator) void {
        switch (self) {
            .string => |s| gpa.free(s),
            .array => |arr| {
                for (arr.items) |item| item.deinit(gpa);
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
};

/// Free all keys, values and the table's own storage.
pub fn deinitTable(tbl: *Table, gpa: Allocator) void {
    for (tbl.keys()) |k| gpa.free(k);
    for (tbl.values()) |v| v.deinit(gpa);
    tbl.deinit(gpa);
}
