//! Single-file compile driver for ore.
//!
//! Runs the whole Wolframite frontend-to-backend pipeline on one source file:
//!
//!   lexer -> parser -> resolver -> typechecker -> Tungsten lowering
//!
//! and then emits either textual Tungsten IR or a relocatable object file.
//! This is the same pipeline exercised by the compiler crate's own tests
//! (see `lower.zig:runLower`).

const std = @import("std");
const compiler = @import("compiler");
const api = @import("Tungsten").api;
const ferro = @import("Tungsten").ferro;

const Allocator = std.mem.Allocator;
const lexer_mod = compiler.lexer;
const parser_mod = compiler.parser;
const ast_mod = compiler.ast;
const diag_mod = compiler.diagnostics;
const resolve_mod = compiler.resolve;
const typecheck_mod = compiler.typecheck;
const types_mod = compiler.types;
const lower_mod = compiler.codegen;

/// What to produce once the module has been type-checked and lowered.
pub const EmitMode = enum {
    /// Run the pipeline only; produce no output.
    none,
    /// Textual Tungsten IR.
    ir,
    /// Relocatable object file (ELF64 on Linux, PE/COFF on Windows).
    @"obj",
};

pub const Result = struct {
    ok: bool,
    /// Output text when `ok` and `mode != .none`. Owned by the arena.
    text: ?[]const u8,
    /// All diagnostics produced along the way. May be non-empty even when
    /// `ok` (warnings).
    diagnostics: diag_mod.Diagnostics,
};

/// Compile `source` as a single module. All allocations come from `arena`,
/// which must outlive the returned `text` slice.
pub fn compile(arena: Allocator, source: []const u8, mode: EmitMode, target: ferro.Target) !Result {
    var diagnostics = diag_mod.Diagnostics.init(arena);
    diagnostics.owns_messages = true;

    var lex = lexer_mod.Lexer.init(arena, source);
    const tokens = lex.tokenize() catch |err| {
        const msg = std.fmt.allocPrint(arena, "failed to tokenize: {s}", .{@errorName(err)}) catch return error.OutOfMemory;
        try diagnostics.add(.@"error", .lexer, msg, null);
        return .{ .ok = false, .text = null, .diagnostics = diagnostics };
    };

    var arena_obj = ast_mod.AstArena.init(arena);
    var parser = parser_mod.Parser.init(arena, tokens, source, &arena_obj, &diagnostics);
    const module_node = parser.parseModule();

    var type_pool = types_mod.TypePool.init(arena);
    var resolver = resolve_mod.Resolver.init(arena, &arena_obj, source, &type_pool, &diagnostics, module_node);
    resolver.resolve() catch |err| {
        const msg = std.fmt.allocPrint(arena, "resolution failed: {s}", .{@errorName(err)}) catch return error.OutOfMemory;
        try diagnostics.add(.@"error", .semantic, msg, null);
    };

    var checker = typecheck_mod.TypeChecker.init(arena, &arena_obj, source, &type_pool, &diagnostics, &resolver.scopes, module_node);
    checker.check() catch |err| {
        const msg = std.fmt.allocPrint(arena, "type checking failed: {s}", .{@errorName(err)}) catch return error.OutOfMemory;
        try diagnostics.add(.@"error", .semantic, msg, null);
    };

    if (diagnostics.hasErrors()) {
        return .{ .ok = false, .text = null, .diagnostics = diagnostics };
    }
    if (mode == .none) {
        return .{ .ok = true, .text = null, .diagnostics = diagnostics };
    }

    const ctx = try api.Context.init(arena, target);
    try lower_mod.lowerAll(arena, &arena_obj, source, &type_pool, &diagnostics, &checker, ctx);

    if (diagnostics.hasErrors()) {
        return .{ .ok = false, .text = null, .diagnostics = diagnostics };
    }

    switch (mode) {
        .ir => {
            var buf: std.ArrayList(u8) = .empty;
            var allocating: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
            try ctx.print(&allocating.writer);
            return .{ .ok = true, .text = try allocating.toOwnedSlice(), .diagnostics = diagnostics };
        },
        .@"obj" => {
            const bytes = try ctx.emitObject();
            return .{ .ok = true, .text = bytes, .diagnostics = diagnostics };
        },
        .none => unreachable,
    }
}

/// Result of `compileAnnotated`: the relocatable object bytes produced from
/// a single lowering. Used by `ore build --emit-annotated` (asm output
/// removed from the project).
pub const AnnotatedResult = struct {
    ok: bool,
    /// Relocatable object file bytes (ELF64 on Linux, PE/COFF on Windows).
    obj_bytes: []const u8,
    diagnostics: diag_mod.Diagnostics,
};

/// Like `compile`, but emits only the relocatable object file from a single
/// lowering. Used by `ore build --emit-annotated` (asm output removed).
pub fn compileAnnotated(
    arena: Allocator,
    source: []const u8,
    target: ferro.Target,
) !AnnotatedResult {
    var diagnostics = diag_mod.Diagnostics.init(arena);
    diagnostics.owns_messages = true;

    var lex = lexer_mod.Lexer.init(arena, source);
    const tokens = lex.tokenize() catch |err| {
        const msg = std.fmt.allocPrint(arena, "failed to tokenize: {s}", .{@errorName(err)}) catch return error.OutOfMemory;
        try diagnostics.add(.@"error", .lexer, msg, null);
        return .{ .ok = false, .obj_bytes = "", .diagnostics = diagnostics };
    };

    var arena_obj = ast_mod.AstArena.init(arena);
    var parser = parser_mod.Parser.init(arena, tokens, source, &arena_obj, &diagnostics);
    const module_node = parser.parseModule();

    var type_pool = types_mod.TypePool.init(arena);
    var resolver = resolve_mod.Resolver.init(arena, &arena_obj, source, &type_pool, &diagnostics, module_node);
    resolver.resolve() catch |err| {
        const msg = std.fmt.allocPrint(arena, "resolution failed: {s}", .{@errorName(err)}) catch return error.OutOfMemory;
        try diagnostics.add(.@"error", .semantic, msg, null);
    };

    var checker = typecheck_mod.TypeChecker.init(arena, &arena_obj, source, &type_pool, &diagnostics, &resolver.scopes, module_node);
    checker.check() catch |err| {
        const msg = std.fmt.allocPrint(arena, "type checking failed: {s}", .{@errorName(err)}) catch return error.OutOfMemory;
        try diagnostics.add(.@"error", .semantic, msg, null);
    };

    if (diagnostics.hasErrors()) {
        return .{ .ok = false, .obj_bytes = "", .diagnostics = diagnostics };
    }

    const ctx = try api.Context.init(arena, target);
    try lower_mod.lowerAll(arena, &arena_obj, source, &type_pool, &diagnostics, &checker, ctx);

    if (diagnostics.hasErrors()) {
        return .{ .ok = false, .obj_bytes = "", .diagnostics = diagnostics };
    }

    const obj_bytes = try ctx.emitObject();

    return .{ .ok = true, .obj_bytes = obj_bytes, .diagnostics = diagnostics };
}
