<!-- markdownlint-disable MD024 -->
# Changelog

All notable changes to z-toml are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project follows [Semantic Versioning](https://semver.org/).

---

## [0.4.0] - Unreleased

### Added

- Structured fidelity and span APIs for v0.4.0 work, including `PathSegment`, `HintPath`, attachment-aware comment records, expanded `FormatHints`, and opt-in parser span collection through `ParseSpans`, `parseSliceWithSpans`, and `parseSliceWithOptions`.
- Broader regression coverage for faithful output, modified-tree fidelity, and parser span capture across comments, multiline strings, quoted-dot keys, escaped keys and headers, inline tables, CRLF and BOM handling, floats and datetimes, and indexed array-of-tables paths.

### Changed

- `FormatHints` has been redesigned around structured paths and ordered records instead of flattened dotted keys and one-comment-per-path storage, and now carries the lexical data needed for faithful output such as key styles, key lexemes, untouched float and datetime lexemes, table syntax, and document-level BOM and line-ending hints.
- `writeTomlWithProfile(..., .faithful, ...)` is now substantially more faithful for both unchanged and modified documents: unchanged parsed input can be replayed byte-for-byte, while modified output preserves attached comments, multiline string styles, escaped keys and headers, dotted-table origin, inline-table spacing intent, line endings, BOMs, and untouched float and datetime spellings when the relevant hints are available.
- The owned parser now supports optional span capture on the same structured path model used by hints, including value spans, statement spans, and table or array-of-tables header spans, while keeping the default parse path on a dedicated no-span specialization.

### Fixed

- Quoted-dot keys no longer collide with nested dotted paths during hint lookup or faithful output.
- Header comment attachment and repeated comment replay now stay on the correct absolute path and preserve parse order for repeated entries and array-of-tables headers.
- Modified faithful output no longer normalizes away attached comment spacing, leaks internal comment trivia into attached-comment replay, or drops validity when fallback basic quoted key escaping is needed.

## [0.3.0] - 2026-05-20 - [Tagged]

### Added

- `WriteOptions.preserve_order`: single-pass writer that emits entries in insertion order. Scalar siblings after a table/AOT use dotted-key prefix instead of context-reset headers.
- `FormatHints`, `StringStyle`, `HintMap` types for format-fidelity tracking during parse.
- `parseSliceWithHints(gpa, input, err_info, hints)`: parse with format hints collection (string styles, comments).
- `parseSliceView(gpa, input, err_info)`: zero-copy parse returning `ValueView` tree where strings borrow from the input buffer.
- `ValueView`, `TableView`, `ArrayListView` types for zero-copy value trees.
- `cloneValue(gpa, view, input)`: deep-copy a `ValueView` tree into an owned `Value` tree.
- `deinitViewTable(tbl, gpa, input)`: free a view tree (containers + owned strings, leaves borrowed strings).
- `src/view.zig`: zero-copy view module.
- `src/output/hints.zig`: format hints module.
- `OutputProfile` enum (compact, preserve, canonical, faithful).
- `writeTomlWithProfile(value, w, profile, hints, gpa)`: profile-based TOML output that consumes FormatHints.
- Comment emission: `# text` lines written before key/value entries when hints are provided.
- Literal string style preservation: `'...'` output when original used literal strings.
- `writeTomlView(view, w, opts, gpa, input)`: serialize a ValueView tree directly to TOML text.
- Suite now 150 tests (126 existing + 24 new coverage tests).

### Changed

- Parser refactored to `ParserTy(V)`: comptime-generic over output type. `ParserVal` (owned) and `ParserView` (zero-copy) share one implementation.
- `WriteOptions.prefer_headers` now cooperates with `preserve_order`: all tables use header syntax when either flag is set.
- Writer functions (`writeTableInner`, `writeKV`, `writeValue`) now accept optional `FormatHints` for comment and string-style consumption.

### Fixed

- `bench_runner.zig` memory leak: wrapped allocations in `ArenaAllocator`.
- `fromToml` hook in `static.zig`: `OutOfMemory` errors now propagate instead of being silently converted to `TypeMismatch`.

## [0.2.0] - 2026-05-11 - [Tagged]

### Added

- `toml.writeToml(value, writer)`: serialize a `Value` tree to valid TOML v1.1.0. Uses `[header]` syntax for sub-tables, `[[...]]` for AOTs, inline `{...}` for scalar-only tables. Round-trips correctly (`parseSlice` → `writeToml` → `parseSlice`).
- `toml.writeTomlOpts(value, writer, opts, allocator)`: with `WriteOptions.sort_keys`, `.prefer_headers`, `.use_escape_e`.
- `toml.WriteOptions` struct.
- `tools/bench.zig`: inline benchmark via `zig build bench`.
- `tools/bench_runner.zig` + `tools/zebrac`: hardware-counter profiling (instructions, cache misses, RSS).
- `examples/pyproject_demo.zig`: end-to-end demo; parse `pyproject.toml` → JSON + round-trip TOML + canonical TOML. Run via `zig build pyproject`.
- `src/temporal.zig` shared date/time formatting helpers used by JSON output, TOML output, corpus comparisons, and examples.
- `test/output.zig` and `test/support.zig` for output-focused coverage and shared test file loading.
- 15 writeToml round-trip tests, 6 formatter tests, 4 fidelity tests, and the extracted output test module. Suite now 126 tests.

### Changed

- **`Value.integer` → `IntValue{value, base}`**: hex `0xFF` now writes back as `0xFF` instead of `255`. Access `.integer.value` for `i64`.
- `build.zig.zon` → `0.2.0`.
- Performance improvements: basic string fast path (−3.1% parse instructions), batched string escaping in writer (−3.0% write instructions), KV pre-collection with EntryKind (−3.3% branch misses), ArrayList pre-allocation. Combined parse+write: 5.55M → 5.38M instructions (−3.1%). RSS unchanged at 1.07MB. No leaks.
- Examples and docs updated for `IntValue`: dynamic integer access now uses `.integer.value`.
- Output and formatter tests moved out of `test/features.zig` into `test/output.zig` to keep parser and serializer coverage separate.
- Benchmarks now isolate arena allocations per input file, use the same parse → write → parse round-trip semantics in both runners, and use a portable monotonic timer path.

### Fixed

- `path_buf[64]` overflow in writeTableInner (bumped to `[128]`).
- AOT context-scoping bug: writer used dotted keys for sub-tables, breaking TOML context after `[[header]]`. Switched to `[header]` syntax for all sub-table navigation.
- Arrays at root level silently dropped: Pass 1 didn't handle `.array`; added non-AOT array serialization.
- Control chars in basic string fast path caused 5 invalid corpus files to parse successfully; added control-byte guard.
- `parse_example.zig` and `parse_proteomics.zig` no longer format `IntValue` as a bare integer struct.
- `parse_proteomics.zig` now prints the parsed `analysis_timestamp` value instead of hardcoding it, and no longer carries the dead `printArrayOfTables` helper.
- Temporal formatting logic is deduplicated across serializers, tests, and examples.
- `test/fuzz.zig` now walks nested arrays recursively instead of stopping after one array level.

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
[0.1.2]: https://github.com/eneskemalergin/z-toml/releases/tag/v0.1.2
[0.2.0]: https://github.com/eneskemalergin/z-toml/releases/tag/v0.2.0
[0.3.0]: https://github.com/eneskemalergin/z-toml/releases/tag/v0.3.0
