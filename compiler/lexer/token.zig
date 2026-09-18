const std = @import("std");

pub const TokenTag = enum(u8) {
    // Literals
    int_literal,
    float_literal,
    string_literal,
    char_literal,
    identifier,

    // Keywords
    fn_kw,
    let_kw,
    mut_kw,
    struct_kw,
    enum_kw,
    impl_kw,
    interface_kw,
    return_kw,
    if_kw,
    else_kw,
    while_kw,
    for_kw,
    in_kw,
    match_kw,
    import_kw,
    as_kw,
    defer_kw,
    true_kw,
    false_kw,
    null_kw,
    comptime_kw,
    move_kw,
    region_kw,

    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    eq,
    bang,
    eq_eq,
    bang_eq,
    lt,
    gt,
    lt_eq,
    gt_eq,
    amp_amp,
    pipe_pipe,
    lshift,
    rshift,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    arrow,
    fat_arrow,
    question,
    amp_mut,
    pipeline,
    at,

    // Delimiters
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    colon,
    semicolon,
    comma,
    dot,
    underscore,

    // Special
    eof,
    invalid,
    newline,

    pub fn lexeme(self: TokenTag) []const u8 {
        return switch (self) {
            .int_literal => "<int>",
            .float_literal => "<float>",
            .string_literal => "<string>",
            .char_literal => "<char>",
            .identifier => "<identifier>",
            .fn_kw => "fn",
            .let_kw => "let",
            .mut_kw => "mut",
            .struct_kw => "struct",
            .enum_kw => "enum",
            .impl_kw => "impl",
            .interface_kw => "interface",
            .return_kw => "return",
            .if_kw => "if",
            .else_kw => "else",
            .while_kw => "while",
            .for_kw => "for",
            .in_kw => "in",
            .match_kw => "match",
            .import_kw => "import",
            .as_kw => "as",
            .defer_kw => "defer",
            .true_kw => "true",
            .false_kw => "false",
            .null_kw => "null",
            .comptime_kw => "comptime",
            .move_kw => "move",
            .region_kw => "region",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .tilde => "~",
            .eq => "=",
            .bang => "!",
            .eq_eq => "==",
            .bang_eq => "!=",
            .lt => "<",
            .gt => ">",
            .lt_eq => "<=",
            .gt_eq => ">=",
            .amp_amp => "&&",
            .pipe_pipe => "||",
            .lshift => "<<",
            .rshift => ">>",
            .plus_eq => "+=",
            .minus_eq => "-=",
            .star_eq => "*=",
            .slash_eq => "/=",
            .arrow => "->",
            .fat_arrow => "=>",
            .question => "?",
            .amp_mut => "&mut",
            .pipeline => "|>",
            .at => "@",
            .lparen => "(",
            .rparen => ")",
            .lbrace => "{",
            .rbrace => "}",
            .lbracket => "[",
            .rbracket => "]",
            .colon => ":",
            .semicolon => ";",
            .comma => ",",
            .dot => ".",
            .underscore => "_",
            .eof => "<eof>",
            .invalid => "<invalid>",
            .newline => "<newline>",
        };
    }
};

pub const Token = struct {
    tag: TokenTag,
    start: u32,
    end: u32,

    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    pub fn len(self: Token) u32 {
        return self.end - self.start;
    }
};

pub const KEYWORDS = init: {
    const KV = struct { []const u8, TokenTag };
    const pairs = [_]KV{
        .{ "fn", .fn_kw },
        .{ "let", .let_kw },
        .{ "mut", .mut_kw },
        .{ "struct", .struct_kw },
        .{ "enum", .enum_kw },
        .{ "impl", .impl_kw },
        .{ "interface", .interface_kw },
        .{ "return", .return_kw },
        .{ "if", .if_kw },
        .{ "else", .else_kw },
        .{ "while", .while_kw },
        .{ "for", .for_kw },
        .{ "in", .in_kw },
        .{ "match", .match_kw },
        .{ "import", .import_kw },
        .{ "as", .as_kw },
        .{ "defer", .defer_kw },
        .{ "true", .true_kw },
        .{ "false", .false_kw },
        .{ "null", .null_kw },
        .{ "comptime", .comptime_kw },
        .{ "move", .move_kw },
        .{ "region", .region_kw },
    };

    const Map = std.StaticStringMap(TokenTag);
    break :init Map.initComptime(pairs);
};

pub fn lookupKeyword(ident: []const u8) ?TokenTag {
    return KEYWORDS.get(ident);
}

test "TokenTag lexeme" {
    try std.testing.expectEqualStrings("fn", TokenTag.fn_kw.lexeme());
    try std.testing.expectEqualStrings("==", TokenTag.eq_eq.lexeme());
    try std.testing.expectEqualStrings("->", TokenTag.arrow.lexeme());
    try std.testing.expectEqualStrings("<eof>", TokenTag.eof.lexeme());
}

test "Token lexeme from source" {
    const source = "hello world";
    const tok = Token{ .tag = .identifier, .start = 0, .end = 5 };
    try std.testing.expectEqualStrings("hello", tok.lexeme(source));
    try std.testing.expectEqual(@as(u32, 5), tok.len());
}

test "lookupKeyword finds keywords" {
    try std.testing.expectEqual(@as(?TokenTag, .fn_kw), lookupKeyword("fn"));
    try std.testing.expectEqual(@as(?TokenTag, .return_kw), lookupKeyword("return"));
    try std.testing.expectEqual(@as(?TokenTag, .comptime_kw), lookupKeyword("comptime"));
    try std.testing.expectEqual(@as(?TokenTag, .move_kw), lookupKeyword("move"));
    try std.testing.expectEqual(@as(?TokenTag, .region_kw), lookupKeyword("region"));
    try std.testing.expectEqual(@as(?TokenTag, null), lookupKeyword("foo"));
    try std.testing.expectEqual(@as(?TokenTag, null), lookupKeyword("Fn"));
}

test "drops class family keywords" {
    try std.testing.expectEqual(@as(?TokenTag, null), lookupKeyword("class"));
    try std.testing.expectEqual(@as(?TokenTag, null), lookupKeyword("override"));
    try std.testing.expectEqual(@as(?TokenTag, null), lookupKeyword("prop"));
    try std.testing.expectEqual(@as(?TokenTag, null), lookupKeyword("this"));
    try std.testing.expectEqual(@as(?TokenTag, null), lookupKeyword("final"));
    try std.testing.expectEqual(@as(?TokenTag, null), lookupKeyword("print"));
}
