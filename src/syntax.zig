//! A small line lexer: comments, strings, numbers and keywords. One table
//! row per language family; anything else is plain text.
const std = @import("std");

pub const Kind = enum(u8) { text, keyword, string, comment, number };

/// What is still open at the end of a line.
pub const State = enum(u8) { normal, block_comment, triple_double, triple_single, backtick };

pub const Lang = struct {
    line_comment: []const u8 = "",
    block_comment: bool = false,
    /// Python's `"""` and `'''`.
    triple: bool = false,
    /// JS template strings and Go raw strings, which can span lines.
    backtick: bool = false,
    /// Zig's `\\` multiline string lines.
    line_string: []const u8 = "",
    keywords: []const []const u8 = &.{},
};

pub const plain: Lang = .{};

const zig: Lang = .{ .line_comment = "//", .line_string = "\\\\", .keywords = &.{
    "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "break",
    "continue", "defer", "errdefer", "try", "catch", "orelse", "and", "or", "struct", "enum",
    "union", "error", "comptime", "inline", "export", "extern", "test", "unreachable", "null",
    "undefined", "true", "false", "opaque", "packed", "align", "callconv", "noreturn", "anytype",
    "anyerror", "type", "void", "bool", "threadlocal", "volatile", "allowzero", "noalias",
    "linksection", "usize", "isize", "u8", "u16", "u32", "u64", "i32", "i64", "f32", "f64",
} };

const c_like: Lang = .{ .line_comment = "//", .block_comment = true, .keywords = &.{
    "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
    "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "return", "short",
    "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
    "volatile", "while", "bool", "true", "false", "NULL", "nullptr", "class", "namespace",
    "public", "private", "protected", "template", "typename", "virtual", "override", "new",
    "delete", "this", "using", "try", "catch", "throw", "constexpr", "include", "define",
    "ifdef", "ifndef", "endif", "pragma", "self", "nil", "id", "final", "package", "import",
    "extends", "implements", "interface", "var", "val", "fun", "object",
} };

const js: Lang = .{ .line_comment = "//", .block_comment = true, .backtick = true, .keywords = &.{
    "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
    "do", "else", "export", "extends", "finally", "for", "function", "if", "import", "in",
    "instanceof", "let", "new", "return", "super", "switch", "this", "throw", "try", "typeof",
    "var", "void", "while", "yield", "async", "await", "of", "true", "false", "null",
    "undefined", "interface", "type", "enum", "implements", "private", "public", "protected",
    "readonly", "static", "as", "from",
} };

const python: Lang = .{ .line_comment = "#", .triple = true, .keywords = &.{
    "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
    "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
    "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "True",
    "False", "None", "self", "match", "case",
} };

const rust: Lang = .{ .line_comment = "//", .block_comment = true, .keywords = &.{
    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
    "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
    "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true",
    "type", "unsafe", "use", "where", "while",
} };

const go: Lang = .{ .line_comment = "//", .block_comment = true, .backtick = true, .keywords = &.{
    "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
    "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
    "return", "select", "struct", "switch", "type", "var", "true", "false", "nil",
} };

const swift: Lang = .{ .line_comment = "//", .block_comment = true, .keywords = &.{
    "class", "struct", "enum", "protocol", "extension", "func", "var", "let", "if", "else",
    "guard", "return", "for", "in", "while", "repeat", "switch", "case", "default", "break",
    "continue", "import", "public", "private", "internal", "fileprivate", "open", "static",
    "self", "Self", "init", "deinit", "true", "false", "nil", "try", "throw", "throws", "async",
    "await", "some", "any", "where",
} };

const shell: Lang = .{ .line_comment = "#", .keywords = &.{
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
    "function", "in", "return", "export", "local", "readonly", "set", "unset", "exit",
} };

const ruby: Lang = .{ .line_comment = "#", .keywords = &.{
    "def", "end", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do",
    "return", "class", "module", "self", "nil", "true", "false", "yield", "begin", "rescue",
    "ensure", "require",
} };

const lua: Lang = .{ .line_comment = "--", .keywords = &.{
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
} };

const data: Lang = .{ .keywords = &.{ "true", "false", "null" } };
const hash_data: Lang = .{ .line_comment = "#", .keywords = &.{ "true", "false", "null" } };
const css: Lang = .{ .block_comment = true };

const by_ext = [_]struct { []const u8, *const Lang }{
    .{ "zig", &zig },       .{ "zon", &zig },        .{ "c", &c_like },       .{ "h", &c_like },
    .{ "cc", &c_like },     .{ "cpp", &c_like },     .{ "hpp", &c_like },     .{ "m", &c_like },
    .{ "mm", &c_like },     .{ "java", &c_like },    .{ "kt", &c_like },      .{ "cs", &c_like },
    .{ "js", &js },         .{ "mjs", &js },         .{ "cjs", &js },         .{ "jsx", &js },
    .{ "ts", &js },         .{ "tsx", &js },         .{ "py", &python },      .{ "rs", &rust },
    .{ "go", &go },         .{ "swift", &swift },    .{ "sh", &shell },       .{ "bash", &shell },
    .{ "zsh", &shell },     .{ "fish", &shell },     .{ "rb", &ruby },        .{ "lua", &lua },
    .{ "json", &data },     .{ "toml", &hash_data }, .{ "yaml", &hash_data }, .{ "yml", &hash_data },
    .{ "ini", &hash_data }, .{ "conf", &hash_data }, .{ "css", &css },
};

pub fn forPath(path: []const u8) *const Lang {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "Makefile") or std.mem.eql(u8, base, "Dockerfile")) return &hash_data;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return &plain;
    const ext = base[dot + 1 ..];
    for (by_ext) |e| if (std.mem.eql(u8, e[0], ext)) return e[1];
    return &plain;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// Lexes one line that begins in `state`, writing a kind per byte into
/// `out` when given, and returns the state the next line begins in.
pub fn lexLine(lang: *const Lang, s: []const u8, state: State, out: ?[]Kind) State {
    var st = state;
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        var kind: Kind = .text;
        switch (st) {
            .block_comment => {
                kind = .comment;
                if (std.mem.indexOfPos(u8, s, i, "*/")) |e| {
                    i = e + 2;
                    st = .normal;
                } else i = s.len;
            },
            .triple_double, .triple_single, .backtick => {
                kind = .string;
                const close: []const u8 = switch (st) {
                    .triple_double => "\"\"\"",
                    .triple_single => "'''",
                    else => "`",
                };
                if (findClose(s, i, close)) |e| {
                    i = e + close.len;
                    st = .normal;
                } else i = s.len;
            },
            .normal => {
                const c = s[i];
                const rest = s[i..];
                if (lang.line_comment.len > 0 and std.mem.startsWith(u8, rest, lang.line_comment) and
                    (lang.line_comment[0] != '#' or i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t'))
                {
                    kind = .comment;
                    i = s.len;
                } else if (lang.line_string.len > 0 and std.mem.startsWith(u8, rest, lang.line_string)) {
                    kind = .string;
                    i = s.len;
                } else if (lang.block_comment and std.mem.startsWith(u8, rest, "/*")) {
                    kind = .comment;
                    i += 2;
                    st = .block_comment;
                } else if (lang.triple and (std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''"))) {
                    kind = .string;
                    i += 3;
                    st = if (c == '"') .triple_double else .triple_single;
                } else if (lang.backtick and c == '`') {
                    kind = .string;
                    i += 1;
                    st = .backtick;
                } else if (c == '"' or (c == '\'' and lang.keywords.len > 0)) {
                    if (findClose(s, i + 1, s[i .. i + 1])) |e| {
                        kind = .string;
                        i = e + 1;
                    } else i += 1;
                } else if (std.ascii.isDigit(c) and (i == 0 or !isWord(s[i - 1]))) {
                    kind = .number;
                    while (i < s.len and (isWord(s[i]) or s[i] == '.')) i += 1;
                } else if (isWord(c) or c == '@') {
                    i += 1;
                    while (i < s.len and isWord(s[i])) i += 1;
                    if (c == '@' or isKeyword(lang, s[start..i])) kind = .keyword;
                } else i += 1;
            },
        }
        if (out) |o| @memset(o[start..i], kind);
    }
    return st;
}

fn isKeyword(lang: *const Lang, w: []const u8) bool {
    for (lang.keywords) |k| if (std.mem.eql(u8, k, w)) return true;
    return false;
}

/// Where `close` next appears from `i`, skipping backslash escapes.
fn findClose(s: []const u8, from: usize, close: []const u8) ?usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
        } else if (std.mem.startsWith(u8, s[i..], close)) return i;
    }
    return null;
}

const t = std.testing;

test "block comments and template strings carry across lines" {
    var k: [32]Kind = undefined;
    const s1 = lexLine(&js, "let a = 1; /* x", .normal, &k);
    try t.expectEqual(State.block_comment, s1);
    try t.expectEqual(Kind.keyword, k[0]);
    try t.expectEqual(Kind.number, k[8]);
    try t.expectEqual(Kind.comment, k[11]);
    try t.expectEqual(State.backtick, lexLine(&js, "y */ `a", s1, &k));
    try t.expectEqual(Kind.comment, k[2]);
    try t.expectEqual(Kind.text, k[4]);
    try t.expectEqual(Kind.string, k[5]);
}

test "a hash only starts a comment at a word boundary" {
    var k: [16]Kind = undefined;
    _ = lexLine(&shell, "echo $#  # hi", .normal, &k);
    try t.expectEqual(Kind.text, k[6]);
    try t.expectEqual(Kind.comment, k[9]);
}

test "an escaped quote stays inside the string" {
    var k: [16]Kind = undefined;
    _ = lexLine(&zig, "\"a\\\"b\" x", .normal, &k);
    try t.expectEqual(Kind.string, k[5]);
    try t.expectEqual(Kind.text, k[7]);
}
