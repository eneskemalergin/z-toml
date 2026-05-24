//! Parser span types for rewrite and diagnostics.
const std = @import("std");
const hints_mod = @import("output/hints.zig");

const Allocator = std.mem.Allocator;

pub const ByteSpan = struct {
    start: usize,
    end: usize,
};

pub const EntrySpan = struct {
    value: ByteSpan,
    statement: ByteSpan,
};

pub const HeaderKind = enum(u1) {
    table,
    aot,
};

pub const HeaderSpan = struct {
    header: ByteSpan,
    kind: HeaderKind,
};

pub const EntrySpanMap = hints_mod.HintMap(EntrySpan);
pub const HeaderSpanMap = hints_mod.HintMap(HeaderSpan);

pub const ParseSpans = struct {
    entries: ?*EntrySpanMap = null,
    headers: ?*HeaderSpanMap = null,

    pub fn deinit(self: *ParseSpans, gpa: Allocator) void {
        if (self.entries) |entries| {
            var it = entries.iterator();
            while (it.next()) |entry| entry.key_ptr.deinit(gpa);
            entries.deinit(gpa);
        }
        if (self.headers) |headers| {
            var it = headers.iterator();
            while (it.next()) |entry| entry.key_ptr.deinit(gpa);
            headers.deinit(gpa);
        }
        self.* = .{};
    }
};
