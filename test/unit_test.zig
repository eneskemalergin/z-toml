const std = @import("std");
const toml = @import("toml");

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
    try std.testing.expectEqual(@as(i64, 42), root.get("count").?.integer);
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
    try std.testing.expectEqual(@as(i64, 5432), root.get("database").?.table.get("port").?.integer);
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
    try std.testing.expectEqual(@as(i64, 1), pt.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), pt.get("y").?.integer);
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
    try std.testing.expectEqual(@as(i64, 0xDEAD), root.get("h").?.integer);
    try std.testing.expectEqual(@as(i64, 0o755), root.get("o").?.integer);
    try std.testing.expectEqual(@as(i64, 0b1010), root.get("b").?.integer);
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
    try std.testing.expectEqual(@as(i64, 1), arr.items[0].integer);
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
    try std.testing.expectEqual(@as(i64, 2), root.get("x").?.table.get("other").?.integer);
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
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/valid/spec-example-1.toml", gpa, .limited(std.math.maxInt(usize)));
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
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "examples/proteomics.toml", gpa, .limited(std.math.maxInt(usize)));
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

    // Samples — integer formats
    const samples = root.get("samples").?.table;
    try std.testing.expectEqual(@as(i64, 96), samples.get("total_samples").?.integer);
    try std.testing.expectEqual(@as(i64, 24), samples.get("biological_replicates").?.integer); // 0x18
    try std.testing.expectEqual(@as(i64, 0b11000000), samples.get("control_group_mask").?.integer);

    // Float specials
    try std.testing.expect(std.math.isInf(samples.get("special_threshold").?.float));
    try std.testing.expect(std.math.isNan(samples.get("undefined_metric").?.float));

    // Conditions — array of tables
    const groups = samples.get("groups").?.table;
    const conditions = groups.get("conditions").?.array;
    try std.testing.expectEqual(@as(usize, 3), conditions.items.len);
    try std.testing.expectEqualStrings("Control_37C", conditions.items[0].table.get("name").?.string);

    // Instrument — nested settings
    const instrument = root.get("instrument").?.table;
    const inst_settings = instrument.get("settings").?.table;
    try std.testing.expectEqual(@as(i64, 120000), inst_settings.get("resolution").?.integer);

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

    // Quantification channels — inline tables
    const quant = root.get("quantification").?.table;
    const q_channels = quant.get("channels").?.table;
    try std.testing.expect(q_channels.count() >= 10);
    try std.testing.expectEqualStrings("126C", q_channels.get("channel_126").?.table.get("name").?.string);

    // Identification filters — quoted keys with hyphens
    const ident = root.get("identification").?.table;
    const ident_filters = ident.get("filters").?.table;
    try std.testing.expectEqual(true, ident_filters.get("protein-groups").?.boolean);
    try std.testing.expectEqual(false, ident_filters.get("shared-peptides").?.boolean);

    // Quality control — array of tables with inline table parameters
    const qc = root.get("quality_control").?.table;
    const qc_checks = qc.get("checks").?.array;
    try std.testing.expectEqual(@as(usize, 4), qc_checks.items.len);
    try std.testing.expectEqualStrings("Outlier Samples", qc_checks.items[1].table.get("name").?.string);
    try std.testing.expectEqualStrings("mahalanobis", qc_checks.items[1].table.get("parameters").?.table.get("method").?.string);

    // Computing cluster jobs — array of tables with sub-tables
    const comp = root.get("computing").?.table;
    const cluster = comp.get("cluster").?.table;
    const jobs = cluster.get("jobs").?.array;
    try std.testing.expectEqual(@as(usize, 4), jobs.items.len);
    try std.testing.expectEqualStrings("database_search", jobs.items[0].table.get("name").?.string);
    try std.testing.expectEqualStrings("-Xmx32g -XX:+UseG1GC",
        jobs.items[0].table.get("environment").?.table.get("JAVA_OPTS").?.string);

    // Pipeline array of tables
    const pipeline = root.get("pipeline").?.array;
    try std.testing.expectEqual(@as(usize, 6), pipeline.items.len);

    // User custom settings — quoted table header ["user.custom-settings"]
    const custom = root.get("user.custom-settings").?.table;
    try std.testing.expectEqual(false, custom.get("enable_debug").?.boolean);
    const nested = custom.get("nested").?.table;
    try std.testing.expectEqual(@as(i64, 42), nested.get("number").?.integer);
    try std.testing.expectEqual(@as(i64, 0xDEADBEEF), nested.get("magic").?.integer);

    // Deep nested table via quoted+dotted key in header
    const deep = nested.get("deep").?.table;
    try std.testing.expectEqual(@as(i64, 3), deep.get("level").?.integer);
    try std.testing.expectEqual(true, deep.get("active").?.boolean);

    // Enrichment
    const enrich = root.get("enrichment").?.table;
    try std.testing.expectEqual(@as(usize, 7), enrich.get("databases").?.array.items.len);
}
