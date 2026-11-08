//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const ir = @import("ir.zig");
pub const codegen = @import("codegen.zig");
pub const obj_elf = @import("obj_elf.zig");
pub const obj_pe = @import("obj_pe.zig");
pub const api = @import("api.zig");
pub const sim = @import("sim.zig");
pub const check_codegen = @import("check_codegen.zig");
pub const disasm = @import("disasm.zig");
pub const verify_ir = @import("verify_ir.zig");
pub const ferro = @import("ferro.zig");
pub const ferro_types = @import("ferro_types.zig");
pub const ferro_reader = @import("ferro_reader.zig");
pub const ferro_resolver = @import("ferro_resolver.zig");
pub const ferro_reloc = @import("ferro_reloc.zig");
pub const ferro_elf = @import("ferro_elf.zig");
pub const ferro_pe = @import("ferro_pe.zig");

test {
    _ = @import("ir.zig");
    _ = @import("codegen.zig");
    _ = @import("obj_elf.zig");
    _ = @import("obj_pe.zig");
    _ = @import("api.zig");
    _ = @import("closure_tests.zig");
    _ = @import("check_codegen.zig");
    _ = @import("disasm.zig");
    _ = @import("ferro.zig");
    _ = @import("ferro_types.zig");
    _ = @import("ferro_reader.zig");
    _ = @import("ferro_resolver.zig");
    _ = @import("ferro_reloc.zig");
    _ = @import("ferro_elf.zig");
    _ = @import("ferro_pe.zig");
}
