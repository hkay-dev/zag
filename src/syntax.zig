//! A small line lexer: comments, strings, numbers, keywords, function and
//! type names, keys in data files, Markdown and HTML. One table row per
//! language family; anything else is plain text.
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

pub const Kind = enum(u8) { text, keyword, string, comment, number, function, type };

/// What is still open at the end of a line. The HTML ones: inside a
/// comment, inside a tag (one that opens a style or script element says
/// so), and inside a style or script element and what's open in there.
pub const State = enum(u8) {
    normal, block_comment, triple_double, triple_single, backtick, fence,
    html_comment, tag, tag_style, tag_script, style, style_comment, script, script_comment, script_backtick,
};

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
    /// Tags, attributes and comments, with CSS and JavaScript inside
    /// `<style>` and `<script>`.
    html: bool = false,
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
const css: Lang = .{ .block_comment = true, .keys = true };
const markdown: Lang = .{ .markdown = true };
const html: Lang = .{ .html = true };

const by_ext = [_]struct { []const u8, *const Lang }{
    .{ "zig", &zig },       .{ "zon", &zig },        .{ "c", &c_like },       .{ "h", &c_like },
    .{ "cc", &c_like },     .{ "cpp", &c_like },     .{ "hpp", &c_like },     .{ "m", &c_like },
    .{ "mm", &c_like },     .{ "java", &c_like },    .{ "kt", &c_like },      .{ "cs", &c_like },
    .{ "js", &js },         .{ "mjs", &js },         .{ "cjs", &js },         .{ "jsx", &js },
    .{ "ts", &js },         .{ "tsx", &js },         .{ "py", &python },      .{ "rs", &rust },
    .{ "go", &go },         .{ "swift", &swift },    .{ "sh", &shell },       .{ "bash", &shell },
    .{ "zsh", &shell },     .{ "fish", &shell },     .{ "rb", &ruby },        .{ "lua", &lua },
    .{ "json", &data },     .{ "jsonl", &data },     .{ "ndjson", &data },    .{ "toml", &hash_data },
    .{ "yaml", &hash_data }, .{ "yml", &hash_data }, .{ "ini", &hash_data }, .{ "conf", &hash_data },
    .{ "css", &css },       .{ "md", &markdown },    .{ "markdown", &markdown }, .{ "html", &html },
    .{ "htm", &html },      .{ "xhtml", &html },     .{ "xml", &html },       .{ "svg", &html },
    .{ "plist", &html },
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

/// Repairs cached line-start states and returns the half-open range whose
/// kinds must be forgotten. Same-line-count edits stop at state convergence.
pub fn syncStates(gpa: std.mem.Allocator, lang: *const Lang, b: *Buffer, states: *std.ArrayList(State), upto: usize) ![2]usize {
    const first = b.touched;
    var invalid = [2]usize{ first, std.math.maxInt(usize) };
    if (first < states.items.len) {
        if (b.lines_shifted) {
            states.shrinkRetainingCapacity(first + 1);
        } else {
            var i = first;
            while (i + 1 < states.items.len and i < b.lines()) : (i += 1) {
                // Past what this frame needs: drop the rest rather than lex to the end.
                if (i >= upto) {
                    states.shrinkRetainingCapacity(i + 1);
                    break;
                }
                const before = states.items[i + 1];
                const after = lexLine(lang, b.line(i), states.items[i], null);
                states.items[i + 1] = after;
                if (i + 1 >= b.touched_end and before == after) {
                    invalid[1] = i + 1;
                    break;
                }
            }
        }
    }
    // Leave pending invalidation intact if extending the cache fails.
    if (lang != &plain) {
        if (states.items.len == 0) try states.append(gpa, .normal);
        while (states.items.len <= upto and states.items.len < b.lines()) {
            const i = states.items.len - 1;
            try states.append(gpa, lexLine(lang, b.line(i), states.items[i], null));
        }
    }
    b.touched = std.math.maxInt(usize);
    b.touched_end = 0;
    b.lines_shifted = false;
    return invalid;
}

/// Lexes one line that begins in `state`, writing a kind per byte into
/// `out` when given, and returns the state the next line begins in.
pub fn lexLine(lang: *const Lang, s: []const u8, state: State, out: ?[]Kind) State {
    if (lang.markdown) return lexMarkdown(s, state, out);
    if (lang.html) return lexHtml(s, state, out);
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
            else => {
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

/// HTML: tag names as keywords, attribute names as functions, their
/// values as strings, comments, and `&entities;` as numbers. A style or
/// script element's text is lexed as CSS or JavaScript up to its end tag.
fn lexHtml(s: []const u8, state: State, out: ?[]Kind) State {
    mark(out, 0, s.len, .text);
    var st = state;
    var i: usize = 0;
    while (i < s.len) switch (st) {
        .html_comment => {
            const e = std.mem.indexOfPos(u8, s, i, "-->");
            const end = if (e) |x| x + 3 else s.len;
            mark(out, i, end, .comment);
            i = end;
            if (e != null) st = .normal;
        },
        .tag, .tag_style, .tag_script => i = attrs(s, i, &st, out),
        .style, .style_comment, .script, .script_comment, .script_backtick => {
            const in_style = st == .style or st == .style_comment;
            const e = endTag(s, i, if (in_style) "style" else "script") orelse s.len;
            const inner: State = switch (st) {
                .style_comment, .script_comment => .block_comment,
                .script_backtick => .backtick,
                else => .normal,
            };
            const after = lexLine(if (in_style) &css else &js, s[i..e], inner, if (out) |o| o[i..e] else null);
            if (e < s.len) {
                st = .normal;
            } else if (in_style) {
                st = if (after == .block_comment) .style_comment else .style;
            } else st = switch (after) {
                .block_comment => .script_comment,
                .backtick => .script_backtick,
                else => .script,
            };
            i = e;
        },
        else => {
            const c = s[i];
            if (std.mem.startsWith(u8, s[i..], "<!--")) {
                st = .html_comment;
            } else if (c == '<' and i + 1 < s.len and (std.ascii.isAlphabetic(s[i + 1]) or s[i + 1] == '/' or s[i + 1] == '!' or s[i + 1] == '?')) {
                const closing = s[i + 1] == '/';
                i += if (closing) 2 else 1;
                const from = i;
                while (i < s.len and (isWord(s[i]) or s[i] == '-' or s[i] == ':' or s[i] == '!' or s[i] == '?')) i += 1;
                mark(out, from, i, .keyword);
                const name = s[from..i];
                st = if (closing) .tag else if (std.ascii.eqlIgnoreCase(name, "style")) .tag_style else if (std.ascii.eqlIgnoreCase(name, "script")) .tag_script else .tag;
            } else if (c == '&') {
                var e = i + 1;
                while (e < s.len and (std.ascii.isAlphanumeric(s[e]) or s[e] == '#')) e += 1;
                if (e > i + 1 and e < s.len and s[e] == ';') {
                    mark(out, i, e + 1, .number);
                    i = e + 1;
                } else i += 1;
            } else i += 1;
        },
    };
    return st;
}

/// Colors a tag's attributes from `i` up to its `>`, after which `st` goes
/// to what the tag opened, and returns where lexing goes on from.
fn attrs(s: []const u8, from: usize, st: *State, out: ?[]Kind) usize {
    var i = from;
    while (i < s.len) {
        const c = s[i];
        if (c == '>') {
            st.* = switch (st.*) {
                .tag_style => .style,
                .tag_script => .script,
                else => .normal,
            };
            return i + 1;
        } else if (c == '"' or c == '\'') {
            const e = if (std.mem.indexOfScalarPos(u8, s, i + 1, c)) |x| x + 1 else s.len;
            mark(out, i, e, .string);
            i = e;
        } else if (isWord(c) or c == '@' or c == ':') {
            const start = i;
            while (i < s.len and (isWord(s[i]) or s[i] == '-' or s[i] == ':' or s[i] == '.' or s[i] == '@')) i += 1;
            mark(out, start, i, .function);
        } else i += 1;
    }
    return i;
}

/// Where `</name` next starts from `from`, in any case.
fn endTag(s: []const u8, from: usize, name: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, s, i, "</")) |at| : (i = at + 2) {
        if (std.ascii.startsWithIgnoreCase(s[at + 2 ..], name)) return at;
    }
    return null;
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

test "html: tags, attributes, values, comments and entities" {
    var k: [48]Kind = undefined;
    _ = lexLine(&html, "<a href=\"x\">&amp; t</a> <!-- c -->", .normal, &k);
    try t.expectEqual(Kind.text, k[0]);
    try t.expectEqual(Kind.keyword, k[1]);
    try t.expectEqual(Kind.function, k[3]);
    try t.expectEqual(Kind.string, k[8]);
    try t.expectEqual(Kind.number, k[12]);
    try t.expectEqual(Kind.text, k[18]);
    try t.expectEqual(Kind.keyword, k[21]);
    try t.expectEqual(Kind.comment, k[25]);
    try t.expectEqual(State.tag, lexLine(&html, "<!DOCTYPE html", .normal, &k));
    try t.expectEqual(Kind.keyword, k[1]);
    try t.expectEqual(State.normal, lexLine(&html, "  lang=\"en\">", .tag, &k));
    try t.expectEqual(Kind.function, k[2]);
    try t.expectEqual(Kind.string, k[7]);
}

test "html: style and script text is lexed as CSS and JavaScript up to the end tag" {
    var k: [48]Kind = undefined;
    try t.expectEqual(State.style_comment, lexLine(&html, "<style> /* a", .normal, &k));
    try t.expectEqual(Kind.comment, k[8]);
    try t.expectEqual(State.style, lexLine(&html, "b */ p {", .style_comment, &k));
    try t.expectEqual(Kind.comment, k[0]);
    try t.expectEqual(State.normal, lexLine(&html, "} </STYLE> <b>", .style, &k));
    try t.expectEqual(Kind.keyword, k[4]);
    try t.expectEqual(Kind.keyword, k[12]);
    try t.expectEqual(State.script_backtick, lexLine(&html, "<script>let s = `x", .normal, &k));
    try t.expectEqual(Kind.keyword, k[8]);
    try t.expectEqual(Kind.string, k[16]);
    try t.expectEqual(State.normal, lexLine(&html, "y`; if (a < b) {}</script>", .script_backtick, &k));
    try t.expectEqual(Kind.string, k[0]);
    try t.expectEqual(Kind.keyword, k[4]);
    try t.expectEqual(Kind.keyword, k[19]);
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

fn expectIncremental(lang: *const Lang, b: *Buffer, states: *std.ArrayList(State), cached: *std.ArrayList([]Kind)) ![2]usize {
    const invalid = try syncStates(t.allocator, lang, b, states, b.lines() - 1);
    // A line-count change may move all later rows; discard those old slots.
    if (cached.items.len != b.lines()) {
        for (cached.items) |k| t.allocator.free(k);
        cached.clearRetainingCapacity();
        for (0..b.lines()) |_| try cached.append(t.allocator, try t.allocator.alloc(Kind, 0));
    }
    var state: State = .normal;
    for (0..b.lines()) |i| {
        const line = b.line(i);
        if (i >= invalid[0] and i < invalid[1]) {
            t.allocator.free(cached.items[i]);
            cached.items[i] = try t.allocator.alloc(Kind, line.len);
            _ = lexLine(lang, line, states.items[i], cached.items[i]);
        }
        const scratch = try t.allocator.alloc(Kind, line.len);
        defer t.allocator.free(scratch);
        try t.expectEqual(state, states.items[i]);
        state = lexLine(lang, line, state, scratch);
        try t.expectEqualSlices(Kind, scratch, cached.items[i]);
    }
    return invalid;
}

test "incremental kinds converge inside and outside multiline regions" {
    const cases = .{
        .{ &c_like, "int a;\n/* start\ninside\nend */\nint b;\nint c;" },
        .{ &python, "a = 1\nx = \"\"\"start\ninside\nend\"\"\"\nb = 2\nc = 3" },
        .{ &js, "let a;\nx = `start\ninside\nend`;\nlet b;\nlet c;" },
        .{ &zig, "const a = 1;\nconst x =\n    \\\\start\n    \\\\inside\n;\nconst b = 2;" },
        .{ &markdown, "before\n```\ninside\n```\nafter\nlast" },
        .{ &html, "<p>\n<!-- start\ninside\nend -->\n<p>\n<p>" },
        .{ &html, "<p>\n<script>\nlet a = 1;\n</script>\n<p>\n<p>" },
    };
    inline for (cases) |case| {
        var b = try Buffer.init(t.allocator, case[1]);
        defer b.deinit(t.allocator);
        var states: std.ArrayList(State) = .empty;
        defer states.deinit(t.allocator);
        var cached: std.ArrayList([]Kind) = .empty;
        defer {
            for (cached.items) |k| t.allocator.free(k);
            cached.deinit(t.allocator);
        }
        _ = try expectIncremental(case[0], &b, &states, &cached);
        for ([_]usize{ 0, 2, 4 }) |line| {
            const pos = b.lineEnd(line);
            try b.replace(t.allocator, pos, pos, "x", pos, false);
            const invalid = try expectIncremental(case[0], &b, &states, &cached);
            try t.expectEqual([2]usize{ line, line + 1 }, invalid);
        }
        // Changing a closer propagates into the suffix rather than retaining it.
        const close_start = b.lineStart(3);
        try b.replace(t.allocator, close_start, b.lineEnd(3), "unclosed", close_start, false);
        _ = try expectIncremental(case[0], &b, &states, &cached);
        _ = try b.undo(t.allocator);
        _ = try expectIncremental(case[0], &b, &states, &cached);
        // Remove an opener, then restore it through undo and redo.
        const start = b.lineStart(1);
        const end = b.lineEnd(1);
        try b.replace(t.allocator, start, end, "changed", start, false);
        _ = try expectIncremental(case[0], &b, &states, &cached);
        _ = try b.undo(t.allocator);
        _ = try expectIncremental(case[0], &b, &states, &cached);
        _ = try b.redo(t.allocator);
        _ = try expectIncremental(case[0], &b, &states, &cached);
        // Two edits before a frame must not converge before the second edit.
        try b.replace(t.allocator, 0, 0, "x", 0, false);
        const pos = b.lineStart(4);
        try b.replace(t.allocator, pos, pos, "y", pos, false);
        _ = try expectIncremental(case[0], &b, &states, &cached);
        try b.replace(t.allocator, 0, 0, "new\n", 0, false);
        _ = try expectIncremental(case[0], &b, &states, &cached);
        _ = try b.undo(t.allocator);
        _ = try expectIncremental(case[0], &b, &states, &cached);
    }
}
