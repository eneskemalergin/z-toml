const std = @import("std");

pub fn readTestFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(std.math.maxInt(usize)));
}
