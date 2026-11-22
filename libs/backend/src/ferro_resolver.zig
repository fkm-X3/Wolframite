//! Ferro symbol resolver.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ferro_types = @import("ferro_types.zig");
const Object = ferro_types.Object;
const ResolvedSymbol = ferro_types.ResolvedSymbol;
const ResolvedSymbols = ferro_types.ResolvedSymbols;
const LinkError = ferro_types.LinkError;
const Target = ferro_types.Target;

pub fn resolveSymbols(
    program: *Object,
    runtime: *Object,
    target: Target,
    gpa: Allocator,
) LinkError!ResolvedSymbols {
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
            // PE's TLS index is synthesized by the relocation/layout stage;
            // the loader initializes it before the process entry point.
            if (target == .windows_x86_64 and std.mem.eql(u8, sym.name, "_tls_index")) continue;
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

    // Allow target OS imports to remain undefined: they are resolved via the
    // platform import table (PE import directory on Windows) rather than the
    // runtime archive. On Linux there are no such imports, so any remaining
    // undefined symbol is a hard error.
    var has_unresolved: bool = false;
    for (result.undefined.items) |name| {
        if (!ferro_types.isOsImport(name, target)) {
            has_unresolved = true;
            std.debug.print("ferro: undefined symbol '{s}'\n", .{name});
        }
    }
    if (has_unresolved) {
        return error.UndefinedSymbol;
    }

    return result;
}
