//! Ferro symbol resolver.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro_types = @import("ferro_types.zig");
const Object = ferro_types.Object;
const ResolvedSymbol = ferro_types.ResolvedSymbol;
const ResolvedSymbols = ferro_types.ResolvedSymbols;
const LinkError = ferro_types.LinkError;

pub fn resolveSymbols(
    program: *Object,
    runtime: *Object,
    _: []const u8,
    gpa: Allocator,
) LinkError !ResolvedSymbols {
    // Map of runtime-defined symbols: name → (section, value).
    var runtime_defined: std.StringHashMap(ResolvedSymbol) =
        std.StringHashMap(ResolvedSymbol).init(gpa);
    defer runtime_defined.deinit();

    for (runtime.symbols.items) |sym| {
        if (sym.section != null) {
            // First definition wins; Tungsten does not emit duplicate symbols.
            if (runtime_defined.get(sym.name) == null) {
                runtime_defined.put(sym.name, .{
                    .section = sym.section.?,
                    .value = sym.value,
                }) catch |err| switch (err) {
                    else => return LinkError.WriteFailed,
                };
            }
        }
    }

    var result = ResolvedSymbols{
        .undefined = .empty,
        .resolved = std.StringHashMap(ResolvedSymbol).init(gpa),
    };
    errdefer result.deinit(gpa);

    for (program.symbols.items) |sym| {
        // Skip the ELF STN_UNDEF null symbol (index 0, empty name).
        if (sym.name.len == 0) continue;
        if (sym.section == null) {
            if (runtime_defined.get(sym.name)) |addr| {
                result.resolved.put(sym.name, addr) catch |err| switch (err) {
                    else => return LinkError.WriteFailed,
                };
            } else {
                result.undefined.append(gpa, sym.name) catch |err| switch (err) {
                    else => return LinkError.WriteFailed,
                };
            }
        }
    }

    if (result.undefined.items.len > 0) {
        const name = result.undefined.items[0];
        std.debug.print("Ferro: undefined symbol '{s}' not found in program or runtime archive\n", .{name});
        return error.UndefinedSymbol;
    }

    return result;
}
