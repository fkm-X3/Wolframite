//! Link description — a Wolframite source module that describes how Ferro
//! should link a program.
//!
//! A link description is a normal Wolframite module (lexer → parser →
//! resolver → typecheck → lower → Tungsten IR) made of top-level `let`
//! bindings with reserved names:
//!
//!     let target = "windows"
//!     let output = "hello.exe"
//!     let entry = "_main"
//!     let subsystem = "console"
//!     let runtime_lib = "wfr_std.lib"
//!     let input = "hello.o"
//!     let debug = false
//!
//! Required: `target`, `output`, `input`, `runtime_lib`.
//! Optional: `entry` (defaults `_main`), `subsystem` (defaults `console`),
//! `debug` (defaults `false`).
//!
//! The compiler recognizes a module as a link description when all required
//! fields are present as string-literal top-level lets and the module defines
//! no `fn main`. The extracted values are handed to Ferro as `linkObject`
//! arguments via `Tungsten.ferro.linkOptionsFromDescription`
//! (see `libs/backend/src/ferro.zig`).

const std = @import("std");
const ast = @import("parser/ast.zig");
const ferro = @import("Tungsten").ferro;

const Allocator = std.mem.Allocator;
const AstArena = ast.AstArena;
const Node = ast.Node;
const NodeIdx = ast.NodeIdx;
const StringRef = ast.StringRef;

pub const LinkDescriptionError = error{
    /// A required link field was missing or not a string literal.
    MissingField,
    /// The module looks like a normal program (defines `fn main`) and is not
    /// a link description.
    NotALinkDescription,
};

/// Reserved top-level binding names recognized as link-description fields.
const field_target = "target";
const field_output = "output";
const field_entry = "entry";
const field_subsystem = "subsystem";
const field_runtime_lib = "runtime_lib";
const field_input = "input";
const field_debug = "debug";

const required_fields = [_][]const u8{
    field_target,
    field_output,
    field_input,
    field_runtime_lib,
};

/// Strip the surrounding double-quotes from a string-literal lexeme.
/// The lexer guarantees the literal is properly terminated, so this is safe.
fn unquoteStringLiteral(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1..s.len - 1];
    return s;
}

/// Extract a link description from a parsed module AST.
///
/// Returns `NotALinkDescription` when the module is an ordinary program
/// (defines `fn main` or lacks required link fields). On success, all string
/// fields point into `arena`/`source` and are valid for the arena's lifetime.
pub fn extractLinkDescription(
    arena: *AstArena,
    source: []const u8,
    module_node: NodeIdx,
) LinkDescriptionError !ferro.LinkDescription {
    const mod = arena.get(module_node);
    if (mod.* != .module) return error.NotALinkDescription;

    // A link description has no `fn main`.
    for (mod.module.decls.indices) |decl_idx| {
        const decl = arena.get(decl_idx);
        switch (decl.*) {
            .fn_decl => |f| {
                if (std.mem.eql(u8, f.name.slice(source), "main")) {
                    return error.NotALinkDescription;
                }
            },
            else => {},
        }
    }

    var desc = ferro.LinkDescription{
        .target = "",
        .output = "",
        .entry = "_main",
        .subsystem = "console",
        .runtime_lib = "",
        .input = "",
        .debug = false,
    };
    var seen_target = false;
    var seen_output = false;
    var seen_input = false;
    var seen_runtime_lib = false;

    for (mod.module.decls.indices) |decl_idx| {
        const decl = arena.get(decl_idx);
        if (decl.* != .let_stmt) continue;
        const l = decl.let_stmt;
        const name = l.name.slice(source);
        const init = l.init_expr orelse continue;
        const init_node = arena.get(init);

        switch (init_node.*) {
            .string_literal => |s| {
                const value = unquoteStringLiteral(s.slice(source));
                if (std.mem.eql(u8, name, field_target)) {
                    desc.target = value;
                    seen_target = true;
                } else if (std.mem.eql(u8, name, field_output)) {
                    desc.output = value;
                    seen_output = true;
                } else if (std.mem.eql(u8, name, field_input)) {
                    desc.input = value;
                    seen_input = true;
                } else if (std.mem.eql(u8, name, field_runtime_lib)) {
                    desc.runtime_lib = value;
                    seen_runtime_lib = true;
                } else if (std.mem.eql(u8, name, field_entry)) {
                    desc.entry = value;
                } else if (std.mem.eql(u8, name, field_subsystem)) {
                    desc.subsystem = value;
                }
            },
            .bool_literal => |b| {
                if (std.mem.eql(u8, name, field_debug)) {
                    desc.debug = b;
                }
            },
            else => {},
        }
    }

    if (!seen_target or !seen_output or !seen_input or !seen_runtime_lib) {
        return error.MissingField;
    }

    return desc;
}

/// Convert an extracted `LinkDescription` into validated `LinkOptions`, ready
/// to pass to `Tungsten.ferro.linkObject`. This is the "compile Wolframite →
/// feed Ferro" mapping.
pub fn linkDescriptionToOptions(desc: ferro.LinkDescription) ferro.LinkDescriptionError !ferro.LinkOptions {
    return try ferro.linkOptionsFromDescription(desc);
}

// ============================================================================
// Tests
// ============================================================================

const lexer = @import("lexer/lexer.zig");
const parser_mod = @import("parser/parser.zig");
const diagnostics = @import("diagnostics.zig");

/// Parse `source` into a module AST, returning the arena and module node.
fn parseLinkModule(source: []const u8) !struct {
    arena: AstArena,
    module_node: NodeIdx,
} {
    var arena = AstArena.init(std.testing.allocator);
    var diag = diagnostics.Diagnostics.init(std.testing.allocator);
    diag.owns_messages = true;

    var lex = lexer.Lexer.init(std.testing.allocator, source);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(std.testing.allocator, tokens, source, &arena, &diag);
    const module_node = parser.parseModule();
    lex.deinit();
    diag.deinit();
    return .{ .arena = arena, .module_node = module_node };
}

test "extractLinkDescription parses a full link description" {
    const source = "let target = \"windows\"\nlet output = \"hello.exe\"\nlet entry = \"_main\"\nlet subsystem = \"console\"\nlet runtime_lib = \"wfr_std.lib\"\nlet input = \"hello.o\"\n";
    var parsed = try parseLinkModule(source);
    defer parsed.arena.deinit();

    const desc = try extractLinkDescription(&parsed.arena, source, parsed.module_node);
    try std.testing.expectEqualSlices(u8, "windows", desc.target);
    try std.testing.expectEqualSlices(u8, "hello.exe", desc.output);
    try std.testing.expectEqualSlices(u8, "_main", desc.entry);
    try std.testing.expectEqualSlices(u8, "console", desc.subsystem);
    try std.testing.expectEqualSlices(u8, "wfr_std.lib", desc.runtime_lib);
    try std.testing.expectEqualSlices(u8, "hello.o", desc.input);
    try std.testing.expectEqual(false, desc.debug);
}

test "extractLinkDescription defaults entry/subsystem/debug when omitted" {
    const source = "let target = \"linux\"\nlet output = \"hello\"\nlet runtime_lib = \"libwfr_std.a\"\nlet input = \"hello.o\"\n";
    var parsed = try parseLinkModule(source);
    defer parsed.arena.deinit();

    const desc = try extractLinkDescription(&parsed.arena, source, parsed.module_node);
    try std.testing.expectEqualSlices(u8, "linux", desc.target);
    try std.testing.expectEqualSlices(u8, "_main", desc.entry);
    try std.testing.expectEqualSlices(u8, "console", desc.subsystem);
    try std.testing.expectEqual(false, desc.debug);
}

test "extractLinkDescription accepts debug = true" {
    const source = "let target = \"windows\"\nlet output = \"hello.exe\"\nlet runtime_lib = \"wfr_std.lib\"\nlet input = \"hello.o\"\nlet debug = true\n";
    var parsed = try parseLinkModule(source);
    defer parsed.arena.deinit();

    const desc = try extractLinkDescription(&parsed.arena, source, parsed.module_node);
    try std.testing.expectEqual(true, desc.debug);
}

test "extractLinkDescription rejects a module that defines fn main" {
    const source = "fn main() -> i32 {\nreturn 0\n}\n";
    var parsed = try parseLinkModule(source);
    defer parsed.arena.deinit();

    if (extractLinkDescription(&parsed.arena, source, parsed.module_node)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkDescriptionError.NotALinkDescription, err);
    }
}

test "extractLinkDescription rejects a missing required field" {
    const source = "let target = \"windows\"\nlet output = \"hello.exe\"\nlet input = \"hello.o\"\n";
    var parsed = try parseLinkModule(source);
    defer parsed.arena.deinit();

    if (extractLinkDescription(&parsed.arena, source, parsed.module_node)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkDescriptionError.MissingField, err);
    }
}

test "linkDescriptionToOptions maps to validated LinkOptions" {
    const desc = ferro.LinkDescription{
        .target = "windows",
        .output = "hello.exe",
        .entry = "_main",
        .subsystem = "console",
        .runtime_lib = "wfr_std.lib",
        .input = "hello.o",
        .debug = false,
    };
    const opts = try linkDescriptionToOptions(desc);
    try std.testing.expectEqual(.windows_x86_64, opts.target);
    try std.testing.expectEqualStrings("_main", opts.entry_symbol);
    try std.testing.expectEqual(.console, opts.subsystem);
    try std.testing.expectEqual(false, opts.debug);

    const linux_desc = ferro.LinkDescription{
        .target = "linux",
        .output = "hello",
        .entry = "_main",
        .subsystem = "gui",
        .runtime_lib = "libwfr_std.a",
        .input = "hello.o",
        .debug = true,
    };
    const linux_opts = try linkDescriptionToOptions(linux_desc);
    try std.testing.expectEqual(.linux_x86_64, linux_opts.target);
    try std.testing.expectEqual(.gui, linux_opts.subsystem);
    try std.testing.expectEqual(true, linux_opts.debug);
}

test "linkDescriptionToOptions rejects a bad target" {
    const desc = ferro.LinkDescription{
        .target = "osx",
        .output = "hello",
        .entry = "_main",
        .subsystem = "console",
        .runtime_lib = "wfr_std.lib",
        .input = "hello.o",
        .debug = false,
    };
    if (linkDescriptionToOptions(desc)) |_| try std.testing.expect(false) else |err| {
        try std.testing.expectEqual(ferro.LinkDescriptionError.InvalidTarget, err);
    }
}
