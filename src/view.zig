//! Zero-copy ValueView types and helpers.
const std = @import("std");
const types = @import("value.zig");

pub const ValueView = union(enum) {
    string: []const u8,
    integer: types.IntValue,
    float: f64,
    boolean: bool,
    offset_datetime: types.OffsetDateTime,
    local_datetime: types.LocalDateTime,
    local_date: types.LocalDate,
    local_time: types.LocalTime,
    array: *ArrayListView,
    table: *TableView,
};

pub const TableView = std.array_hash_map.String(ValueView);

pub const ArrayListView = std.ArrayList(ValueView);

/// Free container structs and table keys. String values that point
/// outside `input` are owned allocations (from escaped-string slow
/// path) and are freed too. Strings pointing into `input` are
/// borrowed and left alone.
pub fn deinitViewValue(value: *ValueView, gpa: std.mem.Allocator, input: []const u8) void {
    switch (value.*) {
        .string => |s| {
            if (s.len > 0) {
                const addr = @intFromPtr(s.ptr);
                const in_start = @intFromPtr(input.ptr);
                const in_end = in_start +% input.len;
                if (addr < in_start or addr >= in_end) gpa.free(s);
            }
        },
        .array => |arr| {
            for (arr.items) |*item| deinitViewValue(item, gpa, input);
            arr.deinit(gpa);
            gpa.destroy(arr);
        },
        .table => |tbl| {
            for (tbl.keys()) |k| gpa.free(k);
            for (tbl.values()) |*v| deinitViewValue(v, gpa, input);
            tbl.deinit(gpa);
            gpa.destroy(tbl);
        },
        else => {},
    }
}

/// Deinit the whole view tree starting from the root table.
pub fn deinitViewTable(tbl: *TableView, gpa: std.mem.Allocator, input: []const u8) void {
    for (tbl.keys()) |k| gpa.free(k);
    for (tbl.values()) |*v| deinitViewValue(v, gpa, input);
    tbl.deinit(gpa);
    gpa.destroy(tbl);
}

/// Deep-copy a ValueView tree into an owned Value tree.
pub fn cloneValue(gpa: std.mem.Allocator, view: ValueView, input: []const u8) std.mem.Allocator.Error!types.Value {
    return switch (view) {
        .string => |s| types.Value{ .string = try gpa.dupe(u8, s) },
        .integer => |iv| types.Value{ .integer = iv },
        .float => |f| types.Value{ .float = f },
        .boolean => |b| types.Value{ .boolean = b },
        .offset_datetime => |dt| types.Value{ .offset_datetime = dt },
        .local_datetime => |dt| types.Value{ .local_datetime = dt },
        .local_date => |d| types.Value{ .local_date = d },
        .local_time => |t| types.Value{ .local_time = t },
        .array => |arr| {
            const new_arr = try gpa.create(types.Array);
            new_arr.* = .empty;
            errdefer {
                for (new_arr.items) |*item| {
                    switch (item.*) {
                        .string => |s| gpa.free(s),
                        .array => |a| {
                            for (a.items) |*elem| gpa.free(elem.string);
                            a.deinit(gpa);
                            gpa.destroy(a);
                        },
                        else => {},
                    }
                }
                new_arr.deinit(gpa);
                gpa.destroy(new_arr);
            }
            try new_arr.ensureTotalCapacity(gpa, arr.items.len);
            for (arr.items) |item| {
                new_arr.appendAssumeCapacity(try cloneValue(gpa, item, input));
            }
            return types.Value{ .array = new_arr };
        },
        .table => |tbl| {
            const new_tbl = try gpa.create(types.Table);
            new_tbl.* = .empty;
            errdefer {
                for (new_tbl.keys()) |k| gpa.free(k);
                for (new_tbl.values()) |*v| {
                    if (v.* == .string) gpa.free(v.*.string);
                }
                new_tbl.deinit(gpa);
                gpa.destroy(new_tbl);
            }
            var it = tbl.iterator();
            while (it.next()) |entry| {
                const key_owned = try gpa.dupe(u8, entry.key_ptr.*);
                errdefer gpa.free(key_owned);
                const val = try cloneValue(gpa, entry.value_ptr.*, input);
                try new_tbl.put(gpa, key_owned, val);
            }
            return types.Value{ .table = new_tbl };
        },
    };
}
