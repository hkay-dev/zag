//! A small line lexer: comments, strings, numbers, keywords, function and
//! type names, keys in data files, and Markdown. One table row per language
//! family; anything else is plain text.
const std = @import("std");

pub const Kind = enum(u8) { text, keyword, string, comment, number, function, type };

/// What is still open at the end of a line.
pub const State = enum(u8) { normal, block_comment, triple_double, triple_single, backtick, fence };

pub const Lang = struct {
    line_comment: []const u8 = "",
    block_comment: bool = false,
    /// Python's `"""` and `'''`.
    triple: bool = false,
    /// JS template strings and Go raw strings, which can span lines.
    backtick: bool = false,
    /// Zig's `\\` multiline string lines.
    line_string: []const u8 = "",
    /// Words before `(` are functions, Capitalized words types and ALL_CAPS
    /// words constants (in the number color).
    names: bool = false,
    /// `key:` and `key =` at the start of a line, and `"key":`, are keys (in
    /// the function color); `[section]` lines are keywords.
    keys: bool = false,
    markdown: bool = false,
    keywords: []const []const u8 = &.{},
};

pub const plain: Lang = .{};

const zig: Lang = .{ .line_comment = "//", .line_string = "\\\\", .names = true, .keywords = &.{
    "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "break",
    "continue", "defer", "errdefer", "try", "catch", "orelse", "and", "or", "struct", "enum",
    "union", "error", "comptime", "inline", "export", "extern", "test", "unreachable", "null",
    "undefined", "true", "false", "opaque", "packed", "align", "callconv", "noreturn", "anytype",
    "anyerror", "type", "void", "bool", "threadlocal", "volatile", "allowzero", "noalias",
    "linksection", "usize", "isize", "u8", "u16", "u32", "u64", "i32", "i64", "f32", "f64",
} };

const c_like: Lang = .{ .line_comment = "//", .block_comment = true, .names = true, .keywords = &.{
    "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
    "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "return", "short",
    "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
    "volatile", "while", "bool", "true", "false", "NULL", "nullptr", "class", "namespace",
    "public", "private", "protected", "template", "typename", "virtual", "override", "new",
    "delete", "this", "using", "try", "catch", "throw", "constexpr", "include", "define",
    "ifdef", "ifndef", "endif", "pragma", "self", "nil", "id", "final", "package", "import",
    "extends", "implements", "interface", "var", "val", "fun", "object",
} };

const js: Lang = .{ .line_comment = "//", .block_comment = true, .backtick = true, .names = true, .keywords = &.{
    "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
    "do", "else", "export", "extends", "finally", "for", "function", "if", "import", "in",
    "instanceof", "let", "new", "return", "super", "switch", "this", "throw", "try", "typeof",
    "var", "void", "while", "yield", "async", "await", "of", "true", "false", "null",
    "undefined", "interface", "type", "enum", "implements", "private", "public", "protected",
    "readonly", "static", "as", "from",
} };

const python: Lang = .{ .line_comment = "#", .triple = true, .names = true, .keywords = &.{
    "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
    "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
    "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "True",
    "False", "None", "self", "match", "case",
} };

const rust: Lang = .{ .line_comment = "//", .block_comment = true, .names = true, .keywords = &.{
    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
    "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
    "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true",
    "type", "unsafe", "use", "where", "while",
} };

const go: Lang = .{ .line_comment = "//", .block_comment = true, .backtick = true, .names = true, .keywords = &.{
    "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
    "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
    "return", "select", "struct", "switch", "type", "var", "true", "false", "nil",
} };

const swift: Lang = .{ .line_comment = "//", .block_comment = true, .names = true, .keywords = &.{
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

const ruby: Lang = .{ .line_comment = "#", .names = true, .keywords = &.{
    "def", "end", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do",
    "return", "class", "module", "self", "nil", "true", "false", "yield", "begin", "rescue",
    "ensure", "require",
} };

const lua: Lang = .{ .line_comment = "--", .names = true, .keywords = &.{
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
} };

const data: Lang = .{ .keys = true, .keywords = &.{ "true", "false", "null" } };
const hash_data: Lang = .{ .line_comment = "#", .keys = true, .keywords = &.{ "true", "false", "null" } };
const css: Lang = .{ .block_comment = true };
const markdown: Lang = .{ .markdown = true };

const by_ext = [_]struct { []const u8, *const Lang }{
    .{ "zig", &zig },       .{ "zon", &zig },        .{ "c", &c_like },       .{ "h", &c_like },
    .{ "cc", &c_like },     .{ "cpp", &c_like },     .{ "hpp", &c_like },     .{ "m", &c_like },
    .{ "mm", &c_like },     .{ "java", &c_like },    .{ "kt", &c_like },      .{ "cs", &c_like },
    .{ "js", &js },         .{ "mjs", &js },         .{ "cjs", &js },         .{ "jsx", &js },
    .{ "ts", &js },         .{ "tsx", &js },         .{ "py", &python },      .{ "rs", &rust },
    .{ "go", &go },         .{ "swift", &swift },    .{ "sh", &shell },       .{ "bash", &shell },
    .{ "zsh", &shell },     .{ "fish", &shell },     .{ "rb", &ruby },        .{ "lua", &lua },
    .{ "json", &data },     .{ "toml", &hash_data }, .{ "yaml", &hash_data }, .{ "yml", &hash_data },
    .{ "ini", &hash_data }, .{ "conf", &hash_data }, .{ "css", &css },       .{ "md", &markdown },
    .{ "markdown", &markdown },
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
    if (lang.markdown) return lexMarkdown(s, state, out);
    var st = state;
    var i: usize = if (lang.keys and st == .normal) keyAt(lang, s, out) else 0;
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
            .normal, .fence => {
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
                        i = e + 1;
                        var j = i;
                        while (j < s.len and s[j] == ' ') j += 1;
                        kind = if (lang.keys and j < s.len and s[j] == ':') .function else .string;
                    } else i += 1;
                } else if (std.ascii.isDigit(c) and (i == 0 or !isWord(s[i - 1]))) {
                    kind = .number;
                    while (i < s.len and (isWord(s[i]) or s[i] == '.')) i += 1;
                } else if (isWord(c) or c == '@') {
                    i += 1;
                    while (i < s.len and isWord(s[i])) i += 1;
                    if (c == '@' or isKeyword(lang, s[start..i])) {
                        kind = .keyword;
                    } else if (lang.names) kind = nameKind(s[start..i], s, i);
                } else i += 1;
            },
        }
        mark(out, start, i, kind);
    }
    return st;
}

fn mark(out: ?[]Kind, from: usize, to: usize, kind: Kind) void {
    if (out) |o| @memset(o[from..to], kind);
}

fn isKeyword(lang: *const Lang, w: []const u8) bool {
    for (lang.keywords) |k| if (std.mem.eql(u8, k, w)) return true;
    return false;
}

/// Capitalized words are types and ALL_CAPS ones constants; a word right
/// before `(` (or Rust's `!(`) is a function.
fn nameKind(w: []const u8, s: []const u8, end: usize) Kind {
    if (std.ascii.isUpper(w[0])) {
        for (w) |ch| if (std.ascii.isLower(ch)) return .type;
        return if (w.len > 1) .number else .type;
    }
    if (end < s.len and s[end] == '(') return .function;
    if (end + 1 < s.len and s[end] == '!' and (s[end + 1] == '(' or s[end + 1] == '[')) return .function;
    return .text;
}

/// Colors a `key:` or `key =` at the start of a data file's line, or a
/// `[section]` line in one with `#` comments, and returns where lexing goes
/// on from; 0 when the line starts with neither.
fn keyAt(lang: *const Lang, s: []const u8, out: ?[]Kind) usize {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i + 1 < s.len and s[i] == '-' and s[i + 1] == ' ') i += 2;
    const from = i;
    if (i < s.len and s[i] == '[' and lang.line_comment.len > 0) {
        const e = std.mem.indexOfScalarPos(u8, s, i, ']') orelse return 0;
        mark(out, 0, from, .text);
        mark(out, from, e + 1, .keyword);
        return e + 1;
    }
    while (i < s.len and (isWord(s[i]) or s[i] == '-' or s[i] == '.')) i += 1;
    if (i == from) return 0;
    var j = i;
    while (j < s.len and s[j] == ' ') j += 1;
    if (j == s.len or (s[j] != ':' and s[j] != '=')) return 0;
    mark(out, 0, from, .text);
    mark(out, from, i, .function);
    return i;
}

/// Markdown: headings, list and quote markers, `code`, fenced blocks,
/// **strong** text and [links](url).
fn lexMarkdown(s: []const u8, state: State, out: ?[]Kind) State {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') i += 1;
    const rest = s[i..];
    const fence = std.mem.startsWith(u8, rest, "```") or std.mem.startsWith(u8, rest, "~~~");
    if (state == .fence or fence) {
        mark(out, 0, s.len, .string);
        return if (fence == (state == .fence)) .normal else .fence;
    }
    mark(out, 0, s.len, .text);
    if (rest.len > 0 and rest[0] == '#') {
        var h = i;
        while (h < s.len and s[h] == '#') h += 1;
        if (h == s.len or s[h] == ' ') {
            mark(out, 0, s.len, .keyword);
            return .normal;
        }
    }
    var p = i;
    if (rest.len > 1 and rest[1] == ' ' and std.mem.indexOfScalar(u8, "-*+>", rest[0]) != null) {
        p += 1;
    } else {
        while (p < s.len and std.ascii.isDigit(s[p])) p += 1;
        if (p > i and p + 1 < s.len and (s[p] == '.' or s[p] == ')') and s[p + 1] == ' ') p += 1 else p = i;
    }
    mark(out, i, p, .keyword);
    while (p < s.len) {
        const end: ?usize = switch (s[p]) {
            '`' => if (std.mem.indexOfScalarPos(u8, s, p + 1, '`')) |e| blk: {
                mark(out, p, e + 1, .string);
                break :blk e + 1;
            } else null,
            '[' => link(s, p, out),
            '*', '_' => if (p + 1 < s.len and s[p + 1] == s[p]) (if (std.mem.indexOfPos(u8, s, p + 2, s[p .. p + 2])) |e| blk: {
                mark(out, p, e + 2, .keyword);
                break :blk e + 2;
            } else null) else null,
            else => null,
        };
        p = end orelse p + 1;
    }
    return .normal;
}

/// Colors a `[text](url)` link at `p` and returns where it ends.
fn link(s: []const u8, p: usize, out: ?[]Kind) ?usize {
    const e = std.mem.indexOfScalarPos(u8, s, p + 1, ']') orelse return null;
    if (e + 1 >= s.len or s[e + 1] != '(') return null;
    const q = std.mem.indexOfScalarPos(u8, s, e + 2, ')') orelse return null;
    mark(out, p, e + 1, .function);
    mark(out, e + 1, q + 1, .comment);
    return q + 1;
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

test "names: types, constants and calls" {
    var k: [32]Kind = undefined;
    _ = lexLine(&python, "x = Page(LIMIT, top(n))", .normal, &k);
    try t.expectEqual(Kind.text, k[0]);
    try t.expectEqual(Kind.type, k[4]);
    try t.expectEqual(Kind.number, k[9]);
    try t.expectEqual(Kind.function, k[16]);
    try t.expectEqual(Kind.text, k[20]);
}

test "data keys only at the start of a line or before a colon" {
    var k: [32]Kind = undefined;
    _ = lexLine(&hash_data, "  - path: http://a", .normal, &k);
    try t.expectEqual(Kind.text, k[2]);
    try t.expectEqual(Kind.function, k[4]);
    try t.expectEqual(Kind.text, k[10]);
    try t.expectEqual(Kind.text, k[14]);
    _ = lexLine(&data, "{\"a\": \"b\"}", .normal, &k);
    try t.expectEqual(Kind.function, k[1]);
    try t.expectEqual(Kind.string, k[6]);
}

test "markdown fences carry across lines and color nothing else inside" {
    var k: [32]Kind = undefined;
    const s1 = lexLine(&markdown, "```sh", .normal, &k);
    try t.expectEqual(State.fence, s1);
    try t.expectEqual(State.fence, lexLine(&markdown, "# not a heading", s1, &k));
    try t.expectEqual(Kind.string, k[0]);
    try t.expectEqual(State.normal, lexLine(&markdown, "```", s1, &k));
    _ = lexLine(&markdown, "- see [x](y) and `z`", .normal, &k);
    try t.expectEqual(Kind.keyword, k[0]);
    try t.expectEqual(Kind.function, k[7]);
    try t.expectEqual(Kind.comment, k[10]);
    try t.expectEqual(Kind.string, k[18]);
}
