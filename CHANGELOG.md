# Changelog

All notable changes to z-toml are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project follows [Semantic Versioning](https://semver.org/).

---

## [0.1.0] - 2026-05-02

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
