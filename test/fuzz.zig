//! In-process fuzz harness for the TOML parser.
//!
//! Generates random byte sequences via PRNG and feeds them to parseSlice,
//! verifying no input causes a crash, panic, or undefined behavior.
//! ParseFailed and OutOfMemory are expected and benign.
//!
//! Usage:  zig build fuzz        # runs the fuzz test with default iterations

const std = @import("std");
const toml = @import("toml");

fn walkValue(value: toml.Value) void {
    switch (value) {
        .table => |t| walkTable(t),
        .array => |a| for (a.items) |item| walkValue(item),
        else => {},
    }
}

fn walkTable(tree: *const toml.Table) void {
    for (tree.keys(), tree.values()) |_, val| {
        walkValue(val);
    }
}

test "fuzz: random byte sequences never crash" {
    const count = 5000;

    const seed: u64 = 0xF0F0_F0F0_F0F0_F0F0;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    for (0..count) |i| {
        // Use testing.allocator with a standalone arena per iteration.
        // The arena owns all parse allocations and releases them at once.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const len = switch (rand.intRangeAtMost(u8, 0, 3)) {
            0 => rand.intRangeAtMost(usize, 1, 64),
            1 => rand.intRangeAtMost(usize, 1, 512),
            2, 3 => rand.intRangeAtMost(usize, 1, 4096),
            else => unreachable,
        };

        const buf = alloc.alloc(u8, len) catch continue;
        for (buf) |*b| {
            b.* = switch (rand.intRangeAtMost(u8, 0, 2)) {
                0 => rand.int(u8),
                1 => ' ' + rand.intRangeAtMost(u8, 0, '~' - ' '),
                else => rand.int(u8),
            };
        }

        if (toml.parseSlice(alloc, buf, null)) |root| {
            walkTable(root);
        } else |err| switch (err) {
            error.ParseFailed => {},
            error.OutOfMemory => {},
        }

        if (i > 0 and i % 1000 == 0) {
            std.debug.print("  fuzz {d}/{d}\n", .{ i, count });
        }
    }

    std.debug.print("  fuzz done: {d} iterations, 0 crashes\n", .{count});
}
