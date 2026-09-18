const std = @import("std");
const Allocator = std.mem.Allocator;
const token_mod = @import("token.zig");
const TokenTag = token_mod.TokenTag;
const Token = token_mod.Token;

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    tokens: std.ArrayListUnmanaged(Token),
    allocator: Allocator,

    pub fn init(allocator: Allocator, source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .tokens = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit(self.allocator);
    }

    pub fn tokenize(self: *Lexer) ![]Token {
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];

            if (ch == '\n' or ch == '\r') {
                const start = self.pos;
                self.pos += 1;
                if (ch == '\r' and self.pos < self.source.len and self.source[self.pos] == '\n') {
                    self.pos += 1;
                }
                try self.tokens.append(self.allocator, .{ .tag = .newline, .start = start, .end = self.pos });
                continue;
            }

            if (ch == ' ' or ch == '\t') {
                self.pos += 1;
                continue;
            }

            if (ch == '/' and self.peek(1) == '/') {
                self.skipLineComment();
                continue;
            }

            if (ch == '/' and self.peek(1) == '*') {
                try self.skipBlockComment();
                continue;
            }

            if (std.ascii.isDigit(ch) or (ch == '.' and std.ascii.isDigit(self.peek(1)))) {
                try self.scanNumber();
                continue;
            }

            if (ch == '"' or ch == '\'') {
                try self.scanString(ch);
                continue;
            }

            if (std.ascii.isAlphabetic(ch) or ch == '_') {
                try self.scanIdentifier();
                continue;
            }

            try self.scanOperator();
        }

        try self.tokens.append(self.allocator, .{
            .tag = .eof,
            .start = self.pos,
            .end = self.pos,
        });

        return self.tokens.items;
    }

    fn peek(self: *const Lexer, offset: u32) u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return 0;
        return self.source[idx];
    }

    fn advance(self: *Lexer) u8 {
        const ch = self.source[self.pos];
        self.pos += 1;
        return ch;
    }

    fn isIdentChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_';
    }

    fn skipLineComment(self: *Lexer) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
    }

    fn skipBlockComment(self: *Lexer) !void {
        self.pos += 2;
        var depth: u32 = 1;
        while (self.pos < self.source.len and depth > 0) {
            const ch = self.source[self.pos];
            if (ch == '/' and self.peek(1) == '*') {
                depth += 1;
                self.pos += 2;
            } else if (ch == '*' and self.peek(1) == '/') {
                depth -= 1;
                self.pos += 2;
            } else {
                self.pos += 1;
            }
        }
        if (depth > 0) {
            return error.UnterminatedBlockComment;
        }
    }

    fn scanNumber(self: *Lexer) !void {
        const start = self.pos;

        if (self.source[self.pos] == '.' and self.pos > 0 and self.source[self.pos - 1] == '.') {
            try self.tokens.append(self.allocator, .{
                .tag = .dot,
                .start = start,
                .end = self.pos + 1,
            });
            self.pos += 1;
            return;
        }

        if (self.source[self.pos] == '0' and self.peek(1) == 'x') {
            self.pos += 2;
            while (self.pos < self.source.len and std.ascii.isHex(self.source[self.pos])) {
                self.pos += 1;
            }
        } else if (self.source[self.pos] == '0' and self.peek(1) == 'b') {
            self.pos += 2;
            while (self.pos < self.source.len and (self.source[self.pos] == '0' or self.source[self.pos] == '1')) {
                self.pos += 1;
            }
        } else {
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
            if (self.pos < self.source.len and self.source[self.pos] == '.' and
                !(self.pos + 1 < self.source.len and self.source[self.pos + 1] == '.'))
            {
                self.pos += 1;
                while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                    self.pos += 1;
                }
            }
            if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                    self.pos += 1;
                }
                while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                    self.pos += 1;
                }
            }
        }

        const is_float = std.mem.indexOfScalar(u8, self.source[start..self.pos], '.') != null or
            std.mem.indexOfScalar(u8, self.source[start..self.pos], 'e') != null or
            std.mem.indexOfScalar(u8, self.source[start..self.pos], 'E') != null;

        try self.tokens.append(self.allocator, .{
            .tag = if (is_float) .float_literal else .int_literal,
            .start = start,
            .end = self.pos,
        });
    }

    fn scanString(self: *Lexer, quote: u8) !void {
        const start = self.pos;
        self.pos += 1;

        var closed = false;
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == '\\') {
                self.pos += 2;
            } else if (ch == quote) {
                self.pos += 1;
                closed = true;
                break;
            } else if (ch == '\n' or ch == '\r') {
                return error.UnterminatedString;
            } else {
                self.pos += 1;
            }
        }
        if (!closed) return error.UnterminatedString;

        const tag: TokenTag = if (quote == '"') .string_literal else .char_literal;
        try self.tokens.append(self.allocator, .{
            .tag = tag,
            .start = start,
            .end = self.pos,
        });
    }

    fn scanIdentifier(self: *Lexer) !void {
        const start = self.pos;
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.pos += 1;
        }

        const ident = self.source[start..self.pos];
        const tag: TokenTag = if (ident.len == 1 and ident[0] == '_')
            .underscore
        else
            token_mod.lookupKeyword(ident) orelse .identifier;

        try self.tokens.append(self.allocator, .{
            .tag = tag,
            .start = start,
            .end = self.pos,
        });
    }

    fn scanOperator(self: *Lexer) !void {
        const ch = self.source[self.pos];
        const start = self.pos;

        const tag: TokenTag = switch (ch) {
            '+' => if (self.peek(1) == '=') blk: {
                self.pos += 1;
                break :blk .plus_eq;
            } else .plus,
            '-' => if (self.peek(1) == '>') blk: {
                self.pos += 1;
                break :blk .arrow;
            } else if (self.peek(1) == '=') blk: {
                self.pos += 1;
                break :blk .minus_eq;
            } else .minus,
            '*' => if (self.peek(1) == '=') blk: {
                self.pos += 1;
                break :blk .star_eq;
            } else .star,
            '/' => if (self.peek(1) == '=') blk: {
                self.pos += 1;
                break :blk .slash_eq;
            } else .slash,
            '%' => .percent,
            '&' => if (self.peek(1) == '&') blk: {
                self.pos += 1;
                break :blk .amp_amp;
            } else if (self.peek(1) == 'm' and self.peek(2) == 'u' and self.peek(3) == 't' and !isIdentChar(self.peek(4))) blk: {
                self.pos += 3;
                break :blk .amp_mut;
            } else .amp,
            '|' => if (self.peek(1) == '>') blk: {
                self.pos += 1;
                break :blk .pipeline;
            } else if (self.peek(1) == '|') blk: {
                self.pos += 1;
                break :blk .pipe_pipe;
            } else .pipe,
            '^' => .caret,
            '~' => .tilde,
            '?' => .question,
            '@' => .at,
            '=' => if (self.peek(1) == '=') blk: {
                self.pos += 1;
                break :blk .eq_eq;
            } else if (self.peek(1) == '>') blk: {
                self.pos += 1;
                break :blk .fat_arrow;
            } else .eq,
            '!' => if (self.peek(1) == '=') blk: {
                self.pos += 1;
                break :blk .bang_eq;
            } else .bang,
            '<' => if (self.peek(1) == '=') blk: {
                self.pos += 1;
                break :blk .lt_eq;
            } else if (self.peek(1) == '<') blk: {
                self.pos += 1;
                break :blk .lshift;
            } else .lt,
            '>' => if (self.peek(1) == '=') blk: {
                self.pos += 1;
                break :blk .gt_eq;
            } else if (self.peek(1) == '>') blk: {
                self.pos += 1;
                break :blk .rshift;
            } else .gt,
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ':' => .colon,
            ';' => .semicolon,
            ',' => .comma,
            '.' => .dot,
            '_' => .underscore,
            else => .invalid,
        };

        self.pos += 1;
        try self.tokens.append(self.allocator, .{
            .tag = tag,
            .start = start,
            .end = self.pos,
        });
    }
};

test "lexer: empty input" {
    var lexer = Lexer.init(std.testing.allocator, "");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(TokenTag.eof, tokens[0].tag);
}

test "lexer: integers" {
    var lexer = Lexer.init(std.testing.allocator, "42 0 123 0xFF 0b1010");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 6), tokens.len);
    try std.testing.expectEqual(TokenTag.int_literal, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.int_literal, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.int_literal, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.int_literal, tokens[3].tag);
    try std.testing.expectEqual(TokenTag.int_literal, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[5].tag);

    try std.testing.expectEqualStrings("42", tokens[0].lexeme(lexer.source));
    try std.testing.expectEqualStrings("0xFF", tokens[3].lexeme(lexer.source));
    try std.testing.expectEqualStrings("0b1010", tokens[4].lexeme(lexer.source));
}

test "lexer: floats" {
    var lexer = Lexer.init(std.testing.allocator, "3.14 1e10 2.5e-3");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenTag.float_literal, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.float_literal, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.float_literal, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[3].tag);

    try std.testing.expectEqualStrings("3.14", tokens[0].lexeme(lexer.source));
    try std.testing.expectEqualStrings("1e10", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqualStrings("2.5e-3", tokens[2].lexeme(lexer.source));
}

test "lexer: string literals" {
    var lexer = Lexer.init(std.testing.allocator, "\"hello\" 'c' \"line1\\nline2\"");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenTag.string_literal, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.char_literal, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.string_literal, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[3].tag);

    try std.testing.expectEqualStrings("\"hello\"", tokens[0].lexeme(lexer.source));
    try std.testing.expectEqualStrings("'c'", tokens[1].lexeme(lexer.source));
}

test "lexer: identifiers and keywords" {
    var lexer = Lexer.init(std.testing.allocator, "fn return struct");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenTag.fn_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.return_kw, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.struct_kw, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[3].tag);
}

test "lexer: new keywords comptime move region" {
    var lexer = Lexer.init(std.testing.allocator, "comptime move region");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenTag.comptime_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.move_kw, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.region_kw, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[3].tag);
}

test "lexer: class family keywords are ordinary identifiers" {
    var lexer = Lexer.init(std.testing.allocator, "class override prop this final print");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 7), tokens.len);
    try std.testing.expectEqual(TokenTag.identifier, tokens[0].tag);
    try std.testing.expectEqualStrings("class", tokens[0].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("override", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.identifier, tokens[2].tag);
    try std.testing.expectEqualStrings("prop", tokens[2].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.identifier, tokens[3].tag);
    try std.testing.expectEqualStrings("this", tokens[3].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.identifier, tokens[4].tag);
    try std.testing.expectEqualStrings("final", tokens[4].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.identifier, tokens[5].tag);
    try std.testing.expectEqualStrings("print", tokens[5].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.eof, tokens[6].tag);
}

test "lexer: mixed identifiers and keywords" {
    var lexer = Lexer.init(std.testing.allocator, "fn add(a: i32) -> i32");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenTag.fn_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("add", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.lparen, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[3].tag);
    try std.testing.expectEqualStrings("a", tokens[3].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.colon, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[5].tag);
    try std.testing.expectEqualStrings("i32", tokens[5].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.rparen, tokens[6].tag);
    try std.testing.expectEqual(TokenTag.arrow, tokens[7].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[8].tag);
    try std.testing.expectEqualStrings("i32", tokens[8].lexeme(lexer.source));
}

test "lexer: operators" {
    var lexer = Lexer.init(std.testing.allocator, "+ - * / % == != < > <= >= && || << >> += -= *= /= -> => = ! & | ^ ~");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenTag.plus, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.minus, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.star, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.slash, tokens[3].tag);
    try std.testing.expectEqual(TokenTag.percent, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.eq_eq, tokens[5].tag);
    try std.testing.expectEqual(TokenTag.bang_eq, tokens[6].tag);
    try std.testing.expectEqual(TokenTag.lt, tokens[7].tag);
    try std.testing.expectEqual(TokenTag.gt, tokens[8].tag);
    try std.testing.expectEqual(TokenTag.lt_eq, tokens[9].tag);
    try std.testing.expectEqual(TokenTag.gt_eq, tokens[10].tag);
    try std.testing.expectEqual(TokenTag.amp_amp, tokens[11].tag);
    try std.testing.expectEqual(TokenTag.pipe_pipe, tokens[12].tag);
    try std.testing.expectEqual(TokenTag.lshift, tokens[13].tag);
    try std.testing.expectEqual(TokenTag.rshift, tokens[14].tag);
    try std.testing.expectEqual(TokenTag.plus_eq, tokens[15].tag);
    try std.testing.expectEqual(TokenTag.minus_eq, tokens[16].tag);
    try std.testing.expectEqual(TokenTag.star_eq, tokens[17].tag);
    try std.testing.expectEqual(TokenTag.slash_eq, tokens[18].tag);
    try std.testing.expectEqual(TokenTag.arrow, tokens[19].tag);
    try std.testing.expectEqual(TokenTag.fat_arrow, tokens[20].tag);
    try std.testing.expectEqual(TokenTag.eq, tokens[21].tag);
    try std.testing.expectEqual(TokenTag.bang, tokens[22].tag);
    try std.testing.expectEqual(TokenTag.amp, tokens[23].tag);
    try std.testing.expectEqual(TokenTag.pipe, tokens[24].tag);
    try std.testing.expectEqual(TokenTag.caret, tokens[25].tag);
    try std.testing.expectEqual(TokenTag.tilde, tokens[26].tag);
}

test "lexer: delimiters" {
    var lexer = Lexer.init(std.testing.allocator, "( ) { } [ ] : ; , . _");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenTag.lparen, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.rparen, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.lbrace, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.rbrace, tokens[3].tag);
    try std.testing.expectEqual(TokenTag.lbracket, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.rbracket, tokens[5].tag);
    try std.testing.expectEqual(TokenTag.colon, tokens[6].tag);
    try std.testing.expectEqual(TokenTag.semicolon, tokens[7].tag);
    try std.testing.expectEqual(TokenTag.comma, tokens[8].tag);
    try std.testing.expectEqual(TokenTag.dot, tokens[9].tag);
    try std.testing.expectEqual(TokenTag.underscore, tokens[10].tag);
}

test "lexer: line comments" {
    var lexer = Lexer.init(std.testing.allocator, "fn // this is a comment\nadd");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenTag.fn_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.newline, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[2].tag);
    try std.testing.expectEqualStrings("add", tokens[2].lexeme(lexer.source));
}

test "lexer: block comments" {
    var lexer = Lexer.init(std.testing.allocator, "fn /* comment */ add");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(TokenTag.fn_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("add", tokens[1].lexeme(lexer.source));
}

test "lexer: nested block comments" {
    var lexer = Lexer.init(std.testing.allocator, "fn /* a /* b */ c */ add");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(TokenTag.fn_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("add", tokens[1].lexeme(lexer.source));
}

test "lexer: unterminated block comment" {
    var lexer = Lexer.init(std.testing.allocator, "fn /* unterminated");
    defer lexer.deinit();

    try std.testing.expectError(error.UnterminatedBlockComment, lexer.tokenize());
}

test "lexer: unterminated string" {
    var lexer = Lexer.init(std.testing.allocator, "\"unterminated");
    defer lexer.deinit();

    try std.testing.expectError(error.UnterminatedString, lexer.tokenize());
}

test "lexer: struct definition" {
    const source =
        \\struct Vec2 {
        \\    x: f64
        \\    y: f64
        \\
        \\    fn add(self: *Vec2, other: *Vec2) -> Vec2 {
        \\        return Vec2{ .x = self.x + other.x, .y = self.y + other.y }
        \\    }
        \\
        \\    fn zero() -> Vec2 {
        \\        return Vec2{ .x = 0.0, .y = 0.0 }
        \\    }
        \\}
    ;

    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expect(tokens.len > 12);
    try std.testing.expectEqual(TokenTag.struct_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("Vec2", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.lbrace, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.newline, tokens[3].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[4].tag);
    try std.testing.expectEqualStrings("x", tokens[4].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.colon, tokens[5].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[6].tag);
    try std.testing.expectEqualStrings("f64", tokens[6].lexeme(lexer.source));
}

test "lexer: question and pipeline operators" {
    var lexer = Lexer.init(std.testing.allocator, "? |> a |> b");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenTag.question, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.pipeline, tokens[1].tag);
    try std.testing.expectEqualStrings("|>", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.identifier, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.pipeline, tokens[3].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[5].tag);
}

test "lexer: at builtin marker" {
    var lexer = Lexer.init(std.testing.allocator, "@sizeof(i32)");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenTag.at, tokens[0].tag);
    try std.testing.expectEqualStrings("@", tokens[0].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("sizeof", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.eof, tokens[5].tag);
}

test "lexer: reference and mut-reference operators" {
    var lexer = Lexer.init(std.testing.allocator, "&x &mut y &fields");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenTag.amp, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.amp_mut, tokens[2].tag);
    try std.testing.expectEqualStrings("&mut", tokens[2].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.identifier, tokens[3].tag);
    try std.testing.expectEqualStrings("y", tokens[3].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.amp, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[5].tag);
    try std.testing.expectEqualStrings("fields", tokens[5].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.eof, tokens[6].tag);
}

test "lexer: amp mut maximal munch edge cases" {
    var lexer = Lexer.init(std.testing.allocator, "&mut &mutx &&x & mut");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenTag.amp_mut, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.amp, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[2].tag);
    try std.testing.expectEqualStrings("mutx", tokens[2].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.amp_amp, tokens[3].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[4].tag);
    try std.testing.expectEqualStrings("x", tokens[4].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.amp, tokens[5].tag);
    try std.testing.expectEqual(TokenTag.mut_kw, tokens[6].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[7].tag);
}

test "lexer: pipe then greater is pipeline not bitwise or" {
    var lexer = Lexer.init(std.testing.allocator, "a |> b | c || d");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenTag.identifier, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.pipeline, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.pipe, tokens[3].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.pipe_pipe, tokens[5].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[6].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[7].tag);
}

test "lexer: enum definition" {
    const source =
        \\enum Option[T] {
        \\    Some(T)
        \\    None
        \\}
    ;

    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expect(tokens.len > 5);
    try std.testing.expectEqual(TokenTag.enum_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("Option", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.lbracket, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[3].tag);
    try std.testing.expectEqualStrings("T", tokens[3].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.rbracket, tokens[4].tag);
}

test "lexer: interface definition" {
    const source =
        \\interface Speakable {
        \\    fn speak(self: *Self) -> String
        \\}
    ;

    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expect(tokens.len > 5);
    try std.testing.expectEqual(TokenTag.interface_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("Speakable", tokens[1].lexeme(lexer.source));
}

test "lexer: for loop" {
    const source =
        \\for i in 0..10 {
        \\    print(i)
        \\}
    ;

    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expect(tokens.len > 5);
    try std.testing.expectEqual(TokenTag.for_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("i", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.in_kw, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.int_literal, tokens[3].tag);
    try std.testing.expectEqualStrings("0", tokens[3].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.dot, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.dot, tokens[5].tag);
    try std.testing.expectEqual(TokenTag.int_literal, tokens[6].tag);
    try std.testing.expectEqualStrings("10", tokens[6].lexeme(lexer.source));
}

test "lexer: match expression" {
    const source =
        \\match result {
        \\    Ok(v) => print(v),
        \\    Err(e) => print(e),
        \\}
    ;

    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expect(tokens.len > 10);
    try std.testing.expectEqual(TokenTag.match_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("result", tokens[1].lexeme(lexer.source));
}

test "lexer: complete program" {
    const source =
        \\fn main() -> i32 {
        \\    let x: i32 = 42
        \\    let y: f64 = 3.14
        \\    if x > 0 {
        \\        return x
        \\    } else {
        \\        return -x
        \\    }
        \\}
    ;

    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expect(tokens.len > 20);
    try std.testing.expectEqual(TokenTag.fn_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("main", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.lparen, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.rparen, tokens[3].tag);
    try std.testing.expectEqual(TokenTag.arrow, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[5].tag);
    try std.testing.expectEqualStrings("i32", tokens[5].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.lbrace, tokens[6].tag);
}

test "lexer: multiple statements" {
    const source = "let x: i32 = 42\nlet y: f64 = 3.14\nreturn x + y";

    var lexer = Lexer.init(std.testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expect(tokens.len > 17);
    try std.testing.expectEqual(TokenTag.let_kw, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("x", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.colon, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[3].tag);
    try std.testing.expectEqualStrings("i32", tokens[3].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.eq, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.int_literal, tokens[5].tag);
    try std.testing.expectEqualStrings("42", tokens[5].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.newline, tokens[6].tag);
    try std.testing.expectEqual(TokenTag.let_kw, tokens[7].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[8].tag);
    try std.testing.expectEqualStrings("y", tokens[8].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.colon, tokens[9].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[10].tag);
    try std.testing.expectEqualStrings("f64", tokens[10].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.eq, tokens[11].tag);
    try std.testing.expectEqual(TokenTag.float_literal, tokens[12].tag);
    try std.testing.expectEqualStrings("3.14", tokens[12].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.newline, tokens[13].tag);
    try std.testing.expectEqual(TokenTag.return_kw, tokens[14].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[15].tag);
    try std.testing.expectEqualStrings("x", tokens[15].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.plus, tokens[16].tag);
    try std.testing.expectEqual(TokenTag.identifier, tokens[17].tag);
    try std.testing.expectEqualStrings("y", tokens[17].lexeme(lexer.source));
}

test "lexer: edge case - single dot" {
    var lexer = Lexer.init(std.testing.allocator, ".");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(TokenTag.dot, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[1].tag);
}

test "lexer: edge case - consecutive operators" {
    var lexer = Lexer.init(std.testing.allocator, "===!=<<>>==>>");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(TokenTag.eq_eq, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.eq, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.bang_eq, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.lshift, tokens[3].tag);
    try std.testing.expectEqual(TokenTag.rshift, tokens[4].tag);
    try std.testing.expectEqual(TokenTag.eq_eq, tokens[5].tag);
    try std.testing.expectEqual(TokenTag.rshift, tokens[6].tag);
}

test "lexer: whitespace handling" {
    var lexer = Lexer.init(std.testing.allocator, "  \t\n  \r\n  fn  ");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenTag.newline, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.newline, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.fn_kw, tokens[2].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[3].tag);
}

test "lexer: underscore identifiers" {
    var lexer = Lexer.init(std.testing.allocator, "_foo _bar _");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenTag.identifier, tokens[0].tag);
    try std.testing.expectEqualStrings("_foo", tokens[0].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.identifier, tokens[1].tag);
    try std.testing.expectEqualStrings("_bar", tokens[1].lexeme(lexer.source));
    try std.testing.expectEqual(TokenTag.underscore, tokens[2].tag);
}

test "lexer: escape sequences in strings" {
    var lexer = Lexer.init(std.testing.allocator, "\"tab\\there\" 'a'");
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(TokenTag.string_literal, tokens[0].tag);
    try std.testing.expectEqual(TokenTag.char_literal, tokens[1].tag);
    try std.testing.expectEqual(TokenTag.eof, tokens[2].tag);
}
