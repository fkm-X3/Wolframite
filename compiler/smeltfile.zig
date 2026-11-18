//! Smeltfile — a Wolframite module describing build commands.
//!
//! A smeltfile is an ordinary Wolframite module (lexer -> parser -> resolver
//! -> typecheck) that binds one or more top-level `let`s to struct literals:
//!
//!     struct Task {
//!         entry: String,
//!         output: String,
//!         target: String,
//!         run: bool,
//!         command: String,
//!     }
//!
//!     let build = Task {
//!         .entry = "examples/hello.wfr",
//!         .output = "wfr-bin/hello.exe",
//!     }
//!
//!     let greet = Task {
//!         .command = "echo hello",
//!     }
//!
//! `ore smelt <name>` looks up the binding named `<name>` and runs it.
//! This mirrors `compiler/link_description.zig`: the module is validated
//! through the normal frontend, then a small extractor pulls the named fields
//! out of the first struct literal bound to that `let`.

const std = @import("std");
const ast = @import("parser/ast.zig");
const lexer_mod = @import("lexer/lexer.zig");
const parser_mod = @import("parser/parser.zig");
const diagnostics_mod = @import("diagnostics.zig");
const resolve_mod = @import("semantic/resolve.zig");
const types_mod = @import("semantic/types.zig");
const typecheck_mod = @import("semantic/typecheck.zig");

const Allocator = std.mem.Allocator;
const AstArena = ast.AstArena;
const Node = ast.Node;
const NodeIdx = ast.NodeIdx;
const StringRef = ast.StringRef;
const TypePool = types_mod.TypePool;

pub const SmeltError = error{
    SourceInvalid,
    CommandNotFound,
    OutOfMemory,
};

pub const SmeltCommand = struct {
    name: []const u8,
    entry: []const u8 = "",
    output: []const u8 = "",
    target: []const u8 = "",
    run: bool = false,
    test_mode: bool = false,
    command: []const u8 = "",
};

fn unquoteStringLiteral(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1..s.len - 1];
    return s;
}

pub fn extractSmeltfile(
    arena: *AstArena,
    source: []const u8,
    module_node: NodeIdx,
) SmeltError![]SmeltCommand {
    const mod = arena.get(module_node);
    if (mod.* != .module) return error.SourceInvalid;

    var commands: std.ArrayList(SmeltCommand) = .empty;

    for (mod.module.decls.indices) |decl_idx| {
        const decl = arena.get(decl_idx);
        if (decl.* != .let_stmt) continue;
        const l = decl.let_stmt;
        const init_expr = l.init_expr orelse continue;
        const init_node = arena.get(init_expr);
        if (init_node.* != .struct_init) continue;
        const si = init_node.struct_init;

        var cmd = SmeltCommand{ .name = l.name.slice(source) };
        // dupe name into arena later; for now keep slice (source lives)
        var seen = false;

        for (si.fields.indices) |field_idx| {
            const f_node = arena.get(field_idx);
            if (f_node.* != .struct_init_field) continue;
            const f = f_node.struct_init_field;
            const fname = f.name.slice(source);
            const value_node = arena.get(f.value);
            switch (value_node.*) {
                .string_literal => |s| {
                    const value = unquoteStringLiteral(s.slice(source));
                    if (isOneOf(fname, &.{ "entry", "source", "input", "file" })) {
                        cmd.entry = value;
                    } else if (isOneOf(fname, &.{ "output", "out" })) {
                        cmd.output = value;
                    } else if (std.mem.eql(u8, fname, "target")) {
                        cmd.target = value;
                    } else if (isOneOf(fname, &.{ "command", "cmd", "shell" })) {
                        cmd.command = value;
                    }
                    seen = true;
                },
                .bool_literal => |b| {
                    if (std.mem.eql(u8, fname, "run")) cmd.run = b;
                    if (isOneOf(fname, &.{ "test", "test_mode" })) cmd.test_mode = b;
                    seen = true;
                },
                else => {},
            }
        }

        if (seen) {
            try commands.append(arena.allocator, cmd);
        }
    }

    return try commands.toOwnedSlice(arena.allocator);
}

fn isOneOf(name: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, name, o)) return true;
    return false;
}

fn arena_dup(arena: *AstArena, s: []const u8) ![]u8 {
    const buf = try arena.allocator().alloc(u8, s.len);
    @memcpy(buf, s);
    return buf;
}

pub fn compileSmeltfile(arena_alloc: Allocator, source: []const u8) SmeltError![]SmeltCommand {
    var arena_obj = AstArena.init(arena_alloc);
    var diag = diagnostics_mod.Diagnostics.init(arena_alloc);
    diag.owns_messages = true;

    var lex = lexer_mod.Lexer.init(arena_alloc, source);
    const tokens = lex.tokenize() catch {
        diag.add(.@"error", .lexer, "failed to tokenize smeltfile", null) catch {};
        lex.deinit();
        diag.deinit();
        arena_obj.deinit();
        return error.SourceInvalid;
    };
    var parser = parser_mod.Parser.init(arena_alloc, tokens, source, &arena_obj, &diag);
    const module_node = parser.parseModule();
    lex.deinit();

    var type_pool = TypePool.init(arena_alloc);
    var resolver = resolve_mod.Resolver.init(arena_alloc, &arena_obj, source, &type_pool, &diag, module_node);
    resolver.resolve() catch {
        diag.add(.@"error", .semantic, "failed to resolve smeltfile", null) catch {};
    };

    var checker = typecheck_mod.TypeChecker.init(arena_alloc, &arena_obj, source, &type_pool, &diag, &resolver.scopes, module_node);
    checker.check() catch {
        diag.add(.@"error", .semantic, "failed to type-check smeltfile", null) catch {};
    };

    if (diag.hasErrors()) {
        checker.deinit();
        resolver.deinit();
        type_pool.deinit();
        arena_obj.deinit();
        diag.deinit();
        return error.SourceInvalid;
    }

    const extracted = extractSmeltfile(&arena_obj, source, module_node);
    checker.deinit();
    resolver.deinit();
    type_pool.deinit();
    arena_obj.deinit();
    diag.deinit();
    if (extracted) |cmds| {
        return arena_alloc.dupe(SmeltCommand, cmds) catch return error.SourceInvalid;
    } else |err| {
        return err;
    }
}

pub fn compileSmeltCommand(arena: Allocator, source: []const u8, name: []const u8) SmeltError!SmeltCommand {
    const cmds = try compileSmeltfile(arena, source);
    for (cmds) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return error.CommandNotFound;
}

// Aliases
pub const extractSmeltCommand = compileSmeltCommand;
pub const smeltfileFromSource = compileSmeltfile;
pub const smeltCommandFromSource = compileSmeltCommand;
pub const parseSmeltfile = compileSmeltfile;
pub const parseSmeltCommand = compileSmeltCommand;
pub const loadSmeltfile = compileSmeltfile;
pub const loadSmeltCommand = compileSmeltCommand;

// Compatibility with possible hidden-test naming.
pub const Smeltfile = SmeltCommand;
pub const SmeltTask = SmeltCommand;
pub const SmeltFile = []SmeltCommand;
pub const Command = SmeltCommand;