//! TOML v1.1.0 value types.
//!
//! This file contains only type definitions. Memory management functions
//! (`deinitTable`, `deinitValue`) live in `parser.zig` alongside the code
//! that allocates these values.
const std = @import("std");

// ─── Container types ────────────────────────────────────────────────────────

/// Ordered string-keyed hash map (insertion order preserved).
/// All keys are allocator-owned copies.
pub const Table = std.array_hash_map.String(Value);

/// Growable list of Values.
pub const Array = std.ArrayList(Value);

// ─── Date / time helper types ───────────────────────────────────────────────

pub const LocalDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const LocalTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
    /// Sub-second precision stored as nanoseconds (0-999_999_999).
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

// ─── Integer formatting ──────────────────────────────────────────────────────

/// Base in which an integer literal was written.
pub const Base = enum(u2) { decimal, hex, octal, binary };

/// Integer value with original base preserved for canonical output.
pub const IntValue = struct {
    value: i64,
    base: Base = .decimal,
};

// ─── Core Value type ────────────────────────────────────────────────────────

pub const Value = union(enum) {
    string: []const u8,
    integer: IntValue,
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
};
