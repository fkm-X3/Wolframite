const std = @import("std");
const ast = @import("../parser/ast.zig");
const StringRef = ast.StringRef;
const NodeIdx = ast.NodeIdx;

pub const TypeIdx = enum(u32) {
    none = 0,
    _,
};

pub const FloatKind = enum {
    f16,
    f32,
    f64,
};

/// The semantic type of a value or a named type. There is no `class_type` or
/// `interface_type`: polymorphism is comptime generics (R19), so a `struct` is a
/// plain aggregate (`struct_type`) and there is no vtable/interface type.
///
/// `function` is the first-class fn type `fn(A, B) -> R` (R4). Its captured set
/// is **not** part of the type — two closures with the same visible signature
/// are the same type even when they capture different bindings (R4a).
pub const SemType = union(enum) {
    void,
    bool_type,
    int: struct { signed: bool, bits: u16 },
    float: FloatKind,
    pointer: TypeIdx,
    function: struct {
        param_types: []const TypeIdx,
        return_type: TypeIdx,
    },
    string_type,
    struct_type: NodeIdx,
    enum_type: NodeIdx,
    array: struct { elem: TypeIdx, size: ?u64 },
    slice: TypeIdx,
    generic_param: struct { name: StringRef, index: u32 },
    /// An unresolved type: the placeholder for a closure parameter or closure
    /// return type that is inferred rather than annotated (R11b). Comparisons
    /// against an `inferred` operand are permissive so a not-yet-resolved
    /// closure does not produce a cascade of spurious errors.
    inferred,
};

pub const TypePool = struct {
    types: std.ArrayListUnmanaged(SemType),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypePool {
        var pool = TypePool{
            .types = .empty,
            .allocator = allocator,
        };
        pool.types.append(allocator, .void) catch unreachable;
        return pool;
    }

    pub fn deinit(self: *TypePool) void {
        for (self.types.items) |t| {
            switch (t) {
                .function => |f| {
                    self.allocator.free(f.param_types);
                },
                else => {},
            }
        }
        self.types.deinit(self.allocator);
    }

    pub fn add(self: *TypePool, sem_type: SemType) !TypeIdx {
        const idx: u32 = @intCast(self.types.items.len);
        try self.types.append(self.allocator, sem_type);
        return @enumFromInt(idx);
    }

    pub fn get(self: *const TypePool, idx: TypeIdx) SemType {
        return self.types.items[@intFromEnum(idx)];
    }

    pub fn count(self: *const TypePool) usize {
        return self.types.items.len;
    }
};

test "type pool lifecycle" {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.count());
}

test "type pool add and get" {
    var pool = TypePool.init(std.testing.allocator);
    defer pool.deinit();

    const i32_ty = try pool.add(.{ .int = .{ .signed = true, .bits = 32 } });
    const f64_ty = try pool.add(.{ .float = .f64 });
    const bool_ty = try pool.add(.bool_type);

    try std.testing.expectEqual(@as(usize, 4), pool.count());
    try std.testing.expectEqual(SemType{ .int = .{ .signed = true, .bits = 32 } }, pool.get(i32_ty));
    try std.testing.expectEqual(SemType{ .float = .f64 }, pool.get(f64_ty));
    try std.testing.expectEqual(SemType.bool_type, pool.get(bool_ty));
}
