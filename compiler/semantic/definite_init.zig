const std = @import("std");
const ast = @import("../parser/ast.zig");
const diag = @import("../diagnostics.zig");

const Allocator = std.mem.Allocator;
const AstArena = ast.AstArena;
const NodeIdx = ast.NodeIdx;
const NodeList = ast.NodeList;
const StringRef = ast.StringRef;
const BinaryOp = ast.BinaryOp;

const InitState = enum {
    uninitialized,
    maybe_initialized,
    initialized,
};

const StateMap = std.AutoHashMapUnmanaged(NodeIdx, InitState);

const Binding = struct {
    decl_node: NodeIdx,
    closure_depth: usize,
};

const Scope = struct {
    bindings: std.StringHashMapUnmanaged(Binding) = .empty,
};

const Flow = struct {
    states: StateMap = .empty,
    reachable: bool = false,

    fn deinit(self: *Flow, allocator: Allocator) void {
        self.states.deinit(allocator);
        self.states = .empty;
    }
};

/// Check that every read of a delayed local binding is dominated by an
/// assignment on every path that can reach it. The pass runs on the original
/// AST, before generic instantiation, because initialization is independent of
/// the types substituted into a generic body.
pub fn check(
    allocator: Allocator,
    arena: *AstArena,
    source: []const u8,
    diagnostics: *diag.Diagnostics,
    module_node: NodeIdx,
) void {
    var analyzer = Analyzer{
        .allocator = allocator,
        .arena = arena,
        .source = source,
        .diagnostics = diagnostics,
        .module_node = module_node,
    };
    defer analyzer.deinit();
    analyzer.checkModule();
}

const Analyzer = struct {
    allocator: Allocator,
    arena: *AstArena,
    source: []const u8,
    diagnostics: *diag.Diagnostics,
    module_node: NodeIdx,

    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    states: StateMap = .empty,
    reachable: bool = true,
    closure_depth: usize = 0,

    fn deinit(self: *Analyzer) void {
        for (self.scopes.items) |*scope| scope.bindings.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.states.deinit(self.allocator);
    }

    fn nameSlice(self: *const Analyzer, ref: StringRef) []const u8 {
        return ref.slice(self.source);
    }

    fn errorAt(self: *Analyzer, node: NodeIdx, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch |err| {
            std.debug.panic("OOM in definite-initialization checker: {s}", .{@errorName(err)});
        };
        const loc = diag.locationFromNode(self.arena, self.source, node);
        self.diagnostics.add(.@"error", .semantic, msg, loc) catch {};
    }

    fn pushScope(self: *Analyzer) void {
        self.scopes.append(self.allocator, .{}) catch @panic("OOM");
    }

    fn popScope(self: *Analyzer) void {
        var scope = self.scopes.pop() orelse unreachable;
        scope.bindings.deinit(self.allocator);
    }

    fn declare(self: *Analyzer, name: StringRef, decl_node: NodeIdx, state: InitState) void {
        const text = self.nameSlice(name);
        if (std.mem.eql(u8, text, "_")) return;
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        scope.bindings.put(self.allocator, text, .{
            .decl_node = decl_node,
            .closure_depth = self.closure_depth,
        }) catch @panic("OOM");
        self.states.put(self.allocator, decl_node, state) catch @panic("OOM");
    }

    fn lookup(self: *const Analyzer, name: []const u8) ?Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].bindings.get(name)) |binding| return binding;
        }
        return null;
    }

    fn cloneStates(self: *const Analyzer) StateMap {
        return self.states.clone(self.allocator) catch @panic("OOM");
    }

    fn captureFlow(self: *const Analyzer) Flow {
        return .{ .states = self.cloneStates(), .reachable = self.reachable };
    }

    fn takeFlow(self: *Analyzer) Flow {
        const flow = Flow{ .states = self.states, .reachable = self.reachable };
        self.states = .empty;
        return flow;
    }

    fn restoreFlow(self: *Analyzer, flow: *Flow) void {
        self.states.deinit(self.allocator);
        self.states = flow.states;
        flow.states = .empty;
        self.reachable = flow.reachable;
    }

    fn restoreClone(self: *Analyzer, flow: Flow) void {
        self.states.deinit(self.allocator);
        self.states = flow.states.clone(self.allocator) catch @panic("OOM");
        self.reachable = flow.reachable;
    }

    fn mergeState(a: InitState, b: InitState) InitState {
        if (a == b) return a;
        return .maybe_initialized;
    }

    /// Add one reachable control-flow path to the accumulated result. A binding
    /// is initialized after a join only when every reachable incoming path
    /// agrees that it is initialized.
    fn mergeInto(self: *Analyzer, destination: *Flow, source: *Flow) void {
        if (!source.reachable) return;
        if (!destination.reachable) {
            destination.states.deinit(self.allocator);
            destination.states = source.states;
            source.states = .empty;
            destination.reachable = true;
            return;
        }

        var it = source.states.iterator();
        while (it.next()) |entry| {
            if (destination.states.getPtr(entry.key_ptr.*)) |current| {
                current.* = mergeState(current.*, entry.value_ptr.*);
            } else {
                destination.states.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*) catch @panic("OOM");
            }
        }
    }

    fn checkModule(self: *Analyzer) void {
        self.pushScope();
        defer self.popScope();

        const module = self.arena.get(self.module_node).module;
        for (module.decls.indices) |decl_idx| {
            const decl = self.arena.get(decl_idx);
            switch (decl.*) {
                .fn_decl => |f| self.checkBoundary(f.params, f.body),
                .test_decl => |t| self.checkBoundary(.{ .indices = &.{} }, t.body),
                else => {},
            }
        }
    }

    /// Functions and closures are independent control-flow boundaries. Their
    /// bodies start with the bindings visible at creation, but assignments in
    /// the body cannot initialize anything for the enclosing continuation.
    fn checkBoundary(self: *Analyzer, params: NodeList, body: NodeIdx) void {
        var saved = self.takeFlow();
        self.states = saved.states.clone(self.allocator) catch @panic("OOM");
        self.reachable = saved.reachable;
        self.closure_depth += 1;
        defer {
            self.states.deinit(self.allocator);
            self.states = saved.states;
            self.reachable = saved.reachable;
            self.closure_depth -= 1;
        }

        self.pushScope();
        defer self.popScope();
        for (params.indices) |param_idx| {
            const param = self.arena.get(param_idx).param;
            self.declare(param.name, param_idx, .initialized);
        }
        if (body != .none) self.checkExpr(body);
    }

    fn reportUninitializedRead(self: *Analyzer, site: NodeIdx, binding: Binding, state: InitState) void {
        const name = self.storageName(binding.decl_node);
        const captured = binding.closure_depth < self.closure_depth;
        switch (state) {
            .initialized => {},
            .uninitialized => if (captured)
                self.errorAt(site, "cannot capture uninitialized binding '{s}' in a closure", .{name})
            else
                self.errorAt(site, "use of uninitialized binding '{s}'", .{name}),
            .maybe_initialized => if (captured)
                self.errorAt(site, "cannot capture possibly uninitialized binding '{s}' in a closure", .{name})
            else
                self.errorAt(site, "use of possibly uninitialized binding '{s}'; not every path assigns it before this use", .{name}),
        }
    }

    fn readIdentifier(self: *Analyzer, expr_idx: NodeIdx) void {
        const id = self.arena.get(expr_idx).identifier;
        const name = self.nameSlice(id);
        if (std.mem.eql(u8, name, "_")) return;
        const binding = self.lookup(name) orelse return;
        const state = self.states.get(binding.decl_node) orelse return;
        self.reportUninitializedRead(expr_idx, binding, state);
    }

    fn directBinding(self: *const Analyzer, target: NodeIdx) ?Binding {
        const node = self.arena.get(target);
        return switch (node.*) {
            .identifier => |id| self.lookup(self.nameSlice(id)),
            .paren_expr => |inner| self.directBinding(inner),
            else => null,
        };
    }

    fn markAssigned(self: *Analyzer, target: NodeIdx) void {
        const binding = self.directBinding(target) orelse return;
        if (self.states.get(binding.decl_node)) |state| {
            if (state != .initialized and binding.closure_depth < self.closure_depth) {
                self.reportUninitializedRead(target, binding, state);
            }
        }
        self.states.put(self.allocator, binding.decl_node, .initialized) catch @panic("OOM");
    }

    fn storageName(self: *const Analyzer, storage: NodeIdx) []const u8 {
        const node = self.arena.get(storage);
        return switch (node.*) {
            .let_stmt => |l| self.nameSlice(l.name),
            .param => |p| self.nameSlice(p.name),
            .for_range => |f| self.nameSlice(f.var_name),
            .for_each => |f| self.nameSlice(f.var_name),
            .identifier => |id| self.nameSlice(id),
            else => "<local>",
        };
    }

    fn checkBlock(self: *Analyzer, block: ast.Node) void {
        self.pushScope();
        defer self.popScope();
        for (block.block.stmts.indices) |stmt| {
            if (!self.reachable) break;
            self.checkStmt(stmt);
        }
    }

    fn checkStmt(self: *Analyzer, stmt_idx: NodeIdx) void {
        if (!self.reachable) return;
        const stmt = self.arena.get(stmt_idx);
        switch (stmt.*) {
            .block => self.checkBlock(stmt.*),
            .let_stmt => |l| {
                if (l.init_expr) |init| {
                    self.checkExpr(init);
                } else if (l.ty == null) {
                    self.errorAt(stmt_idx, "uninitialized binding '{s}' requires a type annotation", .{self.nameSlice(l.name)});
                }
                self.declare(l.name, stmt_idx, if (l.init_expr == null) .uninitialized else .initialized);
            },
            .return_stmt => |r| {
                if (r.value) |value| self.checkExpr(value);
                self.reachable = false;
            },
            .break_stmt, .continue_stmt, .unreachable_stmt => self.reachable = false,
            .expr_stmt => |e| self.checkExpr(e.expr),
            .defer_stmt => |d| self.checkExpr(d.expr),
            .if_expr => self.checkIf(stmt_idx),
            .while_expr => self.checkWhile(stmt_idx),
            .for_range, .for_each => self.checkFor(stmt_idx),
            .match_expr => self.checkMatch(stmt_idx),
            .fn_decl => |f| self.checkBoundary(f.params, f.body),
            .test_decl => |t| self.checkBoundary(.{ .indices = &.{} }, t.body),
            else => self.checkExpr(stmt_idx),
        }
    }

    fn checkExpr(self: *Analyzer, expr_idx: NodeIdx) void {
        if (!self.reachable) return;
        const expr = self.arena.get(expr_idx);
        switch (expr.*) {
            .int_literal,
            .float_literal,
            .string_literal,
            .char_literal,
            .bool_literal,
            .null_literal,
            .fn_ref,
            .fn_type,
            => {},
            .identifier => self.readIdentifier(expr_idx),
            .binary_op => |b| self.checkBinary(b.op, b.left, b.right),
            .unary_op => |u| self.checkExpr(u.operand),
            .deref,
            .paren_expr,
            .try_propagate,
            .move_expr,
            .comptime_expr,
            => |inner| self.checkExpr(inner),
            .call => |c| {
                self.checkExpr(c.func);
                for (c.args.indices) |arg| self.checkExpr(arg);
            },
            .field_access => |f| self.checkExpr(f.object),
            .index_access => |i| {
                self.checkExpr(i.object);
                self.checkExpr(i.index);
            },
            .generic_app => |g| self.checkExpr(g.base),
            .struct_init => |s| {
                for (s.fields.indices) |field_idx| {
                    self.checkExpr(self.arena.get(field_idx).struct_init_field.value);
                }
            },
            .range_expr => |r| {
                self.checkExpr(r.start);
                self.checkExpr(r.end);
            },
            .closure => |c| self.checkBoundary(c.params, c.body),
            .comptime_block => |inner| self.checkStmt(inner),
            .comptime_call => |c| {
                for (c.args.indices) |arg| self.checkExpr(arg);
            },
            .pipeline => |p| {
                self.checkExpr(p.lhs);
                self.checkExpr(p.rhs);
            },
            .region_expr => |r| self.checkStmt(r.body),
            .block,
            .if_expr,
            .while_expr,
            .for_range,
            .for_each,
            .match_expr,
            .let_stmt,
            .return_stmt,
            .break_stmt,
            .continue_stmt,
            .unreachable_stmt,
            .expr_stmt,
            .defer_stmt,
            .fn_decl,
            .test_decl,
            => self.checkStmt(expr_idx),
            .param,
            .field,
            .enum_variant,
            .match_arm,
            .struct_init_field,
            .module,
            .struct_decl,
            .enum_decl,
            .import_decl,
            => {},
        }
    }

    fn checkBinary(self: *Analyzer, op: BinaryOp, left: NodeIdx, right: NodeIdx) void {
        if (op == .assign) {
            // A direct `x = value` is x's initializing write, not a read. Every
            // other lvalue form must read its existing base storage/address.
            if (self.directBinding(left) == null) self.checkExpr(left);
            self.checkExpr(right);
            self.markAssigned(left);
            return;
        }
        if (op == .add_assign or op == .sub_assign or op == .mul_assign or op == .div_assign) {
            self.checkExpr(left);
            self.checkExpr(right);
            return;
        }
        if (op == .and_op or op == .or_op) {
            self.checkExpr(left);
            if (!self.reachable) return;
            var short_circuit = self.captureFlow();
            defer short_circuit.deinit(self.allocator);
            self.checkExpr(right);
            var evaluated_right = self.takeFlow();
            defer evaluated_right.deinit(self.allocator);

            var merged = Flow{};
            self.mergeInto(&merged, &short_circuit);
            self.mergeInto(&merged, &evaluated_right);
            self.restoreFlow(&merged);
            return;
        }
        self.checkExpr(left);
        self.checkExpr(right);
    }

    fn checkIf(self: *Analyzer, if_idx: NodeIdx) void {
        const i = self.arena.get(if_idx).if_expr;
        self.checkExpr(i.cond);
        if (!self.reachable) return;

        var entry = self.captureFlow();
        defer entry.deinit(self.allocator);

        self.checkStmt(i.then_body);
        var then_flow = self.takeFlow();
        defer then_flow.deinit(self.allocator);

        self.restoreFlow(&entry);
        if (i.else_body) |else_body| self.checkStmt(else_body);
        var else_flow = self.takeFlow();
        defer else_flow.deinit(self.allocator);

        var merged = Flow{};
        self.mergeInto(&merged, &then_flow);
        self.mergeInto(&merged, &else_flow);
        self.restoreFlow(&merged);
    }

    fn checkWhile(self: *Analyzer, loop_idx: NodeIdx) void {
        const w = self.arena.get(loop_idx).while_expr;
        self.checkExpr(w.cond);
        if (!self.reachable) return;

        // A while body may execute zero times. Its writes are visible to later
        // statements in that body, but are not definite after the loop.
        var entry = self.captureFlow();
        defer entry.deinit(self.allocator);
        self.checkStmt(w.body);
        self.restoreFlow(&entry);
    }

    fn checkFor(self: *Analyzer, loop_idx: NodeIdx) void {
        const loop = self.arena.get(loop_idx);
        switch (loop.*) {
            .for_range => |f| {
                self.checkExpr(f.start);
                self.checkExpr(f.end);
            },
            .for_each => |f| self.checkExpr(f.iterable),
            else => unreachable,
        }
        if (!self.reachable) return;

        var entry = self.captureFlow();
        defer entry.deinit(self.allocator);
        self.pushScope();
        defer self.popScope();
        switch (loop.*) {
            .for_range => |f| self.declare(f.var_name, loop_idx, .initialized),
            .for_each => |f| self.declare(f.var_name, loop_idx, .initialized),
            else => unreachable,
        }
        const body = switch (loop.*) {
            .for_range => |f| f.body,
            .for_each => |f| f.body,
            else => unreachable,
        };
        self.checkStmt(body);
        self.restoreFlow(&entry);
    }

    fn checkMatch(self: *Analyzer, match_idx: NodeIdx) void {
        const m = self.arena.get(match_idx).match_expr;
        self.checkExpr(m.scrutinee);
        if (!self.reachable) return;

        const exhaustive = self.matchIsExhaustive(m.arms);
        var entry = self.captureFlow();
        defer entry.deinit(self.allocator);
        var merged = Flow{};

        for (m.arms.indices) |arm_idx| {
            self.restoreClone(entry);
            const arm = self.arena.get(arm_idx).match_arm;
            self.pushScope();
            self.declareMatchBindings(arm.pattern);
            if (arm.guard) |guard| self.checkExpr(guard);
            self.checkExpr(arm.body);
            self.popScope();

            var arm_flow = self.takeFlow();
            self.mergeInto(&merged, &arm_flow);
            arm_flow.deinit(self.allocator);
        }

        if (!exhaustive) {
            var fallthrough = Flow{
                .states = entry.states.clone(self.allocator) catch @panic("OOM"),
                .reachable = entry.reachable,
            };
            self.mergeInto(&merged, &fallthrough);
            fallthrough.deinit(self.allocator);
        }
        self.restoreFlow(&merged);
    }

    fn matchPatternVariant(self: *const Analyzer, pattern_idx: NodeIdx) ?ast.EnumVariantInfo {
        const pattern = self.arena.get(pattern_idx);
        const name = switch (pattern.*) {
            .identifier => |id| self.nameSlice(id),
            .call => |c| blk: {
                const callee = self.arena.get(c.func);
                if (callee.* != .identifier) return null;
                break :blk self.nameSlice(callee.identifier);
            },
            .paren_expr => |inner| return self.matchPatternVariant(inner),
            else => return null,
        };
        return ast.findEnumVariant(self.arena, self.source, self.module_node, name);
    }

    fn isWildcardPattern(self: *const Analyzer, pattern_idx: NodeIdx) bool {
        const pattern = self.arena.get(pattern_idx);
        return switch (pattern.*) {
            .identifier => |id| std.mem.eql(u8, self.nameSlice(id), "_"),
            .paren_expr => |inner| self.isWildcardPattern(inner),
            else => false,
        };
    }

    fn declareMatchBindings(self: *Analyzer, pattern_idx: NodeIdx) void {
        const info = self.matchPatternVariant(pattern_idx) orelse return;
        const pattern = self.arena.get(pattern_idx);
        if (pattern.* != .call) return;
        const variant = self.arena.get(info.variant_node).enum_variant;
        for (pattern.call.args.indices, 0..) |arg_idx, i| {
            if (i >= variant.fields.indices.len) break;
            const arg = self.arena.get(arg_idx);
            if (arg.* == .identifier) self.declare(arg.identifier, arg_idx, .initialized);
        }
    }

    fn matchIsExhaustive(self: *const Analyzer, arms: NodeList) bool {
        var enum_decl: ?NodeIdx = null;
        var seen: std.AutoHashMapUnmanaged(NodeIdx, void) = .empty;
        defer seen.deinit(self.allocator);

        for (arms.indices) |arm_idx| {
            const arm = self.arena.get(arm_idx).match_arm;
            if (arm.guard != null) continue;
            if (self.isWildcardPattern(arm.pattern)) return true;
            const info = self.matchPatternVariant(arm.pattern) orelse continue;
            if (enum_decl) |selected| {
                if (selected != info.enum_decl) return false;
            } else {
                enum_decl = info.enum_decl;
            }
            seen.put(self.allocator, info.variant_node, {}) catch @panic("OOM");
        }

        const selected = enum_decl orelse return false;
        const declaration = self.arena.get(selected).enum_decl;
        for (declaration.variants.indices) |variant| {
            if (!seen.contains(variant)) return false;
        }
        return true;
    }
};
