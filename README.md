<!-- markdownlint-disable MD033 MD036 MD041 -->
<p align="center">
  <img src="assets/z-toml-icon_v2.svg" alt="z-toml logo" width="90">
</p>

<h1 align="center">z-toml</h1>

<p align="center">
  TOML v1.1.0 parser for Zig 0.16. Single-pass, no dependencies, corpus-validated. Typed and dynamic APIs.
</p>

<p align="center">
  <a href="https://github.com/eneskemalergin/z-toml/actions/workflows/ci.yml">
    <img src="https://github.com/eneskemalergin/z-toml/actions/workflows/ci.yml/badge.svg?style=flat-square" alt="CI">
  </a>
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0">
  <img src="https://img.shields.io/badge/TOML-v1.1.0-9C4221?style=flat-square" alt="TOML v1.1.0">
  <img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT">
</p>

---

- Single-pass recursive-descent. No intermediate AST.
- Full TOML 1.1.0 coverage: all value types, dotted keys, inline tables, arrays of tables, multi-line strings, escape sequences, date/time types
- `parseInto(T)`: map TOML directly onto a Zig struct with comptime reflection. No manual tree walking.
- `parseSlice`: dynamic tree API for unknown-shape documents
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
        .url = "https://github.com/eneskemalergin/z-toml/archive/refs/tags/v0.1.1.tar.gz",
        .hash = "<run zig fetch to get the hash>",
    },
},
```

Or use `zig fetch` to add it automatically:

```sh
zig fetch --save https://github.com/eneskemalergin/z-toml/archive/refs/tags/v0.1.1.tar.gz
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
    const port  = root.get("database").?.table.get("port").?.integer;
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
| Integer          | `.integer`         | `i64`                                         |
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

Runs 55 tests: unit tests for both APIs plus the full toml-lang/toml-test corpus (215 valid + 467 invalid files), including corpus-backed sweeps for `parseInto`.

## Build steps

| Command                | What it does                                           |
| ---------------------- | ------------------------------------------------------ |
| `zig build test`       | Run all unit tests and the toml-test corpus            |
| `zig build example`    | Parse `examples/example.toml` -> JSON to stdout        |
| `zig build proteomics` | Parse `examples/proteomics.toml` -> color-coded report |

## Roadmap

| Version | Feature | Notes |
| ------- | ------- | ----- |
| **v0.1.1** | `parseInto(T)` typed parser | Shipped |
| **v0.1.2** | Code quality and refactoring | File renames, memory layering fix, `src/output/` namespace. No API changes. |
| **v0.1.3** | `fromToml` custom hook | User types opt in by declaring `pub fn fromToml(v: toml.Value) !T`. Covers types that do not map directly (e.g. `std.net.Address`). |
| **v0.1.4** | `toJson` output | Convert a parsed `Value` tree to JSON. No external dependency. |
| **v0.2.0** | `writeToml` serializer | Write a `Value` tree or typed struct back to `.toml` text. First write-path capability. |
| **v0.2.1** | Canonical formatter | Pretty-print a `Value` tree to normalized TOML (stable key order, consistent spacing). Foundation for a `fmt` subcommand. |
| **v0.3.0** | Zero-copy strings | Return `[]const u8` slices into the input buffer instead of allocating copies. Architecture change; requires caller to keep input alive. |
| **v0.3.1** | `cloneValue` helper | Deep-copy a `Value` subtree into a fresh allocator. Companion to zero-copy. |
| **v0.4.0** | In-place value rewriter | Modify specific TOML keys without re-serializing. Comments and formatting survive the edit. |
| **v1.0.0** | `z-toml` CLI | Standalone binary with `to-json`, `fmt`, `lint`, and `rewrite` subcommands. Marks API stability commitment. |

## References

- [TOML v1.1.0 spec](https://toml.io/en/v1.1.0): the specification this parser implements
- [toml-lang/toml-test](https://github.com/toml-lang/toml-test): the corpus used to validate correctness (215 valid, 467 invalid files)
- [TOML changelog](https://github.com/toml-lang/toml/blob/main/CHANGELOG.md): what changed from v1.0.0 to v1.1.0
- [zig.pkg index](https://pkg.ziglang.org): the Zig community package index where this library is listed

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center"><em>
Keys nest in the deep,<br>
One pass clears the tangled brush,<br>
The value remains.
</em></p>
