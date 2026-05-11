<!-- markdownlint-disable MD024 -->
# Changelog

All notable changes to z-toml are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project follows [Semantic Versioning](https://semver.org/).

---

## [0.2.0] - 2026-05-11

### Added

- `toml.writeToml(value, writer)`: serialize a parsed `Value` tree back to `.toml` text. Uses `[header]` syntax for sub-tables and `[[...]]` for arrays of tables. All output is valid TOML v1.1.0.
- `toml.writeTomlOpts(value, writer, opts, allocator)`: writeToml with `WriteOptions` for canonical output.
- `toml.WriteOptions`: struct with `sort_keys: bool` — when true, keys are sorted alphabetically within each table for deterministic canonical output.
- 15 `writeToml` round-trip tests: simple scalars, special floats, arrays, inline tables, dotted keys, AOTs, nested AOTs with sub-tables/sub-AOTs, datetime variants, empty document, quoted keys, mixed root/dotted tables, spec-example-1, proteomics (678-line real-world file).
- 6 canonical formatter tests: insertion order preserved, sort_keys alphabetical, deterministic output, round-trip with sort_keys, nested table sorting, default opts matches writeToml.
- Test suite is now 127 tests.

### Changed

- `build.zig.zon` version bumped to `0.2.0`.

---

## [0.1.4] - 2026-05-11

### Added

- `toml.toJson(value, writer)`: serialize a parsed `Value` tree to JSON text. Recursive walker covering all 10 `Value` variants. Datetimes become ISO 8601 strings. NaN/Inf floats become JSON `null`. Table keys are emitted in TOML insertion order.
- 18 `toJson` unit tests: string (with escapes), integer, float, NaN/Inf → null, boolean, all four datetime types, empty/mixed arrays, empty/populated tables, round-trip parseSlice→toJson verification.
- Test suite is now 100 tests (82 original + 18 toJson).

### Changed

- `build.zig.zon` version bumped to `0.1.4`.

---

## [0.1.3] - 2026-05-11

### Added

- `fromToml` custom hook for `parseInto`. Types declaring `pub fn fromToml(v: toml.Value, allocator: Allocator) !T` get called instead of the default comptime reflection mapping. The hook fires before any built-in type logic, giving user-defined types full control over construction from a TOML value. User errors become `TypeMismatch`.
- 7 `fromToml` unit tests: happy path, error contract, regression (no hook), allocator passthrough, optional unwrapping, slice of custom types, root struct with hook.

### Changed

- `build.zig.zon` version bumped to `0.1.3`.

---

## [0.1.2] - 2026-05-02 - [Tagged]

### Added

- Two new escape sequence unit tests: `\x` hex escape produces correct bytes, `\e` escape produces ESC byte. Test suite is now 75 tests (52 feature + 5 corpus + 18 OOM).

### Changed

- `src/types.zig` renamed to `src/value.zig`. The file defines the `Value` union and datetime types; the new name matches its content.
- `src/typed.zig` renamed to `src/static.zig`. "Static parser" is the project's own term for the `parseInto` path.
- `deinitTable` and `Value.deinit` moved from `value.zig` into `parser.zig`. `value.zig` is now a pure type-definitions file with no allocator dependency. `root.zig` calls `parser.deinitTable` (public API unchanged).
- `src/output/` namespace created with placeholder files `json.zig` and `toml.zig` for the upcoming `toJson` (v0.1.4) and `writeToml`/`fmtToml` (v0.2.0+) modules.
- `build.zig.zon` version bumped to `0.1.2`.

### Fixed

- Missing `try` on `gpa.dupe` call in `src/static.zig`. The omission caused a compile error at call sites that did not themselves return `Allocator.Error`; the allocation failure path was also silently unreachable.
- Dead `value[end..end]` slice (always empty) removed from `normalizeTemporalValue` in `test/corpus.zig`. The `bufPrint` call now uses a 2-argument form.

---

## [0.1.1] - 2026-05-02

### Added

- `parseInto(T)`: typed parser that maps a TOML document directly onto a Zig struct using comptime reflection. Supports `bool`, all integer widths (range-checked), `f32`/`f64` (integer promoted), `[]const u8`, `[]T`, nested structs, `?T` (null for absent keys), enums (string by name), and all four datetime types.
- `ParseIntoError` error set (`ParseError | error{TypeMismatch, MissingField}`).
- 12 rigorous `parseInto` unit tests covering: flat structs, signed integers, float promotion, optional absent fields, default values, nested headers, dotted keys, arrays of tables, typed slices, enums, extra-keys tolerance, error propagation, `MissingField`, `TypeMismatch` variants, overflow, and unknown enum variants.
- Three corpus-backed `parseInto` tests: sweep of all 215 valid files (no `ParseFailed`), sweep of all 467 invalid files (all `ParseFailed`), and an exact-field fixture against the `spec-example-1` corpus file.

### Changed

- `build.zig.zon` version bumped to `0.1.1`.
- `build.zig.zon` now includes `minimum_zig_version = "0.16.0"` and a package fingerprint.

---

## [0.1.0] - 2026-05-02 - [Tagged]

First public release.

### Added

- Full TOML v1.1.0 parser: all value types (string, integer, float, boolean, offset datetime, local datetime, local date, local time, array, table)
- Dotted keys, inline tables, arrays of tables, multi-line basic and literal strings
- All TOML 1.1.0 escape sequences (`\e`, `\xHH`, `\uHHHH`, `\UHHHHHHHH`)
- Calendar date validation including leap year handling
- Reject invalid constructs: bare CR, NUL bytes, control characters in strings and comments, signed non-decimal integers, leading zeros in integers and floats, invalid Unicode scalars, uppercase base prefixes (`0X`), bad underscore placement
- Table state enforcement: inline tables cannot be extended after definition, explicitly defined tables cannot be reopened, dotted keys cannot traverse arrays of tables
- Structured error info with line, column, and message on parse failure
- Validated against the toml-lang/toml-test corpus: 215 valid files (semantic JSON comparison), 467 invalid files (all rejected)
- 29 unit tests (28 feature tests + 1 complex integration test parsing a 678-line proteomics bioinformatics configuration covering every TOML 1.1.0 feature)
- Two examples: `zig build example` (simple configuration) and `zig build proteomics` (sophisticated showcase)
- `build.zig.zon` package manifest for the Zig package manager
- MIT license

[0.1.0]: https://github.com/eneskemalergin/z-toml/releases/tag/v0.1.0
