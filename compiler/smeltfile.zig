//! Smeltfile — a Wolframite module describing build commands.
//!
//! A smeltfile is an ordinary Wolframite module: it is lexed, parsed,
//! resolved, and type-checked through the normal frontend here, and `ore
//! smelt` runs it through the full pipeline (lowering → Tungsten codegen →
//! Ferro linking) whenever it executes one of its commands.
//!
//! Two kinds of command:
//!
//! 1. Function commands — any top-level `fn` can be a command:
//!
//!        fn build() -> i32 {
//!            print("smelt: build step")
//!            return 0
//!        }
//!
//!    `ore smelt build` compiles a small wrapper that calls `build` as the
//!    program entry point (see `renderFunctionWrapper`).
//!
//! 2. Declarative tasks — top-level `let`s bound to struct literals:
//!
//!        let build = Task {
//!            .entry = "examples/hello.wfr",
//!            .output = "wfr-bin/hello.exe",
//!            .run = false,
//!        }
//!
//!    `ore smelt build` acts on the named fields: entry/source/input/file,
//!    output/out, target, run, test/test_mode, and command/cmd/shell.
//!
//! Function commands and declarative tasks can be mixed in the same file, as
//! long as their names do not collide.

const std = @import("std");
const ast = @import("parser/ast.zig");
const lexer_mod = @import("lexer/lexer.zig");
const parser_mod = @import("parser/parser.zig");
const diagnostics_mod = @import("diagnostics.zig");
const resolve_mod = @import("semantic/resolve.zig");
const types_mod = @import("semantic/types.zig");
const typecheck_mod = @import("semantic/typecheck.zig");
const string_mod = @import("codegen/string.zig");

const Allocator = std.mem.Allocator;
const AstArena = ast.AstArena;
const NodeIdx = ast.NodeIdx;
const StringRef = ast.StringRef;
const Diagnostics = diagnostics_mod.Diagnostics;
const TypePool = types_mod.TypePool;

pub const SmeltError = error{
    /// The named command exists but is a declarative task, not a function.
    NotAFunction,
    /// No command with that name exists in the smeltfile.
    CommandNotFound,
    /// The walked root is not a module node.
    SourceInvalid,
    OutOfMemory,
};

/// What a command binds: a top-level function or a declarative task.
pub const CommandKind = enum {
    function,
    task,
};

pub const SmeltCommand = struct {
    name: []const u8,
    kind: CommandKind,
    /// Task: source file to build (`entry`, `source`, `input`, or `file`).
    entry: []const u8 = "",
    /// Task: output executable path (`output` or `out`); empty = default.
    output: []const u8 = "",
    /// Task: target triple or platform name (`target`); empty = host.
    target: []const u8 = "",
    /// Task: run the built binary after building (`run`).
    run: bool = false,
    /// Task: build in test mode (`test` or `test_mode`).
    test_mode: bool = false,
    /// Task: run this shell command instead of building (`command`, `cmd`,
    /// or `shell`).
    command: []const u8 = "",
    /// Function only: source range of the name token in the `fn <name>`
    /// declaration. Offsets into the smeltfile source (not owned); used by
    /// `renderFunctionWrapper` to splice the entry-point rename.
    name_ref: StringRef = .{ .start = 0, .end = 0 },
    /// Function only: the declared return type is absent or `void`, so the
    /// generated wrapper calls the function and returns 0 instead of
    /// returning its value.
    returns_void: bool = false,
};

/// Everything `ore smelt` needs to know about a smeltfile.
pub const Smeltfile = struct {
    /// False when the file failed the frontend; `commands` is then empty and
    /// `diagnostics` explains why.
    ok: bool,
    /// Commands in declaration order. Strings are allocated from the
    /// allocator passed to `compileSmeltfile`; release with `freeCommands`
    /// (a no-op with an arena allocator).
    commands: []SmeltCommand = &.{},
    /// All diagnostics from the frontend passes. The caller owns this and
    /// must call `deinit`.
    diagnostics: Diagnostics,
};

/// Task field aliases recognized in declarative task literals.
const entry_aliases = [_][]const u8{ "entry", "source", "input", "file" };
const output_aliases = [_][]const u8{ "output", "out" };
const test_aliases = [_][]const u8{ "test", "test_mode" };
const command_aliases = [_][]const u8{ "command", "cmd", "shell" };

fn isOneOf(name: []const u8, options: []const []const u8) bool {
    for (options) |o| {
        if (std.mem.eql(u8, name, o)) return true;
    }
    return false;
}

/// Extract commands from a parsed module AST, in declaration order.
///
/// Top-level `fn`s become function commands; top-level `let`s bound to
/// struct literals with at least one recognized task field become
/// declarative tasks (other struct literals are not commands). Task string
/// values are unescaped with the same decoder the lowerer uses for string
/// literals, so `.command = "echo \"hi\""` reads back as `echo "hi"`.
///
/// Every string in the result is allocated from `strings` (the AST arena is
/// only read); release with `freeCommands`.
pub fn extractSmeltfile(
    arena: *const AstArena,
    strings: Allocator,
    source: []const u8,
    module_node: NodeIdx,
) SmeltError![]SmeltCommand {
    const mod = arena.get(module_node);
    if (mod.* != .module) return error.SourceInvalid;

    var commands: std.ArrayList(SmeltCommand) = .empty;
    errdefer {
        for (commands.items) |cmd| freeCommandStrings(strings, cmd);
        commands.deinit(strings);
    }

    for (mod.module.decls.indices) |decl_idx| {
        const decl = arena.get(decl_idx);
        switch (decl.*) {
            .fn_decl => |f| {
                try commands.append(strings, .{
                    .name = try strings.dupe(u8, f.name.slice(source)),
                    .kind = .function,
                    .name_ref = f.name,
                    .returns_void = fnReturnsVoid(arena, f.return_type, source),
                });
            },
            .let_stmt => |l| {
                const init_expr = l.init_expr orelse continue;
                const init_node = arena.get(init_expr);
                if (init_node.* != .struct_init) continue;
                if (try extractTask(arena, strings, source, l.name.slice(source), init_node.struct_init)) |cmd| {
                    try commands.append(strings, cmd);
                }
            },
            else => {},
        }
    }

    return commands.toOwnedSlice(strings);
}

/// Read one declarative task out of a struct literal, or null when the
/// literal has no recognized task field (not every top-level struct literal
/// is a task). Later fields win over earlier ones.
fn extractTask(
    arena: *const AstArena,
    strings: Allocator,
    source: []const u8,
    name: []const u8,
    si: anytype,
) SmeltError!?SmeltCommand {
    var cmd = SmeltCommand{ .name = try strings.dupe(u8, name), .kind = .task };
    errdefer freeCommandStrings(strings, cmd);

    var recognized = false;
    for (si.fields.indices) |field_idx| {
        const f_node = arena.get(field_idx);
        if (f_node.* != .struct_init_field) continue;
        const f = f_node.struct_init_field;
        const fname = f.name.slice(source);
        const value_node = arena.get(f.value);
        switch (value_node.*) {
            .string_literal => |s| {
                const decoded = try decodeStringLiteral(strings, s.slice(source));
                if (isOneOf(fname, &entry_aliases)) {
                    cmd.entry = decoded;
                } else if (isOneOf(fname, &output_aliases)) {
                    cmd.output = decoded;
                } else if (std.mem.eql(u8, fname, "target")) {
                    cmd.target = decoded;
                } else if (isOneOf(fname, &command_aliases)) {
                    cmd.command = decoded;
                } else {
                    strings.free(decoded);
                    continue;
                }
                recognized = true;
            },
            .bool_literal => |b| {
                if (std.mem.eql(u8, fname, "run")) {
                    cmd.run = b;
                } else if (isOneOf(fname, &test_aliases)) {
                    cmd.test_mode = b;
                } else {
                    continue;
                }
                recognized = true;
            },
            else => {},
        }
    }

    if (!recognized) {
        freeCommandStrings(strings, cmd);
        return null;
    }
    return cmd;
}

/// Decode a string-literal lexeme (the raw slice including the surrounding
/// quotes) into its value bytes, using the same escape rules as lowering.
fn decodeStringLiteral(strings: Allocator, raw: []const u8) SmeltError![]const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return string_mod.unescape(strings, raw[1 .. raw.len - 1]);
    }
    return strings.dupe(u8, raw);
}

/// Whether a fn declaration's return type is absent or `void`.
fn fnReturnsVoid(arena: *const AstArena, return_type: ?NodeIdx, source: []const u8) bool {
    const rt = return_type orelse return true;
    const node = arena.get(rt);
    if (node.* != .identifier) return false;
    return std.mem.eql(u8, node.identifier.slice(source), "void");
}

/// Find a command by name, or null.
pub fn findCommand(commands: []const SmeltCommand, name: []const u8) ?SmeltCommand {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

/// Free a command list returned by `compileSmeltfile`/`extractSmeltfile`
/// (the slice and every string in it). A no-op with an arena allocator.
pub fn freeCommands(allocator: Allocator, commands: []SmeltCommand) void {
    for (commands) |cmd| freeCommandStrings(allocator, cmd);
    allocator.free(commands);
}

fn freeCommandStrings(allocator: Allocator, cmd: SmeltCommand) void {
    // Absent fields hold zero-length literals; freeing those is a no-op.
    allocator.free(cmd.name);
    allocator.free(cmd.entry);
    allocator.free(cmd.output);
    allocator.free(cmd.target);
    allocator.free(cmd.command);
}

/// Compile a smeltfile through the normal frontend (lexer → parser →
/// resolver → typecheck) and extract its commands.
///
/// All allocations come from `allocator`; on success the caller owns
/// `commands` (see `freeCommands`) and `diagnostics` (see `deinit`). A
/// frontend failure is not an error: it comes back as `ok = false` with the
/// rendering diagnostics.
pub fn compileSmeltfile(allocator: Allocator, source: []const u8) SmeltError!Smeltfile {
    var diag = Diagnostics.init(allocator);
    diag.owns_messages = true;

    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = lex.tokenize() catch |err| {
        const loc = if (lex.error_pos) |off| diagnostics_mod.locationFromOffset(source, off) else null;
        const msg = std.fmt.allocPrint(allocator, "failed to tokenize smeltfile: {s}", .{@errorName(err)}) catch {
            diag.deinit();
            return error.OutOfMemory;
        };
        diag.add(.@"error", .lexer, msg, loc) catch {};
        return .{ .ok = false, .diagnostics = diag };
    };

    var arena_obj = AstArena.init(allocator);
    defer arena_obj.deinit();

    var parser = parser_mod.Parser.init(allocator, tokens, source, &arena_obj, &diag);
    const module_node = parser.parseModule();

    var type_pool = TypePool.init(allocator);
    defer type_pool.deinit();

    var resolver = resolve_mod.Resolver.init(allocator, &arena_obj, source, &type_pool, &diag, module_node);
    defer resolver.deinit();
    resolver.resolve() catch |err| {
        const msg = std.fmt.allocPrint(allocator, "smeltfile resolution failed: {s}", .{@errorName(err)}) catch {
            diag.deinit();
            return error.OutOfMemory;
        };
        diag.add(.@"error", .semantic, msg, null) catch {};
    };

    var checker = typecheck_mod.TypeChecker.init(allocator, &arena_obj, source, &type_pool, &diag, &resolver.scopes, module_node);
    defer checker.deinit();
    checker.check() catch |err| {
        const msg = std.fmt.allocPrint(allocator, "smeltfile type-check failed: {s}", .{@errorName(err)}) catch {
            diag.deinit();
            return error.OutOfMemory;
        };
        diag.add(.@"error", .semantic, msg, null) catch {};
    };

    if (diag.hasErrors()) {
        return .{ .ok = false, .diagnostics = diag };
    }

    const commands = extractSmeltfile(&arena_obj, allocator, source, module_node) catch |err| {
        diag.deinit();
        return err;
    };
    return .{ .ok = true, .commands = commands, .diagnostics = diag };
}

/// Build the wrapper source for dispatching a function command: the smeltfile
/// source with its top-level `main` (if any) renamed to `__smelt_main`, plus a
/// generated
/// `fn main` shim that calls the command function as the program entry
/// point. A `void` (or unannotated) command function is called for effect
/// and the wrapper returns 0; any other return type is returned from the
/// wrapper's `i32` main.
///
/// The result is allocated from `allocator`.
pub fn renderFunctionWrapper(
    allocator: Allocator,
    source: []const u8,
    commands: []const SmeltCommand,
    cmd_name: []const u8,
) SmeltError![]u8 {
    const cmd = findCommand(commands, cmd_name) orelse return error.CommandNotFound;
    if (cmd.kind != .function) return error.NotAFunction;

    // The shim's `fn main` would collide with the smeltfile's own, so splice
    // the original `main` out of the way via its name-token range.
    var body = source;
    var body_owned = false;
    defer if (body_owned) allocator.free(body);
    if (findFunction(commands, "main")) |main_cmd| {
        const at = main_cmd.name_ref.start;
        const end = main_cmd.name_ref.end;
        if (at <= end and end <= source.len and std.mem.eql(u8, source[at..end], "main")) {
            body = std.mem.concat(allocator, u8, &.{ source[0..at], "__smelt_main", source[end..] }) catch return error.OutOfMemory;
            body_owned = true;
        }
    }

    // Dispatching `main` itself calls the renamed original.
    const callee = if (std.mem.eql(u8, cmd.name, "main")) "__smelt_main" else cmd.name;

    const shim = if (cmd.returns_void)
        std.fmt.allocPrint(allocator, "\n\nfn main() -> i32 {{\n    {s}()\n    return 0\n}}\n", .{callee})
    else
        std.fmt.allocPrint(allocator, "\n\nfn main() -> i32 {{\n    return {s}()\n}}\n", .{callee});
    const shim_text = shim catch return error.OutOfMemory;
    defer allocator.free(shim_text);

    return std.mem.concat(allocator, u8, &.{ body, shim_text }) catch return error.OutOfMemory;
}

fn findFunction(commands: []const SmeltCommand, name: []const u8) ?SmeltCommand {
    for (commands) |cmd| {
        if (cmd.kind == .function and std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Parse `source` into a module AST without the semantic passes, for
/// extraction tests.
fn parseForTest(source: []const u8) !struct { arena: AstArena, module_node: NodeIdx } {
    var arena = AstArena.init(testing.allocator);
    errdefer arena.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var lex = lexer_mod.Lexer.init(testing.allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(testing.allocator, tokens, source, &arena, &diag);
    const module_node = parser.parseModule();
    return .{ .arena = arena, .module_node = module_node };
}

test "extractSmeltfile finds function commands and tasks" {
    const source =
        \\struct Task {
        \\    entry: String,
        \\    output: String,
        \\    run: bool,
        \\    command: String,
        \\}
        \\
        \\let build = Task {
        \\    .entry = "examples/hello.wfr",
        \\    .output = "wfr-bin/hello.exe",
        \\    .run = false,
        \\}
        \\
        \\fn check() -> i32 {
        \\    return 0
        \\}
        \\
        \\fn main() -> i32 {
        \\    return 0
        \\}
        \\
    ;
    var parsed = try parseForTest(source);
    defer parsed.arena.deinit();

    const cmds = try extractSmeltfile(&parsed.arena, testing.allocator, source, parsed.module_node);
    defer freeCommands(testing.allocator, cmds);

    try testing.expectEqual(@as(usize, 3), cmds.len);

    try testing.expectEqualStrings("build", cmds[0].name);
    try testing.expectEqual(CommandKind.task, cmds[0].kind);
    try testing.expectEqualStrings("examples/hello.wfr", cmds[0].entry);
    try testing.expectEqualStrings("wfr-bin/hello.exe", cmds[0].output);
    try testing.expectEqual(false, cmds[0].run);
    try testing.expectEqualStrings("", cmds[0].command);

    try testing.expectEqualStrings("check", cmds[1].name);
    try testing.expectEqual(CommandKind.function, cmds[1].kind);
    try testing.expectEqual(false, cmds[1].returns_void);

    try testing.expectEqualStrings("main", cmds[2].name);
    try testing.expectEqual(CommandKind.function, cmds[2].kind);
    // name_ref pins the `main` name token for the wrapper rename.
    try testing.expectEqualStrings("main", cmds[2].name_ref.slice(source));
}

test "task field aliases map to the documented fields" {
    const source =
        \\struct Task {
        \\    source: String,
        \\    input: String,
        \\    file: String,
        \\    out: String,
        \\    cmd: String,
        \\    shell: String,
        \\    test: bool,
        \\    test_mode: bool,
        \\}
        \\
        \\let a = Task { .source = "a.wfr" }
        \\let b = Task { .input = "b.wfr" }
        \\let c = Task { .file = "c.wfr" }
        \\let d = Task { .out = "d.exe" }
        \\let e = Task { .cmd = "e" }
        \\let f = Task { .shell = "f" }
        \\let g = Task { .test = true }
        \\let h = Task { .test_mode = true }
        \\
    ;
    var sf = try compileSmeltfile(testing.allocator, source);
    defer sf.diagnostics.deinit();
    defer freeCommands(testing.allocator, sf.commands);

    try testing.expect(sf.ok);
    try testing.expectEqual(@as(usize, 8), sf.commands.len);
    try testing.expectEqualStrings("a.wfr", sf.commands[0].entry);
    try testing.expectEqualStrings("b.wfr", sf.commands[1].entry);
    try testing.expectEqualStrings("c.wfr", sf.commands[2].entry);
    try testing.expectEqualStrings("d.exe", sf.commands[3].output);
    try testing.expectEqualStrings("e", sf.commands[4].command);
    try testing.expectEqualStrings("f", sf.commands[5].command);
    try testing.expectEqual(true, sf.commands[6].test_mode);
    try testing.expectEqual(true, sf.commands[7].test_mode);
}

test "task string values decode escape sequences" {
    const source =
        \\struct Task {
        \\    command: String,
        \\}
        \\
        \\let t = Task {
        \\    .command = "echo \"hi\"\ttoday",
        \\}
        \\
    ;
    var sf = try compileSmeltfile(testing.allocator, source);
    defer sf.diagnostics.deinit();
    defer freeCommands(testing.allocator, sf.commands);

    try testing.expect(sf.ok);
    try testing.expectEqual(@as(usize, 1), sf.commands.len);
    try testing.expectEqualStrings("echo \"hi\"\ttoday", sf.commands[0].command);
}

test "unrecognized struct literals are not commands" {
    const source =
        \\struct Point {
        \\    x: i32,
        \\    y: i32,
        \\}
        \\
        \\let origin = Point {
        \\    .x = 0,
        \\    .y = 0,
        \\}
        \\
    ;
    var sf = try compileSmeltfile(testing.allocator, source);
    defer sf.diagnostics.deinit();
    defer freeCommands(testing.allocator, sf.commands);

    try testing.expect(sf.ok);
    try testing.expectEqual(@as(usize, 0), sf.commands.len);
}

test "findCommand matches by name" {
    const cmds = [_]SmeltCommand{
        .{ .name = "build", .kind = .task },
        .{ .name = "greet", .kind = .function },
    };
    try testing.expectEqualStrings("greet", findCommand(&cmds, "greet").?.name);
    try testing.expect(findCommand(&cmds, "nope") == null);
}

test "compileSmeltfile reports frontend failures through diagnostics" {
    var sf = try compileSmeltfile(testing.allocator, "fn main( {\n");
    defer sf.diagnostics.deinit();
    defer freeCommands(testing.allocator, sf.commands);

    try testing.expect(!sf.ok);
    try testing.expectEqual(@as(usize, 0), sf.commands.len);
    try testing.expect(sf.diagnostics.hasErrors());
}

test "renderFunctionWrapper renames the smeltfile's main and appends the shim" {
    const source =
        \\fn build() -> i32 {
        \\    return 0
        \\}
        \\
        \\fn main() -> i32 {
        \\    return 1
        \\}
        \\
    ;
    var sf = try compileSmeltfile(testing.allocator, source);
    defer sf.diagnostics.deinit();
    defer freeCommands(testing.allocator, sf.commands);
    try testing.expect(sf.ok);

    const wrapper = try renderFunctionWrapper(testing.allocator, source, sf.commands, "build");
    defer testing.allocator.free(wrapper);

    // The original `main` is renamed out of the way and the shim calls the
    // command function; exactly one `fn main` remains.
    try testing.expect(std.mem.indexOf(u8, wrapper, "fn __smelt_main() -> i32") != null);
    try testing.expect(std.mem.indexOf(u8, wrapper, "return build()") != null);
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, wrapper, pos, "fn main(")) |at| {
        count += 1;
        pos = at + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "renderFunctionWrapper dispatching main calls the renamed original" {
    const source =
        \\fn main() -> i32 {
        \\    return 0
        \\}
        \\
    ;
    var sf = try compileSmeltfile(testing.allocator, source);
    defer sf.diagnostics.deinit();
    defer freeCommands(testing.allocator, sf.commands);
    try testing.expect(sf.ok);

    const wrapper = try renderFunctionWrapper(testing.allocator, source, sf.commands, "main");
    defer testing.allocator.free(wrapper);
    try testing.expect(std.mem.indexOf(u8, wrapper, "return __smelt_main()") != null);
}

test "renderFunctionWrapper wraps a void function with an i32 main" {
    const source =
        \\fn greet() {
        \\    print("hello")
        \\}
        \\
    ;
    var sf = try compileSmeltfile(testing.allocator, source);
    defer sf.diagnostics.deinit();
    defer freeCommands(testing.allocator, sf.commands);
    try testing.expect(sf.ok);
    try testing.expectEqual(true, sf.commands[0].returns_void);

    const wrapper = try renderFunctionWrapper(testing.allocator, source, sf.commands, "greet");
    defer testing.allocator.free(wrapper);

    const expected = "fn greet() {\n" ++
        "    print(\"hello\")\n" ++
        "}\n" ++
        "\n\nfn main() -> i32 {\n" ++
        "    greet()\n" ++
        "    return 0\n" ++
        "}\n";
    try testing.expectEqualStrings(expected, wrapper);
}

test "renderFunctionWrapper rejects unknown commands and tasks" {
    const source =
        \\struct Task {
        \\    entry: String,
        \\}
        \\
        \\let build = Task { .entry = "hello.wfr" }
        \\
    ;
    var sf = try compileSmeltfile(testing.allocator, source);
    defer sf.diagnostics.deinit();
    defer freeCommands(testing.allocator, sf.commands);
    try testing.expect(sf.ok);

    try testing.expectError(error.CommandNotFound, renderFunctionWrapper(testing.allocator, source, sf.commands, "nope"));
    try testing.expectError(error.NotAFunction, renderFunctionWrapper(testing.allocator, source, sf.commands, "build"));
}
