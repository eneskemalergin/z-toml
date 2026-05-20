//! Format hints types for TOML format-fidelity tracking.
const std = @import("std");

pub const StringStyle = enum(u2) { basic, literal, multiline_basic, multiline_literal };

/// Key-owning hash map (same as `toml.Table`). Used by FormatHints so
/// that keystrings are freed automatically on deinit.
pub const HintMap = std.array_hash_map.String;

pub const FormatHints = struct {
    string_styles: ?*HintMap(StringStyle) = null,
    comments: ?*HintMap([]const u8) = null,
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
