pub const diagnostics = @import("diagnostics.zig");
pub const lexer = @import("lexer/lexer.zig");
pub const token = @import("lexer/token.zig");
pub const ast = @import("parser/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const prelude = @import("prelude.zig");
pub const types = @import("semantic/types.zig");
pub const scope = @import("semantic/scope.zig");
pub const resolve = @import("semantic/resolve.zig");
pub const generics = @import("semantic/generics.zig");
pub const typecheck = @import("semantic/typecheck.zig");
pub const codegen = @import("codegen/lower.zig");
pub const link_description = @import("link_description.zig");

test {
    _ = @import("diagnostics.zig");
    _ = @import("lexer/lexer.zig");
    _ = @import("lexer/token.zig");
    _ = @import("parser/ast.zig");
    _ = @import("parser/parser.zig");
    _ = @import("prelude.zig");
    _ = @import("semantic/types.zig");
    _ = @import("semantic/scope.zig");
    _ = @import("semantic/resolve.zig");
    _ = @import("semantic/generics.zig");
    _ = @import("semantic/typecheck.zig");
    _ = @import("codegen/lower.zig");
    _ = @import("link_description.zig");
}
