const std = @import("std");
const ast = @import("../parser/ast.zig");
const diag = @import("../diagnostics.zig");
const prelude = @import("../prelude.zig");
const types_mod = @import("types.zig");
const scope_mod = @import("scope.zig");
const generics_mod = @import("generics.zig");

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
const FloatKind = types_mod.FloatKind;
const GenericInfo = generics_mod.GenericInfo;
const GenericInstance = generics_mod.GenericInstance;
const ComptimeValue = generics_mod.ComptimeValue;

/// What an inferred type placeholder stands for, for diagnostics.
const PendingKind = enum { param, closure_ret };

/// An unresolved type (R11b, "unification only"). A closure parameter or a
/// closure's inferred return type registers a per-binder `placeholder`
/// `TypeIdx`; `resolved` fills in the first time a concrete type is unified
/// against it.
const PendingType = struct {
    placeholder: TypeIdx,
    name: StringRef,
    kind: PendingKind,
    resolved: ?TypeIdx = null,
};

/// The resolved types of an operand pair after inference has been propagated
/// between them (a pending placeholder adopts its concrete sibling).
const UnifiedPair = struct {
    left: TypeIdx,
    right: TypeIdx,
};

/// A comptime value and the type it denotes (docs/semantics.md §7.5, R23a).
///
/// The value is what the comptime expression evaluated to; the type is what
/// the expression is typed as, so the lowerer knows what to emit for it.
const ComptimeBinding = struct {
    value: ComptimeValue,
    ty: TypeIdx,
};

/// Walking state for closure capture-set inference (R7): the captures found so
/// far (in source order of first appearance), the set of binders already
/// captured (dedup), and the names bound inside the closure, one set per lexical
/// level so an inner shadowing `let` never reads as a capture of an outer name.
const CaptureSet = struct {
    captured: std.ArrayListUnmanaged(NodeIdx) = .empty,
    seen: std.AutoHashMapUnmanaged(NodeIdx, void) = .empty,
    levels: std.ArrayListUnmanaged(std.StringHashMapUnmanaged(void)) = .empty,

    fn deinit(self: *CaptureSet, allocator: Allocator) void {
        self.captured.deinit(allocator);
        self.seen.deinit(allocator);
        for (self.levels.items) |*level| level.deinit(allocator);
        self.levels.deinit(allocator);
    }

    fn pushLevel(self: *CaptureSet, allocator: Allocator) void {
        self.levels.append(allocator, .empty) catch @panic("OOM");
    }

    fn popLevel(self: *CaptureSet, allocator: Allocator) void {
        const last = self.levels.items.len - 1;
        self.levels.items[last].deinit(allocator);
        self.levels.items.len = last;
    }

    fn bind(self: *CaptureSet, allocator: Allocator, name: []const u8) void {
        self.levels.items[self.levels.items.len - 1].put(allocator, name, {}) catch @panic("OOM");
    }

    fn isBound(self: *CaptureSet, name: []const u8) bool {
        var i = self.levels.items.len;
        while (i > 0) {
            i -= 1;
            if (self.levels.items[i].contains(name)) return true;
        }
        return false;
    }
};

pub const TypeChecker = struct {
    allocator: Allocator,
    arena: *AstArena,
    source: []const u8,
    type_pool: *TypePool,
    diagnostics: *diag.Diagnostics,
    module_node: NodeIdx,

    node_types: std.ArrayListUnmanaged(TypeIdx),
    scopes: scope_mod.ScopeStack,

    fn_ret_type: TypeIdx,
    in_function: bool,
    /// Whether the expression being typed sits inside a `comptime` context,
    /// where `?` has no success/error split to branch on (R29c).
    in_comptime: bool,

    type_name_buf: [2][16]u8,
    type_name_toggle: u1 = 0,
    /// Scratch buffer for rendering a comptime expression into a diagnostic.
    constraint_buf: [256]u8 = undefined,

    /// Inference state for closures typed without annotations (R11b). Keyed by
    /// the binder: a closure parameter node, or the closure node itself for its
    /// inferred return type.
    pending: std.AutoHashMapUnmanaged(NodeIdx, PendingType),
    /// Reverse index: a placeholder `TypeIdx` -> the binder node behind it.
    pending_by_type: std.AutoHashMapUnmanaged(TypeIdx, NodeIdx),

    /// Cache for instantiated generic functions: (decl, args hash/signature) -> applied_fn sig/type
    instantiations: std.AutoHashMapUnmanaged(u64, TypeIdx),

    /// The generic table (R21): one template per generic declaration.
    generic_info: std.AutoHashMapUnmanaged(NodeIdx, GenericInfo),
    /// The instantiation cache (R20b/R21b): instance key -> instance. The
    /// key is the declaration plus the structural hash of the type arguments,
    /// so the same `(decl, args)` always maps to one instance.
    fn_instances: std.AutoHashMapUnmanaged(u64, *GenericInstance),
    /// The instances in creation order, so codegen can emit one function per
    /// instance.
    instance_list: std.ArrayListUnmanaged(*GenericInstance),
    /// The instance a call site resolves to, keyed by the callee node. The
    /// callee node is the identifier (or the type application) the call
    /// names, so a pipeline and a direct call of the same generic share it.
    instance_by_callee: std.AutoHashMapUnmanaged(NodeIdx, *GenericInstance),

    /// The comptime value of every evaluated comptime expression, keyed by
    /// node (R23a). The checker computes the value; the lowerer only has to
    /// turn it into a constant.
    comptime_values: std.AutoHashMapUnmanaged(NodeIdx, ComptimeBinding),
    /// The branch a `comptime if` takes, keyed by the `if` node: true when
    /// the then-branch is taken (R23c).
    comptime_branches: std.AutoHashMapUnmanaged(NodeIdx, bool),
    /// Set when a comptime constraint fails. The instance being checked stops
    /// type-checking at that point (R23b).
    constraint_failed: bool = false,

    void_ty: TypeIdx,
    bool_ty: TypeIdx,
    i8_ty: TypeIdx,
    i16_ty: TypeIdx,
    i32_ty: TypeIdx,
    i64_ty: TypeIdx,
    u8_ty: TypeIdx,
    u16_ty: TypeIdx,
    u32_ty: TypeIdx,
    u64_ty: TypeIdx,
    f32_ty: TypeIdx,
    f64_ty: TypeIdx,
    string_ty: TypeIdx,
    /// The type of a type value (`@typeOf(x)`).
    type_value_ty: TypeIdx,

    pub fn init(
        allocator: Allocator,
        arena: *AstArena,
        source: []const u8,
        type_pool: *TypePool,
        diagnostics: *diag.Diagnostics,
        resolver_scopes: *const scope_mod.ScopeStack,
        module_node: NodeIdx,
    ) TypeChecker {
        const void_ty = type_pool.add(.void) catch @panic("OOM");
        const bool_ty = type_pool.add(.bool_type) catch @panic("OOM");
        const i8_ty = type_pool.add(.{ .int = .{ .signed = true, .bits = 8 } }) catch @panic("OOM");
        const i16_ty = type_pool.add(.{ .int = .{ .signed = true, .bits = 16 } }) catch @panic("OOM");
        const i32_ty = type_pool.add(.{ .int = .{ .signed = true, .bits = 32 } }) catch @panic("OOM");
        const i64_ty = type_pool.add(.{ .int = .{ .signed = true, .bits = 64 } }) catch @panic("OOM");
        const u8_ty = type_pool.add(.{ .int = .{ .signed = false, .bits = 8 } }) catch @panic("OOM");
        const u16_ty = type_pool.add(.{ .int = .{ .signed = false, .bits = 16 } }) catch @panic("OOM");
        const u32_ty = type_pool.add(.{ .int = .{ .signed = false, .bits = 32 } }) catch @panic("OOM");
        const u64_ty = type_pool.add(.{ .int = .{ .signed = false, .bits = 64 } }) catch @panic("OOM");
        const f32_ty = type_pool.add(.{ .float = .f32 }) catch @panic("OOM");
        const f64_ty = type_pool.add(.{ .float = .f64 }) catch @panic("OOM");
        const string_ty = type_pool.add(.string_type) catch @panic("OOM");
        const type_value_ty = type_pool.add(.type_value) catch @panic("OOM");

        var node_types: std.ArrayListUnmanaged(TypeIdx) = .empty;
        node_types.append(allocator, void_ty) catch @panic("OOM");

        var scopes = scope_mod.ScopeStack.init(allocator);
        const module_scope = scopes.pushScope(null) catch @panic("OOM");
        if (resolver_scopes.scopeCount() > 0) {
            var it = resolver_scopes.scopes.items[0].symbols.iterator();
            while (it.next()) |entry| {
                scopes.insert(entry.key_ptr.*, entry.value_ptr.*) catch @panic("OOM");
            }
        }
        _ = module_scope;

        return .{
            .allocator = allocator,
            .arena = arena,
            .source = source,
            .type_pool = type_pool,
            .diagnostics = diagnostics,
            .scopes = scopes,
            .module_node = module_node,
            .node_types = node_types,
            .fn_ret_type = void_ty,
            .in_function = false,
            .in_comptime = false,
            .type_name_buf = undefined,
            .type_name_toggle = 0,
            .pending = .empty,
            .pending_by_type = .empty,
            .instantiations = .empty,
            .generic_info = .empty,
            .fn_instances = .empty,
            .instance_list = .empty,
            .instance_by_callee = .empty,
            .comptime_values = .empty,
            .comptime_branches = .empty,
            .void_ty = void_ty,
            .bool_ty = bool_ty,
            .i8_ty = i8_ty,
            .i16_ty = i16_ty,
            .i32_ty = i32_ty,
            .i64_ty = i64_ty,
            .u8_ty = u8_ty,
            .u16_ty = u16_ty,
            .u32_ty = u32_ty,
            .u64_ty = u64_ty,
            .f32_ty = f32_ty,
            .f64_ty = f64_ty,
            .string_ty = string_ty,
            .type_value_ty = type_value_ty,
        };
    }

    fn builtinTypeName(self: *const TypeChecker, name: []const u8) ?TypeIdx {
        if (std.mem.eql(u8, name, "void")) return self.void_ty;
        if (std.mem.eql(u8, name, "bool")) return self.bool_ty;
        if (std.mem.eql(u8, name, "i8")) return self.i8_ty;
        if (std.mem.eql(u8, name, "i16")) return self.i16_ty;
        if (std.mem.eql(u8, name, "i32")) return self.i32_ty;
        if (std.mem.eql(u8, name, "i64")) return self.i64_ty;
        if (std.mem.eql(u8, name, "u8")) return self.u8_ty;
        if (std.mem.eql(u8, name, "u16")) return self.u16_ty;
        if (std.mem.eql(u8, name, "u32")) return self.u32_ty;
        if (std.mem.eql(u8, name, "u64")) return self.u64_ty;
        if (std.mem.eql(u8, name, "f32")) return self.f32_ty;
        if (std.mem.eql(u8, name, "f64")) return self.f64_ty;
        if (std.mem.eql(u8, name, "String")) return self.string_ty;
        return null;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.node_types.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pending_by_type.deinit(self.allocator);
        self.instantiations.deinit(self.allocator);
        for (self.instance_list.items) |inst| {
            self.allocator.free(inst.args);
            self.allocator.free(inst.mangled);
            self.allocator.destroy(inst);
        }
        self.instance_list.deinit(self.allocator);
        self.fn_instances.deinit(self.allocator);
        self.instance_by_callee.deinit(self.allocator);
        self.comptime_values.deinit(self.allocator);
        self.comptime_branches.deinit(self.allocator);
        var info_it = self.generic_info.iterator();
        while (info_it.next()) |entry| {
            const info = entry.value_ptr.*;
            self.allocator.free(info.param_names);
            self.allocator.free(info.param_nodes);
            self.allocator.free(info.template_params);
        }
        self.generic_info.deinit(self.allocator);
        self.scopes.deinit();
    }

    pub fn check(self: *TypeChecker) !void {
        const mod = self.arena.get(self.module_node);
        for (mod.module.decls.indices) |decl_idx| {
            try self.checkDecl(decl_idx);
        }
    }

    fn nameSlice(self: *const TypeChecker, ref: StringRef) []const u8 {
        return ref.slice(self.source);
    }

    fn errorAt(self: *TypeChecker, _: NodeIdx, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch |err| {
            std.debug.panic("OOM in typechecker: {s}", .{@errorName(err)});
        };
        self.diagnostics.add(.@"error", .semantic, msg, null) catch {};
    }

    fn setNodeType(self: *TypeChecker, node: NodeIdx, ty: TypeIdx) void {
        const idx = node.toInt();
        while (self.node_types.items.len <= idx) {
            self.node_types.append(self.allocator, self.void_ty) catch @panic("OOM");
        }
        self.node_types.items[idx] = ty;
    }

    fn getNodeType(self: *const TypeChecker, node: NodeIdx) TypeIdx {
        const idx = node.toInt();
        if (idx < self.node_types.items.len) {
            return self.node_types.items[idx];
        }
        return self.void_ty;
    }
    pub fn nodeType(self: *const TypeChecker, node: NodeIdx) TypeIdx {
        return self.getNodeType(node);
    }

    /// The type of a `void`-returning expression, for callers that need to
    /// compare against a call result.
    pub fn voidTypeIndex(self: *const TypeChecker) TypeIdx {
        return self.void_ty;
    }

    fn checkDecl(self: *TypeChecker, decl_idx: NodeIdx) anyerror!void {
        const decl = self.arena.get(decl_idx);
        switch (decl.*) {
            .fn_decl => {
                const f = decl.fn_decl;
                if (f.generic_params.indices.len > 0) {
                    // A generic fn is a template: its parameters stand for
                    // `generic_param` placeholders, so the body cannot be
                    // type-checked as written. It is checked once per
                    // instance, on a clone with the type arguments bound
                    // (R21 step 2). Here only the template is resolved.
                    _ = self.genericInfoFor(decl_idx);
                    return;
                }
                try self.checkFnDecl(decl_idx);
            },
            .enum_decl => try self.checkEnumDecl(decl_idx),
            else => {},
        }
    }

    fn checkEnumDecl(self: *TypeChecker, decl_idx: NodeIdx) !void {
        const decl = self.arena.get(decl_idx);
        const e = decl.enum_decl;
        // Type the variant payload types so match arms can bind them.
        // Generic enums (Option[T]) leave payloads unresolved.
        if (e.generic_params.indices.len == 0) {
            for (e.variants.indices) |variant_idx| {
                const variant = self.arena.get(variant_idx);
                for (variant.enum_variant.fields.indices) |field_idx| {
                    _ = self.inferExprType(field_idx);
                }
            }
        }
    }

    fn checkFnDecl(self: *TypeChecker, fn_idx: NodeIdx) anyerror!void {
        const fn_decl = self.arena.get(fn_idx);
        const f = fn_decl.fn_decl;

        const prev_ret = self.fn_ret_type;
        const prev_in_fn = self.in_function;

        self.in_function = true;
        if (f.return_type) |ret_ty| {
            self.fn_ret_type = self.inferTypeRef(ret_ty);
        } else {
            self.fn_ret_type = self.void_ty;
        }

        self.setNodeType(fn_idx, self.fn_ret_type);

        const fn_scope = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");

        for (f.generic_params.indices) |gp_idx| {
            const gp = self.arena.get(gp_idx);
            self.scopes.insert(self.nameSlice(gp.identifier), .{
                .name = gp.identifier,
                .kind = .generic_param,
                .decl_node = gp_idx,
                .type_idx = TypeIdx.none,
            }) catch @panic("OOM");
        }

        for (f.params.indices) |param_idx| {
            const param = self.arena.get(param_idx);
            const param_ty = self.inferTypeRef(param.param.ty);
            // Record the type on the binder so a closure that captures this
            // parameter can read it off the env entry (R7/R8).
            self.setNodeType(param_idx, param_ty);
            self.scopes.insert(self.nameSlice(param.param.name), .{
                .name = param.param.name,
                .kind = .param,
                .decl_node = param_idx,
                .type_idx = param_ty,
            }) catch @panic("OOM");
        }

        if (f.body != NodeIdx.none) {
            try self.checkStmt(f.body);
        }

        self.scopes.popScope();
        _ = fn_scope;

        self.fn_ret_type = prev_ret;
        self.in_function = prev_in_fn;
    }

    // ========================================================================
    // Comptime generics and monomorphization (R19-R25)
    // ========================================================================

    /// The declared name of a declaration, for diagnostics and mangling.
    fn declName(self: *const TypeChecker, decl_idx: NodeIdx) []const u8 {
        const decl = self.arena.get(decl_idx);
        return switch (decl.*) {
            .fn_decl => |f| f.name.slice(self.source),
            .struct_decl => |s| s.name.slice(self.source),
            .enum_decl => |e| e.name.slice(self.source),
            else => "generic",
        };
    }

    /// Whether a declaration is a generic template.
    fn isGenericDecl(self: *const TypeChecker, decl_idx: NodeIdx) bool {
        const decl = self.arena.get(decl_idx);
        return decl.* == .fn_decl and decl.fn_decl.generic_params.indices.len > 0;
    }

    /// The template of a generic declaration: its generic parameters, the
    /// parameter types written with `generic_param` placeholders, and the
    /// return type template (R19d).
    ///
    /// The template is resolved once per declaration and shared by every
    /// instance; substitution turns it into concrete types (R21 step 2).
    fn genericInfoFor(self: *TypeChecker, decl_idx: NodeIdx) GenericInfo {
        if (self.generic_info.get(decl_idx)) |info| return info;

        const f = self.arena.get(decl_idx).fn_decl;
        const count = f.generic_params.indices.len;

        const names = self.allocator.alloc(StringRef, count) catch @panic("OOM");
        const nodes = self.allocator.alloc(NodeIdx, count) catch @panic("OOM");
        for (f.generic_params.indices, 0..) |gp_idx, i| {
            const gp = self.arena.get(gp_idx);
            names[i] = gp.identifier;
            nodes[i] = gp_idx;
        }

        const tparams = self.allocator.alloc(TypeIdx, f.params.indices.len) catch @panic("OOM");
        for (f.params.indices, 0..) |param_idx, i| {
            const param = self.arena.get(param_idx);
            tparams[i] = self.resolveTemplateType(f.generic_params, param.param.ty);
        }

        const tret: TypeIdx = if (f.return_type) |ret|
            self.resolveTemplateType(f.generic_params, ret)
        else
            self.void_ty;

        const info = GenericInfo{
            .decl = decl_idx,
            .param_names = names,
            .param_nodes = nodes,
            .template_params = tparams,
            .template_return = tret,
        };
        self.generic_info.put(self.allocator, decl_idx, info) catch @panic("OOM");
        return info;
    }

    /// The index of the generic parameter a type node names, if any.
    fn genericParamIndex(self: *const TypeChecker, gparams: NodeList, node: NodeIdx) ?u32 {
        const inner = self.arena.get(node);
        if (inner.* != .identifier) return null;
        const name = self.nameSlice(inner.identifier);
        for (gparams.indices, 0..) |gp_idx, i| {
            const gp = self.arena.get(gp_idx);
            if (std.mem.eql(u8, self.nameSlice(gp.identifier), name)) return @intCast(i);
        }
        return null;
    }

    /// The `generic_param` placeholder for a generic parameter used in type
    /// position (R19d).
    fn genericParamType(self: *TypeChecker, node: NodeIdx, index: u32) TypeIdx {
        const inner = self.arena.get(node).identifier;
        return self.type_pool.add(.{ .generic_param = .{ .name = inner, .index = index } }) catch @panic("OOM");
    }

    /// Resolve a type node in template mode: a name that is one of the
    /// declaration's generic parameters becomes a `generic_param` placeholder;
    /// every other type resolves as usual.
    fn resolveTemplateType(self: *TypeChecker, gparams: NodeList, node: NodeIdx) TypeIdx {
        const n = self.arena.get(node);
        switch (n.*) {
            .identifier => {
                if (self.genericParamIndex(gparams, node)) |i| {
                    return self.genericParamType(node, i);
                }
                return self.inferExprType(node);
            },
            .unary_op => |u| {
                switch (u.op) {
                    .ref, .mut_ref => {
                        const pointee = self.resolveTemplateType(gparams, u.operand);
                        return self.type_pool.add(.{ .pointer = pointee }) catch @panic("OOM");
                    },
                    else => return self.inferExprType(node),
                }
            },
            .fn_type => |ft| {
                const params = self.allocator.alloc(TypeIdx, ft.params.indices.len) catch @panic("OOM");
                defer self.allocator.free(params);
                for (ft.params.indices, 0..) |p, i| {
                    params[i] = self.resolveTemplateType(gparams, p);
                }
                const ret = self.resolveTemplateType(gparams, ft.return_type);
                return self.functionType(params, ret);
            },
            .generic_app => |ga| {
                if (self.resolveTemplateApp(gparams, ga.base, ga.args.indices)) |ty| return ty;
                return self.inferExprType(node);
            },
            .index_access => |ia| {
                const one = [_]NodeIdx{ia.index};
                if (self.resolveTemplateApp(gparams, ia.object, &one)) |ty| return ty;
                return self.inferExprType(node);
            },
            else => return self.inferExprType(node),
        }
    }

    /// Resolve a type application in template mode: `Pair[T, U]` inside a
    /// generic body is an applied struct whose arguments are still
    /// placeholders.
    fn resolveTemplateApp(
        self: *TypeChecker,
        gparams: NodeList,
        base: NodeIdx,
        arg_nodes: []const NodeIdx,
    ) ?TypeIdx {
        const base_node = self.arena.get(base);
        if (base_node.* != .identifier) return null;
        const name = self.nameSlice(base_node.identifier);
        const sym = self.scopes.lookup(name, self.scopes.currentScope()) orelse return null;
        switch (sym.kind) {
            .struct_type, .enum_type => {},
            else => return null,
        }
        const decl = self.arena.get(sym.decl_node);
        const gp_count = switch (decl.*) {
            .struct_decl => |s| s.generic_params.indices.len,
            .enum_decl => |e| e.generic_params.indices.len,
            else => return null,
        };
        if (gp_count != arg_nodes.len) return null;

        const args = self.allocator.alloc(TypeIdx, arg_nodes.len) catch @panic("OOM");
        for (arg_nodes, 0..) |a, i| {
            args[i] = self.resolveTemplateType(gparams, a);
        }
        return self.appliedType(sym.decl_node, args);
    }

    /// The instance of a generic declaration for a concrete set of type
    /// arguments (R20b/R21).
    ///
    /// The instance is cached: the same `(decl, args)` always maps to the same
    /// instance (R21b), and the cache entry is published *before* the body is
    /// checked, so a recursive use resolves to the instance being built
    /// (R21a).
    fn instanceFor(self: *TypeChecker, decl_idx: NodeIdx, args: []const TypeIdx) !*GenericInstance {
        const key = self.instanceKey(decl_idx, args);
        if (self.fn_instances.get(key)) |inst| return inst;

        const info = self.genericInfoFor(decl_idx);

        // The clone stands in for the generic body: it is type-checked and
        // lowered as its own function (R21 step 2).
        const clone = try ast.cloneSubtree(self.arena, decl_idx);

        const owned_args = try self.allocator.alloc(TypeIdx, args.len);
        @memcpy(owned_args, args);

        // The concrete signature: the template's parameter and return types
        // with the type arguments substituted in.
        const param_types = try self.allocator.alloc(TypeIdx, info.template_params.len);
        defer self.allocator.free(param_types);
        for (info.template_params, 0..) |t, i| {
            param_types[i] = try generics_mod.substType(self.type_pool, t, owned_args);
        }
        const return_type = try generics_mod.substType(self.type_pool, info.template_return, owned_args);
        const sig = self.functionType(param_types, return_type);

        var mangler = generics_mod.Mangler.init(self.arena, self.source, self.type_pool, self.allocator);
        defer mangler.deinit();
        try mangler.mangleInstance(self.declName(decl_idx), owned_args);
        const mangled = try self.allocator.dupe(u8, mangler.out.items);

        const inst = try self.allocator.create(GenericInstance);
        errdefer self.allocator.destroy(inst);
        inst.* = .{
            .decl = decl_idx,
            .args = owned_args,
            .mangled = mangled,
            .clone = clone,
            .sig = sig,
            .return_type = return_type,
        };

        // Publish the instance before checking the body so that a recursive
        // use of the same `(decl, args)` resolves to it (R21a).
        try self.fn_instances.put(self.allocator, key, inst);
        try self.instance_list.append(self.allocator, inst);

        try self.checkGenericInstance(inst);
        return inst;
    }

    /// The cache key of an instance: the declaration plus the structural hash
    /// of the type arguments, so that two sites naming the same instance land
    /// on the same key (R20a).
    fn instanceKey(self: *const TypeChecker, decl_idx: NodeIdx, args: []const TypeIdx) u64 {
        var h: u64 = 0xcbf29ce484222325;
        h = (h ^ @as(u64, @intFromEnum(decl_idx))) *% 0x100000001b3;
        for (args) |arg| {
            h = (h ^ generics_mod.typeHash(self.type_pool, arg)) *% 0x100000001b3;
        }
        return h;
    }

    /// Type-check the clone of a generic body with the type arguments bound
    /// (R21 step 2: substitute, then resolve and type-check the clone in a
    /// fresh scope, exactly like ordinary code).
    fn checkGenericInstance(self: *TypeChecker, inst: *GenericInstance) !void {
        const clone = self.arena.get(inst.clone).fn_decl;

        const prev_ret = self.fn_ret_type;
        const prev_in_fn = self.in_function;

        self.in_function = true;
        self.fn_ret_type = inst.return_type;
        self.setNodeType(inst.clone, inst.return_type);

        // A fresh scope whose parent is the module scope: the instance body
        // sees the module's names, but none of the caller's locals.
        _ = self.scopes.pushScope(0) catch @panic("OOM");

        // The generic parameters, bound to their concrete types.
        for (clone.generic_params.indices, 0..) |gp_idx, i| {
            const gp = self.arena.get(gp_idx);
            self.scopes.insert(self.nameSlice(gp.identifier), .{
                .name = gp.identifier,
                .kind = .generic_param,
                .decl_node = gp_idx,
                .type_idx = inst.args[i],
            }) catch @panic("OOM");
        }

        for (clone.params.indices) |param_idx| {
            const param = self.arena.get(param_idx);
            const param_ty = self.inferTypeRef(param.param.ty);
            self.setNodeType(param_idx, param_ty);
            self.scopes.insert(self.nameSlice(param.param.name), .{
                .name = param.param.name,
                .kind = .param,
                .decl_node = param_idx,
                .type_idx = param_ty,
            }) catch @panic("OOM");
        }

        if (clone.body != NodeIdx.none) {
            try self.checkStmt(clone.body);
        }

        // The next instance starts from a clean slate.
        self.constraint_failed = false;

        self.scopes.popScope();

        self.fn_ret_type = prev_ret;
        self.in_function = prev_in_fn;
    }

    /// A call to a generic fn: resolve the type arguments — written out at the
    /// call site, or inferred from the argument types (R24) — then instantiate
    /// the declaration for them (R21).
    fn checkGenericCall(
        self: *TypeChecker,
        node_idx: NodeIdx,
        decl_idx: NodeIdx,
        callee_node: NodeIdx,
        args: NodeList,
        piped: ?NodeIdx,
        hole: ?usize,
    ) TypeIdx {
        const info = self.genericInfoFor(decl_idx);
        const name = self.declName(decl_idx);

        // The effective argument list: the piped value takes the `_` hole, or
        // is prepended as argument 0 (R30).
        var effective: std.ArrayList(NodeIdx) = .empty;
        defer effective.deinit(self.allocator);
        if (piped) |p| {
            if (hole) |h| {
                for (args.indices, 0..) |a, i| {
                    effective.append(self.allocator, if (i == h) p else a) catch @panic("OOM");
                }
            } else {
                effective.append(self.allocator, p) catch @panic("OOM");
                for (args.indices) |a| effective.append(self.allocator, a) catch @panic("OOM");
            }
        } else {
            for (args.indices) |a| effective.append(self.allocator, a) catch @panic("OOM");
        }

        // The type arguments: written out at the call site, or inferred.
        var concrete: []TypeIdx = &.{};
        var owned_concrete = false;
        defer if (owned_concrete) self.allocator.free(concrete);

        if (self.explicitTypeArgs(callee_node)) |ta| {
            if (ta.len != info.paramCount()) {
                self.allocator.free(ta);
                self.errorAt(node_idx, "generic '{s}' expects {d} type argument(s), got {d}", .{
                    name, info.paramCount(), ta.len,
                });
                for (effective.items) |a| _ = self.inferExprType(a);
                return self.void_ty;
            }
            concrete = ta;
            owned_concrete = true;
        } else {
            const inferred = self.inferGenericArgs(node_idx, info, effective.items, name) orelse {
                for (effective.items) |a| _ = self.inferExprType(a);
                return self.void_ty;
            };
            concrete = inferred;
            owned_concrete = true;
        }

        const inst = self.instanceFor(decl_idx, concrete) catch |err| {
            self.errorAt(node_idx, "cannot instantiate generic '{s}': {s}", .{ name, @errorName(err) });
            return self.void_ty;
        };

        // Check the value arguments against the instance's concrete parameter
        // types.
        const param_types = self.type_pool.get(inst.sig).function.param_types;
        self.checkArgList(node_idx, param_types, args, piped, hole);

        self.instance_by_callee.put(self.allocator, callee_node, inst) catch @panic("OOM");
        return inst.return_type;
    }

    /// The type arguments written at a generic call site: `first[i32](...)`
    /// and `pair[i32, f64](...)`.
    fn explicitTypeArgs(self: *TypeChecker, callee_node: NodeIdx) ?[]TypeIdx {
        const n = self.arena.get(callee_node);
        switch (n.*) {
            .index_access => |ia| {
                const out = self.allocator.alloc(TypeIdx, 1) catch @panic("OOM");
                out[0] = self.inferExprType(ia.index);
                return out;
            },
            .generic_app => |ga| {
                const out = self.allocator.alloc(TypeIdx, ga.args.indices.len) catch @panic("OOM");
                for (ga.args.indices, 0..) |a, i| out[i] = self.inferExprType(a);
                return out;
            },
            else => return null,
        }
    }

    /// Infer the type arguments of a generic call from the argument types
    /// (R24).
    ///
    /// Each generic parameter that occurs in a parameter type is unified
    /// *from* the corresponding argument type — one-way, argument to
    /// parameter. A parameter that occurs only in the return type is not
    /// inferable and has to be written out (R24b).
    fn inferGenericArgs(
        self: *TypeChecker,
        node_idx: NodeIdx,
        info: GenericInfo,
        arg_nodes: []const NodeIdx,
        name: []const u8,
    ) ?[]TypeIdx {
        var bindings = generics_mod.Bindings.init(self.allocator, info.paramCount()) catch @panic("OOM");
        defer bindings.deinit(self.allocator);

        const arg_types = self.allocator.alloc(TypeIdx, arg_nodes.len) catch @panic("OOM");
        defer self.allocator.free(arg_types);
        for (arg_nodes, 0..) |a, i| arg_types[i] = self.inferExprType(a);

        for (info.template_params, arg_types) |t, a| {
            generics_mod.unifyTemplate(self.type_pool, t, a, &bindings);
        }

        if (bindings.conflict) {
            const pname = if (bindings.conflict_index < info.param_names.len)
                self.nameSlice(info.param_names[bindings.conflict_index])
            else
                name;
            self.errorAt(node_idx, "conflicting types for generic parameter '{s}' of '{s}'", .{ pname, name });
            return null;
        }

        const out = self.allocator.alloc(TypeIdx, info.paramCount()) catch @panic("OOM");
        errdefer self.allocator.free(out);
        for (info.param_names, 0..) |pn, i| {
            const bound = bindings.bound[i] orelse {
                self.errorAt(node_idx, "cannot infer generic parameter '{s}' of '{s}'; write it out", .{
                    self.nameSlice(pn), name,
                });
                return null;
            };
            if (!self.isConcrete(bound)) {
                self.errorAt(node_idx, "cannot infer a concrete type for generic parameter '{s}' of '{s}'", .{
                    self.nameSlice(pn), name,
                });
                return null;
            }
            out[i] = bound;
        }
        return out;
    }

    /// The generic declaration a callee node names, if any: `first[i32](...)`
    /// and `pair[i32, f64](...)` name a generic fn with explicit type
    /// arguments.
    fn genericCalleeDecl(self: *TypeChecker, callee_node: NodeIdx) ?NodeIdx {
        const n = self.arena.get(callee_node);
        const base = switch (n.*) {
            .index_access => |ia| ia.object,
            .generic_app => |ga| ga.base,
            else => return null,
        };
        const base_node = self.arena.get(base);
        if (base_node.* != .identifier) return null;
        const name = self.nameSlice(base_node.identifier);
        const sym = self.scopes.lookup(name, self.scopes.currentScope()) orelse return null;
        if (sym.kind != .function) return null;
        if (!self.isGenericDecl(sym.decl_node)) return null;
        return sym.decl_node;
    }

    // ========================================================================
    // Comptime evaluation (R23)
    // ========================================================================

    /// The comptime value of a node. `.none` means the expression has no
    /// compile-time value.
    pub fn comptimeValue(self: *const TypeChecker, node_idx: NodeIdx) ComptimeValue {
        return self.getComptimeValue(node_idx);
    }

    /// The branch a `comptime if` takes: true when the then-branch is taken.
    pub fn comptimeBranch(self: *const TypeChecker, node_idx: NodeIdx) ?bool {
        return self.getComptimeBranch(node_idx);
    }

    /// Type-check a comptime builtin call and evaluate it (R23a).
    ///
    /// The roster is final: `@typeOf`, `@sizeOf`, `@alignOf`, `@hasField`,
    /// `@field` and `@assert`. The result type follows the builtin, and the
    /// value is recorded so that the lowerer does not have to recompute it.
    fn inferComptimeCall(self: *TypeChecker, node_idx: NodeIdx, cc: anytype) TypeIdx {
        const name = self.nameSlice(cc.name);
        var ty: TypeIdx = self.void_ty;
        if (std.mem.eql(u8, name, "typeOf")) {
            ty = self.type_value_ty;
        } else if (std.mem.eql(u8, name, "sizeOf") or std.mem.eql(u8, name, "alignOf")) {
            ty = self.u64_ty;
        } else if (std.mem.eql(u8, name, "hasField")) {
            ty = self.bool_ty;
        } else if (std.mem.eql(u8, name, "field")) {
            ty = self.comptimeFieldType(node_idx, cc);
        }
        const value = self.evalComptimeCall(node_idx, cc);
        self.comptime_values.put(self.allocator, node_idx, .{ .value = value, .ty = ty }) catch @panic("OOM");
        return ty;
    }

    /// Evaluate a comptime builtin call (R23a).
    ///
    /// Every builtin evaluates once its arguments are concrete, which — inside
    /// an instance — they are: the type arguments are already substituted.
    fn evalComptimeCall(self: *TypeChecker, node_idx: NodeIdx, cc: anytype) ComptimeValue {
        const name = self.nameSlice(cc.name);

        if (std.mem.eql(u8, name, "typeOf")) {
            if (cc.args.indices.len != 1) {
                self.errorAt(node_idx, "@typeOf expects one argument", .{});
                return .{ .none = {} };
            }
            return .{ .type_value = self.inferExprType(cc.args.indices[0]) };
        }

        if (std.mem.eql(u8, name, "sizeOf") or std.mem.eql(u8, name, "alignOf")) {
            if (cc.args.indices.len != 1) {
                self.errorAt(node_idx, "@{s} expects one type argument", .{name});
                return .{ .none = {} };
            }
            const ty = self.comptimeTypeArg(cc.args.indices[0]) orelse {
                self.errorAt(node_idx, "@{s} expects a type argument", .{name});
                return .{ .none = {} };
            };
            const size: i64 = if (std.mem.eql(u8, name, "sizeOf"))
                self.sizeOfType(ty)
            else
                self.alignOfType(ty);
            return .{ .int = size };
        }

        if (std.mem.eql(u8, name, "hasField")) {
            if (cc.args.indices.len != 2) {
                self.errorAt(node_idx, "@hasField expects a type and a field name", .{});
                return .{ .none = {} };
            }
            const ty = self.comptimeTypeArg(cc.args.indices[0]) orelse {
                self.errorAt(node_idx, "@hasField expects a type argument", .{});
                return .{ .none = {} };
            };
            const field = self.stringLiteral(cc.args.indices[1]) orelse {
                self.errorAt(node_idx, "@hasField expects a string field name", .{});
                return .{ .none = {} };
            };
            return .{ .bool = self.structHasField(ty, field) };
        }

        if (std.mem.eql(u8, name, "field")) {
            if (cc.args.indices.len != 2) {
                self.errorAt(node_idx, "@field expects a value and a field name", .{});
                return .{ .none = {} };
            }
            const field = self.stringLiteral(cc.args.indices[1]) orelse {
                self.errorAt(node_idx, "@field expects a string field name", .{});
                return .{ .none = {} };
            };
            // A struct literal is a comptime value, so its field is one too;
            // any other value is read at runtime.
            const obj = self.arena.get(cc.args.indices[0]);
            if (obj.* == .struct_init) {
                const value_node = self.structInitFieldValue(obj.struct_init, field) orelse return .{ .none = {} };
                return self.evalComptime(value_node);
            }
            return .{ .none = {} };
        }

        if (std.mem.eql(u8, name, "assert")) {
            if (cc.args.indices.len == 0 or cc.args.indices.len > 2) {
                self.errorAt(node_idx, "@assert expects a condition and an optional message", .{});
                return .{ .none = {} };
            }
            const cond = self.evalComptime(cc.args.indices[0]);
            var message: []const u8 = "";
            if (cc.args.indices.len == 2) {
                message = self.stringLiteral(cc.args.indices[1]) orelse "";
            }
            switch (cond) {
                .bool => |ok| {
                    if (!ok) self.reportConstraintFailure(node_idx, cc.args.indices[0], message);
                },
                .none => self.errorAt(node_idx, "@assert needs a comptime condition", .{}),
                else => self.errorAt(node_idx, "@assert needs a bool condition", .{}),
            }
            return .{ .bool = true };
        }

        self.errorAt(node_idx, "unknown comptime builtin '@{s}'", .{name});
        return .{ .none = {} };
    }

    /// Evaluate an expression to a comptime value (R23a).
    ///
    /// Only the expressions whose value is known at compile time evaluate: the
    /// literals, the comptime builtins, and the operators over them.
    fn evalComptime(self: *TypeChecker, node_idx: NodeIdx) ComptimeValue {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .int_literal => |v| return .{ .int = v },
            .float_literal => |v| return .{ .float = v },
            .string_literal => |ref| return .{ .string = self.stringContent(ref) },
            .char_literal => |ref| return .{ .int = self.charCode(ref) },
            .bool_literal => |v| return .{ .bool = v },
            .paren_expr => |p| return self.evalComptime(p),
            .unary_op => |u| return self.evalComptimeUnary(u),
            .binary_op => |b| return self.evalComptimeBinary(b),
            .comptime_expr => |inner| return self.evalComptime(inner),
            .comptime_call => {
                // An evaluated builtin keeps its value, so it is never
                // evaluated (and never diagnosed) twice.
                if (self.comptime_values.get(node_idx)) |b| return b.value;
                return self.evalComptimeCall(node_idx, node.comptime_call);
            },
            .if_expr => |i| {
                const taken = self.comptime_branches.get(node_idx) orelse return .{ .none = {} };
                const branch = if (taken) i.then_body else (i.else_body orelse return .{ .none = {} });
                return self.evalComptime(branch);
            },
            else => return .{ .none = {} },
        }
    }

    /// The comptime value of a unary operation over a comptime operand.
    fn evalComptimeUnary(self: *TypeChecker, u: anytype) ComptimeValue {
        const operand = self.evalComptime(u.operand);
        return switch (operand) {
            .int => |v| switch (u.op) {
                .neg => ComptimeValue{ .int = -%v },
                .bit_not => ComptimeValue{ .int = ~v },
                else => ComptimeValue{ .none = {} },
            },
            .float => |v| switch (u.op) {
                .neg => ComptimeValue{ .float = -v },
                else => ComptimeValue{ .none = {} },
            },
            .bool => |v| switch (u.op) {
                .not => ComptimeValue{ .bool = !v },
                else => ComptimeValue{ .none = {} },
            },
            else => ComptimeValue{ .none = {} },
        };
    }

    /// The comptime value of a binary operation over comptime operands.
    fn evalComptimeBinary(self: *TypeChecker, b: anytype) ComptimeValue {
        const left = self.evalComptime(b.left);
        const right = self.evalComptime(b.right);

        // Type values compare by identity (def-eq).
        if (left == .type_value or right == .type_value) {
            const eq_opt = switch (left) {
                .type_value => |lv| blk: {
                    const other = switch (right) {
                        .type_value => |rv| rv,
                        else => self.comptimeTypeArg(b.right) orelse break :blk null,
                    };
                    break :blk self.typesEqual(lv, other);
                },
                else => blk: {
                    const other = self.comptimeTypeArg(b.left) orelse break :blk null;
                    break :blk self.typesEqual(other, right.type_value);
                },
            };
            if (eq_opt == null) return ComptimeValue{ .none = {} };
            const eq = eq_opt.?;
            return switch (b.op) {
                .eq => ComptimeValue{ .bool = eq },
                .ne => ComptimeValue{ .bool = !eq },
                else => ComptimeValue{ .none = {} },
            };
        }

        switch (left) {
            .int => |lv| switch (right) {
                .int => |rv| return comptimeIntOp(b.op, lv, rv),
                .float => |rv| return comptimeFloatOp(b.op, @floatFromInt(lv), rv),
                else => return ComptimeValue{ .none = {} },
            },
            .float => |lv| switch (right) {
                .int => |rv| return comptimeFloatOp(b.op, lv, @floatFromInt(rv)),
                .float => |rv| return comptimeFloatOp(b.op, lv, rv),
                else => return ComptimeValue{ .none = {} },
            },
            .bool => |lv| switch (right) {
                .bool => |rv| return switch (b.op) {
                    .eq => ComptimeValue{ .bool = lv == rv },
                    .ne => ComptimeValue{ .bool = lv != rv },
                    .and_op => ComptimeValue{ .bool = lv and rv },
                    .or_op => ComptimeValue{ .bool = lv or rv },
                    else => ComptimeValue{ .none = {} },
                },
                else => return ComptimeValue{ .none = {} },
            },
            .string => |lv| switch (right) {
                .string => |rv| return switch (b.op) {
                    .eq => ComptimeValue{ .bool = std.mem.eql(u8, lv, rv) },
                    .ne => ComptimeValue{ .bool = !std.mem.eql(u8, lv, rv) },
                    else => ComptimeValue{ .none = {} },
                },
                else => return ComptimeValue{ .none = {} },
            },
            else => return ComptimeValue{ .none = {} },
        }
    }

    /// A `comptime if`: the condition is evaluated at compile time and only
    /// the branch it selects is type-checked and lowered (R23c).
    ///
    /// Specialization is the point of the construct, so the branch that is not
    /// taken is pruned: it is never checked and never emitted.
    fn inferComptimeIf(self: *TypeChecker, expr_idx: NodeIdx, if_idx: NodeIdx) TypeIdx {
        const i = self.arena.get(if_idx).if_expr;
        const cond = self.evalComptime(i.cond);
        var taken_then = false;
        switch (cond) {
            .bool => |ok| taken_then = ok,
            .none => self.errorAt(expr_idx, "a comptime condition must be known at compile time", .{}),
            else => self.errorAt(expr_idx, "a comptime condition must be a bool", .{}),
        }
        self.comptime_branches.put(self.allocator, if_idx, taken_then) catch @panic("OOM");

        const branch: NodeIdx = if (taken_then) i.then_body else (i.else_body orelse NodeIdx.none);
        var ty: TypeIdx = self.void_ty;
        if (branch != NodeIdx.none) ty = self.inferExprType(branch);
        self.setNodeType(if_idx, ty);
        return ty;
    }

    /// The type a node denotes in type position: a generic parameter, a
    /// builtin type name, a struct or enum declaration, or an application of
    /// one. Null when the node does not denote a type.
    fn comptimeTypeArg(self: *TypeChecker, node_idx: NodeIdx) ?TypeIdx {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .identifier => |id| {
                const name = self.nameSlice(id);
                if (self.builtinTypeName(name)) |ty| return ty;
                const sym = self.scopes.lookup(name, self.scopes.currentScope()) orelse return null;
                switch (sym.kind) {
                    // A generic parameter stands for the type argument the
                    // instance was created with.
                    .generic_param => return sym.type_idx,
                    .struct_type, .enum_type => return self.resolveDeclType(sym.decl_node),
                    else => return null,
                }
            },
            .generic_app => {
                const ty = self.inferExprType(node_idx);
                return switch (self.type_pool.get(ty)) {
                    .struct_type, .applied_struct, .enum_type, .applied_enum => ty,
                    else => null,
                };
            },
            .index_access => |ia| {
                // A one-argument application of a generic type name.
                const base = self.arena.get(ia.object);
                if (base.* != .identifier) return null;
                const sym = self.scopes.lookup(self.nameSlice(base.identifier), self.scopes.currentScope()) orelse return null;
                if (sym.kind != .struct_type and sym.kind != .enum_type) return null;
                const ty = self.inferExprType(node_idx);
                return switch (self.type_pool.get(ty)) {
                    .struct_type, .applied_struct, .enum_type, .applied_enum => ty,
                    else => null,
                };
            },
            .fn_type => return self.inferExprType(node_idx),
            .unary_op => |u| switch (u.op) {
                .ref, .mut_ref => {
                    const pointee = self.comptimeTypeArg(u.operand) orelse return null;
                    return self.type_pool.add(.{ .pointer = pointee }) catch @panic("OOM");
                },
                else => return null,
            },
            else => return null,
        }
    }

    /// The text of a string literal node, without its surrounding quotes.
    fn stringLiteral(self: *const TypeChecker, node_idx: NodeIdx) ?[]const u8 {
        const node = self.arena.get(node_idx);
        if (node.* != .string_literal) return null;
        return self.stringContent(node.string_literal);
    }

    /// The source text of a string literal token, stripped of its quotes.
    ///
    /// The lexer keeps the quotes in the token's lexeme, so comptime string
    /// values (`@hasField`'s field name, `@assert`'s message) must be bare.
    fn stringContent(self: *const TypeChecker, ref: StringRef) []const u8 {
        const raw = ref.slice(self.source);
        if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') return raw[1 .. raw.len - 1];
        return raw;
    }

    /// The initializer of a named field of a struct literal.
    fn structInitFieldValue(self: *const TypeChecker, si: anytype, field_name: []const u8) ?NodeIdx {
        for (si.fields.indices) |field_idx| {
            const field = self.arena.get(field_idx).struct_init_field;
            if (std.mem.eql(u8, self.nameSlice(field.name), field_name)) return field.value;
        }
        return null;
    }

    /// Whether a type is a struct with the named field (R23a).
    fn structHasField(self: *TypeChecker, ty: TypeIdx, field_name: []const u8) bool {
        return switch (self.type_pool.get(ty)) {
            .struct_type => |decl| self.structFieldType(decl, field_name) != null,
            .applied_struct => |a| self.appliedFieldType(a.decl, a.args, field_name) != null,
            else => false,
        };
    }

    /// The type of a named field of a struct type.
    fn fieldTypeOf(self: *TypeChecker, ty: TypeIdx, field_name: []const u8) ?TypeIdx {
        return switch (self.type_pool.get(ty)) {
            .struct_type => |decl| self.structFieldType(decl, field_name),
            .applied_struct => |a| self.appliedFieldType(a.decl, a.args, field_name),
            else => null,
        };
    }

    /// The type of `@field(x, "name")`: the type of the named field of `x`.
    fn comptimeFieldType(self: *TypeChecker, node_idx: NodeIdx, cc: anytype) TypeIdx {
        if (cc.args.indices.len != 2) {
            self.errorAt(node_idx, "@field expects a value and a field name", .{});
            return self.void_ty;
        }
        const obj_ty = self.inferExprType(cc.args.indices[0]);
        const field = self.stringLiteral(cc.args.indices[1]) orelse {
            self.errorAt(node_idx, "@field expects a string field name", .{});
            return self.void_ty;
        };
        return self.fieldTypeOf(obj_ty, field) orelse {
            self.errorAt(node_idx, "'{s}' has no field '{s}'", .{ self.typeName(obj_ty), field });
            return self.void_ty;
        };
    }

    /// The byte size of a type (docs/semantics.md §3).
    fn sizeOfType(self: *const TypeChecker, ty: TypeIdx) i64 {
        return switch (self.type_pool.get(ty)) {
            .void => 0,
            .bool_type => 1,
            .int => |i| @divExact(i.bits, 8),
            .float => |f| switch (f) {
                .f16 => 2,
                .f32 => 4,
                .f64 => 8,
            },
            .string_type => 16,
            .pointer => 8,
            .function => 16,
            .struct_type => |decl| 8 * @as(i64, @intCast(structFieldCount(self.arena, decl))),
            .applied_struct => |a| 8 * @as(i64, @intCast(structFieldCount(self.arena, a.decl))),
            .enum_type => |decl| 8 * @as(i64, @intCast(enumPayloadSlots(self.arena, decl) + 1)),
            .applied_enum => |a| 8 * @as(i64, @intCast(enumPayloadSlots(self.arena, a.decl) + 1)),
            .array => |a| @as(i64, @intCast(a.size orelse 0)) * self.sizeOfType(a.elem),
            .slice => 16,
            .generic_param => 8,
            .type_value => 8,
            .applied_fn => 16,
            .inferred => 8,
        };
    }

    /// The natural alignment of a type (docs/semantics.md §3).
    fn alignOfType(self: *const TypeChecker, ty: TypeIdx) i64 {
        return switch (self.type_pool.get(ty)) {
            .bool_type => 1,
            .int => |i| if (i.bits <= 8) 1 else if (i.bits <= 16) 2 else if (i.bits <= 32) 4 else 8,
            .float => |f| switch (f) {
                .f16 => 2,
                .f32 => 4,
                .f64 => 8,
            },
            .type_value => 8,
            .applied_fn => 8,
            .inferred => 8,
            .void, .string_type, .pointer, .function, .struct_type, .applied_struct, .enum_type, .applied_enum, .array, .slice, .generic_param => 8,
        };
    }

    /// The code point of a character literal.
    fn charCode(self: *const TypeChecker, ref: StringRef) i64 {
        const raw = ref.slice(self.source);
        if (raw.len < 2) return 0;
        const body = raw[1 .. raw.len - 1];
        if (body.len == 0) return 0;
        if (body[0] != '\\') return body[0];
        if (body.len < 2) return 0;
        return switch (body[1]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            '\\' => '\\',
            '\'' => '\'',
            else => body[1],
        };
    }

    /// Report a failed comptime constraint (R23b).
    ///
    /// A constraint that mentions a bound generic parameter is reported as a
    /// generic constraint failure naming the parameter and the type argument
    /// it was given; anything else uses the assertion's own message.
    fn reportConstraintFailure(self: *TypeChecker, node_idx: NodeIdx, cond: NodeIdx, message: []const u8) void {
        if (self.genericParamMention(cond)) |param_node| {
            const name = self.nameSlice(self.arena.get(param_node).identifier);
            const sym = self.scopes.lookup(name, self.scopes.currentScope());
            const arg_ty = if (sym) |s| s.type_idx else TypeIdx.none;
            const rendered = self.renderComptimeExpr(cond);
            self.errorAt(node_idx, "generic constraint not satisfied: {s} = {s} does not satisfy {s}", .{
                name, self.typeName(arg_ty), rendered,
            });
            self.constraint_failed = true;
            return;
        }
        if (message.len > 0) {
            self.errorAt(node_idx, "{s}", .{message});
        } else {
            self.errorAt(node_idx, "comptime assertion failed", .{});
        }
        self.constraint_failed = true;
    }

    /// The generic parameter an expression mentions, if any: an identifier
    /// that resolves to a generic parameter of the enclosing instance.
    fn genericParamMention(self: *TypeChecker, node_idx: NodeIdx) ?NodeIdx {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .identifier => |id| {
                const name = self.nameSlice(id);
                const sym = self.scopes.lookup(name, self.scopes.currentScope()) orelse return null;
                if (sym.kind != .generic_param) return null;
                return node_idx;
            },
            .binary_op => |b| {
                if (self.genericParamMention(b.left)) |n| return n;
                return self.genericParamMention(b.right);
            },
            .unary_op => |u| return self.genericParamMention(u.operand),
            .paren_expr => |p| return self.genericParamMention(p),
            .comptime_expr => |inner| return self.genericParamMention(inner),
            .comptime_call => |cc| {
                for (cc.args.indices) |arg| {
                    if (self.genericParamMention(arg)) |n| return n;
                }
                return null;
            },
            .field_access => |fa| return self.genericParamMention(fa.object),
            .index_access => |ia| {
                if (self.genericParamMention(ia.object)) |n| return n;
                return self.genericParamMention(ia.index);
            },
            .generic_app => |ga| {
                if (self.genericParamMention(ga.base)) |n| return n;
                for (ga.args.indices) |arg| {
                    if (self.genericParamMention(arg)) |n| return n;
                }
                return null;
            },
            .call => |c| {
                if (self.genericParamMention(c.func)) |n| return n;
                for (c.args.indices) |arg| {
                    if (self.genericParamMention(arg)) |n| return n;
                }
                return null;
            },
            .struct_init => |si| {
                for (si.fields.indices) |field_idx| {
                    const value = self.arena.get(field_idx).struct_init_field.value;
                    if (self.genericParamMention(value)) |n| return n;
                }
                return null;
            },
            .if_expr => |i| {
                if (self.genericParamMention(i.cond)) |n| return n;
                if (self.genericParamMention(i.then_body)) |n| return n;
                if (i.else_body) |else_body| {
                    if (self.genericParamMention(else_body)) |n| return n;
                }
                return null;
            },
            .pipeline => |p| {
                if (self.genericParamMention(p.lhs)) |n| return n;
                return self.genericParamMention(p.rhs);
            },
            .try_propagate => |inner| return self.genericParamMention(inner),
            .move_expr => |inner| return self.genericParamMention(inner),
            .block => |b| {
                for (b.stmts.indices) |stmt| {
                    if (self.genericParamMention(stmt)) |n| return n;
                }
                return null;
            },
            else => return null,
        }
    }

    /// Render a comptime expression as source text, for a diagnostic: the
    /// constraint that failed is shown the way it was written.
    fn renderComptimeExpr(self: *TypeChecker, node_idx: NodeIdx) []const u8 {
        var len: usize = 0;
        self.renderComptimeExprInto(node_idx, &self.constraint_buf, &len);
        return self.constraint_buf[0..len];
    }

    fn renderComptimeExprInto(self: *TypeChecker, node_idx: NodeIdx, buf: []u8, len: *usize) void {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .identifier => |id| self.appendTo(buf, len, self.nameSlice(id)),
            .string_literal => |ref| self.appendTo(buf, len, self.nameSlice(ref)),
            .char_literal => |ref| self.appendTo(buf, len, self.nameSlice(ref)),
            .int_literal => |v| {
                var tmp: [24]u8 = undefined;
                self.appendTo(buf, len, std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "0");
            },
            .float_literal => |v| {
                var tmp: [24]u8 = undefined;
                self.appendTo(buf, len, std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "0");
            },
            .bool_literal => |v| self.appendTo(buf, len, if (v) "true" else "false"),
            .comptime_call => |cc| {
                self.appendTo(buf, len, "@");
                self.appendTo(buf, len, self.nameSlice(cc.name));
                self.appendTo(buf, len, "(");
                for (cc.args.indices, 0..) |arg, i| {
                    if (i > 0) self.appendTo(buf, len, ", ");
                    self.renderComptimeExprInto(arg, buf, len);
                }
                self.appendTo(buf, len, ")");
            },
            .paren_expr => |p| {
                self.appendTo(buf, len, "(");
                self.renderComptimeExprInto(p, buf, len);
                self.appendTo(buf, len, ")");
            },
            .binary_op => |b| {
                self.renderComptimeExprInto(b.left, buf, len);
                self.appendTo(buf, len, " ");
                self.appendTo(buf, len, binaryOpName(b.op));
                self.appendTo(buf, len, " ");
                self.renderComptimeExprInto(b.right, buf, len);
            },
            .unary_op => |u| {
                self.appendTo(buf, len, unaryOpName(u.op));
                self.renderComptimeExprInto(u.operand, buf, len);
            },
            .comptime_expr => |inner| {
                self.appendTo(buf, len, "comptime ");
                self.renderComptimeExprInto(inner, buf, len);
            },
            .field_access => |fa| {
                self.renderComptimeExprInto(fa.object, buf, len);
                self.appendTo(buf, len, ".");
                self.appendTo(buf, len, self.nameSlice(fa.field));
            },
            .index_access => |ia| {
                self.renderComptimeExprInto(ia.object, buf, len);
                self.appendTo(buf, len, "[");
                self.renderComptimeExprInto(ia.index, buf, len);
                self.appendTo(buf, len, "]");
            },
            .generic_app => |ga| {
                self.renderComptimeExprInto(ga.base, buf, len);
                self.appendTo(buf, len, "[");
                for (ga.args.indices, 0..) |arg, i| {
                    if (i > 0) self.appendTo(buf, len, ", ");
                    self.renderComptimeExprInto(arg, buf, len);
                }
                self.appendTo(buf, len, "]");
            },
            .call => |c| {
                self.renderComptimeExprInto(c.func, buf, len);
                self.appendTo(buf, len, "(");
                for (c.args.indices, 0..) |arg, i| {
                    if (i > 0) self.appendTo(buf, len, ", ");
                    self.renderComptimeExprInto(arg, buf, len);
                }
                self.appendTo(buf, len, ")");
            },
            .if_expr => |i| {
                self.appendTo(buf, len, "if ");
                self.renderComptimeExprInto(i.cond, buf, len);
                self.appendTo(buf, len, " { ... }");
                if (i.else_body != null) self.appendTo(buf, len, " else { ... }");
            },
            .pipeline => |p| {
                self.renderComptimeExprInto(p.lhs, buf, len);
                self.appendTo(buf, len, " |> ");
                self.renderComptimeExprInto(p.rhs, buf, len);
            },
            .try_propagate => |inner| {
                self.renderComptimeExprInto(inner, buf, len);
                self.appendTo(buf, len, "?");
            },
            .move_expr => |inner| {
                self.appendTo(buf, len, "move ");
                self.renderComptimeExprInto(inner, buf, len);
            },
            .fn_type => |ft| {
                self.appendTo(buf, len, "fn(");
                for (ft.params.indices, 0..) |arg, i| {
                    if (i > 0) self.appendTo(buf, len, ", ");
                    self.renderComptimeExprInto(arg, buf, len);
                }
                self.appendTo(buf, len, ") -> ");
                self.renderComptimeExprInto(ft.return_type, buf, len);
            },
            .block => {
                self.appendTo(buf, len, "{ ... }");
            },
            .struct_init => |si| {
                self.renderComptimeExprInto(si.ty, buf, len);
                self.appendTo(buf, len, "{ ... }");
            },
            else => self.appendTo(buf, len, "..."),
        }
    }

    /// Append text to a fixed buffer, dropping what does not fit.
    fn appendTo(_: *TypeChecker, buf: []u8, len: *usize, text: []const u8) void {
        const room = buf.len - len.*;
        const n = @min(room, text.len);
        @memcpy(buf[len.*..][0..n], text[0..n]);
        len.* += n;
    }

    fn checkStmt(self: *TypeChecker, stmt_idx: NodeIdx) anyerror!void {
        // A failed comptime constraint stops the check of the instance it was
        // found in (R23b).
        if (self.constraint_failed) return;
        const stmt = self.arena.get(stmt_idx);
        switch (stmt.*) {
            .block => |b| {
                _ = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");
                for (b.stmts.indices) |inner| {
                    try self.checkStmt(inner);
                }
                self.scopes.popScope();
            },
            .let_stmt => |l| {
                var declared_ty: TypeIdx = self.void_ty;
                if (l.ty) |ty| {
                    declared_ty = self.inferTypeRef(ty);
                }
                self.setNodeType(stmt_idx, declared_ty);

                const has_concrete_annotation = l.ty != null and self.isConcrete(declared_ty);
                if (l.init_expr) |init_val| {
                    // Thread the annotation down so an unannotated closure whose
                    // parameter types only the annotation fixes still infers
                    // (R11b). Doing this instead of a plain `inferExprType`
                    // keeps a closure init from erroring before it sees the
                    // expected signature.
                    const init_ty = if (has_concrete_annotation)
                        self.inferExprTypeExpected(init_val, declared_ty)
                    else
                        self.inferExprType(init_val);
                    if (has_concrete_annotation) {
                        if (!self.typesEqual(declared_ty, init_ty)) {
                            self.errorAt(stmt_idx, "type mismatch: expected '{s}' but got '{s}'", .{
                                self.typeName(declared_ty), self.typeName(init_ty),
                            });
                        }
                    }
                    self.setNodeType(stmt_idx, init_ty);
                }

                self.scopes.insert(self.nameSlice(l.name), .{
                    .name = l.name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = self.getNodeType(stmt_idx),
                }) catch @panic("OOM");
            },
            .return_stmt => |r| {
                if (r.value) |val| {
                    // `expected` is the already-fixed return type, or the
                    // placeholder itself while an unannotated closure's return
                    // type is still open.
                    const expected = self.pendingResolved(self.fn_ret_type);
                    const val_ty = if (self.isConcrete(expected))
                        self.inferExprTypeExpected(val, expected)
                    else
                        self.inferExprType(val);
                    // The first concrete `return x` in an unannotated closure
                    // fixes that closure's return type (R11c).
                    if (self.isInferred(self.fn_ret_type) and self.isConcrete(val_ty)) {
                        self.resolvePlaceholder(self.fn_ret_type, val_ty);
                    }
                    const fixed = self.pendingResolved(self.fn_ret_type);
                    if (!self.typesEqual(val_ty, fixed)) {
                        self.errorAt(stmt_idx, "return type mismatch: expected '{s}' but got '{s}'", .{
                            self.typeName(fixed), self.typeName(val_ty),
                        });
                    }
                }
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .expr_stmt => |e| {
                _ = self.inferExprType(e.expr);
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .defer_stmt => |d| {
                _ = self.inferExprType(d.expr);
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .if_expr => |i| {
                const cond_ty = self.inferExprType(i.cond);
                if (!self.typesEqual(cond_ty, self.bool_ty)) {
                    self.errorAt(stmt_idx, "if condition must be bool, got '{s}'", .{self.typeName(cond_ty)});
                }
                try self.checkStmt(i.then_body);
                if (i.else_body) |else_b| {
                    try self.checkStmt(else_b);
                }
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .while_expr => |w| {
                const cond_ty = self.inferExprType(w.cond);
                if (!self.typesEqual(cond_ty, self.bool_ty)) {
                    self.errorAt(stmt_idx, "while condition must be bool, got '{s}'", .{self.typeName(cond_ty)});
                }
                try self.checkStmt(w.body);
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .for_range => |fr| {
                _ = self.inferExprType(fr.start);
                _ = self.inferExprType(fr.end);
                _ = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");
                self.scopes.insert(self.nameSlice(fr.var_name), .{
                    .name = fr.var_name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = self.i32_ty,
                }) catch @panic("OOM");
                try self.checkStmt(fr.body);
                self.scopes.popScope();
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .for_each => |fe| {
                const iter_ty = self.inferExprType(fe.iterable);
                const var_ty = self.forEachElemType(stmt_idx, iter_ty);
                _ = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");
                self.scopes.insert(self.nameSlice(fe.var_name), .{
                    .name = fe.var_name,
                    .kind = .local,
                    .decl_node = stmt_idx,
                    .type_idx = var_ty,
                }) catch @panic("OOM");
                try self.checkStmt(fe.body);
                self.scopes.popScope();
                self.setNodeType(stmt_idx, self.void_ty);
            },
            .match_expr => |m| {
                try self.checkMatchStmt(stmt_idx, m);
            },
            .fn_decl => {
                try self.checkFnDecl(stmt_idx);
            },
            else => {
                _ = self.inferExprType(stmt_idx);
            },
        }
    }

    fn inferExprType(self: *TypeChecker, expr_idx: NodeIdx) TypeIdx {
        // A comptime expression keeps both its value and its type: evaluating
        // it twice would repeat the diagnostics it produced.
        if (self.comptime_values.get(expr_idx)) |b| return b.ty;
        const prev = self.getNodeType(expr_idx);
        if (prev != self.void_ty) return prev;

        const expr = self.arena.get(expr_idx);
        const ty = self.inferExprTypeInner(expr_idx, expr);
        self.setNodeType(expr_idx, ty);
        return ty;
    }

    fn inferGenericApp(self: *TypeChecker, expr_idx: NodeIdx, ga: anytype) TypeIdx {
        const base = self.inferExprType(ga.base);
        // Type arguments of the application (`Pair[i32, f64]` -> i32, f64).
        const arg_count = ga.args.indices.len;
        const args = self.allocator.alloc(TypeIdx, arg_count) catch @panic("OOM");
        defer self.allocator.free(args);
        for (ga.args.indices, 0..) |arg_idx, i| {
            args[i] = self.inferExprType(arg_idx);
        }
        return self.applyTypeArgs(expr_idx, base, args);
    }

    /// Apply type arguments to a generic struct or enum declaration
    /// (R19c/R25).
    fn applyTypeArgs(self: *TypeChecker, expr_idx: NodeIdx, base: TypeIdx, args: []const TypeIdx) TypeIdx {
        switch (self.type_pool.get(base)) {
            .struct_type => |decl_node| return self.applyToDecl(expr_idx, decl_node, args),
            .enum_type => |decl_node| return self.applyToDecl(expr_idx, decl_node, args),
            else => return base,
        }
    }

    /// Apply type arguments to a generic struct or enum declaration, checking
    /// the arity (R19c: all arguments have to be supplied).
    fn applyToDecl(self: *TypeChecker, expr_idx: NodeIdx, decl_node: NodeIdx, args: []const TypeIdx) TypeIdx {
        const decl = self.arena.get(decl_node);
        switch (decl.*) {
            .struct_decl => |s| {
                const gp_count = s.generic_params.indices.len;
                if (gp_count != args.len) {
                    self.errorAt(expr_idx, "struct expects {d} generic argument(s), got {d}", .{ gp_count, args.len });
                    return self.void_ty;
                }
                return self.appliedType(decl_node, args);
            },
            .enum_decl => |e| {
                const gp_count = e.generic_params.indices.len;
                if (gp_count != args.len) {
                    self.errorAt(expr_idx, "enum expects {d} generic argument(s), got {d}", .{ gp_count, args.len });
                    return self.void_ty;
                }
                return self.appliedType(decl_node, args);
            },
            else => return self.void_ty,
        }
    }

    /// The type of a generic application `Name[Args]` (R20b): the applied
    /// struct/enum type, memoized in the application cache so that
    /// `Option[i32]` used a hundred times is one `TypeIdx`.
    fn appliedType(self: *TypeChecker, decl_node: NodeIdx, args: []const TypeIdx) TypeIdx {
        const key = self.appKey(decl_node, args);
        if (self.instantiations.get(key)) |cached| return cached;
        const owned = self.allocator.alloc(TypeIdx, args.len) catch @panic("OOM");
        @memcpy(owned, args);
        const decl = self.arena.get(decl_node);
        const sem: SemType = switch (decl.*) {
            .enum_decl => .{ .applied_enum = .{ .decl = decl_node, .args = owned } },
            else => .{ .applied_struct = .{ .decl = decl_node, .args = owned } },
        };
        const applied = self.type_pool.add(sem) catch @panic("OOM");
        self.instantiations.put(self.allocator, key, applied) catch @panic("OOM");
        return applied;
    }

    /// The cache key of a type application: the declaration plus the
    /// structural hash of the type arguments, so that two sites naming the
    /// same instance land on the same key (R20a).
    fn appKey(self: *const TypeChecker, decl_node: NodeIdx, args: []const TypeIdx) u64 {
        var h: u64 = 0xcbf29ce484222325;
        h = (h ^ @as(u64, @intFromEnum(decl_node))) *% 0x100000001b3;
        for (args) |arg| {
            h = (h ^ generics_mod.typeHash(self.type_pool, arg)) *% 0x100000001b3;
        }
        return h;
    }

    /// A one-argument application of a generic type name: `Option[i32]`.
    ///
    /// The parser gives a one-argument application the same shape as an
    /// index, so this returns null when the base is not a generic type name
    /// and an ordinary index keeps its meaning.
    fn tryTypeApplication(self: *TypeChecker, expr_idx: NodeIdx, base: NodeIdx, arg: NodeIdx) ?TypeIdx {
        const base_node = self.arena.get(base);
        if (base_node.* != .identifier) return null;
        const name = self.nameSlice(base_node.identifier);
        const sym = self.scopes.lookup(name, self.scopes.currentScope()) orelse return null;
        switch (sym.kind) {
            .struct_type, .enum_type => {},
            else => return null,
        }
        const decl = self.arena.get(sym.decl_node);
        const gp_count = switch (decl.*) {
            .struct_decl => |s| s.generic_params.indices.len,
            .enum_decl => |e| e.generic_params.indices.len,
            else => return null,
        };
        if (gp_count != 1) return null;

        const args = self.allocator.alloc(TypeIdx, 1) catch @panic("OOM");
        defer self.allocator.free(args);
        args[0] = self.inferExprType(arg);
        return self.applyToDecl(expr_idx, sym.decl_node, args);
    }

    fn inferExprTypeInner(self: *TypeChecker, expr_idx: NodeIdx, expr: *const Node) TypeIdx {
        switch (expr.*) {
            .int_literal => return self.i32_ty,
            .float_literal => return self.f64_ty,
            .string_literal => return self.string_ty,
            .char_literal => return self.i32_ty,
            .bool_literal => return self.bool_ty,
            .null_literal => return self.void_ty,
            .identifier => |id| {
                const name = self.nameSlice(id);
                if (self.builtinTypeName(name)) |ty| return ty;
                if (ast.findEnumVariant(self.arena, self.source, self.module_node, name)) |vi| {
                    return self.resolveDeclType(vi.enum_decl);
                }
                if (self.scopes.lookup(name, self.scopes.currentScope())) |sym| {
                    // A read of a closure parameter whose type is still being
                    // inferred joins that parameter's unification set (R11b).
                    if (sym.kind == .param) {
                        if (self.pending.get(sym.decl_node)) |p| {
                            return p.resolved orelse p.placeholder;
                        }
                    }
                    if (sym.type_idx != TypeIdx.none) {
                        return sym.type_idx;
                    }
                    return self.resolveDeclType(sym.decl_node);
                }
                return self.void_ty;
            },
            .binary_op => |b| {
                // Propagate an unresolved closure-parameter placeholder between
                // the operands before comparing them (R11b, "unification only").
                const left_raw = self.inferExprType(b.left);
                const right_raw = self.inferExprType(b.right);
                const unified = self.unifyOperands(left_raw, right_raw);
                const left_ty = unified.left;
                const right_ty = unified.right;

                if (b.op == .assign or b.op == .add_assign or b.op == .sub_assign or
                    b.op == .mul_assign or b.op == .div_assign)
                {
                    if (!self.typesEqual(left_ty, right_ty)) {
                        self.errorAt(expr_idx, "assignment type mismatch: '{s}' and '{s}'", .{
                            self.typeName(left_ty), self.typeName(right_ty),
                        });
                    }
                    return left_ty;
                }

                if (b.op == .eq or b.op == .ne or b.op == .lt or b.op == .gt or
                    b.op == .le or b.op == .ge)
                {
                    if (!self.typesEqual(left_ty, right_ty)) {
                        self.errorAt(expr_idx, "comparison of incompatible types: '{s}' and '{s}'", .{
                            self.typeName(left_ty), self.typeName(right_ty),
                        });
                    }
                    return self.bool_ty;
                }

                if (b.op == .and_op or b.op == .or_op) {
                    if (!self.typesEqual(left_ty, self.bool_ty)) {
                        self.errorAt(expr_idx, "logical op requires bool operands", .{});
                    }
                    return self.bool_ty;
                }

                if (!self.typesEqual(left_ty, right_ty)) {
                    self.errorAt(expr_idx, "binary op type mismatch: '{s}' and '{s}'", .{
                        self.typeName(left_ty), self.typeName(right_ty),
                    });
                }

                if (b.op == .range) return self.i32_ty;
                return left_ty;
            },
            .unary_op => |u| {
                return self.inferExprType(u.operand);
            },
            .call => |c| {
                return self.inferCallType(expr_idx, c);
            },
            .field_access => |fa| {
                const obj_ty = self.inferExprType(fa.object);
                const obj_sem_type = self.type_pool.get(obj_ty);
                switch (obj_sem_type) {
                    .struct_type => |decl_node| {
                        if (self.structFieldType(decl_node, self.nameSlice(fa.field))) |ft| {
                            return ft;
                        }
                        const s = self.arena.get(decl_node).struct_decl;
                        self.errorAt(expr_idx, "struct '{s}' has no field '{s}'", .{
                            self.nameSlice(s.name), self.nameSlice(fa.field),
                        });
                        return self.void_ty;
                    },
                    .applied_struct => |a| {
                        if (self.appliedFieldType(a.decl, a.args, self.nameSlice(fa.field))) |ft| {
                            return ft;
                        }
                        const s = self.arena.get(a.decl).struct_decl;
                        self.errorAt(expr_idx, "struct '{s}' has no field '{s}'", .{
                            self.nameSlice(s.name), self.nameSlice(fa.field),
                        });
                        return self.void_ty;
                    },
                    .pointer => |elem| {
                        const elem_type = self.type_pool.get(elem);
                        switch (elem_type) {
                            .struct_type => |decl_node| {
                                if (self.structFieldType(decl_node, self.nameSlice(fa.field))) |ft| {
                                    return ft;
                                }
                                self.errorAt(expr_idx, "struct has no field '{s}'", .{self.nameSlice(fa.field)});
                                return self.void_ty;
                            },
                            .applied_struct => |a| {
                                if (self.appliedFieldType(a.decl, a.args, self.nameSlice(fa.field))) |ft| {
                                    return ft;
                                }
                                self.errorAt(expr_idx, "struct has no field '{s}'", .{self.nameSlice(fa.field)});
                                return self.void_ty;
                            },
                            else => {},
                        }
                        self.errorAt(expr_idx, "cannot access field on non-struct type", .{});
                        return self.void_ty;
                    },
                    else => {
                        self.errorAt(expr_idx, "cannot access field on type '{s}'", .{self.typeName(obj_ty)});
                        return self.void_ty;
                    },
                }
            },
            .index_access => |ia| {
                // A one-argument application of a generic type name
                // (`Option[i32]`) is not an index: it denotes the type
                // itself (R19c).
                if (self.tryTypeApplication(expr_idx, ia.object, ia.index)) |ty| return ty;
                const obj_ty = self.inferExprType(ia.object);
                _ = self.inferExprType(ia.index);
                return self.inferElementType(expr_idx, obj_ty);
            },
            .generic_app => |ga| {
                return self.inferGenericApp(expr_idx, ga);
            },
            .paren_expr => |p| {
                return self.inferExprType(p);
            },
            .fn_type => |ft| {
                const params = self.allocator.alloc(TypeIdx, ft.params.indices.len) catch @panic("OOM");
                defer self.allocator.free(params);
                for (ft.params.indices, 0..) |param_ty, i| {
                    params[i] = self.inferTypeRef(param_ty);
                }
                return self.functionType(params, self.inferTypeRef(ft.return_type));
            },
            .fn_ref => |id| {
                const name = self.nameSlice(id);
                const sym = self.scopes.lookup(name, self.scopes.currentScope());
                if (sym == null or sym.?.kind != .function) {
                    self.errorAt(expr_idx, "'{s}' is not a function", .{name});
                    return self.void_ty;
                }
                return self.fnSignatureType(sym.?.decl_node);
            },
            .struct_init => |si| {
                return self.inferStructInit(expr_idx, si);
            },
            .range_expr => |r| {
                _ = self.inferExprType(r.start);
                _ = self.inferExprType(r.end);
                return self.i32_ty;
            },
            .closure => |cl| {
                return self.inferClosureType(expr_idx, cl, null);
            },
            .comptime_block => |inner| {
                const prev_comptime = self.in_comptime;
                self.in_comptime = true;
                tryStd(self.checkStmt(inner));
                self.in_comptime = prev_comptime;
                return self.void_ty;
            },
            .comptime_expr => |inner| {
                const prev_comptime = self.in_comptime;
                self.in_comptime = true;
                const inner_node = self.arena.get(inner);
                if (inner_node.* == .if_expr) {
                    // A `comptime if` picks its branch at compile time, so the
                    // branch that is not taken is never checked (R23c).
                    const ty = self.inferComptimeIf(expr_idx, inner);
                    self.in_comptime = prev_comptime;
                    return ty;
                }
                const ty = self.inferExprType(inner);
                self.in_comptime = prev_comptime;
                const value = self.evalComptime(inner);
                if (value != .none) {
                    self.comptime_values.put(self.allocator, expr_idx, .{ .value = value, .ty = ty }) catch @panic("OOM");
                }
                return ty;
            },
            .comptime_call => |cc| {
                return self.inferComptimeCall(expr_idx, cc);
            },
            .pipeline => |p| {
                return self.inferPipeline(expr_idx, p);
            },
            .try_propagate => |inner| return self.inferPropagate(expr_idx, inner),
            .move_expr => |inner| return self.inferExprType(inner),
            .region_expr => |r| {
                if (r.allocator) |alloc_ty| {
                    _ = self.inferExprType(alloc_ty);
                }
                tryStd(self.checkStmt(r.body));
                return self.void_ty;
            },
            .block => |b| {
                tryStd(self.checkStmt(expr_idx));
                if (b.stmts.indices.len > 0) {
                    const last = self.arena.get(b.stmts.indices[b.stmts.indices.len - 1]);
                    if (last.* == .expr_stmt) {
                        return self.inferExprType(last.expr_stmt.expr);
                    }
                    return self.getNodeType(b.stmts.indices[b.stmts.indices.len - 1]);
                }
                return self.void_ty;
            },
            .if_expr => |i| {
                const cond_ty = self.inferExprType(i.cond);
                if (!self.typesEqual(cond_ty, self.bool_ty)) {
                    self.errorAt(expr_idx, "if condition must be bool", .{});
                }
                const then_ty = self.inferExprType(i.then_body);
                var else_ty: TypeIdx = self.void_ty;
                if (i.else_body) |else_b| {
                    else_ty = self.inferExprType(else_b);
                }
                if (!self.typesEqual(then_ty, else_ty)) {
                    if (i.else_body != null) {
                        self.errorAt(expr_idx, "if branches have different types", .{});
                    }
                }
                return then_ty;
            },
            .match_expr => |m| {
                const scrut_ty = self.inferExprType(m.scrutinee);
                var result_ty: TypeIdx = self.void_ty;
                const scrut_sem = self.type_pool.get(scrut_ty);
                if (scrut_sem == .enum_type) {
                    const enum_node = scrut_sem.enum_type;
                    for (m.arms.indices) |arm_idx| {
                        result_ty = tryStdTy(self.checkEnumArm(arm_idx, enum_node, &.{}));
                    }
                } else if (scrut_sem == .applied_enum) {
                    const enum_node = scrut_sem.applied_enum.decl;
                    const args = scrut_sem.applied_enum.args;
                    for (m.arms.indices) |arm_idx| {
                        result_ty = tryStdTy(self.checkEnumArm(arm_idx, enum_node, args));
                    }
                } else {
                    for (m.arms.indices) |arm_idx| {
                        const arm = self.arena.get(arm_idx);
                        _ = self.inferExprType(arm.match_arm.pattern);
                        if (arm.match_arm.guard) |guard| {
                            _ = self.inferExprType(guard);
                        }
                        result_ty = self.inferExprType(arm.match_arm.body);
                    }
                }
                return result_ty;
            },
            else => return self.void_ty,
        }
    }

    fn inferTypeRef(self: *TypeChecker, expr_idx: NodeIdx) TypeIdx {
        return self.inferExprType(expr_idx);
    }

    /// The `function` type for a signature. `params` is copied into a slice
    /// owned by the type pool.
    fn functionType(self: *TypeChecker, params: []const TypeIdx, return_type: TypeIdx) TypeIdx {
        const owned = self.allocator.alloc(TypeIdx, params.len) catch @panic("OOM");
        @memcpy(owned, params);
        return self.type_pool.add(.{ .function = .{
            .param_types = owned,
            .return_type = return_type,
        } }) catch @panic("OOM");
    }

    /// The `function` type of a declared `fn`, built from its parameters and
    /// return annotation. The reference itself carries no capture environment.
    fn fnSignatureType(self: *TypeChecker, fn_idx: NodeIdx) TypeIdx {
        const f = self.arena.get(fn_idx).fn_decl;
        const params = self.allocator.alloc(TypeIdx, f.params.indices.len) catch @panic("OOM");
        defer self.allocator.free(params);
        for (f.params.indices, 0..) |param_idx, i| {
            const param = self.arena.get(param_idx);
            params[i] = self.inferTypeRef(param.param.ty);
        }
        const return_type: TypeIdx = if (f.return_type) |ret| self.inferTypeRef(ret) else self.void_ty;
        return self.functionType(params, return_type);
    }

    // ========================================================================
    // Inference and unification (R11b)
    // ========================================================================

    /// A fresh unresolved placeholder. Each call makes a distinct `TypeIdx`, so
    /// it can stand for exactly one binder in the inference maps.
    fn freshInferred(self: *TypeChecker) TypeIdx {
        return self.type_pool.add(.inferred) catch @panic("OOM");
    }

    /// Register a binder whose type is not yet known: a closure parameter node,
    /// or a closure node for its inferred return type.
    fn registerPending(self: *TypeChecker, binder: NodeIdx, name: StringRef, kind: PendingKind) TypeIdx {
        const placeholder = self.freshInferred();
        self.pending.put(self.allocator, binder, .{
            .placeholder = placeholder,
            .name = name,
            .kind = kind,
        }) catch @panic("OOM");
        self.pending_by_type.put(self.allocator, placeholder, binder) catch @panic("OOM");
        return placeholder;
    }

    /// Give a placeholder a concrete type the first time one is unified against
    /// it, and rewrite every cached node type that still names it so later reads
    /// see the concrete type (R11b, "unification only"). Resolution is
    /// first-wins: a later unify against an already-resolved binder is ignored.
    fn resolvePlaceholder(self: *TypeChecker, placeholder: TypeIdx, concrete: TypeIdx) void {
        if (!self.isInferred(placeholder) or !self.isConcrete(concrete)) return;
        if (self.pending_by_type.get(placeholder)) |binder| {
            if (self.pending.getPtr(binder)) |p| {
                if (p.resolved != null) return;
                p.resolved = concrete;
            }
        }
        for (self.node_types.items) |*nt| {
            if (nt.* == placeholder) nt.* = concrete;
        }
    }

    fn isInferred(self: *const TypeChecker, ty: TypeIdx) bool {
        return self.type_pool.get(ty) == .inferred;
    }

    /// The concrete type a binder's placeholder resolved to, or `ty` itself when
    /// it is not an unresolved placeholder. Lets a reader that still holds the
    /// placeholder compare against the fixed type.
    fn pendingResolved(self: *const TypeChecker, ty: TypeIdx) TypeIdx {
        if (!self.isInferred(ty)) return ty;
        const binder = self.pending_by_type.get(ty) orelse return ty;
        const p = self.pending.get(binder) orelse return ty;
        return p.resolved orelse ty;
    }

    /// Whether a type is known well enough to unify or thread. `.inferred` is
    /// the only not-yet-known type; every other `SemType` is concrete.
    fn isConcrete(self: *const TypeChecker, ty: TypeIdx) bool {
        return !self.isInferred(ty);
    }

    /// Propagate an unresolved placeholder between two operands: if one side is
    /// pending and the other concrete, the placeholder adopts the concrete type
    /// (R11b, "unification only"). A pair of unresolved placeholders stays
    /// unresolved, which is what makes an untypable closure body an error.
    fn unifyOperands(self: *TypeChecker, left_ty: TypeIdx, right_ty: TypeIdx) UnifiedPair {
        if (self.isInferred(left_ty) and self.isConcrete(right_ty)) {
            self.resolvePlaceholder(left_ty, right_ty);
            return .{ .left = right_ty, .right = right_ty };
        }
        if (self.isInferred(right_ty) and self.isConcrete(left_ty)) {
            self.resolvePlaceholder(right_ty, left_ty);
            return .{ .left = left_ty, .right = left_ty };
        }
        return .{ .left = left_ty, .right = right_ty };
    }

    /// Infer `expr_idx` with an expected type, threading it into closure params
    /// (R11a). For anything but a closure this is a plain inference plus, when
    /// the expression is an unresolved placeholder, adopting the expected type.
    fn inferExprTypeExpected(self: *TypeChecker, expr_idx: NodeIdx, expected: TypeIdx) TypeIdx {
        const prev = self.getNodeType(expr_idx);
        if (prev != self.void_ty) return prev;

        const expr = self.arena.get(expr_idx);
        if (expr.* == .closure) {
            const ty = self.inferClosureType(expr_idx, expr.closure, expected);
            self.setNodeType(expr_idx, ty);
            return ty;
        }
        const ty = self.inferExprType(expr_idx);
        if (self.isInferred(ty) and self.isConcrete(expected)) {
            self.resolvePlaceholder(ty, expected);
            return expected;
        }
        // An expected instance refines the bare declaration: a variant
        // constructor has the declaration's type, but in a context that
        // expects `Option[i32]` the value is that instance.
        if (self.refines(expected, ty)) return expected;
        return ty;
    }

    /// Whether `expected` is an instance of the generic declaration that `ty`
    /// names.
    fn refines(self: *const TypeChecker, expected: TypeIdx, ty: TypeIdx) bool {
        const e = self.type_pool.get(expected);
        const t = self.type_pool.get(ty);
        return switch (e) {
            .applied_enum => |a| switch (t) {
                .enum_type => |d| d == a.decl,
                else => false,
            },
            .applied_struct => |a| switch (t) {
                .struct_type => |d| d == a.decl,
                else => false,
            },
            else => false,
        };
    }

    /// Type a struct literal and check each provided field against its declared
    /// type. Generic struct fields (generic params not yet substituted) are left
    /// unchecked (R25).
    fn inferStructInit(self: *TypeChecker, expr_idx: NodeIdx, si: anytype) TypeIdx {
        const ty = self.inferExprType(si.ty);
        const sem = self.type_pool.get(ty);
        if (sem == .applied_struct) {
            const decl_node = sem.applied_struct.decl;
            const args = sem.applied_struct.args;
            // The instance's field types, with the type arguments substituted
            // in (R25).
            for (si.fields.indices) |field_idx| {
                const f = self.arena.get(field_idx).struct_init_field;
                if (self.appliedFieldType(decl_node, args, self.nameSlice(f.name))) |et| {
                    const got = self.inferExprTypeExpected(f.value, et);
                    if (!self.typesEqual(et, got)) {
                        self.errorAt(expr_idx, "field '{s}' expects '{s}' but got '{s}'", .{
                            self.nameSlice(f.name), self.typeName(et), self.typeName(got),
                        });
                    }
                } else {
                    _ = self.inferExprType(f.value);
                }
            }
            return ty;
        }
        if (sem != .struct_type) {
            for (si.fields.indices) |field_idx| {
                _ = self.inferExprType(self.arena.get(field_idx).struct_init_field.value);
            }
            return ty;
        }
        const decl_node = sem.struct_type;
        const gparams = self.arena.get(decl_node).struct_decl.generic_params;
        const is_generic = gparams.indices.len > 0;
        // The field types as templates: a field typed by one of the struct's
        // generic parameters stays a placeholder until the instance's type
        // arguments are known.
        const templates = self.allocator.alloc(TypeIdx, si.fields.indices.len) catch @panic("OOM");
        defer self.allocator.free(templates);
        for (si.fields.indices, 0..) |field_idx, i| {
            const f = self.arena.get(field_idx).struct_init_field;
            templates[i] = self.structFieldType(decl_node, self.nameSlice(f.name)) orelse self.void_ty;
        }
        for (si.fields.indices) |field_idx| {
            const f = self.arena.get(field_idx).struct_init_field;
            const field_name = self.nameSlice(f.name);
            const expected = self.structFieldType(decl_node, field_name);
            if (expected) |et| {
                if (!is_generic and et != self.void_ty) {
                    const got = self.inferExprTypeExpected(f.value, et);
                    if (!self.typesEqual(et, got)) {
                        self.errorAt(expr_idx, "field '{s}' expects '{s}' but got '{s}'", .{
                            field_name, self.typeName(et), self.typeName(got),
                        });
                    }
                } else {
                    _ = self.inferExprType(f.value);
                }
            } else {
                _ = self.inferExprType(f.value);
                self.errorAt(expr_idx, "struct has no field '{s}'", .{field_name});
            }
        }
        // A generic struct's type arguments are recoverable from the field
        // values, so the initializer may leave them out (R25).
        if (is_generic) {
            const values = self.allocator.alloc(TypeIdx, si.fields.indices.len) catch @panic("OOM");
            defer self.allocator.free(values);
            for (si.fields.indices, 0..) |field_idx, i| {
                values[i] = self.inferExprType(self.arena.get(field_idx).struct_init_field.value);
            }
            if (self.inferTypeArgs(expr_idx, decl_node, gparams, templates, values)) |type_args| {
                defer self.allocator.free(type_args);
                return self.appliedType(decl_node, type_args);
            }
        }
        return ty;
    }

    /// Type a closure literal: infer its captured set (R7), its parameter types
    /// (R11b), and its return type (R11c). `expected`, when present, is the
    /// context's `function` type and fixes unannotated params and the return
    /// (R11a).
    fn inferClosureType(self: *TypeChecker, expr_idx: NodeIdx, cl: anytype, expected: ?TypeIdx) TypeIdx {
        var expected_params: []const TypeIdx = &.{};
        var expected_ret: ?TypeIdx = null;
        if (expected) |e| {
            if (self.type_pool.get(e) == .function) {
                const ef = self.type_pool.get(e).function;
                expected_params = ef.param_types;
                if (ef.return_type != self.void_ty) expected_ret = ef.return_type;
            }
        }
        if (expected_params.len != 0 and expected_params.len != cl.params.indices.len) {
            self.errorAt(expr_idx, "closure has {d} parameter(s) but is expected to have {d}", .{
                cl.params.indices.len, expected_params.len,
            });
        }

        // Capture set, in source order of first appearance (R7b). Collected
        // before the closure's own params are scoped so a free name resolves to
        // its enclosing binding, not to the closure parameter of the same name.
        const env = self.collectCaptures(cl);

        const param_types = self.allocator.alloc(TypeIdx, cl.params.indices.len) catch @panic("OOM");
        defer self.allocator.free(param_types);
        for (cl.params.indices, 0..) |param_idx, i| {
            const pnode = self.arena.get(param_idx).param;
            const ty: TypeIdx = if (pnode.ty != NodeIdx.none)
                self.inferTypeRef(pnode.ty)
            else if (i < expected_params.len and expected_params[i] != self.void_ty)
                expected_params[i]
            else
                self.registerPending(param_idx, pnode.name, .param);
            param_types[i] = ty;
            self.setNodeType(param_idx, ty);
        }

        var ret_ty: TypeIdx = self.void_ty;
        var ret_placeholder: ?TypeIdx = null;
        if (expected_ret) |r| {
            ret_ty = r;
        } else {
            const ph = self.registerPending(expr_idx, .{ .start = 0, .end = 0 }, .closure_ret);
            ret_placeholder = ph;
            ret_ty = ph;
        }

        const prev_ret = self.fn_ret_type;
        const prev_in_fn = self.in_function;
        self.fn_ret_type = ret_ty;
        self.in_function = true;

        _ = self.scopes.pushScope(self.scopes.currentScope()) catch @panic("OOM");
        for (cl.params.indices, 0..) |param_idx, i| {
            const pname = self.arena.get(param_idx).param.name;
            self.scopes.insert(self.nameSlice(pname), .{
                .name = pname,
                .kind = .param,
                .decl_node = param_idx,
                .type_idx = param_types[i],
            }) catch @panic("OOM");
        }

        const body_is_block = self.arena.get(cl.body).* == .block;
        const body_ty = self.inferExprType(cl.body);

        self.scopes.popScope();
        self.fn_ret_type = prev_ret;
        self.in_function = prev_in_fn;

        if (ret_placeholder) |ph| {
            // An expression body's type is the closure's return type; a block
            // body's explicit `return`s already fixed it, and a body with no
            // return is `void`. Resolution is first-wins, so a fixed return is
            // never overwritten — which is what lets `?` fix the return type to
            // the propagated enum (R29a) even though the whole `?` expression
            // has the success payload's type.
            if (self.isConcrete(body_ty)) self.resolvePlaceholder(ph, body_ty);
            ret_ty = if (self.pending.get(expr_idx)) |p| (p.resolved orelse ph) else body_ty;
            if (!body_is_block and self.isConcrete(body_ty) and !self.typesEqual(ret_ty, body_ty)) {
                self.errorAt(expr_idx, "closure body has type '{s}' but is expected to return '{s}'", .{
                    self.typeName(body_ty), self.typeName(ret_ty),
                });
            }
        } else if (!body_is_block and !self.typesEqual(ret_ty, body_ty) and
            !self.tailPropagatesTo(ret_ty, cl.body))
        {
            // The return type here was fixed before the body was typed (a
            // `let` annotation or a contextual fn type). A tail `?` on that
            // very enum is exempt from the body/return equality: its error
            // path already returns the enum and its success payload is the
            // implicit return value, re-wrapped into the enum when lowered
            // (R27a/R28) — the closure does not drop the propagated enum.
            self.errorAt(expr_idx, "closure body has type '{s}' but is expected to return '{s}'", .{
                self.typeName(body_ty), self.typeName(ret_ty),
            });
        }

        // A parameter with no annotation and no expected type is only okay if
        // the body fixed it (R11b).
        for (cl.params.indices, 0..) |param_idx, i| {
            if (self.pending.get(param_idx)) |p| {
                if (p.resolved) |r| {
                    param_types[i] = r;
                } else {
                    self.errorAt(param_idx, "cannot infer parameter type of closure parameter '{s}'", .{
                        self.nameSlice(p.name),
                    });
                    param_types[i] = self.void_ty;
                }
            }
        }

        self.arena.set(expr_idx, .{ .closure = .{ .params = cl.params, .body = cl.body, .env = env } });
        return self.functionType(param_types, ret_ty);
    }

    /// Whether `body` is a tail `x?` propagating the same enum declaration
    /// `ret_ty` returns. The propagate expression has the success payload's
    /// type while the closure returns the enum itself, so when the return
    /// type was already fixed before the body was typed the usual body/return
    /// equality does not apply: the error path of `?` returns the enum and
    /// the success payload is re-wrapped into it when lowered (R27a/R28).
    fn tailPropagatesTo(self: *TypeChecker, ret_ty: TypeIdx, body: NodeIdx) bool {
        const node = self.arena.get(body);
        if (node.* != .try_propagate) return false;
        const sem = self.type_pool.get(self.getNodeType(node.try_propagate));
        const enum_node = switch (sem) {
            .enum_type => |n| n,
            .applied_enum => |a| a.decl,
            else => return false,
        };
        return self.isEnumDecl(ret_ty, enum_node);
    }

    /// Walk a closure body and return the env `NodeList` of captured binding
    /// declaration nodes (R7). Module-level functions, type names, variants, and
    /// the closure's own bindings are not captured.
    fn collectCaptures(self: *TypeChecker, cl: anytype) NodeList {
        var cs = CaptureSet{};
        defer cs.deinit(self.allocator);
        cs.pushLevel(self.allocator);
        for (cl.params.indices) |param_idx| {
            cs.bind(self.allocator, self.nameSlice(self.arena.get(param_idx).param.name));
        }
        self.walkCaptures(cl.body, &cs);
        return self.arena.allocNodeList(cs.captured.items) catch @panic("OOM");
    }

    fn addCapture(self: *TypeChecker, cs: *CaptureSet, sym: scope_mod.Symbol) void {
        const gop = cs.seen.getOrPut(self.allocator, sym.decl_node) catch @panic("OOM");
        if (gop.found_existing) return;
        cs.captured.append(self.allocator, sym.decl_node) catch @panic("OOM");
    }

    fn captureIdentifier(self: *TypeChecker, node_idx: NodeIdx, cs: *CaptureSet) void {
        const name = self.nameSlice(self.arena.get(node_idx).identifier);
        if (std.mem.eql(u8, name, "_")) return;
        if (cs.isBound(name)) return;
        if (self.builtinTypeName(name) != null) return;
        if (ast.findEnumVariant(self.arena, self.source, self.module_node, name) != null) return;
        const sym = self.scopes.lookup(name, self.scopes.currentScope()) orelse return;
        switch (sym.kind) {
            // A free value binding, or a generic param captured like a value
            // (R7d). Static entities (functions, types, modules, prelude) are
            // not captured (R7c).
            .local, .param, .generic_param => self.addCapture(cs, sym),
            else => {},
        }
    }

    fn walkMatchArm(self: *TypeChecker, arm_idx: NodeIdx, cs: *CaptureSet) void {
        const arm = self.arena.get(arm_idx).match_arm;
        cs.pushLevel(self.allocator);
        const pattern = self.arena.get(arm.pattern);
        if (pattern.* == .call) {
            // Payload identifiers are bindings for the arm body; the callee is a
            // variant name and is never captured.
            for (pattern.call.args.indices) |arg_idx| {
                const arg = self.arena.get(arg_idx);
                if (arg.* == .identifier) {
                    cs.bind(self.allocator, self.nameSlice(arg.identifier));
                } else {
                    self.walkCaptures(arg_idx, cs);
                }
            }
        } else {
            self.walkCaptures(arm.pattern, cs);
        }
        if (arm.guard) |g| self.walkCaptures(g, cs);
        self.walkCaptures(arm.body, cs);
        cs.popLevel(self.allocator);
    }

    fn walkCaptures(self: *TypeChecker, node_idx: NodeIdx, cs: *CaptureSet) void {
        const node = self.arena.get(node_idx);
        switch (node.*) {
            .identifier => self.captureIdentifier(node_idx, cs),
            .binary_op => |b| {
                self.walkCaptures(b.left, cs);
                self.walkCaptures(b.right, cs);
            },
            .unary_op => |u| self.walkCaptures(u.operand, cs),
            .call => |c| {
                self.walkCaptures(c.func, cs);
                for (c.args.indices) |a| self.walkCaptures(a, cs);
            },
            .field_access => |fa| self.walkCaptures(fa.object, cs),
            .index_access => |ia| {
                self.walkCaptures(ia.object, cs);
                self.walkCaptures(ia.index, cs);
            },
            .generic_app => |ga| {
                self.walkCaptures(ga.base, cs);
                for (ga.args.indices) |a| self.walkCaptures(a, cs);
            },
            .paren_expr => |p| self.walkCaptures(p, cs),
            .struct_init => |si| {
                self.walkCaptures(si.ty, cs);
                for (si.fields.indices) |f| {
                    self.walkCaptures(self.arena.get(f).struct_init_field.value, cs);
                }
            },
            .range_expr => |r| {
                self.walkCaptures(r.start, cs);
                self.walkCaptures(r.end, cs);
            },
            .fn_type => |ft| {
                for (ft.params.indices) |p| self.walkCaptures(p, cs);
                self.walkCaptures(ft.return_type, cs);
            },
            .closure => |cl| {
                cs.pushLevel(self.allocator);
                for (cl.params.indices) |param_idx| {
                    cs.bind(self.allocator, self.nameSlice(self.arena.get(param_idx).param.name));
                }
                self.walkCaptures(cl.body, cs);
                cs.popLevel(self.allocator);
            },
            .comptime_block, .comptime_expr => |inner| self.walkCaptures(inner, cs),
            .comptime_call => |cc| {
                for (cc.args.indices) |a| self.walkCaptures(a, cs);
            },
            .pipeline => |p| {
                self.walkCaptures(p.lhs, cs);
                self.walkCaptures(p.rhs, cs);
            },
            .try_propagate, .move_expr => |inner| self.walkCaptures(inner, cs),
            .region_expr => |r| {
                if (r.allocator) |a| self.walkCaptures(a, cs);
                self.walkCaptures(r.body, cs);
            },
            .block => |b| {
                cs.pushLevel(self.allocator);
                for (b.stmts.indices) |s| self.walkCaptures(s, cs);
                cs.popLevel(self.allocator);
            },
            .if_expr => |i| {
                self.walkCaptures(i.cond, cs);
                self.walkCaptures(i.then_body, cs);
                if (i.else_body) |e| self.walkCaptures(e, cs);
            },
            .while_expr => |w| {
                self.walkCaptures(w.cond, cs);
                self.walkCaptures(w.body, cs);
            },
            .for_range => |fr| {
                self.walkCaptures(fr.start, cs);
                self.walkCaptures(fr.end, cs);
                cs.pushLevel(self.allocator);
                cs.bind(self.allocator, self.nameSlice(fr.var_name));
                self.walkCaptures(fr.body, cs);
                cs.popLevel(self.allocator);
            },
            .for_each => |fe| {
                self.walkCaptures(fe.iterable, cs);
                cs.pushLevel(self.allocator);
                cs.bind(self.allocator, self.nameSlice(fe.var_name));
                self.walkCaptures(fe.body, cs);
                cs.popLevel(self.allocator);
            },
            .match_expr => |m| {
                self.walkCaptures(m.scrutinee, cs);
                for (m.arms.indices) |arm_idx| self.walkMatchArm(arm_idx, cs);
            },
            .let_stmt => |l| {
                if (l.ty) |t| self.walkCaptures(t, cs);
                if (l.init_expr) |e| self.walkCaptures(e, cs);
                cs.bind(self.allocator, self.nameSlice(l.name));
            },
            .return_stmt => |r| {
                if (r.value) |v| self.walkCaptures(v, cs);
            },
            .expr_stmt => |e| self.walkCaptures(e.expr, cs),
            .defer_stmt => |d| self.walkCaptures(d.expr, cs),
            else => {},
        }
    }

    // ========================================================================
    // Calls
    // ========================================================================

    /// Type of a call expression: a direct call to a named `fn`, a prelude call,
    /// an enum variant constructor (`Some(x)`), or a call through a fn value
    /// (`f(x)` where `f` holds a `fn(...)`). There is no method dispatch —
    /// `recv.f(...)` is a field read typed by `inferExprType`, then a fn-value
    /// call.
    fn inferCallType(self: *TypeChecker, expr_idx: NodeIdx, c: anytype) TypeIdx {
        const callee = self.arena.get(c.func);
        if (callee.* == .identifier) {
            const name = self.nameSlice(callee.identifier);
            if (ast.findEnumVariant(self.arena, self.source, self.module_node, name)) |vi| {
                return self.checkEnumVariantCall(expr_idx, vi, c.args);
            }
            if (self.scopes.lookup(name, self.scopes.currentScope())) |sym| {
                switch (sym.kind) {
                    .prelude_fn => return self.checkPreludeCall(expr_idx, sym, c.args, null, null),
                    .function => {
                        if (self.isGenericDecl(sym.decl_node)) {
                            return self.checkGenericCall(expr_idx, sym.decl_node, c.func, c.args, null, null);
                        }
                        return self.checkDirectCall(expr_idx, sym, c.args);
                    },
                    else => return self.checkFnValueCall(expr_idx, c),
                }
            }
            // An undefined callee: the resolver already reported it, so type
            // the arguments and produce no value rather than a second error.
            for (c.args.indices) |arg| _ = self.inferExprType(arg);
            return self.void_ty;
        }
        // A generic application in callee position: `first[i32](...)`.
        if (self.genericCalleeDecl(c.func)) |decl_idx| {
            return self.checkGenericCall(expr_idx, decl_idx, c.func, c.args, null, null);
        }
        return self.checkFnValueCall(expr_idx, c);
    }

    /// Type a call to a declared `fn` by name (R14a, no env at the call site).
    fn checkDirectCall(self: *TypeChecker, node_idx: NodeIdx, sym: scope_mod.Symbol, args: NodeList) TypeIdx {
        const sig = self.fnSignatureType(sym.decl_node);
        const f = self.type_pool.get(sig).function;
        self.checkArgList(node_idx, f.param_types, args, null, null);
        return f.return_type;
    }

    /// Type a call through a fn value (`f(x)` where `f` is a local, a field, or
    /// any expression of `function` type). This is the call-through-ptr form
    /// (R14b): the callee's visible signature drives arity and argument typing.
    fn checkFnValueCall(self: *TypeChecker, expr_idx: NodeIdx, c: anytype) TypeIdx {
        const callee_ty = self.inferExprType(c.func);
        const sem = self.type_pool.get(callee_ty);
        if (sem == .function) {
            self.checkArgList(expr_idx, sem.function.param_types, c.args, null, null);
            return sem.function.return_type;
        }
        if (sem == .applied_fn) {
            const sig = self.type_pool.get(sem.applied_fn.sig).function;
            self.checkArgList(expr_idx, sig.param_types, c.args, null, null);
            return sig.return_type;
        }
        for (c.args.indices) |arg| _ = self.inferExprType(arg);
        self.errorAt(expr_idx, "cannot call a value of type '{s}'", .{self.typeName(callee_ty)});
        return self.void_ty;
    }

    /// Check an argument list against a parameter-type list, optionally with a
    /// piped value replacing a `_` hole (R30a) or prepended as argument 0
    /// (R30b). Each argument is inferred with its expected type so a closure
    /// argument infers its parameters (R11a).
    fn checkArgList(
        self: *TypeChecker,
        node_idx: NodeIdx,
        param_types: []const TypeIdx,
        args: NodeList,
        piped: ?NodeIdx,
        hole: ?usize,
    ) void {
        const effective = args.indices.len + (if (piped != null and hole == null) @as(usize, 1) else 0);
        if (param_types.len != effective) {
            self.errorAt(node_idx, "call has {d} arguments but the function takes {d}", .{
                effective, param_types.len,
            });
        }

        var pi: usize = 0;
        if (piped != null and hole == null) {
            self.checkOneArg(node_idx, param_types, pi, piped.?);
            pi += 1;
        }
        var ai: usize = 0;
        while (ai < args.indices.len) : (ai += 1) {
            if (hole) |h| {
                if (ai == h) {
                    self.checkOneArg(node_idx, param_types, pi, piped.?);
                    pi += 1;
                    continue;
                }
            }
            self.checkOneArg(node_idx, param_types, pi, args.indices[ai]);
            pi += 1;
        }
    }

    /// Check one argument against parameter `pi` (if a parameter exists),
    /// threading the expected type into a closure argument (R11a/R11b).
    fn checkOneArg(self: *TypeChecker, node_idx: NodeIdx, param_types: []const TypeIdx, pi: usize, arg: NodeIdx) void {
        if (self.isHole(arg)) {
            self.errorAt(node_idx, "'_' hole outside a pipeline", .{});
            return;
        }
        if (pi >= param_types.len) {
            _ = self.inferExprType(arg);
            return;
        }
        const et = param_types[pi];
        if (et != self.void_ty) {
            const got = self.inferExprTypeExpected(arg, et);
            if (!self.typesEqual(et, got)) {
                self.errorAt(node_idx, "argument {d} expects '{s}' but got '{s}'", .{
                    pi + 1, self.typeName(et), self.typeName(got),
                });
            }
        } else {
            _ = self.inferExprType(arg);
        }
    }

    /// Type a prelude call. An IO entry is checked against its roster
    /// signature; a composition entry is generic, so its result type is
    /// derived from the operands (R31). `piped`/`hole` carry pipeline
    /// desugaring (R30) for `x |> print(...)` and `x |> id`.
    fn checkPreludeCall(
        self: *TypeChecker,
        node_idx: NodeIdx,
        sym: scope_mod.Symbol,
        args: NodeList,
        piped: ?NodeIdx,
        hole: ?usize,
    ) TypeIdx {
        if (sym.prelude.index >= prelude.roster.len) {
            self.errorAt(node_idx, "prelude function '{s}' is not in the roster", .{
                sym.displayName(self.source),
            });
            return self.void_ty;
        }
        const entry = prelude.roster[sym.prelude.index];
        return switch (entry.kind) {
            .io => self.checkIoPreludeCall(node_idx, entry, args, piped, hole),
            .composition => self.checkCompositionCall(node_idx, entry, args, piped, hole),
        };
    }

    /// Type a prelude call against its roster signature. A prelude entry has no
    /// AST declaration, so arity and argument types are read off the roster row.
    /// `piped`/`hole` carry pipeline desugaring (R30) for `x |> print(...)`.
    fn checkIoPreludeCall(
        self: *TypeChecker,
        node_idx: NodeIdx,
        entry: prelude.PreludeFn,
        args: NodeList,
        piped: ?NodeIdx,
        hole: ?usize,
    ) TypeIdx {
        const name = entry.name;

        const effective = args.indices.len + (if (piped != null and hole == null) @as(usize, 1) else 0);
        if (entry.params.len != effective) {
            self.errorAt(node_idx, "'{s}' takes {d} argument(s), got {d}", .{
                name, entry.params.len, effective,
            });
            for (args.indices) |arg| _ = self.inferExprType(arg);
            if (piped) |p| _ = self.inferExprType(p);
            return self.typeForParam(entry.return_type);
        }

        var pi: usize = 0;
        if (piped != null and hole == null) {
            self.checkPreludeArg(node_idx, name, entry, pi, piped.?);
            pi += 1;
        }
        var ai: usize = 0;
        while (ai < args.indices.len) : (ai += 1) {
            if (hole) |h| {
                if (ai == h) {
                    self.checkPreludeArg(node_idx, name, entry, pi, piped.?);
                    pi += 1;
                    continue;
                }
            }
            self.checkPreludeArg(node_idx, name, entry, pi, args.indices[ai]);
            pi += 1;
        }

        return self.typeForParam(entry.return_type);
    }

    fn checkPreludeArg(self: *TypeChecker, node_idx: NodeIdx, name: []const u8, entry: prelude.PreludeFn, pi: usize, arg: NodeIdx) void {
        if (self.isHole(arg)) {
            self.errorAt(node_idx, "'_' hole outside a pipeline", .{});
            return;
        }
        const want = entry.params[pi];
        if (want == .void) {
            self.errorAt(node_idx, "'{s}' takes no arguments", .{name});
            return;
        }
        const want_ty = self.typeForParam(want);
        const got_ty = self.inferExprTypeExpected(arg, want_ty);
        if (!self.typesEqual(want_ty, got_ty)) {
            self.errorAt(node_idx, "'{s}' expects '{s}', got '{s}'", .{
                name, self.typeName(want_ty), self.typeName(got_ty),
            });
        }
    }

    fn typeForParam(self: *const TypeChecker, param: prelude.ParamType) TypeIdx {
        return switch (param) {
            .string => self.string_ty,
            .i64 => self.i64_ty,
            .u64 => self.u64_ty,
            .f64 => self.f64_ty,
            .void => self.void_ty,
        };
    }

    // ========================================================================
    // Composition prelude (R31)
    // ========================================================================

    /// Type a composition prelude call (R31).
    ///
    /// The five composition entries are generic: their result type is derived
    /// from the operand types rather than read off the roster, and their
    /// bodies are source expansions the lowerer materializes.
    ///
    /// | call | expansion |
    /// |---|---|
    /// | `id(x)` | `x` |
    /// | `pipe(x, f)` | `f(x)` |
    /// | `compose(f, g)(x)` | `f(g(x))` |
    /// | `curry(f)(a)(b)` | `f(a, b)` |
    /// | `uncurry(h)(a, b)` | `h(a)(b)` |
    fn checkCompositionCall(
        self: *TypeChecker,
        node_idx: NodeIdx,
        entry: prelude.PreludeFn,
        args: NodeList,
        piped: ?NodeIdx,
        hole: ?usize,
    ) TypeIdx {
        const shape = entry.shape orelse return self.void_ty;
        const name = entry.name;

        // The effective argument list: the piped value replaces the `_` hole
        // (R30a) or is prepended as argument 0 (R30b).
        const total = args.indices.len + (if (piped != null and hole == null) @as(usize, 1) else 0);
        var buf: [8]NodeIdx = undefined;
        if (total > buf.len) {
            // Every composition entry is at most 2-ary; reject before filling
            // the buffer so an oversized call cannot overflow it.
            self.errorAt(node_idx, "'{s}' takes at most 2 arguments, got {d}", .{ name, total });
            for (args.indices) |arg| _ = self.inferExprType(arg);
            if (piped) |p| _ = self.inferExprType(p);
            return self.void_ty;
        }
        var n: usize = 0;
        if (piped) |p| {
            if (hole) |h| {
                for (args.indices, 0..) |arg, i| {
                    buf[n] = if (i == h) p else arg;
                    n += 1;
                }
            } else {
                buf[n] = p;
                n += 1;
                for (args.indices) |arg| {
                    buf[n] = arg;
                    n += 1;
                }
            }
        } else {
            for (args.indices) |arg| {
                buf[n] = arg;
                n += 1;
            }
        }
        const effective = buf[0..n];

        const arity: usize = switch (shape) {
            .id => 1,
            .pipe => 2,
            .compose => 2,
            .curry => 1,
            .uncurry => 1,
        };
        if (n != arity) {
            self.errorAt(node_idx, "'{s}' takes {d} argument(s), got {d}", .{ name, arity, n });
            for (effective) |arg| _ = self.inferExprType(arg);
            return self.void_ty;
        }

        return switch (shape) {
            .id => self.inferExprType(effective[0]),
            .pipe => self.checkPipeComposition(node_idx, name, effective[0], effective[1]),
            .compose => self.checkComposeComposition(node_idx, name, effective[0], effective[1]),
            .curry => self.checkCurryComposition(node_idx, name, effective[0]),
            .uncurry => self.checkUncurryComposition(node_idx, name, effective[0]),
        };
    }

    /// `pipe(x, f)` ≡ `f(x)` (R31a): `f` takes one argument and `x` has that
    /// argument's type. The result is `f`'s return type.
    fn checkPipeComposition(self: *TypeChecker, node_idx: NodeIdx, name: []const u8, x: NodeIdx, f: NodeIdx) TypeIdx {
        const f_ty = self.inferExprType(f);
        const f_sem = self.type_pool.get(f_ty);
        if (f_sem != .function) {
            self.errorAt(node_idx, "'{s}' expects a function, got '{s}'", .{ name, self.typeName(f_ty) });
            _ = self.inferExprType(x);
            return self.void_ty;
        }
        if (f_sem.function.param_types.len != 1) {
            self.errorAt(node_idx, "'{s}' expects a function of one argument", .{name});
            _ = self.inferExprType(x);
            return self.void_ty;
        }
        const want = f_sem.function.param_types[0];
        const got = self.inferExprType(x);
        if (!self.typesEqual(want, got)) {
            self.errorAt(node_idx, "argument 1 expects '{s}' but got '{s}'", .{
                self.typeName(want), self.typeName(got),
            });
        }
        return f_sem.function.return_type;
    }

    /// `compose(f, g)` ≡ `|x| f(g(x))` (R31a): right-to-left and exactly
    /// 2-ary. `g` takes one argument and `f` takes `g`'s result. The result
    /// type is `fn(A) -> C`.
    fn checkComposeComposition(self: *TypeChecker, node_idx: NodeIdx, name: []const u8, f: NodeIdx, g: NodeIdx) TypeIdx {
        const f_ty = self.inferExprType(f);
        const f_sem = self.type_pool.get(f_ty);
        const g_ty = self.inferExprType(g);
        const g_sem = self.type_pool.get(g_ty);
        if (f_sem != .function or g_sem != .function) {
            self.errorAt(node_idx, "'{s}' expects two functions", .{name});
            return self.void_ty;
        }
        if (f_sem.function.param_types.len != 1 or g_sem.function.param_types.len != 1) {
            self.errorAt(node_idx, "'{s}' expects functions of one argument", .{name});
            return self.void_ty;
        }
        const a = g_sem.function.param_types[0];
        const b = g_sem.function.return_type;
        const c = f_sem.function.return_type;
        const want = f_sem.function.param_types[0];
        if (!self.typesEqual(want, b)) {
            self.errorAt(node_idx, "argument 1 expects '{s}' but got '{s}'", .{
                self.typeName(want), self.typeName(b),
            });
        }
        return self.functionType(&.{a}, c);
    }

    /// `curry(f)` ≡ `|a| |b| f(a, b)` (R31a): front-to-left and exactly
    /// 2-ary. `f` takes two arguments. The result type is
    /// `fn(A) -> fn(B) -> R`.
    fn checkCurryComposition(self: *TypeChecker, node_idx: NodeIdx, name: []const u8, f: NodeIdx) TypeIdx {
        const f_ty = self.inferExprType(f);
        const f_sem = self.type_pool.get(f_ty);
        if (f_sem != .function) {
            self.errorAt(node_idx, "'{s}' expects a function, got '{s}'", .{ name, self.typeName(f_ty) });
            return self.void_ty;
        }
        if (f_sem.function.param_types.len != 2) {
            self.errorAt(node_idx, "'{s}' expects a function of two arguments", .{name});
            return self.void_ty;
        }
        const a = f_sem.function.param_types[0];
        const b = f_sem.function.param_types[1];
        const r = f_sem.function.return_type;
        return self.functionType(&.{a}, self.functionType(&.{b}, r));
    }

    /// `uncurry(h)` ≡ `|a, b| h(a)(b)` (R31a): exactly 2-ary. `h` takes one
    /// argument and returns a function. The result type is `fn(A, B) -> R`.
    fn checkUncurryComposition(self: *TypeChecker, node_idx: NodeIdx, name: []const u8, h: NodeIdx) TypeIdx {
        const h_ty = self.inferExprType(h);
        const h_sem = self.type_pool.get(h_ty);
        if (h_sem != .function) {
            self.errorAt(node_idx, "'{s}' expects a function, got '{s}'", .{ name, self.typeName(h_ty) });
            return self.void_ty;
        }
        if (h_sem.function.param_types.len != 1) {
            self.errorAt(node_idx, "'{s}' expects a function of one argument", .{name});
            return self.void_ty;
        }
        const inner_ty = h_sem.function.return_type;
        const inner_sem = self.type_pool.get(inner_ty);
        if (inner_sem != .function) {
            self.errorAt(node_idx, "'{s}' expects a function returning a function, got '{s}'", .{
                name, self.typeName(inner_ty),
            });
            return self.void_ty;
        }
        const a = h_sem.function.param_types[0];
        const b = inner_sem.function.param_types[0];
        const r = inner_sem.function.return_type;
        return self.functionType(&.{ a, b }, r);
    }

    // ========================================================================
    // Pipelines
    // ========================================================================

    fn isHole(self: *TypeChecker, node_idx: NodeIdx) bool {
        const n = self.arena.get(node_idx);
        return n.* == .identifier and std.mem.eql(u8, self.nameSlice(n.identifier), "_");
    }

    /// Type `lhs |> rhs` (R30). The pipeline's type is the callee's return type;
    /// the piped value replaces the single `_` hole, or is prepended as
    /// argument 0, or is the sole argument of a bare fn value.
    fn inferPipeline(self: *TypeChecker, expr_idx: NodeIdx, p: anytype) TypeIdx {
        const rhs = self.arena.get(p.rhs);
        if (rhs.* == .call) {
            const c = rhs.call;
            var hole: ?usize = null;
            var holes: usize = 0;
            for (c.args.indices, 0..) |arg, i| {
                if (self.isHole(arg)) {
                    hole = i;
                    holes += 1;
                }
            }
            if (holes > 1) {
                self.errorAt(expr_idx, "a piped call may have at most one '_' hole", .{});
            }
            return self.checkPipedCall(expr_idx, c, p.lhs, hole);
        }
        // A prelude name in the pipeline's head is a call, not a value:
        // `x |> id` is `id(x)` (R30c). A prelude entry has no fn value to
        // take a reference to, so it stays a plain identifier.
        if (rhs.* == .identifier) {
            const name = self.nameSlice(rhs.identifier);
            if (self.scopes.lookup(name, self.scopes.currentScope())) |sym| {
                if (sym.kind == .prelude_fn) {
                    return self.checkPreludeCall(expr_idx, sym, .{ .indices = &.{} }, p.lhs, null);
                }
            }
        }
        return self.checkPipedValue(expr_idx, p.rhs, p.lhs);
    }

    fn checkPipedCall(self: *TypeChecker, node_idx: NodeIdx, c: anytype, piped: NodeIdx, hole: ?usize) TypeIdx {
        const callee = self.arena.get(c.func);
        if (callee.* == .identifier) {
            const name = self.nameSlice(callee.identifier);
            if (ast.findEnumVariant(self.arena, self.source, self.module_node, name)) |vi| {
                const variant = self.arena.get(vi.variant_node);
                const fields = variant.enum_variant.fields;
                const ptypes = self.allocator.alloc(TypeIdx, fields.indices.len) catch @panic("OOM");
                defer self.allocator.free(ptypes);
                for (fields.indices, 0..) |f, i| ptypes[i] = self.inferExprType(f);
                self.checkArgList(node_idx, ptypes, c.args, piped, hole);
                return self.type_pool.add(.{ .enum_type = vi.enum_decl }) catch self.void_ty;
            }
            if (self.scopes.lookup(name, self.scopes.currentScope())) |sym| {
                switch (sym.kind) {
                    .prelude_fn => return self.checkPreludeCall(node_idx, sym, c.args, piped, hole),
                    .function => {
                        if (self.isGenericDecl(sym.decl_node)) {
                            return self.checkGenericCall(node_idx, sym.decl_node, c.func, c.args, piped, hole);
                        }
                        const sig = self.fnSignatureType(sym.decl_node);
                        const f = self.type_pool.get(sig).function;
                        self.checkArgList(node_idx, f.param_types, c.args, piped, hole);
                        return f.return_type;
                    },
                    else => {},
                }
            }
        }

        // A generic application in callee position: `first[i32](...)`.
        if (self.genericCalleeDecl(c.func)) |decl_idx| {
            return self.checkGenericCall(node_idx, decl_idx, c.func, c.args, piped, hole);
        }

        const callee_ty = self.inferExprType(c.func);
        const sem = self.type_pool.get(callee_ty);
        if (sem == .function) {
            self.checkArgList(node_idx, sem.function.param_types, c.args, piped, hole);
            return sem.function.return_type;
        }
        if (sem == .applied_fn) {
            const sig = self.type_pool.get(sem.applied_fn.sig).function;
            self.checkArgList(node_idx, sig.param_types, c.args, piped, hole);
            return sig.return_type;
        }
        _ = self.inferExprType(piped);
        for (c.args.indices) |a| _ = self.inferExprType(a);
        self.errorAt(node_idx, "cannot pipe into a value of type '{s}'", .{self.typeName(callee_ty)});
        return self.void_ty;
    }

    /// `lhs |> rhs` where `rhs` is a bare fn value: `lhs` is its single
    /// argument (R30c).
    fn checkPipedValue(self: *TypeChecker, node_idx: NodeIdx, rhs: NodeIdx, piped: NodeIdx) TypeIdx {
        const rhs_ty = self.inferExprType(rhs);
        const sem = self.type_pool.get(rhs_ty);
        if (sem == .function) {
            const f = sem.function;
            if (f.param_types.len >= 1 and f.param_types[0] != self.void_ty) {
                const got = self.inferExprTypeExpected(piped, f.param_types[0]);
                if (!self.typesEqual(f.param_types[0], got)) {
                    self.errorAt(node_idx, "piped value expects '{s}' but got '{s}'", .{
                        self.typeName(f.param_types[0]), self.typeName(got),
                    });
                }
            } else {
                _ = self.inferExprType(piped);
            }
            return f.return_type;
        }
        if (sem == .applied_fn) {
            const f = self.type_pool.get(sem.applied_fn.sig).function;
            if (f.param_types.len >= 1 and f.param_types[0] != self.void_ty) {
                const got = self.inferExprTypeExpected(piped, f.param_types[0]);
                if (!self.typesEqual(f.param_types[0], got)) {
                    self.errorAt(node_idx, "piped value expects '{s}' but got '{s}'", .{
                        self.typeName(f.param_types[0]), self.typeName(got),
                    });
                }
            } else {
                _ = self.inferExprType(piped);
            }
            return f.return_type;
        }
        _ = self.inferExprType(piped);
        self.errorAt(node_idx, "cannot pipe into a value of type '{s}'", .{self.typeName(rhs_ty)});
        return self.void_ty;
    }

    // ========================================================================
    // Error propagation `?` (R26-R29)
    // ========================================================================

    /// The variant decomposition of an enum `?` can propagate on (R26).
    pub const PropagateShape = struct {
        /// Declaration index of the single-payload success variant.
        success_index: u32,
        /// Type of the success variant's payload: the type of `x?`.
        success_payload_ty: TypeIdx,
        /// Declaration index of the error variant.
        error_index: u32,
        /// Payload field count on the error variant (0 or 1).
        error_field_count: u32,
        /// Type of the error payload (`void` when the error variant is bare).
        error_payload_ty: TypeIdx,
    };

    /// The success/error split of an enum `?` can propagate on, or null when the
    /// enum does not have the required shape (R26): exactly two variants, one
    /// with exactly one payload field (the success variant, `Ok(T)` / `Some(T)`)
    /// and the other with 0 or 1 fields (the error variant, `Err(E)` / `None`).
    /// Declaration order breaks the tie for a `Result`-shaped enum: the first
    /// one-field variant is the success variant. There is no hard-coded
    /// `Result`/`Option`; the shape alone decides.
    pub fn propagateShape(self: *TypeChecker, enum_node: NodeIdx) ?PropagateShape {
        return self.propagateShapeFor(enum_node, &.{});
    }

    /// The same split, with an instance's type arguments substituted into the
    /// payload types (R27b): the success payload of `Result[i32, string]` is
    /// `i32`, not the declaration's `T`.
    pub fn propagateShapeFor(self: *TypeChecker, enum_node: NodeIdx, args: []const TypeIdx) ?PropagateShape {
        const decl = self.arena.get(enum_node);
        if (decl.* != .enum_decl) return null;
        const variants = decl.enum_decl.variants.indices;
        if (variants.len != 2) return null;

        var success: ?usize = null;
        var err: ?usize = null;
        for (variants, 0..) |variant_idx, i| {
            const fields = self.arena.get(variant_idx).enum_variant.fields;
            if (fields.indices.len == 1 and success == null) {
                success = i;
            } else if (fields.indices.len <= 1 and err == null) {
                err = i;
            } else {
                return null;
            }
        }
        const success_i = success orelse return null;
        const error_i = err orelse return null;

        const gparams = decl.enum_decl.generic_params;
        const success_variant = self.arena.get(variants[success_i]).enum_variant;
        const error_variant = self.arena.get(variants[error_i]).enum_variant;
        const error_count = error_variant.fields.indices.len;

        return .{
            .success_index = @intCast(success_i),
            .success_payload_ty = self.enumPayloadType(gparams, args, success_variant.fields.indices[0]),
            .error_index = @intCast(error_i),
            .error_field_count = @intCast(error_count),
            .error_payload_ty = if (error_count == 1)
                self.enumPayloadType(gparams, args, error_variant.fields.indices[0])
            else
                self.void_ty,
        };
    }

    /// The type of an enum variant's payload field: the declared field type
    /// with the instance's type arguments substituted in (R27b). A field typed
    /// by one of the declaration's generic parameters (`Ok(T)`) becomes a
    /// `generic_param` placeholder that the substitution replaces.
    fn enumPayloadType(
        self: *TypeChecker,
        gparams: NodeList,
        args: []const TypeIdx,
        field_idx: NodeIdx,
    ) TypeIdx {
        const ty = self.resolveTemplateType(gparams, field_idx);
        if (args.len == 0) return ty;
        return generics_mod.substType(self.type_pool, ty, args) catch @panic("OOM");
    }

    /// Whether `ty` is an instance of the enum declared at `enum_node`.
    fn isEnumDecl(self: *const TypeChecker, ty: TypeIdx, enum_node: NodeIdx) bool {
        return switch (self.type_pool.get(ty)) {
            .enum_type => |node| node == enum_node,
            .applied_enum => |a| a.decl == enum_node,
            else => false,
        };
    }

    /// Type `x?` (R26-R29). The operand must be a two-variant enum with a
    /// single-payload success variant and a 0-or-1-field error variant; the
    /// expression has the success payload's type. The enclosing fn/closure must
    /// return an instance of the same enum declaration (R27a) — that enum is the
    /// branch-to-return target of R28. The instance's type arguments are
    /// substituted into the payload (R27b), so `Result[i32, string]?` has the
    /// type `i32`.
    fn inferPropagate(self: *TypeChecker, expr_idx: NodeIdx, operand: NodeIdx) TypeIdx {
        if (self.in_comptime) {
            self.errorAt(expr_idx, "'?' cannot propagate at comptime", .{});
            return self.inferExprType(operand);
        }

        const operand_ty = self.inferExprType(operand);
        // A closure parameter whose type is still inferred cannot be inspected.
        // Leaving the placeholder in place lets the binder raise its own
        // "cannot infer parameter type" diagnostic instead of a cascade here.
        if (self.isInferred(operand_ty)) return operand_ty;

        const sem = self.type_pool.get(operand_ty);
        if (sem != .enum_type and sem != .applied_enum) {
            self.errorAt(expr_idx, "'?' needs a Result or Option value, got '{s}'", .{self.typeName(operand_ty)});
            return self.void_ty;
        }
        const enum_node = if (sem == .enum_type) sem.enum_type else sem.applied_enum.decl;
        const args: []const TypeIdx = if (sem == .enum_type) &.{} else sem.applied_enum.args;
        const shape = self.propagateShapeFor(enum_node, args) orelse {
            self.errorAt(expr_idx, "'?' needs a one-payload success variant and an error variant", .{});
            return self.void_ty;
        };

        // R27a: the enclosing fn/closure must return an instance of the same
        // enum declaration so its error branch can `return` that enum. R29a: in
        // a closure whose return type is still being inferred, `?` fixes it to
        // the operand's enum (first-wins, so an earlier `return` already
        // settled it).
        const enclosing = self.pendingResolved(self.fn_ret_type);
        if (self.isInferred(enclosing)) {
            self.resolvePlaceholder(self.fn_ret_type, operand_ty);
        } else if (!self.isEnumDecl(enclosing, enum_node)) {
            self.errorAt(expr_idx, "'?' requires the enclosing function to return the same Result/Option type", .{});
        }
        return shape.success_payload_ty;
    }

    // ========================================================================
    // Enums and match
    // ========================================================================

    /// Type an enum variant constructor `Some(x)` and return the enum type.
    /// Payload arguments are checked against the declared field types. A
    /// generic enum's type arguments are inferred from the payload arguments
    /// (R24), so `Some(7)` has the type `Option[i32]`; a parameter the payload
    /// does not mention stays uninferred and the constructor keeps the bare
    /// declaration's type.
    fn checkEnumVariantCall(self: *TypeChecker, node_idx: NodeIdx, vi: ast.EnumVariantInfo, args: NodeList) TypeIdx {
        const variant = self.arena.get(vi.variant_node);
        const fields = variant.enum_variant.fields;
        if (args.indices.len != fields.indices.len) {
            self.errorAt(node_idx, "variant '{s}' takes {d} arguments, got {d}", .{
                self.nameSlice(variant.enum_variant.name), fields.indices.len, args.indices.len,
            });
        }
        const gparams = self.arena.get(vi.enum_decl).enum_decl.generic_params;

        // The payload types as templates: a payload typed by one of the
        // enum's generic parameters stays a placeholder until the instance's
        // type arguments are known.
        const templates = self.allocator.alloc(TypeIdx, fields.indices.len) catch @panic("OOM");
        defer self.allocator.free(templates);
        for (fields.indices, 0..) |field_idx, i| {
            templates[i] = self.resolveTemplateType(gparams, field_idx);
        }

        for (args.indices, 0..) |arg, i| {
            if (i < fields.indices.len) {
                const field_ty = templates[i];
                // A payload that mentions a generic parameter cannot be
                // checked against an argument yet: its type is only known
                // once the instance's type arguments are.
                if (field_ty != self.void_ty and !self.mentionsGenericParam(field_ty)) {
                    const got = self.inferExprTypeExpected(arg, field_ty);
                    if (!self.typesEqual(field_ty, got)) {
                        self.errorAt(node_idx, "variant field {d} expects '{s}' but got '{s}'", .{
                            i + 1, self.typeName(field_ty), self.typeName(got),
                        });
                    }
                } else {
                    _ = self.inferExprType(arg);
                }
            } else {
                _ = self.inferExprType(arg);
            }
        }

        if (gparams.indices.len == 0) {
            return self.type_pool.add(.{ .enum_type = vi.enum_decl }) catch self.void_ty;
        }
        const values = self.allocator.alloc(TypeIdx, args.indices.len) catch @panic("OOM");
        defer self.allocator.free(values);
        for (args.indices, 0..) |arg_idx, i| {
            values[i] = self.inferExprType(arg_idx);
        }
        if (self.inferTypeArgs(node_idx, vi.enum_decl, gparams, templates, values)) |type_args| {
            defer self.allocator.free(type_args);
            return self.appliedType(vi.enum_decl, type_args);
        }
        return self.type_pool.add(.{ .enum_type = vi.enum_decl }) catch self.void_ty;
    }

    /// Infer a generic declaration's type arguments from the types of the
    /// values that mention them (R24/R25).
    ///
    /// Each template is the declared type of a field or payload with the
    /// declaration's generic parameters left as placeholders; each value type
    /// is the type of the expression that fills it. A parameter that no value
    /// mentions cannot be inferred, so the caller keeps the declaration's
    /// bare type.
    fn inferTypeArgs(
        self: *TypeChecker,
        node_idx: NodeIdx,
        decl_node: NodeIdx,
        gparams: NodeList,
        templates: []const TypeIdx,
        value_types: []const TypeIdx,
    ) ?[]TypeIdx {
        const decl = self.arena.get(decl_node);
        const decl_name = switch (decl.*) {
            .struct_decl => |s| self.nameSlice(s.name),
            .enum_decl => |e| self.nameSlice(e.name),
            else => "",
        };

        var bindings = generics_mod.Bindings.init(self.allocator, gparams.indices.len) catch @panic("OOM");
        defer bindings.deinit(self.allocator);

        for (templates, value_types) |t, v| {
            generics_mod.unifyTemplate(self.type_pool, t, v, &bindings);
        }
        if (bindings.conflict) {
            const pname = if (bindings.conflict_index < gparams.indices.len)
                self.nameSlice(self.arena.get(gparams.indices[bindings.conflict_index]).identifier)
            else
                decl_name;
            self.errorAt(node_idx, "conflicting types for generic parameter '{s}' of '{s}'", .{
                pname, decl_name,
            });
            return null;
        }

        const out = self.allocator.alloc(TypeIdx, gparams.indices.len) catch @panic("OOM");
        for (gparams.indices, 0..) |_, i| {
            const bound = bindings.bound[i] orelse {
                self.allocator.free(out);
                return null;
            };
            if (!self.isConcrete(bound)) {
                self.allocator.free(out);
                return null;
            }
            out[i] = bound;
        }
        return out;
    }

    /// Whether a type mentions a generic parameter, so that its concrete
    /// value is not known yet.
    fn mentionsGenericParam(self: *const TypeChecker, ty: TypeIdx) bool {
        return switch (self.type_pool.get(ty)) {
            .generic_param => true,
            .pointer => |elem| self.mentionsGenericParam(elem),
            .function => |f| blk: {
                for (f.param_types) |p| {
                    if (self.mentionsGenericParam(p)) break :blk true;
                }
                break :blk self.mentionsGenericParam(f.return_type);
            },
            .applied_struct => |a| blk: {
                for (a.args) |x| {
                    if (self.mentionsGenericParam(x)) break :blk true;
                }
                break :blk false;
            },
            .applied_enum => |a| blk: {
                for (a.args) |x| {
                    if (self.mentionsGenericParam(x)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn checkMatchStmt(self: *TypeChecker, stmt_idx: NodeIdx, m: anytype) anyerror!void {
        const scrut_ty = self.inferExprType(m.scrutinee);
        const scrut_sem = self.type_pool.get(scrut_ty);
        if (scrut_sem == .enum_type) {
            const enum_node = scrut_sem.enum_type;
            for (m.arms.indices) |arm_idx| {
                _ = try self.checkEnumArm(arm_idx, enum_node, &.{});
            }
        } else if (scrut_sem == .applied_enum) {
            const enum_node = scrut_sem.applied_enum.decl;
            const args = scrut_sem.applied_enum.args;
            for (m.arms.indices) |arm_idx| {
                _ = try self.checkEnumArm(arm_idx, enum_node, args);
            }
        } else {
            for (m.arms.indices) |arm_idx| {
                const arm = self.arena.get(arm_idx);
                _ = self.inferExprType(arm.match_arm.pattern);
                if (arm.match_arm.guard) |guard| {
                    _ = self.inferExprType(guard);
                }
                _ = self.inferExprType(arm.match_arm.body);
            }
        }
        self.setNodeType(stmt_idx, self.void_ty);
    }

    /// Check one enum match arm: verify the pattern names a variant of
    /// `enum_node`, bind its payload identifiers in an arm-local scope, and
    /// type the body. Returns the body's type (for expression-position
    /// matches). `args` are the scrutinee's type arguments, substituted into
    /// the payload types (R25/R27b).
    fn checkEnumArm(
        self: *TypeChecker,
        arm_idx: NodeIdx,
        enum_node: NodeIdx,
        args: []const TypeIdx,
    ) anyerror!TypeIdx {
        const arm = self.arena.get(arm_idx);
        const pattern = self.arena.get(arm.match_arm.pattern);
        // The `_` wildcard matches every variant and binds no payload.
        if (self.isWildcardPattern(pattern)) {
            _ = try self.scopes.pushScope(self.scopes.currentScope());
            defer self.scopes.popScope();
            _ = self.inferExprType(arm.match_arm.pattern);
            if (arm.match_arm.guard) |guard| {
                const guard_ty = self.inferExprType(guard);
                if (!self.typesEqual(guard_ty, self.bool_ty)) {
                    self.errorAt(arm_idx, "match guard must be bool, got '{s}'", .{self.typeName(guard_ty)});
                }
            }
            return self.inferExprType(arm.match_arm.body);
        }
        const variant = self.enumVariantFor(enum_node, pattern) orelse {
            self.errorAt(arm_idx, "match arm pattern must be a variant of this enum", .{});
            _ = self.inferExprType(arm.match_arm.pattern);
            return self.inferExprType(arm.match_arm.body);
        };

        _ = try self.scopes.pushScope(self.scopes.currentScope());
        const variant_node = self.arena.get(variant.variant_node);
        const gparams = self.arena.get(enum_node).enum_decl.generic_params;
        if (pattern.* == .call) {
            for (pattern.call.args.indices, 0..) |arg_idx, i| {
                if (i >= variant_node.enum_variant.fields.indices.len) break;
                const arg = self.arena.get(arg_idx);
                if (arg.* != .identifier) continue;
                const field_ty = self.enumPayloadType(gparams, args, variant_node.enum_variant.fields.indices[i]);
                self.scopes.insert(self.nameSlice(arg.identifier), .{
                    .name = arg.identifier,
                    .kind = .local,
                    .decl_node = arg_idx,
                    .type_idx = field_ty,
                }) catch @panic("OOM");
            }
        }
        _ = self.inferExprType(arm.match_arm.pattern);
        if (arm.match_arm.guard) |guard| {
            const guard_ty = self.inferExprType(guard);
            if (!self.typesEqual(guard_ty, self.bool_ty)) {
                self.errorAt(arm_idx, "match guard must be bool, got '{s}'", .{self.typeName(guard_ty)});
            }
        }
        const body_ty = self.inferExprType(arm.match_arm.body);
        self.scopes.popScope();
        return body_ty;
    }

    /// Whether a match pattern is the `_` wildcard.
    fn isWildcardPattern(self: *const TypeChecker, pattern: *const Node) bool {
        return pattern.* == .identifier and std.mem.eql(u8, self.nameSlice(pattern.identifier), "_");
    }

    /// Match a pattern node against the variants of `enum_node`.
    fn enumVariantFor(self: *TypeChecker, enum_node: NodeIdx, pattern: *const Node) ?ast.EnumVariantInfo {
        const name: []const u8 = switch (pattern.*) {
            .identifier => |id| self.nameSlice(id),
            .call => |c| blk: {
                const callee = self.arena.get(c.func);
                if (callee.* != .identifier) return null;
                break :blk self.nameSlice(callee.identifier);
            },
            else => return null,
        };
        const vi = ast.findEnumVariant(self.arena, self.source, self.module_node, name) orelse return null;
        if (vi.enum_decl != enum_node) return null;
        return vi;
    }

    // ========================================================================
    // Indexing and iteration
    // ========================================================================

    /// Element type produced by `obj[index]`.
    fn inferElementType(self: *TypeChecker, node_idx: NodeIdx, obj_ty: TypeIdx) TypeIdx {
        var sem = self.type_pool.get(obj_ty);
        if (sem == .pointer) sem = self.type_pool.get(sem.pointer);
        return switch (sem) {
            .string_type => self.i32_ty,
            .array => |a| a.elem,
            .slice => |e| e,
            // A type name used as a generic application (`Option[i32]`) is
            // not real indexing: the application denotes the type itself.
            // Unresolved identifiers (e.g. `Slice[T]` inside a generic fn)
            // fall back to i32.
            .struct_type, .applied_struct, .enum_type, .applied_enum, .applied_fn => obj_ty,
            .void, .inferred => self.i32_ty,
            else => blk: {
                self.errorAt(node_idx, "cannot index a value of type '{s}'", .{self.typeName(obj_ty)});
                break :blk self.void_ty;
            },
        };
    }

    /// Element type of a `for ... in` iterable, or void if not iterable.
    fn forEachElemType(self: *TypeChecker, node_idx: NodeIdx, iter_ty: TypeIdx) TypeIdx {
        var sem = self.type_pool.get(iter_ty);
        if (sem == .pointer) sem = self.type_pool.get(sem.pointer);
        return switch (sem) {
            .string_type => self.i32_ty,
            .array => |a| a.elem,
            .slice => |e| e,
            else => blk: {
                self.errorAt(node_idx, "'for ... in' requires a String, array or slice", .{});
                break :blk self.void_ty;
            },
        };
    }

    fn structFieldType(self: *TypeChecker, decl_node: NodeIdx, field_name: []const u8) ?TypeIdx {
        const s = self.arena.get(decl_node).struct_decl;
        for (s.fields.indices) |field_idx| {
            const field = self.arena.get(field_idx);
            if (std.mem.eql(u8, self.nameSlice(field.field.name), field_name)) {
                return self.declFieldType(s.generic_params, field.field.ty);
            }
        }
        return null;
    }

    /// The type of a field of an applied struct: the declared field type with
    /// the instance's type arguments substituted in (R25).
    fn appliedFieldType(
        self: *TypeChecker,
        decl_node: NodeIdx,
        args: []const TypeIdx,
        field_name: []const u8,
    ) ?TypeIdx {
        const t = self.structFieldType(decl_node, field_name) orelse return null;
        return generics_mod.substType(self.type_pool, t, args) catch @panic("OOM");
    }

    /// The semantic type of a declared field. A field typed directly by one of
    /// the declaration's generic parameters (`first: A`) becomes a
    /// `generic_param` placeholder that an application substitutes; every other
    /// type is resolved in place.
    fn declFieldType(self: *TypeChecker, generic_params: NodeList, ty: ast.TypeRepr) TypeIdx {
        switch (ty) {
            .plain => |n| {
                if (self.genericParamIndex(generic_params, n)) |i| {
                    return self.genericParamType(n, i);
                }
            },
            .reference, .mut_reference => |n| {
                if (self.genericParamIndex(generic_params, n)) |i| {
                    const inner = self.genericParamType(n, i);
                    return self.type_pool.add(.{ .pointer = inner }) catch @panic("OOM");
                }
            },
        }
        return self.inferTypeRefNode(ty);
    }

    fn inferTypeRefNode(self: *TypeChecker, ty: ast.TypeRepr) TypeIdx {
        return switch (ty) {
            .plain => |n| self.inferExprType(n),
            .reference, .mut_reference => |n| blk: {
                const pointee = self.inferExprType(n);
                break :blk self.type_pool.add(.{ .pointer = pointee }) catch @panic("OOM");
            },
        };
    }

    fn resolveDeclType(self: *TypeChecker, decl_node: NodeIdx) TypeIdx {
        const decl = self.arena.get(decl_node);
        switch (decl.*) {
            .fn_decl => {
                if (decl.fn_decl.return_type) |ret| {
                    return self.inferExprType(ret);
                }
                return self.void_ty;
            },
            .struct_decl => {
                return self.type_pool.add(.{ .struct_type = decl_node }) catch @panic("OOM");
            },
            .enum_decl => {
                return self.type_pool.add(.{ .enum_type = decl_node }) catch @panic("OOM");
            },
            .field => {
                return self.inferTypeRefNode(decl.field.ty);
            },
            .param => {
                return self.inferTypeRef(decl.param.ty);
            },
            .let_stmt => {
                if (decl.let_stmt.ty) |ty| {
                    return self.inferTypeRef(ty);
                }
                if (decl.let_stmt.init_expr) |init_val| {
                    return self.inferExprType(init_val);
                }
                return self.void_ty;
            },
            else => return self.void_ty,
        }
    }

    fn typesEqual(self: *const TypeChecker, a: TypeIdx, b: TypeIdx) bool {
        if (a == b) return true;
        const ta = self.type_pool.get(a);
        const tb = self.type_pool.get(b);
        return self.semTypesEqual(ta, tb);
    }

    fn semTypesEqual(self: *const TypeChecker, a: SemType, b: SemType) bool {
        // A generic declaration and an application of it denote the same type
        // until the application's type arguments are substituted by
        // instantiation, which does not happen at this stage.
        if (a == .applied_enum and b == .enum_type) return a.applied_enum.decl == b.enum_type;
        if (a == .enum_type and b == .applied_enum) return a.enum_type == b.applied_enum.decl;
        if (a == .applied_struct and b == .struct_type) return a.applied_struct.decl == b.struct_type;
        if (a == .struct_type and b == .applied_struct) return a.struct_type == b.applied_struct.decl;
        if (@as(std.meta.Tag(SemType), a) != @as(std.meta.Tag(SemType), b)) return false;
        switch (a) {
            .void, .bool_type, .string_type, .inferred => return true,
            .int => |ai| return ai.signed == b.int.signed and ai.bits == b.int.bits,
            .float => |af| return af == b.float,
            .pointer => |ap| return self.typesEqual(ap, b.pointer),
            .function => |af| {
                const bf = b.function;
                if (!self.typesEqual(af.return_type, bf.return_type)) return false;
                if (af.param_types.len != bf.param_types.len) return false;
                for (af.param_types, bf.param_types) |pa, pb| {
                    if (!self.typesEqual(pa, pb)) return false;
                }
                return true;
            },
            .struct_type => |an| return an == b.struct_type,
            .applied_struct => |aa| return aa.decl == b.applied_struct.decl and self.typeListsEqual(aa.args, b.applied_struct.args),
            .enum_type => |an| return an == b.enum_type,
            .applied_enum => |aa| return aa.decl == b.applied_enum.decl and self.typeListsEqual(aa.args, b.applied_enum.args),
            .applied_fn => |aa| return aa.decl == b.applied_fn.decl and self.typeListsEqual(aa.args, b.applied_fn.args) and self.typesEqual(aa.sig, b.applied_fn.sig),
            .array => |aa| {
                const ba = b.array;
                return self.typesEqual(aa.elem, ba.elem) and aa.size == ba.size;
            },
            .slice => |ae| return self.typesEqual(ae, b.slice),
            .generic_param => |ag| return ag.index == b.generic_param.index,
            .type_value => return true,
        }
    }

    fn typeListsEqual(self: *const TypeChecker, a: []const TypeIdx, b: []const TypeIdx) bool {
        if (a.len != b.len) return false;
        for (a, b) |pa, pb| {
            if (!self.typesEqual(pa, pb)) return false;
        }
        return true;
    }

    fn typeName(self: *TypeChecker, idx: TypeIdx) []const u8 {
        const t = self.type_pool.get(idx);
        return switch (t) {
            .int => |i| blk: {
                const buf = &self.type_name_buf[self.type_name_toggle];
                self.type_name_toggle ^= 1;
                break :blk std.fmt.bufPrint(buf, "{s}{d}", .{ if (i.signed) "i" else "u", i.bits }) catch "int";
            },
            .void => "void",
            .bool_type => "bool",
            .float => |f| @tagName(f),
            .pointer => "pointer",
            .function => "function",
            .string_type => "String",
            .struct_type => |decl| self.declName(decl),
            .applied_struct => |a| self.declName(a.decl),
            .enum_type => |decl| self.declName(decl),
            .applied_enum => |a| self.declName(a.decl),
            .applied_fn => "function",
            .array => "array",
            .slice => "slice",
            .generic_param => "generic",
            .type_value => "type",
            .inferred => "inferred",
        };
    }

    pub fn getNodeTypes(self: *const TypeChecker) []const TypeIdx {
        return self.node_types.items;
    }

    /// The monomorphized instances, in creation order. Codegen emits one
    /// function per instance (R21 step 4).
    pub fn instances(self: *const TypeChecker) []const *GenericInstance {
        return self.instance_list.items;
    }

    /// The instance a call site resolves to, keyed by the callee node.
    pub fn instanceForCallee(self: *const TypeChecker, callee_node: NodeIdx) ?*GenericInstance {
        return self.instance_by_callee.get(callee_node);
    }

    /// The comptime value of a node. `.none` means the expression has no
    /// compile-time value.
    pub fn getComptimeValue(self: *const TypeChecker, node_idx: NodeIdx) ComptimeValue {
        const binding = self.comptime_values.get(node_idx) orelse return .{ .none = {} };
        return binding.value;
    }

    /// The branch a `comptime if` takes: true when the then-branch is taken.
    pub fn getComptimeBranch(self: *const TypeChecker, node_idx: NodeIdx) ?bool {
        return self.comptime_branches.get(node_idx);
    }
};

fn tryStd(what: anyerror!void) void {
    what catch @panic("OOM");
}

fn tryStdTy(what: anyerror!TypeIdx) TypeIdx {
    return what catch @panic("OOM");
}

/// The number of fields of a struct declaration.
fn structFieldCount(arena: *const AstArena, decl_idx: NodeIdx) u64 {
    const decl = arena.get(decl_idx);
    return switch (decl.*) {
        .struct_decl => |s| s.fields.indices.len,
        else => 0,
    };
}

/// The number of payload slots of an enum: the widest variant decides
/// (docs/semantics.md §3.2).
fn enumPayloadSlots(arena: *const AstArena, decl_idx: NodeIdx) u64 {
    const decl = arena.get(decl_idx);
    const e = decl.enum_decl;
    var widest: u64 = 0;
    for (e.variants.indices) |variant_idx| {
        const variant = arena.get(variant_idx).enum_variant;
        widest = @max(widest, variant.fields.indices.len);
    }
    return widest;
}

/// The source spelling of a binary operator, for a diagnostic that shows a
/// comptime expression the way it was written.
fn binaryOpName(op: BinaryOp) []const u8 {
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

/// The source spelling of a unary operator, for a diagnostic that shows a
/// comptime expression the way it was written.
fn unaryOpName(op: ast.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .not => "!",
        .bit_not => "~",
        .ref => "&",
        .mut_ref => "&mut ",
    };
}

/// The comptime value of an integer operation.
fn comptimeIntOp(op: BinaryOp, l: i64, r: i64) ComptimeValue {
    return switch (op) {
        .add => ComptimeValue{ .int = l +% r },
        .sub => ComptimeValue{ .int = l -% r },
        .mul => ComptimeValue{ .int = l *% r },
        .div => if (r == 0) ComptimeValue{ .none = {} } else ComptimeValue{ .int = @divTrunc(l, r) },
        .mod => if (r == 0) ComptimeValue{ .none = {} } else ComptimeValue{ .int = @rem(l, r) },
        .eq => ComptimeValue{ .bool = l == r },
        .ne => ComptimeValue{ .bool = l != r },
        .lt => ComptimeValue{ .bool = l < r },
        .gt => ComptimeValue{ .bool = l > r },
        .le => ComptimeValue{ .bool = l <= r },
        .ge => ComptimeValue{ .bool = l >= r },
        .bit_and => ComptimeValue{ .int = l & r },
        .bit_or => ComptimeValue{ .int = l | r },
        .bit_xor => ComptimeValue{ .int = l ^ r },
        .shift_left => ComptimeValue{ .int = l << @as(u6, @truncate(@as(u64, @bitCast(r)))) },
        .shift_right => ComptimeValue{ .int = l >> @as(u6, @truncate(@as(u64, @bitCast(r)))) },
        .and_op => ComptimeValue{ .bool = l != 0 and r != 0 },
        .or_op => ComptimeValue{ .bool = l != 0 or r != 0 },
        else => ComptimeValue{ .none = {} },
    };
}

/// The comptime value of a floating-point operation.
fn comptimeFloatOp(op: BinaryOp, l: f64, r: f64) ComptimeValue {
    return switch (op) {
        .add => ComptimeValue{ .float = l + r },
        .sub => ComptimeValue{ .float = l - r },
        .mul => ComptimeValue{ .float = l * r },
        .div => ComptimeValue{ .float = l / r },
        .eq => ComptimeValue{ .bool = l == r },
        .ne => ComptimeValue{ .bool = l != r },
        .lt => ComptimeValue{ .bool = l < r },
        .gt => ComptimeValue{ .bool = l > r },
        .le => ComptimeValue{ .bool = l <= r },
        .ge => ComptimeValue{ .bool = l >= r },
        else => ComptimeValue{ .none = {} },
    };
}

const CheckRun = struct {
    arena: AstArena,
    type_pool: TypePool,
    diagnostics: diag.Diagnostics,
};

fn runCheck(allocator: Allocator, source: []const u8) !CheckRun {
    var arena = AstArena.init(allocator);
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    var parser = @import("../parser/parser.zig").Parser.init(allocator, tokens, source, &arena, &diags);
    const module_node = parser.parseModule();
    var type_pool = types_mod.TypePool.init(allocator);
    {
        var resolver = @import("resolve.zig").Resolver.init(allocator, &arena, source, &type_pool, &diags, module_node);
        defer resolver.deinit();
        try resolver.resolve();
        var checker = TypeChecker.init(allocator, &arena, source, &type_pool, &diags, &resolver.scopes, module_node);
        defer checker.deinit();
        try checker.check();
    }
    return .{ .arena = arena, .type_pool = type_pool, .diagnostics = diags };
}

fn deinitCheck(res: *CheckRun) void {
    res.arena.deinit();
    res.type_pool.deinit();
    res.diagnostics.deinit();
}

/// Whether any diagnostic message contains `needle`. Used to pin the wording of
/// the prelude's own diagnostics without depending on unrelated ones.
fn hasMessage(diagnostics: *const diag.Diagnostics, needle: []const u8) bool {
    for (diagnostics.items.items) |item| {
        if (std.mem.indexOf(u8, item.message, needle) != null) return true;
    }
    return false;
}

/// The index of the AST node holding the `print(...)` call in `source`, if any.
fn findPrintCall(arena: *const AstArena, source: []const u8) ?NodeIdx {
    for (arena.nodes.items, 0..) |node, i| {
        if (node != .call) continue;
        const callee = arena.get(node.call.func);
        if (callee.* != .identifier) continue;
        if (std.mem.eql(u8, callee.identifier.slice(source), "print")) return @enumFromInt(i);
    }
    return null;
}

test "typecheck: empty module" {
    var res = try runCheck(std.testing.allocator, "");
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: integer literal" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    return 42
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: float literal" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> f64 {
        \\    return 3.14
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: string literal" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> String {
        \\    return "hello"
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: bool literal" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> bool {
        \\    return true
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: if expression" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    if true {
        \\        return 1
        \\    } else {
        \\        return 2
        \\    }
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: while loop" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    mut s: i32 = 0
        \\    while s < 10 {
        \\        s = s + 1
        \\    }
        \\    return s
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: for range loop" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    mut s: i32 = 0
        \\    for i in 0..10 {
        \\        s = s + i
        \\    }
        \\    return s
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: match expression" {
    var res = try runCheck(std.testing.allocator,
        \\fn check(x: i32) -> i32 {
        \\    match x {
        \\        1 => 10,
        \\        2 => 20,
        \\    }
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: function call" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn main() -> i32 {
        \\    return add(1, 2)
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: let with type annotation" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let x: i32 = 42
        \\    return x
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: let with inferred type" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let z = 42
        \\    return z
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: struct field access" {
    var res = try runCheck(std.testing.allocator,
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\}
        \\fn main() -> f64 {
        \\    let v: Vec2 = Vec2{ .x = 1.0, .y = 2.0 }
        \\    return v.x
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: comparison returns bool" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> bool {
        \\    return 1 < 2
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: print resolves through the prelude" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    print("hello")
        \\    return 42
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: print takes a String and nothing else" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    print(42)
        \\    return 0
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'print' expects 'String', got 'i32'"));
}

test "typecheck: print is arity checked" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    print("a", "b")
        \\    return 0
        \\}
    );
    defer {
        res.arena.deinit();
        res.type_pool.deinit();
        res.diagnostics.deinit();
    }
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'print' takes 1 argument(s), got 2"));
}

test "typecheck: a prelude call is void" {
    const source =
        \\fn main() -> i32 {
        \\    print("hello")
        \\    return 42
        \\}
    ;
    const allocator = std.testing.allocator;
    var arena = AstArena.init(allocator);
    defer arena.deinit();
    var lex = @import("../lexer/lexer.zig").Lexer.init(allocator, source);
    defer lex.deinit();
    const tokens = try lex.tokenize();
    var diags = diag.Diagnostics.init(allocator);
    diags.owns_messages = true;
    defer diags.deinit();
    var parser = @import("../parser/parser.zig").Parser.init(allocator, tokens, source, &arena, &diags);
    const module_node = parser.parseModule();
    var type_pool = types_mod.TypePool.init(allocator);
    defer type_pool.deinit();

    var resolver = @import("resolve.zig").Resolver.init(allocator, &arena, source, &type_pool, &diags, module_node);
    defer resolver.deinit();
    try resolver.resolve();
    var checker = TypeChecker.init(allocator, &arena, source, &type_pool, &diags, &resolver.scopes, module_node);
    defer checker.deinit();
    try checker.check();

    const call = findPrintCall(&arena, source).?;
    // `print` produces no value a program can bind, so an i32 must not come
    // back from it.
    try std.testing.expect(checker.nodeType(call) == checker.voidTypeIndex());
    try std.testing.expect(!diags.hasErrors());
}

test "typecheck: generic application is accepted in type position" {
    var res = try runCheck(std.testing.allocator,
        \\struct Pair[A, B] {
        \\    first: A
        \\    second: B
        \\}
        \\struct Holder {
        \\    pair: Pair[i32, f64]
        \\}
        \\fn main() -> Pair[i32, f64] {
        \\    let p: Pair[i32, f64] = Pair[i32, f64]{ .first = 1, .second = 2.0 }
        \\    let h: Holder = Holder{ .pair = p }
        \\    return p
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

// ---------------------------------------------------------------------------
// Function values and closures (R4, R5, R7, R9, R11, R30)
// ---------------------------------------------------------------------------

/// The `n`th closure node in `arena` in arena (post-parse) order, if any. Nodes
/// are appended after their children, so a nested closure precedes the closure
/// that contains it. Node 0 is the arena's reserved sentinel and is skipped.
fn nthClosure(arena: *const AstArena, n: usize) ?NodeIdx {
    var seen: usize = 0;
    var i: usize = 1;
    while (i < arena.nodes.items.len) : (i += 1) {
        if (arena.nodes.items[i] != .closure) continue;
        if (seen == n) return @enumFromInt(i);
        seen += 1;
    }
    return null;
}

/// The name of a capture entry: the binding introduced by a `let` statement or
/// a `param`.
fn captureName(arena: *const AstArena, source: []const u8, node_idx: NodeIdx) []const u8 {
    const node = arena.get(node_idx);
    return switch (node.*) {
        .let_stmt => |l| l.name.slice(source),
        .param => |p| p.name.slice(source),
        else => "<unknown>",
    };
}

test "typecheck: fn value call through a local" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn main() -> i32 {
        \\    let f = add
        \\    return f(1, 2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: fn value passed to a fn parameter" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn apply(f: fn(i32, i32) -> i32, x: i32, y: i32) -> i32 {
        \\    return f(x, y)
        \\}
        \\fn main() -> i32 {
        \\    let f = add
        \\    return apply(f, 1, 2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: fn value stored in a struct field and called" {
    var res = try runCheck(std.testing.allocator,
        \\struct Handler {
        \\    f: fn(i32) -> i32
        \\}
        \\fn inc(x: i32) -> i32 {
        \\    return x + 1
        \\}
        \\fn main() -> i32 {
        \\    let h = Handler{ .f = inc }
        \\    return h.f(2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure with an annotated parameter" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f = |x: i32| x + 1
        \\    return f(2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure infers its parameter from the body" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f = |x| x + 1
        \\    return f(2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure infers from a let annotation" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f: fn(i32) -> i32 = |x| x + 1
        \\    return f(2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure infers from a parameter type at the call site" {
    var res = try runCheck(std.testing.allocator,
        \\fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
        \\    return f(x)
        \\}
        \\fn main() -> i32 {
        \\    return apply(|v| v + 1, 2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: block-bodied closure infers its return type" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let f = |x: i32| {
        \\        let y = x + 1
        \\        return y
        \\    }
        \\    return f(1)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: closure with no expected or inferred parameter type is an error" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() {
        \\    let f = |x| 42
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "cannot infer parameter type of closure parameter 'x'"));
}

test "typecheck: closure captures in source order with dedup" {
    const source =
        \\fn main() -> i32 {
        \\    let a = 1
        \\    let outer = |x: i32| {
        \\        let inner = |y: i32| x + y + a + a
        \\        return inner(3)
        \\    }
        \\    return outer(2)
        \\}
    ;
    var res = try runCheck(std.testing.allocator, source);
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());

    // The parser appends a closure node after its body, so the inner closure
    // comes first in arena order.
    const inner = nthClosure(&res.arena, 0).?;
    const outer = nthClosure(&res.arena, 1).?;

    const outer_env = res.arena.get(outer).closure.env;
    try std.testing.expectEqual(@as(usize, 1), outer_env.indices.len);
    try std.testing.expectEqualStrings("a", captureName(&res.arena, source, outer_env.indices[0]));

    // `x` is free for the inner closure; `a` used twice appears once.
    const inner_env = res.arena.get(inner).closure.env;
    try std.testing.expectEqual(@as(usize, 2), inner_env.indices.len);
    try std.testing.expectEqualStrings("x", captureName(&res.arena, source, inner_env.indices[0]));
    try std.testing.expectEqualStrings("a", captureName(&res.arena, source, inner_env.indices[1]));
}

test "typecheck: closure does not capture module fns or type names" {
    const source =
        \\struct S {
        \\    v: i32
        \\}
        \\fn helper(x: i32) -> i32 {
        \\    return x
        \\}
        \\fn main() -> i32 {
        \\    let f = |x: i32| {
        \\        let s = S{ .v = helper(x) }
        \\        return s.v
        \\    }
        \\    return f(1)
        \\}
    ;
    var res = try runCheck(std.testing.allocator, source);
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());

    const f = nthClosure(&res.arena, 0).?;
    try std.testing.expectEqual(@as(usize, 0), res.arena.get(f).closure.env.indices.len);
}

test "typecheck: closure captures an enclosing fn parameter" {
    const source =
        \\fn make(x: i32) -> i32 {
        \\    let f = |y: i32| x + y
        \\    return f(1)
        \\}
        \\fn main() -> i32 {
        \\    return make(2)
        \\}
    ;
    var res = try runCheck(std.testing.allocator, source);
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());

    const f = nthClosure(&res.arena, 0).?;
    const env = res.arena.get(f).closure.env;
    try std.testing.expectEqual(@as(usize, 1), env.indices.len);
    try std.testing.expectEqualStrings("x", captureName(&res.arena, source, env.indices[0]));
}

test "typecheck: pipeline with a hole and a bare fn value" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn inc(x: i32) -> i32 {
        \\    return x + 1
        \\}
        \\fn main() -> i32 {
        \\    let a = 1
        \\    let b = 2
        \\    let c = a |> add(_, b)
        \\    let d = c |> inc
        \\    let e = a |> add(b)
        \\    return d + e
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: pipeline into a closure" {
    var res = try runCheck(std.testing.allocator,
        \\fn main() -> i32 {
        \\    let x = 1
        \\    let y = x |> |v| v + 1
        \\    return y
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: a hole outside a pipeline is an error" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\fn main() -> i32 {
        \\    return add(_, 1)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'_' hole outside a pipeline"));
}

// ---------------------------------------------------------------------------
// Error propagation `?` (R26-R29)
// ---------------------------------------------------------------------------

test "typecheck: `?` on a concrete Result-shaped enum yields the success payload" {
    var res = try runCheck(std.testing.allocator,
        \\struct Config {
        \\    port: i32
        \\}
        \\enum LoadResult {
        \\    Ok(Config)
        \\    Err(i32)
        \\}
        \\fn load() -> LoadResult {
        \\    return Ok(Config{ .port = 8080 })
        \\}
        \\fn main() -> LoadResult {
        \\    let c = load()?
        \\    let p: i32 = c.port
        \\    return Ok(Config{ .port = p })
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: `?` accepts generic Result and Option in a matching fn" {
    var res = try runCheck(std.testing.allocator,
        \\enum Result[T, E] {
        \\    Ok(T)
        \\    Err(E)
        \\}
        \\enum Option[T] {
        \\    Some(T)
        \\    None
        \\}
        \\fn fetch() -> Result[i32, String] {
        \\    return Ok(1)
        \\}
        \\fn find() -> Option[i32] {
        \\    return Some(1)
        \\}
        \\fn from_result() -> Result[i32, String] {
        \\    let x = fetch()?
        \\    return Ok(x)
        \\}
        \\fn from_option() -> Option[i32] {
        \\    let y = find()?
        \\    return Some(y)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: `?` requires the enclosing fn to return the same enum" {
    var res = try runCheck(std.testing.allocator,
        \\enum Result[T, E] {
        \\    Ok(T)
        \\    Err(E)
        \\}
        \\enum Option[T] {
        \\    Some(T)
        \\    None
        \\}
        \\fn f(r: Result[i32, String]) -> Option[i32] {
        \\    let x = r?
        \\    return Some(1)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'?' requires the enclosing function to return the same Result/Option type"));
}

test "typecheck: `?` in a void fn is rejected" {
    var res = try runCheck(std.testing.allocator,
        \\enum Result[T, E] {
        \\    Ok(T)
        \\    Err(E)
        \\}
        \\fn f(r: Result[i32, String]) {
        \\    let x = r?
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "enclosing function"));
}

test "typecheck: `?` on a non-enum value is rejected" {
    var res = try runCheck(std.testing.allocator,
        \\fn f() -> i32 {
        \\    let x = 1?
        \\    return x
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'?' needs a Result or Option value, got 'i32'"));
}

test "typecheck: `?` rejects a three-variant enum" {
    var res = try runCheck(std.testing.allocator,
        \\enum Three {
        \\    A(i32)
        \\    B
        \\    C
        \\}
        \\fn f(x: Three) -> Three {
        \\    let y = x?
        \\    return x
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'?' needs a one-payload success variant and an error variant"));
}

test "typecheck: `?` rejects a two-variant enum with no payload variant" {
    var res = try runCheck(std.testing.allocator,
        \\enum Neither {
        \\    A
        \\    B
        \\}
        \\fn f(x: Neither) -> Neither {
        \\    let y = x?
        \\    return x
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "one-payload success variant"));
}

test "typecheck: `?` rejects a multi-field error variant" {
    var res = try runCheck(std.testing.allocator,
        \\enum Wide {
        \\    Ok(i32)
        \\    Err(i32, i32)
        \\}
        \\fn f(x: Wide) -> Wide {
        \\    let y = x?
        \\    return x
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "one-payload success variant"));
}

test "typecheck: `?` at comptime is rejected" {
    var res = try runCheck(std.testing.allocator,
        \\enum Result[T, E] {
        \\    Ok(T)
        \\    Err(E)
        \\}
        \\fn f(r: Result[i32, String]) -> Result[i32, String] {
        \\    comptime {
        \\        let x = r?
        \\    }
        \\    return Ok(1)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'?' cannot propagate at comptime"));
}

test "typecheck: chained `?` on a self-referential enum" {
    var res = try runCheck(std.testing.allocator,
        \\enum Nest {
        \\    Ok(Nest)
        \\    Err(i32)
        \\}
        \\fn f(n: Nest) -> Nest {
        \\    let a = n?
        \\    let b = a?
        \\    return b
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: `?` in a closure fixes its inferred return to the enum" {
    var res = try runCheck(std.testing.allocator,
        \\enum Result[T, E] {
        \\    Ok(T)
        \\    Err(E)
        \\}
        \\fn main() -> i32 {
        \\    let f = |r: Result[i32, String]| {
        \\        let x = r?
        \\        return Ok(1)
        \\    }
        \\    return 1
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: an expression-bodied closure cannot drop the propagated enum" {
    var res = try runCheck(std.testing.allocator,
        \\enum Result[T, E] {
        \\    Ok(T)
        \\    Err(E)
        \\}
        \\fn main() -> i32 {
        \\    let f = |r: Result[i32, String]| r?
        \\    return 1
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "closure body has type"));
}

test "typecheck: a tail `?` in an expression-bodied closure with a fixed return type" {
    var res = try runCheck(std.testing.allocator,
        \\enum Res {
        \\    Ok(i32)
        \\    Err(String)
        \\}
        \\fn main() -> i32 {
        \\    let f: fn(Res) -> Res = |r| r?
        \\    return 1
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: a tail `?` with an annotated parameter under a fixed return type" {
    var res = try runCheck(std.testing.allocator,
        \\enum Res {
        \\    Ok(i32)
        \\    Err(String)
        \\}
        \\fn main() -> i32 {
        \\    let f: fn(Res) -> Res = |r: Res| r?
        \\    return 1
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: a contextual closure accepts a tail `?`" {
    var res = try runCheck(std.testing.allocator,
        \\enum Res {
        \\    Ok(i32)
        \\    Err(String)
        \\}
        \\fn apply(g: fn(Res) -> Res) -> i32 {
        \\    return 1
        \\}
        \\fn main() -> i32 {
        \\    let a = apply(|r: Res| r?)
        \\    return a
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: a tail `?` against a different return enum still errors" {
    var res = try runCheck(std.testing.allocator,
        \\enum Res {
        \\    Ok(i32)
        \\    Err(String)
        \\}
        \\enum Other {
        \\    Ok(i32)
        \\    Err(String)
        \\}
        \\fn main() -> i32 {
        \\    let f: fn(Res) -> Other = |r| r?
        \\    return 1
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "closure body has type"));
}

test "typecheck: a full two-arm enum match still type-checks" {
    var res = try runCheck(std.testing.allocator,
        \\enum Load {
        \\    Ok(i32)
        \\    Err(i32)
        \\}
        \\fn f(r: Load) -> Load {
        \\    return match r {
        \\        Ok(v) => Ok(v),
        \\        Err(e) => Err(e),
        \\    }
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: `?` in a match arm body" {
    var res = try runCheck(std.testing.allocator,
        \\enum Load {
        \\    Ok(i32)
        \\    Err(i32)
        \\}
        \\fn f(r: Load, o: Load) -> Load {
        \\    return match r {
        \\        Ok(v) => Ok(v),
        \\        Err(_) => Ok(o?),
        \\    }
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: prelude id/pipe/compose types" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn inc(x: i32) -> i32 { return x + 1 }
        \\fn double(x: i32) -> i32 { return x * 2 }
        \\fn main() -> i32 {
        \\    let a: i32 = id(5)
        \\    let b: i32 = pipe(3, inc)
        \\    let c: fn(i32) -> i32 = compose(double, inc)
        \\    let d: fn(i32) -> fn(i32) -> i32 = curry(add)
        \\    let e: fn(i32, i32) -> i32 = uncurry(d)
        \\    return a + b + c(1) + e(1, 2)
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}

test "typecheck: prelude curry/uncurry arity errors" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn main() -> i32 {
        \\    let x = curry(add, 1)
        \\    return 0
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'curry' takes 1 argument(s)"));

    var res2 = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn main() -> i32 {
        \\    let x = uncurry(add, 1)
        \\    return 0
        \\}
    );
    defer deinitCheck(&res2);
    try std.testing.expect(res2.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res2.diagnostics, "'uncurry' takes 1 argument(s)"));
}

test "typecheck: prelude composition expects function of two arguments" {
    var res = try runCheck(std.testing.allocator,
        \\fn inc(x: i32) -> i32 { return x + 1 }
        \\fn main() -> i32 {
        \\    let x = curry(inc)
        \\    return 0
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'curry' expects a function of two arguments"));
}

test "typecheck: an oversized composition call is rejected without overflowing" {
    var res = try runCheck(std.testing.allocator,
        \\fn add(a: i32, b: i32) -> i32 { return a + b }
        \\fn main() -> i32 {
        \\    let x = curry(add, 1, 2, 3, 4, 5, 6, 7, 8)
        \\    return 0
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(res.diagnostics.hasErrors());
    try std.testing.expect(hasMessage(&res.diagnostics, "'curry' takes at most 2 arguments"));
}

test "typecheck: pipe with prelude identifier" {
    var res = try runCheck(std.testing.allocator,
        \\fn inc(x: i32) -> i32 { return x + 1 }
        \\fn main() -> i32 {
        \\    let x = 3 |> inc
        \\    let y = 3 |> id
        \\    return x + y
        \\}
    );
    defer deinitCheck(&res);
    try std.testing.expect(!res.diagnostics.hasErrors());
}
