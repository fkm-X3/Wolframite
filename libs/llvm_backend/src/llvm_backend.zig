//! llvm_backend — Zig bindings for the version-independent LLVM wrapper.
//!
//! This is the Zig-facing surface of the LLVM backend. It wraps the stable
//! C ABI declared in `include/llvm_backend/llvm_backend.h`, so Zig (and
//! Wolframite, once it self-hosts) can talk to LLVM through one seam instead
//! of fighting LLVM's constantly-changing C++ API. Only the C++ in this
//! package changes when we bump LLVM; this module stays put.
//!
//! The C++ is currently a stub (nothing talks to real LLVM yet), so these
//! calls just exercise the plumbing and set the stage for a real codegen.

const std = @import("std");

// --------------------------------------------------------------------------
// Opaque handles. Identical to the C typedefs; we never touch their fields.
// --------------------------------------------------------------------------

pub const Context = opaque {};
pub const Module = opaque {};
pub const Function = opaque {};
pub const BasicBlock = opaque {};
pub const Value = opaque {};
pub const Type = opaque {};

/// Optimization level applied at codegen time (mirrors LLVM's -O{0,1,2,3}).
pub const OptLevel = enum(c_int) {
    none = 0,
    less = 1,
    default = 2,
    aggressive = 3,
};

/// Pass level: how much optimization the pipeline runs.
pub const PassLevel = enum(c_int) {
    none = 0,
    function = 1,
    module = 2,
};

// --------------------------------------------------------------------------
// Context
// --------------------------------------------------------------------------

pub fn contextCreate() ?*Context {
    return lvb_context_create();
}

pub fn contextDestroy(ctx: *Context) void {
    lvb_context_destroy(ctx);
}

pub fn moduleCreate(ctx: *Context, name: [:0]const u8) ?*Module {
    return lvb_module_create(ctx, name.ptr);
}

// --------------------------------------------------------------------------
// Types
// --------------------------------------------------------------------------

pub fn typeVoid(ctx: *Context) *Type { return lvb_type_void(ctx).?; }
pub fn typeI1(ctx: *Context) *Type   { return lvb_type_i1(ctx).?; }
pub fn typeI8(ctx: *Context) *Type   { return lvb_type_i8(ctx).?; }
pub fn typeI32(ctx: *Context) *Type  { return lvb_type_i32(ctx).?; }
pub fn typeI64(ctx: *Context) *Type  { return lvb_type_i64(ctx).?; }
pub fn typeF32(ctx: *Context) *Type  { return lvb_type_f32(ctx).?; }
pub fn typeF64(ctx: *Context) *Type  { return lvb_type_f64(ctx).?; }

// --------------------------------------------------------------------------
// Functions & blocks
// --------------------------------------------------------------------------

pub fn functionAdd(module: *Module, name: [:0]const u8, fn_type: *Type, is_external: bool) ?*Function {
    return lvb_function_add(module, name.ptr, fn_type, @intFromBool(is_external));
}

pub fn blockAppend(function: *Function, name: [:0]const u8) ?*BasicBlock {
    return lvb_block_append(function, name.ptr);
}

pub fn builderSetInsert(ctx: *Context, block: *BasicBlock) void {
    lvb_builder_set_insert(ctx, block);
}

// --------------------------------------------------------------------------
// Constants & instructions
// --------------------------------------------------------------------------

pub fn constInt(ctx: *Context, t: *Type, value: i64) ?*Value {
    return lvb_const_int(ctx, t, value);
}

pub fn constFp(ctx: *Context, t: *Type, value: f64) ?*Value {
    return lvb_const_fp(ctx, t, value);
}

pub fn insnAlloca(ctx: *Context, t: *Type, name: ?[:0]const u8) ?*Value {
    return lvb_insn_alloca(ctx, t, name_ptr(name));
}

pub fn insnAdd(ctx: *Context, lhs: *Value, rhs: *Value) ?*Value {
    return lvb_insn_add(ctx, lhs, rhs);
}

pub fn insnRet(ctx: *Context, value: *Value) void {
    lvb_insn_ret(ctx, value);
}

pub fn insnRetVoid(ctx: *Context) void {
    lvb_insn_ret_void(ctx);
}

// --------------------------------------------------------------------------
// Emission (stubs)
// --------------------------------------------------------------------------

pub fn moduleEmitObject(module: *Module, out_path: [:0]const u8, opt: OptLevel, passes: PassLevel) c_int {
    return lvb_module_emit_object(module, out_path.ptr, @intFromEnum(opt), @intFromEnum(passes));
}

pub fn moduleToString(module: *Module, writer: anytype) !void {
    const n = lvb_module_to_string(module, null, 0);
    var buf = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, n);
    defer buf.deinit();
    const written = lvb_module_to_string(module, buf.items.ptr, buf.capacity);
    try writer.writeAll(buf.items[0..written]);
}

// --------------------------------------------------------------------------
// Errors
// --------------------------------------------------------------------------

pub fn lastError(ctx: *Context) [:0]const u8 {
    return std.mem.span(lvb_last_error(ctx));
}

// --------------------------------------------------------------------------
// Native declarations
// --------------------------------------------------------------------------

extern "c" fn lvb_context_create() ?*Context;
extern "c" fn lvb_context_destroy(ctx: *Context) void;
extern "c" fn lvb_module_create(ctx: *Context, name: [*:0]const u8) ?*Module;

extern "c" fn lvb_type_void(ctx: *Context) ?*Type;
extern "c" fn lvb_type_i1(ctx: *Context) ?*Type;
extern "c" fn lvb_type_i8(ctx: *Context) ?*Type;
extern "c" fn lvb_type_i32(ctx: *Context) ?*Type;
extern "c" fn lvb_type_i64(ctx: *Context) ?*Type;
extern "c" fn lvb_type_f32(ctx: *Context) ?*Type;
extern "c" fn lvb_type_f64(ctx: *Context) ?*Type;

extern "c" fn lvb_function_add(module: *Module, name: [*:0]const u8, fn_type: *Type, is_external: c_int) ?*Function;
extern "c" fn lvb_block_append(function: *Function, name: [*:0]const u8) ?*BasicBlock;
extern "c" fn lvb_builder_set_insert(ctx: *Context, block: *BasicBlock) void;

extern "c" fn lvb_const_int(ctx: *Context, t: *Type, value: c_longlong) ?*Value;
extern "c" fn lvb_const_fp(ctx: *Context, t: *Type, value: f64) ?*Value;
extern "c" fn lvb_insn_alloca(ctx: *Context, t: *Type, name: [*:0]const u8) ?*Value;
extern "c" fn lvb_insn_add(ctx: *Context, lhs: *Value, rhs: *Value) ?*Value;
extern "c" fn lvb_insn_ret(ctx: *Context, value: *Value) void;
extern "c" fn lvb_insn_ret_void(ctx: *Context) void;

extern "c" fn lvb_module_emit_object(module: *Module, out_path: [*:0]const u8, opt: c_int, passes: c_int) c_int;
extern "c" fn lvb_module_to_string(module: *Module, buf: ?[*]u8, buf_len: usize) usize;
extern "c" fn lvb_last_error(ctx: *Context) [*:0]const u8;

fn name_ptr(name: ?[:0]const u8) [*:0]const u8 {
    return if (name) |n| n.ptr else "";
}

test "llvm_backend smoke test" {
    const ctx = contextCreate().?;
    defer contextDestroy(ctx);

    const module = moduleCreate(ctx, "test.module").?;

    const i32_ty = typeI32(ctx);
    const int4 = constInt(ctx, i32_ty, 4).?;
    const int2 = constInt(ctx, i32_ty, 2).?;
    _ = insnAdd(ctx, int4, int2);

    // The stub always "emits" successfully and has no error.
    try std.testing.expectEqual(@as(c_int, 0), moduleEmitObject(module, "out.obj", .default, .module));
    try std.testing.expectEqualStrings("", lastError(ctx));
}
