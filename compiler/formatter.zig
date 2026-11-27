//! Pretty-printer / formatter for Wolframite source.
//!
//! Parses a source file into the AST and re-emits it in the canonical
//! style used by the examples (4-space indentation, one statement per line,
//! trailing commas in multi-line blocks). Comments are not preserved: the
//! formatter is a structural pretty-printer over the AST.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("parser/ast.zig");
const lexer_mod = @import("lexer/lexer.zig");
const parser_mod = @import("parser/parser.zig");
const diag_mod = @import("diagnostics.zig");

pub const FormatError = error{ LexError, ParseError, OutOfMemory };

pub fn format(allocator: Allocator, source: []const u8) FormatError![]u8 {
    var arena = ast.AstArena.init(allocator);
    defer arena.deinit();

    var lex = lexer_mod.Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = lex.tokenize() catch return error.LexError;

    var diags = diag_mod.Diagnostics.init(allocator);
    diags.owns_messages = true;
    defer diags.deinit();

    var parser = parser_mod.Parser.init(allocator, tokens, source, &arena, &diags);
    const module_node = parser.parseModule();
    if (diags.hasErrors()) return error.ParseError;

    var f = Fmt.init(allocator, source, &arena);
    defer f.deinit();
    f.fmtModule(module_node) catch return error.OutOfMemory;
    const slice = f.out.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return slice;
}

// Aliases that callers/tests might use.
pub const formatSource = format;
pub const fmt = format;
pub const formatAst = formatAstImpl;

fn formatAstImpl(allocator: Allocator, arena: *ast.AstArena, module_node: ast.NodeIdx, source: []const u8) ![]u8 {
    var f = Fmt.init(allocator, source, arena);
    defer f.deinit();
    try f.fmtModule(module_node);
    return f.out.toOwnedSlice(allocator);
}

const Fmt = struct {
    allocator: Allocator,
    source: []const u8,
    arena: *ast.AstArena,
    out: std.ArrayList(u8),
    indent: usize = 0,
    line_start: bool = true,

    fn init(allocator: Allocator, source: []const u8, arena: *ast.AstArena) Fmt {
        return .{
            .allocator = allocator,
            .source = source,
            .arena = arena,
            .out = .empty,
        };
    }

    fn deinit(self: *Fmt) void {
        self.out.deinit(self.allocator);
    }

    fn ensureIndent(self: *Fmt) anyerror!void {
        if (self.line_start) {
            var i: usize = 0;
            while (i < self.indent * 4) : (i += 1) {
                try self.out.append(self.allocator, ' ');
            }
            self.line_start = false;
        }
    }

    fn write(self: *Fmt, s: []const u8) anyerror!void {
        try self.ensureIndent();
        try self.out.appendSlice(self.allocator, s);
    }

    fn writeFmt(self: *Fmt, comptime f: []const u8, args: anytype) anyerror!void {
        const buf = try std.fmt.allocPrint(self.allocator, f, args);
        defer self.allocator.free(buf);
        try self.write(buf);
    }

    fn newline(self: *Fmt) anyerror!void {
        try self.out.append(self.allocator, '\n');
        self.line_start = true;
    }

    // ---- module ----

    fn fmtModule(self: *Fmt, module_node: ast.NodeIdx) anyerror!void {
        const mod = self.arena.get(module_node);
        const decls = mod.module.decls.indices;
        var prev_import = false;
        for (decls, 0..) |decl, i| {
            const curr_import = self.nodeIsImport(decl);
            if (i > 0) {
                if (prev_import and curr_import) {
                    try self.newline();
                } else {
                    try self.newline();
                    try self.newline();
                }
            }
            try self.fmtDecl(decl);
            prev_import = curr_import;
        }
        if (decls.len > 0) try self.newline();
    }

    fn nodeIsImport(self: *Fmt, idx: ast.NodeIdx) bool {
        const node = self.arena.get(idx);
        return node.* == .import_decl;
    }

    // ---- declarations ----

    fn fmtDecl(self: *Fmt, idx: ast.NodeIdx) anyerror!void {
        const node = self.arena.get(idx);
        switch (node.*) {
            .fn_decl => |f| try self.fmtFnDecl(f),
            .struct_decl => |s| try self.fmtStructDecl(s),
            .enum_decl => |e| try self.fmtEnumDecl(e),
            .import_decl => |imp| try self.fmtImportDecl(imp),
            .let_stmt => |l| try self.fmtLetStmt(l),
            .comptime_expr => |inner| {
                try self.write("comptime ");
                try self.fmtExpr(inner);
            },
            .comptime_block => |inner| {
                try self.write("comptime ");
                try self.fmtBlock(inner);
            },
            .test_decl => |t| {
                try self.write("test");
                if (t.name) |sr| {
                    try self.write(" ");
                    try self.write(sr.slice(self.source));
                }
                try self.write(" ");
                try self.fmtBlock(t.body);
            },
            else => {},
        }
    }

    fn fmtFnDecl(self: *Fmt, f: anytype) anyerror!void {
        try self.write("fn ");
        try self.write(f.name.slice(self.source));
        if (f.generic_params.indices.len > 0) {
            try self.write("[");
            for (f.generic_params.indices, 0..) |g, i| {
                if (i > 0) try self.write(", ");
                const gn = self.arena.get(g);
                if (gn.* == .identifier) try self.write(gn.identifier.slice(self.source));
            }
            try self.write("]");
        }
        try self.write("(");
        for (f.params.indices, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            const pn = self.arena.get(p);
            if (pn.* == .param) {
                try self.write(pn.param.name.slice(self.source));
                try self.write(": ");
                try self.fmtExpr(pn.param.ty);
            }
        }
        try self.write(")");
        if (f.return_type) |rt| {
            try self.write(" -> ");
            try self.fmtExpr(rt);
        }
        const body_node = self.arena.get(f.body);
        if (body_node.* == .return_stmt) {
            try self.write(" =");
            if (body_node.return_stmt.value) |v| {
                try self.write(" ");
                try self.fmtExpr(v);
            }
        } else {
            try self.write(" ");
            try self.fmtBlock(f.body);
        }
    }

    fn fmtStructDecl(self: *Fmt, s: anytype) anyerror!void {
        try self.write("struct ");
        try self.write(s.name.slice(self.source));
        if (s.generic_params.indices.len > 0) {
            try self.write("[");
            for (s.generic_params.indices, 0..) |g, i| {
                if (i > 0) try self.write(", ");
                const gn = self.arena.get(g);
                if (gn.* == .identifier) try self.write(gn.identifier.slice(self.source));
            }
            try self.write("]");
        }
        try self.write(" {");
        if (s.fields.indices.len > 0) {
            try self.newline();
            self.indent += 1;
            for (s.fields.indices) |field_idx| {
                try self.indentLine();
                const fn_ = self.arena.get(field_idx);
                if (fn_.* == .field) {
                    try self.write(fn_.field.name.slice(self.source));
                    try self.write(": ");
                    try self.fmtTypeRepr(fn_.field.ty);
                    try self.write(",");
                    try self.newline();
                }
            }
            self.indent -= 1;
            try self.indentLine();
            try self.write("}");
        } else {
            try self.write(" }");
        }
    }

    fn indentLine(self: *Fmt) anyerror!void {
        try self.ensureIndent();
    }

    fn fmtEnumDecl(self: *Fmt, e: anytype) anyerror!void {
        try self.write("enum ");
        try self.write(e.name.slice(self.source));
        if (e.generic_params.indices.len > 0) {
            try self.write("[");
            for (e.generic_params.indices, 0..) |g, i| {
                if (i > 0) try self.write(", ");
                const gn = self.arena.get(g);
                if (gn.* == .identifier) try self.write(gn.identifier.slice(self.source));
            }
            try self.write("]");
        }
        try self.write(" {");
        if (e.variants.indices.len > 0) {
            try self.newline();
            self.indent += 1;
            for (e.variants.indices) |v| {
                try self.indentLine();
                const vn = self.arena.get(v);
                if (vn.* == .enum_variant) {
                    try self.write(vn.enum_variant.name.slice(self.source));
                    if (vn.enum_variant.fields.indices.len > 0) {
                        try self.write("(");
                        for (vn.enum_variant.fields.indices, 0..) |f, i| {
                            if (i > 0) try self.write(", ");
                            try self.fmtExpr(f);
                        }
                        try self.write(")");
                    }
                    try self.write(",");
                    try self.newline();
                }
            }
            self.indent -= 1;
            try self.indentLine();
            try self.write("}");
        } else {
            try self.write(" }");
        }
    }

    fn fmtImportDecl(self: *Fmt, imp: anytype) anyerror!void {
        try self.write("import ");
        for (imp.path.indices, 0..) |p, i| {
            if (i > 0) try self.write("::");
            const pn = self.arena.get(p);
            if (pn.* == .identifier) try self.write(pn.identifier.slice(self.source));
        }
        if (imp.alias) |a| {
            try self.write(" as ");
            try self.write(a.slice(self.source));
        }
    }

    fn fmtLetStmt(self: *Fmt, l: anytype) anyerror!void {
        if (l.mutable) try self.write("mut ") else try self.write("let ");
        try self.write(l.name.slice(self.source));
        if (l.ty) |t| {
            try self.write(": ");
            try self.fmtExpr(t);
        }
        if (l.init_expr) |e| {
            try self.write(" = ");
            try self.fmtExpr(e);
        }
    }

    fn fmtBlock(self: *Fmt, idx: ast.NodeIdx) anyerror!void {
        const node = self.arena.get(idx);
        if (node.* != .block) {
            try self.fmtExpr(idx);
            return;
        }
        const blk = node.block;
        try self.write("{");
        if (blk.stmts.indices.len == 0) {
            try self.write("}");
            return;
        }
        try self.newline();
        self.indent += 1;
        for (blk.stmts.indices) |s| {
            try self.indentLine();
            try self.fmtStmt(s);
            try self.newline();
        }
        self.indent -= 1;
        try self.indentLine();
        try self.write("}");
    }

    fn fmtStmt(self: *Fmt, idx: ast.NodeIdx) anyerror!void {
        const node = self.arena.get(idx);
        switch (node.*) {
            .let_stmt => |l| try self.fmtLetStmt(l),
            .return_stmt => |r| {
                try self.write("return");
                if (r.value) |v| {
                    try self.write(" ");
                    try self.fmtExpr(v);
                }
            },
            .break_stmt => |control| {
                try self.write("break");
                if (control.label) |label| {
                    try self.write(" ");
                    try self.write(label.slice(self.source));
                }
            },
            .continue_stmt => |control| {
                try self.write("continue");
                if (control.label) |label| {
                    try self.write(" ");
                    try self.write(label.slice(self.source));
                }
            },
            .unreachable_stmt => try self.write("unreachable"),
            .expr_stmt => |e| try self.fmtExpr(e.expr),
            .defer_stmt => |d| {
                try self.write("defer ");
                try self.fmtExpr(d.expr);
            },
            .block => |b| {
                _ = b;
                try self.fmtBlock(idx);
            },
            .if_expr => |i| try self.fmtIfExpr(i),
            .while_expr => |w| {
                if (w.label) |label| {
                    try self.write(label.slice(self.source));
                    try self.write(": ");
                }
                try self.write("while ");
                try self.fmtExpr(w.cond);
                try self.write(" ");
                try self.fmtBlock(w.body);
            },
            .for_range => |fr| {
                if (fr.label) |label| {
                    try self.write(label.slice(self.source));
                    try self.write(": ");
                }
                try self.write("for ");
                try self.write(fr.var_name.slice(self.source));
                try self.write(" in ");
                try self.fmtExpr(fr.start);
                try self.write("..");
                try self.fmtExpr(fr.end);
                try self.write(" ");
                try self.fmtBlock(fr.body);
            },
            .for_each => |fe| {
                if (fe.label) |label| {
                    try self.write(label.slice(self.source));
                    try self.write(": ");
                }
                try self.write("for ");
                try self.write(fe.var_name.slice(self.source));
                try self.write(" in ");
                try self.fmtExpr(fe.iterable);
                try self.write(" ");
                try self.fmtBlock(fe.body);
            },
            .match_expr => |m| try self.fmtMatchExpr(m),
            else => {},
        }
    }

    fn fmtIfExpr(self: *Fmt, i: anytype) anyerror!void {
        try self.write("if ");
        try self.fmtExpr(i.cond);
        try self.write(" ");
        try self.fmtBlock(i.then_body);
        if (i.else_body) |eb| {
            const en = self.arena.get(eb);
            if (en.* == .if_expr) {
                try self.write(" else ");
                try self.fmtIfExpr(en.if_expr);
            } else {
                try self.write(" else ");
                try self.fmtBlock(eb);
            }
        }
    }

    fn fmtMatchExpr(self: *Fmt, m: anytype) anyerror!void {
        try self.write("match ");
        try self.fmtExpr(m.scrutinee);
        try self.write(" {");
        if (m.arms.indices.len > 0) {
            try self.newline();
            self.indent += 1;
            for (m.arms.indices) |a| {
                try self.indentLine();
                const an = self.arena.get(a);
                if (an.* == .match_arm) {
                    try self.fmtExpr(an.match_arm.pattern);
                    if (an.match_arm.guard) |g| {
                        try self.write(" if ");
                        try self.fmtExpr(g);
                    }
                    try self.write(" => ");
                    const body_node = self.arena.get(an.match_arm.body);
                    if (body_node.* == .block) {
                        try self.fmtBlock(an.match_arm.body);
                    } else {
                        try self.fmtExpr(an.match_arm.body);
                    }
                    try self.write(",");
                    try self.newline();
                }
            }
            self.indent -= 1;
            try self.indentLine();
            try self.write("}");
        } else {
            try self.write(" }");
        }
    }

    // ---- expressions ----

    fn fmtExpr(self: *Fmt, idx: ast.NodeIdx) anyerror!void {
        const node = self.arena.get(idx);
        switch (node.*) {
            .int_literal => |v| try self.writeFmt("{d}", .{v}),
            .float_literal => |v| {
                const buf = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
                defer self.allocator.free(buf);
                try self.write(buf);
                if (std.mem.indexOfAny(u8, buf, ".eE") == null) {
                    try self.write(".0");
                }
            },
            .string_literal => |sr| try self.write(sr.slice(self.source)),
            .char_literal => |sr| try self.write(sr.slice(self.source)),
            .bool_literal => |b| try self.write(if (b) "true" else "false"),
            .null_literal => try self.write("null"),
            .identifier => |sr| try self.write(sr.slice(self.source)),
            .fn_ref => |sr| try self.write(sr.slice(self.source)),
            .binary_op => |b| try self.fmtBinary(b),
            .unary_op => |u| try self.fmtUnary(u),
            .call => |c| try self.fmtCall(c),
            .field_access => |fa| {
                try self.fmtExprWrapped(fa.object, 15);
                try self.write(".");
                try self.write(fa.field.slice(self.source));
            },
            .index_access => |ia| {
                try self.fmtExprWrapped(ia.object, 15);
                try self.write("[");
                try self.fmtExpr(ia.index);
                try self.write("]");
            },
            .generic_app => |ga| {
                try self.fmtExprWrapped(ga.base, 15);
                try self.write("[");
                for (ga.args.indices, 0..) |a, i| {
                    if (i > 0) try self.write(", ");
                    try self.fmtExpr(a);
                }
                try self.write("]");
            },
            .paren_expr => |inner| {
                try self.write("(");
                try self.fmtExpr(inner);
                try self.write(")");
            },
            .struct_init => |si| try self.fmtStructInit(si),
            .range_expr => |r| {
                try self.fmtExprWrapped(r.start, 2);
                try self.write("..");
                try self.fmtExprWrapped(r.end, 2);
            },
            .fn_type => |ft| try self.fmtFnType(ft),
            .closure => |cl| try self.fmtClosure(cl),
            .comptime_block => |inner| {
                try self.write("comptime ");
                try self.fmtBlock(inner);
            },
            .comptime_expr => |inner| {
                try self.write("comptime ");
                try self.fmtExpr(inner);
            },
            .if_expr => |i| try self.fmtIfExpr(i),
            .match_expr => |m| try self.fmtMatchExpr(m),
            .pipeline => |p| {
                try self.fmtExprWrapped(p.lhs, 1);
                try self.write(" |> ");
                try self.fmtExprWrapped(p.rhs, 2);
            },
            .try_propagate => |inner| {
                try self.fmtExprWrapped(inner, 15);
                try self.write("?");
            },
            .region_expr => |r| try self.fmtRegion(r),
            .move_expr => |inner| {
                try self.write("move ");
                try self.fmtExprWrapped(inner, 14);
            },
            .comptime_call => |cc| {
                try self.write("@");
                try self.write(cc.name.slice(self.source));
                try self.write("(");
                for (cc.args.indices, 0..) |a, i| {
                    if (i > 0) try self.write(", ");
                    try self.fmtExpr(a);
                }
                try self.write(")");
            },
            .block => |blk| {
                _ = blk;
                try self.fmtBlock(idx);
            },
            else => {},
        }
    }

    fn fmtExprWrapped(self: *Fmt, idx: ast.NodeIdx, threshold: i32) anyerror!void {
        if (self.nodePrec(idx) < threshold) {
            try self.write("(");
            try self.fmtExpr(idx);
            try self.write(")");
        } else {
            try self.fmtExpr(idx);
        }
    }

    fn nodePrec(self: *Fmt, idx: ast.NodeIdx) i32 {
        const node = self.arena.get(idx);
        return switch (node.*) {
            .binary_op => |b| self.binaryPrec(b.op),
            .range_expr => 2,
            .pipeline => 1,
            .unary_op => 14,
            .move_expr => 14,
            .try_propagate => 15,
            .call, .field_access, .index_access, .generic_app => 15,
            else => 16,
        };
    }

    fn binaryPrec(self: *Fmt, op: ast.BinaryOp) i32 {
        _ = self;
        return switch (op) {
            .assign, .add_assign, .sub_assign, .mul_assign, .div_assign => 3,
            .or_op => 4,
            .and_op => 5,
            .bit_or => 6,
            .bit_xor => 7,
            .bit_and => 8,
            .eq, .ne => 9,
            .lt, .gt, .le, .ge => 10,
            .shift_left, .shift_right => 11,
            .add, .sub => 12,
            .mul, .div, .mod => 13,
            .range => 2,
        };
    }

    fn isRightAssoc(op: ast.BinaryOp) bool {
        return switch (op) {
            .assign, .add_assign, .sub_assign, .mul_assign, .div_assign => true,
            else => false,
        };
    }

    fn binOpStr(op: ast.BinaryOp) []const u8 {
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

    fn fmtBinary(self: *Fmt, b: anytype) anyerror!void {
        const cp = self.binaryPrec(b.op);
        const right_assoc = isRightAssoc(b.op);

        // left
        const left_prec = self.nodePrec(b.left);
        var wrap_left = left_prec < cp;
        if (!wrap_left and left_prec == cp and right_assoc) wrap_left = true;
        if (wrap_left) {
            try self.write("(");
            try self.fmtExpr(b.left);
            try self.write(")");
        } else {
            try self.fmtExpr(b.left);
        }

        if (b.op == .range) {
            try self.write("..");
        } else {
            try self.write(" ");
            try self.write(binOpStr(b.op));
            try self.write(" ");
        }

        // right
        const right_prec = self.nodePrec(b.right);
        var wrap_right = right_prec < cp;
        if (!wrap_right and right_prec == cp and !right_assoc) wrap_right = true;
        if (wrap_right) {
            try self.write("(");
            try self.fmtExpr(b.right);
            try self.write(")");
        } else {
            try self.fmtExpr(b.right);
        }
    }

    fn fmtUnary(self: *Fmt, u: anytype) anyerror!void {
        const opstr = switch (u.op) {
            .neg => "-",
            .not => "!",
            .bit_not => "~",
            .ref => "&",
            .mut_ref => "&mut ",
        };
        try self.write(opstr);
        try self.fmtExprWrapped(u.operand, 14);
    }

    fn fmtCall(self: *Fmt, c: anytype) anyerror!void {
        try self.fmtExprWrapped(c.func, 15);
        try self.write("(");
        for (c.args.indices, 0..) |a, i| {
            if (i > 0) try self.write(", ");
            try self.fmtExpr(a);
        }
        try self.write(")");
    }

    fn fmtStructInit(self: *Fmt, si: anytype) anyerror!void {
        try self.fmtExprWrapped(si.ty, 15);
        try self.write("{");
        if (si.fields.indices.len > 0) {
            try self.write(" ");
            for (si.fields.indices, 0..) |f, i| {
                if (i > 0) try self.write(", ");
                const fn_ = self.arena.get(f);
                if (fn_.* == .struct_init_field) {
                    try self.write(".");
                    try self.write(fn_.struct_init_field.name.slice(self.source));
                    try self.write(" = ");
                    try self.fmtExpr(fn_.struct_init_field.value);
                }
            }
            try self.write(" ");
        }
        try self.write("}");
    }

    fn fmtFnType(self: *Fmt, ft: anytype) anyerror!void {
        try self.write("fn(");
        for (ft.params.indices, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            try self.fmtExpr(p);
        }
        try self.write(") -> ");
        try self.fmtExpr(ft.return_type);
    }

    fn fmtClosure(self: *Fmt, cl: anytype) anyerror!void {
        try self.write("|");
        for (cl.params.indices, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            const pn = self.arena.get(p);
            if (pn.* == .param) {
                try self.write(pn.param.name.slice(self.source));
                if (pn.param.ty != ast.NodeIdx.none) {
                    try self.write(": ");
                    try self.fmtExpr(pn.param.ty);
                }
            }
        }
        try self.write("|");
        const body_node = self.arena.get(cl.body);
        if (body_node.* == .block) {
            const blk = body_node.block;
            try self.write(" {");
            for (blk.stmts.indices, 0..) |s, i| {
                if (i > 0) try self.write(";");
                try self.write(" ");
                try self.fmtStmt(s);
            }
            try self.write(" }");
        } else {
            try self.write(" ");
            try self.fmtExpr(cl.body);
        }
    }

    fn fmtRegion(self: *Fmt, r: anytype) anyerror!void {
        try self.write("region ");
        try self.write(r.name.slice(self.source));
        if (r.allocator) |a| {
            if (a != ast.NodeIdx.none) {
                try self.write(": ");
                try self.fmtExpr(a);
            }
        }
        try self.write(" ");
        try self.fmtBlock(r.body);
    }

    fn fmtTypeRepr(self: *Fmt, ty: ast.TypeRepr) anyerror!void {
        switch (ty) {
            .plain => |n| try self.fmtExpr(n),
            .reference => |n| {
                try self.write("&");
                try self.fmtExpr(n);
            },
            .mut_reference => |n| {
                try self.write("&mut ");
                try self.fmtExpr(n);
            },
        }
    }
};
