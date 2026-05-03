const std = @import("std");
const toml = @import("toml");
const Io = std.Io;

fn printIndent(w: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll("  ");
}

fn printKey(w: anytype, indent: usize, key: []const u8) !void {
    try printIndent(w, indent);
    try w.print("\x1b[1;36m{s}\x1b[0m: ", .{key});
}

fn printScalar(w: anytype, comptime color: []const u8, comptime fmt_str: []const u8, args: anytype) !void {
    try w.print("\x1b[" ++ color ++ "m" ++ fmt_str ++ "\x1b[0m\n", args);
}

fn printTable(w: anytype, tbl: *toml.Table, indent: usize) !void {
    for (tbl.keys(), tbl.values()) |key, val| {
        try printKey(w, indent, key);
        switch (val) {
            .string => |s| try printScalar(w, "32", "\"{s}\"", .{s}),
            .integer => |v| try printScalar(w, "33", "{d}", .{v}),
            .float => |v| try printScalar(w, "35", "{d}", .{v}),
            .boolean => |v| try printScalar(w, "33", "{s}", .{if (v) "true" else "false"}),
            .offset_datetime => |v| try printScalar(w, "34", "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s:d:0>2}:{d:0>2}", .{ v.date.year, v.date.month, v.date.day, v.time.hour, v.time.minute, v.time.second, if (v.offset_minutes < 0) '-' else '+', @abs(@divTrunc(v.offset_minutes, 60)), @abs(@mod(v.offset_minutes, 60)) }),
            .local_datetime => |v| try printScalar(w, "34", "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ v.date.year, v.date.month, v.date.day, v.time.hour, v.time.minute, v.time.second }),
            .local_date => |v| try printScalar(w, "34", "{d:0>4}-{d:0>2}-{d:0>2}", .{ v.year, v.month, v.day }),
            .local_time => |v| try printScalar(w, "34", "{d:0>2}:{d:0>2}:{d:0>2}", .{ v.hour, v.minute, v.second }),
            .array => |arr| {
                try w.writeAll("\x1b[33m[");
                if (arr.items.len <= 4) {
                    for (arr.items, 0..) |item, i| {
                        if (i > 0) try w.writeAll(", ");
                        switch (item) {
                            .string => |s| try w.print("\"{s}\"", .{s}),
                            .integer => |v| try w.print("{d}", .{v}),
                            .float => |v| try w.print("{d}", .{v}),
                            .boolean => |v| try w.print("{s}", .{if (v) "true" else "false"}),
                            else => try w.writeAll("..."),
                        }
                    }
                } else {
                    try w.print("{d} items", .{arr.items.len});
                }
                try w.writeAll("]\x1b[0m\n");
            },
            .table => |sub| {
                try w.writeAll("\n");
                try printTable(w, sub, indent + 1);
            },
        }
    }
}

fn printArrayOfTables(w: anytype, key: []const u8, arr: *toml.Array, indent: usize) !void {
    for (arr.items, 0..) |item, i| {
        try printIndent(w, indent);
        try w.print("\x1b[1;33m[[{s} #{d}]]\x1b[0m\n", .{ key, i + 1 });
        try printTable(w, item.table, indent + 1);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const src = try Io.Dir.cwd().readFileAlloc(io, "examples/proteomics.toml", allocator, .limited(std.math.maxInt(usize)));

    var err_info: toml.ErrorInfo = .{};
    const root = toml.parseSlice(allocator, src, &err_info) catch |e| {
        std.debug.print("parse error at line {d}:{d}: {s}\n", .{ err_info.line, err_info.col, err_info.message() });
        return e;
    };
    defer toml.deinit(root, allocator);

    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &stdout_writer.interface;

    try w.writeAll("\x1b[1;35m╔══════════════════════════════════════╗\x1b[0m\n");
    try w.writeAll("\x1b[1;35m║   Proteomics Configuration Report    ║\x1b[0m\n");
    try w.writeAll("\x1b[1;35m╚══════════════════════════════════════╝\x1b[0m\n\n");

    // Walk the root table and group into sections
    // We use the known section order to print a structured report

    // ─── Study Metadata ───
    try w.print("\x1b[1;4;36mSTUDY METADATA\x1b[0m\n", .{});
    try printKey(w, 1, "title");
    try printScalar(w, "32", "\"{s}\"", .{root.get("title").?.string});
    try printKey(w, 1, "study-id");
    try printScalar(w, "32", "\"{s}\"", .{root.get("study-id").?.string});
    try printKey(w, 1, "is_clinical");
    try printScalar(w, "33", "{s}", .{if (root.get("is_clinical").?.boolean) "true" else "false"});
    try printKey(w, 1, "analysis_timestamp");
    try printScalar(w, "34", "2025-04-02T09:15:00+00:00", .{});
    try w.writeAll("\n");

    // ─── Samples ───
    try w.print("\x1b[1;4;36mSAMPLES\x1b[0m\n", .{});
    const samples = root.get("samples").?.table;
    try printKey(w, 1, "total_samples");
    try printScalar(w, "33", "{d}", .{samples.get("total_samples").?.integer});
    try printKey(w, 1, "biological_replicates (hex)");
    try printScalar(w, "33", "{d}", .{samples.get("biological_replicates").?.integer});
    try printKey(w, 1, "well_volume_nl");
    try printScalar(w, "33", "{d}", .{samples.get("well_volume_nl").?.integer});
    try printKey(w, 1, "target_mass_accuracy");
    try printScalar(w, "35", "{d}", .{samples.get("target_mass_accuracy").?.float});
    try w.writeAll("\n");

    // Groups
    const groups = samples.get("groups").?.table;
    const conditions = groups.get("conditions").?.array;
    try w.print("\x1b[1m  Conditions ({d}):\x1b[0m\n", .{conditions.items.len});
    for (conditions.items) |cond| {
        const c = cond.table;
        try printIndent(w, 2);
        try w.print("  \x1b[33m• {s}\x1b[0m ({d}°C, {d}h, {d} samples)\n", .{
            c.get("name").?.string,
            @as(i64, @intFromFloat(c.get("temperature").?.float)),
            c.get("duration_h").?.integer,
            c.get("sample_ids").?.array.items.len,
        });
    }
    try w.writeAll("\n");

    // ─── Instrument ───
    try w.print("\x1b[1;4;36mINSTRUMENT\x1b[0m\n", .{});
    const instrument = root.get("instrument").?.table;
    try printKey(w, 1, "vendor");
    try printScalar(w, "32", "\"{s}\"", .{instrument.get("vendor").?.string});
    try printKey(w, 1, "model");
    try printScalar(w, "32", "\"{s}\"", .{instrument.get("model").?.string});
    const inst_settings = instrument.get("settings").?.table;
    try printKey(w, 1, "resolution");
    try printScalar(w, "33", "{d}", .{inst_settings.get("resolution").?.integer});
    try printKey(w, 1, "acquisition_modes");
    try printScalar(w, "33", "{d} modes", .{inst_settings.get("acquisition_modes").?.array.items.len});
    try w.writeAll("\n");

    // ─── Database ───
    try w.print("\x1b[1;4;36mDATABASE SEARCH\x1b[0m\n", .{});
    const db = root.get("database").?.table;
    try printKey(w, 1, "name");
    try printScalar(w, "32", "\"{s}\"", .{db.get("name").?.string});
    const db_search = db.get("search").?.table;
    try printKey(w, 1, "enzyme");
    try printScalar(w, "32", "\"{s}\"", .{db_search.get("enzyme").?.string});
    try printKey(w, 1, "variable modifications");
    try printScalar(w, "33", "{d}", .{db_search.get("variable_modifications").?.array.items.len});
    const db_scoring = db_search.get("scoring").?.table;
    try printKey(w, 1, "scoring algorithm");
    try printScalar(w, "32", "\"{s}\"", .{db_scoring.get("algorithm").?.string});
    try printKey(w, 1, "FDR threshold");
    try printScalar(w, "35", "{d}", .{db_scoring.get("fdr_threshold").?.float});
    try w.writeAll("\n");

    // ─── Quantification ───
    try w.print("\x1b[1;4;36mQUANTIFICATION\x1b[0m\n", .{});
    const quant = root.get("quantification").?.table;
    try printKey(w, 1, "method");
    try printScalar(w, "32", "\"{s}\"", .{quant.get("method").?.string});
    const q_channels = quant.get("channels").?.table;
    try printKey(w, 1, "channels");
    try printScalar(w, "33", "{d}", .{q_channels.count()});
    try w.writeAll("\n");

    // ─── Identification ───
    try w.print("\x1b[1;4;36mIDENTIFICATION\x1b[0m\n", .{});
    const ident = root.get("identification").?.table;
    try printKey(w, 1, "pipeline");
    try printScalar(w, "32", "\"{s}\"", .{ident.get("pipeline").?.string});
    try printKey(w, 1, "search engines");
    try printScalar(w, "33", "{d}", .{ident.get("search_engines").?.array.items.len});
    try w.writeAll("\n");

    // ─── Quality Control ───
    try w.print("\x1b[1;4;36mQUALITY CONTROL\x1b[0m\n", .{});
    const qc = root.get("quality_control").?.table;
    const qc_checks = qc.get("checks").?.array;
    try printKey(w, 1, "checks");
    try printScalar(w, "33", "{d} configured", .{qc_checks.items.len});
    for (qc_checks.items) |check| {
        const ch = check.table;
        const sev = ch.get("severity").?.string;
        const color: []const u8 = if (std.mem.eql(u8, sev, "error")) "31" else if (std.mem.eql(u8, sev, "warning")) "33" else "32";
        try printIndent(w, 2);
        try w.print("  • {s} \x1b[1;{s}m[{s}]\x1b[0m\n", .{ ch.get("name").?.string, color, sev });
    }
    try w.writeAll("\n");

    // ─── Computing ───
    try w.print("\x1b[1;4;36mCOMPUTING\x1b[0m\n", .{});
    const comp = root.get("computing").?.table;
    try printKey(w, 1, "max_memory_mb");
    try printScalar(w, "33", "{d}", .{comp.get("max_memory_mb").?.integer});
    try printKey(w, 1, "threads");
    try printScalar(w, "33", "{d}", .{comp.get("threads").?.integer});
    const cluster = comp.get("cluster").?.table;
    const jobs = cluster.get("jobs").?.array;
    try printKey(w, 1, "cluster jobs");
    try printScalar(w, "33", "{d}", .{jobs.items.len});
    for (jobs.items) |job| {
        const j = job.table;
        try printIndent(w, 2);
        try w.print("  • \x1b[33m{s}\x1b[0m ({d} CPUs, {d} GB, {s})\n", .{
            j.get("name").?.string,
            j.get("cpus").?.integer,
            j.get("memory_gb").?.integer,
            j.get("walltime").?.string,
        });
    }
    try w.writeAll("\n");

    // ─── Pipeline ───
    try w.print("\x1b[1;4;36mPIPELINE\x1b[0m\n", .{});
    const pipeline = root.get("pipeline").?.array;
    try printKey(w, 1, "steps");
    try printScalar(w, "33", "{d}", .{pipeline.items.len});
    for (pipeline.items) |step| {
        const s = step.table;
        try printIndent(w, 2);
        try w.print("  \x1b[33mStep {d}: {s}\x1b[0m → {s}\n", .{
            s.get("step").?.integer,
            s.get("name").?.string,
            s.get("output").?.string,
        });
    }
    try w.writeAll("\n");

    // ─── Differential Expression ───
    try w.print("\x1b[1;4;36mDIFFERENTIAL EXPRESSION\x1b[0m\n", .{});
    const de = root.get("differential_expression").?.table;
    try printKey(w, 1, "tool");
    try printScalar(w, "32", "\"{s}\"", .{de.get("tool").?.string});
    const de_comparisons = de.get("comparisons").?.table;
    const pairs = de_comparisons.get("pairs").?.array;
    try printKey(w, 1, "pairwise comparisons");
    try printScalar(w, "33", "{d}", .{pairs.items.len});
    for (pairs.items) |pair| {
        const p = pair.table;
        try printIndent(w, 2);
        try w.print("  • \x1b[33m{s}\x1b[0m ({s} vs {s})\n", .{
            p.get("name").?.string,
            p.get("condition_a").?.string,
            p.get("condition_b").?.string,
        });
    }
    try w.writeAll("\n");

    // ─── Enrichment ───
    try w.print("\x1b[1;4;36mPATHWAY ENRICHMENT\x1b[0m\n", .{});
    const enrich = root.get("enrichment").?.table;
    try printKey(w, 1, "databases");
    try printScalar(w, "33", "{d}", .{enrich.get("databases").?.array.items.len});
    const enrich_params = enrich.get("parameters").?.table;
    try printKey(w, 1, "custom gene sets");
    try printScalar(w, "33", "{d}", .{enrich_params.get("custom_gene_sets").?.array.items.len});
    try w.writeAll("\n");

    // ─── Collaborators ───
    try w.print("\x1b[1;4;36mCOLLABORATORS\x1b[0m\n", .{});
    const collab = root.get("collaborators").?.table;
    try printKey(w, 1, "PI");
    try printScalar(w, "32", "\"{s}\"", .{collab.get("pi").?.string});
    try printKey(w, 1, "analysts");
    try printScalar(w, "33", "{d}", .{collab.get("analysts").?.array.items.len});
    try w.writeAll("\n");

    try w.print("\x1b[1;35mTotal keys in root: {d}\x1b[0m\n", .{root.count()});
    try stdout_writer.flush();
}
