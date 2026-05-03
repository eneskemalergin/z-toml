//! OOM safety tests using std.testing.checkAllAllocationFailures.
//!
//! Wraps the allocator in a FailingAllocator that fails at each allocation
//! point in sequence, verifying that every error-cleanup path properly
//! frees partial state. Covers both the raw parser (parseSlice) and the
//! typed API (parseInto) indirectly since parseInto delegates to parseSlice.

const std = @import("std");
const toml = @import("toml");

// ─── Helpers ──────────────────────────────────────────────────────────────────

fn parseValid(ally: std.mem.Allocator, src: []const u8) !void {
    const root = try toml.parseSlice(ally, src, null);
    toml.deinit(root, ally);
}

fn parseInvalid(ally: std.mem.Allocator, src: []const u8) !void {
    if (toml.parseSlice(ally, src, null)) |root| {
        toml.deinit(root, ally);
        return error.UnexpectedSuccess;
    } else |err| switch (err) {
        error.ParseFailed => {},
        error.OutOfMemory => return error.OutOfMemory,
    }
}

fn checkOOM(test_src: []const u8) !void {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseValid, .{test_src});
}

fn checkOOMInvalid(test_src: []const u8) !void {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseInvalid, .{test_src});
}

// ─── Valid TOML: simple values ─────────────────────────────────────────────────

test "oom: simple key/value" {
    try checkOOM(
        \\title = "hello"
        \\count = 42
        \\pi = 3.14
        \\flag = true
    );
}

test "oom: quoted key" {
    try checkOOM(
        \\"hyphenated-key" = "value"
    );
}

test "oom: integer bases (hex, octal, binary)" {
    try checkOOM(
        \\h = 0xDEAD
        \\o = 0o755
        \\b = 0b1010
        \\underscored = 1_000_000
    );
}

test "oom: float specials" {
    try checkOOM(
        \\a = inf
        \\b = -inf
        \\c = nan
        \\d = 1.5e3
        \\e = -1.5
    );
}

test "oom: datetime types" {
    try checkOOM(
        \\ld = 2025-01-15
        \\lt = 08:30:00
        \\ldt = 2025-01-15T08:30:00
        \\odt = 2025-01-15T08:30:00Z
        \\odt2 = 2025-04-01T14:22:33-05:00
    );
}

// ─── Valid TOML: strings ──────────────────────────────────────────────────────

test "oom: basic string with escapes" {
    try checkOOM(
        \\s = "hello\nworld\t!\u0041"
    );
}

test "oom: multi-line basic string" {
    try checkOOM(
        \\s = """
        \\line one
        \\line two"""
    );
}

test "oom: multi-line literal string" {
    try checkOOM(
        \\s = '''
        \\line one
        \\line two
        \\'''
    );
}

// ─── Valid TOML: arrays and inline tables ──────────────────────────────────────

test "oom: array" {
    try checkOOM(
        \\a = [1, 2, "three", true, 4.5]
    );
}

// ─── Valid TOML: tables, dotted keys, AOT ──────────────────────────────────────

test "oom: super-table after sub-table" {
    try checkOOM(
        \\[x.y.z.w]
        \\key = 1
        \\[x]
        \\other = 2
    );
}

test "oom: dotted key in table header" {
    try checkOOM(
        \\[a.b]
        \\val = 1
        \\[a.c]
        \\val = 2
    );
}

// ─── Invalid TOML: rejection with clean teardown ───────────────────────────────

test "oom: duplicate key rejection" {
    try checkOOMInvalid(
        \\name = "a"
        \\name = "b"
    );
}

test "oom: bare CR rejection" {
    try checkOOMInvalid(
        \\key = 1\rnext = 2
    );
}

test "oom: dotted key through AOT rejection" {
    try checkOOMInvalid(
        \\[[tab.arr]]
        \\[tab]
        \\arr.val1 = 1
    );
}

test "oom: invalid leap day" {
    try checkOOMInvalid("day = 2100-02-29\n");
}

test "oom: leading zeros rejection" {
    try checkOOMInvalid(
        \\x = 00e1
    );
}

test "oom: control char in string" {
    try checkOOMInvalid("bad = \"\x01\"\n");
}

test "oom: unclosed string" {
    try checkOOMInvalid("key = \"unclosed\n");
}
