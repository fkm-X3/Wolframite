const std = @import("std");
const ast = @import("parser/ast.zig");

pub const Severity = enum {
    @"error",
    warning,
    note,
    info,
};

pub const Phase = enum {
    lexer,
    parser,
    semantic,
    codegen,
};

pub const Location = struct {
    line: u32,
    column: u32,
};

pub const Diagnostic = struct {
    severity: Severity,
    phase: Phase,
    message: []const u8,
    location: ?Location,
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Diagnostic),
    owns_messages: bool = false,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        if (self.owns_messages) {
            for (self.items.items) |item| {
                self.allocator.free(item.message);
            }
        }
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *Diagnostics, severity: Severity, phase: Phase, message: []const u8, location: ?Location) !void {
        try self.items.append(self.allocator, .{
            .severity = severity,
            .phase = phase,
            .message = message,
            .location = location,
        });
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.items.items) |item| {
            if (item.severity == .@"error") return true;
        }
        return false;
    }

    pub fn count(self: *const Diagnostics, severity: Severity) usize {
        var result: usize = 0;
        for (self.items.items) |item| {
            if (item.severity == severity) result += 1;
        }
        return result;
    }

    pub fn clear(self: *Diagnostics) void {
        self.items.clearRetainingCapacity();
    }

    /// Render every diagnostic in a human-readable form, including a source
    /// snippet and a caret pointing at the reported location when one is
    /// available. `writer` is any type exposing `print`/`writeAll`/`writeByte`.
    pub fn render(self: *const Diagnostics, writer: anytype, source: []const u8, path: []const u8) !void {
        for (self.items.items) |item| {
            try renderDiagnostic(writer, item, source, path);
        }
    }

    /// Aliases kept for callers/tests that prefer a different name.
    pub fn format(self: *const Diagnostics, writer: anytype, source: []const u8, path: []const u8) !void {
        try self.render(writer, source, path);
    }

    pub fn print(self: *const Diagnostics, writer: anytype, source: []const u8, path: []const u8) !void {
        try self.render(writer, source, path);
    }

    pub fn display(self: *const Diagnostics, writer: anytype, source: []const u8, path: []const u8) !void {
        try self.render(writer, source, path);
    }

    pub fn write(self: *const Diagnostics, writer: anytype, source: []const u8, path: []const u8) !void {
        try self.render(writer, source, path);
    }

    pub fn show(self: *const Diagnostics, writer: anytype, source: []const u8, path: []const u8) !void {
        try self.render(writer, source, path);
    }
};

/// Render a single diagnostic in human-readable form.
pub fn renderDiagnostic(writer: anytype, item: Diagnostic, source: []const u8, path: []const u8) !void {
    if (item.location) |loc| {
        try writer.print("{s}:{d}:{d}: {s} [{s}]: {s}\n", .{
            path, loc.line, loc.column, @tagName(item.severity), @tagName(item.phase), item.message,
        });
        const line_text = sourceLine(source, loc.line);
        try writer.writeAll("   |\n");
        try writer.print("{d:>3} | {s}\n", .{ loc.line, line_text });
        try writer.writeAll("   | ");
        // Caret column is 1-based; clamp to the line length.
        var col = loc.column;
        if (col == 0) col = 1;
        var i: u32 = 1;
        while (i < col) : (i += 1) {
            try writer.writeByte(' ');
        }
        try writer.writeByte('^');
        try writer.writeByte('\n');
    } else {
        try writer.print("{s}: {s} [{s}]: {s}\n", .{
            path, @tagName(item.severity), @tagName(item.phase), item.message,
        });
    }
}

/// Free-function alias for callers that prefer passing the diagnostics in.
pub fn renderDiagnostics(writer: anytype, diagnostics: *const Diagnostics, source: []const u8, path: []const u8) !void {
    try diagnostics.render(writer, source, path);
}

pub fn formatDiagnostics(writer: anytype, diagnostics: *const Diagnostics, source: []const u8, path: []const u8) !void {
    try diagnostics.render(writer, source, path);
}

pub fn printDiagnostics(writer: anytype, diagnostics: *const Diagnostics, source: []const u8, path: []const u8) !void {
    try diagnostics.render(writer, source, path);
}

/// Convert a byte offset in `source` into a 1-based line/column location.
pub fn locationFromOffset(source: []const u8, offset: usize) Location {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    const limit = @min(offset, source.len);
    while (i < limit) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

/// Return the text of a 1-based source line, without its trailing newline.
pub fn sourceLine(source: []const u8, line: u32) []const u8 {
    if (line == 0) return "";
    var current: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (current == line) {
            // find end of line
            var end = i;
            while (end < source.len and source[end] != '\n' and source[end] != '\r') : (end += 1) {}
            return source[i..end];
        }
        if (source[i] == '\n') {
            current += 1;
            if (current == line) start = i + 1;
        }
    }
    if (current == line) {
        // line runs to end of source
        var end = source.len;
        // strip trailing \r if any
        if (end > start and source[end - 1] == '\r') end -= 1;
        return source[start..end];
    }
    return "";
}

/// Best-effort location for an AST node, derived from any StringRef it carries.
pub fn locationFromNode(arena: *const ast.AstArena, source: []const u8, node: ast.NodeIdx) ?Location {
    if (node == .none) return null;
    const n = arena.get(node);
    switch (n.*) {
        .return_stmt => |r| {
            if (r.value) |v| return locationFromNode(arena, source, v);
            return null;
        },
        .expr_stmt => |e| return locationFromNode(arena, source, e.expr),
        .defer_stmt => |d| return locationFromNode(arena, source, d.expr),
        .deref,
        .paren_expr,
        .move_expr,
        .comptime_expr,
        .try_propagate,
        => |operand| return locationFromNode(arena, source, operand),
        .unary_op => |u| return locationFromNode(arena, source, u.operand),
        else => {},
    }
    const ref: ?ast.StringRef = switch (n.*) {
        .identifier => |r| r,
        .string_literal => |r| r,
        .char_literal => |r| r,
        .fn_ref => |r| r,
        .let_stmt => |l| l.name,
        .break_stmt, .continue_stmt => |control| control.keyword,
        .unreachable_stmt => |keyword| keyword,
        .fn_decl => |f| f.name,
        .struct_decl => |s| s.name,
        .enum_decl => |e| e.name,
        .field => |f| f.name,
        .param => |p| p.name,
        .enum_variant => |v| v.name,
        .region_expr => |r| r.name,
        .while_expr => |w| w.label,
        .for_range => |fr| fr.label orelse fr.var_name,
        .for_each => |fe| fe.label orelse fe.var_name,
        .field_access => |fa| fa.field,
        .struct_init_field => |f| f.name,
        .import_decl => |imp| blk: {
            if (imp.path.indices.len == 0) break :blk null;
            const first = arena.get(imp.path.indices[0]);
            if (first.* == .identifier) break :blk first.identifier;
            break :blk null;
        },
        else => null,
    };
    if (ref) |r| return locationFromOffset(source, r.start);
    return null;
}

test "diagnostics: add and hasErrors" {
    var diags = Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    try std.testing.expect(!diags.hasErrors());

    try diags.add(.@"error", .lexer, "unexpected character", .{ .line = 1, .column = 5 });
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), diags.count(.@"error"));

    try diags.add(.warning, .parser, "unused variable", null);
    try std.testing.expectEqual(@as(usize, 1), diags.count(.warning));
}

test "diagnostics: clear" {
    var diags = Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    try diags.add(.@"error", .lexer, "err1", null);
    try diags.add(.@"error", .parser, "err2", null);
    try std.testing.expect(diags.hasErrors());

    diags.clear();
    try std.testing.expect(!diags.hasErrors());
}
