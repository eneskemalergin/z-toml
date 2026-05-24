<!-- markdownlint-disable MD033 MD036 MD041 -->
<p align="center">
  <img src="assets/z-toml-icon_v2.svg" alt="z-toml logo" width="90">
</p>

<h1 align="center">z-toml</h1>

<p align="center">
  TOML v1.1.0 parser for Zig 0.16. Single-pass, zero-dependency, corpus-validated. Typed, dynamic, and zero-copy APIs.
</p>

<p align="center">
  <a href="https://github.com/eneskemalergin/z-toml/actions/workflows/ci.yml">
    <img src="https://github.com/eneskemalergin/z-toml/actions/workflows/ci.yml/badge.svg?style=flat-square" alt="CI">
  </a>
  <img src="https://img.shields.io/badge/version-v0.3.0-2C8EBB?style=flat-square" alt="v0.3.0">
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0">
  <img src="https://img.shields.io/badge/TOML-v1.1.0-9C4221?style=flat-square" alt="TOML v1.1.0">
  <img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT">
</p>

---

- Single-pass recursive-descent. No intermediate AST.
- Full TOML 1.1.0 coverage: all value types, dotted keys, inline tables, arrays of tables, multi-line strings, escape sequences, date/time types
- `parseInto(T)`: map TOML directly onto a Zig struct with comptime reflection. No manual tree walking.
- `parseSlice`: dynamic tree API for unknown-shape documents
- `parseSliceView`: zero-copy parse returning borrowed strings from the input buffer
- `toJson`: serialize a parsed tree to JSON
- `writeToml` / `writeTomlOpts`: serialize back to TOML text
- `writeTomlValue` / `writeTomlValueOpts`: serialize a single TOML value expression, including inline-table output for table values
- `writeTomlWithProfile`: profile-based output (compact, preserve, canonical, faithful)
- `rewriteValueAtPath` / `rewriteValueAtPathOpts`: replace one existing value by structured path while preserving surrounding bytes
- `setValueAtPath` / `setValueAtPathOpts`: create or replace one value by structured path
- `rewriteValues`: apply multiple rewrite operations sequentially to one document
- `writeTomlView`: serialize a zero-copy view directly to TOML
- `parseSliceWithHints`: capture format-fidelity hints for faithful roundtrips and modified-tree output
- `parseSliceWithSpans` / `parseSliceWithOptions`: capture rewrite-ready value, statement, and header spans on structured paths
- `cloneValue`: deep-copy a zero-copy view into an owned tree
- Validated against the [toml-lang/toml-test](https://github.com/toml-lang/toml-test) corpus (215 valid + 467 invalid files)
- Clear error messages with line and column numbers
- No dependencies beyond the Zig standard library

## Requirements

Zig **0.16.0** or later.

## Installation

Add z-toml as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .z_toml = .{
        .url = "https://github.com/eneskemalergin/z-toml/archive/refs/tags/v0.3.0.tar.gz",
        .hash = "<run zig fetch to get the hash>",
    },
},
```

Or use `zig fetch` to add it automatically:

```sh
zig fetch --save https://github.com/eneskemalergin/z-toml/archive/refs/tags/v0.3.0.tar.gz
```

Then wire it up in your `build.zig`:

```zig
const z_toml = b.dependency("z_toml", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("toml", z_toml.module("toml"));
```

## Quick start

### Typed API (`parseInto`)

The simplest way to read a config file. Define a struct and let the library fill it in.

```zig
const std = @import("std");
const toml = @import("toml");

const Database = struct { host: []const u8, port: u16 };
const Config = struct {
    title: []const u8,
    database: Database,
    retries: u8 = 3, // default used when key is absent
    tags: ?[][]const u8 = null, // null when key is absent
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const src =
        \\title = "My App"
        \\[database]
        \\host = "localhost"
        \\port = 5432
    ;

    var err: toml.ErrorInfo = .{};
    const cfg = toml.parseInto(Config, arena.allocator(), src, &err) catch |e| {
        std.debug.print("parse error at {d}:{d}: {s}\n",
            .{ err.line, err.col, err.message() });
        return e;
    };

    std.debug.print("{s} on {s}:{d}\n",
        .{ cfg.title, cfg.database.host, cfg.database.port });
}
```

### Dynamic API (`parseSlice`)

Use this when the TOML shape is not known at compile time.

```zig
const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src =
        \\title = "My App"
        \\[database]
        \\host = "localhost"
        \\port = 5432
    ;

    var err: toml.ErrorInfo = .{};
    const root = toml.parseSlice(gpa, src, &err) catch |e| {
        std.debug.print("parse error at {d}:{d}: {s}\n",
            .{ err.line, err.col, err.message() });
        return e;
    };
    // root is *toml.Table. Free with toml.deinit(root, gpa) or deinit the arena.

    const title = root.get("title").?.string;
    const port  = root.get("database").?.table.get("port").?.integer.value;
    _ = title;
    _ = port;
}
```

## API

### `parseInto`

```zig
pub fn parseInto(
    comptime T: type,
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
) ParseIntoError!T
```

Parses `input` and maps the root table onto a value of type `T` using comptime reflection. `T` must be a struct. Field names must match TOML keys exactly.

Supported field types:

| Zig field type                                              | Maps from                                         |
| ----------------------------------------------------------- | ------------------------------------------------- |
| `bool`                                                      | TOML boolean                                      |
| integers (`i8`..`i64`, `u8`..`u64`, ...)                    | TOML integer, range-checked                       |
| `f32`, `f64`                                                | TOML float; TOML integer is promoted silently     |
| `[]const u8`                                                | TOML string (gpa-owned copy)                      |
| `[]T`                                                       | TOML array                                        |
| struct                                                      | TOML table (nested)                               |
| `?T`                                                        | value when present, `null` when the key is absent |
| enum                                                        | TOML string matched by variant name               |
| `LocalDate`, `LocalTime`, `LocalDateTime`, `OffsetDateTime` | TOML datetime types                               |

Fields with a Zig default value use that default when the key is absent. Fields without a default and without `?` return `error.MissingField` when absent. Extra TOML keys not present in the struct are silently ignored.

Returns `error.ParseFailed` for invalid TOML, `error.MissingField` for a required absent key, `error.TypeMismatch` for a wrong TOML type or out-of-range integer.

#### `fromToml` custom hook

Types can opt into custom mapping by declaring a method:

```zig
pub fn fromToml(v: toml.Value, allocator: Allocator) !MyType
```

When `parseInto` encounters a type with `fromToml`, it calls this method instead of the default comptime reflection. The hook fires for container types (struct, enum, union, opaque) and replaces the default mapping entirely:

```zig
const MyId = struct {
    raw: []const u8,
    pub fn fromToml(v: toml.Value, allocator: std.mem.Allocator) !MyId {
        return .{ .raw = try allocator.dupe(u8, v.string) };
    }
};
const Config = struct { id: MyId };

var cfg = try toml.parseInto(Config, arena.allocator(), "id = \"abc-123\"", null);
// cfg.id.raw == "abc-123"
```

Use cases: wrapping strings into parsed types (IP addresses, URIs), validation at parse time (positive-only integers, port ranges), enum construction from custom rules.

### `parseSlice`

```zig
pub fn parseSlice(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
) ParseError!*Table
```

Parses `input` as TOML v1.1.0. Returns a heap-allocated `*Table` on success. On failure, populates `err_info` (if non-null) and returns `error.ParseFailed`. Returns `error.OutOfMemory` on allocation failure.

### `deinit`

```zig
pub fn deinit(table: *Table, gpa: std.mem.Allocator) void
```

Recursively frees all memory owned by `table` and destroys the table pointer itself. Skip this if you used an `ArenaAllocator`. Just deinit the arena.

### `toJson`

```zig
pub fn toJson(value: Value, w: *std.Io.Writer) std.Io.Writer.Error!void
```

Serializes a parsed `Value` tree as JSON to `w`. NaN/Inf floats become `null`. Datetimes are ISO 8601 strings. Table keys are emitted in TOML insertion order.

```zig
var buf: [4096]u8 = undefined;
var w = std.Io.Writer.fixed(&buf);
try toml.toJson(root_value, &w);
std.debug.print("{s}\n", .{w.buffered()});
```

### `writeToml`

```zig
pub fn writeToml(value: Value, w: *std.Io.Writer) std.Io.Writer.Error!void
```

Serializes a parsed `Value` tree back to TOML text. Uses `[header]` syntax for sub-tables and `[[...]]` for arrays of tables. All output is valid TOML v1.1.0.

```zig
var buf: [4096]u8 = undefined;
var w = std.Io.Writer.fixed(&buf);
try toml.writeToml(.{ .table = root }, &w);
std.debug.print("{s}\n", .{w.buffered()});
```

### `writeTomlOpts`

```zig
pub fn writeTomlOpts(
    value: Value,
    w: *std.Io.Writer,
    opts: WriteOptions,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void
```

Same as `writeToml` but with `WriteOptions` for canonical output. Set `opts.sort_keys = true` to sort keys alphabetically within each table.

```zig
var buf: [4096]u8 = undefined;
var w = std.Io.Writer.fixed(&buf);
try toml.writeTomlOpts(.{ .table = root }, &w, .{ .sort_keys = true }, gpa);
```

### `writeTomlValue`

```zig
pub fn writeTomlValue(
    value: Value,
    w: *std.Io.Writer,
) (std.Io.Writer.Error || Allocator.Error)!void
```

Serializes one `Value` as a TOML value expression. Table values are emitted as inline tables, so the result is valid anywhere a TOML value can appear.

### `writeTomlValueOpts`

```zig
pub fn writeTomlValueOpts(
    value: Value,
    w: *std.Io.Writer,
    opts: WriteOptions,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || Allocator.Error)!void
```

Same as `writeTomlValue` but applies `WriteOptions` to the emitted value expression. `prefer_headers` has no effect here because a value position cannot emit TOML table headers.

### `WriteOptions`

```zig
pub const WriteOptions = struct {
    sort_keys: bool = false,
    prefer_headers: bool = false,
    use_escape_e: bool = false,
    preserve_order: bool = false,
};
```

### `parseSliceWithHints`

```zig
pub fn parseSliceWithHints(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    hints: ?*FormatHints,
) ParseError!*Table
```

Same as `parseSlice` but records string styles and comments into `FormatHints` during parsing. Pass the collected hints to `writeTomlWithProfile` for format-fidelity output.

### `parseSliceWithSpans`

```zig
pub fn parseSliceWithSpans(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    spans: ?*ParseSpans,
) ParseError!*Table
```

Same as `parseSlice` but records rewrite-ready value spans, statement spans, and table/AOT header spans keyed by structured path segments.

### `parseSliceWithOptions`

```zig
pub const ParseOptions = struct {
    hints: ?*FormatHints = null,
    spans: ?*ParseSpans = null,
};

pub fn parseSliceWithOptions(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
    options: ParseOptions,
) ParseError!*Table
```

Use this when you need both fidelity hints and span collection from a single parse.

### `rewriteValueAtPath`

```zig
pub fn rewriteValueAtPath(
    input: []const u8,
    path: []const PathSegment,
    new_value: Value,
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void
```

Rewrites one existing value in `input` by structured path and writes the result to `w`. Bytes outside the replaced value span are copied through unchanged.

This includes table replacements. By default, replacements preserve the existing string or table style when the parsed hints can justify it. With `prefer_headers = true`, table and array-of-tables replacements can expand into header-based TOML fragments instead of staying inline.

### `rewriteValueAtPathOpts`

```zig
pub fn rewriteValueAtPathOpts(
    input: []const u8,
    path: []const PathSegment,
    new_value: Value,
    w: *std.Io.Writer,
    opts: WriteOptions,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void
```

Same rewrite operation, but the replacement value is serialized with caller-provided `WriteOptions`. This is useful when the replacement expression should use a specific escape style or sorted inline-table keys instead of the default emission.

### `setValueAtPath`

```zig
pub fn setValueAtPath(
    input: []const u8,
    path: []const PathSegment,
    new_value: Value,
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void
```

Creates or replaces one value by structured path. Missing keys can be materialized under the nearest valid table or array-of-tables element. Missing indices are rejected.

### `setValueAtPathOpts`

```zig
pub fn setValueAtPathOpts(
    input: []const u8,
    path: []const PathSegment,
    new_value: Value,
    w: *std.Io.Writer,
    options: RewriteOptions,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void
```

Same create-or-replace operation, but with `RewriteOptions` controlling replacement formatting and whether existing style hints should be reused when rewriting an existing entry.

### `rewriteValues`

```zig
pub const RewriteOperation = struct {
    path: []const PathSegment,
    value: Value,
};

pub const RewriteMode = enum {
    replace_only,
    create_or_replace,
};

pub const RewriteOptions = struct {
    mode: RewriteMode = .replace_only,
    write: WriteOptions = .{},
    preserve_existing_styles: bool = true,
};

pub fn rewriteValues(
    input: []const u8,
    operations: []const RewriteOperation,
    w: *std.Io.Writer,
    options: RewriteOptions,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || RewriteError)!void
```

Applies multiple rewrite operations sequentially to one document. This is the Phase 6 batch surface. Later operations see the bytes produced by earlier ones.

### `FormatHints`

```zig
pub const PathSegment = union(enum) {
    key: []const u8,
    index: usize,
};

pub const HintPath = struct {
    segments: []const PathSegment,
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

pub fn HintMap(comptime V: type) type { ... }
```

`FormatHints` now carries structured-path fidelity data for comments, string styles, key quoting, key lexemes, untouched float and datetime lexemes, table syntax, and document-level BOM and line-ending preservation.

### `ParseSpans`

```zig
pub const ByteSpan = struct {
    start: usize,
    end: usize,
};

pub const EntrySpan = struct {
    value: ByteSpan,
    statement: ByteSpan,
};

pub const HeaderKind = enum(u1) { table, aot };

pub const HeaderSpan = struct {
    header: ByteSpan,
    kind: HeaderKind,
};

pub const ParseSpans = struct {
    entries: ?*EntrySpanMap = null,
    headers: ?*HeaderSpanMap = null,
};
```

### `OutputProfile`

```zig
pub const OutputProfile = enum { compact, preserve, canonical, faithful };
```

Each profile maps to a set of `WriteOptions` plus optional hint consumption:

- `compact`: `sort_keys = false`, `prefer_headers = false`, `use_escape_e = false`, consumes no hints.
- `preserve`: `sort_keys = false`, `prefer_headers = true`, `use_escape_e = false`, consumes `string_styles` and `preserve_order` behavior.
- `canonical`: `sort_keys = true`, `prefer_headers = true`, `use_escape_e = true`, consumes no hints.
- `faithful`: `sort_keys = false`, `prefer_headers = true`, `use_escape_e = true`, consumes `string_styles`, `comments`, `key_styles`, `key_lexemes`, `value_lexemes`, `table_syntax`, and `document`.

### `writeTomlWithProfile`

```zig
pub fn writeTomlWithProfile(
    value: Value,
    w: *std.Io.Writer,
    profile: OutputProfile,
    hints: ?*FormatHints,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void
```

Serializes `value` as TOML using a named profile. When `.faithful` is paired with collected hints, the writer preserves string styles, attached comments, key and header lexemes, untouched float and datetime spellings on modified output, inline-table and dotted-table syntax intent, and document-level BOM and line-ending behavior. Unchanged parsed documents can be replayed byte-for-byte from the stored original source.

### `parseSliceView`

```zig
pub fn parseSliceView(
    gpa: std.mem.Allocator,
    input: []const u8,
    err_info: ?*ErrorInfo,
) ParseError!*TableView
```

Zero-copy parse: strings borrow from `input` instead of being allocated. Caller must keep `input` alive while the view tree is in use. Free with `deinitViewTable`.

### `ValueView` / `TableView`

```zig
pub const ValueView = union(enum) { string, integer, float, boolean, offset_datetime, local_datetime, local_date, local_time, array: *ArrayListView, table: *TableView };
pub const TableView = std.array_hash_map.String(ValueView);
pub const ArrayListView = std.ArrayList(ValueView);
```

Zero-copy value tree. Strings are `[]const u8` slices into the parse input. Container types still heap-allocate but values inside borrow.

### `deinitViewTable`

```zig
pub fn deinitViewTable(tbl: *TableView, gpa: std.mem.Allocator, input: []const u8) void
```

Frees container structs and any owned string allocations (escaped strings). Borrowed strings pointing into `input` are left alone.

### `writeTomlView`

```zig
pub fn writeTomlView(
    view: ValueView,
    w: *std.Io.Writer,
    opts: WriteOptions,
    gpa: std.mem.Allocator,
    input: []const u8,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void
```

Serialize a `ValueView` tree to TOML. Internally clones to an owned `Value` and writes.

### `cloneValue`

```zig
pub fn cloneValue(gpa: std.mem.Allocator, view: ValueView, input: []const u8) std.mem.Allocator.Error!Value
```

Deep-copy a value from a view tree into an owned `Value` tree. All strings are freshly allocated. Use this when you need to keep values after the input buffer is freed.

### `ErrorInfo`

```zig
pub const ErrorInfo = struct {
    line: u32,
    col:  u32,
    // ...
    pub fn message(self: *const ErrorInfo) []const u8 { ... }
};
```

### Value types

| TOML type        | Field              | Zig type                                      |
| ---------------- | ------------------ | --------------------------------------------- |
| String           | `.string`          | `[]const u8`                                  |
| Integer          | `.integer`         | `IntValue` (`.value: i64`, `.base: Base`)     |
| Float            | `.float`           | `f64`                                         |
| Boolean          | `.boolean`         | `bool`                                        |
| Offset Date-Time | `.offset_datetime` | `OffsetDateTime`                              |
| Local Date-Time  | `.local_datetime`  | `LocalDateTime`                               |
| Local Date       | `.local_date`      | `LocalDate`                                   |
| Local Time       | `.local_time`      | `LocalTime`                                   |
| Array            | `.array`           | `*Array` (`std.ArrayList(Value)`)             |
| Table            | `.table`           | `*Table` (`std.array_hash_map.String(Value)`) |

All datetime structs are plain data (`year`, `month`, `day`, `hour`, `minute`, `second`, `nanosecond`, `offset_minutes`).

### Memory model

Every value in the tree is owned by the `gpa` you passed to `parseSlice`. You have two options:

1. **Arena**: pass `arena.allocator()` and call `arena.deinit()` when done.
2. **GPA**: call `toml.deinit(root, gpa)` to walk and free the tree precisely.

## Running the examples

Two examples demonstrate the parser at different complexity levels:

### Simple: `example.toml`

```sh
zig build example
```

Parses `examples/example.toml` (a small configuration snippet) and prints a typed JSON representation to stdout.

### Sophisticated: `proteomics.toml`

```sh
zig build proteomics
```

Parses `examples/proteomics.toml`, a 678-line bioinformatics configuration that exercises every TOML v1.1.0 feature: bare keys, quoted keys, dotted keys, all integer bases (hex, octal, binary), special floats (inf, -inf, nan), all four datetime types, multi-line basic and literal strings, escape sequences (`\e`, `\xHH`, `\uHHHH`, `\UHHHHHHHH`), arrays (nested, mixed-type), inline tables (single-line and multi-line), dotted-key table headers with quoted segments (`["user.custom-settings".nested.deep]`), and deeply nested arrays of tables. Outputs a structured color-coded report.

## Running tests

```sh
zig build test
```

Runs 150 tests: unit tests for both APIs plus the full toml-lang/toml-test corpus (215 valid + 467 invalid files), including corpus-backed sweeps for `parseInto`.

For the focused real-document release gate, run:

```sh
zig build validate
```

This runs the end-to-end validation harness in `test/validation.zig` plus the example, proteomics, and pyproject smoke programs.

## Build steps

| Command                | What it does                                           |
| ---------------------- | ------------------------------------------------------ |
| `zig build test`       | Run all unit tests and the toml-test corpus            |
| `zig build validate`   | Run the end-to-end validation harness and real-document smoke matrix |
| `zig build fuzz`       | Run the in-process fuzz harness (5000 random inputs)   |
| `zig build example`    | Parse `examples/example.toml` -> JSON to stdout        |
| `zig build proteomics` | Parse `examples/proteomics.toml` -> color-coded report |

## Roadmap

| Version    | Feature                 | Notes                                                                                                       |
| ---------- | ----------------------- | ----------------------------------------------------------------------------------------------------------- |
| **v0.4.0** | In-place value rewriter | Modify specific TOML keys without re-serializing. Comments and formatting survive the edit.                 |
| **v1.0.0** | `z-toml` CLI            | Standalone binary with `to-json`, `fmt`, `lint`, and `rewrite` subcommands. Marks API stability commitment. |

## References

- [TOML v1.1.0 spec](https://toml.io/en/v1.1.0): the specification this parser implements
- [toml-lang/toml-test](https://github.com/toml-lang/toml-test): the corpus used to validate correctness (215 valid, 467 invalid files)
- [TOML changelog](https://github.com/toml-lang/toml/blob/main/CHANGELOG.md): what changed from v1.0.0 to v1.1.0
- [zigistry](https://zigistry.dev/): the Zig community package index where this library is listed

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center"><em>
Keys nest in the deep,<br>
One pass clears the tangled brush,<br>
The value remains.
</em></p>
