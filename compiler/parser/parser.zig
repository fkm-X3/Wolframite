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

    fn peek(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn peekNext(self: *const Parser) Token {
        if (self.pos + 1 < self.tokens.len) {
            return self.tokens[self.pos + 1];
        }
        return self.tokens[self.tokens.len - 1];
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.pos];
        self.pos += 1;
        return tok;
    }

    fn check(self: *const Parser, tag: TokenTag) bool {
        return self.pos < self.tokens.len and self.tokens[self.pos].tag == tag;
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
            .interface_kw => {
                _ = self.advance();
                return self.parseInterfaceDecl();
            },
            .impl_kw => {
                _ = self.advance();
                return self.parseImplBlock();
            },
            .import_kw => {
                _ = self.advance();
                return self.parseImportDecl();
            },
            .let_kw, .mut_kw => {
                return self.parseLetStmt();
            },
            else => {
                self.errorHere("expected declaration (fn, struct, enum, interface, impl, import, comptime, let, mut)", .{});
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
        var methods = std.ArrayList(NodeIdx).empty;
        defer {
            fields.deinit(self.allocator);
            methods.deinit(self.allocator);
        }

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rbrace)) break;

            if (self.check(.fn_kw)) {
                _ = self.advance();
                const method = self.parseFnDecl() orelse {
                    self.recoverTo(.rbrace);
                    break;
                };
                methods.append(self.allocator, method) catch unreachable;
            } else {
                const field = self.parseField() orelse {
                    self.recoverTo(.rbrace);
                    break;
                };
                fields.append(self.allocator, field) catch unreachable;
            }
        }

        _ = self.expect(.rbrace);
        return self.appendNode(.{ .struct_decl = .{
            .name = self.makeStringRef(name_tok),
            .generic_params = generic_params,
            .fields = self.arena.allocNodeList(fields.items) catch NodeList{ .indices = &.{} },
            .methods = self.arena.allocNodeList(methods.items) catch NodeList{ .indices = &.{} },
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

    fn parseInterfaceDecl(self: *Parser) ?NodeIdx {
        const name_tok = self.expect(.identifier) orelse return null;
        const generic_params = self.parseGenericParams() orelse NodeList{ .indices = &.{} };

        if (self.expect(.lbrace) == null) return null;

        var methods = std.ArrayList(NodeIdx).empty;
        defer methods.deinit(self.allocator);

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rbrace)) break;

            if (!self.check(.fn_kw)) {
                self.errorHere("expected 'fn' in interface", .{});
                self.recoverTo(.rbrace);
                break;
            }
            _ = self.advance();

            const name_tok2 = self.expect(.identifier) orelse {
                self.recoverTo(.rbrace);
                break;
            };
            const params = self.parseParamList() orelse {
                self.recoverTo(.rbrace);
                break;
            };

            var return_type: ?NodeIdx = null;
            self.skipNewlinesAndSemicolons();
            if (self.expectPeek(.arrow)) |_| {
                return_type = self.parseExpr(Precedence.none.toInt());
                self.skipNewlinesAndSemicolons();
            }

            methods.append(self.allocator, self.appendNode(.{ .fn_decl = .{
                .name = self.makeStringRef(name_tok2),
                .generic_params = NodeList{ .indices = &.{} },
                .params = params,
                .return_type = return_type,
                .body = NodeIdx.none,
            } })) catch unreachable;
        }

        _ = self.expect(.rbrace);
        return self.appendNode(.{ .interface_decl = .{
            .name = self.makeStringRef(name_tok),
            .generic_params = generic_params,
            .methods = self.arena.allocNodeList(methods.items) catch NodeList{ .indices = &.{} },
        } });
    }

    fn parseImplBlock(self: *Parser) ?NodeIdx {
        const self_type = self.parseExpr(Precedence.none.toInt()) orelse return null;
        if (self.expect(.lbrace) == null) return null;

        var methods = std.ArrayList(NodeIdx).empty;
        defer methods.deinit(self.allocator);

        while (true) {
            self.skipNewlinesAndSemicolons();
            if (self.check(.rbrace)) break;

            if (!self.check(.fn_kw)) {
                self.errorHere("expected 'fn' in impl block", .{});
                self.recoverTo(.rbrace);
                break;
            }
            _ = self.advance();
            const method = self.parseFnDecl() orelse {
                self.recoverTo(.rbrace);
                break;
            };
            methods.append(self.allocator, method) catch unreachable;
        }

        _ = self.expect(.rbrace);
        return self.appendNode(.{ .impl_block = .{
            .self_type = self_type,
            .methods = self.arena.allocNodeList(methods.items) catch NodeList{ .indices = &.{} },
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

    fn parseTypeRepr(self: *Parser) ?TypeRepr {
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
                .generic_app => |g| g.base,
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
            .impl_kw => {
                _ = self.advance();
                const inner = self.parseExpr(Precedence.prefix.toInt()) orelse return null;
                return self.appendNode(.{ .impl_type = inner });
            },
            .pipe, .pipe_pipe => return self.parseClosure(),
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
                const index = self.parseExpr(Precedence.none.toInt()) orelse return left;
                _ = self.expect(.rbracket);
                return self.appendNode(.{ .index_access = .{ .object = left, .index = index } });
            },
            .dot => {
                const field_tok = self.expect(.identifier) orelse return left;
                return self.appendNode(.{ .field_access = .{ .object = left, .field = self.makeStringRef(field_tok) } });
            },
            .pipeline => {
                const right = self.parseExpr(prec) orelse return left;
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

const TestResult = struct { arena: ast.AstArena, node: NodeIdx };

fn runTest(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    var arena = ast.AstArena.init(allocator);
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    var parser = Parser.init(allocator, tokens, source, &arena, &diags);
    const module = parser.parseModule();
    return TestResult{ .arena = arena, .node = module };
}

fn getMod(res: *const TestResult) *const Node {
    return res.arena.get(res.node);
}

fn tagOf(node: *const Node) std.meta.Tag(Node) {
    return std.meta.activeTag(node.*);
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
    try std.testing.expectEqual(@as(usize, 0), decl.struct_decl.methods.indices.len);
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

test "parser: interface declaration" {
    var res = try runTest(std.testing.allocator,
        \\interface Speakable {
        \\    fn speak(self: &Self) -> String
        \\}
    );
    defer res.arena.deinit();
    const mod = getMod(&res);
    const decl = res.arena.get(mod.module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .interface_decl), tagOf(decl));
    try std.testing.expectEqual(@as(usize, 1), decl.interface_decl.methods.indices.len);
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

test "parser: struct with methods" {
    var res = try runTest(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\
        \\    fn add(self: &Vec2, other: &Vec2) -> Vec2 {
        \\        return Vec2{ .x = self.x + other.x, .y = self.y + other.y }
        \\    }
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .struct_decl), tagOf(decl));
    try std.testing.expectEqual(@as(usize, 2), decl.struct_decl.fields.indices.len);
    try std.testing.expectEqual(@as(usize, 1), decl.struct_decl.methods.indices.len);
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

test "parser: method call with field access" {
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

test "parser: impl block" {
    var res = try runTest(std.testing.allocator,
        \\impl Vec2 {
        \\    fn zero() -> Vec2 {
        \\        return Vec2{ .x = 0.0, .y = 0.0 }
        \\    }
        \\}
    );
    defer res.arena.deinit();
    const decl = res.arena.get(getMod(&res).module.decls.indices[0]);
    try std.testing.expectEqual(@as(std.meta.Tag(Node), .impl_block), tagOf(decl));
    try std.testing.expectEqual(@as(usize, 1), decl.impl_block.methods.indices.len);
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
