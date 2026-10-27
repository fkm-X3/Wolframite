//! AST → Tungsten IR lowering.
//!
//! Walks a type-checked module and drives the Tungsten `api.Context` to build
//! IR: one function per `fn`, a deduplicated string literal pool, and
//! alloca/field-offset lowering for aggregates.
//!
//! Value convention: every W value occupies one 8-byte slot (matching the
//! backend's slot-based codegen). A `String` value is a pointer to a
//! 16-byte `[len][ptr]` block (see `string.zig`); a struct value is a
//! pointer to its stack-allocated block; an enum value is a pointer to its
//! tag-plus-payload block.
//!
//! Known simplifications:
//! - All integer math runs in 64-bit slots; narrow types are not truncated.
//! - Struct copies share the underlying block (no deep copy).
//! - A returned struct/enum/String value is the address of the callee's
//!   stack block; the caller must consume it before the frame is reused, so
//!   aggregates do not yet survive their producing frame.

const std = @import("std");
const api = @import("Tungsten").api;
const ast = @import("../parser/ast.zig");
const diag = @import("../diagnostics.zig");
const types_mod = @import("../semantic/types.zig");
const typecheck_mod = @import("../semantic/typecheck.zig");
const generics_mod = @import("../semantic/generics.zig");
const scope_mod = @import("../semantic/scope.zig");
const prelude = @import("../prelude.zig");
const string_mod = @import("string.zig");

const Allocator = std.mem.Allocator;
const AstArena = ast.AstArena;
const Node = ast.Node;
const NodeIdx = ast.NodeIdx;
const NodeList = ast.NodeList;
const StringRef = ast.StringRef;
const BinaryOp = ast.BinaryOp;
const TypePool = types_mod.TypePool;
const TypeIdx = types_mod.TypeIdx;
const SemType = types_mod.SemType;
const GenericInstance = generics_mod.GenericInstance;

/// A name binding inside a function body.
/// `value` is the SSA value (parameters) or slot pointer (locals);
/// `ty` is the semantic type, resolved from the checker's cached node types.
const Binding = struct {
    value: api.Value,
    ty: TypeIdx,
    /// The materialized composition this binding holds, if any (R31b).
    materialized: ?Materialized = null,
};

/// A statically known module-level `fn` a composition calls directly.
const DirectFn = struct {
    /// The callee's IR function index.
    fidx: api.FunctionIdx,
    /// The IR type of the callee's result.
    ret: api.TypeIdx,
    /// The IR `function_value` type of the callee — the type of the fn
    /// value a call to it produces.
    fv_ty: api.TypeIdx,
};

/// One operand of a composition (R31): the function the expansion applies.
const Operand = union(enum) {
    /// A statically known module-level `fn`: the expansion calls it
    /// directly, with a null env (R31b).
    direct: DirectFn,
    /// A fn value: the expansion calls it through `call_ptr` (R16c).
    fn_value: struct {
        /// The operand's value: the address of its `{ fn_ptr, env_ptr }`
        /// record.
        value: api.Value,
        /// The IR `function_value` type of the value.
        fv_ty: api.TypeIdx,
        /// The IR type of the callee's result.
        ret: api.TypeIdx,
    },
};

/// One capture of a lifted composition closure (R31): how the lifted body
/// reads it back out of the env record.
const Capture = union(enum) {
    /// A statically known module-level `fn`: the lifted body calls it
    /// directly and it takes no env space (R31b).
    direct: DirectFn,
    /// A fn value captured by value: 16 bytes inline in the env record, and
    /// the body calls it through `call_ptr`.
    fn_value: struct {
        /// The IR `function_value` type of the captured fn.
        fv_ty: api.TypeIdx,
        /// The IR type of the captured fn's result.
        ret: api.TypeIdx,
    },
    /// A plain value: 8 bytes inline in the env record. The payload is the
    /// IR type of the captured value.
    value: api.TypeIdx,
};

/// Byte size of one capture in an env record: a fn value stores its 16-byte
/// record inline, a plain value one 8-byte slot, and a statically known fn
/// nothing at all — it is called directly and needs no env slot (R31b).
fn captureSize(cap: Capture) u64 {
    return switch (cap) {
        .direct => 0,
        .fn_value => api.fn_value_size,
        .value => 8,
    };
}

/// One capture at its creation site: the layout the lifted body expects and
/// the value the env record copies into it.
const EnvSlot = struct {
    capture: Capture,
    value: api.Value,
};

/// The body of a lifted composition closure (R31): the source expansion the
/// closure stands for, together with the capture layout its env record uses.
const CompositionBody = union(enum) {
    /// `compose(f, g)`: `|x| f(g(x))`.
    compose: struct { f: Capture, g: Capture },
    /// `curry(f)`: `|a| |b| f(a, b)`. The outer lifted function takes `a`
    /// and returns the inner closure.
    curry_outer: struct {
        f: Capture,
        /// The partially applied argument `a`, captured by the inner
        /// closure.
        a: Capture,
        /// The lifted function that takes `b` and calls `f(a, b)`.
        inner: api.FunctionIdx,
        /// The IR `function_value` type of the inner closure.
        inner_fv_ty: api.TypeIdx,
    },
    /// `curry(f)(a)`: `|b| f(a, b)`.
    curry_inner: struct { f: Capture, a: Capture },
    /// `uncurry(h)`: `|a, b| h(a)(b)`.
    uncurry: struct {
        h: Capture,
        /// The IR type of `h(a)(b)`'s result.
        ret: api.TypeIdx,
    },
};

/// A composition chain in the AST (R31): a prelude composition call
/// together with the arguments its result is applied to.
const CompositionChain = struct {
    /// The expansion shape of the root call.
    shape: prelude.Shape,
    /// The root call's own operands (`compose(f, g)` → `[f, g]`).
    operands: []const NodeIdx,
    /// The arguments the chain applies to the root's result, in evaluation
    /// order (`curry(f)(a)(b)` → `[a, b]`).
    applied: []const NodeIdx,
    /// The root call's node, whose type is the composition's result type.
    root: NodeIdx,
};

/// A composition a local holds, known statically to the lowerer (R31b).
///
/// A materialized composition is a closure whose body the lowerer wrote, so
/// applying it lowers to the expansion's own calls instead of a call through
/// the fn value — and the expansion's env record is built in the frame that
/// applies it, where it stays alive.
const Materialized = union(enum) {
    /// `curry(f)`: the value awaits its first argument. Applying it
    /// materializes the inner closure `|b| f(a, b)` at the application site.
    curry_outer: struct {
        /// The operand the expansion calls.
        f: Operand,
        /// The chain the composition came from: its root node carries the
        /// composition's result type.
        chain: CompositionChain,
    },
    /// `curry(f)(a)`: the value awaits its second argument. Applying it is a
    /// direct call to the lifted inner function with its env record.
    curry_inner: struct {
        /// The lifted inner function.
        fidx: api.FunctionIdx,
        /// The IR type of the call's result.
        ret: api.TypeIdx,
        /// The inner closure's env record.
        env: api.Value,
    },
};

/// What a lowered function's body is. Pass 2 walks `all_functions` and emits
/// the body each entry names.
const FunctionBody = union(enum) {
    /// A declared `fn` (or a monomorphized instance): the declaration node.
    decl: NodeIdx,
    /// A lifted closure literal: the closure node. Its captures come from
    /// the closure's inferred env list.
    closure: NodeIdx,
    /// A lifted composition expansion (R31).
    composition: CompositionBody,
};

pub const Lowerer = struct {
    gpa: Allocator,
    arena: *AstArena,
    source: []const u8,
    type_pool: *TypePool,
    diagnostics: *diag.Diagnostics,
    checker: *typecheck_mod.TypeChecker,
    ctx: *api.Context,
    strings: string_mod.LiteralPool,

    void_ty: api.TypeIdx,
    bool_ty: api.TypeIdx,
    i8_ty: api.TypeIdx,
    i16_ty: api.TypeIdx,
    i32_ty: api.TypeIdx,
    i64_ty: api.TypeIdx,
    u8_ty: api.TypeIdx,
    u16_ty: api.TypeIdx,
    u32_ty: api.TypeIdx,
    u64_ty: api.TypeIdx,
    f32_ty: api.TypeIdx,
    f64_ty: api.TypeIdx,
    ptr_ty: api.TypeIdx,

    /// fn_decl node -> created FunctionIdx.
    fn_by_node: std.AutoHashMapUnmanaged(NodeIdx, api.FunctionIdx),
    /// The lowered functions in creation order, for body lowering. Closure and
    /// composition lifting appends entries during body lowering, so this list
    /// is walked by index and the lifted bodies are lowered in the same pass.
    all_functions: std.ArrayListUnmanaged(struct { body: FunctionBody, idx: api.FunctionIdx }),
    /// Source-order counter for unique lifted-closure function names.
    closure_counter: u32 = 0,
    /// Source-order counter for unique lifted-composition function names.
    composition_counter: u32 = 0,

    /// Function parameters of the current function: name -> binding.
    params: std.StringHashMapUnmanaged(Binding),
    /// Mutable locals of the current function: name -> binding (slot pointer).
    locals: std.StringHashMapUnmanaged(Binding),
    /// Shadowed bindings for scope-aware local binding.
    shadows: std.ArrayListUnmanaged(struct { name: []const u8, prev: ?Binding }),
    /// Deferred expressions, innermost scope last.
    pending_defers: std.ArrayListUnmanaged(NodeIdx),
    /// The composition the expression being lowered materialized, if any
    /// (R31b). The binding that holds it picks it up.
    pending_materialized: ?Materialized = null,

    block_terminated: bool = false,

    pub fn init(
        gpa: Allocator,
        arena: *AstArena,
        source: []const u8,
        type_pool: *TypePool,
        diagnostics: *diag.Diagnostics,
        checker: *typecheck_mod.TypeChecker,
        ctx: *api.Context,
    ) !Lowerer {
        var self = Lowerer{
            .gpa = gpa,
            .arena = arena,
            .source = source,
            .type_pool = type_pool,
            .diagnostics = diagnostics,
            .checker = checker,
            .ctx = ctx,
            .strings = undefined,
            .void_ty = try ctx.voidType(),
            .bool_ty = try ctx.boolType(),
            .i8_ty = try ctx.intType(true, 8),
            .i16_ty = try ctx.intType(true, 16),
            .i32_ty = try ctx.intType(true, 32),
            .i64_ty = try ctx.intType(true, 64),
            .u8_ty = try ctx.intType(false, 8),
            .u16_ty = try ctx.intType(false, 16),
            .u32_ty = try ctx.intType(false, 32),
            .u64_ty = try ctx.intType(false, 64),
            .f32_ty = try ctx.floatType(.f32),
            .f64_ty = try ctx.floatType(.f64),
            .ptr_ty = undefined,
            .fn_by_node = .empty,
            .all_functions = .empty,
            .params = .empty,
            .locals = .empty,
            .shadows = .empty,
            .pending_defers = .empty,
        };
        self.ptr_ty = try ctx.ptrType(self.i64_ty);
        self.strings = string_mod.LiteralPool.init(gpa, ctx);
        return self;
    }

    pub fn deinit(self: *Lowerer) void {
        self.fn_by_node.deinit(self.gpa);
        self.all_functions.deinit(self.gpa);
        self.params.deinit(self.gpa);
        self.locals.deinit(self.gpa);
        self.shadows.deinit(self.gpa);
        self.pending_defers.deinit(self.gpa);
        self.strings.deinit();
    }

    /// Lower the entire checked module into `ctx`.
    pub fn run(self: *Lowerer) !void {
        const module = self.arena.get(self.checker.module_node);

        // Pass 1: create every function.
        for (module.module.decls.indices) |decl_idx| {
            const decl = self.arena.get(decl_idx);
            switch (decl.*) {
                .fn_decl => |f| {
                    if (f.generic_params.indices.len > 0) {
                        // A generic fn is a template, not a function: it has
                        // no body of its own to lower. Each instance is
                        // lowered as its own function, named after its type
                        // arguments (R21 step 4, R22).
                        continue;
                    }
                    _ = try self.createFunction(decl_idx, self.nameSlice(f.name));
                },
                else => {},
            }
        }

        // Pass 1b: create one function per monomorphized instance. The
        // instances are created lazily by the checker, so this is where the
        // generic templates turn into real functions (R21 step 4).
        for (self.checker.instances()) |inst| {
            _ = try self.createInstanceFunction(inst);
        }

        // Pass 2: function bodies. Closure and composition lifting append new
        // functions during this walk, so it is index-based to pick those up
        // too.
        var i: usize = 0;
        while (i < self.all_functions.items.len) : (i += 1) {
            const f = self.all_functions.items[i];
            try self.lowerFunctionBody(f.body, f.idx);
        }
    }

    // ========================================================================
    // Declarations
    // ========================================================================

    fn createFunction(self: *Lowerer, decl_idx: NodeIdx, name: []const u8) !api.FunctionIdx {
        const f = self.arena.get(decl_idx).fn_decl;
        const ret_ir = self.irTypeFor(self.checker.nodeType(decl_idx));
        // R14: every lowered function carries a leading hidden env parameter so
        // it can also be called through a fn value with no thunk; `main` is
        // exempt (R15).
        const env_hole: u32 = if (std.mem.eql(u8, name, "main")) 0 else 1;
        const fidx = try self.ctx.addFunction(name, ret_ir, @as(u32, @intCast(f.params.indices.len)) + env_hole);
        try self.fn_by_node.put(self.gpa, decl_idx, fidx);
        try self.all_functions.append(self.gpa, .{ .body = .{ .decl = decl_idx }, .idx = fidx });
        return fidx;
    }

    /// Create the function of one monomorphized instance (R21 step 4).
    ///
    /// The instance's symbol is the mangled name `<base>__<args>` (R22) and
    /// its body is the clone the checker type-checked with the type
    /// arguments bound (R21 step 2). An instance is never `main`, so it
    /// always carries the hidden env parameter.
    fn createInstanceFunction(self: *Lowerer, inst: *GenericInstance) !api.FunctionIdx {
        const clone = self.arena.get(inst.clone).fn_decl;
        const ret_ir = self.irTypeFor(inst.return_type);
        const fidx = try self.ctx.addFunction(
            inst.mangled,
            ret_ir,
            @as(u32, @intCast(clone.params.indices.len)) + 1,
        );
        try self.fn_by_node.put(self.gpa, inst.clone, fidx);
        try self.all_functions.append(self.gpa, .{ .body = .{ .decl = inst.clone }, .idx = fidx });
        return fidx;
    }

    fn lowerFunctionBody(self: *Lowerer, body: FunctionBody, fidx: api.FunctionIdx) !void {
        self.ctx.setCurrentFunction(fidx);
        self.params.clearRetainingCapacity();
        self.locals.clearRetainingCapacity();
        self.shadows.clearRetainingCapacity();
        self.pending_defers.clearRetainingCapacity();
        self.pending_materialized = null;
        self.block_terminated = false;

        const entry = try self.ctx.appendBlock();
        self.setBlock(entry);

        switch (body) {
            .decl => |decl_idx| {
                const f = self.arena.get(decl_idx).fn_decl;
                // R14: visible parameters sit after the hidden env parameter
                // (`main` is exempt and keeps parameter 0 as its first
                // visible parameter).
                const env_hole: u32 = if (std.mem.eql(u8, self.nameSlice(f.name), "main")) 0 else 1;
                for (f.params.indices, 0..) |param_idx, i| {
                    const param = self.arena.get(param_idx);
                    try self.params.put(self.gpa, self.nameSlice(param.param.name), .{
                        .value = @enumFromInt(env_hole + i),
                        .ty = try self.paramType(param.param.ty),
                    });
                }

                if (f.body != NodeIdx.none) {
                    try self.lowerStmt(f.body);
                }

                if (!self.block_terminated) {
                    try self.defaultRet(self.checker.nodeType(decl_idx));
                }
            },
            // A lifted closure body reads its visible parameters from hidden
            // argument slots 1..n and its captures from the env record in
            // parameter 0; it is not built from an fn_decl.
            .closure => |closure_node| try self.lowerLiftedBody(closure_node),
            .composition => |comp| try self.lowerCompositionBody(comp),
        }
    }

    /// Emit the fallthrough return for a body that did not terminate: a void
    /// function returns nothing, anything else returns a zero value (aggregates
    /// are pointer-shaped, so a null block pointer is a valid zero).
    fn defaultRet(self: *Lowerer, ret_ty: TypeIdx) !void {
        if (self.block_terminated) return;
        if (self.type_pool.get(ret_ty) == .void) {
            _ = try self.ctx.buildRetVoid();
        } else {
            _ = try self.ctx.buildRet(try self.ctx.buildIntConst(self.i64_ty, 0));
        }
    }

    /// Lower a lifted closure body (docs/semantics.md §6.2: the uniform
    /// env-first ABI). Visible parameters arrive as hidden argument slots
    /// 1..n; the env record address is argument 0. Each capture is copied out
    /// of the record into a stack slot, so the body sees ordinary locals — a
    /// captured `mut` binding is mutable inside its copy and never aliases
    /// the outer binding (R8d). A fn-value capture is stored inline as two
    /// words, so it is copied back out into a fresh 16-byte record.
    fn lowerLiftedBody(self: *Lowerer, closure_node: NodeIdx) !void {
        const cl = self.arena.get(closure_node).closure;

        for (cl.params.indices, 0..) |param_idx, i| {
            const param = self.arena.get(param_idx);
            try self.params.put(self.gpa, self.nameSlice(param.param.name), .{
                .value = self.ctx.getParam(@intCast(i + 1)),
                .ty = self.checker.nodeType(param_idx),
            });
        }

        const env_ptr = self.ctx.getParam(0);
        var offset: u64 = 0;
        for (cl.env.indices) |decl_idx| {
            const cap_ty = try self.captureType(decl_idx);
            const name = self.captureName(decl_idx);
            const slot_addr = try self.ctx.buildPtrAdd(
                self.ptr_ty,
                env_ptr,
                try self.ctx.buildIntConst(self.i64_ty, @intCast(offset)),
            );
            if (self.type_pool.get(cap_ty) == .function) {
                const record = try self.ctx.buildAllocaBytes(self.ptr_ty, api.fn_value_size);
                const word0 = try self.ctx.buildLoad(self.i64_ty, slot_addr);
                _ = try self.ctx.buildStore(self.i64_ty, record, word0);
                const src1 = try self.ctx.buildPtrAdd(self.ptr_ty, slot_addr, try self.ctx.buildIntConst(self.i64_ty, 8));
                const word1 = try self.ctx.buildLoad(self.i64_ty, src1);
                const dst1 = try self.ctx.buildPtrAdd(self.ptr_ty, record, try self.ctx.buildIntConst(self.i64_ty, 8));
                _ = try self.ctx.buildStore(self.i64_ty, dst1, word1);
                try self.bindLocal(name, record, cap_ty);
            } else {
                const captured = try self.ctx.buildLoad(self.i64_ty, slot_addr);
                const slot = try self.ctx.buildAllocaBytes(self.ptr_ty, 8);
                _ = try self.ctx.buildStore(self.i64_ty, slot, captured);
                try self.bindLocal(name, slot, cap_ty);
            }
            offset += self.envFieldSize(cap_ty);
        }

        const body = cl.body;
        const ret_ty = self.type_pool.get(self.exprType(closure_node)).function.return_type;
        if (self.arena.get(body).* == .block) {
            const val = try self.lowerBlockValue(self.arena.get(body).block);
            if (!self.block_terminated) {
                if (self.type_pool.get(ret_ty) == .void) {
                    _ = try self.ctx.buildRetVoid();
                } else if (self.tailPropagateVariant(body, ret_ty)) |svi| {
                    // A tail `?` in a block-bodied closure: the checker pairs
                    // it with the closure's return type only in the expression
                    // form; for a block, the propagate is lowered as a statement
                    // expression in lowerBlockValue and returns the success
                    // payload value, so re-wrap it like the expression form.
                    const wrapped = try self.lowerVariantInitValues(svi, &.{val});
                    _ = try self.ctx.buildRet(wrapped);
                } else {
                    _ = try self.ctx.buildRet(val);
                }
                self.terminated();
            }
        } else {
            // Expression-body shorthand: the body's value is the return value.
            const val = try self.lowerExpr(body);
            if (!self.block_terminated) {
                if (self.type_pool.get(ret_ty) == .void) {
                    _ = try self.ctx.buildRetVoid();
                } else if (self.tailPropagateVariant(body, ret_ty)) |svi| {
                    // A tail `?` whose propagated enum is the closure's
                    // return type (the checker accepts this only then): the
                    // propagate expression's value is the success payload,
                    // so the implicit return re-wraps it into the return
                    // enum's success variant. The error path of `?` already
                    // returned the rebuilt enum itself.
                    const wrapped = try self.lowerVariantInitValues(svi, &.{val});
                    _ = try self.ctx.buildRet(wrapped);
                } else {
                    _ = try self.ctx.buildRet(val);
                }
                self.terminated();
            }
        }
        if (!self.block_terminated) {
            try self.defaultRet(ret_ty);
        }
    }

    /// The success variant of `ret_ty` when `body` is a tail `x?` propagating
    /// that very enum, else null. The checker pairs a tail propagate
    /// expression with the closure's return type at type time (R27a), so the
    /// success payload is re-wrapped into this variant to form the implicit
    /// return of an expression-bodied closure.
    fn tailPropagateVariant(self: *Lowerer, body: NodeIdx, ret_ty: TypeIdx) ?ast.EnumVariantInfo {
        const node = self.arena.get(body);
        if (node.* != .try_propagate) return null;
        const sem = self.type_pool.get(ret_ty);
        const enum_node = switch (sem) {
            .enum_type => |n| n,
            .applied_enum => |a| a.decl,
            else => return null,
        };
        const shape = self.checker.propagateShape(enum_node) orelse return null;
        const variants = self.arena.get(enum_node).enum_decl.variants.indices;
        return .{
            .enum_decl = enum_node,
            .variant_node = variants[shape.success_index],
            .index = shape.success_index,
        };
    }

    // ========================================================================
    // Statements
    // ========================================================================

    fn lowerStmt(self: *Lowerer, node_idx: NodeIdx) anyerror!void {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .block => |b| try self.lowerBlock(b.stmts),
            .let_stmt => try self.lowerLet(node_idx),
            .return_stmt => |r| try self.lowerReturn(r),
            .expr_stmt => |e| _ = try self.lowerExpr(e.expr),
            .defer_stmt => |d| try self.pending_defers.append(self.gpa, d.expr),
            .if_expr => try self.lowerIf(node_idx),
            .while_expr => try self.lowerWhile(node_idx),
            .for_range => try self.lowerForRange(node_idx),
            .for_each => |fe| try self.lowerForEach(node_idx, fe),
            .match_expr => try self.lowerMatch(node_idx),
            .fn_decl => {},
            .comptime_block => {
                const block = node.comptime_block;
                const bnode = self.arena.get(block);
                if (bnode.* == .block) {
                    for (bnode.block.stmts.indices) |stmt| {
                        _ = try self.lowerStmt(stmt);
                    }
                } else {
                    _ = try self.lowerStmt(block);
                }
            },
            .comptime_expr => |inner| {
                const inner_node = self.arena.get(inner);
                if (inner_node.* == .if_expr) {
                    if (self.checker.comptimeBranch(inner)) |taken| {
                        const branch = if (taken) inner_node.if_expr.then_body else (inner_node.if_expr.else_body orelse return);
                        const bn = self.arena.get(branch);
                        if (bn.* == .block) {
                            try self.lowerBlock(bn.block.stmts);
                        } else {
                            _ = try self.lowerExpr(branch);
                        }
                        return;
                    }
                }
                _ = try self.lowerExpr(node_idx);
            },
            .comptime_call => {
                _ = try self.lowerComptimeCall(node_idx, node.comptime_call);
            },
            else => _ = try self.lowerExpr(node_idx),
        }
    }

    fn lowerBlock(self: *Lowerer, stmts: NodeList) anyerror!void {
        const defer_marker = self.pending_defers.items.len;
        const local_marker = self.shadows.items.len;

        for (stmts.indices) |stmt_idx| {
            try self.lowerStmt(stmt_idx);
            if (self.block_terminated) break;
        }

        if (!self.block_terminated) {
            try self.flushDefersFrom(defer_marker);
        }
        try self.popLocalScope(local_marker);
    }

    /// Emit pending defers from index `marker` onward, last first.
    fn flushDefersFrom(self: *Lowerer, marker: usize) !void {
        while (self.pending_defers.items.len > marker) {
            const expr = self.pending_defers.items[self.pending_defers.items.len - 1];
            self.pending_defers.items.len -= 1;
            _ = try self.lowerExpr(expr);
        }
    }

    /// Emit pending defers from index `marker` onward, last first, without
    /// consuming them. An early-return path (the error branch of `?`) must run
    /// the defers it unwinds, but the enclosing block keeps them for its own
    /// exit, so the list is left intact.
    fn emitDefersFrom(self: *Lowerer, marker: usize) !void {
        var i = self.pending_defers.items.len;
        while (i > marker) {
            i -= 1;
            _ = try self.lowerExpr(self.pending_defers.items[i]);
        }
    }

    fn popLocalScope(self: *Lowerer, marker: usize) !void {
        while (self.shadows.items.len > marker) {
            const entry = self.shadows.items[self.shadows.items.len - 1];
            self.shadows.items.len -= 1;
            if (entry.prev) |prev| {
                try self.locals.put(self.gpa, entry.name, prev);
            } else {
                _ = self.locals.remove(entry.name);
            }
        }
    }

    fn bindLocal(self: *Lowerer, name: []const u8, slot: api.Value, ty: TypeIdx) !void {
        try self.bindLocalMaterialized(name, slot, ty, null);
    }

    /// Bind a local, recording the materialized composition it holds, if any
    /// (R31b).
    fn bindLocalMaterialized(
        self: *Lowerer,
        name: []const u8,
        slot: api.Value,
        ty: TypeIdx,
        materialized: ?Materialized,
    ) !void {
        try self.shadows.append(self.gpa, .{ .name = name, .prev = self.locals.get(name) });
        try self.locals.put(self.gpa, name, .{ .value = slot, .ty = ty, .materialized = materialized });
    }

    fn lowerLet(self: *Lowerer, node_idx: NodeIdx) !void {
        const l = self.arena.get(node_idx).let_stmt;
        const slot = try self.allocVarSlot(self.checker.nodeType(node_idx));
        var materialized: ?Materialized = null;
        if (l.init_expr) |init_idx| {
            self.pending_materialized = null;
            const val = try self.lowerExpr(init_idx);
            materialized = self.pending_materialized;
            self.pending_materialized = null;
            _ = try self.ctx.buildStore(self.i64_ty, slot, val);
        } else {
            _ = try self.ctx.buildStore(self.i64_ty, slot, try self.ctx.buildIntConst(self.i64_ty, 0));
        }
        try self.bindLocalMaterialized(self.nameSlice(l.name), slot, self.checker.nodeType(node_idx), materialized);
    }

    fn allocVarSlot(self: *Lowerer, ty: TypeIdx) !api.Value {
        const size: u32 = switch (self.type_pool.get(ty)) {
            .struct_type => |decl_node| structSize(self.arena, decl_node),
            // An applied struct has the layout of its declaration (R20c).
            .applied_struct => |a| structSize(self.arena, a.decl),
            else => 8,
        };
        return self.ctx.buildAllocaBytes(self.ptr_ty, size);
    }

    fn lowerReturn(self: *Lowerer, r: anytype) !void {
        // Deferred expressions run before the function leaves, innermost first.
        try self.flushDefersFrom(0);
        if (r.value) |val_idx| {
            const val = try self.lowerExpr(val_idx);
            _ = try self.ctx.buildRet(val);
        } else {
            _ = try self.ctx.buildRetVoid();
        }
        self.terminated();
    }

    // ========================================================================
    // Control flow
    // ========================================================================

    fn lowerIf(self: *Lowerer, node_idx: NodeIdx) !void {
        const i = self.arena.get(node_idx).if_expr;
        const cond = try self.lowerExpr(i.cond);

        const then_b = try self.ctx.appendBlock();
        const else_b = try self.ctx.appendBlock();
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildCondBr(cond, then_b, else_b);

        self.setBlock(then_b);
        try self.lowerStmt(i.then_body);
        if (!self.block_terminated) _ = try self.ctx.buildBr(merge);

        self.setBlock(else_b);
        if (i.else_body) |else_idx| {
            try self.lowerStmt(else_idx);
        }
        if (!self.block_terminated) _ = try self.ctx.buildBr(merge);

        self.setBlock(merge);
    }

    /// Lower an `if` in expression position: branches contribute values to a
    /// phi at the merge block. Branches that terminate (return) do not
    /// contribute an incoming edge. Void-typed ifs fall back to statement
    /// lowering.
    fn lowerIfExpr(self: *Lowerer, node_idx: NodeIdx, i: anytype) !api.Value {
        if (self.type_pool.get(self.exprType(node_idx)) == .void) {
            try self.lowerIf(node_idx);
            return self.ctx.buildIntConst(self.i64_ty, 0);
        }

        const cond = try self.lowerExpr(i.cond);
        const then_b = try self.ctx.appendBlock();
        const else_b = try self.ctx.appendBlock();
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildCondBr(cond, then_b, else_b);

        self.setBlock(then_b);
        const then_val = try self.lowerBranchValue(i.then_body);
        const then_has = !self.block_terminated;
        if (then_has) _ = try self.ctx.buildBr(merge);

        self.setBlock(else_b);
        const else_val = if (i.else_body) |else_idx|
            try self.lowerBranchValue(else_idx)
        else
            try self.ctx.buildIntConst(self.i64_ty, 0);
        const else_has = !self.block_terminated;
        if (else_has) _ = try self.ctx.buildBr(merge);

        self.setBlock(merge);
        var incoming = std.ArrayList(api.PhiIncoming).empty;
        defer incoming.deinit(self.gpa);
        if (then_has) try incoming.append(self.gpa, .{ .value = then_val, .block = then_b });
        if (else_has) try incoming.append(self.gpa, .{ .value = else_val, .block = else_b });
        if (incoming.items.len == 0) return self.ctx.buildIntConst(self.i64_ty, 0);
        return self.ctx.buildPhi(self.irTypeFor(self.exprType(node_idx)), incoming.items);
    }

    /// Evaluate a branch body in expression position: blocks yield their last
    /// expression, other nodes lower as expressions.
    fn lowerBranchValue(self: *Lowerer, node_idx: NodeIdx) !api.Value {
        const node = self.arena.get(node_idx);
        if (node.* == .block) return self.lowerBlockValue(node.block);
        return self.lowerExpr(node_idx);
    }

    fn lowerWhile(self: *Lowerer, node_idx: NodeIdx) !void {
        const w = self.arena.get(node_idx).while_expr;
        const header = try self.ctx.appendBlock();
        const body = try self.ctx.appendBlock();
        const end = try self.ctx.appendBlock();
        _ = try self.ctx.buildBr(header);

        self.setBlock(header);
        const cond = try self.lowerExpr(w.cond);
        _ = try self.ctx.buildCondBr(cond, body, end);

        self.setBlock(body);
        try self.lowerStmt(w.body);
        if (!self.block_terminated) _ = try self.ctx.buildBr(header);

        self.setBlock(end);
    }

    fn lowerForRange(self: *Lowerer, node_idx: NodeIdx) !void {
        const fr = self.arena.get(node_idx).for_range;

        // Loop variable lives in a mutable slot; the bound is evaluated once.
        const slot = try self.ctx.buildAllocaBytes(self.ptr_ty, 8);
        _ = try self.ctx.buildStore(self.i64_ty, slot, try self.lowerExpr(fr.start));
        const end = try self.lowerExpr(fr.end);

        const header = try self.ctx.appendBlock();
        const body = try self.ctx.appendBlock();
        const incr = try self.ctx.appendBlock();
        const exit = try self.ctx.appendBlock();
        _ = try self.ctx.buildBr(header);

        self.setBlock(header);
        const cur = try self.ctx.buildLoad(self.i64_ty, slot);
        const cond = try self.ctx.buildIcmp(.icmp_slt, self.bool_ty, cur, end);
        _ = try self.ctx.buildCondBr(cond, body, exit);

        self.setBlock(body);
        try self.bindLocal(self.nameSlice(fr.var_name), slot, self.checker.nodeType(fr.start));
        try self.lowerStmt(fr.body);
        if (!self.block_terminated) {
            _ = try self.ctx.buildBr(incr);

            self.setBlock(incr);
            const next = try self.ctx.buildAdd(self.i64_ty, try self.ctx.buildLoad(self.i64_ty, slot), try self.ctx.buildIntConst(self.i64_ty, 1));
            _ = try self.ctx.buildStore(self.i64_ty, slot, next);
            _ = try self.ctx.buildBr(header);
        }
        self.setBlock(exit);
        try self.popLocalScope(self.shadows.items.len - if (self.locals.get(self.nameSlice(fr.var_name)) != null) @as(usize, 1) else 0);
    }

    /// `for x in iterable` — currently lowers to String iteration: walk the
    /// `[len][data]` block and expose each byte as an i32 char.
    fn lowerForEach(self: *Lowerer, node_idx: NodeIdx, fe: anytype) !void {
        const iterable = try self.lowerExpr(fe.iterable);
        const sem = self.type_pool.get(self.exprType(fe.iterable));
        switch (sem) {
            .string_type => try self.lowerForEachString(fe, iterable),
            else => self.codegenError(node_idx, "only String iteration is lowered for 'for ... in'", .{}),
        }
    }

    fn lowerForEachString(self: *Lowerer, fe: anytype, iterable: api.Value) !void {
        const len_addr = try self.ctx.buildPtrAdd(self.ptr_ty, iterable, try self.ctx.buildIntConst(self.i64_ty, @intCast(string_mod.len_offset)));
        const len = try self.ctx.buildLoad(self.i64_ty, len_addr);
        const data_addr = try self.ctx.buildPtrAdd(self.ptr_ty, iterable, try self.ctx.buildIntConst(self.i64_ty, @intCast(string_mod.data_offset)));
        const data = try self.ctx.buildLoad(self.ptr_ty, data_addr);

        const var_slot = try self.ctx.buildAllocaBytes(self.ptr_ty, 8);
        const i_slot = try self.ctx.buildAllocaBytes(self.ptr_ty, 8);
        _ = try self.ctx.buildStore(self.i64_ty, i_slot, try self.ctx.buildIntConst(self.i64_ty, 0));

        const header = try self.ctx.appendBlock();
        const body = try self.ctx.appendBlock();
        const incr = try self.ctx.appendBlock();
        const exit = try self.ctx.appendBlock();
        _ = try self.ctx.buildBr(header);

        self.setBlock(header);
        const i = try self.ctx.buildLoad(self.i64_ty, i_slot);
        const cond = try self.ctx.buildIcmp(.icmp_ult, self.bool_ty, i, len);
        _ = try self.ctx.buildCondBr(cond, body, exit);

        self.setBlock(body);
        const cur_i = try self.ctx.buildLoad(self.i64_ty, i_slot);
        const elem_ptr = try self.ctx.buildPtrAdd(self.ptr_ty, data, cur_i);
        const ch = try self.ctx.buildLoad(self.i32_ty, elem_ptr);
        _ = try self.ctx.buildStore(self.i64_ty, var_slot, ch);
        try self.bindLocal(self.nameSlice(fe.var_name), var_slot, self.checker.i32_ty);
        try self.lowerStmt(fe.body);
        if (!self.block_terminated) {
            _ = try self.ctx.buildBr(incr);

            self.setBlock(incr);
            const next = try self.ctx.buildAdd(self.i64_ty, try self.ctx.buildLoad(self.i64_ty, i_slot), try self.ctx.buildIntConst(self.i64_ty, 1));
            _ = try self.ctx.buildStore(self.i64_ty, i_slot, next);
            _ = try self.ctx.buildBr(header);
        }
        self.setBlock(exit);
        try self.popLocalScope(self.shadows.items.len - if (self.locals.get(self.nameSlice(fe.var_name)) != null) @as(usize, 1) else 0);
    }

    /// `obj[index]` — Strings index by byte (char), arrays by element slot.
    fn lowerIndexAccess(self: *Lowerer, node_idx: NodeIdx, ia: anytype) !api.Value {
        const obj = try self.lowerExpr(ia.object);
        const index = try self.lowerExpr(ia.index);
        var sem = self.type_pool.get(self.exprType(ia.object));
        if (sem == .pointer) sem = self.type_pool.get(sem.pointer);
        switch (sem) {
            .string_type => {
                const data_addr = try self.ctx.buildPtrAdd(self.ptr_ty, obj, try self.ctx.buildIntConst(self.i64_ty, @intCast(string_mod.data_offset)));
                const data = try self.ctx.buildLoad(self.ptr_ty, data_addr);
                const elem_ptr = try self.ctx.buildPtrAdd(self.ptr_ty, data, index);
                return self.ctx.buildLoad(self.i32_ty, elem_ptr);
            },
            .array => {
                const elem_ptr = try self.ctx.buildPtrAdd(self.ptr_ty, obj, try self.ctx.buildMul(self.i64_ty, index, try self.ctx.buildIntConst(self.i64_ty, 8)));
                return self.ctx.buildLoad(self.i64_ty, elem_ptr);
            },
            else => {
                self.codegenError(node_idx, "index access is only lowered for String and array values", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
        }
    }

    fn lowerMatch(self: *Lowerer, node_idx: NodeIdx) !void {
        const m = self.arena.get(node_idx).match_expr;
        const scrutinee = try self.lowerExpr(m.scrutinee);
        if (self.isEnumType(self.exprType(m.scrutinee))) {
            _ = try self.lowerMatchEnum(node_idx, m, scrutinee, false);
        } else {
            _ = try self.lowerMatchInt(node_idx, m, scrutinee, false);
        }
    }

    /// Lower a match in expression position (value-producing arms).
    fn lowerMatchExpr(self: *Lowerer, node_idx: NodeIdx) !api.Value {
        if (self.type_pool.get(self.exprType(node_idx)) == .void) {
            try self.lowerMatch(node_idx);
            return self.ctx.buildIntConst(self.i64_ty, 0);
        }
        const m = self.arena.get(node_idx).match_expr;
        const scrutinee = try self.lowerExpr(m.scrutinee);
        if (self.isEnumType(self.exprType(m.scrutinee))) {
            return self.lowerMatchEnum(node_idx, m, scrutinee, true);
        }
        return self.lowerMatchInt(node_idx, m, scrutinee, true);
    }

    /// Whether a type is an enum, generic or not. An applied enum has the
    /// layout of the declaration it was instantiated from (R2a), so both lower
    /// the same way.
    fn isEnumType(self: *const Lowerer, ty: TypeIdx) bool {
        return switch (self.type_pool.get(ty)) {
            .enum_type, .applied_enum => true,
            else => false,
        };
    }

    /// Integer-literal match: icmp chain to per-arm blocks, phi at merge when
    /// the match is in expression position. A `_` pattern matches every value,
    /// and a guard decides whether a matched arm runs.
    fn lowerMatchInt(self: *Lowerer, node_idx: NodeIdx, m: anytype, scrutinee: api.Value, want_value: bool) !api.Value {
        var arm_consts = std.ArrayList(api.Value).empty;
        defer arm_consts.deinit(self.gpa);
        var wildcards = std.ArrayList(bool).empty;
        defer wildcards.deinit(self.gpa);
        for (m.arms.indices) |arm_idx| {
            const arm = self.arena.get(arm_idx);
            const pattern = self.arena.get(arm.match_arm.pattern);
            switch (pattern.*) {
                .int_literal => |v| {
                    try arm_consts.append(self.gpa, try self.ctx.buildIntConst(self.i64_ty, v));
                    try wildcards.append(self.gpa, false);
                },
                .identifier => |id| {
                    if (std.mem.eql(u8, self.nameSlice(id), "_")) {
                        try arm_consts.append(self.gpa, try self.ctx.buildIntConst(self.i64_ty, 0));
                        try wildcards.append(self.gpa, true);
                    } else {
                        self.codegenError(arm_idx, "only integer match patterns are supported for non-enum scrutinees", .{});
                        try arm_consts.append(self.gpa, try self.ctx.buildIntConst(self.i64_ty, 0));
                        try wildcards.append(self.gpa, false);
                    }
                },
                else => {
                    self.codegenError(arm_idx, "only integer match patterns are supported for non-enum scrutinees", .{});
                    try arm_consts.append(self.gpa, try self.ctx.buildIntConst(self.i64_ty, 0));
                    try wildcards.append(self.gpa, false);
                },
            }
        }

        var checks = std.ArrayList(api.BasicBlockIdx).empty;
        defer checks.deinit(self.gpa);
        var bodies = std.ArrayList(api.BasicBlockIdx).empty;
        defer bodies.deinit(self.gpa);
        var body_blocks = std.ArrayList(api.BasicBlockIdx).empty;
        defer body_blocks.deinit(self.gpa);
        var body_vals = std.ArrayList(api.Value).empty;
        defer body_vals.deinit(self.gpa);
        var terminated_flags = std.ArrayList(bool).empty;
        defer terminated_flags.deinit(self.gpa);
        for (m.arms.indices) |_| {
            try checks.append(self.gpa, try self.ctx.appendBlock());
            try bodies.append(self.gpa, try self.ctx.appendBlock());
            try body_blocks.append(self.gpa, undefined);
            try terminated_flags.append(self.gpa, false);
        }
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildBr(checks.items[0]);

        for (m.arms.indices, 0..) |arm_idx, i| {
            const arm = self.arena.get(arm_idx);
            self.setBlock(checks.items[i]);
            const next_check = if (i + 1 < checks.items.len) checks.items[i + 1] else merge;
            if (wildcards.items[i]) {
                _ = try self.ctx.buildBr(bodies.items[i]);
            } else {
                const match_cond = try self.ctx.buildIcmp(.icmp_eq, self.bool_ty, scrutinee, arm_consts.items[i]);
                _ = try self.ctx.buildCondBr(match_cond, bodies.items[i], next_check);
            }

            self.setBlock(bodies.items[i]);
            // A guard runs after the pattern matched; a failed guard falls
            // through to the next arm.
            if (arm.match_arm.guard) |guard| {
                const guard_block = try self.ctx.appendBlock();
                body_blocks.items[i] = guard_block;
                const guard_val = try self.lowerExpr(guard);
                _ = try self.ctx.buildCondBr(guard_val, guard_block, next_check);
                self.setBlock(guard_block);
            } else {
                body_blocks.items[i] = bodies.items[i];
            }
            if (want_value) {
                try body_vals.append(self.gpa, try self.lowerExpr(arm.match_arm.body));
            } else {
                try self.lowerStmt(arm.match_arm.body);
            }
            terminated_flags.items[i] = self.block_terminated;
            if (!self.block_terminated) _ = try self.ctx.buildBr(merge);
        }

        self.setBlock(merge);
        if (!want_value) return self.ctx.buildIntConst(self.i64_ty, 0);
        var incoming = std.ArrayList(api.PhiIncoming).empty;
        defer incoming.deinit(self.gpa);
        for (m.arms.indices, 0..) |_, i| {
            if (!terminated_flags.items[i]) {
                try incoming.append(self.gpa, .{ .value = body_vals.items[i], .block = body_blocks.items[i] });
            }
        }
        if (incoming.items.len == 0) return self.ctx.buildIntConst(self.i64_ty, 0);
        return self.ctx.buildPhi(self.irTypeFor(self.exprType(node_idx)), incoming.items);
    }

    /// Enum match: compare the tag byte, then bind the matched variant's
    /// payload identifiers for the arm body. A `_` pattern matches every
    /// variant, and a guard decides whether a matched arm runs. Returns an
    /// expression value when the match is in expression position.
    fn lowerMatchEnum(self: *Lowerer, node_idx: NodeIdx, m: anytype, scrutinee: api.Value, want_value: bool) !api.Value {
        const tag = try self.ctx.buildLoad(self.i64_ty, scrutinee);

        var checks = std.ArrayList(api.BasicBlockIdx).empty;
        defer checks.deinit(self.gpa);
        var bodies = std.ArrayList(api.BasicBlockIdx).empty;
        defer bodies.deinit(self.gpa);
        var body_blocks = std.ArrayList(api.BasicBlockIdx).empty;
        defer body_blocks.deinit(self.gpa);
        var body_vals = std.ArrayList(api.Value).empty;
        defer body_vals.deinit(self.gpa);
        var terminated_flags = std.ArrayList(bool).empty;
        defer terminated_flags.deinit(self.gpa);
        for (m.arms.indices) |_| {
            try checks.append(self.gpa, try self.ctx.appendBlock());
            try bodies.append(self.gpa, try self.ctx.appendBlock());
            try body_blocks.append(self.gpa, undefined);
            try terminated_flags.append(self.gpa, false);
        }
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildBr(checks.items[0]);

        for (m.arms.indices, 0..) |arm_idx, i| {
            const arm = self.arena.get(arm_idx);
            const pattern = self.arena.get(arm.match_arm.pattern);
            const next_check = if (i + 1 < checks.items.len) checks.items[i + 1] else merge;
            const wildcard = self.isWildcardPattern(pattern);
            const variant: ?ast.EnumVariantInfo = if (wildcard) null else self.matchVariantFor(arm_idx, pattern);

            if (wildcard) {
                self.setBlock(checks.items[i]);
                _ = try self.ctx.buildBr(bodies.items[i]);
            } else if (variant == null) {
                self.setBlock(checks.items[i]);
                _ = try self.ctx.buildCondBr(tag, bodies.items[i], next_check);
                self.setBlock(bodies.items[i]);
                _ = try self.ctx.buildBr(merge);
                terminated_flags.items[i] = false;
                body_blocks.items[i] = bodies.items[i];
                if (want_value) try body_vals.append(self.gpa, try self.ctx.buildIntConst(self.i64_ty, 0));
                continue;
            } else {
                self.setBlock(checks.items[i]);
                const tag_const = try self.ctx.buildIntConst(self.i64_ty, @intCast(variant.?.index));
                const match_cond = try self.ctx.buildIcmp(.icmp_eq, self.bool_ty, tag, tag_const);
                _ = try self.ctx.buildCondBr(match_cond, bodies.items[i], next_check);
            }

            self.setBlock(bodies.items[i]);
            const local_marker = self.shadows.items.len;
            if (pattern.* == .call) {
                const variant_node = self.arena.get(variant.?.variant_node);
                for (pattern.call.args.indices, 0..) |arg_idx, j| {
                    const arg = self.arena.get(arg_idx);
                    if (arg.* != .identifier) continue;
                    const payload_addr = try self.ctx.buildPtrAdd(self.ptr_ty, scrutinee, try self.ctx.buildIntConst(self.i64_ty, @intCast(enumPayloadOffset(j))));
                    const payload = try self.ctx.buildLoad(self.i64_ty, payload_addr);
                    const slot = try self.ctx.buildAllocaBytes(self.ptr_ty, 8);
                    _ = try self.ctx.buildStore(self.i64_ty, slot, payload);
                    const payload_ty = if (j < variant_node.enum_variant.fields.indices.len)
                        self.checker.nodeType(variant_node.enum_variant.fields.indices[j])
                    else
                        self.checker.void_ty;
                    try self.bindLocal(self.nameSlice(arg.identifier), slot, payload_ty);
                }
            }
            // A guard runs after the pattern matched and its payload is bound;
            // a failed guard falls through to the next arm.
            if (arm.match_arm.guard) |guard| {
                const guard_block = try self.ctx.appendBlock();
                body_blocks.items[i] = guard_block;
                const guard_val = try self.lowerExpr(guard);
                _ = try self.ctx.buildCondBr(guard_val, guard_block, next_check);
                self.setBlock(guard_block);
            } else {
                body_blocks.items[i] = bodies.items[i];
            }
            if (want_value) {
                try body_vals.append(self.gpa, try self.lowerExpr(arm.match_arm.body));
            } else {
                try self.lowerStmt(arm.match_arm.body);
            }
            terminated_flags.items[i] = self.block_terminated;
            if (!self.block_terminated) _ = try self.ctx.buildBr(merge);
            try self.popLocalScope(local_marker);
        }

        self.setBlock(merge);
        if (!want_value) return self.ctx.buildIntConst(self.i64_ty, 0);
        var incoming = std.ArrayList(api.PhiIncoming).empty;
        defer incoming.deinit(self.gpa);
        for (m.arms.indices, 0..) |_, i| {
            if (!terminated_flags.items[i]) {
                try incoming.append(self.gpa, .{ .value = body_vals.items[i], .block = body_blocks.items[i] });
            }
        }
        if (incoming.items.len == 0) return self.ctx.buildIntConst(self.i64_ty, 0);
        return self.ctx.buildPhi(self.irTypeFor(self.exprType(node_idx)), incoming.items);
    }

    /// Whether a match pattern is the `_` wildcard.
    fn isWildcardPattern(self: *Lowerer, pattern: *const Node) bool {
        return pattern.* == .identifier and std.mem.eql(u8, self.nameSlice(pattern.identifier), "_");
    }

    /// Resolve a match arm pattern to an enum variant (either a bare variant
    /// name or a `Variant(...)` call), reporting an error when neither fits.
    fn matchVariantFor(self: *Lowerer, arm_idx: NodeIdx, pattern: *const Node) ?ast.EnumVariantInfo {
        const name: []const u8 = switch (pattern.*) {
            .identifier => |id| self.nameSlice(id),
            .call => |c| blk: {
                const callee = self.arena.get(c.func);
                if (callee.* != .identifier) {
                    self.codegenError(arm_idx, "unsupported match pattern", .{});
                    return null;
                }
                break :blk self.nameSlice(callee.identifier);
            },
            else => {
                self.codegenError(arm_idx, "match arm pattern must be an enum variant", .{});
                return null;
            },
        };
        const vi = ast.findEnumVariant(self.arena, self.source, self.checker.module_node, name) orelse {
            self.codegenError(arm_idx, "'{s}' is not an enum variant", .{name});
            return null;
        };
        return vi;
    }

    // ========================================================================
    // Expressions
    // ========================================================================

    fn lowerExpr(self: *Lowerer, node_idx: NodeIdx) !api.Value {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .int_literal => |v| return self.ctx.buildIntConst(self.irTypeFor(self.checker.nodeType(node_idx)), v),
            .float_literal => |v| return self.ctx.buildFloatConst(self.irTypeFor(self.checker.nodeType(node_idx)), v),
            .bool_literal => |v| return self.ctx.buildIntConst(self.bool_ty, if (v) 1 else 0),
            .null_literal => return self.ctx.buildIntConst(self.i64_ty, 0),
            .char_literal => |ref| return self.lowerChar(ref),
            .string_literal => |ref| return self.lowerString(ref),
            .fn_ref => |id| return self.lowerFnRef(node_idx, id),
            .identifier => |id| {
                const name = self.nameSlice(id);
                if (ast.findEnumVariant(self.arena, self.source, self.checker.module_node, name)) |vi| {
                    return self.lowerVariantInit(vi, .{ .args = NodeList{ .indices = &.{} } });
                }
                return self.lowerIdentifier(node_idx, id);
            },
            .binary_op => |b| return self.lowerBinary(node_idx, b),
            .unary_op => |u| return self.lowerUnary(node_idx, u),
            .call => |c| return self.lowerCall(node_idx, c),
            .field_access => |fa| {
                if (try self.lowerFieldAddr(node_idx, fa)) |addr| {
                    return self.ctx.buildLoad(self.i64_ty, addr);
                }
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .index_access => |ia| return self.lowerIndexAccess(node_idx, ia),
            .generic_app => {
                self.codegenError(node_idx, "a type application is not a value", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .paren_expr => |p| return self.lowerExpr(p),
            .closure => |cl| return self.lowerClosure(node_idx, cl),
            .pipeline => |p| return self.lowerPipeline(node_idx, p),
            .struct_init => |si| return self.lowerStructInit(node_idx, si),
            .range_expr => {
                self.codegenError(node_idx, "range expression outside of a for loop", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .if_expr => |i| return self.lowerIfExpr(node_idx, i),
            .match_expr => return self.lowerMatchExpr(node_idx),
            .try_propagate => |inner| return self.lowerPropagate(node_idx, inner),
            .comptime_block => {
                const block = node.comptime_block;
                const bnode = self.arena.get(block);
                if (bnode.* == .block) {
                    for (bnode.block.stmts.indices) |stmt| {
                        _ = try self.lowerStmt(stmt);
                    }
                } else {
                    _ = try self.lowerStmt(block);
                }
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .comptime_expr => |inner| {
                const inner_node = self.arena.get(inner);
                if (inner_node.* == .if_expr) {
                    if (self.checker.comptimeBranch(inner)) |taken| {
                        const branch = if (taken) inner_node.if_expr.then_body else (inner_node.if_expr.else_body orelse return self.ctx.buildIntConst(self.i64_ty, 0));
                        return self.lowerExpr(branch);
                    }
                }
                const cv = self.checker.comptimeValue(node_idx);
                if (cv != .none) return try self.lowerComptimeValue(cv);
                return self.lowerExpr(inner);
            },
            .comptime_call => |cc| return self.lowerComptimeCall(node_idx, cc),
            .while_expr, .for_range, .for_each => {
                self.codegenError(node_idx, "loops in expression position are not supported", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .block => |b| return self.lowerBlockValue(b),
            else => {
                self.codegenError(node_idx, "expression not lowered", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
        }
    }

    fn lowerBlockValue(self: *Lowerer, b: anytype) !api.Value {
        const defer_marker = self.pending_defers.items.len;
        const local_marker = self.shadows.items.len;
        var last_val: api.Value = undefined;
        var has_value = false;

        for (b.stmts.indices, 0..) |stmt_idx, i| {
            if (self.block_terminated) break;
            const node = self.arena.get(stmt_idx);
            if (i + 1 == b.stmts.indices.len and node.* == .expr_stmt) {
                last_val = try self.lowerExpr(node.expr_stmt.expr);
                has_value = true;
            } else {
                try self.lowerStmt(stmt_idx);
            }
        }

        if (!self.block_terminated) {
            try self.flushDefersFrom(defer_marker);
        }
        try self.popLocalScope(local_marker);

        if (has_value) return last_val;
        return self.ctx.buildIntConst(self.i64_ty, 0);
    }

    /// Lower `x?` (R28): load the operand's tag, branch to a propagate block on
    /// the error variant and to an ok block otherwise. The propagate block
    /// rebuilds the enclosing function's enum from the error payload (or the
    /// bare error variant), runs the defers it unwinds, and returns it; the ok
    /// block loads the success payload, which is the value of the expression.
    /// The propagate path terminates, so no phi is needed.
    fn lowerPropagate(self: *Lowerer, node_idx: NodeIdx, inner: NodeIdx) !api.Value {
        const operand = try self.lowerExpr(inner);
        const operand_ty = self.exprType(inner);
        const sem = self.type_pool.get(operand_ty);
        // An applied enum has the layout of the declaration it was
        // instantiated from (R2a), so the shape comes from that declaration.
        const enum_node = switch (sem) {
            .enum_type => |n| n,
            .applied_enum => |a| a.decl,
            else => {
                self.codegenError(node_idx, "cannot propagate a non-enum value", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
        };
        const args: []const TypeIdx = switch (sem) {
            .enum_type => &.{},
            .applied_enum => |a| a.args,
            else => &.{},
        };
        const shape = self.checker.propagateShapeFor(enum_node, args) orelse {
            self.codegenError(node_idx, "cannot propagate this enum: no one-payload success variant and error variant", .{});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        };

        const tag = try self.ctx.buildLoad(self.i64_ty, operand);
        const err_tag = try self.ctx.buildIntConst(self.i64_ty, @intCast(shape.error_index));
        const is_err = try self.ctx.buildIcmp(.icmp_eq, self.bool_ty, tag, err_tag);

        const propagate_b = try self.ctx.appendBlock();
        const ok_b = try self.ctx.appendBlock();
        _ = try self.ctx.buildCondBr(is_err, propagate_b, ok_b);

        // Error path: construct the error variant of the enclosing return enum
        // and return it. The operand and the enclosing function share the enum
        // declaration (R27a), so the variant's index and payload layout match.
        self.setBlock(propagate_b);
        const err_value = try self.ctx.buildAllocaBytes(self.ptr_ty, enumSizeFor(shape.error_field_count));
        _ = try self.ctx.buildStore(self.i64_ty, err_value, try self.ctx.buildIntConst(self.i64_ty, @intCast(shape.error_index)));
        if (shape.error_field_count == 1) {
            const src_addr = try self.ctx.buildPtrAdd(self.ptr_ty, operand, try self.ctx.buildIntConst(self.i64_ty, @intCast(enumPayloadOffset(0))));
            const payload = try self.ctx.buildLoad(self.i64_ty, src_addr);
            const dst_addr = try self.ctx.buildPtrAdd(self.ptr_ty, err_value, try self.ctx.buildIntConst(self.i64_ty, @intCast(enumPayloadOffset(0))));
            _ = try self.ctx.buildStore(self.i64_ty, dst_addr, payload);
        }
        try self.emitDefersFrom(0);
        _ = try self.ctx.buildRet(err_value);
        self.terminated();

        // Success path: the payload is the value of `x?`.
        self.setBlock(ok_b);
        const payload_addr = try self.ctx.buildPtrAdd(self.ptr_ty, operand, try self.ctx.buildIntConst(self.i64_ty, @intCast(enumPayloadOffset(0))));
        return self.ctx.buildLoad(self.i64_ty, payload_addr);
    }

    fn lowerChar(self: *Lowerer, ref: StringRef) !api.Value {
        const raw = ref.slice(self.source);
        const body = raw[1 .. raw.len - 1];
        const bytes = try string_mod.unescape(self.gpa, body);
        defer self.gpa.free(bytes);
        const value: i64 = if (bytes.len > 0) bytes[0] else 0;
        return self.ctx.buildIntConst(self.i32_ty, value);
    }

    fn lowerString(self: *Lowerer, ref: StringRef) !api.Value {
        const raw = ref.slice(self.source);
        const bytes = try string_mod.unescape(self.gpa, raw[1 .. raw.len - 1]);
        defer self.gpa.free(bytes);
        const global = try self.strings.globalFor(bytes);

        const repr = try self.ctx.buildAllocaBytes(self.ptr_ty, string_mod.total_size);
        _ = try self.ctx.buildStore(self.i64_ty, repr, try self.ctx.buildIntConst(self.i64_ty, @intCast(bytes.len)));
        const data = try self.ctx.buildGlobalAddr(self.ptr_ty, global);
        const data_addr = try self.ctx.buildPtrAdd(self.ptr_ty, repr, try self.ctx.buildIntConst(self.i64_ty, @intCast(string_mod.data_offset)));
        _ = try self.ctx.buildStore(self.i64_ty, data_addr, data);
        return repr;
    }

    fn lowerIdentifier(self: *Lowerer, node_idx: NodeIdx, id: StringRef) !api.Value {
        const name = self.nameSlice(id);
        if (self.params.get(name)) |param| return param.value;
        if (self.locals.get(name)) |binding| {
            return self.ctx.buildLoad(self.i64_ty, binding.value);
        }
        self.codegenError(node_idx, "unknown identifier '{s}'", .{name});
        return self.ctx.buildIntConst(self.i64_ty, 0);
    }

    fn lowerBinary(self: *Lowerer, node_idx: NodeIdx, b: anytype) !api.Value {
        if (b.op == .assign or b.op == .add_assign or b.op == .sub_assign or
            b.op == .mul_assign or b.op == .div_assign)
        {
            return self.lowerAssign(node_idx, b);
        }

        const lhs = try self.lowerExpr(b.left);
        const rhs = try self.lowerExpr(b.right);
        const left_ty = self.exprType(b.left);
        const sem = self.type_pool.get(left_ty);
        const is_float = sem == .float;
        const ir_ty = self.irTypeFor(left_ty);

        return switch (b.op) {
            .add => if (is_float) self.ctx.buildFAdd(ir_ty, lhs, rhs) else self.ctx.buildAdd(ir_ty, lhs, rhs),
            .sub => if (is_float) self.ctx.buildFSub(ir_ty, lhs, rhs) else self.ctx.buildSub(ir_ty, lhs, rhs),
            .mul => if (is_float) self.ctx.buildFMul(ir_ty, lhs, rhs) else self.ctx.buildMul(ir_ty, lhs, rhs),
            .div => if (is_float) self.ctx.buildFDiv(ir_ty, lhs, rhs) else if (sem.int.signed) self.ctx.buildSDiv(ir_ty, lhs, rhs) else self.ctx.buildUDiv(ir_ty, lhs, rhs),
            .mod => if (is_float) blk: {
                self.codegenError(node_idx, "modulo on float operands", .{});
                break :blk try self.ctx.buildIntConst(self.i64_ty, 0);
            } else if (sem.int.signed) self.ctx.buildSRem(ir_ty, lhs, rhs) else self.ctx.buildURem(ir_ty, lhs, rhs),
            .bit_and => self.ctx.buildAnd(ir_ty, lhs, rhs),
            .bit_or => self.ctx.buildOr(ir_ty, lhs, rhs),
            .bit_xor => self.ctx.buildXor(ir_ty, lhs, rhs),
            .shift_left => self.ctx.buildShl(ir_ty, lhs, rhs),
            .shift_right => self.ctx.buildShr(ir_ty, lhs, rhs),
            .eq, .ne, .lt, .gt, .le, .ge => self.lowerCompare(sem, ir_ty, b.op, lhs, rhs),
            .and_op => self.lowerLogicalAnd(b),
            .or_op => self.lowerLogicalOr(b),
            .range => blk: {
                self.codegenError(node_idx, "range expression outside of a for loop", .{});
                break :blk try self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .assign, .add_assign, .sub_assign, .mul_assign, .div_assign => unreachable,
        };
    }

    fn lowerCompare(self: *Lowerer, sem: SemType, ir_ty: api.TypeIdx, op: BinaryOp, lhs: api.Value, rhs: api.Value) !api.Value {
        if (sem == .float) {
            const cond: api.Opcode = switch (op) {
                .eq => .fcmp_oeq,
                .ne => .fcmp_one,
                .lt => .fcmp_olt,
                .le => .fcmp_ole,
                .gt => .fcmp_ogt,
                .ge => .fcmp_oge,
                else => unreachable,
            };
            return self.ctx.buildFCmp(cond, ir_ty, lhs, rhs);
        }
        const signed = sem == .int and sem.int.signed;
        const cond: api.Opcode = switch (op) {
            .eq => .icmp_eq,
            .ne => .icmp_ne,
            .lt => if (signed) .icmp_slt else .icmp_ult,
            .le => if (signed) .icmp_sle else .icmp_ule,
            .gt => if (signed) .icmp_sgt else .icmp_ugt,
            .ge => if (signed) .icmp_sge else .icmp_uge,
            else => unreachable,
        };
        return self.ctx.buildIcmp(cond, self.bool_ty, lhs, rhs);
    }

    fn lowerLogicalAnd(self: *Lowerer, b: anytype) !api.Value {
        const lhs = try self.lowerExpr(b.left);
        const rhs_block = try self.ctx.appendBlock();
        const false_block = try self.ctx.appendBlock();
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildCondBr(lhs, rhs_block, false_block);

        self.setBlock(rhs_block);
        const rhs = try self.lowerExpr(b.right);
        const has_rhs = !self.block_terminated;
        if (has_rhs) _ = try self.ctx.buildBr(merge);

        self.setBlock(false_block);
        const zero = try self.ctx.buildIntConst(self.bool_ty, 0);
        _ = try self.ctx.buildBr(merge);

        self.setBlock(merge);
        var incoming = std.ArrayList(api.PhiIncoming).empty;
        defer incoming.deinit(self.gpa);
        if (has_rhs) try incoming.append(self.gpa, .{ .value = rhs, .block = rhs_block });
        try incoming.append(self.gpa, .{ .value = zero, .block = false_block });
        return self.ctx.buildPhi(self.bool_ty, incoming.items);
    }

    fn lowerLogicalOr(self: *Lowerer, b: anytype) !api.Value {
        const lhs = try self.lowerExpr(b.left);
        const true_block = try self.ctx.appendBlock();
        const rhs_block = try self.ctx.appendBlock();
        const merge = try self.ctx.appendBlock();
        _ = try self.ctx.buildCondBr(lhs, true_block, rhs_block);

        self.setBlock(true_block);
        const one = try self.ctx.buildIntConst(self.bool_ty, 1);
        _ = try self.ctx.buildBr(merge);

        self.setBlock(rhs_block);
        const rhs = try self.lowerExpr(b.right);
        const has_rhs = !self.block_terminated;
        if (has_rhs) _ = try self.ctx.buildBr(merge);

        self.setBlock(merge);
        var incoming = std.ArrayList(api.PhiIncoming).empty;
        defer incoming.deinit(self.gpa);
        try incoming.append(self.gpa, .{ .value = one, .block = true_block });
        if (has_rhs) try incoming.append(self.gpa, .{ .value = rhs, .block = rhs_block });
        return self.ctx.buildPhi(self.bool_ty, incoming.items);
    }

    fn lowerAssign(self: *Lowerer, node_idx: NodeIdx, b: anytype) !api.Value {
        const addr = try self.lowerLvalue(b.left) orelse {
            self.codegenError(node_idx, "invalid assignment target", .{});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        };
        const rhs = try self.lowerExpr(b.right);

        if (b.op == .assign) {
            _ = try self.ctx.buildStore(self.i64_ty, addr, rhs);
            return rhs;
        }

        const cur = try self.ctx.buildLoad(self.i64_ty, addr);
        const sem = self.type_pool.get(self.checker.nodeType(b.left));
        const ir_ty = self.irTypeForSem(sem);
        const is_float = sem == .float;
        const result = switch (b.op) {
            .add_assign => if (is_float) try self.ctx.buildFAdd(ir_ty, cur, rhs) else try self.ctx.buildAdd(ir_ty, cur, rhs),
            .sub_assign => if (is_float) try self.ctx.buildFSub(ir_ty, cur, rhs) else try self.ctx.buildSub(ir_ty, cur, rhs),
            .mul_assign => if (is_float) try self.ctx.buildFMul(ir_ty, cur, rhs) else try self.ctx.buildMul(ir_ty, cur, rhs),
            .div_assign => if (is_float) try self.ctx.buildFDiv(ir_ty, cur, rhs) else if (sem.int.signed) try self.ctx.buildSDiv(ir_ty, cur, rhs) else try self.ctx.buildUDiv(ir_ty, cur, rhs),
            else => unreachable,
        };
        _ = try self.ctx.buildStore(self.i64_ty, addr, result);
        return result;
    }

    fn lowerUnary(self: *Lowerer, node_idx: NodeIdx, u: anytype) !api.Value {
        const operand = try self.lowerExpr(u.operand);
        const sem = self.type_pool.get(self.checker.nodeType(u.operand));
        const is_float = sem == .float;
        const ir_ty = self.irTypeFor(self.checker.nodeType(u.operand));

        return switch (u.op) {
            .neg => if (is_float)
                self.ctx.buildFSub(ir_ty, try self.ctx.buildFloatConst(ir_ty, 0.0), operand)
            else
                self.ctx.buildSub(ir_ty, try self.ctx.buildIntConst(ir_ty, 0), operand),
            .not => self.ctx.buildXor(self.bool_ty, operand, try self.ctx.buildIntConst(self.bool_ty, 1)),
            .bit_not => self.ctx.buildXor(ir_ty, operand, try self.ctx.buildIntConst(ir_ty, -1)),
            .ref, .mut_ref => self.lowerRef(node_idx, u.operand),
        };
    }

    /// `&x` / `&mut x`. An aggregate value (`struct`, `enum`, `String`, pointer)
    /// is already a pointer to its block under this lowering's value
    /// convention, so its reference is the value itself; this is what makes
    /// the free-function mutation model work — `scale(&mut v, 2.0)` passes the
    /// struct's block straight to `fn scale(v: &mut Vec2)`, and the callee's
    /// `&mut T` parameter arrives as that same pointer. A scalar local's
    /// reference is its stack slot; a scalar parameter (an SSA value with no
    /// address) is spilled to a fresh slot first.
    fn lowerRef(self: *Lowerer, node_idx: NodeIdx, operand_idx: NodeIdx) !api.Value {
        switch (self.type_pool.get(self.exprType(operand_idx))) {
            .struct_type,
            .enum_type,
            .string_type,
            .array,
            .pointer,
            .applied_struct,
            .applied_enum,
            => return self.lowerExpr(operand_idx),
            else => {},
        }

        const node = self.arena.get(operand_idx);
        if (node.* == .identifier) {
            const name = self.nameSlice(node.identifier);
            if (self.locals.get(name)) |binding| return binding.value;
            if (self.params.get(name)) |param| {
                const slot = try self.ctx.buildAllocaBytes(self.ptr_ty, 8);
                _ = try self.ctx.buildStore(self.i64_ty, slot, param.value);
                return slot;
            }
        }
        self.codegenError(node_idx, "cannot take a reference of this expression", .{});
        return self.ctx.buildIntConst(self.i64_ty, 0);
    }

    fn lowerCall(self: *Lowerer, node_idx: NodeIdx, c: anytype) !api.Value {
        // A composition chain: the result of a prelude composition call is
        // applied (`compose(f, g)(x)`, `curry(f)(a)(b)`, `uncurry(h)(a, b)`).
        // The chain is flattened so a statically known operand lowers to a
        // direct call (R31b).
        var applied_buf: [8]NodeIdx = undefined;
        if (self.matchCompositionChain(node_idx, &applied_buf)) |chain| {
            return self.lowerCompositionChain(chain);
        }
        return self.lowerCallPiped(node_idx, c.func, c.args.indices, null, null);
    }

    /// Lower a call, optionally with a piped value (R30): `piped` replaces the
    /// `_` hole at `hole`, or is prepended as argument 0 when there is no hole.
    fn lowerCallPiped(
        self: *Lowerer,
        node_idx: NodeIdx,
        func: NodeIdx,
        args: []const NodeIdx,
        piped: ?NodeIdx,
        hole: ?usize,
    ) !api.Value {
        const callee = self.arena.get(func);
        switch (callee.*) {
            .identifier => |id| {
                const name = self.nameSlice(id);
                if (ast.findEnumVariant(self.arena, self.source, self.checker.module_node, name)) |vi| {
                    var vals = try self.lowerArgs(args, piped, hole);
                    defer vals.deinit(self.gpa);
                    return self.lowerVariantInitValues(vi, vals.items);
                }
                // A local or parameter shadows any module-level name; it holds
                // a fn value, so the call goes through the record. A local
                // that holds a materialized composition is known statically,
                // so its application lowers to the expansion's own call
                // (R31b).
                if (self.locals.get(name)) |binding| {
                    if (binding.materialized) |desc| {
                        return self.lowerMaterializedCall(node_idx, desc, args, piped, hole);
                    }
                    return self.lowerCallIndirect(node_idx, func, args, piped, hole);
                }
                if (self.params.get(name) != null) {
                    return self.lowerCallIndirect(node_idx, func, args, piped, hole);
                }
                const sym = self.checker.scopes.scopes.items[0].symbols.get(name) orelse {
                    self.codegenError(node_idx, "unknown function '{s}'", .{name});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                };
                if (sym.kind == .prelude_fn) {
                    return self.lowerPreludeCall(node_idx, sym, args, piped, hole);
                }
                if (sym.kind != .function) {
                    self.codegenError(node_idx, "'{s}' is not a function", .{name});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                }
                // A generic fn is a template: the call names an *instance*,
                // which the checker resolved while type-checking the call
                // site (R21).
                if (self.checker.instanceForCallee(func)) |inst| {
                    return self.lowerInstanceCall(node_idx, inst, args, piped, hole);
                }
                const fidx = self.fn_by_node.get(sym.decl_node) orelse {
                    self.codegenError(node_idx, "function '{s}' has no lowering", .{name});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                };
                const ret_ir = self.irTypeFor(self.checker.nodeType(sym.decl_node));
                var vals = try self.lowerArgs(args, piped, hole);
                defer vals.deinit(self.gpa);
                // R14a: the callee carries a hidden env parameter; a direct
                // named call passes a null env. `main` is exempt (R15).
                if (!std.mem.eql(u8, name, "main")) {
                    const null_env = try self.ctx.buildIntConst(self.i64_ty, 0);
                    try vals.insert(self.gpa, 0, null_env);
                }
                return self.ctx.buildCall(fidx, ret_ir, vals.items);
            },
            .field_access => {
                // A struct field of fn type is an ordinary fn value; anything
                // else that reached here as a callee is a non-callable field.
                const sem = self.type_pool.get(self.exprType(func));
                if (sem == .function) return self.lowerCallIndirect(node_idx, func, args, piped, hole);
                const fa = self.arena.get(func).field_access;
                self.codegenError(node_idx, "'{s}' is not callable; call a free function or use a fn value", .{
                    self.nameSlice(fa.field),
                });
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .index_access, .generic_app => {
                // A type application in callee position (`first[i32](...)`)
                // names a generic fn: the call goes to the instance the
                // checker resolved for those type arguments (R21).
                if (self.checker.instanceForCallee(func)) |inst| {
                    return self.lowerInstanceCall(node_idx, inst, args, piped, hole);
                }
                return self.lowerCallIndirect(node_idx, func, args, piped, hole);
            },
            else => return self.lowerCallIndirect(node_idx, func, args, piped, hole),
        }
    }

    /// Lower a call to a monomorphized instance: a direct call to the
    /// instance's function, with a null env in the hidden argument slot
    /// (R14a — an instance never captures anything).
    fn lowerInstanceCall(
        self: *Lowerer,
        node_idx: NodeIdx,
        inst: *GenericInstance,
        args: []const NodeIdx,
        piped: ?NodeIdx,
        hole: ?usize,
    ) !api.Value {
        const fidx = self.fn_by_node.get(inst.clone) orelse {
            self.codegenError(node_idx, "instance '{s}' has no lowering", .{inst.mangled});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        };
        var vals = try self.lowerArgs(args, piped, hole);
        defer vals.deinit(self.gpa);
        const null_env = try self.ctx.buildIntConst(self.i64_ty, 0);
        try vals.insert(self.gpa, 0, null_env);
        const ret_ir = self.irTypeFor(inst.return_type);
        return self.ctx.buildCall(fidx, ret_ir, vals.items);
    }

    /// Lower a call through a fn value: the callee expression is a `{ fn_ptr,
    /// env_ptr }` record and the call goes through `call_ptr`, which marshals
    /// the record's env as the callee's hidden argument 0 (R14b/R16c). This
    /// covers a local holding a closure, a curried `f(x)(y)`, a fn value in a
    /// struct field, and a pipeline into a bare fn value.
    fn lowerCallIndirect(
        self: *Lowerer,
        node_idx: NodeIdx,
        func: NodeIdx,
        args: []const NodeIdx,
        piped: ?NodeIdx,
        hole: ?usize,
    ) !api.Value {
        const callee_ty = self.exprType(func);
        const sem = self.type_pool.get(callee_ty);
        if (sem != .function) {
            self.codegenError(node_idx, "callee is not a function value", .{});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        }
        const callee = try self.lowerExpr(func);
        var vals = try self.lowerArgs(args, piped, hole);
        defer vals.deinit(self.gpa);
        const ret_ir = self.irTypeFor(sem.function.return_type);
        return self.ctx.buildCallPtr(ret_ir, callee, vals.items);
    }

    /// Lower a bare function name in value position (the resolver rewrote it
    /// to `fn_ref`): pair the function's address with a null env into a fn
    /// value (R3a — non-capturing callees ignore the env slot, R14).
    fn lowerFnRef(self: *Lowerer, node_idx: NodeIdx, id: StringRef) !api.Value {
        const name = self.nameSlice(id);
        const sym = self.checker.scopes.scopes.items[0].symbols.get(name) orelse {
            self.codegenError(node_idx, "unknown function '{s}'", .{name});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        };
        if (sym.kind != .function) {
            self.codegenError(node_idx, "'{s}' is not a function", .{name});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        }
        const fidx = self.fn_by_node.get(sym.decl_node) orelse {
            self.codegenError(node_idx, "function '{s}' has no lowering", .{name});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        };
        const fv_ty = try self.fnValueTypeForDecl(sym.decl_node);
        const fn_addr = try self.ctx.buildFuncAddr(self.i64_ty, fidx);
        const null_env = try self.ctx.buildIntConst(self.i64_ty, 0);
        return self.ctx.buildFnValue(fv_ty, fn_addr, null_env);
    }

    /// Lower a closure literal: lift its body into a module-level IR function
    /// with the uniform env-first ABI (visible params at slots 1..n, env at
    /// slot 0), copy the captured set by value into a stack env record at the
    /// literal's site, and pair the lifted callee's address with the record
    /// (docs/semantics.md §5.2, §6.2). An empty capture set produces no record
    /// and pairs with a null env (R8b).
    fn lowerClosure(self: *Lowerer, node_idx: NodeIdx, cl: anytype) !api.Value {
        const fn_sem = self.type_pool.get(self.exprType(node_idx));
        if (fn_sem != .function) {
            self.codegenError(node_idx, "closure without a function type", .{});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        }
        const fv_ty = try self.fnValueTypeForFn(fn_sem);
        const ret_ir = self.irTypeFor(fn_sem.function.return_type);

        // Lift the body into its own function; pass 2 lowers it after the
        // current body (the all_functions list is walked by index).
        const name = try std.fmt.allocPrint(self.gpa, "closure_{d}", .{self.closure_counter});
        defer self.gpa.free(name);
        self.closure_counter += 1;
        const fidx = try self.ctx.addFunction(name, ret_ir, @as(u32, @intCast(cl.params.indices.len)) + 1);
        try self.all_functions.append(self.gpa, .{ .body = .{ .closure = node_idx }, .idx = fidx });

        // Env record: one slot per capture, each copied by value at the site
        // (R8c). A fn-value capture stores its two words inline (R16d).
        var fields = std.ArrayList(api.EnvField).empty;
        defer fields.deinit(self.gpa);
        for (cl.env.indices) |decl_idx| {
            const cap_ty = try self.captureType(decl_idx);
            try fields.append(self.gpa, .{
                .type_idx = try self.fieldIrType(cap_ty),
                .value = try self.captureValue(decl_idx),
            });
        }
        const env = try self.ctx.buildEnvRecord(fields.items);
        const env_ptr = if (env == .none) try self.ctx.buildIntConst(self.i64_ty, 0) else env;

        const fn_addr = try self.ctx.buildFuncAddr(self.i64_ty, fidx);
        return self.ctx.buildFnValue(fv_ty, fn_addr, env_ptr);
    }

    /// Lower `lhs |> rhs` (R30): the piped value is the callee's argument 0
    /// (or replaces the single `_` hole). A bare-fn rhs is an ordinary call
    /// with one argument, so named fns stay direct calls and fn values go
    /// through `call_ptr`.
    fn lowerPipeline(self: *Lowerer, node_idx: NodeIdx, p: anytype) !api.Value {
        const rhs = self.arena.get(p.rhs);
        if (rhs.* == .call) {
            const c = rhs.call;
            var hole: ?usize = null;
            for (c.args.indices, 0..) |arg_idx, i| {
                if (self.isHole(arg_idx)) {
                    hole = i;
                    break;
                }
            }
            return self.lowerCallPiped(node_idx, c.func, c.args.indices, p.lhs, hole);
        }
        // Bare callee (named fn, fn value, closure, or enum variant): the
        // piped value is its single argument.
        return self.lowerCallPiped(node_idx, p.rhs, &.{}, p.lhs, null);
    }

    /// `_` in a piped call's argument list (R30a).
    fn isHole(self: *Lowerer, node_idx: NodeIdx) bool {
        const node = self.arena.get(node_idx);
        return node.* == .identifier and std.mem.eql(u8, self.nameSlice(node.identifier), "_");
    }

    /// Lower a prelude call.
    ///
    /// An IO entry (`print`) names a runtime symbol, so the call becomes a
    /// named symbol in the object file and the linker resolves it against
    /// `libs/std`. Arguments are already IR values in the platform ABI, so a
    /// `String` argument arrives as the pointer `lowerString` built — exactly
    /// what the runtime's `*const String` parameter expects, with no
    /// marshalling in between. Extern C calls keep the plain C ABI: no
    /// hidden env parameter (R17).
    ///
    /// A composition entry has no runtime identity (R31c): it is a source
    /// expansion over ordinary functions, so the lowerer materializes it as
    /// direct calls and stack env records.
    fn lowerPreludeCall(
        self: *Lowerer,
        node_idx: NodeIdx,
        sym: scope_mod.Symbol,
        args: []const NodeIdx,
        piped: ?NodeIdx,
        hole: ?usize,
    ) !api.Value {
        if (sym.prelude.index >= prelude.roster.len) {
            self.codegenError(node_idx, "prelude function '{s}' is not in the roster", .{
                sym.displayName(self.source),
            });
            return self.ctx.buildIntConst(self.i64_ty, 0);
        }
        const entry = prelude.roster[sym.prelude.index];

        switch (entry.kind) {
            .io => {
                var vals = try self.lowerArgs(args, piped, hole);
                defer vals.deinit(self.gpa);
                return self.ctx.buildExternCall(entry.symbol.?, self.void_ty, vals.items);
            },
            .composition => {
                const shape = entry.shape.?;
                var buf: [8]NodeIdx = undefined;
                const operands = effectiveArgNodes(args, piped, hole, &buf) orelse {
                    self.codegenError(node_idx, "too many arguments to prelude function '{s}'", .{entry.name});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                };
                const chain = CompositionChain{
                    .shape = shape,
                    .operands = operands,
                    .applied = &.{},
                    .root = node_idx,
                };
                return self.lowerCompositionChain(chain);
            },
        }
    }

    // ========================================================================
    // Composition prelude (R31)
    // ========================================================================

    /// The number of applications a shape's expansion takes after its own
    /// operands: `compose(f, g)` takes one (`x`), `curry(f)` takes two
    /// (`a`, `b`), `uncurry(h)` takes two, `id`/`pipe` take none.
    fn shapeApplications(shape: prelude.Shape) usize {
        return switch (shape) {
            .id, .pipe => 0,
            .compose => 1,
            .curry, .uncurry => 2,
        };
    }

    /// The prelude roster entry named `name`, when the name is one.
    fn preludeEntry(self: *Lowerer, name: []const u8) ?prelude.PreludeFn {
        const sym = self.checker.scopes.scopes.items[0].symbols.get(name) orelse return null;
        if (sym.kind != .prelude_fn) return null;
        if (sym.prelude.index >= prelude.roster.len) return null;
        return prelude.roster[sym.prelude.index];
    }

    /// Match a composition chain (R31).
    ///
    /// A composition's result is applied: `compose(f, g)(x)`,
    /// `curry(f)(a)(b)`, `uncurry(h)(a, b)`. The chain is walked from the
    /// outermost call down to the prelude call at its root; every level above
    /// the root contributes one application, and the applications are
    /// collected in evaluation order — the innermost level first.
    fn matchCompositionChain(self: *Lowerer, node_idx: NodeIdx, applied_buf: *[8]NodeIdx) ?CompositionChain {
        var levels: [8]NodeList = undefined;
        var n_levels: usize = 0;
        var cur = node_idx;
        while (true) {
            const node = self.arena.get(cur);
            if (node.* != .call) return null;
            const c = node.call;
            const callee = self.arena.get(c.func);
            if (callee.* == .identifier) {
                const entry = self.preludeEntry(self.nameSlice(callee.identifier)) orelse return null;
                if (entry.kind != .composition) return null;
                // The root is the prelude call; the levels above it apply its
                // result. Evaluation order runs from the innermost level out.
                var n: usize = 0;
                var i = n_levels;
                while (i > 0) {
                    i -= 1;
                    for (levels[i].indices) |arg| {
                        if (n >= applied_buf.len) return null;
                        applied_buf[n] = arg;
                        n += 1;
                    }
                }
                return .{
                    .shape = entry.shape.?,
                    .operands = c.args.indices,
                    .applied = applied_buf[0..n],
                    .root = cur,
                };
            }
            if (n_levels >= levels.len) return null;
            levels[n_levels] = c.args;
            n_levels += 1;
            cur = c.func;
        }
    }

    /// The effective argument list of a prelude call: the piped value
    /// replaces the `_` hole (R30a) or is prepended as argument 0 (R30b).
    fn effectiveArgNodes(
        args: []const NodeIdx,
        piped: ?NodeIdx,
        hole: ?usize,
        buf: *[8]NodeIdx,
    ) ?[]const NodeIdx {
        var n: usize = 0;
        if (piped) |p| {
            if (hole) |h| {
                for (args, 0..) |arg, i| {
                    if (n >= buf.len) return null;
                    buf[n] = if (i == h) p else arg;
                    n += 1;
                }
            } else {
                if (n >= buf.len) return null;
                buf[n] = p;
                n += 1;
                for (args) |arg| {
                    if (n >= buf.len) return null;
                    buf[n] = arg;
                    n += 1;
                }
            }
        } else {
            for (args) |arg| {
                if (n >= buf.len) return null;
                buf[n] = arg;
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// Apply a materialized composition (R31b).
    ///
    /// The composition's expansion is known statically, so the application
    /// lowers to the expansion's own call: `curry(f)` applied to `a`
    /// materializes the inner closure `|b| f(a, b)` right here — its env
    /// record lives in this frame, where it stays alive — and the inner
    /// closure applied to `b` is a direct call to the lifted function.
    fn lowerMaterializedCall(
        self: *Lowerer,
        node_idx: NodeIdx,
        desc: Materialized,
        args: []const NodeIdx,
        piped: ?NodeIdx,
        hole: ?usize,
    ) !api.Value {
        var buf: [8]NodeIdx = undefined;
        const effective = effectiveArgNodes(args, piped, hole, &buf) orelse {
            self.codegenError(node_idx, "too many arguments to a curried function", .{});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        };
        switch (desc) {
            .curry_outer => |d| {
                if (effective.len != 1) {
                    self.codegenError(node_idx, "a curried function takes one argument, got {d}", .{effective.len});
                    return self.ctx.buildIntConst(self.i64_ty, 0);
                }
                const a = try self.lowerExpr(effective[0]);
                return self.materializeCurryInner(d.f, a, d.chain);
            },
            .curry_inner => |d| {
                var vals = try self.lowerArgValues(effective);
                defer vals.deinit(self.gpa);
                var call_args = std.ArrayList(api.Value).empty;
                defer call_args.deinit(self.gpa);
                // The lifted function takes its env record as hidden
                // argument 0 (R14a).
                try call_args.append(self.gpa, d.env);
                for (vals.items) |v| try call_args.append(self.gpa, v);
                return self.ctx.buildCall(d.fidx, d.ret, call_args.items);
            },
        }
    }

    /// Lower a composition chain (R31).
    ///
    /// The expansion is flattened: a statically known operand lowers to a
    /// direct call (R31b), so `curry(add)(1)(2)` is one `call @fn0(...)`
    /// with no `call_ptr` at all. A composition whose result is *not* fully
    /// applied is materialized as a closure — a lifted function plus a stack
    /// env record (R31c).
    fn lowerCompositionChain(self: *Lowerer, chain: CompositionChain) !api.Value {
        const expected = shapeApplications(chain.shape);
        if (chain.applied.len <= expected) {
            return self.lowerCompositionExpanded(chain, chain.applied);
        }
        // The expansion's result is itself applied: `id(f)(x)` is `f(x)`.
        const value = try self.lowerCompositionExpanded(chain, chain.applied[0..expected]);
        var vals = try self.lowerArgValues(chain.applied[expected..]);
        defer vals.deinit(self.gpa);
        const result = try self.applyFnValue(value, vals.items, self.compositionResultType(chain));
        self.pending_materialized = null;
        return result;
    }

    /// Lower a composition's expansion with the given applications.
    fn lowerCompositionExpanded(self: *Lowerer, chain: CompositionChain, applied: []const NodeIdx) !api.Value {
        switch (chain.shape) {
            .id => {
                if (applied.len == 0) return self.lowerExpr(chain.operands[0]);
                // `id(f)(x)` is `f(x)`.
                const f = try self.classifyCallee(chain.operands[0]);
                var vals = try self.lowerArgValues(applied);
                defer vals.deinit(self.gpa);
                const result = try self.callOperand(f, vals.items);
                self.pending_materialized = null;
                return result;
            },
            .pipe => {
                const x = try self.lowerExpr(chain.operands[0]);
                const f = try self.classifyCallee(chain.operands[1]);
                var vals = std.ArrayList(api.Value).empty;
                defer vals.deinit(self.gpa);
                try vals.append(self.gpa, x);
                const result = try self.callOperand(f, vals.items);
                self.pending_materialized = null;
                return result;
            },
            .compose => {
                const f = try self.classifyCallee(chain.operands[0]);
                const g = try self.classifyCallee(chain.operands[1]);
                if (applied.len == 0) return self.materializeCompose(f, g, chain);
                const x = try self.lowerExpr(applied[0]);
                const gx = try self.callOperand(g, &.{x});
                const result = try self.callOperand(f, &.{gx});
                self.pending_materialized = null;
                return result;
            },
            .curry => {
                const f = try self.classifyCallee(chain.operands[0]);
                if (applied.len == 2) {
                    const a = try self.lowerExpr(applied[0]);
                    const b = try self.lowerExpr(applied[1]);
                    const result = try self.callOperand(f, &.{ a, b });
                    self.pending_materialized = null;
                    return result;
                }
                if (applied.len == 1) {
                    const a = try self.lowerExpr(applied[0]);
                    return self.materializeCurryInner(f, a, chain);
                }
                return self.materializeCurryOuter(f, chain);
            },
            .uncurry => {
                // `uncurry(curry(f))` is `f` (R31a): the pair list applies
                // `f`'s own argument list, and the unapplied form is `f`'s fn
                // value. Fusing the pair also keeps the intermediate inner
                // closure out of the expansion — its env record would be
                // built in the `curry_outer` frame and die with it.
                if (try self.curryOperand(chain.operands[0])) |f| {
                    switch (applied.len) {
                        2 => {
                            const a = try self.lowerExpr(applied[0]);
                            const b = try self.lowerExpr(applied[1]);
                            self.pending_materialized = null;
                            return self.callOperand(f, &.{ a, b });
                        },
                        1 => {
                            const a = try self.lowerExpr(applied[0]);
                            // The node passed to `uncurry` has type
                            // `fn(A) -> fn(B) -> R`, which is exactly the
                            // type shape `curry`'s inner closure is derived
                            // from.
                            const sub_chain = CompositionChain{
                                .shape = .curry,
                                .operands = chain.operands,
                                .applied = &.{},
                                .root = chain.operands[0],
                            };
                            return self.materializeCurryInner(f, a, sub_chain);
                        },
                        else => {
                            self.pending_materialized = null;
                            return self.fnValueOf(f);
                        },
                    }
                }
                const h = try self.classifyCallee(chain.operands[0]);
                if (applied.len == 2) {
                    const a = try self.lowerExpr(applied[0]);
                    const b = try self.lowerExpr(applied[1]);
                    const inner = try self.callOperand(h, &.{a});
                    // `h(a)` is the inner closure; `b` is applied to it.
                    const result = try self.applyFnValue(inner, &.{b}, self.calleeReturnType(chain.operands[0]));
                    self.pending_materialized = null;
                    return result;
                }
                return self.materializeUncurry(h, chain);
            },
        }
    }

    /// The semantic type of the value a composition's expansion produces.
    fn compositionResultType(self: *Lowerer, chain: CompositionChain) TypeIdx {
        return switch (chain.shape) {
            .id => self.exprType(chain.operands[0]),
            .pipe => self.calleeReturnType(chain.operands[1]),
            .compose, .curry => self.calleeReturnType(chain.operands[0]),
            .uncurry => blk: {
                const inner = self.type_pool.get(self.calleeReturnType(chain.operands[0]));
                if (inner != .function) break :blk self.checker.void_ty;
                break :blk inner.function.return_type;
            },
        };
    }

    /// The semantic type of a callee's result.
    fn calleeReturnType(self: *Lowerer, node_idx: NodeIdx) TypeIdx {
        const sem = self.type_pool.get(self.exprType(node_idx));
        switch (sem) {
            .function => |f| return f.return_type,
            .applied_fn => |a| {
                const sig = self.type_pool.get(a.sig);
                if (sig == .function) return sig.function.return_type;
            },
            else => {},
        }
        return self.checker.void_ty;
    }

    /// Apply a fn value to already-lowered arguments (R16c): the callee's
    /// visible signature drives the call's result type.
    fn applyFnValue(self: *Lowerer, callee: api.Value, args: []const api.Value, fn_ty: TypeIdx) !api.Value {
        const sem = self.type_pool.get(fn_ty);
        if (sem != .function) {
            self.codegenError(NodeIdx.none, "a composition result is not a function", .{});
            return self.ctx.buildIntConst(self.i64_ty, 0);
        }
        return self.ctx.buildCallPtr(self.irTypeFor(sem.function.return_type), callee, args);
    }

    /// Classify a composition operand that is applied to arguments.
    ///
    /// A statically known module-level `fn` is called directly (R31b); every
    /// other operand is a fn value and goes through `call_ptr` (R16c).
    fn classifyCallee(self: *Lowerer, node_idx: NodeIdx) !Operand {
        const node = self.arena.get(node_idx);
        if (node.* == .fn_ref) {
            const name = self.nameSlice(node.fn_ref);
            const sym = self.checker.scopes.scopes.items[0].symbols.get(name);
            if (sym != null and sym.?.kind == .function) {
                const decl = sym.?.decl_node;
                if (self.fn_by_node.get(decl)) |fidx| {
                    return .{ .direct = .{
                        .fidx = fidx,
                        .ret = self.irTypeFor(self.checker.nodeType(decl)),
                        .fv_ty = try self.fnValueTypeForDecl(decl),
                    } };
                }
            }
        }
        const sem = self.type_pool.get(self.exprType(node_idx));
        if (sem != .function) {
            self.codegenError(node_idx, "a composition operand is not a function", .{});
            return .{ .fn_value = .{
                .value = try self.ctx.buildIntConst(self.i64_ty, 0),
                .fv_ty = self.i64_ty,
                .ret = self.i64_ty,
            } };
        }
        const value = try self.lowerExpr(node_idx);
        return .{ .fn_value = .{
            .value = value,
            .fv_ty = try self.fnValueTypeForFn(sem),
            .ret = self.irTypeFor(sem.function.return_type),
        } };
    }

    /// Call a composition operand with already-lowered arguments.
    fn callOperand(self: *Lowerer, op: Operand, args: []const api.Value) !api.Value {
        switch (op) {
            .direct => |d| {
                var vals = std.ArrayList(api.Value).empty;
                defer vals.deinit(self.gpa);
                // R14a: the callee carries a hidden env parameter; a direct
                // named call passes a null env.
                try vals.append(self.gpa, try self.ctx.buildIntConst(self.i64_ty, 0));
                for (args) |a| try vals.append(self.gpa, a);
                return self.ctx.buildCall(d.fidx, d.ret, vals.items);
            },
            .fn_value => |fv| {
                return self.ctx.buildCallPtr(fv.ret, fv.value, args);
            },
        }
    }

    /// The operand of a `curry(f)` the lowerer can see through (R31a): a
    /// directly applied `curry` call, or a local known to hold one. Matching
    /// the pair in `uncurry(curry(f))` lets the expansion produce `f` itself
    /// instead of an intermediate inner closure.
    fn curryOperand(self: *Lowerer, node_idx: NodeIdx) !?Operand {
        var buf: [8]NodeIdx = undefined;
        if (self.matchCompositionChain(node_idx, &buf)) |chain| {
            if (chain.shape == .curry and chain.applied.len == 0) {
                return try self.classifyCallee(chain.operands[0]);
            }
        }
        const node = self.arena.get(node_idx);
        if (node.* == .identifier) {
            if (self.locals.get(self.nameSlice(node.identifier))) |binding| {
                if (binding.materialized) |desc| {
                    switch (desc) {
                        .curry_outer => |d| return d.f,
                        .curry_inner => {},
                    }
                }
            }
        }
        return null;
    }

    /// The fn value of a composition operand. A statically known module-level
    /// `fn` pairs its address with a null env (R3a/R14); a fn value is
    /// already that record.
    fn fnValueOf(self: *Lowerer, op: Operand) !api.Value {
        switch (op) {
            .direct => |d| {
                const fn_addr = try self.ctx.buildFuncAddr(self.i64_ty, d.fidx);
                const null_env = try self.ctx.buildIntConst(self.i64_ty, 0);
                return self.ctx.buildFnValue(d.fv_ty, fn_addr, null_env);
            },
            .fn_value => |fv| return fv.value,
        }
    }

    /// Lower an argument list into IR values.
    fn lowerArgValues(self: *Lowerer, args: []const NodeIdx) !std.ArrayList(api.Value) {
        var vals = std.ArrayList(api.Value).empty;
        errdefer vals.deinit(self.gpa);
        for (args) |arg| {
            try vals.append(self.gpa, try self.lowerExpr(arg));
        }
        return vals;
    }

    /// The env representation of a composition operand.
    fn captureOf(op: Operand) Capture {
        return switch (op) {
            .direct => |d| .{ .direct = d },
            .fn_value => |fv| .{ .fn_value = .{ .fv_ty = fv.fv_ty, .ret = fv.ret } },
        };
    }

    /// The runtime value of a composition operand, when it has one.
    fn operandValue(op: Operand) ?api.Value {
        return switch (op) {
            .direct => null,
            .fn_value => |fv| fv.value,
        };
    }

    /// The env representation of a captured value: a fn value is stored
    /// inline as its 16-byte record, anything else as one 8-byte slot.
    fn argumentCapture(self: *Lowerer, sem_ty: TypeIdx) !Capture {
        const sem = self.type_pool.get(sem_ty);
        switch (sem) {
            .function => |f| {
                return .{ .fn_value = .{
                    .fv_ty = try self.fnValueTypeForFn(sem),
                    .ret = self.irTypeFor(f.return_type),
                } };
            },
            else => {},
        }
        return .{ .value = self.irTypeForSem(sem) };
    }

    /// The semantic type of a composition's root call.
    fn chainType(self: *Lowerer, chain: CompositionChain) SemType {
        return self.type_pool.get(self.checker.nodeType(chain.root));
    }

    /// The type of `curry`'s first argument — the type the inner closure
    /// captures.
    fn curryArgType(self: *Lowerer, chain: CompositionChain) TypeIdx {
        const sem = self.chainType(chain);
        if (sem != .function or sem.function.param_types.len == 0) return self.checker.void_ty;
        return sem.function.param_types[0];
    }

    /// The `fn(B) -> R` type of `curry`'s inner closure.
    fn curryInnerType(self: *Lowerer, chain: CompositionChain) TypeIdx {
        const sem = self.chainType(chain);
        if (sem != .function) return self.checker.void_ty;
        return sem.function.return_type;
    }

    /// The IR `function_value` type of `curry`'s inner closure.
    fn curryInnerFvType(self: *Lowerer, chain: CompositionChain) !api.TypeIdx {
        const sem = self.type_pool.get(self.curryInnerType(chain));
        if (sem != .function) return self.i64_ty;
        return self.fnValueTypeForFn(sem);
    }

    /// The IR `function_value` type of the whole composition — the type of
    /// the closure a materialization produces.
    fn compositionFvType(self: *Lowerer, chain: CompositionChain) !api.TypeIdx {
        const sem = self.chainType(chain);
        if (sem != .function) return self.i64_ty;
        return self.fnValueTypeForFn(sem);
    }

    /// A unique name for a lifted composition function.
    fn compositionName(self: *Lowerer, prefix: []const u8) ![]const u8 {
        const name = try std.fmt.allocPrint(self.gpa, "{s}_{d}", .{ prefix, self.composition_counter });
        self.composition_counter += 1;
        return name;
    }

    /// Build an env record for a composition's captures, copying each
    /// capture by value into its slot (R8c).
    fn buildCompositionEnv(self: *Lowerer, slots: []const EnvSlot) !api.Value {
        var fields = std.ArrayList(api.EnvField).empty;
        defer fields.deinit(self.gpa);
        for (slots) |slot| {
            switch (slot.capture) {
                .direct => {},
                .fn_value => |fv| {
                    try fields.append(self.gpa, .{ .type_idx = fv.fv_ty, .value = slot.value });
                },
                .value => |ty| {
                    try fields.append(self.gpa, .{ .type_idx = ty, .value = slot.value });
                },
            }
        }
        const env = try self.ctx.buildEnvRecord(fields.items);
        if (env == .none) return try self.ctx.buildIntConst(self.i64_ty, 0);
        return env;
    }

    /// Materialize `compose(f, g)` as a closure (R31c): the lifted function
    /// takes `x` and computes `f(g(x))`, capturing `f` and `g`.
    fn materializeCompose(self: *Lowerer, f: Operand, g: Operand, chain: CompositionChain) !api.Value {
        const f_capture = captureOf(f);
        const g_capture = captureOf(g);
        const sem = self.chainType(chain);
        const ret: api.TypeIdx = if (sem == .function) self.irTypeFor(sem.function.return_type) else self.i64_ty;

        const name = try self.compositionName("compose");
        defer self.gpa.free(name);
        const fidx = try self.ctx.addFunction(name, ret, 2);
        try self.all_functions.append(self.gpa, .{
            .body = .{ .composition = .{ .compose = .{ .f = f_capture, .g = g_capture } } },
            .idx = fidx,
        });

        var slots: [2]EnvSlot = undefined;
        var n: usize = 0;
        if (operandValue(f)) |v| {
            slots[n] = .{ .capture = f_capture, .value = v };
            n += 1;
        }
        if (operandValue(g)) |v| {
            slots[n] = .{ .capture = g_capture, .value = v };
            n += 1;
        }
        const env = try self.buildCompositionEnv(slots[0..n]);
        const fn_addr = try self.ctx.buildFuncAddr(self.i64_ty, fidx);
        self.pending_materialized = null;
        return self.ctx.buildFnValue(try self.compositionFvType(chain), fn_addr, env);
    }

    /// Materialize `curry(f)` as a closure (R31c): the outer lifted function
    /// takes `a` and returns the inner closure `|b| f(a, b)`, which captures
    /// `f` and `a`.
    fn materializeCurryOuter(self: *Lowerer, f: Operand, chain: CompositionChain) !api.Value {
        const f_capture = captureOf(f);
        const a_capture = try self.argumentCapture(self.curryArgType(chain));
        const inner_fv_ty = try self.curryInnerFvType(chain);
        const inner_sem = self.type_pool.get(self.curryInnerType(chain));
        const inner_ret: api.TypeIdx = if (inner_sem == .function)
            self.irTypeFor(inner_sem.function.return_type)
        else
            self.i64_ty;

        // The inner closure `|b| f(a, b)`.
        const inner_name = try self.compositionName("curry_inner");
        defer self.gpa.free(inner_name);
        const inner_fidx = try self.ctx.addFunction(inner_name, inner_ret, 2);
        try self.all_functions.append(self.gpa, .{
            .body = .{ .composition = .{ .curry_inner = .{ .f = f_capture, .a = a_capture } } },
            .idx = inner_fidx,
        });

        // The outer closure `|a| |b| f(a, b)`.
        const outer_name = try self.compositionName("curry_outer");
        defer self.gpa.free(outer_name);
        const outer_fidx = try self.ctx.addFunction(outer_name, inner_fv_ty, 2);
        try self.all_functions.append(self.gpa, .{
            .body = .{ .composition = .{ .curry_outer = .{
                .f = f_capture,
                .a = a_capture,
                .inner = inner_fidx,
                .inner_fv_ty = inner_fv_ty,
            } } },
            .idx = outer_fidx,
        });

        // The outer's env record holds `f`; `a` arrives as its argument.
        var slots: [1]EnvSlot = undefined;
        var n: usize = 0;
        if (operandValue(f)) |v| {
            slots[n] = .{ .capture = f_capture, .value = v };
            n += 1;
        }
        const env = try self.buildCompositionEnv(slots[0..n]);
        const fn_addr = try self.ctx.buildFuncAddr(self.i64_ty, outer_fidx);
        // The binding that holds this value knows the composition, so an
        // application of it materializes the inner closure at the
        // application site (R31b).
        self.pending_materialized = .{ .curry_outer = .{ .f = f, .chain = chain } };
        return self.ctx.buildFnValue(try self.compositionFvType(chain), fn_addr, env);
    }

    /// Materialize `curry(f)(a)` as a closure (R31c): the lifted function
    /// takes `b` and calls `f(a, b)`, capturing `f` and `a`.
    fn materializeCurryInner(self: *Lowerer, f: Operand, a: api.Value, chain: CompositionChain) !api.Value {
        const f_capture = captureOf(f);
        const a_capture = try self.argumentCapture(self.curryArgType(chain));
        const inner_fv_ty = try self.curryInnerFvType(chain);
        const inner_sem = self.type_pool.get(self.curryInnerType(chain));
        const inner_ret: api.TypeIdx = if (inner_sem == .function)
            self.irTypeFor(inner_sem.function.return_type)
        else
            self.i64_ty;

        const name = try self.compositionName("curry_inner");
        defer self.gpa.free(name);
        const fidx = try self.ctx.addFunction(name, inner_ret, 2);
        try self.all_functions.append(self.gpa, .{
            .body = .{ .composition = .{ .curry_inner = .{ .f = f_capture, .a = a_capture } } },
            .idx = fidx,
        });

        var slots: [2]EnvSlot = undefined;
        var n: usize = 0;
        if (operandValue(f)) |v| {
            slots[n] = .{ .capture = f_capture, .value = v };
            n += 1;
        }
        slots[n] = .{ .capture = a_capture, .value = a };
        n += 1;
        const env = try self.buildCompositionEnv(slots[0..n]);
        const fn_addr = try self.ctx.buildFuncAddr(self.i64_ty, fidx);
        // The binding that holds this value knows the composition, so an
        // application of it is a direct call to the lifted inner function
        // (R31b).
        self.pending_materialized = .{ .curry_inner = .{ .fidx = fidx, .ret = inner_ret, .env = env } };
        return self.ctx.buildFnValue(inner_fv_ty, fn_addr, env);
    }

    /// Materialize `uncurry(h)` as a closure (R31c): the lifted function
    /// takes `a` and `b` and computes `h(a)(b)`, capturing `h`.
    fn materializeUncurry(self: *Lowerer, h: Operand, chain: CompositionChain) !api.Value {
        const h_capture = captureOf(h);
        const sem = self.chainType(chain);
        const ret: api.TypeIdx = if (sem == .function) self.irTypeFor(sem.function.return_type) else self.i64_ty;

        const name = try self.compositionName("uncurry");
        defer self.gpa.free(name);
        const fidx = try self.ctx.addFunction(name, ret, 3);
        try self.all_functions.append(self.gpa, .{
            .body = .{ .composition = .{ .uncurry = .{ .h = h_capture, .ret = ret } } },
            .idx = fidx,
        });

        var slots: [1]EnvSlot = undefined;
        var n: usize = 0;
        if (operandValue(h)) |v| {
            slots[n] = .{ .capture = h_capture, .value = v };
            n += 1;
        }
        const env = try self.buildCompositionEnv(slots[0..n]);
        const fn_addr = try self.ctx.buildFuncAddr(self.i64_ty, fidx);
        self.pending_materialized = null;
        return self.ctx.buildFnValue(try self.compositionFvType(chain), fn_addr, env);
    }

    // -----------------------------------------------------------------------
    // Lifted composition bodies
    // -----------------------------------------------------------------------

    fn lowerCompositionBody(self: *Lowerer, comp: CompositionBody) !void {
        switch (comp) {
            .compose => |c| try self.lowerComposeBody(c),
            .curry_outer => |c| try self.lowerCurryOuterBody(c),
            .curry_inner => |c| try self.lowerCurryInnerBody(c),
            .uncurry => |c| try self.lowerUncurryBody(c),
        }
    }

    /// `compose(f, g)`: `|x| f(g(x))`. The env record holds `f` and `g`.
    fn lowerComposeBody(self: *Lowerer, c: anytype) !void {
        const env = self.ctx.getParam(0);
        const x = self.ctx.getParam(1);
        const gx = try self.callCapture(c.g, env, captureSize(c.f), &.{x});
        const result = try self.callCapture(c.f, env, 0, &.{gx});
        _ = try self.ctx.buildRet(result);
        self.terminated();
    }

    /// `curry(f)`: `|a| |b| f(a, b)`. The env record holds `f`; the applied
    /// argument `a` arrives as the parameter and is copied into the inner
    /// closure's own env record.
    fn lowerCurryOuterBody(self: *Lowerer, c: anytype) !void {
        const env = self.ctx.getParam(0);
        const a = self.ctx.getParam(1);

        var slots: [2]EnvSlot = undefined;
        var n: usize = 0;
        switch (c.f) {
            .direct => {},
            .fn_value => {
                const record = try self.loadCapture(env, 0, c.f);
                slots[n] = .{ .capture = c.f, .value = record };
                n += 1;
            },
            .value => {},
        }
        slots[n] = .{ .capture = c.a, .value = a };
        n += 1;

        const inner_env = try self.buildCompositionEnv(slots[0..n]);
        const fn_addr = try self.ctx.buildFuncAddr(self.i64_ty, c.inner);
        const value = try self.ctx.buildFnValue(c.inner_fv_ty, fn_addr, inner_env);
        _ = try self.ctx.buildRet(value);
        self.terminated();
    }

    /// `curry(f)(a)`: `|b| f(a, b)`. The env record holds `f` and `a`.
    fn lowerCurryInnerBody(self: *Lowerer, c: anytype) !void {
        const env = self.ctx.getParam(0);
        const b = self.ctx.getParam(1);
        const a = try self.loadCapture(env, captureSize(c.f), c.a);
        const result = try self.callCapture(c.f, env, 0, &.{ a, b });
        _ = try self.ctx.buildRet(result);
        self.terminated();
    }

    /// `uncurry(h)`: `|a, b| h(a)(b)`. The env record holds `h`.
    fn lowerUncurryBody(self: *Lowerer, c: anytype) !void {
        const env = self.ctx.getParam(0);
        const a = self.ctx.getParam(1);
        const b = self.ctx.getParam(2);
        const inner = try self.callCapture(c.h, env, 0, &.{a});
        const result = try self.ctx.buildCallPtr(c.ret, inner, &.{b});
        _ = try self.ctx.buildRet(result);
        self.terminated();
    }

    /// Load a capture out of the env record (R8a): a fn value is copied into
    /// a fresh 16-byte record, a plain value is loaded from its slot.
    fn loadCapture(self: *Lowerer, env: api.Value, offset: u64, cap: Capture) !api.Value {
        const slot = try self.ctx.buildPtrAdd(
            self.ptr_ty,
            env,
            try self.ctx.buildIntConst(self.i64_ty, @intCast(offset)),
        );
        switch (cap) {
            .direct => {
                self.codegenError(NodeIdx.none, "a direct operand has no env slot", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
            .fn_value => {
                const record = try self.ctx.buildAllocaBytes(self.ptr_ty, api.fn_value_size);
                const word0 = try self.ctx.buildLoad(self.i64_ty, slot);
                _ = try self.ctx.buildStore(self.i64_ty, record, word0);
                const src1 = try self.ctx.buildPtrAdd(self.ptr_ty, slot, try self.ctx.buildIntConst(self.i64_ty, 8));
                const word1 = try self.ctx.buildLoad(self.i64_ty, src1);
                const dst1 = try self.ctx.buildPtrAdd(self.ptr_ty, record, try self.ctx.buildIntConst(self.i64_ty, 8));
                _ = try self.ctx.buildStore(self.i64_ty, dst1, word1);
                return record;
            },
            .value => |ty| {
                return self.ctx.buildLoad(ty, slot);
            },
        }
    }

    /// Call a captured operand from a lifted composition body: a statically
    /// known fn is called directly, a captured fn value through `call_ptr`.
    fn callCapture(
        self: *Lowerer,
        cap: Capture,
        env: api.Value,
        offset: u64,
        args: []const api.Value,
    ) !api.Value {
        switch (cap) {
            .direct => |d| {
                var vals = std.ArrayList(api.Value).empty;
                defer vals.deinit(self.gpa);
                try vals.append(self.gpa, try self.ctx.buildIntConst(self.i64_ty, 0));
                for (args) |a| try vals.append(self.gpa, a);
                return self.ctx.buildCall(d.fidx, d.ret, vals.items);
            },
            .fn_value => |fv| {
                const record = try self.loadCapture(env, offset, cap);
                return self.ctx.buildCallPtr(fv.ret, record, args);
            },
            .value => {
                self.codegenError(NodeIdx.none, "a plain value is not callable", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
        }
    }

    /// Lower an enum variant constructor (`Some(x)`): stack block with the
    /// variant index in slot 0 and payloads after it.
    fn lowerVariantInit(self: *Lowerer, vi: ast.EnumVariantInfo, c: anytype) !api.Value {
        var vals = try self.lowerArgs(c.args.indices, null, null);
        defer vals.deinit(self.gpa);
        return self.lowerVariantInitValues(vi, vals.items);
    }

    /// Lower an enum variant constructor from already-lowered payload values.
    fn lowerVariantInitValues(self: *Lowerer, vi: ast.EnumVariantInfo, values: []const api.Value) !api.Value {
        const variant = self.arena.get(vi.variant_node);
        const payload_count = variant.enum_variant.fields.indices.len;
        const block = try self.ctx.buildAllocaBytes(self.ptr_ty, enumSizeFor(payload_count));
        _ = try self.ctx.buildStore(self.i64_ty, block, try self.ctx.buildIntConst(self.i64_ty, @intCast(vi.index)));
        for (values, 0..) |val, i| {
            const addr = try self.ctx.buildPtrAdd(self.ptr_ty, block, try self.ctx.buildIntConst(self.i64_ty, @intCast(enumPayloadOffset(i))));
            _ = try self.ctx.buildStore(self.i64_ty, addr, val);
        }
        return block;
    }

    /// Lower an argument list, threading a piped value through it (R30):
    /// `piped` replaces the `_` hole at index `hole`, or is prepended as
    /// argument 0 when there is no hole.
    fn lowerArgs(
        self: *Lowerer,
        args: []const NodeIdx,
        piped: ?NodeIdx,
        hole: ?usize,
    ) !std.ArrayList(api.Value) {
        var vals = std.ArrayList(api.Value).empty;
        errdefer vals.deinit(self.gpa);
        if (piped) |p| {
            if (hole) |h| {
                for (args, 0..) |arg_idx, i| {
                    try vals.append(self.gpa, if (i == h) try self.lowerExpr(p) else try self.lowerExpr(arg_idx));
                }
            } else {
                try vals.append(self.gpa, try self.lowerExpr(p));
                for (args) |arg_idx| {
                    try vals.append(self.gpa, try self.lowerExpr(arg_idx));
                }
            }
        } else {
            for (args) |arg_idx| {
                try vals.append(self.gpa, try self.lowerExpr(arg_idx));
            }
        }
        return vals;
    }

    fn lowerStructInit(self: *Lowerer, node_idx: NodeIdx, si: anytype) !api.Value {
        const ty = self.checker.nodeType(si.ty);
        const sem = self.type_pool.get(ty);
        const decl_node = switch (sem) {
            // An applied struct has the layout of the declaration it was
            // instantiated from, with the type arguments substituted into
            // the field types (R20c, R25).
            .struct_type => |n| n,
            .applied_struct => |a| a.decl,
            else => {
                self.codegenError(node_idx, "struct init on a non-struct type", .{});
                return self.ctx.buildIntConst(self.i64_ty, 0);
            },
        };

        const base = try self.ctx.buildAllocaBytes(self.ptr_ty, structSize(self.arena, decl_node));

        const decl = self.arena.get(decl_node);
        const fields: []const NodeIdx = switch (decl.*) {
            .struct_decl => |s| s.fields.indices,
            else => &.{},
        };

        // Each field slot gets its initializer, or zero if omitted.
        for (fields, 0..) |field_idx, i| {
            const field_name = self.nameSlice(self.arena.get(field_idx).field.name);
            const offset: u64 = 8 * @as(u64, @intCast(i));
            var init_val: ?api.Value = null;
            for (si.fields.indices) |init_idx| {
                const init_field = self.arena.get(init_idx).struct_init_field;
                if (std.mem.eql(u8, self.nameSlice(init_field.name), field_name)) {
                    init_val = try self.lowerExpr(init_field.value);
                    break;
                }
            }
            const addr = try self.ctx.buildPtrAdd(self.ptr_ty, base, try self.ctx.buildIntConst(self.i64_ty, @intCast(offset)));
            if (init_val) |v| {
                _ = try self.ctx.buildStore(self.i64_ty, addr, v);
            } else {
                _ = try self.ctx.buildStore(self.i64_ty, addr, try self.ctx.buildIntConst(self.i64_ty, 0));
            }
        }
        return base;
    }

    fn lowerFieldAddr(self: *Lowerer, node_idx: NodeIdx, fa: anytype) anyerror!?api.Value {
        const obj = try self.lowerExpr(fa.object);
        const obj_ty = self.exprType(fa.object);
        const sem = self.type_pool.get(obj_ty);
        const field_name = self.nameSlice(fa.field);

        var decl_node: ?NodeIdx = null;
        switch (sem) {
            .struct_type => |n| decl_node = n,
            .applied_struct => |a| decl_node = a.decl,
            .pointer => |elem| switch (self.type_pool.get(elem)) {
                .struct_type => |n| decl_node = n,
                .applied_struct => |a| decl_node = a.decl,
                else => {},
            },
            else => {},
        }
        const target = decl_node orelse {
            self.codegenError(node_idx, "field access on a non-struct type", .{});
            return null;
        };

        const offset = structFieldOffset(self.arena, self.source, target, field_name);
        const off = offset orelse {
            self.codegenError(node_idx, "no such field '{s}'", .{field_name});
            return null;
        };

        const off_val = try self.ctx.buildIntConst(self.i64_ty, @intCast(off));
        return try self.ctx.buildPtrAdd(self.ptr_ty, obj, off_val);
    }

    fn lowerLvalue(self: *Lowerer, node_idx: NodeIdx) !?api.Value {
        const node = self.arena.get(node_idx);
        return switch (node.*) {
            .identifier => |id| blk: {
                const name = self.nameSlice(id);
                if (self.locals.get(name)) |binding| break :blk binding.value;
                if (self.params.get(name) != null) {
                    self.codegenError(node_idx, "cannot assign to parameter '{s}'", .{name});
                } else {
                    self.codegenError(node_idx, "unknown identifier '{s}'", .{name});
                }
                break :blk null;
            },
            .field_access => |fa| try self.lowerFieldAddr(node_idx, fa),
            else => null,
        };
    }

    // ========================================================================
    // Types
    // ========================================================================

    fn irTypeFor(self: *Lowerer, ty: TypeIdx) api.TypeIdx {
        return self.irTypeForSem(self.type_pool.get(ty));
    }

    fn irTypeForSem(self: *Lowerer, sem: SemType) api.TypeIdx {
        return switch (sem) {
            .void => self.void_ty,
            .bool_type => self.bool_ty,
            .int => |i| if (i.signed)
                switch (i.bits) {
                    8 => self.i8_ty,
                    16 => self.i16_ty,
                    32 => self.i32_ty,
                    else => self.i64_ty,
                }
            else switch (i.bits) {
                8 => self.u8_ty,
                16 => self.u16_ty,
                32 => self.u32_ty,
                else => self.u64_ty,
            },
            .float => |f| switch (f) {
                .f32 => self.f32_ty,
                .f64 => self.f64_ty,
                .f16 => self.f64_ty,
            },
            // Pointers, strings, structs and enums all live in one slot.
            else => self.ptr_ty,
        };
    }

    /// Semantic type of a function parameter's type node. The checker caches
    /// the pointee's type on `&T`/`&mut T` unary nodes but not the reference
    /// itself, so reference types are rebuilt here.
    fn paramType(self: *Lowerer, ty_node: NodeIdx) !TypeIdx {
        const node = self.arena.get(ty_node);
        if (node.* == .unary_op) {
            switch (node.unary_op.op) {
                .ref, .mut_ref => {
                    const pointee = self.checker.nodeType(node.unary_op.operand);
                    return try self.type_pool.add(.{ .pointer = pointee });
                },
                else => {},
            }
        }
        return self.checker.nodeType(ty_node);
    }

    /// Semantic type of a captured binding. Capture lists hold the *binder*
    /// declaration nodes (a `param` or a `let_stmt`), and the checker records
    /// each binder's type on its own node (R7/R8).
    fn captureType(self: *Lowerer, decl_idx: NodeIdx) !TypeIdx {
        const node = self.arena.get(decl_idx);
        switch (node.*) {
            .param, .let_stmt => {},
            else => {
                self.codegenError(decl_idx, "captured binding is not a parameter or local", .{});
                return self.checker.void_ty;
            },
        }
        return self.checker.nodeType(decl_idx);
    }

    /// Name of a captured binding, from its binder declaration node.
    fn captureName(self: *Lowerer, decl_idx: NodeIdx) []const u8 {
        const node = self.arena.get(decl_idx);
        return switch (node.*) {
            .param => |p| self.nameSlice(p.name),
            .let_stmt => |l| self.nameSlice(l.name),
            else => "_",
        };
    }

    /// Current value of a captured binding at a closure literal's site: a
    /// local's slot is loaded (capture by value, R8c), a parameter is already
    /// an SSA value. A fn-value binding is itself a `{ fn_ptr, env_ptr }`
    /// record address; `buildEnvRecord` copies its two words inline (R16d).
    fn captureValue(self: *Lowerer, decl_idx: NodeIdx) !api.Value {
        const name = self.captureName(decl_idx);
        if (self.locals.get(name)) |binding| {
            return self.ctx.buildLoad(self.i64_ty, binding.value);
        }
        if (self.params.get(name)) |param| {
            return param.value;
        }
        self.codegenError(decl_idx, "captured binding '{s}' has no slot in this frame", .{name});
        return self.ctx.buildIntConst(self.i64_ty, 0);
    }

    /// IR type for one slot of a closure env record: fn values are their
    /// 16-byte record type, everything else the ordinary one-slot type.
    fn fieldIrType(self: *Lowerer, ty: TypeIdx) !api.TypeIdx {
        const sem = self.type_pool.get(ty);
        if (sem == .function) return self.fnValueTypeForFn(sem);
        return self.irTypeForSem(sem);
    }

    /// Byte size of one capture slot in an env record: one 8-byte slot per
    /// value, or the inline 16-byte `{ fn_ptr, env_ptr }` record for a fn
    /// value (docs/semantics.md §5.2 R8a, §6.4 R16d).
    fn envFieldSize(self: *Lowerer, ty: TypeIdx) u64 {
        return if (self.type_pool.get(ty) == .function) api.fn_value_size else 8;
    }

    /// IR `function_value` type for a semantic `function` type.
    fn fnValueTypeForFn(self: *Lowerer, sem: SemType) !api.TypeIdx {
        const f = sem.function;
        var params = std.ArrayList(api.TypeIdx).empty;
        defer params.deinit(self.gpa);
        for (f.param_types) |pt| {
            try params.append(self.gpa, self.irTypeFor(pt));
        }
        const sig = try self.ctx.funcType(self.irTypeFor(f.return_type), params.items);
        return self.ctx.fnValueType(sig);
    }

    /// IR `function_value` type for a declared function: its visible
    /// signature (params + return), without the hidden env parameter (R14).
    fn fnValueTypeForDecl(self: *Lowerer, decl_idx: NodeIdx) !api.TypeIdx {
        const f = self.arena.get(decl_idx).fn_decl;
        var params = std.ArrayList(api.TypeIdx).empty;
        defer params.deinit(self.gpa);
        for (f.params.indices) |param_idx| {
            try params.append(self.gpa, self.irTypeFor(try self.paramType(self.arena.get(param_idx).param.ty)));
        }
        const sig = try self.ctx.funcType(self.irTypeFor(self.checker.nodeType(decl_idx)), params.items);
        return self.ctx.fnValueType(sig);
    }

    /// Semantic type of a local/param binding by name, if any.
    /// Lower a comptime builtin call: `@assert` is a compile-time check with
    /// no runtime code, `@field` does a field access, `@hasField`/`@sizeOf`/
    /// `@alignOf`/`@typeOf` become their comptime values (R23a).
    fn lowerComptimeCall(self: *Lowerer, node_idx: NodeIdx, cc: anytype) !api.Value {
        const name = self.nameSlice(cc.name);
        const cv = self.checker.comptimeValue(node_idx);
        if (cv != .none) return try self.lowerComptimeValue(cv);
        if (std.mem.eql(u8, name, "assert")) return self.ctx.buildIntConst(self.i64_ty, 0);
        if (std.mem.eql(u8, name, "field")) {
            if (cc.args.indices.len == 2) {
                const field_lit = self.arena.get(cc.args.indices[1]);
                if (field_lit.* == .string_literal) {
                    const bare = field_lit.string_literal.slice(self.source);
                    const s = if (bare.len >= 2 and bare[0] == '"' and bare[bare.len - 1] == '"') bare[1 .. bare.len - 1] else bare;
                    const obj_ty = self.checker.nodeType(cc.args.indices[0]);
                    const sem = self.type_pool.get(obj_ty);
                    const decl_node: ?NodeIdx = switch (sem) {
                        .struct_type => |n| n,
                        .applied_struct => |a| a.decl,
                        .pointer => |elem| switch (self.type_pool.get(elem)) {
                            .struct_type => |n| n,
                            .applied_struct => |a| a.decl,
                            else => null,
                        },
                        else => null,
                    };
                    if (decl_node) |dn| {
                        if (structFieldOffset(self.arena, self.source, dn, s)) |off| {
                            const obj = try self.lowerExpr(cc.args.indices[0]);
                            const off_val = try self.ctx.buildIntConst(self.i64_ty, @intCast(off));
                            const addr = try self.ctx.buildPtrAdd(self.ptr_ty, obj, off_val);
                            return self.ctx.buildLoad(self.i64_ty, addr);
                        }
                    }
                }
            }
            return self.ctx.buildIntConst(self.i64_ty, 0);
        }
        return self.ctx.buildIntConst(self.i64_ty, 0);
    }

    /// Turn a comptime value into a runtime constant (R23a).
    fn lowerComptimeValue(self: *Lowerer, cv: anytype) !api.Value {
        return switch (cv) {
            .none => self.ctx.buildIntConst(self.i64_ty, 0),
            .bool => |v| self.ctx.buildIntConst(self.bool_ty, if (v) 1 else 0),
            .int => |v| self.ctx.buildIntConst(self.i64_ty, v),
            .float => |v| self.ctx.buildFloatConst(self.f64_ty, v),
            .string => |s| blk: {
                const bytes = try self.gpa.dupe(u8, s);
                defer self.gpa.free(bytes);
                const global = try self.strings.globalFor(bytes);
                const repr = try self.ctx.buildAllocaBytes(self.ptr_ty, string_mod.total_size);
                _ = try self.ctx.buildStore(self.i64_ty, repr, try self.ctx.buildIntConst(self.i64_ty, @intCast(bytes.len)));
                const data = try self.ctx.buildGlobalAddr(self.ptr_ty, global);
                const data_addr = try self.ctx.buildPtrAdd(self.ptr_ty, repr, try self.ctx.buildIntConst(self.i64_ty, @intCast(string_mod.data_offset)));
                _ = try self.ctx.buildStore(self.i64_ty, data_addr, data);
                break :blk repr;
            },
            .type_value => self.ctx.buildIntConst(self.i64_ty, 0),
        };
    }

    fn bindingType(self: *Lowerer, name: []const u8) ?TypeIdx {
        if (self.params.get(name)) |p| return p.ty;
        if (self.locals.get(name)) |l| return l.ty;
        return null;
    }

    /// Type of an expression node, falling back to the binding map for
    /// identifiers the checker did not directly cache a type for.
    fn exprType(self: *Lowerer, node_idx: NodeIdx) TypeIdx {
        const node = self.arena.get(node_idx);
        if (node.* == .identifier) {
            if (self.bindingType(self.nameSlice(node.identifier))) |ty| return ty;
        }
        return self.checker.nodeType(node_idx);
    }

    // ========================================================================
    // Misc
    // ========================================================================

    fn setBlock(self: *Lowerer, block: api.BasicBlockIdx) void {
        self.ctx.setCurrentBlock(block);
        self.block_terminated = false;
    }

    fn terminated(self: *Lowerer) void {
        self.block_terminated = true;
    }

    fn nameSlice(self: *Lowerer, ref: StringRef) []const u8 {
        return ref.slice(self.source);
    }

    fn codegenError(self: *Lowerer, _: NodeIdx, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.gpa, fmt, args) catch |err| {
            std.debug.panic("OOM in codegen: {s}", .{@errorName(err)});
        };
        self.diagnostics.add(.@"error", .codegen, msg, null) catch {};
    }
};

/// Lower a fully checked module into `ctx`.
pub fn lowerAll(
    gpa: Allocator,
    arena: *AstArena,
    source: []const u8,
    type_pool: *TypePool,
    diagnostics: *diag.Diagnostics,
    checker: *typecheck_mod.TypeChecker,
    ctx: *api.Context,
) !void {
    var lowerer = try Lowerer.init(gpa, arena, source, type_pool, diagnostics, checker, ctx);
    defer lowerer.deinit();
    try lowerer.run();
}

// ============================================================================
// Aggregate layout
// ============================================================================
//
// Structs are plain aggregates: fields packed in declaration order with no
// header preamble, each occupying one 8-byte slot to match the backend's
// slot-based codegen. A struct lives on the stack in one `allocaBytes`
// region.
//
// An enum value is a pointer to a stack block laid out as:
//
// ```text
// [ tag: i64 ][ payload 0 ][ payload 1 ] ...
// ```
//
// The tag is the variant's index in declaration order. Payload slots are
// 8 bytes each; the block is sized by the constructing variant's own
// payload count.

/// Number of fields in a struct declaration.
fn fieldCount(arena: *const AstArena, decl_idx: NodeIdx) u64 {
    const decl = arena.get(decl_idx);
    return switch (decl.*) {
        .struct_decl => |s| @intCast(s.fields.indices.len),
        else => 0,
    };
}

/// Total byte size of a stack-allocated struct.
fn structSize(arena: *const AstArena, decl_idx: NodeIdx) u32 {
    return @intCast(8 * fieldCount(arena, decl_idx));
}

/// Byte offset of a named field inside a struct.
fn structFieldOffset(arena: *const AstArena, source: []const u8, decl_idx: NodeIdx, field_name: []const u8) ?u64 {
    const decl = arena.get(decl_idx);
    const fields: []const NodeIdx = switch (decl.*) {
        .struct_decl => |s| s.fields.indices,
        else => return null,
    };
    for (fields, 0..) |field_idx, i| {
        const field = arena.get(field_idx);
        const name = switch (field.*) {
            .field => |f| f.name,
            else => continue,
        };
        if (std.mem.eql(u8, name.slice(source), field_name)) {
            return 8 * @as(u64, @intCast(i));
        }
    }
    return null;
}

/// Byte offset of enum payload slot `index`, after the 8-byte tag.
fn enumPayloadOffset(index: u64) u64 {
    return 8 * (index + 1);
}

/// Total byte size of an enum block holding `payload_count` payload slots.
fn enumSizeFor(payload_count: u64) u32 {
    return @intCast(8 * (payload_count + 1));
}

// ============================================================================
// Tests
// ============================================================================

const TestResult = struct {
    arena: AstArena,
    type_pool: TypePool,
    diagnostics: diag.Diagnostics,
    ctx: *api.Context,

    fn deinit(self: *TestResult) void {
        self.ctx.deinit();
        self.arena.deinit();
        self.type_pool.deinit();
        self.diagnostics.deinit();
    }

    fn text(self: *TestResult, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        self.ctx.print(&w) catch unreachable;
        return buf[0..w.end];
    }
};

fn runLower(allocator: Allocator, source: []const u8) !TestResult {
    var arena = AstArena.init(allocator);
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    var parser = @import("../parser/parser.zig").Parser.init(allocator, tokens, source, &arena, &diags);
    const module_node = parser.parseModule();
    var type_pool = TypePool.init(allocator);
    var checker: typecheck_mod.TypeChecker = undefined;
    {
        var resolver = @import("../semantic/resolve.zig").Resolver.init(allocator, &arena, source, &type_pool, &diags, module_node);
        defer resolver.deinit();
        try resolver.resolve();
        checker = typecheck_mod.TypeChecker.init(allocator, &arena, source, &type_pool, &diags, &resolver.scopes, module_node);
        try checker.check();
    }
    const ctx = try api.Context.init(allocator);
    errdefer ctx.deinit();
    try lowerAll(allocator, &arena, source, &type_pool, &diags, &checker, ctx);
    checker.deinit();
    return .{ .arena = arena, .type_pool = type_pool, .diagnostics = diags, .ctx = ctx };
}

fn checkLower(allocator: Allocator, source: []const u8) !TestResult {
    var res = try runLower(allocator, source);
    errdefer {
        res.ctx.deinit();
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
    return res;
}

test "lower: int return" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return 42
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @main() {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "iconst 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret %0") != null);
}

test "lower: arithmetic and calls" {
    var res = try checkLower(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn main() -> i32 {
        \\    return add(3, 4)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // R14: `add` takes a hidden env parameter first, so its visible params
    // occupy slots 1 and 2.
    try std.testing.expect(std.mem.indexOf(u8, text, "add %1, %2") != null);
    // The call site primes the hidden env argument with a null env.
    try std.testing.expect(std.mem.indexOf(u8, text, "call @fn0(%") != null);
}

test "lower: print lowers to an extern call into the runtime" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    print("Hello, world!")
        \\    return 42
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The prelude name is gone: what reaches the IR is the runtime symbol.
    try std.testing.expect(std.mem.indexOf(u8, text, "wfr_std_print") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extern_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "iconst 42") != null);
}

test "lower: a generic fn is monomorphized per type argument" {
    var res = try checkLower(std.testing.allocator,
        \\fn first[T](a: T, b: T) -> T {
        \\    return a
        \\}
        \\fn main() -> i32 {
        \\    let x = first(1, 2)
        \\    return x
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The template has no function of its own; the instance carries the
    // mangled symbol `first__i32` (R22).
    try std.testing.expect(std.mem.indexOf(u8, text, "first__i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @first__i32(") != null);
}

test "lower: expression-body fn shorthand returns its value" {
    var res = try checkLower(std.testing.allocator,
        \\fn dbl(x: i32) -> i32 = x * 2
        \\fn main() -> i32 {
        \\    return dbl(21)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "mul %1, %2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret %3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call @fn0(%") != null);
}

test "lower: if statement with else and assignment" {
    var res = try checkLower(std.testing.allocator,
        \\fn sign(x: i32) -> i32 {
        \\    mut r: i32 = 0
        \\    if x > 0 {
        \\        r = 1
        \\    } else {
        \\        r = -1
        \\    }
        \\    return r
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "cond_br") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bb3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store") != null);
}

test "lower: while loop" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    mut s: i32 = 0
        \\    mut i: i32 = 0
        \\    while i < 10 {
        \\        s = s + i
        \\        i = i + 1
        \\    }
        \\    return s
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp slt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bb1:") != null);
}

test "lower: for range loop" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    mut s: i32 = 0
        \\    for i in 0..10 {
        \\        s = s + i
        \\    }
        \\    return s
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp slt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load") != null);
}

test "lower: short-circuit and with phi" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> bool {
        \\    let b = 1 < 2 && 3 < 4
        \\    return b
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "phi") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cond_br") != null);
}

test "lower: struct init and field access" {
    var res = try checkLower(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
        \\fn main() -> f64 {
        \\    let v: Vec2 = Vec2{ .x = 1.0, .y = 2.0 }
        \\    return v.x
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fconst 1") != null);
}

test "lower: aggregate layout has no header preamble" {
    // Structs are plain aggregates (8-byte slots, no header preamble) and
    // enums are tag + payload slots at fixed offsets.
    try std.testing.expectEqual(@as(u64, 8), enumPayloadOffset(0));
    try std.testing.expectEqual(@as(u64, 16), enumPayloadOffset(1));
    try std.testing.expectEqual(@as(u32, 16), enumSizeFor(1));
    try std.testing.expectEqual(@as(u32, 24), enumSizeFor(2));
}

test "lower: free function over a struct is a named call over gep fields" {
    var res = try checkLower(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
        \\fn sum(v: Vec2) -> f64 {
        \\    return v.x + v.y
        \\}
        \\fn main() -> f64 {
        \\    let v: Vec2 = Vec2{ .x = 1.0, .y = 2.0 }
        \\    return sum(v)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The declaration keeps its name and the call is a direct call — there is
    // no receiver argument and no dispatch through a table.
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @sum()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call @fn") != null);
    // Field reads are static byte-offset geps on the aggregate parameter.
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fadd") != null);
}

test "lower: a free function mutates a struct through a `&mut` parameter" {
    var res = try checkLower(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
        \\fn scale(v: &mut Vec2, factor: f64) {
        \\    v.x = v.x * factor
        \\    v.y = v.y * factor
        \\}
        \\fn main() -> f64 {
        \\    mut v: Vec2 = Vec2{ .x = 3.0, .y = 4.0 }
        \\    scale(&mut v, 2.0)
        \\    return v.x
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The `&mut T` parameter arrives as the aggregate's block pointer, so the
    // mutation is a store through a static field offset of that pointer.
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fmul") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store") != null);
    // `scale(&mut v, 2.0)` is a plain direct call with the block and the factor.
    try std.testing.expect(std.mem.indexOf(u8, text, "call @fn") != null);
}

test "lower: dot-call on a struct value is not method dispatch" {
    var res = try runLower(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
        \\fn add(a: Vec2, b: Vec2) -> Vec2 {
        \\    return Vec2{ .x = a.x + b.x, .y = a.y + b.y }
        \\}
        \\fn main() -> f64 {
        \\    let u: Vec2 = Vec2{ .x = 1.0, .y = 2.0 }
        \\    let w = u.add(u)
        \\    return w.x
        \\}
    );
    defer res.deinit();
    try std.testing.expect(res.diagnostics.hasErrors());
}

test "lower: string literal pool" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let s: String = "hi"
        \\    return 0
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "global @str_0 = string \"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
}

test "lower: defers run before return" {
    var res = try checkLower(std.testing.allocator,
        \\fn g() {
        \\}
        \\fn f() -> i32 {
        \\    defer g()
        \\    return 1
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    const call_pos = std.mem.indexOf(u8, text, "call @fn0(").?;
    const ret_pos = std.mem.indexOf(u8, text, "ret %").?;
    try std.testing.expect(call_pos < ret_pos);
}

test "lower: float arithmetic and compare" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> bool {
        \\    return 1.5 + 2.5 >= 3.0
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "fadd") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fcmp oge") != null);
}

test "lower: emit assembly for a module" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return 42
        \\}
    );
    defer res.deinit();

    const asm_text = try res.ctx.emitAssembly();
    defer res.ctx.gpa.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "section .text") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "_main:") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "mov     rax, 42") != null);
}

test "lower: if expression produces a phi at the merge" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return if true { 1 } else { 2 }
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "phi") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret %") != null);
}

test "lower: match on enum with payload binding" {
    var res = try checkLower(std.testing.allocator,
        \\enum Option[i32] {
        \\    None
        \\    Some(i32)
        \\}
        \\fn main() -> i32 {
        \\    mut x: Option[i32] = Some(7)
        \\    match x {
        \\        None => 0
        \\        Some(n) => n * 2
        \\    }
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp eq") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mul") != null);
}

test "lower: match expression as a value" {
    var res = try checkLower(std.testing.allocator,
        \\enum Color {
        \\    Red
        \\    Green
        \\    Blue
        \\}
        \\fn main() -> i32 {
        \\    mut c: Color = Blue
        \\    return match c {
        \\        Red => 1
        \\        Green => 2
        \\        Blue => 3
        \\    }
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "phi") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp eq") != null);
}

test "lower: for...in iterates string bytes" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    mut s: i32 = 0
        \\    for c in "ab" {
        \\        s = s + c
        \\    }
        \\    return s
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp ult") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
}

test "lower: string index access loads a byte" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return "ab"[1]
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load") != null);
}

test "lower: interface method call no longer parses" {
    var res = try runLower(std.testing.allocator,
        \\interface Shape {
        \\    fn area(self: &Shape) -> i32
        \\    fn name(self: &Shape) -> i32
        \\}
        \\struct Square {
        \\    side: i32
        \\    fn area(self: &Square) -> i32 {
        \\        return self.side * self.side
        \\    }
        \\    fn name(self: &Square) -> i32 {
        \\        return 1
        \\    }
        \\}
        \\fn describe(s: &impl Shape) -> i32 {
        \\    return s.area()
        \\}
        \\fn main() -> i32 {
        \\    mut sq: Square = Square{ .side = 4 }
        \\    return describe(sq)
        \\}
    );
    defer res.deinit();
    try std.testing.expect(res.diagnostics.hasErrors());
}

test "lower: a named fn used as a value becomes a fn value" {
    var res = try checkLower(std.testing.allocator,
        \\fn inc(x: i32) -> i32 {
        \\    return x + 1
        \\}
        \\fn main() -> i32 {
        \\    let f = inc
        \\    return f(1)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // A named fn lowered as a value pairs its address with a null env (R14).
    try std.testing.expect(std.mem.indexOf(u8, text, "func_addr @fn0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "iconst 0") != null);
    // Calling through the local is indirect: no direct `call @fn0` remains.
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr") != null);
}

test "lower: closure literal lifts to a function and is called indirectly" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let inc = |x| x + 1
        \\    return inc(5)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The literal lifts to a module-level `closure_0` with an env-first ABI
    // (R14): its visible param is slot 1.
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @closure_0()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "add %1,") != null);
    // The fn value pairs the address with a null env; the call goes indirect.
    try std.testing.expect(std.mem.indexOf(u8, text, "func_addr @fn1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr %") != null);
    // No capture set: the env slot is still primed with a null env (there is
    // no second `alloca` for an env record).
    try std.testing.expect(std.mem.indexOf(u8, text, "iconst 0") != null);
}

test "lower: a lifted closure body has exactly one return terminator" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let inc = |x| x + 1
        \\    return inc(5)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // Isolate the lifted function and count its return terminators: an
    // expression-body closure must not emit its own `ret` and then fall
    // through to the default `ret` in the same block.
    const start = std.mem.indexOf(u8, text, "fn @closure_0()").?;
    const rest = text[start..];
    const end = std.mem.indexOf(u8, rest, "\n}\n").?;
    const body = rest[0..end];
    var rets: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, body, idx, "ret ")) |pos| {
        rets += 1;
        idx = pos + 4;
    }
    try std.testing.expectEqual(@as(usize, 1), rets);
}

test "lower: closure capturing a local copies it into an env record" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let n = 10
        \\    let add = |x| x + n
        \\    return add(5)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // One 8-byte capture => an 8-byte env record whose bytes are copied from
    // the captured local, then stored into the fn value's env slot (R16).
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @closure_0()") != null);
    // The lifted body reads its capture back out of the env (slot 0) and
    // binds it to a fresh slot.
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr %") != null);
}

test "lower: closure capturing a parameter works in a non-main function" {
    var res = try checkLower(std.testing.allocator,
        \\fn outer(n: i32) -> i32 {
        \\    let inner = |x| x * n
        \\    return inner(3)
        \\}
        \\fn main() -> i32 {
        \\    return outer(4)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @outer()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @closure_0()") != null);
    // The capture is copied out of a stack slot (`n` at slot 1) into the env.
    try std.testing.expect(std.mem.indexOf(u8, text, "store %3, %1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mul %1,") != null);
    // `main` calls `outer` directly with a null env followed by the argument.
    try std.testing.expect(std.mem.indexOf(u8, text, "call @fn0(%1, %0)") != null);
}

test "lower: a closure nested inside a closure lifts to its own function" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let mk = || |x| x + 1
        \\    let f = mk()
        \\    return f(5)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // Both literals become module-level functions; the outer returns the inner
    // as a 16-byte fn value (R16d).
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @closure_0()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @closure_1()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "func_addr @fn2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr %") != null);
}

test "lower: pipeline feeds a value into a closure" {
    var res = try checkLower(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f = |x| x + 1
        \\    return 2 |> f
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The piped value is prepended as argument 0 to the indirect call.
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @closure_0()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr %9(%10)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "iconst 2") != null);
}

test "lower: `?` inside a closure body branches out of the lifted function" {
    var res = try checkLower(std.testing.allocator,
        \\enum Res {
        \\    Ok(i32)
        \\    Err(i32)
        \\}
        \\fn get() -> Res {
        \\    return Ok(1)
        \\}
        \\fn main() -> Res {
        \\    let unwrap = |r: Res| {
        \\        let v = r?
        \\        return Ok(v)
        \\    }
        \\    return unwrap(get())
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The closure lifts; its `?` lowers to a compare + conditional branch +
    // `ret` on the taken path, all inside `closure_0`.
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @closure_0()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp eq") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cond_br") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr %") != null);
}

test "lower: `?` branches to an early return on the error variant" {
    var res = try checkLower(std.testing.allocator,
        \\enum Maybe {
        \\    None
        \\    Some(i32)
        \\}
        \\fn get() -> Maybe {
        \\    return Some(1)
        \\}
        \\fn main() -> Maybe {
        \\    let v = get()?
        \\    return Some(v)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The propagate path is a compare of the tag against the error variant
    // index, a conditional branch, and a `ret` on the taken path (R28/R28a).
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp eq") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cond_br") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret %") != null);
}

test "lower: `?` rebuilds the error variant from its payload" {
    var res = try checkLower(std.testing.allocator,
        \\enum Res {
        \\    Ok(i32)
        \\    Err(i32)
        \\}
        \\fn get() -> Res {
        \\    return Err(5)
        \\}
        \\fn main() -> Res {
        \\    let v = get()?
        \\    return Ok(v)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The error variant carries one field, so the propagate path copies it:
    // one payload slot plus the tag is a 16-byte block.
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp eq") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr_add") != null);
}

test "lower: a tail `?` closure re-wraps the payload into the return enum" {
    var res = try checkLower(std.testing.allocator,
        \\enum Res {
        \\    Ok(i32)
        \\    Err(i32)
        \\}
        \\fn main() -> i32 {
        \\    let f: fn(Res) -> Res = |r| r?
        \\    return 1
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // Isolate the lifted function. Its error path rebuilds the enum and
    // returns it; its success path re-wraps the payload — two 16-byte
    // enum blocks and exactly two `ret` terminators, one per path, with no
    // fallthrough to the default return.
    const start = std.mem.indexOf(u8, text, "fn @closure_0()").?;
    const rest = text[start..];
    const end = std.mem.indexOf(u8, rest, "\n}\n").?;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "icmp eq") != null);
    var allocas: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, body, idx, "alloca 16")) |pos| {
        allocas += 1;
        idx = pos + 9;
    }
    try std.testing.expectEqual(@as(usize, 2), allocas);
    var rets: usize = 0;
    idx = 0;
    while (std.mem.indexOfPos(u8, body, idx, "ret ")) |pos| {
        rets += 1;
        idx = pos + 4;
    }
    try std.testing.expectEqual(@as(usize, 2), rets);
}

test "lower: prelude curry(add)(1)(2) expands to direct calls with no call_ptr" {
    var res = try checkLower(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn main() -> i32 {
        \\    return curry(add)(1)(2)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call @") != null);
}

test "lower: prelude compose(f,g)(x) expands to two direct calls" {
    var res = try checkLower(std.testing.allocator,
        \\fn inc(x: i32) -> i32 { return x + 1 }
        \\fn double(x: i32) -> i32 { return x * 2 }
        \\fn main() -> i32 {
        \\    let f: fn(i32) -> i32 = compose(double, inc)
        \\    return f(3)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // compose expands to direct calls in the expanded form
    var call_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, text, idx, "call @")) |pos| {
        call_count += 1;
        idx = pos + 6;
    }
    try std.testing.expect(call_count >= 2);
}

test "lower: prelude id and pipe expand directly" {
    var res = try checkLower(std.testing.allocator,
        \\fn inc(x: i32) -> i32 { return x + 1 }
        \\fn main() -> i32 {
        \\    let a = id(5)
        \\    let b = pipe(3, inc)
        \\    return a + b
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr") == null);
}

test "lower: uncurry(h)(a,b) expands to direct calls" {
    var res = try checkLower(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn main() -> i32 {
        \\    let h = curry(add)
        \\    return uncurry(h)(1, 2)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "call @") != null);
}

test "lower: uncurry(curry(f))(a,b) fuses to a direct call" {
    var res = try checkLower(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn main() -> i32 {
        \\    return uncurry(curry(add))(1, 2)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "call_ptr") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call @") != null);
}

test "lower: a stored uncurry(curry(f)) holds f without an intermediate closure" {
    var res = try checkLower(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn main() -> i32 {
        \\    let u = uncurry(curry(add))
        \\    return u(1, 2)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // The fused pair holds `add`'s own fn value, so no closure of the pair
    // (whose env would die with its frame) is lifted.
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @curry_outer_") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @curry_inner_") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @uncurry_") == null);
}

test "lower: uncurrying a stored curry keeps the searchable operand" {
    var res = try checkLower(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn main() -> i32 {
        \\    let h = curry(add)
        \\    let u = uncurry(h)
        \\    return u(1, 2)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // `u` holds `add`'s own fn value, not `curry(add)`'s, so the pair does
    // not lift an `uncurry` function.
    try std.testing.expect(std.mem.indexOf(u8, text, "fn @uncurry_") == null);
}

test "lower: materialized curry(f) produces a fn value with env record" {
    var res = try checkLower(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn main() -> i32 {
        \\    let f = curry(add)
        \\    let g = f(1)
        \\    return g(2)
        \\}
    );
    defer res.deinit();

    var buf: [8192]u8 = undefined;
    const text = res.text(&buf);
    // Materialized forms use fn values/indirect calls
    try std.testing.expect(std.mem.indexOf(u8, text, "func_addr") != null or std.mem.indexOf(u8, text, "call_ptr") != null);
}
