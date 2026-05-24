//! Format hints types for TOML format-fidelity tracking.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PathSegment = union(enum) {
    key: []const u8,
    index: usize,
};

pub const HintPath = struct {
    segments: []const PathSegment,

    pub fn clone(self: HintPath, gpa: Allocator) !HintPath {
        const owned = try gpa.alloc(PathSegment, self.segments.len);
        var cloned: usize = 0;
        errdefer {
            for (owned[0..cloned]) |segment| switch (segment) {
                .key => |text| gpa.free(text),
                .index => {},
            };
            gpa.free(owned);
        }

        for (self.segments, 0..) |segment, index| {
            owned[index] = switch (segment) {
                .key => |text| .{ .key = try gpa.dupe(u8, text) },
                .index => |value| .{ .index = value },
            };
            cloned += 1;
        }

        return .{ .segments = owned };
    }

    pub fn deinit(self: *HintPath, gpa: Allocator) void {
        for (self.segments) |segment| switch (segment) {
            .key => |text| gpa.free(text),
            .index => {},
        };
        gpa.free(self.segments);
        self.* = .{ .segments = &.{} };
    }

    pub fn eql(a: HintPath, b: HintPath) bool {
        if (a.segments.len != b.segments.len) return false;
        for (a.segments, b.segments) |lhs, rhs| {
            switch (lhs) {
                .key => |lhs_text| switch (rhs) {
                    .key => |rhs_text| {
                        if (!std.mem.eql(u8, lhs_text, rhs_text)) return false;
                    },
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

    pub fn hash(self: HintPath) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (self.segments) |segment| switch (segment) {
            .key => |text| {
                const tag: u8 = 0;
                hasher.update(std.mem.asBytes(&tag));
                hasher.update(std.mem.asBytes(&text.len));
                hasher.update(text);
            },
            .index => |value| {
                const tag: u8 = 1;
                hasher.update(std.mem.asBytes(&tag));
                hasher.update(std.mem.asBytes(&value));
            },
        };
        return hasher.final();
    }
};

const PathContext = struct {
    pub fn hash(_: @This(), path: HintPath) u64 {
        return path.hash();
    }

    pub fn eql(_: @This(), a: HintPath, b: HintPath) bool {
        return HintPath.eql(a, b);
    }
};

pub const StringStyle = enum(u2) { basic, literal, multiline_basic, multiline_literal };
pub const KeyStyle = enum(u2) { bare, literal, basic };
pub const TableSyntax = enum(u3) { inline_compact, inline_spaced, header, aot, dotted };
pub const LineEnding = enum(u1) { lf, crlf };

pub const DocumentHints = struct {
    has_bom: bool = false,
    line_ending: LineEnding = .lf,
    original_source: ?[]const u8 = null,
};

pub const CommentAttachment = enum(u3) {
    before_entry,
    trailing_entry,
    before_table,
    trailing_table,
    before_aot,
    trailing_aot,
};

pub const CommentRecord = struct {
    attachment: CommentAttachment,
    text: []const u8,
    raw: ?[]const u8 = null,
};

pub const CommentList = std.ArrayListUnmanaged(CommentRecord);

pub fn HintMap(comptime V: type) type {
    return std.HashMapUnmanaged(HintPath, V, PathContext, std.hash_map.default_max_load_percentage);
}

pub const KeyStyleMap = HintMap(KeyStyle);
pub const KeyLexemeMap = HintMap([]const u8);
pub const ValueLexemeMap = HintMap([]const u8);
pub const TableSyntaxMap = HintMap(TableSyntax);
pub const CommentMap = HintMap(CommentList);

pub const FormatHints = struct {
    string_styles: ?*HintMap(StringStyle) = null,
    key_styles: ?*KeyStyleMap = null,
    key_lexemes: ?*KeyLexemeMap = null,
    value_lexemes: ?*ValueLexemeMap = null,
    table_syntax: ?*TableSyntaxMap = null,
    comments: ?*CommentMap = null,
    document: ?*DocumentHints = null,

    pub fn deinit(self: *FormatHints, gpa: std.mem.Allocator) void {
        if (self.string_styles) |styles| {
            var it = styles.iterator();
            while (it.next()) |entry| entry.key_ptr.deinit(gpa);
            styles.deinit(gpa);
        }
        if (self.key_styles) |styles| {
            var it = styles.iterator();
            while (it.next()) |entry| entry.key_ptr.deinit(gpa);
            styles.deinit(gpa);
        }
        if (self.key_lexemes) |lexemes| {
            var it = lexemes.iterator();
            while (it.next()) |entry| {
                entry.key_ptr.deinit(gpa);
                gpa.free(entry.value_ptr.*);
            }
            lexemes.deinit(gpa);
        }
        if (self.value_lexemes) |lexemes| {
            var it = lexemes.iterator();
            while (it.next()) |entry| {
                entry.key_ptr.deinit(gpa);
                gpa.free(entry.value_ptr.*);
            }
            lexemes.deinit(gpa);
        }
        if (self.table_syntax) |syntax| {
            var it = syntax.iterator();
            while (it.next()) |entry| entry.key_ptr.deinit(gpa);
            syntax.deinit(gpa);
        }
        if (self.comments) |comments| {
            var it = comments.iterator();
            while (it.next()) |entry| {
                entry.key_ptr.deinit(gpa);
                entry.value_ptr.deinit(gpa);
            }
            comments.deinit(gpa);
        }
        if (self.document) |document| {
            if (document.original_source) |source| gpa.free(source);
            document.* = .{};
        }
        self.* = .{};
    }
};

pub const OutputProfile = enum {
    /// Inline scalar-only tables, no hints used. Current default.
    compact,
    /// Keep entry order and string styles.
    preserve,
    /// Sorted keys, deterministic, prefer headers.
    canonical,
    /// Preserve everything including comments.
    faithful,
};
