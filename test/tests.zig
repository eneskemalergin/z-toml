//! Test entry point. Imports all test modules so they compile and run.
//! Tests are split into three files: feature tests, corpus tests, and OOM tests.

const _features = @import("features.zig");
const _corpus = @import("corpus.zig");
const _oom = @import("oom.zig");

comptime {
    _ = _features;
    _ = _corpus;
    _ = _oom;
}
