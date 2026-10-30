//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const ir = @import("ir.zig");
pub const codegen = @import("codegen.zig");
pub const api = @import("api.zig");
pub const ferro = @import("ferro.zig");

test {
    _ = @import("ir.zig");
    _ = @import("codegen.zig");
    _ = @import("api.zig");
    _ = @import("closure_tests.zig");
    _ = @import("ferro.zig");
}
