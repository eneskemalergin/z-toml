//! Feature tests for the z-toml parser. Covers dynamic `parseSlice` API,
//! typed `parseInto` API, error paths, edge cases, and the `fromToml` hook.

const std = @import("std");
const toml = @import("toml");
const support = @import("support.zig");

test "empty document" {
    const gpa = std.testing.allocator;
    const root = try toml.parseSlice(gpa, "", null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqual(@as(usize, 0), root.count());
}

test "simple key/value" {
    const gpa = std.testing.allocator;
    const src =
        \\title = "TOML Example"
        \\count = 42
        \\flag = true
        \\pi = 3.14
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    try std.testing.expectEqualStrings("TOML Example", root.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 42), root.get("count").?.integer.value);
    try std.testing.expectEqual(true, root.get("flag").?.boolean);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), root.get("pi").?.float, 1e-10);
}

test "dotted keys" {
    const gpa = std.testing.allocator;
    const src =
        \\fruit.name = "banana"
        \\fruit.color = "yellow"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    const fruit = root.get("fruit").?.table;
    try std.testing.expectEqualStrings("banana", fruit.get("name").?.string);
    try std.testing.expectEqualStrings("yellow", fruit.get("color").?.string);
}

test "table header" {
    const gpa = std.testing.allocator;
    const src =
        \\[owner]
        \\name = "Tom"
        \\
        \\[database]
        \\port = 5432
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    try std.testing.expectEqualStrings("Tom", root.get("owner").?.table.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 5432), root.get("database").?.table.get("port").?.integer.value);
}

test "array of tables" {
    const gpa = std.testing.allocator;
    const src =
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    const products = root.get("products").?.array;
    try std.testing.expectEqual(@as(usize, 2), products.items.len);
    try std.testing.expectEqualStrings("Hammer", products.items[0].table.get("name").?.string);
    try std.testing.expectEqualStrings("Nail", products.items[1].table.get("name").?.string);
}

test "inline table" {
    const gpa = std.testing.allocator;
    const src =
        \\point = {x = 1, y = 2}
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    const pt = root.get("point").?.table;
    try std.testing.expectEqual(@as(i64, 1), pt.get("x").?.integer.value);
    try std.testing.expectEqual(@as(i64, 2), pt.get("y").?.integer.value);
}

test "string escapes" {
    const gpa = std.testing.allocator;
    const src =
        \\s = "hello\nworld\t!\u0041"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqualStrings("hello\nworld\t!A", root.get("s").?.string);
}

test "integer bases" {
    const gpa = std.testing.allocator;
    const src =
        \\h = 0xDEAD
        \\o = 0o755
        \\b = 0b1010
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqual(@as(i64, 0xDEAD), root.get("h").?.integer.value);
    try std.testing.expectEqual(@as(i64, 0o755), root.get("o").?.integer.value);
    try std.testing.expectEqual(@as(i64, 0b1010), root.get("b").?.integer.value);
}

test "float specials" {
    const gpa = std.testing.allocator;
    const src =
        \\a = inf
        \\b = -inf
        \\c = nan
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    try std.testing.expect(std.math.isInf(root.get("a").?.float));
    try std.testing.expect(std.math.isInf(root.get("b").?.float));
    try std.testing.expect(std.math.isNan(root.get("c").?.float));
}

test "local date" {
    const gpa = std.testing.allocator;
    const src = "d = 1979-05-27";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    const d = root.get("d").?.local_date;
    try std.testing.expectEqual(@as(u16, 1979), d.year);
    try std.testing.expectEqual(@as(u8, 5), d.month);
    try std.testing.expectEqual(@as(u8, 27), d.day);
}

test "local time" {
    const gpa = std.testing.allocator;
    const src = "t = 07:32:00";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    const t = root.get("t").?.local_time;
    try std.testing.expectEqual(@as(u8, 7), t.hour);
    try std.testing.expectEqual(@as(u8, 32), t.minute);
}

test "offset datetime" {
    const gpa = std.testing.allocator;
    const src = "dt = 1979-05-27T07:32:00Z";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    const dt = root.get("dt").?.offset_datetime;
    try std.testing.expectEqual(@as(u16, 1979), dt.date.year);
    try std.testing.expectEqual(@as(i16, 0), dt.offset_minutes);
}

test "comments" {
    const gpa = std.testing.allocator;
    const src =
        \\# full line comment
        \\key = "value" # end of line comment
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqualStrings("value", root.get("key").?.string);
}

test "multi-line basic string" {
    const gpa = std.testing.allocator;
    const src =
        \\s = """
        \\line one
        \\line two"""
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqualStrings("line one\nline two", root.get("s").?.string);
}

test "multi-line literal string" {
    const gpa = std.testing.allocator;
    const src =
        \\s = '''
        \\no \escapes here
        \\'''
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqualStrings("no \\escapes here\n", root.get("s").?.string);
}

test "array mixed" {
    const gpa = std.testing.allocator;
    const src = "x = [1, 2.0, \"three\"]";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    const arr = root.get("x").?.array;
    try std.testing.expectEqual(@as(usize, 3), arr.items.len);
    try std.testing.expectEqual(@as(i64, 1), arr.items[0].integer.value);
}

test "super-table defined after sub-table" {
    const gpa = std.testing.allocator;
    const src =
        \\[x.y.z.w]
        \\key = 1
        \\[x]
        \\other = 2
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqual(@as(i64, 2), root.get("x").?.table.get("other").?.integer.value);
}

test "invalid duplicate key" {
    const gpa = std.testing.allocator;
    const src =
        \\name = "a"
        \\name = "b"
    ;
    try std.testing.expectError(error.ParseFailed, toml.parseSlice(gpa, src, null));
}

test "invalid duplicate table header" {
    const gpa = std.testing.allocator;
    const src =
        \\[fruit]
        \\color = "red"
        \\[fruit]
        \\color = "blue"
    ;
    try std.testing.expectError(error.ParseFailed, toml.parseSlice(gpa, src, null));
}

test "reject bare CR line endings" {
    const gpa = std.testing.allocator;
    const src = "key = 1\rnext = 2";
    try std.testing.expectError(error.ParseFailed, toml.parseSlice(gpa, src, null));
}

test "reject dotted key traversal through array of tables" {
    const gpa = std.testing.allocator;
    const src =
        \\[[tab.arr]]
        \\[tab]
        \\arr.val1 = 1
    ;
    try std.testing.expectError(error.ParseFailed, toml.parseSlice(gpa, src, null));
}

test "reject invalid unicode scalar escape" {
    const gpa = std.testing.allocator;
    const src = "bad = \"\\uD800\"";
    try std.testing.expectError(error.ParseFailed, toml.parseSlice(gpa, src, null));
}

test "reject invalid leap day" {
    const gpa = std.testing.allocator;
    const src = "day = 2100-02-29";
    try std.testing.expectError(error.ParseFailed, toml.parseSlice(gpa, src, null));
}

test "offset datetime preserves fractional seconds" {
    const gpa = std.testing.allocator;
    const src = "dt = 1979-05-27T07:32:00.5Z";
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);

    const dt = root.get("dt").?.offset_datetime;
    try std.testing.expectEqual(@as(u32, 500_000_000), dt.time.nanosecond);
    try std.testing.expectEqual(@as(i16, 0), dt.offset_minutes);
}

test "reject leading zeros in exponent-only float" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.ParseFailed, toml.parseSlice(gpa, "x = 00e1\n", null));
    try std.testing.expectError(error.ParseFailed, toml.parseSlice(gpa, "x = 01e2\n", null));
    // Valid: single zero before exponent is allowed
    const root = try toml.parseSlice(gpa, "x = 0e1\n", null);
    defer toml.deinit(root, gpa);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), root.get("x").?.float, 1e-15);
}

test "example file: spec-example-1.toml" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "test/valid/spec-example-1.toml");
    defer gpa.free(src);

    var err: toml.ErrorInfo = .{};
    const root = toml.parseSlice(gpa, src, &err) catch |e| {
        std.debug.print("\nparse error line={d} col={d}: {s}\n", .{ err.line, err.col, err.message() });
        return e;
    };
    defer toml.deinit(root, gpa);
    try std.testing.expect(root.count() > 0);
}

test "proteomics.toml parses successfully" {
    const gpa = std.testing.allocator;
    const src = try support.readTestFile(gpa, "examples/proteomics.toml");
    defer gpa.free(src);

    var err: toml.ErrorInfo = .{};
    const root = toml.parseSlice(gpa, src, &err) catch |e| {
        std.debug.print("\nparse error line={d} col={d}: {s}\n", .{ err.line, err.col, err.message() });
        return e;
    };
    defer toml.deinit(root, gpa);

    // Verify root-level key count
    try std.testing.expect(root.count() >= 10);

    // Study metadata
    try std.testing.expectEqualStrings("PROT-2025-0042", root.get("study-id").?.string);
    try std.testing.expectEqual(true, root.get("is_clinical").?.boolean);

    // Samples: integer formats
    const samples = root.get("samples").?.table;
    try std.testing.expectEqual(@as(i64, 96), samples.get("total_samples").?.integer.value);
    try std.testing.expectEqual(@as(i64, 24), samples.get("biological_replicates").?.integer.value); // 0x18
    try std.testing.expectEqual(@as(i64, 0b11000000), samples.get("control_group_mask").?.integer.value);

    // Float specials
    try std.testing.expect(std.math.isInf(samples.get("special_threshold").?.float));
    try std.testing.expect(std.math.isNan(samples.get("undefined_metric").?.float));

    // Conditions: array of tables
    const groups = samples.get("groups").?.table;
    const conditions = groups.get("conditions").?.array;
    try std.testing.expectEqual(@as(usize, 3), conditions.items.len);
    try std.testing.expectEqualStrings("Control_37C", conditions.items[0].table.get("name").?.string);

    // Instrument: nested settings
    const instrument = root.get("instrument").?.table;
    const inst_settings = instrument.get("settings").?.table;
    try std.testing.expectEqual(@as(i64, 120000), inst_settings.get("resolution").?.integer.value);

    // Ionization sub-table
    const ionization = inst_settings.get("ionization").?.table;
    try std.testing.expectEqualStrings("NSI", ionization.get("source").?.string);

    // Nested array-of-arrays (mz_ranges)
    const mz_ranges = inst_settings.get("mz_ranges").?.array;
    try std.testing.expectEqual(@as(usize, 3), mz_ranges.items.len);
    try std.testing.expectEqual(@as(usize, 2), mz_ranges.items[0].array.items.len);

    // Database search
    const db = root.get("database").?.table;
    const db_search = db.get("search").?.table;
    try std.testing.expectEqualStrings("Trypsin", db_search.get("enzyme").?.string);
    try std.testing.expectEqual(@as(usize, 5), db_search.get("variable_modifications").?.array.items.len);

    // Quantification channels: inline tables
    const quant = root.get("quantification").?.table;
    const q_channels = quant.get("channels").?.table;
    try std.testing.expect(q_channels.count() >= 10);
    try std.testing.expectEqualStrings("126C", q_channels.get("channel_126").?.table.get("name").?.string);

    // Identification filters: quoted keys with hyphens
    const ident = root.get("identification").?.table;
    const ident_filters = ident.get("filters").?.table;
    try std.testing.expectEqual(true, ident_filters.get("protein-groups").?.boolean);
    try std.testing.expectEqual(false, ident_filters.get("shared-peptides").?.boolean);

    // Quality control: array of tables with inline table parameters
    const qc = root.get("quality_control").?.table;
    const qc_checks = qc.get("checks").?.array;
    try std.testing.expectEqual(@as(usize, 4), qc_checks.items.len);
    try std.testing.expectEqualStrings("Outlier Samples", qc_checks.items[1].table.get("name").?.string);
    try std.testing.expectEqualStrings("mahalanobis", qc_checks.items[1].table.get("parameters").?.table.get("method").?.string);

    // Computing cluster jobs: array of tables with sub-tables
    const comp = root.get("computing").?.table;
    const cluster = comp.get("cluster").?.table;
    const jobs = cluster.get("jobs").?.array;
    try std.testing.expectEqual(@as(usize, 4), jobs.items.len);
    try std.testing.expectEqualStrings("database_search", jobs.items[0].table.get("name").?.string);
    try std.testing.expectEqualStrings("-Xmx32g -XX:+UseG1GC", jobs.items[0].table.get("environment").?.table.get("JAVA_OPTS").?.string);

    // Pipeline array of tables
    const pipeline = root.get("pipeline").?.array;
    try std.testing.expectEqual(@as(usize, 6), pipeline.items.len);

    // Quoted table header ["user.custom-settings"]
    const custom = root.get("user.custom-settings").?.table;
    try std.testing.expectEqual(false, custom.get("enable_debug").?.boolean);
    const nested = custom.get("nested").?.table;
    try std.testing.expectEqual(@as(i64, 42), nested.get("number").?.integer.value);
    try std.testing.expectEqual(@as(i64, 0xDEADBEEF), nested.get("magic").?.integer.value);

    // Deep nested table via quoted+dotted key in header
    const deep = nested.get("deep").?.table;
    try std.testing.expectEqual(@as(i64, 3), deep.get("level").?.integer.value);
    try std.testing.expectEqual(true, deep.get("active").?.boolean);

    // Enrichment
    const enrich = root.get("enrichment").?.table;
    try std.testing.expectEqual(@as(usize, 7), enrich.get("databases").?.array.items.len);
}

// ─── parseInto tests ─────────────────────────────────────────────────────────

test "parseInto: flat struct with all scalar types" {
    const Config = struct {
        title: []const u8,
        port: u16,
        debug: bool,
        ratio: f64,
    };
    const src =
        \\title = "My App"
        \\port = 8080
        \\debug = true
        \\ratio = 0.5
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), src, null);
    try std.testing.expectEqualStrings("My App", cfg.title);
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqual(true, cfg.debug);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), cfg.ratio, 1e-10);
}

test "parseInto: signed integers including negative values" {
    const Config = struct { delta: i32, temp: i8 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "delta = -300\ntemp = -42", null);
    try std.testing.expectEqual(@as(i32, -300), cfg.delta);
    try std.testing.expectEqual(@as(i8, -42), cfg.temp);
}

test "parseInto: f32 field uses floatCast" {
    const Config = struct { x: f32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "x = 1.5", null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), cfg.x, 1e-6);
}

test "parseInto: integer promoted to float" {
    const Config = struct { ratio: f64 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "ratio = 2", null);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), cfg.ratio, 1e-10);
}

test "parseInto: optional field absent yields null" {
    const Config = struct {
        name: []const u8,
        timeout: ?u32,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "name = \"z-toml\"", null);
    try std.testing.expectEqualStrings("z-toml", cfg.name);
    try std.testing.expectEqual(@as(?u32, null), cfg.timeout);
}

test "parseInto: optional nested struct absent yields null" {
    const Database = struct { host: []const u8, port: u16 };
    const Config = struct { database: ?Database };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "", null);
    try std.testing.expectEqual(@as(?Database, null), cfg.database);
}

test "parseInto: default value used when key absent" {
    const Config = struct { retries: u8 = 3 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "", null);
    try std.testing.expectEqual(@as(u8, 3), cfg.retries);
}

test "parseInto: nested struct maps to table" {
    const Database = struct { host: []const u8, port: u16 };
    const Config = struct { database: Database };
    const src =
        \\[database]
        \\host = "localhost"
        \\port = 5432
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), src, null);
    try std.testing.expectEqualStrings("localhost", cfg.database.host);
    try std.testing.expectEqual(@as(u16, 5432), cfg.database.port);
}

test "parseInto: dotted key builds nested struct" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { server: Server };
    const src =
        \\server.host = "example.com"
        \\server.port = 443
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), src, null);
    try std.testing.expectEqualStrings("example.com", cfg.server.host);
    try std.testing.expectEqual(@as(u16, 443), cfg.server.port);
}

test "parseInto: array-of-tables maps to slice of structs" {
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { servers: []Server };
    const src =
        \\[[servers]]
        \\host = "a.example.com"
        \\port = 8001
        \\
        \\[[servers]]
        \\host = "b.example.com"
        \\port = 8002
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), src, null);
    try std.testing.expectEqual(@as(usize, 2), cfg.servers.len);
    try std.testing.expectEqualStrings("a.example.com", cfg.servers[0].host);
    try std.testing.expectEqual(@as(u16, 8001), cfg.servers[0].port);
    try std.testing.expectEqualStrings("b.example.com", cfg.servers[1].host);
    try std.testing.expectEqual(@as(u16, 8002), cfg.servers[1].port);
}

test "parseInto: slice of integers" {
    const Config = struct { ports: []u16 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "ports = [80, 443, 8080]", null);
    try std.testing.expectEqual(@as(usize, 3), cfg.ports.len);
    try std.testing.expectEqual(@as(u16, 80), cfg.ports[0]);
    try std.testing.expectEqual(@as(u16, 8080), cfg.ports[2]);
}

test "parseInto: empty array produces zero-length slice" {
    const Config = struct { tags: [][]const u8 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "tags = []", null);
    try std.testing.expectEqual(@as(usize, 0), cfg.tags.len);
}

test "parseInto: slice of strings" {
    const Config = struct { tags: [][]const u8 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "tags = [\"zig\", \"toml\", \"fast\"]", null);
    try std.testing.expectEqual(@as(usize, 3), cfg.tags.len);
    try std.testing.expectEqualStrings("zig", cfg.tags[0]);
    try std.testing.expectEqualStrings("fast", cfg.tags[2]);
}

test "parseInto: enum field maps from string" {
    const Level = enum { debug, info, warn, err };
    const Config = struct { log_level: Level };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "log_level = \"warn\"", null);
    try std.testing.expectEqual(Level.warn, cfg.log_level);
}

test "parseInto: extra TOML keys not in struct are silently ignored" {
    const Config = struct { port: u16 };
    const src =
        \\port = 9000
        \\extra_key = "should be ignored"
        \\[section_not_in_struct]
        \\x = 1
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), src, null);
    try std.testing.expectEqual(@as(u16, 9000), cfg.port);
}

test "parseInto: invalid TOML propagates ParseFailed" {
    const Config = struct { x: u32 };
    var err: toml.ErrorInfo = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = toml.parseInto(Config, arena.allocator(), "x = !!bad", &err);
    try std.testing.expectError(error.ParseFailed, result);
    try std.testing.expect(err.line >= 1);
}

test "parseInto: missing required field returns MissingField" {
    const Config = struct { required: u32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.MissingField,
        toml.parseInto(Config, arena.allocator(), "", null),
    );
}

test "parseInto: type mismatch string-for-integer returns TypeMismatch" {
    const Config = struct { count: u32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        toml.parseInto(Config, arena.allocator(), "count = \"not a number\"", null),
    );
}

test "parseInto: type mismatch bool-for-integer returns TypeMismatch" {
    const Config = struct { count: u32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        toml.parseInto(Config, arena.allocator(), "count = true", null),
    );
}

test "parseInto: type mismatch table-for-scalar returns TypeMismatch" {
    const Config = struct { port: u16 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        toml.parseInto(Config, arena.allocator(), "[port]\nx = 1", null),
    );
}

test "parseInto: integer positive overflow returns TypeMismatch" {
    const Config = struct { small: u8 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        toml.parseInto(Config, arena.allocator(), "small = 300", null),
    );
}

test "parseInto: negative integer into unsigned returns TypeMismatch" {
    const Config = struct { count: u32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        toml.parseInto(Config, arena.allocator(), "count = -1", null),
    );
}

test "parseInto: enum unknown variant returns TypeMismatch" {
    const Level = enum { debug, info, warn, err };
    const Config = struct { log_level: Level };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        toml.parseInto(Config, arena.allocator(), "log_level = \"trace\"", null),
    );
}

test "\\x hex escape produces correct bytes" {
    const gpa = std.testing.allocator;
    const src =
        \\s = "\x68\x65\x6c\x6c\x6f"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqualStrings("hello", root.get("s").?.string);
}

test "\\e escape produces ESC byte" {
    const gpa = std.testing.allocator;
    const src =
        \\s = "\e[31m"
    ;
    const root = try toml.parseSlice(gpa, src, null);
    defer toml.deinit(root, gpa);
    try std.testing.expectEqualStrings("\x1B[31m", root.get("s").?.string);
}

test "fromToml: happy path wraps string into custom type" {
    const MyId = struct {
        raw: []const u8,
        pub fn fromToml(v: toml.Value, allocator: std.mem.Allocator) !@This() {
            const s = v.string;
            return @This(){ .raw = try allocator.dupe(u8, s) };
        }
    };
    const Config = struct { id: MyId };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "id = \"abc-123\"", null);
    try std.testing.expectEqualStrings("abc-123", cfg.id.raw);
}

test "fromToml: error returned from hook maps to TypeMismatch" {
    const NeverPositive = struct {
        x: i64,
        pub fn fromToml(v: toml.Value, allocator: std.mem.Allocator) !@This() {
            _ = allocator;
            if (v.integer.value <= 0) return error.NegativeValue;
            return @This(){ .x = v.integer.value };
        }
    };
    const Config = struct { val: NeverPositive };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        toml.parseInto(Config, arena.allocator(), "val = -1", null),
    );
}

test "fromToml: type without fromToml still maps normally" {
    const Config = struct { name: []const u8, count: i64 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "name = \"zig\"\ncount = 42", null);
    try std.testing.expectEqualStrings("zig", cfg.name);
    try std.testing.expectEqual(@as(i64, 42), cfg.count);
}

test "fromToml: allocator passthrough returns owned []u8" {
    const OwnedStr = struct {
        buf: []u8,
        pub fn fromToml(v: toml.Value, allocator: std.mem.Allocator) !@This() {
            const duped = try allocator.dupe(u8, v.string);
            return @This(){ .buf = duped };
        }
    };
    const Config = struct { label: OwnedStr };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "label = \"hello\"", null);
    try std.testing.expectEqualStrings("hello", cfg.label.buf);
}

test "fromToml: optional ?MyFromTomlType field" {
    const MyId = struct {
        raw: []const u8,
        pub fn fromToml(v: toml.Value, allocator: std.mem.Allocator) !@This() {
            return @This(){ .raw = try allocator.dupe(u8, v.string) };
        }
    };
    const Config = struct { id: ?MyId };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "id = \"abc\"", null);
    try std.testing.expect(cfg.id != null);
    try std.testing.expectEqualStrings("abc", cfg.id.?.raw);

    const cfg2 = try toml.parseInto(Config, arena.allocator(), "", null);
    try std.testing.expect(cfg2.id == null);
}

test "fromToml: slice []MyFromTomlType" {
    const Wrapper = struct {
        inner: i64,
        pub fn fromToml(v: toml.Value, allocator: std.mem.Allocator) !@This() {
            _ = allocator;
            return @This(){ .inner = v.integer.value };
        }
    };
    const Config = struct { nums: []Wrapper };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(Config, arena.allocator(), "nums = [10, 20, 30]", null);
    try std.testing.expectEqual(@as(usize, 3), cfg.nums.len);
    try std.testing.expectEqual(@as(i64, 10), cfg.nums[0].inner);
    try std.testing.expectEqual(@as(i64, 30), cfg.nums[2].inner);
}

test "fromToml: hook on root struct fires instead of mapTable" {
    const RootCustom = struct {
        title: []const u8,
        pub fn fromToml(v: toml.Value, allocator: std.mem.Allocator) !@This() {
            const tbl = v.table;
            const t = tbl.get("my_title").?.string;
            return @This(){ .title = try allocator.dupe(u8, t) };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try toml.parseInto(RootCustom, arena.allocator(), "my_title = \"custom mapping\"", null);
    try std.testing.expectEqualStrings("custom mapping", cfg.title);
}
