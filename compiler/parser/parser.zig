const std = @import("std");
const Allocator = std.mem.Allocator;
const token_mod = @import("../lexer/token.zig");
const ast = @import("ast.zig");
const diag = @import("../diagnostics.zig");

const TokenTag = token_mod.TokenTag;
const Token = token_mod.Token;
const NodeIdx = ast.NodeIdx;
const NodeList = ast.NodeList;
const Node = ast.Node;
const TypeRepr = ast.TypeRepr;
const StringRef = ast.StringRef;
const BinaryOp = ast.BinaryOp;
const UnaryOp = ast.UnaryOp;

const Precedence = enum(u8) {
    none = 0,
    pipeline,
    range,
    assignment,
    logical_or,
    logical_and,
    bitwise_or,
    bitwise_xor,
    bitwise_and,
    equality,
    comparison,
    shift,
    term,
    factor,
    prefix,
    postfix,

    fn toInt(p: Precedence) u8 {
        return @intFromEnum(p);
    }
};

pub const Parser = struct {
    tokens: []const Token,
    pos: usize,
    source: []const u8,
    arena: *ast.AstArena,
    diagnostics: *diag.Diagnostics,
    allocator: Allocator,
    /// `?` is a postfix operator on expressions and never part of a type
    /// (`docs/syntax.md` §4.13, §4.17). Set while a type reference is parsed so
    /// `x: i32?` is reported instead of silently typing as `i32`.
    in_type_ref: bool = false,

    pub fn init(
        allocator: Allocator,
        tokens: []const Token,
        source: []const u8,
        arena: *ast.AstArena,
        diagnostics: *diag.Diagnostics,
    ) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .source = source,
            .arena = arena,
            .diagnostics = diagnostics,
            .allocator = allocator,
        };
    }

    /// The token stream always ends with an `eof` sentinel, so a position past
    /// the end is an `eof` too: a routine that consumed the sentinel (or the
    /// error recovery that consumed it) must see `eof` again instead of
    /// indexing out of bounds.
    fn peek(self: *const Parser) Token {
        if (self.pos >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.pos];
    }

    fn peekNext(self: *const Parser) Token {
        if (self.pos + 1 < self.tokens.len) {
            return self.tokens[self.pos + 1];
        }
        return self.tokens[self.tokens.len - 1];
    }

    fn advance(self: *Parser) Token {
        const tok = self.peek();
        if (self.pos < self.tokens.len) {
            self.pos += 1;
        }
        return tok;
    }

    fn check(self: *const Parser, tag: TokenTag) bool {
        if (self.pos >= self.tokens.len) return tag == .eof;
        return self.tokens[self.pos].tag == tag;
    }

    fn expect(self: *Parser, tag: TokenTag) ?Token {
        if (self.check(tag)) {
            return self.advance();
        }
        const tok = self.peek();
        self.errorTok(tok, "expected '{s}' but found '{s}'", .{ tag.lexeme(), tok.tag.lexeme() });
        return null;
    }

    fn expectPeek(self: *Parser, tag: TokenTag) ?Token {
        if (self.check(tag)) {
            return self.advance();
        }
        return null;
    }

    /// Accept an identifier or the `_` wildcard as a binding name.
    fn expectName(self: *Parser) ?Token {
        if (self.check(.identifier) or self.check(.underscore)) {
            return self.advance();
        }
        const tok = self.peek();
        self.errorTok(tok, "expected identifier but found '{s}'", .{tok.tag.lexeme()});
        return null;
    }

    fn skipNewlinesAndSemicolons(self: *Parser) void {
        while (self.pos < self.tokens.len) {
            const tok = self.peek();
            if (tok.tag == .newline or tok.tag == .semicolon) {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn makeStringRef(_: *const Parser, tok: Token) StringRef {
        return .{ .start = tok.start, .end = tok.end };
    }

    fn appendNode(self: *Parser, node: Node) NodeIdx {
        return self.arena.append(node) catch |err| {
            std.debug.panic("OOM in parser: {s}", .{@errorName(err)});
        };
    }

    fn errorTok(self: *Parser, _: Token, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch |err| {
            std.debug.panic("OOM in parser error: {s}", .{@errorName(err)});
        };
        self.diagnostics.add(.@"error", .parser, msg, null) catch {};
    }

    fn errorHere(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        self.errorTok(self.peek(), fmt, args);
    }

    fn parseGenericParams(self: *Parser) ?NodeList {
        if (!self.check(.lbracket)) return NodeList{ .indices = &.{} };
        _ = self.advance();
        var params = std.ArrayList(NodeIdx).empty;
        defer params.deinit(self.allocator);

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rbracket)) break;
            if (params.items.len != 0) {
                if (self.expect(.comma) == null) break;
                self.skipNewlinesAndSemicolons();
            }
            const tok = self.expect(.identifier) orelse {
                while (!self.check(.rbracket) and !self.check(.eof)) _ = self.advance();
                break;
            };
            params.append(self.allocator, self.appendNode(.{ .identifier = self.makeStringRef(tok) })) catch unreachable;
            self.skipNewlinesAndSemicolons();
        }
        _ = self.expect(.rbracket);
        return self.arena.allocNodeList(params.items) catch null orelse NodeList{ .indices = &.{} };
    }

    fn parseParamList(self: *Parser) ?NodeList {
        if (self.expect(.lparen) == null) return NodeList{ .indices = &.{} };
        var params = std.ArrayList(NodeIdx).empty;
        defer params.deinit(self.allocator);

        // Parameter annotations are type references (`docs/syntax.md` §4.2).
        const saved_type_ref = self.in_type_ref;
        self.in_type_ref = true;
        defer self.in_type_ref = saved_type_ref;

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rparen)) break;
            if (params.items.len > 0) {
                if (self.expect(.comma) == null) break;
                self.skipNewlinesAndSemicolons();
                if (self.check(.rparen)) break;
            }
            const name_tok = self.expect(.identifier) orelse {
                self.recoverTo(.rparen);
                break;
            };
            _ = self.expect(.colon);
            const ty = self.parseExpr(Precedence.none.toInt()) orelse NodeIdx.none;
            params.append(self.allocator, self.appendNode(.{ .param = .{ .name = self.makeStringRef(name_tok), .ty = ty } })) catch unreachable;
            self.skipNewlinesAndSemicolons();
        }
        _ = self.expect(.rparen);
        return self.arena.allocNodeList(params.items) catch null orelse NodeList{ .indices = &.{} };
    }

    pub fn parseModule(self: *Parser) NodeIdx {
        var decls = std.ArrayList(NodeIdx).empty;
        defer decls.deinit(self.allocator);

        while (!self.check(.eof)) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.eof)) break;

            if (self.parseDecl()) |decl| {
                decls.append(self.allocator, decl) catch unreachable;
            } else {
                _ = self.advance();
            }
            self.skipNewlinesAndSemicolons();
        }

        const list = self.arena.allocNodeList(decls.items) catch NodeList{ .indices = &.{} };
        return self.appendNode(.{ .module = .{ .decls = list } });
    }

    fn parseDecl(self: *Parser) ?NodeIdx {
        const tok = self.peek();
        switch (tok.tag) {
            .fn_kw => {
                _ = self.advance();
                return self.parseFnDecl();
            },
            .comptime_kw => {
                return self.parseComptime();
            },
            .struct_kw => {
                _ = self.advance();
                return self.parseStructDecl();
            },
            .enum_kw => {
                _ = self.advance();
                return self.parseEnumDecl();
            },
            .import_kw => {
                _ = self.advance();
                return self.parseImportDecl();
            },
            .let_kw, .mut_kw => {
                return self.parseLetStmt();
            },
            else => {
                self.errorHere("expected declaration (fn, struct, enum, import, comptime, let, mut)", .{});
                return null;
            },
        }
    }

    fn parseFnDecl(self: *Parser) ?NodeIdx {
        const name_tok = self.expect(.identifier) orelse return null;

        const generic_params = self.parseGenericParams() orelse NodeList{ .indices = &.{} };
        const params = self.parseParamList() orelse return null;

        var return_type: ?NodeIdx = null;
        self.skipNewlinesAndSemicolons();
        if (self.expectPeek(.arrow)) |_| {
            self.skipNewlinesAndSemicolons();
            const saved_type_ref = self.in_type_ref;
            self.in_type_ref = true;
            defer self.in_type_ref = saved_type_ref;
            return_type = self.parseExpr(Precedence.prefix.toInt());
            self.skipNewlinesAndSemicolons();
        }

        self.skipNewlinesAndSemicolons();

        const body: NodeIdx = if (self.check(.lbrace))
            self.parseBlock() orelse return null
        else if (self.check(.eq)) blk: {
            _ = self.advance();
            const expr = self.parseExpr(Precedence.none.toInt()) orelse NodeIdx.none;
            // Wrap the shorthand expression in an implicit `return` so the
            // semantic and lowering passes treat it as a statement.
            break :blk self.appendNode(.{ .return_stmt = .{ .value = expr } });
        } else {
            self.errorHere("expected '{{' or '=' for function body", .{});
            return null;
        };

        return self.appendNode(.{ .fn_decl = .{
            .name = self.makeStringRef(name_tok),
            .generic_params = generic_params,
            .params = params,
            .return_type = return_type,
            .body = body,
        } });
    }

    fn parseStructDecl(self: *Parser) ?NodeIdx {
        const name_tok = self.expect(.identifier) orelse return null;
        const generic_params = self.parseGenericParams() orelse NodeList{ .indices = &.{} };

        if (self.expect(.lbrace) == null) return null;

        var fields = std.ArrayList(NodeIdx).empty;
        defer fields.deinit(self.allocator);

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rbrace)) break;

            if (self.check(.fn_kw)) {
                self.errorHere("structs hold data only; declare a free function over the type instead", .{});
                self.recoverTo(.rbrace);
                break;
            }

            const field = self.parseField() orelse {
                self.recoverTo(.rbrace);
                break;
            };
            fields.append(self.allocator, field) catch unreachable;
        }

        _ = self.expect(.rbrace);
        return self.appendNode(.{ .struct_decl = .{
            .name = self.makeStringRef(name_tok),
            .generic_params = generic_params,
            .fields = self.arena.allocNodeList(fields.items) catch NodeList{ .indices = &.{} },
        } });
    }

    fn parseEnumDecl(self: *Parser) ?NodeIdx {
        const name_tok = self.expect(.identifier) orelse return null;
        const generic_params = self.parseGenericParams() orelse NodeList{ .indices = &.{} };

        if (self.expect(.lbrace) == null) return null;

        var variants = std.ArrayList(NodeIdx).empty;
        defer variants.deinit(self.allocator);

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rbrace)) break;

            const var_name = self.expect(.identifier) orelse {
                self.recoverTo(.rbrace);
                break;
            };

            var variant_fields = std.ArrayList(NodeIdx).empty;
            defer variant_fields.deinit(self.allocator);

            if (self.check(.lparen)) {
                _ = self.advance();
                while (true) {
                    self.skipNewlinesAndSemicolons();
                    if (self.check(.rparen)) break;
                    if (variant_fields.items.len > 0) {
                        if (self.expect(.comma) == null) break;
                        self.skipNewlinesAndSemicolons();
                        if (self.check(.rparen)) break;
                    }
                    const fld = self.parseExpr(Precedence.none.toInt()) orelse break;
                    variant_fields.append(self.allocator, fld) catch unreachable;
                    self.skipNewlinesAndSemicolons();
                }
                _ = self.expect(.rparen);
            }

            const field_list = self.arena.allocNodeList(variant_fields.items) catch NodeList{ .indices = &.{} };
            variants.append(self.allocator, self.appendNode(.{ .enum_variant = .{
                .name = self.makeStringRef(var_name),
                .fields = field_list,
            } })) catch unreachable;
        }

        _ = self.expect(.rbrace);
        return self.appendNode(.{ .enum_decl = .{
            .name = self.makeStringRef(name_tok),
            .generic_params = generic_params,
            .variants = self.arena.allocNodeList(variants.items) catch NodeList{ .indices = &.{} },
        } });
    }

    fn parseImportDecl(self: *Parser) ?NodeIdx {
        var path_parts = std.ArrayList(NodeIdx).empty;
        defer path_parts.deinit(self.allocator);

        const first = self.expect(.identifier) orelse return null;
        path_parts.append(self.allocator, self.appendNode(.{ .identifier = self.makeStringRef(first) })) catch unreachable;

        while (self.check(.colon) and self.peekNext().tag == .colon) {
            _ = self.advance();
            _ = self.advance();
            const part = self.expect(.identifier) orelse break;
            path_parts.append(self.allocator, self.appendNode(.{ .identifier = self.makeStringRef(part) })) catch unreachable;
        }

        var alias: ?StringRef = null;
        self.skipNewlinesAndSemicolons();
        if (self.expectPeek(.as_kw)) |_| {
            if (self.expect(.identifier)) |tok| {
                alias = self.makeStringRef(tok);
            }
        }

        return self.appendNode(.{ .import_decl = .{
            .path = self.arena.allocNodeList(path_parts.items) catch NodeList{ .indices = &.{} },
            .alias = alias,
        } });
    }

    /// `fn` '(' <type_list> ')' '->' <type> — a first-class fn type
    /// (`docs/syntax.md` §4.10). The same node serves type position (`x:
    /// fn(i32) -> i32`) and expression position, where it denotes a comptime
    /// type value rather than a runtime function (`docs/semantics.md` R4b).
    fn parseFnType(self: *Parser) ?NodeIdx {
        _ = self.expect(.fn_kw) orelse return null;
        if (self.expect(.lparen) == null) return null;

        var params = std.ArrayList(NodeIdx).empty;
        defer params.deinit(self.allocator);

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rparen)) break;
            if (params.items.len > 0) {
                if (self.expect(.comma) == null) break;
                self.skipNewlinesAndSemicolons();
                if (self.check(.rparen)) break;
            }
            const param_ty = self.parseExpr(Precedence.prefix.toInt()) orelse {
                self.recoverTo(.rparen);
                break;
            };
            params.append(self.allocator, param_ty) catch unreachable;
            self.skipNewlinesAndSemicolons();
        }
        _ = self.expect(.rparen);

        // The return type binds tighter than the `,` that closes an enclosing
        // list, so `fn(A, B) -> R` never swallows the next argument.
        if (self.expect(.arrow) == null) return null;
        const return_type = self.parseExpr(Precedence.prefix.toInt()) orelse return null;

        return self.appendNode(.{ .fn_type = .{
            .params = self.arena.allocNodeList(params.items) catch NodeList{ .indices = &.{} },
            .return_type = return_type,
        } });
    }

    /// `T`, `&T`, `&mut T`, `T[A, B]`, ... A generic application stays a
    /// `generic_app` node inside `plain`/`reference`, so every type position
    /// carries the same node and no type representation is duplicated here.
    fn parseTypeRepr(self: *Parser) ?TypeRepr {
        const saved_type_ref = self.in_type_ref;
        self.in_type_ref = true;
        defer self.in_type_ref = saved_type_ref;

        const expr = self.parseExpr(Precedence.prefix.toInt()) orelse return null;
        const node = self.arena.get(expr);
        if (node.* == .unary_op) {
            switch (node.unary_op.op) {
                .ref => return .{ .reference = node.unary_op.operand },
                .mut_ref => return .{ .mut_reference = node.unary_op.operand },
                else => {},
            }
        }
        return .{ .plain = expr };
    }

    fn parseField(self: *Parser) ?NodeIdx {
        const name_tok = self.expect(.identifier) orelse return null;
        if (self.expect(.colon) == null) return null;
        const ty = self.parseTypeRepr() orelse return null;
        return self.appendNode(.{ .field = .{ .name = self.makeStringRef(name_tok), .ty = ty } });
    }

    fn parseStmt(self: *Parser) ?NodeIdx {
        const tok = self.peek();
        switch (tok.tag) {
            .let_kw, .mut_kw => return self.parseLetStmt(),
            .return_kw => {
                _ = self.advance();
                if (self.check(.newline) or self.check(.semicolon) or self.check(.rbrace) or self.check(.eof)) {
                    return self.appendNode(.{ .return_stmt = .{ .value = null } });
                }
                const value = self.parseExpr(Precedence.none.toInt()) orelse return null;
                return self.appendNode(.{ .return_stmt = .{ .value = value } });
            },
            .if_kw => {
                _ = self.advance();
                return self.parseIfExpr();
            },
            .while_kw => {
                _ = self.advance();
                return self.parseWhileExpr();
            },
            .for_kw => {
                _ = self.advance();
                return self.parseForStmt();
            },
            .defer_kw => {
                _ = self.advance();
                const expr = self.parseExpr(Precedence.none.toInt()) orelse return null;
                return self.appendNode(.{ .defer_stmt = .{ .expr = expr } });
            },
            .lbrace => return self.parseBlock(),
            .match_kw => {
                _ = self.advance();
                return self.parseMatchExpr();
            },
            .identifier => {
                const expr = self.parseExpr(Precedence.none.toInt()) orelse return null;
                return self.appendNode(.{ .expr_stmt = .{ .expr = expr } });
            },
            else => {
                const expr = self.parseExpr(Precedence.none.toInt()) orelse return null;
                return self.appendNode(.{ .expr_stmt = .{ .expr = expr } });
            },
        }
    }

    fn parseLetStmt(self: *Parser) ?NodeIdx {
        const mutable = if (self.check(.mut_kw)) blk: {
            _ = self.advance();
            break :blk true;
        } else blk: {
            if (self.check(.let_kw)) {
                _ = self.advance();
            }
            break :blk false;
        };

        const name_tok = self.expectName() orelse return null;

        var ty: ?NodeIdx = null;
        var init_expr: ?NodeIdx = null;

        self.skipNewlinesAndSemicolons();
        if (self.expectPeek(.colon)) |_| {
            const type_repr = self.parseTypeRepr() orelse return null;
            ty = switch (type_repr) {
                .plain => |n| n,
                .reference => |n| n,
                .mut_reference => |n| n,
            };
            self.skipNewlinesAndSemicolons();
        }
        if (self.expectPeek(.eq)) |_| {
            init_expr = self.parseExpr(Precedence.none.toInt());
        }

        return self.appendNode(.{ .let_stmt = .{
            .mutable = mutable,
            .name = self.makeStringRef(name_tok),
            .ty = ty,
            .init_expr = init_expr,
        } });
    }

    fn parseIfExpr(self: *Parser) ?NodeIdx {
        const cond = self.parseExpr(Precedence.none.toInt()) orelse return null;

        self.skipNewlinesAndSemicolons();
        const then_body = self.parseBlock() orelse {
            if (self.check(.if_kw)) {
                const nested = self.parseIfExpr() orelse return null;
                return self.appendNode(.{ .if_expr = .{ .cond = cond, .then_body = nested, .else_body = null } });
            }
            return null;
        };

        var else_body: ?NodeIdx = null;
        self.skipNewlinesAndSemicolons();
        if (self.expectPeek(.else_kw)) |_| {
            self.skipNewlinesAndSemicolons();
            if (self.check(.if_kw)) {
                else_body = self.parseIfExpr();
            } else if (self.check(.lbrace)) {
                else_body = self.parseBlock();
            } else {
                self.errorHere("expected 'if' or block after 'else'", .{});
            }
        }

        return self.appendNode(.{ .if_expr = .{ .cond = cond, .then_body = then_body, .else_body = else_body } });
    }

    fn parseWhileExpr(self: *Parser) ?NodeIdx {
        const cond = self.parseExpr(Precedence.none.toInt()) orelse return null;
        self.skipNewlinesAndSemicolons();
        const body = self.parseBlock() orelse return null;
        return self.appendNode(.{ .while_expr = .{ .cond = cond, .body = body } });
    }

    fn parseForStmt(self: *Parser) ?NodeIdx {
        const name_tok = self.expect(.identifier) orelse return null;
        if (self.expect(.in_kw) == null) return null;

        const start = self.parseExpr(Precedence.none.toInt()) orelse return null;

        const range_start: NodeIdx = blk: {
            const start_node = self.arena.get(start);
            if (tagOf(start_node) == .range_expr) {
                break :blk start_node.range_expr.start;
            }
            break :blk NodeIdx.none;
        };

        if (range_start != NodeIdx.none) {
            const end = self.arena.get(start).range_expr.end;
            self.skipNewlinesAndSemicolons();
            const body = self.parseBlock() orelse return null;
            return self.appendNode(.{ .for_range = .{
                .var_name = self.makeStringRef(name_tok),
                .start = range_start,
                .end = end,
                .body = body,
            } });
        }

        if (self.check(.dot) and self.peekNext().tag == .dot) {
            _ = self.advance();
            _ = self.advance();
            const end = self.parseExpr(Precedence.none.toInt()) orelse return null;
            self.skipNewlinesAndSemicolons();
            const body = self.parseBlock() orelse return null;
            return self.appendNode(.{ .for_range = .{
                .var_name = self.makeStringRef(name_tok),
                .start = start,
                .end = end,
                .body = body,
            } });
        }

        self.skipNewlinesAndSemicolons();
        const body = self.parseBlock() orelse return null;
        return self.appendNode(.{ .for_each = .{
            .var_name = self.makeStringRef(name_tok),
            .iterable = start,
            .body = body,
        } });
    }

    fn parseMatchExpr(self: *Parser) ?NodeIdx {
        const scrutinee = self.parseExpr(Precedence.none.toInt()) orelse return null;
        if (self.expect(.lbrace) == null) return null;

        var arms = std.ArrayList(NodeIdx).empty;
        defer arms.deinit(self.allocator);

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rbrace)) break;

            if (self.check(.comma)) {
                _ = self.advance();
                continue;
            }

            const pattern = self.parseExpr(Precedence.none.toInt()) orelse {
                self.recoverTo(.rbrace);
                break;
            };
            self.skipNewlinesAndSemicolons();
            var guard: ?NodeIdx = null;
            if (self.expectPeek(.if_kw)) |_| {
                guard = self.parseExpr(Precedence.none.toInt());
                self.skipNewlinesAndSemicolons();
            }
            _ = self.expect(.fat_arrow);
            self.skipNewlinesAndSemicolons();
            const body = self.parseExpr(Precedence.none.toInt()) orelse {
                self.recoverTo(.rbrace);
                break;
            };

            arms.append(self.allocator, self.appendNode(.{ .match_arm = .{ .pattern = pattern, .guard = guard, .body = body } })) catch unreachable;
            self.skipNewlinesAndSemicolons();
            if (self.check(.comma)) {
                _ = self.advance();
            }
        }

        _ = self.expect(.rbrace);
        return self.appendNode(.{ .match_expr = .{
            .scrutinee = scrutinee,
            .arms = self.arena.allocNodeList(arms.items) catch NodeList{ .indices = &.{} },
        } });
    }

    fn parseBlock(self: *Parser) ?NodeIdx {
        if (self.expect(.lbrace) == null) return null;

        var stmts = std.ArrayList(NodeIdx).empty;
        defer stmts.deinit(self.allocator);

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rbrace) or self.check(.eof)) break;

            if (self.parseStmt()) |stmt| {
                stmts.append(self.allocator, stmt) catch unreachable;
            } else {
                self.recoverToNewlineOrBrace();
                continue;
            }
        }

        _ = self.expect(.rbrace);
        return self.appendNode(.{ .block = .{
            .stmts = self.arena.allocNodeList(stmts.items) catch NodeList{ .indices = &.{} },
        } });
    }

    fn parseExpr(self: *Parser, min_prec: u8) ?NodeIdx {
        var left = self.parsePrefix() orelse return null;

        while (true) {
            const tok = self.peek();

            if (tok.tag == .newline or tok.tag == .semicolon or tok.tag == .rbrace or
                tok.tag == .rparen or tok.tag == .rbracket or tok.tag == .comma or
                tok.tag == .eof or tok.tag == .else_kw or tok.tag == .fat_arrow)
            {
                break;
            }

            if (tok.tag == .lbrace) {
                if (self.peekNext().tag == .dot) {
                    _ = self.advance();
                    left = self.parseStructInitBody(left);
                    continue;
                }
                break;
            }

            if (tok.tag == .question) {
                const qprec = Precedence.postfix.toInt();
                if (qprec < min_prec) break;
                if (self.in_type_ref) {
                    self.errorTok(tok, "'?' propagates an error in expression position; it is not part of a type", .{});
                    _ = self.advance();
                    break;
                }
                // `?` binds to its primary (`docs/syntax.md` §8.6), so a second
                // `?` would have nothing left to unwrap.
                if (tagOf(self.arena.get(left)) == .try_propagate) {
                    self.errorTok(tok, "'?' already unwrapped this value", .{});
                    _ = self.advance();
                    break;
                }
                _ = self.advance();
                left = self.appendNode(.{ .try_propagate = left });
                continue;
            }

            const prec = self.infixPrec(tok.tag) orelse break;
            if (prec < min_prec) break;

            if (tok.tag == .dot) {
                const next = self.peekNext();
                if (next.tag == .dot) {
                    if (prec >= min_prec) {
                        _ = self.advance();
                        _ = self.advance();
                        const right = self.parseExpr(prec) orelse return null;
                        left = self.appendNode(.{ .range_expr = .{ .start = left, .end = right } });
                        continue;
                    }
                    break;
                }
            }

            _ = self.advance();
            left = self.parseInfix(left, tok, prec);
        }

        return left;
    }

    fn parsePrefix(self: *Parser) ?NodeIdx {
        const tok = self.peek();

        switch (tok.tag) {
            .int_literal => {
                _ = self.advance();
                const val = std.fmt.parseInt(i64, tok.lexeme(self.source), 0) catch {
                    self.errorTok(tok, "invalid integer literal", .{});
                    return null;
                };
                return self.appendNode(.{ .int_literal = val });
            },
            .float_literal => {
                _ = self.advance();
                const val = std.fmt.parseFloat(f64, tok.lexeme(self.source)) catch {
                    self.errorTok(tok, "invalid float literal", .{});
                    return null;
                };
                return self.appendNode(.{ .float_literal = val });
            },
            .string_literal => {
                _ = self.advance();
                return self.appendNode(.{ .string_literal = self.makeStringRef(tok) });
            },
            .char_literal => {
                _ = self.advance();
                return self.appendNode(.{ .char_literal = self.makeStringRef(tok) });
            },
            .true_kw => {
                _ = self.advance();
                return self.appendNode(.{ .bool_literal = true });
            },
            .false_kw => {
                _ = self.advance();
                return self.appendNode(.{ .bool_literal = false });
            },
            .null_kw => {
                _ = self.advance();
                return self.appendNode(.{ .null_literal = {} });
            },
            .identifier => {
                _ = self.advance();
                return self.appendNode(.{ .identifier = self.makeStringRef(tok) });
            },
            .lparen => {
                _ = self.advance();
                const expr = self.parseExpr(Precedence.none.toInt()) orelse return null;
                _ = self.expect(.rparen);
                return self.appendNode(.{ .paren_expr = expr });
            },
            .lbrace => {
                return self.parseBlock();
            },
            .if_kw => {
                _ = self.advance();
                return self.parseIfExpr();
            },
            .match_kw => {
                _ = self.advance();
                return self.parseMatchExpr();
            },
            .minus => {
                _ = self.advance();
                const operand = self.parseExpr(Precedence.prefix.toInt()) orelse return null;
                return self.appendNode(.{ .unary_op = .{ .op = .neg, .operand = operand } });
            },
            .bang => {
                _ = self.advance();
                const operand = self.parseExpr(Precedence.prefix.toInt()) orelse return null;
                return self.appendNode(.{ .unary_op = .{ .op = .not, .operand = operand } });
            },
            .tilde => {
                _ = self.advance();
                const operand = self.parseExpr(Precedence.prefix.toInt()) orelse return null;
                return self.appendNode(.{ .unary_op = .{ .op = .bit_not, .operand = operand } });
            },
            .underscore => {
                _ = self.advance();
                return self.appendNode(.{ .identifier = self.makeStringRef(tok) });
            },
            .amp => {
                _ = self.advance();
                const operand = self.parseExpr(Precedence.prefix.toInt()) orelse return null;
                return self.appendNode(.{ .unary_op = .{ .op = .ref, .operand = operand } });
            },
            .amp_mut => {
                _ = self.advance();
                const operand = self.parseExpr(Precedence.prefix.toInt()) orelse return null;
                return self.appendNode(.{ .unary_op = .{ .op = .mut_ref, .operand = operand } });
            },
            .plus => {
                _ = self.advance();
                return self.parseExpr(Precedence.prefix.toInt());
            },
            .move_kw => {
                _ = self.advance();
                const operand = self.parseExpr(Precedence.prefix.toInt()) orelse return null;
                return self.appendNode(.{ .move_expr = operand });
            },
            .pipe, .pipe_pipe => return self.parseClosure(),
            .fn_kw => return self.parseFnType(),
            .comptime_kw => return self.parseComptime(),
            .region_kw => return self.parseRegion(),
            .at => return self.parseComptimeCall(),
            else => {
                self.errorTok(tok, "unexpected token in expression: '{s}'", .{tok.tag.lexeme()});
                return null;
            },
        }
    }

    fn parseInfix(self: *Parser, left: NodeIdx, tok: Token, prec: u8) NodeIdx {
        switch (tok.tag) {
            .plus, .minus, .star, .slash, .percent,
            .amp, .pipe, .caret,
            .eq_eq, .bang_eq, .lt, .gt, .lt_eq, .gt_eq,
            .amp_amp, .pipe_pipe,
            .lshift, .rshift,
            .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq,
            => {
                const op = tokenToBinaryOp(tok.tag);
                const next_min = if (isRightAssoc(tok.tag)) prec else prec + 1;
                const right = self.parseExpr(next_min) orelse return left;
                return self.appendNode(.{ .binary_op = .{ .op = op, .left = left, .right = right } });
            },
            .lparen => {
                var args = std.ArrayList(NodeIdx).empty;
                defer args.deinit(self.allocator);

                while (true) {
                    self.skipNewlinesAndSemicolons();
                    if (self.check(.rparen)) break;
                    if (args.items.len > 0) {
                        if (self.expect(.comma) == null) break;
                        self.skipNewlinesAndSemicolons();
                        if (self.check(.rparen)) break;
                    }
                    const arg = self.parseExpr(Precedence.none.toInt()) orelse break;
                    args.append(self.allocator, arg) catch unreachable;
                    self.skipNewlinesAndSemicolons();
                }
                _ = self.expect(.rparen);

                return self.appendNode(.{ .call = .{
                    .func = left,
                    .args = self.arena.allocNodeList(args.items) catch NodeList{ .indices = &.{} },
                } });
            },
            .lbracket => {
                // `T[A, B]` — a generic application — shares this syntax with
                // indexing `xs[0]`. A single argument is an `index_access`; the
                // semantic passes read a type name on the left as a generic
                // application (`Option[i32]`). Two or more arguments can only
                // be a generic application, so they get their own node.
                var args = std.ArrayList(NodeIdx).empty;
                defer args.deinit(self.allocator);

                while (true) {
                    self.skipNewlinesAndSemicolons();
                    if (self.check(.rbracket)) break;
                    if (args.items.len != 0) {
                        if (self.expect(.comma) == null) break;
                        self.skipNewlinesAndSemicolons();
                        if (self.check(.rbracket)) break;
                    }
                    const arg = self.parseExpr(Precedence.none.toInt()) orelse {
                        self.recoverTo(.rbracket);
                        break;
                    };
                    args.append(self.allocator, arg) catch unreachable;
                    self.skipNewlinesAndSemicolons();
                }
                _ = self.expect(.rbracket);

                if (args.items.len == 0) {
                    self.errorHere("expected an index or type argument inside '[]'", .{});
                    return left;
                }
                if (args.items.len == 1) {
                    return self.appendNode(.{ .index_access = .{ .object = left, .index = args.items[0] } });
                }
                return self.appendNode(.{ .generic_app = .{
                    .base = left,
                    .args = self.arena.allocNodeList(args.items) catch NodeList{ .indices = &.{} },
                } });
            },
            .dot => {
                const field_tok = self.expect(.identifier) orelse return left;
                return self.appendNode(.{ .field_access = .{ .object = left, .field = self.makeStringRef(field_tok) } });
            },
            .pipeline => {
                // Left-associative (`docs/syntax.md` §4.8): `a |> f |> g`
                // nests as `(a |> f) |> g`, so `prec + 1` keeps the next `|>`
                // out of this right-hand side.
                const right = self.parseExpr(prec + 1) orelse return left;
                return self.appendNode(.{ .pipeline = .{ .lhs = left, .rhs = right } });
            },
            else => {
                return left;
            },
        }
    }

    fn parseClosure(self: *Parser) ?NodeIdx {
        var params = std.ArrayList(NodeIdx).empty;
        defer params.deinit(self.allocator);

        if (self.check(.pipe_pipe)) {
            _ = self.advance();
        } else {
            _ = self.expect(.pipe) orelse return null;
            self.skipNewlinesAndSemicolons();
            if (!self.check(.pipe)) {
                while (true) {
                    self.skipNewlinesAndSemicolons();
                    const name_tok = self.expectName() orelse break;
                    var ty: NodeIdx = NodeIdx.none;
                    if (self.expectPeek(.colon)) |_| {
                        // Stop before the closing `|`, which would otherwise be
                        // consumed as the bitwise-or operator.
                        ty = self.parseExpr(Precedence.prefix.toInt()) orelse NodeIdx.none;
                    }
                    params.append(self.allocator, self.appendNode(.{ .param = .{
                        .name = self.makeStringRef(name_tok),
                        .ty = ty,
                    } })) catch unreachable;
                    self.skipNewlinesAndSemicolons();
                    if (self.check(.comma)) {
                        _ = self.advance();
                    } else break;
                }
            }
            _ = self.expect(.pipe);
        }

        const body = if (self.check(.lbrace))
            self.parseBlock() orelse return null
        else
            self.parseExpr(Precedence.none.toInt()) orelse return null;

        return self.appendNode(.{ .closure = .{
            .params = self.arena.allocNodeList(params.items) catch NodeList{ .indices = &.{} },
            .body = body,
            .env = NodeList{ .indices = &.{} },
        } });
    }

    fn parseComptime(self: *Parser) ?NodeIdx {
        _ = self.expect(.comptime_kw) orelse return null;
        if (self.check(.lbrace)) {
            const body = self.parseBlock() orelse return null;
            return self.appendNode(.{ .comptime_block = body });
        }
        const expr = self.parseExpr(Precedence.none.toInt()) orelse return null;
        return self.appendNode(.{ .comptime_expr = expr });
    }

    fn parseRegion(self: *Parser) ?NodeIdx {
        _ = self.expect(.region_kw) orelse return null;
        const name_tok = self.expect(.identifier) orelse return null;

        var allocator_ty: ?NodeIdx = null;
        if (self.expectPeek(.colon)) |_| {
            allocator_ty = self.parseExpr(Precedence.none.toInt());
        }
        self.skipNewlinesAndSemicolons();

        const body = self.parseBlock() orelse return null;
        return self.appendNode(.{ .region_expr = .{
            .name = self.makeStringRef(name_tok),
            .allocator = allocator_ty,
            .body = body,
        } });
    }

    fn parseComptimeCall(self: *Parser) ?NodeIdx {
        _ = self.expect(.at) orelse return null;
        const name_tok = self.expect(.identifier) orelse return null;

        var args = std.ArrayList(NodeIdx).empty;
        defer args.deinit(self.allocator);

        if (self.expectPeek(.lparen)) |_| {
            while (true) {
                self.skipNewlinesAndSemicolons();
                if (self.check(.rparen)) break;
                if (args.items.len > 0) {
                    if (self.expect(.comma) == null) break;
                    self.skipNewlinesAndSemicolons();
                    if (self.check(.rparen)) break;
                }
                const arg = self.parseExpr(Precedence.none.toInt()) orelse break;
                args.append(self.allocator, arg) catch unreachable;
                self.skipNewlinesAndSemicolons();
            }
            _ = self.expect(.rparen);
        }

        return self.appendNode(.{ .comptime_call = .{
            .name = self.makeStringRef(name_tok),
            .args = self.arena.allocNodeList(args.items) catch NodeList{ .indices = &.{} },
        } });
    }

    fn parseStructInitBody(self: *Parser, ty: NodeIdx) NodeIdx {
        var fields = std.ArrayList(NodeIdx).empty;
        defer fields.deinit(self.allocator);

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rbrace)) break;
            if (fields.items.len > 0) {
                if (self.expect(.comma) == null) break;
                self.skipNewlinesAndSemicolons();
                if (self.check(.rbrace)) break;
            }

            if (self.expect(.dot) == null) break;
            const name_tok = self.expect(.identifier) orelse break;
            if (self.expect(.eq) == null) break;
            const value = self.parseExpr(Precedence.none.toInt()) orelse break;

            fields.append(self.allocator, self.appendNode(.{ .struct_init_field = .{
                .name = self.makeStringRef(name_tok),
                .value = value,
            } })) catch unreachable;
            self.skipNewlinesAndSemicolons();
        }

        _ = self.expect(.rbrace);
        return self.appendNode(.{ .struct_init = .{
            .ty = ty,
            .fields = self.arena.allocNodeList(fields.items) catch NodeList{ .indices = &.{} },
        } });
    }

    fn infixPrec(_: *const Parser, tag: TokenTag) ?u8 {
        return switch (tag) {
            .pipeline => Precedence.pipeline.toInt(),
            .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq => Precedence.assignment.toInt(),
            .pipe_pipe => Precedence.logical_or.toInt(),
            .amp_amp => Precedence.logical_and.toInt(),
            .pipe => Precedence.bitwise_or.toInt(),
            .caret => Precedence.bitwise_xor.toInt(),
            .amp => Precedence.bitwise_and.toInt(),
            .eq_eq, .bang_eq => Precedence.equality.toInt(),
            .lt, .gt, .lt_eq, .gt_eq => Precedence.comparison.toInt(),
            .lshift, .rshift => Precedence.shift.toInt(),
            .plus, .minus => Precedence.term.toInt(),
            .star, .slash, .percent => Precedence.factor.toInt(),
            .lparen => Precedence.postfix.toInt(),
            .lbracket => Precedence.postfix.toInt(),
            .dot => Precedence.postfix.toInt(),
            else => null,
        };
    }

    fn recoverTo(self: *Parser, tag: TokenTag) void {
        while (self.pos < self.tokens.len) {
            const tok = self.peek();
            if (tok.tag == tag or tok.tag == .eof) return;
            self.pos += 1;
        }
    }

    fn recoverToNewlineOrBrace(self: *Parser) void {
        while (self.pos < self.tokens.len) {
            const tok = self.peek();
            if (tok.tag == .newline or tok.tag == .rbrace or tok.tag == .semicolon or tok.tag == .eof) return;
            self.pos += 1;
        }
    }
};

fn tokenToBinaryOp(tag: TokenTag) BinaryOp {
    return switch (tag) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        .amp => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .eq_eq => .eq,
        .bang_eq => .ne,
        .lt => .lt,
        .gt => .gt,
        .lt_eq => .le,
        .gt_eq => .ge,
        .amp_amp => .and_op,
        .pipe_pipe => .or_op,
        .lshift => .shift_left,
        .rshift => .shift_right,
        .eq => .assign,
        .plus_eq => .add_assign,
        .minus_eq => .sub_assign,
        .star_eq => .mul_assign,
        .slash_eq => .div_assign,
        else => .add,
    };
}

fn isRightAssoc(tag: TokenTag) bool {
    return switch (tag) {
        .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq => true,
        else => false,
    };
}

const TestResult = struct { arena: ast.AstArena, node: NodeIdx, source: []const u8 };

/// Parses `source` and requires a clean result: tests built on this helper
/// only assert AST shape, so a parser that also emitted a diagnostic (for
/// example a shorthand body it silently skipped) would otherwise still pass.
fn runTest(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    var arena = ast.AstArena.init(allocator);
    errdefer arena.deinit();
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    defer diags.deinit();
    var parser = Parser.init(allocator, tokens, source, &arena, &diags);
    const module = parser.parseModule();
    if (diags.hasErrors()) {
        std.debug.panic("unexpected parse error: {s}", .{diags.items.items[0].message});
    }
    return TestResult{ .arena = arena, .node = module, .source = source };
}

fn expectParseErrors(allocator: std.mem.Allocator, source: []const u8) !void {
    var arena = ast.AstArena.init(allocator);
    defer arena.deinit();
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    defer diags.deinit();
    var parser = Parser.init(allocator, tokens, source, &arena, &diags);
    _ = parser.parseModule();
    try std.testing.expect(diags.hasErrors());
}

/// Rejects `source` and requires one diagnostic to mention `needle`, so a test
/// pins the guidance the user sees rather than just "something went wrong".
fn expectParseErrorContaining(allocator: std.mem.Allocator, source: []const u8, needle: []const u8) !void {
    var arena = ast.AstArena.init(allocator);
    defer arena.deinit();
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    defer diags.deinit();
    var parser = Parser.init(allocator, tokens, source, &arena, &diags);
    _ = parser.parseModule();
    try std.testing.expect(diags.hasErrors());
    for (diags.items.items) |d| {
        if (std.mem.indexOf(u8, d.message, needle) != null) return;
    }
    std.debug.panic("no diagnostic contained '{s}'", .{needle});
}

/// Parses `source` and drops the result, so a test can only assert "this does
/// not crash". Diagnostics are expected and ignored.
fn expectNoCrash(allocator: std.mem.Allocator, source: []const u8) !void {
    var arena = ast.AstArena.init(allocator);
    defer arena.deinit();
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    // A prefix may not lex at all (an unterminated string); this test is about
    // the parser's recovery from whatever did lex.
    const tokens = lex.tokenize() catch return;
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    defer diags.deinit();
    var parser = Parser.init(allocator, tokens, source, &arena, &diags);
    _ = parser.parseModule();
}

fn getMod(res: *const TestResult) *const Node {
    return res.arena.get(res.node);
}

fn tagOf(node: *const Node) std.meta.Tag(Node) {
    return std.meta.activeTag(node.*);
}

fn nameOf(res: *const TestResult, id: ast.StringRef) []const u8 {
    return id.slice(res.source);
}

fn declAt(res: *const TestResult, i: usize) *const Node {
    return res.arena.get(res.arena.get(res.node).module.decls.indices[i]);
}

fn firstInitOfBody(res: *const TestResult) !*const Node {
    const body = res.arena.get(declAt(res, 0).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    return res.arena.get(stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull);
}

/// Value of a shorthand `fn` body: `fn f() = expr` stores the expression as the
/// value of an implicit `return`, not inside a block.
fn shorthandValue(res: *const TestResult, decl_index: usize) !*const Node {
    const body = res.arena.get(declAt(res, decl_index).fn_decl.body);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .return_stmt), tagOf(body));
    return res.arena.get(body.return_stmt.value orelse return error.TestUnexpectedNull);
}

test "parser: empty module" {
    var res = try runTest(std.testing.allocator, "");
    defer res.arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), getMod(&res).module.decls.indices.len);
}

test "parser: simple function" {
    var res = try runTest(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
    );
    defer res.arena.deinit();
    const mod = getMod(&res);
    try std.testing.expectEqual(@as(usize, 1), mod.module.decls.indices.len);
    const decl = res.arena.get(mod.module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .fn_decl), tagOf(decl));
    const body = res.arena.get(decl.fn_decl.body);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .block), tagOf(body));
    try std.testing.expectEqual(@as(usize, 1), body.block.stmts.indices.len);
    const ret = res.arena.get(body.block.stmts.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .return_stmt), tagOf(ret));
}

test "parser: struct declaration" {
    var res = try runTest(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
    );
    defer res.arena.deinit();
    const mod = getMod(&res);
    try std.testing.expectEqual(@as(usize, 1), mod.module.decls.indices.len);
    const decl = res.arena.get(mod.module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .struct_decl), tagOf(decl));
    try std.testing.expectEqual(@as(usize, 2), decl.struct_decl.fields.indices.len);
}

test "parser: enum declaration" {
    var res = try runTest(std.testing.allocator,
        \\enum Option[T] {
        \\    Some(T)
        \\    None
        \\}
    );
    defer res.arena.deinit();
    const mod = getMod(&res);
    const decl = res.arena.get(mod.module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .enum_decl), tagOf(decl));
    try std.testing.expectEqual(@as(usize, 2), decl.enum_decl.variants.indices.len);
}

test "parser: interface declaration is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\interface Speakable {
        \\    fn speak(self: &Self) -> String
        \\}
    );
}

test "parser: if expression" {
    var res = try runTest(std.testing.allocator,
        \\fn test(x: i32) -> i32 {
        \\    if x > 0 {
        \\        return x
        \\    } else {
        \\        return -x
        \\    }
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const if_expr = res.arena.get(body.block.stmts.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .if_expr), tagOf(if_expr));
    try std.testing.expect(if_expr.if_expr.else_body != null);
}

test "parser: for range loop" {
    var res = try runTest(std.testing.allocator,
        \\fn sum() -> i32 {
        \\    mut s: i32 = 0
        \\    for i in 0..10 {
        \\        s = s + i
        \\    }
        \\    return s
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    try std.testing.expectEqual(@as(usize, 3), body.block.stmts.indices.len);
    const for_stmt = res.arena.get(body.block.stmts.indices[1]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .for_range), tagOf(for_stmt));
}

test "parser: match expression" {
    var res = try runTest(std.testing.allocator,
        \\fn check(x: i32) -> i32 {
        \\    match x {
        \\        1 => 10,
        \\        2 => 20,
        \\    }
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const match = res.arena.get(body.block.stmts.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .match_expr), tagOf(match));
    try std.testing.expectEqual(@as(usize, 2), match.match_expr.arms.indices.len);
}

test "parser: import declaration" {
    var res = try runTest(std.testing.allocator, "import math");
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .import_decl), tagOf(decl));
    try std.testing.expectEqual(@as(usize, 1), decl.import_decl.path.indices.len);
}

test "parser: import with alias" {
    var res = try runTest(std.testing.allocator, "import utils as u");
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .import_decl), tagOf(decl));
    try std.testing.expect(decl.import_decl.alias != null);
}

test "parser: struct with methods is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\
        \\    fn add(self: &Vec2, other: &Vec2) -> Vec2 {
        \\        return Vec2{ .x = self.x + other.x, .y = self.y + other.y }
        \\    }
        \\}
    );
}

test "parser: let with type annotation" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let x: i32 = 42
        \\    mut y: f64 = 3.14
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    try std.testing.expectEqual(@as(usize, 2), body.block.stmts.indices.len);
    const let1 = res.arena.get(body.block.stmts.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .let_stmt), tagOf(let1));
    try std.testing.expectEqual(false, let1.let_stmt.mutable);
    try std.testing.expect(let1.let_stmt.ty != null);
    try std.testing.expect(let1.let_stmt.init_expr != null);
    const let2 = res.arena.get(body.block.stmts.indices[1]);
    try std.testing.expectEqual(true, let2.let_stmt.mutable);
}

test "parser: let with inferred type" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let z = x + 10
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .let_stmt), tagOf(stmt));
    try std.testing.expectEqual(false, stmt.let_stmt.mutable);
    try std.testing.expect(stmt.let_stmt.ty == null);
    try std.testing.expect(stmt.let_stmt.init_expr != null);
}

test "parser: call expression" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    foo("hello")
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const call = res.arena.get(stmt.expr_stmt.expr);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .call), tagOf(call));
}

test "parser: print as field name after dot" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    io.print("hello")
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const call = res.arena.get(stmt.expr_stmt.expr);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .call), tagOf(call));
    const callee = res.arena.get(call.call.func);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .field_access), tagOf(callee));
}

test "parser: field access in call position" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    foo.bar()
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const call = res.arena.get(stmt.expr_stmt.expr);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .call), tagOf(call));
}

test "parser: while loop" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    while true {
        \\        print("looping")
        \\    }
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .while_expr), tagOf(stmt));
}

test "parser: defer statement" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    defer cleanup()
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .defer_stmt), tagOf(stmt));
}

test "parser: single-expression function" {
    var res = try runTest(std.testing.allocator,
        \\fn double(x: i32) -> i32 = x * 2
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .fn_decl), tagOf(decl));
    const body = res.arena.get(decl.fn_decl.body);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .return_stmt), tagOf(body));
    const ret = body.return_stmt;
    try std.testing.expect(ret.value != null);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .binary_op), tagOf(res.arena.get(ret.value.?)));
}

test "parser: impl block is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\impl Vec2 {
        \\    fn zero() -> Vec2 {
        \\        return Vec2{ .x = 0.0, .y = 0.0 }
        \\    }
        \\}
    );
}

test "parser: impl type is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\fn describe(s: &impl Shape) -> i32 {
        \\    return s.speak()
        \\}
    );
}

test "parser: struct init expression" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let v = Vec2{ .x = 1.0, .y = 2.0 }
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const init_expr = stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull;
    const struct_init = res.arena.get(init_expr);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .struct_init), tagOf(struct_init));
    try std.testing.expectEqual(@as(usize, 2), struct_init.struct_init.fields.indices.len);
}

test "parser: index access" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let x = list[0]
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const body = res.arena.get(decl.fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const expr = stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull;
    const idx = res.arena.get(expr);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(idx));
}

test "parser: module with multiple declarations" {
    var res = try runTest(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\
        \\fn sub(a: i32, b: i32) -> i32 {
        \\    return a - b
        \\}
    );
    defer res.arena.deinit();
    try std.testing.expectEqual(@as(usize, 2), getMod(&res).module.decls.indices.len);
}

test "parser: namespace import" {
    var res = try runTest(std.testing.allocator, "import os::path");
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .import_decl), tagOf(decl));
    try std.testing.expectEqual(@as(usize, 2), decl.import_decl.path.indices.len);
}

test "parser: closure expression" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let f = |x: i32| x + 1
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const init = res.arena.get(stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .closure), tagOf(init));
    try std.testing.expectEqual(@as(usize, 1), init.closure.params.indices.len);
}

test "parser: zero-arg closure" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let f = || 42
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const init = res.arena.get(stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .closure), tagOf(init));
    try std.testing.expectEqual(@as(usize, 0), init.closure.params.indices.len);
}

test "parser: pipeline operator" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let y = x |> f
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const init = res.arena.get(stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(init));
}

test "parser: pipeline binds looser than arithmetic" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let y = a + b |> f
        \\}
    );
    defer res.arena.deinit();
    const init = try firstInitOfBody(&res);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(init));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .binary_op), tagOf(res.arena.get(init.pipeline.lhs)));
    const rhs = res.arena.get(init.pipeline.rhs);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .identifier), tagOf(rhs));
    try std.testing.expectEqualStrings("f", nameOf(&res, rhs.identifier));
}

test "parser: pipeline chain is left associative" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let y = x |> f |> g
        \\}
    );
    defer res.arena.deinit();
    const init = try firstInitOfBody(&res);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(init));
    const inner = res.arena.get(init.pipeline.lhs);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(inner));
    const rhs = res.arena.get(init.pipeline.rhs);
    try std.testing.expectEqualStrings("g", nameOf(&res, rhs.identifier));
}

test "parser: pipeline with call and hole" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let v3 = v1 |> add(_, v2)
        \\}
    );
    defer res.arena.deinit();
    const init = try firstInitOfBody(&res);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(init));
    const call = res.arena.get(init.pipeline.rhs);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .call), tagOf(call));
    try std.testing.expectEqual(@as(usize, 2), call.call.args.indices.len);
    const hole = res.arena.get(call.call.args.indices[0]);
    try std.testing.expectEqualStrings("_", nameOf(&res, hole.identifier));
}

test "parser: piped closure call" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let y = x |> |v| v + 1
        \\}
    );
    defer res.arena.deinit();
    const init = try firstInitOfBody(&res);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(init));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .closure), tagOf(res.arena.get(init.pipeline.rhs)));
}

test "parser: closure with block body" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let f = |x: i32| { let y = x + 1
        \\        return y }
        \\}
    );
    defer res.arena.deinit();
    const init = try firstInitOfBody(&res);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .closure), tagOf(init));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .block), tagOf(res.arena.get(init.closure.body)));
}

test "parser: closure returning a closure" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let outer = |x| { let inner = |y| x + y
        \\        return inner }
        \\}
    );
    defer res.arena.deinit();
    const init = try firstInitOfBody(&res);
    const body = res.arena.get(init.closure.body);
    const inner_stmt = res.arena.get(body.block.stmts.indices[0]);
    const inner = res.arena.get(inner_stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .closure), tagOf(inner));
}

test "parser: fn name used as a value" {
    var res = try runTest(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\
        \\fn main() -> i32 {
        \\    return apply(add, 2, 3)
        \\}
    );
    defer res.arena.deinit();
    const main_decl = declAt(&res, 1);
    const body = res.arena.get(main_decl.fn_decl.body);
    const ret = res.arena.get(body.block.stmts.indices[0]);
    const call = res.arena.get(ret.return_stmt.value orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .call), tagOf(call));
    try std.testing.expectEqual(@as(usize, 3), call.call.args.indices.len);
    const fn_name = res.arena.get(call.call.args.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .identifier), tagOf(fn_name));
    try std.testing.expectEqualStrings("add", nameOf(&res, fn_name.identifier));
}

test "parser: fn type in param position" {
    var res = try runTest(std.testing.allocator,
        \\fn apply(f: fn(i32, i32) -> i32, x: i32, y: i32) -> i32 {
        \\    return f(x, y)
        \\}
    );
    defer res.arena.deinit();
    const decl = declAt(&res, 0);
    try std.testing.expectEqual(@as(usize, 3), decl.fn_decl.params.indices.len);
    const param = res.arena.get(decl.fn_decl.params.indices[0]);
    const fn_ty = res.arena.get(param.param.ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .fn_type), tagOf(fn_ty));
    try std.testing.expectEqual(@as(usize, 2), fn_ty.fn_type.params.indices.len);
    const ret = res.arena.get(fn_ty.fn_type.return_type);
    try std.testing.expectEqualStrings("i32", nameOf(&res, ret.identifier));
}

test "parser: fn type as return type" {
    var res = try runTest(std.testing.allocator,
        \\fn make_adder(base: i32) -> fn(i32) -> i32 = |x| x + base
    );
    defer res.arena.deinit();
    const decl = declAt(&res, 0);
    const return_ty = res.arena.get(decl.fn_decl.return_type orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .fn_type), tagOf(return_ty));
    try std.testing.expectEqual(@as(usize, 1), return_ty.fn_type.params.indices.len);
    const shorthand = res.arena.get(decl.fn_decl.body);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .return_stmt), tagOf(shorthand));
    const closure = res.arena.get(shorthand.return_stmt.value orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .closure), tagOf(closure));
}

test "parser: fn type in let annotation" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let f: fn(i32) -> i32 = add
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(declAt(&res, 0).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const fn_ty = res.arena.get(stmt.let_stmt.ty orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .fn_type), tagOf(fn_ty));
    const init = res.arena.get(stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqualStrings("add", nameOf(&res, init.identifier));
}

test "parser: fn type in struct field" {
    var res = try runTest(std.testing.allocator,
        \\struct Handler {
        \\    cb: fn(i32) -> i32
        \\}
    );
    defer res.arena.deinit();
    const decl = declAt(&res, 0);
    const field = res.arena.get(decl.struct_decl.fields.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(TypeRepr), .plain), @as(std.meta.Tag(TypeRepr), field.field.ty));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .fn_type), tagOf(res.arena.get(field.field.ty.plain)));
}

test "parser: zero-parameter and nested fn types" {
    var res = try runTest(std.testing.allocator,
        \\fn higher(f: fn() -> fn(i32) -> i32) -> fn(i32) -> i32 {
        \\    return f()
        \\}
    );
    defer res.arena.deinit();
    const decl = declAt(&res, 0);
    const param = res.arena.get(decl.fn_decl.params.indices[0]);
    const outer = res.arena.get(param.param.ty);
    try std.testing.expectEqual(@as(usize, 0), outer.fn_type.params.indices.len);
    const inner = res.arena.get(outer.fn_type.return_type);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .fn_type), tagOf(inner));
    const decl_return = res.arena.get(decl.fn_decl.return_type orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .fn_type), tagOf(decl_return));
}

test "parser: fn type in expression position" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let t = fn(i32) -> i32
        \\}
    );
    defer res.arena.deinit();
    const init = try firstInitOfBody(&res);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .fn_type), tagOf(init));
    try std.testing.expectEqual(@as(usize, 1), init.fn_type.params.indices.len);
}

test "parser: fn type without arrow is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\fn f(x: fn(i32) i32) -> i32 {
        \\    return 0
        \\}
    );
}

test "parser: bare fn in type position is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\fn main() {
        \\    let f: fn = add
        \\}
    );
}

test "parser: postfix try propagation" {
    var res = try runTest(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return foo()?
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const ret = res.arena.get(body.block.stmts.indices[0]);
    const value = res.arena.get(ret.return_stmt.value orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(value));
}

test "parser: comptime block and expression" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let a = comptime { 1 }
        \\    let b = comptime 1 + 2
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const stmt_a = res.arena.get(body.block.stmts.indices[0]);
    const init_a = res.arena.get(stmt_a.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .comptime_block), tagOf(init_a));
    const stmt_b = res.arena.get(body.block.stmts.indices[1]);
    const init_b = res.arena.get(stmt_b.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .comptime_expr), tagOf(init_b));
}

test "parser: region expression" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    region r {
        \\        let x = 1
        \\    }
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const region = res.arena.get(stmt.expr_stmt.expr);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .region_expr), tagOf(region));
    try std.testing.expectEqual(@as(u32, 1), region.region_expr.name.end - region.region_expr.name.start);
}

test "parser: move expression" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let y = move x
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const init = res.arena.get(stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .move_expr), tagOf(init));
}

test "parser: comptime builtin call" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let n = @sizeof(i32)
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const init = res.arena.get(stmt.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .comptime_call), tagOf(init));
    try std.testing.expectEqual(@as(u32, 6), init.comptime_call.name.end - init.comptime_call.name.start);
    try std.testing.expectEqual(@as(usize, 1), init.comptime_call.args.indices.len);
}

test "parser: match guard" {
    var res = try runTest(std.testing.allocator,
        \\fn f(x: i32) -> i32 {
        \\    match x {
        \\        n if n > 0 => 1,
        \\        _ => 0,
        \\    }
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const match = res.arena.get(body.block.stmts.indices[0]);
    const arm0 = res.arena.get(match.match_expr.arms.indices[0]);
    try std.testing.expect(arm0.match_arm.guard != null);
    const arm1 = res.arena.get(match.match_expr.arms.indices[1]);
    try std.testing.expect(arm1.match_arm.guard == null);
}

test "parser: reference type representations" {
    var res = try runTest(std.testing.allocator,
        \\struct S {
        \\    p: &i32
        \\    q: &mut bool
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    const field0 = res.arena.get(decl.struct_decl.fields.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(TypeRepr), .reference), @as(std.meta.Tag(TypeRepr), field0.field.ty));
    const field1 = res.arena.get(decl.struct_decl.fields.indices[1]);
    try std.testing.expectEqual(@as(std.meta.Tag(TypeRepr), .mut_reference), @as(std.meta.Tag(TypeRepr), field1.field.ty));
}

test "parser: wildcard binding" {
    var res = try runTest(std.testing.allocator,
        \\fn main() {
        \\    let _ = 1
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(res.arena.get(getMod(&res).module.decls.indices[0]).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .let_stmt), tagOf(stmt));
    try std.testing.expectEqual(@as(u32, 1), stmt.let_stmt.name.end - stmt.let_stmt.name.start);
}

// --- shorthand `fn` bodies (`docs/syntax.md` §4.3) ---

test "parser: shorthand body is a pipeline" {
    var res = try runTest(std.testing.allocator,
        \\fn f(x: i32) -> i32 = x |> g |> h
    );
    defer res.arena.deinit();
    const value = try shorthandValue(&res, 0);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(value));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(res.arena.get(value.pipeline.lhs)));
    try std.testing.expectEqualStrings("h", nameOf(&res, res.arena.get(value.pipeline.rhs).identifier));
}

test "parser: shorthand body accepts a struct initializer" {
    var res = try runTest(std.testing.allocator,
        \\fn zero() -> Vec2 = Vec2 { .x = 0.0, .y = 0.0 }
    );
    defer res.arena.deinit();
    const value = try shorthandValue(&res, 0);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .struct_init), tagOf(value));
    try std.testing.expectEqual(@as(usize, 2), value.struct_init.fields.indices.len);
}

test "parser: shorthand body accepts if and match" {
    var res = try runTest(std.testing.allocator,
        \\fn abs(x: i32) -> i32 = if x > 0 { x } else { -x }
        \\fn zero(x: i32) -> i32 = match x { 1 => 1, _ => 0 }
    );
    defer res.arena.deinit();
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .if_expr), tagOf(try shorthandValue(&res, 0)));
    const match_expr = try shorthandValue(&res, 1);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .match_expr), tagOf(match_expr));
    try std.testing.expectEqual(@as(usize, 2), match_expr.match_expr.arms.indices.len);
}

test "parser: shorthand body accepts a closure block and propagation" {
    var res = try runTest(std.testing.allocator,
        \\fn adder() -> Fn = |x| { x + 1 }
        \\fn f() -> i32 = g()?
    );
    defer res.arena.deinit();
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .closure), tagOf(try shorthandValue(&res, 0)));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(try shorthandValue(&res, 1)));
}

test "parser: shorthand body on a generic function" {
    var res = try runTest(std.testing.allocator,
        \\fn first[T](xs: Slice[T]) -> T = xs[0]
    );
    defer res.arena.deinit();
    const decl = declAt(&res, 0);
    try std.testing.expectEqual(@as(usize, 1), decl.fn_decl.generic_params.indices.len);
    const gp = res.arena.get(decl.fn_decl.generic_params.indices[0]);
    try std.testing.expectEqualStrings("T", nameOf(&res, gp.identifier));
    const value = try shorthandValue(&res, 0);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(value));
}

test "parser: function without a body is rejected" {
    try expectParseErrorContaining(std.testing.allocator,
        \\fn f(x: i32) -> i32
    , "for function body");
}

// --- generic applications (`docs/syntax.md` §4.6, §6.1) ---

test "parser: multi-argument generic application" {
    var res = try runTest(std.testing.allocator,
        \\fn unwrap(r: Result[i32, String]) -> Pair[i32, f64] { return p }
    );
    defer res.arena.deinit();
    const decl = declAt(&res, 0);
    const param = res.arena.get(decl.fn_decl.params.indices[0]);
    const arg = res.arena.get(param.param.ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .generic_app), tagOf(arg));
    try std.testing.expectEqualStrings("Result", nameOf(&res, res.arena.get(arg.generic_app.base).identifier));
    try std.testing.expectEqual(@as(usize, 2), arg.generic_app.args.indices.len);
    try std.testing.expectEqualStrings("i32", nameOf(&res, res.arena.get(arg.generic_app.args.indices[0]).identifier));
    try std.testing.expectEqualStrings("String", nameOf(&res, res.arena.get(arg.generic_app.args.indices[1]).identifier));

    const ret = res.arena.get(decl.fn_decl.return_type orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .generic_app), tagOf(ret));
    try std.testing.expectEqualStrings("Pair", nameOf(&res, res.arena.get(ret.generic_app.base).identifier));
}

test "parser: nested and multi-argument generic applications" {
    var res = try runTest(std.testing.allocator,
        \\fn f(a: Result[Option[i32], String], b: Pair[Pair[i32, f64], Pair[i32, f64]], c: Vec[Vec[Vec[i32]]]) { }
    );
    defer res.arena.deinit();
    const params = declAt(&res, 0).fn_decl.params;

    const a = res.arena.get(res.arena.get(params.indices[0]).param.ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .generic_app), tagOf(a));
    const a0 = res.arena.get(a.generic_app.args.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(a0));
    try std.testing.expectEqualStrings("Option", nameOf(&res, res.arena.get(a0.index_access.object).identifier));

    const b = res.arena.get(res.arena.get(params.indices[1]).param.ty);
    try std.testing.expectEqual(@as(usize, 2), b.generic_app.args.indices.len);
    const b0 = res.arena.get(b.generic_app.args.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .generic_app), tagOf(b0));
    try std.testing.expectEqual(@as(usize, 2), b0.generic_app.args.indices.len);
    try std.testing.expectEqualStrings("f64", nameOf(&res, res.arena.get(b0.generic_app.args.indices[1]).identifier));

    const c = res.arena.get(res.arena.get(params.indices[2]).param.ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(c));
    const c0 = res.arena.get(c.index_access.index);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(c0));
    const c00 = res.arena.get(c0.index_access.index);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(c00));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .identifier), tagOf(res.arena.get(c00.index_access.index)));
}

test "parser: generic arguments span newlines and allow a trailing comma" {
    var res = try runTest(std.testing.allocator,
        \\fn f(r: Result[
        \\    i32,
        \\    String,
        \\]) { }
    );
    defer res.arena.deinit();
    const arg = res.arena.get(res.arena.get(declAt(&res, 0).fn_decl.params.indices[0]).param.ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .generic_app), tagOf(arg));
    try std.testing.expectEqual(@as(usize, 2), arg.generic_app.args.indices.len);
    try std.testing.expectEqualStrings("String", nameOf(&res, res.arena.get(arg.generic_app.args.indices[1]).identifier));
}

test "parser: generic application in let annotation and struct field" {
    var res = try runTest(std.testing.allocator,
        \\struct Holder {
        \\    value: Result[i32, String]
        \\}
        \\fn f() {
        \\    let pair: Pair[i32, f64] = g()
        \\}
    );
    defer res.arena.deinit();
    const field = res.arena.get(declAt(&res, 0).struct_decl.fields.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(TypeRepr), .plain), @as(std.meta.Tag(TypeRepr), field.field.ty));
    const field_ty = res.arena.get(field.field.ty.plain);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .generic_app), tagOf(field_ty));
    try std.testing.expectEqual(@as(usize, 2), field_ty.generic_app.args.indices.len);

    const body = res.arena.get(declAt(&res, 1).fn_decl.body);
    const let_stmt = res.arena.get(body.block.stmts.indices[0]);
    const annotation = res.arena.get(let_stmt.let_stmt.ty orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .generic_app), tagOf(annotation));
    try std.testing.expectEqualStrings("Pair", nameOf(&res, res.arena.get(annotation.generic_app.base).identifier));
}

test "parser: reference to a multi-argument generic" {
    var res = try runTest(std.testing.allocator,
        \\fn f(shared: &Result[i32, String], owned: &mut Result[i32, String]) { }
    );
    defer res.arena.deinit();
    const params = declAt(&res, 0).fn_decl.params;
    for (params.indices) |idx| {
        const unary = res.arena.get(res.arena.get(idx).param.ty);
        try std.testing.expectEqual(@as(std.meta.Tag(Node), .unary_op), tagOf(unary));
        const app = res.arena.get(unary.unary_op.operand);
        try std.testing.expectEqual(@as(std.meta.Tag(Node), .generic_app), tagOf(app));
        try std.testing.expectEqual(@as(usize, 2), app.generic_app.args.indices.len);
    }
}

test "parser: single-argument brackets stay an index access" {
    var res = try runTest(std.testing.allocator,
        \\fn first(xs: Slice[i32]) -> i32 { return xs[0] }
    );
    defer res.arena.deinit();
    const decl = declAt(&res, 0);
    const param_ty = res.arena.get(res.arena.get(decl.fn_decl.params.indices[0]).param.ty);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(param_ty));
    try std.testing.expectEqualStrings("Slice", nameOf(&res, res.arena.get(param_ty.index_access.object).identifier));
    const body = res.arena.get(decl.fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const value = res.arena.get(stmt.return_stmt.value orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(value));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .int_literal), tagOf(res.arena.get(value.index_access.index)));
}

test "parser: multi-argument generic application nests behind a call and a shift" {
    var res = try runTest(std.testing.allocator,
        \\fn f() {
        \\    let a = make()[0]
        \\    let b = x << 1
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(declAt(&res, 0).fn_decl.body);
    const a = res.arena.get(res.arena.get(body.block.stmts.indices[0]).let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(a));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .call), tagOf(res.arena.get(a.index_access.object)));
    const b = res.arena.get(res.arena.get(body.block.stmts.indices[1]).let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .binary_op), tagOf(b));
}

test "parser: empty bracket list is rejected" {
    try expectParseErrorContaining(std.testing.allocator,
        \\fn f(xs: Slice[]) { }
    , "inside '[]'");
}

test "parser: unterminated generic argument list is rejected" {
    // Regression: recovering from the missing `]` must not walk past the end of
    // the token stream.
    try expectParseErrors(std.testing.allocator,
        \\fn f(r: Pair[i32, f64) { }
    );
    try expectParseErrors(std.testing.allocator,
        \\fn f(r: Pair[i32,
    );
}

test "parser: no prefix of a dense program crashes" {
    // Every recovery path in the parser has to survive input that stops in the
    // middle of a token, a list, or a block.
    const source =
        \\struct Pair[A, B] { first: A
        \\    second: B }
        \\fn unwrap(r: Result[Pair[i32, f64], String]) -> i32 = match r? { Ok(p) => p.first, Err(_) => 0 }
        \\fn main() {
        \\    let xs: Vec[i32] = Vec[i32]{ 1, 2 }
        \\    for v in xs |> iter { g(v)? }
        \\    while next()? { |v| v? }
        \\}
    ;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        try expectNoCrash(std.testing.allocator, source[0..i]);
    }
}

// --- pipe chains (`docs/syntax.md` §5.2) ---

test "parser: pipe binds looser than comparison" {
    var res = try runTest(std.testing.allocator,
        \\fn f() {
        \\    let y = x |> f == 0
        \\}
    );
    defer res.arena.deinit();
    const pipe = try firstInitOfBody(&res);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(pipe));
    const rhs = res.arena.get(pipe.pipeline.rhs);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .binary_op), tagOf(rhs));
    try std.testing.expectEqual(@as(BinaryOp, .eq), rhs.binary_op.op);
}

test "parser: pipe inside call arguments, match arms and return" {
    var res = try runTest(std.testing.allocator,
        \\fn f() -> i32 {
        \\    let a = g(x |> f, 2)
        \\    let b = match x |> f { 1 => 1, _ => 0 }
        \\    return x |> h
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(declAt(&res, 0).fn_decl.body);
    const call_init = res.arena.get(res.arena.get(body.block.stmts.indices[0]).let_stmt.init_expr orelse return error.TestUnexpectedNull);
    const call = res.arena.get(call_init.call.args.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(call));
    const match_init = res.arena.get(res.arena.get(body.block.stmts.indices[1]).let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(res.arena.get(match_init.match_expr.scrutinee)));
    const ret = res.arena.get(body.block.stmts.indices[2]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(res.arena.get(ret.return_stmt.value orelse return error.TestUnexpectedNull)));
}

test "parser: pipe with propagation and a following stage" {
    var res = try runTest(std.testing.allocator,
        \\fn f() {
        \\    let y = x |> g()?
        \\    let z = x |> g()? |> h
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(declAt(&res, 0).fn_decl.body);
    const first = res.arena.get(res.arena.get(body.block.stmts.indices[0]).let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(res.arena.get(first.pipeline.rhs)));
    const second = res.arena.get(res.arena.get(body.block.stmts.indices[1]).let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(second));
    const inner = res.arena.get(second.pipeline.lhs);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(inner));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(res.arena.get(inner.pipeline.rhs)));
}

test "parser: pipe in a struct initializer field" {
    var res = try runTest(std.testing.allocator,
        \\fn f() {
        \\    let p = Point { .x = xs |> len, .y = 0 }
        \\}
    );
    defer res.arena.deinit();
    const init = try firstInitOfBody(&res);
    const field0 = res.arena.get(init.struct_init.fields.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .pipeline), tagOf(res.arena.get(field0.struct_init_field.value)));
}

// --- postfix `?` propagation (`docs/syntax.md` §8.6) ---

test "parser: propagation chains through call, field and index" {
    var res = try runTest(std.testing.allocator,
        \\fn f() -> i32 { return g()?.h()[0]? }
    );
    defer res.arena.deinit();
    const body = res.arena.get(declAt(&res, 0).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    const outer = res.arena.get(stmt.return_stmt.value orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(outer));
    const index = res.arena.get(outer.try_propagate);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .index_access), tagOf(index));
    const call = res.arena.get(index.index_access.object);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .call), tagOf(call));
    const field = res.arena.get(call.call.func);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .field_access), tagOf(field));
    const inner = res.arena.get(field.field_access.object);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(inner));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .call), tagOf(res.arena.get(inner.try_propagate)));
}

test "parser: propagation in argument lists, closures and match arms" {
    var res = try runTest(std.testing.allocator,
        \\fn f() -> i32 {
        \\    let a = g(h()?, 2)
        \\    let b = |v| v?
        \\    let c = match r? { Some(v) => v?, _ => 0 }
        \\    return r.value?
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(declAt(&res, 0).fn_decl.body);
    const a = res.arena.get(res.arena.get(body.block.stmts.indices[0]).let_stmt.init_expr orelse return error.TestUnexpectedNull);
    const a0 = res.arena.get(a.call.args.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(a0));
    const b = res.arena.get(res.arena.get(body.block.stmts.indices[1]).let_stmt.init_expr orelse return error.TestUnexpectedNull);
    const b_body = res.arena.get(b.closure.body);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(b_body));
    const c = res.arena.get(res.arena.get(body.block.stmts.indices[2]).let_stmt.init_expr orelse return error.TestUnexpectedNull);
    const arm = res.arena.get(c.match_expr.arms.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(res.arena.get(arm.match_arm.body)));
    const ret = res.arena.get(body.block.stmts.indices[3]);
    const value = res.arena.get(ret.return_stmt.value orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(value));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .field_access), tagOf(res.arena.get(value.try_propagate)));
}

test "parser: propagation in statement, if, while, for, defer and comptime positions" {
    var res = try runTest(std.testing.allocator,
        \\fn f() -> i32 {
        \\    g()?
        \\    if r? { return 1 }
        \\    while r? { }
        \\    for v in r? { }
        \\    defer r?
        \\    comptime { r? }
        \\    return 0
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(declAt(&res, 0).fn_decl.body);
    const stmt = res.arena.get(body.block.stmts.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .expr_stmt), tagOf(stmt));
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(res.arena.get(stmt.expr_stmt.expr)));
    const if_stmt = res.arena.get(body.block.stmts.indices[1]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(res.arena.get(if_stmt.if_expr.cond)));
    const while_stmt = res.arena.get(body.block.stmts.indices[2]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(res.arena.get(while_stmt.while_expr.cond)));
    const for_stmt = res.arena.get(body.block.stmts.indices[3]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(res.arena.get(for_stmt.for_each.iterable)));
    const defer_stmt = res.arena.get(body.block.stmts.indices[4]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(res.arena.get(defer_stmt.defer_stmt.expr)));
    const comptime_stmt = res.arena.get(body.block.stmts.indices[5]);
    const comptime_block = res.arena.get(comptime_stmt.expr_stmt.expr);
    const inner = res.arena.get(comptime_block.comptime_block);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .try_propagate), tagOf(res.arena.get(res.arena.get(inner.block.stmts.indices[0]).expr_stmt.expr)));
}

test "parser: doubled propagation is rejected" {
    try expectParseErrorContaining(std.testing.allocator,
        \\fn f() -> i32 { return g()?? }
    , "already unwrapped");
}

test "parser: propagation is rejected in type positions" {
    try expectParseErrorContaining(std.testing.allocator,
        \\fn f() { let x: i32? = 1 }
    , "not part of a type");
    try expectParseErrorContaining(std.testing.allocator,
        \\fn f(x: i32?) { }
    , "not part of a type");
    try expectParseErrorContaining(std.testing.allocator,
        \\fn f() -> Result[i32, String]? { return r }
    , "not part of a type");
    try expectParseErrorContaining(std.testing.allocator,
        \\struct S { value: i32? }
    , "not part of a type");
    try expectParseErrorContaining(std.testing.allocator,
        \\fn f() { let g: fn(i32) -> i32? = h }
    , "not part of a type");
}

// --- removed OOP syntax ---

test "parser: class declaration is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\class Animal {
        \\    name: String
        \\}
    );
}

test "parser: property block is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\class Counter {
        \\    prop count: i32 {
        \\        get => this.count
        \\        set(v) { this.count = v }
        \\    }
        \\}
    );
}

test "parser: struct inheritance is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\struct Dog(Animal) {
        \\    name: String
        \\}
    );
}

test "parser: fat pointer to an impl is rejected" {
    try expectParseErrors(std.testing.allocator,
        \\fn speak(s: *impl Speakable) -> String { return s.speak() }
    );
}

test "parser: impl and interface are ordinary identifiers" {
    var res = try runTest(std.testing.allocator,
        \\fn f() {
        \\    let impl = 1
        \\    let interface = impl + 1
        \\}
    );
    defer res.arena.deinit();
    const body = res.arena.get(declAt(&res, 0).fn_decl.body);
    const second = res.arena.get(body.block.stmts.indices[1]);
    const init = res.arena.get(second.let_stmt.init_expr orelse return error.TestUnexpectedNull);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .binary_op), tagOf(init));
    try std.testing.expectEqualStrings("impl", nameOf(&res, res.arena.get(init.binary_op.left).identifier));
}

fn exprToBinaryOp(op: BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shift_left => "<<",
        .shift_right => ">>",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .gt => ">",
        .le => "<=",
        .ge => ">=",
        .and_op => "&&",
        .or_op => "||",
        .assign => "=",
        .add_assign => "+=",
        .sub_assign => "-=",
        .mul_assign => "*=",
        .div_assign => "/=",
        .range => "..",
    };
}
