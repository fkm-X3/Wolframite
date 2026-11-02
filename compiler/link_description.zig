//! Link description — a Wolframite source module that describes how Ferro
//! should link a program.
//!
//! A link description is a normal Wolframite module (lexer → parser →
//! resolver → typecheck → lower → Tungsten IR) that binds a single
//! linker-args struct literal to a top-level `let`:
//!
//!     struct LinkerArgs {
//!         target: String,
//!         output: String,
//!         entry: String,
//!         subsystem: String,
//!         runtime_lib: String,
//!         input: String,
//!         debug: bool,
//!     }
//!
//!     let link = LinkerArgs {
//!         .target = "linux",
//!         .output = "hello",
//!         .entry = "_main",
//!         .subsystem = "console",
//!         .runtime_lib = "libwfr_std.a",
//!         .input = "hello.o",
//!         .debug = false,
//!     };
//!
//! Required: `target`, `output`, `input`, `runtime_lib`.
//! Optional: `entry` (defaults `_main`), `subsystem` (defaults `console`),
//! `debug` (defaults `false`).
//!
//! The compiler extracts it via `compiler.link_description.compileLinkDescription`,
//! converts it to `ferro.LinkOptions` with `linkOptionsFromSource`, and feeds
//! those options to `Tungsten.ferro.linkObject` (see `libs/backend/src/ferro.zig`).

const std = @import("std");
const ast = @import("parser/ast.zig");
const ferro = @import("Tungsten").ferro;
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

pub const LinkDescriptionError = error{
    /// A required link field was missing or not a string literal.
    MissingField,
    /// The module looks like a normal program (defines `fn main`) and is not
    /// a link description.
    NotALinkDescription,
    /// The link-description source failed to lex, resolve, or type-check.
    SourceInvalid,
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
/// A link description is a module that defines no `fn main` and binds a single
/// struct literal to a top-level `let`:
///
///     struct LinkerArgs {
///         target: String,
///         output: String,
///         entry: String,
///         subsystem: String,
///         runtime_lib: String,
///         input: String,
///         debug: bool,
///     }
///
///     let link = LinkerArgs {
///         .target = "linux",
///         .output = "hello",
///         .entry = "_main",
///         .subsystem = "console",
///         .runtime_lib = "libwfr_std.a",
///         .input = "hello.o",
///         .debug = false,
///     };
///
/// Required fields: `target`, `output`, `input`, `runtime_lib`.
/// Optional: `entry` (defaults "_main"), `subsystem` (defaults "console"),
/// `debug` (defaults `false`).
///
/// Returns `NotALinkDescription` when the module is an ordinary program
/// (defines `fn main`) or does not bind a linker-args struct. On success, all
/// string fields point into `arena`/`source` and are valid for the arena's
/// lifetime.
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

    // Find the top-level `let` whose initializer is the linker-args struct
    // literal and read its named fields.
    for (mod.module.decls.indices) |decl_idx| {
        const decl = arena.get(decl_idx);
        if (decl.* != .let_stmt) continue;
        const l = decl.let_stmt;
        const init_expr = l.init_expr orelse continue;
        const init_node = arena.get(init_expr);
        if (init_node.* != .struct_init) continue;
        const si = init_node.struct_init;

        for (si.fields.indices) |field_idx| {
            const f_node = arena.get(field_idx);
            if (f_node.* != .struct_init_field) continue;
            const f = f_node.struct_init_field;
            const fname = f.name.slice(source);
            const value_node = arena.get(f.value);
            switch (value_node.*) {
                .string_literal => |s| {
                    const value = unquoteStringLiteral(s.slice(source));
                    if (std.mem.eql(u8, fname, field_target)) {
                        desc.target = value;
                        seen_target = true;
                    } else if (std.mem.eql(u8, fname, field_output)) {
                        desc.output = value;
                        seen_output = true;
                    } else if (std.mem.eql(u8, fname, field_input)) {
                        desc.input = value;
                        seen_input = true;
                    } else if (std.mem.eql(u8, fname, field_runtime_lib)) {
                        desc.runtime_lib = value;
                        seen_runtime_lib = true;
                    } else if (std.mem.eql(u8, fname, field_entry)) {
                        desc.entry = value;
                    } else if (std.mem.eql(u8, fname, field_subsystem)) {
                        desc.subsystem = value;
                    }
                },
                .bool_literal => |b| {
                    if (std.mem.eql(u8, fname, field_debug)) {
                        desc.debug = b;
                    }
                },
                else => {},
            }
        }
        break; // only the first linker-args struct is consumed
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

/// Compile a link-description source module through the normal compiler
/// pipeline (lexer → parser → resolver → typecheck) and extract its
/// `ferro.LinkDescription`.
///
/// The returned `LinkDescription` borrows string slices from `source`, so
/// `source` must outlive it. All intermediate arena state is freed before
/// returning.
pub fn compileLinkDescription(
    arena: Allocator,
    source: []const u8,
) LinkDescriptionError !ferro.LinkDescription {
    var arena_obj = ast.AstArena.init(arena);
    var diag = diagnostics_mod.Diagnostics.init(arena);
    diag.owns_messages = true;

    var lex = lexer_mod.Lexer.init(arena, source);
    const tokens = lex.tokenize() catch {
        diag.add(.@"error", .lexer, "failed to tokenize link description", null) catch {};
        return error.SourceInvalid;
    };
    var parser = parser_mod.Parser.init(arena, tokens, source, &arena_obj, &diag);
    const module_node = parser.parseModule();
    lex.deinit();

    var type_pool = TypePool.init(arena);
    var resolver = resolve_mod.Resolver.init(arena, &arena_obj, source, &type_pool, &diag, module_node);
    resolver.resolve() catch {
        diag.add(.@"error", .semantic, "failed to resolve link description", null) catch {};
        return error.SourceInvalid;
    };

    var checker = typecheck_mod.TypeChecker.init(arena, &arena_obj, source, &type_pool, &diag, &resolver.scopes, module_node);
    checker.check() catch {
        diag.add(.@"error", .semantic, "failed to type-check link description", null) catch {};
        return error.SourceInvalid;
    };

    if (diag.hasErrors()) {
        checker.deinit();
        resolver.deinit();
        type_pool.deinit();
        arena_obj.deinit();
        diag.deinit();
        return error.SourceInvalid;
    }
    const desc_result = extractLinkDescription(&arena_obj, source, module_node);
    checker.deinit();
    resolver.deinit();
    type_pool.deinit();
    arena_obj.deinit();
    diag.deinit();
    return desc_result;
}

/// Compile a link-description source module and convert it to validated
/// `ferro.LinkOptions`, ready to pass to `ferro.linkObject`.
pub fn linkOptionsFromSource(
    arena: Allocator,
    source: []const u8,
) !ferro.LinkOptions {
    const desc = try compileLinkDescription(arena, source);
    return try linkDescriptionToOptions(desc);
}

// ============================================================================
// Tests
// ============================================================================

const lexer = @import("lexer/lexer.zig");
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
    const source = "struct LinkerArgs {\n    target: String,\n    output: String,\n    entry: String,\n    subsystem: String,\n    runtime_lib: String,\n    input: String,\n    debug: bool,\n}\n\nlet link = LinkerArgs {\n    .target = \"windows\",\n    .output = \"hello.exe\",\n    .entry = \"_main\",\n    .subsystem = \"console\",\n    .runtime_lib = \"wfr_std.lib\",\n    .input = \"hello.o\",\n    .debug = false,\n};\n";
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
    const source = "struct LinkerArgs {\n    target: String,\n    output: String,\n    entry: String,\n    subsystem: String,\n    runtime_lib: String,\n    input: String,\n    debug: bool,\n}\n\nlet link = LinkerArgs {\n    .target = \"linux\",\n    .output = \"hello\",\n    .runtime_lib = \"libwfr_std.a\",\n    .input = \"hello.o\",\n};\n";
    var parsed = try parseLinkModule(source);
    defer parsed.arena.deinit();

    const desc = try extractLinkDescription(&parsed.arena, source, parsed.module_node);
    try std.testing.expectEqualSlices(u8, "linux", desc.target);
    try std.testing.expectEqualSlices(u8, "_main", desc.entry);
    try std.testing.expectEqualSlices(u8, "console", desc.subsystem);
    try std.testing.expectEqual(false, desc.debug);
}

test "extractLinkDescription accepts debug = true" {
    const source = "struct LinkerArgs {\n    target: String,\n    output: String,\n    entry: String,\n    subsystem: String,\n    runtime_lib: String,\n    input: String,\n    debug: bool,\n}\n\nlet link = LinkerArgs {\n    .target = \"windows\",\n    .output = \"hello.exe\",\n    .runtime_lib = \"wfr_std.lib\",\n    .input = \"hello.o\",\n    .debug = true,\n};\n";
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
    const source = "struct LinkerArgs {\n    target: String,\n    output: String,\n    entry: String,\n    subsystem: String,\n    runtime_lib: String,\n    input: String,\n    debug: bool,\n}\n\nlet link = LinkerArgs {\n    .target = \"windows\",\n    .output = \"hello.exe\",\n    .input = \"hello.o\",\n};\n";
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

test "compileLinkDescription extracts a LinkDescription from source" {
    const source = "struct LinkerArgs {\n    target: String,\n    output: String,\n    entry: String,\n    subsystem: String,\n    runtime_lib: String,\n    input: String,\n    debug: bool,\n}\n\nlet link = LinkerArgs {\n    .target = \"linux\",\n    .output = \"hello\",\n    .entry = \"_main\",\n    .subsystem = \"console\",\n    .runtime_lib = \"libwfr_std.a\",\n    .input = \"hello.o\",\n    .debug = false,\n};\n";
    const desc = try compileLinkDescription(std.testing.allocator, source);
    try std.testing.expectEqualSlices(u8, "linux", desc.target);
    try std.testing.expectEqualSlices(u8, "hello", desc.output);
    try std.testing.expectEqualSlices(u8, "_main", desc.entry);
    try std.testing.expectEqualSlices(u8, "console", desc.subsystem);
    try std.testing.expectEqualSlices(u8, "libwfr_std.a", desc.runtime_lib);
    try std.testing.expectEqualSlices(u8, "hello.o", desc.input);
    try std.testing.expectEqual(false, desc.debug);
}

test "compileLinkDescription derives LinkOptions fed to Ferro" {
    const source = "struct LinkerArgs {\n    target: String,\n    output: String,\n    entry: String,\n    subsystem: String,\n    runtime_lib: String,\n    input: String,\n    debug: bool,\n}\n\nlet link = LinkerArgs {\n    .target = \"windows\",\n    .output = \"hello.exe\",\n    .entry = \"_main\",\n    .subsystem = \"console\",\n    .runtime_lib = \"wfr_std.lib\",\n    .input = \"hello.o\",\n    .debug = false,\n};\n";
    const opts = try linkOptionsFromSource(std.testing.allocator, source);
    try std.testing.expectEqual(.windows_x86_64, opts.target);
    try std.testing.expectEqualStrings("_main", opts.entry_symbol);
    try std.testing.expectEqual(.console, opts.subsystem);
    try std.testing.expectEqual(false, opts.debug);
}

test "compileLinkDescription rejects a source missing a required field" {
    const source = "struct LinkerArgs {\n    target: String,\n    output: String,\n    entry: String,\n    subsystem: String,\n    runtime_lib: String,\n    input: String,\n    debug: bool,\n}\n\nlet link = LinkerArgs {\n    .target = \"windows\",\n    .output = \"hello.exe\",\n    .input = \"hello.o\",\n};\n";
    if (compileLinkDescription(std.testing.allocator, source)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkDescriptionError.MissingField, err);
    }
}

test "compileLinkDescription rejects a source that defines fn main" {
    const source = "fn main() -> i32 {\nreturn 0\n}\n";
    if (compileLinkDescription(std.testing.allocator, source)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(LinkDescriptionError.NotALinkDescription, err);
    }
}

test "linkOptionsFromSource rejects a source with an invalid target" {
    const source = "struct LinkerArgs {\n    target: String,\n    output: String,\n    entry: String,\n    subsystem: String,\n    runtime_lib: String,\n    input: String,\n    debug: bool,\n}\n\nlet link = LinkerArgs {\n    .target = \"osx\",\n    .output = \"hello\",\n    .runtime_lib = \"libwfr_std.a\",\n    .input = \"hello.o\",\n};\n";
    if (linkOptionsFromSource(std.testing.allocator, source)) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(std.mem.eql(u8, @errorName(err), "InvalidTarget"));
    }
}
