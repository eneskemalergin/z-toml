<!-- markdownlint-disable MD033 MD041 -->
<p align="center">
  <img src="assets/z-toml-icon_v2.svg" alt="z-toml logo" width="90">
</p>

<h1 align="center">z-toml</h1>

<p align="center">
  TOML v1.1.0 parser and rewrite toolkit for Zig 0.16 and 0.17.
</p>

<p align="center">
  <a href="https://github.com/eneskemalergin/z-toml/actions/workflows/ci.yml">
    <img src="https://github.com/eneskemalergin/z-toml/actions/workflows/ci.yml/badge.svg?style=flat-square" alt="CI">
  </a>
  <img src="https://img.shields.io/badge/version-v0.4.1-2C8EBB?style=flat-square" alt="v0.4.1">
  <img src="https://img.shields.io/badge/zig-0.16.0%20%7C%200.17.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0 | 0.17.0">
  <img src="https://img.shields.io/badge/TOML-v1.1.0-9C4221?style=flat-square" alt="TOML v1.1.0">
  <img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT">
</p>

<p align="center">
  Typed parse. Dynamic trees. Zero-copy views. Faithful output. Byte-local rewrites.
</p>

---

z-toml is built for tools that need more than parse-and-print. It gives you a single-pass TOML parser, a zero-copy read path, profile-based writers, and structured-path rewrites that preserve untouched bytes around the edit.

## Highlights

- `parseInto(T)` maps TOML directly onto Zig structs.
- `parseSlice` gives you a dynamic tree for unknown document shapes.
- `parseSliceView` borrows strings from the input buffer for zero-copy reads.
- `writeTomlWithProfile` supports `compact`, `preserve`, `canonical`, and `faithful` output modes.
- `rewriteValueAtPath`, `setValueAtPath`, and `rewriteValues` perform structured-path edits without reserializing the whole file.
- `toJson`, `writeToml`, and `writeTomlView` cover export, roundtrip, and view-based output flows.
- The core is zero-dependency, corpus-validated, and backed by explicit `test`, `validate`, and `fuzz` gates.

## Quick Look

```zig
const std = @import("std");
const toml = @import("toml");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const src =
        \\title = "My App"
        \\[server]
        \\port = 8080
    ;

    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    const port = root.get("server").?.table.get("port").?.integer.value;
    _ = port;
}
```

```zig
try toml.rewriteValueAtPath(
    src,
    &[_]toml.PathSegment{ .{ .key = "server" }, .{ .key = "port" } },
    .{ .integer = .{ .value = 9090 } },
    &writer,
    gpa,
);
```

## Install

Requires Zig `0.16.0` or `0.17.0`.

```sh
zig fetch --save https://github.com/eneskemalergin/z-toml/archive/refs/tags/v0.4.1.tar.gz
```

```zig
.dependencies = .{
    .z_toml = .{
        .url = "https://github.com/eneskemalergin/z-toml/archive/refs/tags/v0.4.1.tar.gz",
        .hash = "<run zig fetch to get the hash>",
    },
};
```

```zig
const z_toml = b.dependency("z_toml", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("toml", z_toml.module("toml"));
```

## Validation

- `zig build test` runs the package suite and corpus-backed checks.
- `zig build validate` runs the end-to-end real-document validation gate.
- `zig build fuzz` runs the 5000-iteration fuzz harness.

## Roadmap

Direction, not a schedule. Items land when they are ready.

- **Documentation**: guides and reference material for parsing, typed mapping, faithful output, and rewrites.
- **CLI**: `to-json`, `fmt`, `lint`, and `rewrite` commands, then extensions shaped by user feedback.
- **Typed serialization**: complete round trips, with `parseInto(T)` for reads and `writeFromStruct(T)` for writes.
- **Config overlays**: merge parsed trees, for layered configuration.
- **Composability**: zero-copy views together with format hints.
- **Zig releases**: keep up with new Zig versions as they ship.

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center"><em>
Keys nest in the deep,<br>
One pass clears the tangled brush,<br>
The value remains.
</em></p>
