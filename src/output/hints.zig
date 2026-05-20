const std = @import("std");

pub const StringStyle = enum(u2) { basic, literal, multiline_basic, multiline_literal };

/// Key-owning hash map (same as `toml.Table`). Used by FormatHints so
/// that keystrings are freed automatically on deinit.
pub const HintMap = std.array_hash_map.String;

pub const FormatHints = struct {
    string_styles: ?*HintMap(StringStyle) = null,
    /// Comments keyed by dotted path (from root). Leading comments
    /// before a key are stored under that key's path. Trailing comments
    /// after a value are stored under the same key.
    comments: ?*HintMap([]const u8) = null,
};
