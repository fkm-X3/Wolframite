//! Class and struct memory layouts plus vtable generation.
//!
//! A class instance is heap-allocated (via the `malloc` opcode) and laid out
//! as:
//!
//! ```text
//! [ vtable_ptr: u64 ][ ref_count: i64 ][ field 0 ][ field 1 ] ...
//! ```
//!
//! Every field occupies one 8-byte slot regardless of its declared width,
//! matching the backend's slot-based codegen. A struct is the same shape
//! without the two header slots, and lives on the stack in a single
//! `allocaBytes` region instead of the heap.

const std = @import("std");
const api = @import("Tungsten").api;
const ast = @import("../parser/ast.zig");

const Allocator = std.mem.Allocator;
const NodeIdx = ast.NodeIdx;

pub const vtable_offset: u64 = 0;
pub const ref_count_offset: u64 = 8;
pub const class_header_size: u64 = 16;

pub fn fieldCount(arena: *const ast.AstArena, decl_idx: NodeIdx) u64 {
    const decl = arena.get(decl_idx);
    return switch (decl.*) {
        .struct_decl => |s| @intCast(s.fields.indices.len),
        else => 0,
    };
}

/// Total byte size of a stack-allocated struct.
pub fn structSize(arena: *const ast.AstArena, decl_idx: NodeIdx) u32 {
    return @intCast(8 * fieldCount(arena, decl_idx));
}

/// Total byte size of a heap-allocated class instance.
pub fn classSize(arena: *const ast.AstArena, decl_idx: NodeIdx) u32 {
    return @intCast(class_header_size + 8 * fieldCount(arena, decl_idx));
}

/// Byte offset of a named field inside a struct (stack, no header).
pub fn structFieldOffset(arena: *const ast.AstArena, source: []const u8, decl_idx: NodeIdx, field_name: []const u8) ?u64 {
    return fieldOffsetOf(arena, source, decl_idx, field_name, 0);
}

/// Byte offset of a named field inside a class (heap, after the header).
pub fn classFieldOffset(arena: *const ast.AstArena, source: []const u8, decl_idx: NodeIdx, field_name: []const u8) ?u64 {
    return fieldOffsetOf(arena, source, decl_idx, field_name, class_header_size);
}

fn fieldOffsetOf(arena: *const ast.AstArena, source: []const u8, decl_idx: NodeIdx, field_name: []const u8, base: u64) ?u64 {
    const decl = arena.get(decl_idx);
    const fields: []const NodeIdx = switch (decl.*) {
        .struct_decl => |s| s.fields.indices,
        else => return null,
    };
    for (fields, 0..) |field_idx, i| {
        const field = arena.get(field_idx);
        const name = switch (field.*) {
            .field => |f| f.name,
            else => continue,
        };
        if (std.mem.eql(u8, name.slice(source), field_name)) {
            return base + 8 * @as(u64, @intCast(i));
        }
    }
    return null;
}

/// Emit a vtable global: one entry per virtual method, in `funcs` order.
pub fn generateVtable(gpa: Allocator, ctx: *api.Context, type_name: []const u8, funcs: []const api.FunctionIdx) !api.GlobalIdx {
    const name = try std.fmt.allocPrint(gpa, "vtable_{s}", .{type_name});
    defer gpa.free(name);
    return ctx.addFnArrayGlobal(name, funcs);
}

// ============================================================================
// Enums (tagged unions)
// ============================================================================
//
// An enum value is a pointer to a stack block laid out as:
//
// ```text
// [ tag: i64 ][ payload 0 ][ payload 1 ] ...
// ```
//
// The tag is the variant's index in declaration order. Payload slots are
// 8 bytes each, matching the backend's slot-based codegen. The block is
// sized by the constructing variant's own payload count.

pub const enum_tag_offset: u64 = 0;

pub fn enumPayloadOffset(index: u64) u64 {
    return 8 * (index + 1);
}

pub fn enumSizeFor(payload_count: u64) u32 {
    return @intCast(8 * (payload_count + 1));
}

test "class layout: header plus 8-byte fields" {
    // Layout math is exercised indirectly through lower.zig's integration
    // tests; here we pin the constants.
    try std.testing.expectEqual(@as(u64, 16), class_header_size);
    try std.testing.expectEqual(@as(u64, 0), vtable_offset);
    try std.testing.expectEqual(@as(u64, 8), ref_count_offset);
}
