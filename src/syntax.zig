//! A small line lexer: comments, strings, numbers, keywords, function and
//! type names, keys in data files, Markdown and HTML. One table row per
//! language family; anything else is plain text.
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

pub const Kind = enum(u8) { text, keyword, string, comment, number, function, type };

/// What is still open at the end of a line. The HTML ones: inside a
/// comment, inside a tag (one that opens a style or script element says
/// so), and inside a style or script element and what's open in there.
pub const State = enum(usize) {
    normal, block_comment, triple_double, triple_single, backtick,
    html_comment, tag, tag_style, tag_script, style, style_comment, script, script_comment, script_backtick,
    tag_double, tag_single, tag_style_double, tag_style_single, tag_script_double, tag_script_single,
    // Values from fence onward encode (length - 3) * 2 plus the tilde bit.
    fence = 32,
    _,
};

pub const Lang = struct {
    line_comment: []const u8 = "",
    hash_boundary: enum { anywhere, whitespace, shell } = .anywhere,
    block_comment: bool = false,
    /// Python's `"""` and `'''`.
    triple: bool = false,
    /// JS template strings and Go raw strings, which can span lines.
    backtick: bool = false,
    /// Backtick strings take no backslash escapes (Go raw strings).
    raw_backtick: bool = false,
    /// Rust's `'a` lifetimes and `'outer:` labels, which aren't char literals.
    lifetimes: bool = false,
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
    /// Unified diffs: each line is colored by its first character.
    diff: bool = false,
    /// Keywords match in any case (SQL).
    ignore_case: bool = false,
    exts: []const u8 = "",
    keywords: []const u8 = "",
};

inline fn kw(comptime words: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10000);
        var buf: [words.len + 1]u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, words, " \n");
        while (it.next()) |w| {
            buf[n] = @intCast(w.len);
            @memcpy(buf[n + 1 ..][0..w.len], w);
            n += 1 + w.len;
        }
        const out = buf[0..n].*;
        return &out;
    }
}

fn hasWord(packed_words: []const u8, w: []const u8, ignore_case: bool) bool {
    var i: usize = 0;
    while (i < packed_words.len) {
        const len = packed_words[i];
        const word = packed_words[i + 1 ..][0..len];
        if (len == w.len and (if (ignore_case) std.ascii.eqlIgnoreCase(word, w) else std.mem.eql(u8, word, w))) return true;
        i += 1 + len;
    }
    return false;
}

pub const plain: Lang = .{};

const zig: Lang = .{ .line_comment = "//", .line_string = "\\\\", .names = true, .exts = kw("zig zon"), .keywords = kw(
    "const var fn pub return if else while for switch break continue defer errdefer try catch orelse " ++
    "and or struct enum union error comptime inline export extern test unreachable null undefined true " ++
    "false opaque packed align callconv noreturn anytype anyerror type void bool threadlocal volatile " ++
    "allowzero noalias linksection usize isize u8 u16 u32 u64 i32 i64 f32 f64",
) };

const c_like: Lang = .{ .line_comment = "//", .block_comment = true, .names = true, .exts = kw("c h cc cpp hpp m mm java kt cs"), .keywords = kw(
    "auto break case char const continue default do double else enum extern float for goto if inline " ++
    "int long return short signed sizeof static struct switch typedef union unsigned void volatile " ++
    "while bool true false NULL nullptr class namespace public private protected template typename " ++
    "virtual override new delete this using try catch throw constexpr include define ifdef ifndef " ++
    "endif pragma self nil id final package import extends implements interface var val fun object",
) };

const js: Lang = .{ .line_comment = "//", .block_comment = true, .backtick = true, .names = true, .exts = kw("js mjs cjs jsx ts tsx"), .keywords = kw(
    "break case catch class const continue debugger default delete do else export extends finally for " ++
    "function if import in instanceof let new return super switch this throw try typeof var void while " ++
    "yield async await of true false null undefined interface type enum implements private public " ++
    "protected readonly static as from",
) };

const python: Lang = .{ .line_comment = "#", .triple = true, .names = true, .exts = kw("py"), .keywords = kw(
    "and as assert async await break class continue def del elif else except finally for from global " ++
    "if import in is lambda nonlocal not or pass raise return try while with yield True False None " ++
    "self match case",
) };

const rust: Lang = .{ .line_comment = "//", .block_comment = true, .names = true, .lifetimes = true, .exts = kw("rs"), .keywords = kw(
    "as async await break const continue crate dyn else enum extern false fn for if impl in let loop " ++
    "match mod move mut pub ref return self Self static struct super trait true type unsafe use where while",
) };

const go: Lang = .{ .line_comment = "//", .block_comment = true, .backtick = true, .raw_backtick = true, .names = true, .exts = kw("go"), .keywords = kw(
    "break case chan const continue default defer else fallthrough for func go goto if import " ++
    "interface map package range return select struct switch type var true false nil",
) };

const swift: Lang = .{ .line_comment = "//", .block_comment = true, .names = true, .exts = kw("swift"), .keywords = kw(
    "class struct enum protocol extension func var let if else guard return for in while repeat switch " ++
    "case default break continue import public private internal fileprivate open static self Self init " ++
    "deinit true false nil try throw throws async await some any where",
) };

const shell: Lang = .{ .line_comment = "#", .hash_boundary = .shell, .exts = kw("sh bash zsh zshrc zshenv zprofile bashrc bash_profile profile"), .keywords = kw(
    "if then else elif fi for while until do done case esac function in return export local readonly " ++
    "set unset exit select declare typeset source alias",
) };

const fish: Lang = .{ .line_comment = "#", .hash_boundary = .shell, .exts = kw("fish"), .keywords = kw("if else end for in while switch case function begin return break continue and or not set set_color status source exit") };
const ruby: Lang = .{ .line_comment = "#", .names = true, .exts = kw("rb"), .keywords = kw("def end if elsif else unless while until for in do return class module self nil true false yield begin rescue ensure require") };
const lua: Lang = .{ .line_comment = "--", .names = true, .exts = kw("lua"), .keywords = kw("and break do else elseif end false for function if in local nil not or repeat return then true until while") };

const sql: Lang = .{ .line_comment = "--", .block_comment = true, .ignore_case = true, .exts = kw("sql"), .keywords = kw(
    "select from where and or not in is null as on join left right inner outer full cross group by " ++
    "order having limit offset insert into values update set delete create table view index drop alter " ++
    "add column primary key foreign references unique default distinct union all case when then else " ++
    "end exists between like asc desc with returning begin commit rollback transaction if true false " ++
    "integer int text varchar boolean real blob date timestamp trigger constraint check",
) };

const php: Lang = .{ .line_comment = "//", .block_comment = true, .names = true, .exts = kw("php"), .keywords = kw(
    "abstract and array as break case catch class clone const continue declare default do echo else " ++
    "elseif empty enum extends final finally fn for foreach function global if implements include " ++
    "include_once instanceof interface isset list match namespace new or print private protected " ++
    "public readonly require require_once return static switch throw trait try unset use var while " ++
    "yield true false null self parent this php",
) };

const dart: Lang = .{ .line_comment = "//", .block_comment = true, .triple = true, .names = true, .exts = kw("dart"), .keywords = kw(
    "abstract as assert async await break case catch class const continue covariant default deferred " ++
    "do dynamic else enum export extends extension external factory false final finally for Function " ++
    "get hide if implements import in interface is late library mixin new null on operator part " ++
    "required rethrow return sealed set show static super switch sync this throw true try typedef var " ++
    "void when while with yield",
) };

const diff: Lang = .{ .diff = true, .exts = kw("diff patch") };
const data: Lang = .{ .keys = true, .exts = kw("json jsonl ndjson"), .keywords = kw("true false null") };
const hash_data: Lang = .{ .line_comment = "#", .hash_boundary = .whitespace, .keys = true, .exts = kw("yaml yml ini conf gitignore gitattributes env"), .keywords = kw("true false null") };
const toml: Lang = .{ .line_comment = "#", .keys = true, .exts = kw("toml"), .keywords = kw("true false null") };
const css: Lang = .{ .block_comment = true, .keys = true, .exts = kw("css") };
const markdown: Lang = .{ .markdown = true, .exts = kw("md markdown") };
const html: Lang = .{ .html = true, .exts = kw("html htm xhtml xml svg plist") };

/// The languages a user can pick by hand, by name. Several names share a
/// family's table (C, C++ and Java all lex as C).
pub const languages = [_]struct { name: []const u8, lang: *const Lang }{
    .{ .name = "Plain Text", .lang = &plain },  .{ .name = "C", .lang = &c_like },
    .{ .name = "C++", .lang = &c_like },        .{ .name = "C#", .lang = &c_like },
    .{ .name = "CSS", .lang = &css },           .{ .name = "Dart", .lang = &dart },
    .{ .name = "Diff", .lang = &diff },         .{ .name = "Fish", .lang = &fish },
    .{ .name = "Go", .lang = &go },             .{ .name = "HTML", .lang = &html },
    .{ .name = "INI", .lang = &hash_data },     .{ .name = "Java", .lang = &c_like },
    .{ .name = "JavaScript", .lang = &js },     .{ .name = "JSON", .lang = &data },
    .{ .name = "Kotlin", .lang = &c_like },     .{ .name = "Lua", .lang = &lua },
    .{ .name = "Markdown", .lang = &markdown }, .{ .name = "Objective-C", .lang = &c_like },
    .{ .name = "PHP", .lang = &php },           .{ .name = "Python", .lang = &python },
    .{ .name = "Ruby", .lang = &ruby },         .{ .name = "Rust", .lang = &rust },
    .{ .name = "Shell", .lang = &shell },       .{ .name = "SQL", .lang = &sql },
    .{ .name = "Swift", .lang = &swift },       .{ .name = "TOML", .lang = &toml },
    .{ .name = "TypeScript", .lang = &js },     .{ .name = "XML", .lang = &html },
    .{ .name = "YAML", .lang = &hash_data },    .{ .name = "Zig", .lang = &zig },
};

/// The language for a Markdown code fence info string, in any case.
pub fn forFence(hint: []const u8) *const Lang {
    for (languages) |l| if (std.ascii.eqlIgnoreCase(l.name, hint) or hasWord(l.lang.exts, hint, true)) return l.lang;
    const aliases = comptime [_]struct { []const u8, *const Lang }{
        .{ "console", &shell }, .{ "golang", &go }, .{ "objc", &c_like }, .{ "csharp", &c_like }, .{ "jsonc", &data },
    };
    for (aliases) |a| if (std.ascii.eqlIgnoreCase(a[0], hint)) return a[1];
    return &plain;
}

/// The first name in `languages` for `lang`'s family.
pub fn nameOf(lang: *const Lang) []const u8 {
    for (languages) |l| if (l.lang == lang) return l.name;
    return "Plain Text";
}

/// The language a file's first line names: a `#!` interpreter (through
/// `env` too, with versions like `python3.12` dropped) or `<?php`/`<?xml`.
pub fn forHeader(first_line: []const u8) ?*const Lang {
    if (std.mem.startsWith(u8, first_line, "<?php")) return &php;
    if (std.mem.startsWith(u8, first_line, "<?xml")) return &html;
    if (!std.mem.startsWith(u8, first_line, "#!")) return null;
    var words = std.mem.tokenizeAny(u8, first_line[2..], " \t\r");
    var prog = std.fs.path.basename(words.next() orelse return null);
    if (std.mem.eql(u8, prog, "env")) {
        while (words.next()) |w| {
            if (w[0] == '-' or std.mem.indexOfScalar(u8, w, '=') != null) continue;
            prog = std.fs.path.basename(w);
            break;
        } else return null;
    }
    var end = prog.len;
    while (end > 0 and (std.ascii.isDigit(prog[end - 1]) or prog[end - 1] == '.')) end -= 1;
    const name = prog[0..end];
    const table = comptime [_]struct { []const u8, *const Lang }{
        .{ kw("sh bash zsh dash ksh"), &shell }, .{ kw("node deno bun"), &js }, .{ kw("fish"), &fish }, .{ kw("python"), &python },
        .{ kw("ruby"), &ruby },                  .{ kw("lua"), &lua },          .{ kw("php"), &php },   .{ kw("dart"), &dart },
    };
    for (table) |e| if (hasWord(e[0], name, false)) return e[1];
    return null;
}

/// `forPath`, falling back to `forHeader` for files their name doesn't place.
pub fn detect(path: []const u8, first_line: []const u8) *const Lang {
    const by_path = forPath(path);
    if (by_path != &plain) return by_path;
    return forHeader(first_line) orelse &plain;
}

pub fn forPath(path: []const u8) *const Lang {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "Makefile") or std.mem.eql(u8, base, "Dockerfile")) return &hash_data;
    if (std.mem.startsWith(u8, base, ".env.")) return &hash_data;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return &plain;
    const ext = base[dot + 1 ..];
    for (languages) |l| if (hasWord(l.lang.exts, ext, false)) return l.lang;
    return &plain;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// Whether lexing a line can change the next line's incoming state.
pub fn needsState(lang: *const Lang) bool {
    return lang.block_comment or lang.triple or lang.backtick or lang.markdown or lang.html;
}

pub const Sync = struct {
    from: usize,
    end: usize,
    shift_at: usize = 0,
    delta: ?isize = null,
};

/// Repairs cached line-start states, preserving shifted suffix states when a
/// single line-count delta is known. Stateless languages need no cache.
pub fn syncStatesShift(gpa: std.mem.Allocator, lang: *const Lang, b: *Buffer, states: *std.ArrayList(State), upto: usize) !Sync {
    const first = b.touched;
    var res: Sync = .{ .from = first, .end = std.math.maxInt(usize) };
    const stateful = needsState(lang);
    if (!stateful) {
        states.clearAndFree(gpa);
        if (!b.lines_shifted) {
            if (first != std.math.maxInt(usize)) res.end = b.touched_end;
        } else if (b.line_delta) |delta| {
            if (b.shift_at == first) {
                res.shift_at = first;
                res.delta = delta;
                res.end = b.touched_end;
            }
        }
    } else if (first < states.items.len) {
        var converge = !b.lines_shifted;
        if (b.lines_shifted) {
            if (b.line_delta) |delta| if (b.shift_at == first and first + 1 < states.items.len) {
                if (delta > 0) {
                    @memset(try states.addManyAt(gpa, first + 1, @intCast(delta)), .normal);
                } else if (delta < 0) {
                    states.replaceRangeAssumeCapacity(first + 1, @min(@as(usize, @intCast(-delta)), states.items.len - (first + 1)), &.{});
                }
                res.shift_at = first;
                res.delta = delta;
                converge = true;
            };
            if (!converge) states.shrinkRetainingCapacity(first + 1);
        }
        if (converge) {
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
                    res.end = i + 1;
                    break;
                }
            }
        }
    }
    // Leave pending invalidation intact if extending the cache fails.
    if (stateful) {
        if (states.items.len == 0) try states.append(gpa, .normal);
        while (states.items.len <= upto and states.items.len < b.lines()) {
            const i = states.items.len - 1;
            try states.append(gpa, lexLine(lang, b.line(i), states.items[i], null));
        }
    }
    b.touched = std.math.maxInt(usize);
    b.touched_end = 0;
    b.lines_shifted = false;
    b.line_delta = null;
    return res;
}

fn staysNormal(lang: *const Lang, s: []const u8) bool {
    if (lang.block_comment and std.mem.indexOf(u8, s, "/*") != null) return false;
    if (lang.triple and (std.mem.indexOf(u8, s, "\"\"\"") != null or std.mem.indexOf(u8, s, "'''") != null)) return false;
    if (lang.backtick and std.mem.indexOfScalar(u8, s, '`') != null) return false;
    return true;
}

/// Lexes one line that begins in `state`, writing a kind per byte into
/// `out` when given, and returns the state the next line begins in.
pub fn lexLine(lang: *const Lang, s: []const u8, state: State, out: ?[]Kind) State {
    if (lang.markdown) return lexMarkdown(s, state, out);
    if (lang.html) return lexHtml(s, state, out);
    if (lang.diff) {
        mark(out, 0, s.len, diffKind(s));
        return .normal;
    }
    if (out == null and state == .normal and staysNormal(lang, s)) return .normal;
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
                const e = if (st == .backtick and lang.raw_backtick) std.mem.indexOfPos(u8, s, i, close) else findClose(s, i, close);
                if (e) |at| {
                    i = at + close.len;
                    st = .normal;
                } else i = s.len;
            },
            else => {
                const c = s[i];
                const rest = s[i..];
                if (lang.line_comment.len > 0 and std.mem.startsWith(u8, rest, lang.line_comment) and
                    (lang.line_comment[0] != '#' or hashBoundary(lang, s, i)))
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
                } else if (c == '\'' and lang.lifetimes and isLifetime(s, i)) {
                    i += 1;
                } else if (c == '"' or (c == '\'' and lang != &plain)) {
                    if (findClose(s, i + 1, s[i .. i + 1])) |e| {
                        i = e + 1;
                        var j = i;
                        while (j < s.len and s[j] == ' ') j += 1;
                        kind = if (lang.keys and j < s.len and s[j] == ':') .function else .string;
                    } else {
                        kind = .string;
                        i = s.len;
                    }
                } else if (std.ascii.isDigit(c) and (i == 0 or !isWord(s[i - 1]))) {
                    kind = .number;
                    while (i < s.len and (isWord(s[i]) or s[i] == '.')) i += 1;
                } else if (isWord(c) or c == '@') {
                    i += 1;
                    while (i < s.len and isWord(s[i])) i += 1;
                    if (out != null) {
                        if (c == '@' or hasWord(lang.keywords, s[start..i], lang.ignore_case)) {
                            kind = .keyword;
                        } else if (lang.names) kind = nameKind(s[start..i], s, i);
                    }
                } else i += 1;
            },
        }
        mark(out, start, i, kind);
    }
    return st;
}

fn hashBoundary(lang: *const Lang, s: []const u8, i: usize) bool {
    if (lang.hash_boundary == .anywhere or i == 0) return true;
    const prev = s[i - 1];
    const whitespace = prev == ' ' or prev == '\t';
    if (lang.hash_boundary == .whitespace) return whitespace;
    if (!whitespace and std.mem.indexOfScalar(u8, ";|&()<>", prev) == null) return false;
    var start = i - 1;
    while (start > 0 and s[start - 1] == '\\') start -= 1;
    return ((i - 1 - start) & 1) == 0;
}

fn mark(out: ?[]Kind, from: usize, to: usize, kind: Kind) void {
    if (out) |o| @memset(o[from..to], kind);
}

/// A diff line's color: file headers as keywords, hunk headers as
/// functions, added lines as strings, removed ones as numbers and
/// `\ No newline` notes as comments.
fn diffKind(s: []const u8) Kind {
    var it = std.mem.tokenizeScalar(u8, "+++ |--- |diff |index |new file|deleted file|similarity|rename |old mode|new mode", '|');
    while (it.next()) |h| if (std.mem.startsWith(u8, s, h)) return .keyword;
    if (std.mem.startsWith(u8, s, "@@")) return .function;
    if (s.len == 0) return .text;
    return switch (s[0]) {
        '+' => .string,
        '-' => .number,
        '\\' => .comment,
        else => .text,
    };
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
    if (out == null) return 0;
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
    var run: usize = 0;
    if (i <= 3 and rest.len > 0 and (rest[0] == '`' or rest[0] == '~')) {
        while (run < rest.len and rest[run] == rest[0]) run += 1;
    }
    const encoded = @backingInt(state);
    const fence_base = @backingInt(State.fence);
    if (encoded >= fence_base) {
        mark(out, 0, s.len, .string);
        const fence = encoded - fence_base;
        const delimiter: u8 = if ((fence & 1) == 0) '`' else '~';
        const closes = run >= fence / 2 + 3 and rest[0] == delimiter and
            std.mem.trim(u8, rest[run..], " \t\r").len == 0;
        return if (closes) .normal else state;
    }
    if (run >= 3 and (rest[0] == '~' or std.mem.indexOfScalar(u8, rest[run..], '`') == null)) {
        mark(out, 0, s.len, .string);
        return @fromBackingInt(fence_base + (run - 3) * 2 + @as(usize, @intFromBool(rest[0] == '~')));
    }
    if (out == null) return .normal;
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
    var bracket: usize = 0;
    var paren: usize = 0;
    while (p < s.len) {
        const end: ?usize = switch (s[p]) {
            '`' => if (std.mem.indexOfScalarPos(u8, s, p + 1, '`')) |e| blk: {
                mark(out, p, e + 1, .string);
                break :blk e + 1;
            } else null,
            '[' => link(s, p, &bracket, &paren, out),
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

/// Cached delimiter positions advance monotonically, even for failed links.
fn link(s: []const u8, p: usize, bracket: *usize, paren: *usize, out: ?[]Kind) ?usize {
    if (bracket.* <= p) bracket.* = std.mem.indexOfScalarPos(u8, s, p + 1, ']') orelse s.len;
    const e = bracket.*;
    if (e == s.len or e + 1 >= s.len or s[e + 1] != '(') return null;
    if (paren.* <= e + 1) paren.* = std.mem.indexOfScalarPos(u8, s, e + 2, ')') orelse s.len;
    const q = paren.*;
    if (q == s.len) return null;
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
        .tag_double, .tag_single, .tag_style_double, .tag_style_single, .tag_script_double, .tag_script_single => {
            const quote: u8 = switch (st) {
                .tag_double, .tag_style_double, .tag_script_double => '"',
                else => '\'',
            };
            const e = std.mem.indexOfScalarPos(u8, s, i, quote);
            const end = if (e) |at| at + 1 else s.len;
            mark(out, i, end, .string);
            i = end;
            if (e != null) st = switch (st) {
                .tag_style_double, .tag_style_single => .tag_style,
                .tag_script_double, .tag_script_single => .tag_script,
                else => .tag,
            };
        },
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
                mark(out, i, i + 4, .comment);
                i += 4;
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
            const self_closing = i > 0 and s[i - 1] == '/';
            st.* = if (self_closing) .normal else switch (st.*) {
                .tag_style => .style,
                .tag_script => .script,
                else => .normal,
            };
            return i + 1;
        } else if (c == '"' or c == '\'') {
            const close = std.mem.indexOfScalarPos(u8, s, i + 1, c);
            const e = if (close) |x| x + 1 else s.len;
            mark(out, i, e, .string);
            i = e;
            if (close == null) st.* = switch (st.*) {
                .tag_style => if (c == '"') .tag_style_double else .tag_style_single,
                .tag_script => if (c == '"') .tag_script_double else .tag_script_single,
                else => if (c == '"') .tag_double else .tag_single,
            };
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
        if (!std.ascii.startsWithIgnoreCase(s[at + 2 ..], name)) continue;
        const end = at + 2 + name.len;
        if (end == s.len or s[end] == '>' or s[end] == '/' or
            std.mem.indexOfScalar(u8, " \t\r\n\x0c", s[end]) != null) return at;
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

/// Whether the `'` at `i` starts a lifetime or label (`'a`, `'static`)
/// rather than a char literal (`'a'`, `'\n'`, `'é'`).
fn isLifetime(s: []const u8, i: usize) bool {
    if (i + 1 >= s.len or !isWord(s[i + 1])) return false;
    const n = std.unicode.utf8ByteSequenceLength(s[i + 1]) catch 1;
    return i + 1 + n >= s.len or s[i + 1 + n] != '\'';
}

test "rust lifetimes, go raw backslashes and css single quotes" {
    var k: [40]Kind = undefined;
    _ = lexLine(&rust, "fn f<'a>(x: &'a str, c: 'b')", .normal, &k);
    try t.expectEqual(Kind.text, k[9]);
    try t.expectEqual(Kind.string, k[24]);
    try t.expectEqual(State.normal, lexLine(&go, "re := `\\d+\\` + x", .normal, &k));
    try t.expectEqual(Kind.string, k[11]);
    try t.expectEqual(Kind.text, k[15]);
    _ = lexLine(&css, "a { font: 'Inter'; }", .normal, &k);
    try t.expectEqual(Kind.string, k[10]);
}

const t = std.testing;

test "new languages: sql keywords in any case, diff lines, names and headers" {
    var k: [32]Kind = undefined;
    _ = lexLine(&sql, "SELECT a -- x", .normal, &k);
    try t.expectEqual(Kind.keyword, k[0]);
    try t.expectEqual(Kind.comment, k[10]);
    _ = lexLine(&diff, "--- a/x", .normal, &k);
    try t.expectEqual(Kind.keyword, k[0]);
    _ = lexLine(&diff, "-old", .normal, &k);
    try t.expectEqual(Kind.number, k[1]);
    _ = lexLine(&diff, "+new", .normal, &k);
    try t.expectEqual(Kind.string, k[1]);
    try t.expectEqual(&hash_data, forPath("/r/.gitignore"));
    try t.expectEqual(&hash_data, forPath(".env.local"));
    try t.expectEqual(&diff, forPath("a.patch"));
    try t.expectEqual(&python, forHeader("#!/usr/bin/env python3.12").?);
    try t.expectEqual(&js, forHeader("#!/usr/bin/env -S node --x").?);
    try t.expectEqual(&shell, forHeader("#!/bin/bash -e").?);
    try t.expectEqual(@as(?*const Lang, null), forHeader("#!/usr/bin/env"));
    try t.expectEqual(&ruby, detect("bin/tool", "#!/usr/bin/env ruby"));
    try t.expectEqual(&rust, detect("a.rs", "#!/bin/sh"));
    inline for (.{ .{ "sql", &sql }, .{ "C++", &c_like }, .{ "C#", &c_like }, .{ "csharp", &c_like }, .{ "py", &python }, .{ "golang", &go }, .{ "jsonc", &data }, .{ "console", &shell }, .{ "objc", &c_like }, .{ "unknown", &plain } }) |c| {
        try t.expectEqual(c[1], forFence(c[0]));
    }
    try t.expectEqualStrings("C", nameOf(&c_like));
}

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
    try t.expectEqual(State.html_comment, lexLine(&html, "<!--> <b>", .normal, &k));
    try t.expectEqual(Kind.comment, k[7]);
    try t.expectEqual(State.html_comment, lexLine(&html, "<!---> a", .normal, &k));
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
    try t.expectEqual(State.normal, lexLine(&html, "<script src=\"a.js\"/> <b>", .normal, &k));
    try t.expectEqual(Kind.keyword, k[22]);
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
    if (b.lines_shifted) b.line_delta = null;
    const sync = try syncStatesShift(t.allocator, lang, b, states, b.lines() - 1);
    const invalid = [2]usize{ sync.from, sync.end };
    if (!needsState(lang)) {
        try t.expectEqual(@as(usize, 0), states.items.len);
        try t.expectEqual(@as(usize, 0), states.capacity);
    }
    // A line-count change may move all later rows; discard those old slots.
    if (cached.items.len != b.lines()) {
        for (cached.items) |k| t.allocator.free(k);
        cached.clearRetainingCapacity();
        for (0..b.lines()) |_| try cached.append(t.allocator, try t.allocator.alloc(Kind, 0));
    }
    var state: State = .normal;
    for (0..b.lines()) |i| {
        const line = b.line(i);
        const incoming: State = if (needsState(lang)) states.items[i] else .normal;
        if (i >= invalid[0] and i < invalid[1]) {
            t.allocator.free(cached.items[i]);
            cached.items[i] = try t.allocator.alloc(Kind, line.len);
            _ = lexLine(lang, line, incoming, cached.items[i]);
        }
        const scratch = try t.allocator.alloc(Kind, line.len);
        defer t.allocator.free(scratch);
        try t.expectEqual(state, incoming);
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
        .{ &shell, "echo first\n# comment\necho $#\necho 'text'\nexport X=1\nlast" },
        .{ &fish, "echo first\n# comment\nset x 1\necho 'text'\nend\nlast" },
        .{ &ruby, "def first\n# comment\nvalue = 1\nputs 'text'\nend\nlast" },
        .{ &lua, "local first\n-- comment\nvalue = 1\nprint('text')\nend\nlast" },
        .{ &diff, "diff a b\n@@ header\n+added\n-removed\n same\nlast" },
        .{ &data, "{\n\"key\": 1,\n\"yes\": true,\n\"text\": \"value\"\n}\nlast" },
        .{ &hash_data, "key: value\n# comment\nyes: true\ntext: 'value'\nnext: 2\nlast" },
        .{ &toml, "[section]\n# comment\nyes = true\ntext = 'value'\nnext = 2\nlast" },
        .{ &markdown, "before\n```\ninside\n```\nafter\nlast" },
        .{ &markdown, "before\n~~~~\ninside\n~~~~\nafter\nlast" },
        .{ &markdown, "before\n````\ninside\n````\nafter\nlast" },
        .{ &html, "<p>\n<!-- start\ninside\nend -->\n<p>\n<p>" },
        .{ &html, "<p>\n<script>\nlet a = 1;\n</script>\n<p>\n<p>" },
        .{ &html, "<p>\n<div title=\"start\ninside\nend\">\n<p>\n<p>" },
        .{ &html, "<p>\n<script title='start\ninside\nend'></script>\n<p>\n<p>" },
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

test "syncStatesShift converges on Return and Backspace-join" {
    var b = try Buffer.init(t.allocator, "int a;\n/* open\ninside\nclose */\nint b;\nint c;");
    defer b.deinit(t.allocator);
    var states: std.ArrayList(State) = .empty;
    defer states.deinit(t.allocator);

    _ = try syncStatesShift(t.allocator, &c_like, &b, &states, b.lines() - 1);

    // Return outside multiline region converges at line 2 with delta = +1.
    const e0 = b.lineEnd(0);
    try b.replace(t.allocator, e0, e0, "\n", e0, false);
    const r1 = try syncStatesShift(t.allocator, &c_like, &b, &states, b.lines() - 1);
    try t.expectEqual(Sync{ .from = 0, .end = 2, .shift_at = 0, .delta = 1 }, r1);

    // Return inside block comment propagates .block_comment and converges at line 5.
    const e3 = b.lineEnd(3);
    try b.replace(t.allocator, e3, e3, "\n", e3, false);
    const r2 = try syncStatesShift(t.allocator, &c_like, &b, &states, b.lines() - 1);
    try t.expectEqual(Sync{ .from = 3, .end = 5, .shift_at = 3, .delta = 1 }, r2);
    try t.expectEqual(State.block_comment, states.items[4]);

    // Backspace-join inside block comment converges at line 4 with delta = -1.
    try b.replace(t.allocator, e3, e3 + 1, "", e3 + 1, false);
    const r3 = try syncStatesShift(t.allocator, &c_like, &b, &states, b.lines() - 1);
    try t.expectEqual(Sync{ .from = 3, .end = 4, .shift_at = 3, .delta = -1 }, r3);

    // Backspace-join on line 0 converges at line 1 with delta = -1.
    try b.replace(t.allocator, e0, e0 + 1, "", e0 + 1, false);
    const r4 = try syncStatesShift(t.allocator, &c_like, &b, &states, b.lines() - 1);
    try t.expectEqual(Sync{ .from = 0, .end = 1, .shift_at = 0, .delta = -1 }, r4);

    // Verify every cached line state matches a full fresh lex.
    var st: State = .normal;
    for (0..b.lines()) |i| {
        try t.expectEqual(st, states.items[i]);
        st = lexLine(&c_like, b.line(i), st, null);
    }

    // Two stacked Returns clear line_delta and fall back to suffix invalidation.
    try b.replace(t.allocator, e0, e0, "\n", e0, false);
    try b.replace(t.allocator, e0 + 1, e0 + 1, "\n", e0 + 1, false);
    const r5 = try syncStatesShift(t.allocator, &c_like, &b, &states, b.lines() - 1);
    try t.expectEqual(Sync{ .from = 0, .end = std.math.maxInt(usize), .shift_at = 0, .delta = null }, r5);
}

test "state-only lexLine and lexMarkdown match full lexing" {
    var scratch: [128]Kind = undefined;
    const cases = .{
        .{ &c_like, State.normal, "int x = 1; // /* ignored" },
        .{ &c_like, State.normal, "int x = 1; /* start" },
        .{ &c_like, State.block_comment, "still comment */ int y = 2;" },
        .{ &css, State.normal, "  color: red;" },
        .{ &css, State.normal, "  color: /* open" },
        .{ &python, State.normal, "x = '''multi" },
        .{ &js, State.normal, "const s = `tmpl" },
        .{ &markdown, State.normal, "## heading with `code` and **bold**" },
        .{ &markdown, State.normal, "```zig" },
        .{ &markdown, State.fence, "inside" },
        .{ &markdown, State.fence, "```" },
    };
    inline for (cases) |c| {
        const full = lexLine(c[0], c[2], c[1], scratch[0..c[2].len]);
        const fast = lexLine(c[0], c[2], c[1], null);
        try t.expectEqual(full, fast);
    }
}

test "unfinished strings consume their line without opening comments" {
    var k: [128]Kind = undefined;
    inline for (.{ &c_like, &js, &python, &ruby, &toml, &zig }) |lang| {
        inline for (.{ "\"a\\\" /* # // `", "'a\\' /* # // `" }) |line| {
            try t.expectEqual(State.normal, lexLine(lang, line, .normal, &k));
            try t.expectEqual(State.normal, lexLine(lang, line, .normal, null));
            for (k[0..line.len]) |kind| try t.expectEqual(Kind.string, kind);
        }
    }
    var line: [8193]u8 = undefined;
    var kinds: [line.len]Kind = undefined;
    line[0] = '"';
    var i: usize = 1;
    while (i < line.len) : (i += 2) @memcpy(line[i..][0..2], "\\\"");
    try t.expectEqual(State.normal, lexLine(&js, &line, .normal, &kinds));
    try t.expectEqual(State.normal, lexLine(&js, &line, .normal, null));
    for (kinds) |kind| try t.expectEqual(Kind.string, kind);
}

test "markdown failed bracket candidates preserve later inline markup" {
    inline for (.{ " `x` **y**", "]( `x` **y**", "] nope [ok](url) `x` **y**" }) |tail| {
        var line: [8192 + tail.len]u8 = undefined;
        var kinds: [line.len]Kind = undefined;
        @memset(line[0..8192], '[');
        @memcpy(line[8192..], tail);
        try t.expectEqual(State.normal, lexLine(&markdown, &line, .normal, &kinds));
        try t.expectEqual(State.normal, lexLine(&markdown, &line, .normal, null));
        const code = std.mem.indexOf(u8, &line, "`x`").?;
        try t.expectEqual(Kind.string, kinds[code]);
        try t.expectEqual(Kind.keyword, kinds[line.len - 3]);
        if (std.mem.indexOf(u8, &line, "[ok]")) |at| try t.expectEqual(Kind.function, kinds[at]);
    }
}

test "html quoted attributes retain quote and tag destination across lines" {
    var k: [64]Kind = undefined;
    const cases = .{
        .{ "<div title=\"first", State.tag_double, "\">", State.normal },
        .{ "<div title='first", State.tag_single, "'>", State.normal },
        .{ "<style title=\"first", State.tag_style_double, "\">", State.style },
        .{ "<style title='first", State.tag_style_single, "'>", State.style },
        .{ "<script title=\"first", State.tag_script_double, "\">", State.script },
        .{ "<script title='first", State.tag_script_single, "'>", State.script },
    };
    inline for (cases) |case| {
        try t.expectEqual(case[1], lexLine(&html, case[0], .normal, &k));
        try t.expectEqual(case[1], lexLine(&html, case[0], .normal, null));
        inline for (.{ "", "more > text", "</script> <!--" }) |line| {
            try t.expectEqual(case[1], lexLine(&html, line, case[1], &k));
            try t.expectEqual(case[1], lexLine(&html, line, case[1], null));
            for (k[0..line.len]) |kind| try t.expectEqual(Kind.string, kind);
        }
        try t.expectEqual(case[3], lexLine(&html, case[2], case[1], &k));
        try t.expectEqual(case[3], lexLine(&html, case[2], case[1], null));
        try t.expectEqual(Kind.string, k[0]);
        try t.expectEqual(Kind.text, k[1]);
    }
    try t.expectEqual(State.normal, lexLine(&html, "\">body</div>", .tag_double, &k));
    try t.expectEqual(Kind.text, k[2]);
    try t.expectEqual(Kind.keyword, k[8]);
    try t.expectEqual(State.script, lexLine(&html, "\">const x = 1;", .tag_script_double, &k));
    try t.expectEqual(Kind.keyword, k[2]);
}

test "html embedded closing tags require a complete name boundary" {
    var k: [64]Kind = undefined;
    inline for (.{ .{ State.script, "script" }, .{ State.style, "style" } }) |case| {
        inline for (.{ "ure>", "-extra>", ":extra>", "0>" }) |suffix| {
            const line = "</" ++ case[1] ++ suffix;
            try t.expectEqual(case[0], lexLine(&html, line, case[0], &k));
            try t.expectEqual(case[0], lexLine(&html, line, case[0], null));
        }
        inline for (.{ ">", " />", "\t>", "\x0c>" }) |suffix| {
            const line = "</" ++ case[1] ++ suffix;
            try t.expectEqual(State.normal, lexLine(&html, line, case[0], &k));
            try t.expectEqual(State.normal, lexLine(&html, line, case[0], null));
            try t.expectEqual(Kind.keyword, k[2]);
        }
        const split = "</" ++ case[1];
        try t.expectEqual(State.tag, lexLine(&html, split, case[0], &k));
        try t.expectEqual(State.tag, lexLine(&html, split, case[0], null));
    }
    try t.expectEqual(State.normal, lexLine(&html, "</scripture></SCRIPT>", .script, &k));
}

test "markdown fences retain delimiter length and require valid closing lines" {
    var k: [64]Kind = undefined;
    inline for (.{ "````lang", "~~~~lang" }) |opener| {
        const state = lexLine(&markdown, opener, .normal, &k);
        try t.expect(state != .normal);
        try t.expectEqual(state, lexLine(&markdown, opener, .normal, null));
        inline for (.{ "", "```", "~~~", "````text", "~~~~text", "    ````", "    ~~~~", "# heading" }) |line| {
            try t.expectEqual(state, lexLine(&markdown, line, state, &k));
            try t.expectEqual(state, lexLine(&markdown, line, state, null));
            for (k[0..line.len]) |kind| try t.expectEqual(Kind.string, kind);
        }
        const wrong = if (opener[0] == '`') "~~~~~" else "`````";
        try t.expectEqual(state, lexLine(&markdown, wrong, state, &k));
        try t.expectEqual(state, lexLine(&markdown, wrong, state, null));
        const close = if (opener[0] == '`') "   ````` \t\r" else "   ~~~~~ \t\r";
        try t.expectEqual(State.normal, lexLine(&markdown, close, state, &k));
        try t.expectEqual(State.normal, lexLine(&markdown, close, state, null));
    }
    inline for (.{ "    ```", "```bad`info" }) |line| {
        try t.expectEqual(State.normal, lexLine(&markdown, line, .normal, &k));
        try t.expectEqual(State.normal, lexLine(&markdown, line, .normal, null));
    }
    try t.expect(lexLine(&markdown, "~~~", .normal, null) != State.fence);
}

test "hash comments use each language boundary" {
    var k: [64]Kind = undefined;
    inline for (.{ &python, &ruby, &toml }) |lang| {
        const line = "x=1#comment";
        try t.expectEqual(State.normal, lexLine(lang, line, .normal, &k));
        try t.expectEqual(State.normal, lexLine(lang, line, .normal, null));
        try t.expectEqual(Kind.comment, k[3]);
        _ = lexLine(lang, "\"#string\" #comment", .normal, &k);
        try t.expectEqual(Kind.string, k[1]);
        try t.expectEqual(Kind.comment, k[10]);
    }
    _ = lexLine(forPath("a.yaml"), "key: value#scalar #comment", .normal, &k);
    try t.expectEqual(Kind.text, k[10]);
    try t.expectEqual(Kind.comment, k[18]);
    inline for (.{ &shell, &fish }) |lang| {
        _ = lexLine(lang, "echo $# foo#bar;#comment", .normal, &k);
        try t.expectEqual(Kind.text, k[6]);
        try t.expectEqual(Kind.text, k[11]);
        try t.expectEqual(Kind.comment, k[16]);
    }
    try t.expectEqual(&toml, forPath("a.toml"));
    try t.expectEqual(&toml, forFence("TOML"));
}

test "shell hash boundaries respect odd and even backslash runs" {
    var line: [64]u8 = undefined;
    var kinds: [64]Kind = undefined;
    const prefix = "echo foo";
    const tail = "#bar; echo next";
    @memcpy(line[0..prefix.len], prefix);
    inline for (.{ &shell, &fish }) |lang| {
        for (";|&()<> \t") |separator| {
            for (0..6) |slashes| {
                const boundary = prefix.len + slashes;
                @memset(line[prefix.len..boundary], '\\');
                line[boundary] = separator;
                @memcpy(line[boundary + 1 ..][0..tail.len], tail);
                const text = line[0 .. boundary + 1 + tail.len];
                try t.expectEqual(State.normal, lexLine(lang, text, .normal, &kinds));
                try t.expectEqual(State.normal, lexLine(lang, text, .normal, null));
                const expected: Kind = if ((slashes & 1) == 0) .comment else .text;
                try t.expectEqual(expected, kinds[boundary + 1]);
                try t.expectEqual(expected, kinds[text.len - 1]);
            }
        }
    }
}

test "incremental states notice fence metadata and quoted attribute edits" {
    const cases = .{
        .{ &markdown, "```\ncode\n```\n# after\nlast", "````", "~~~~" },
        .{ &html, "<script title=\"open\nmiddle\n\">const x = 1;\n</script>\nlast", "<script title='open", "<style title='open" },
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
        inline for (.{ case[2], case[3] }) |opener| {
            try b.replace(t.allocator, 0, b.lineEnd(0), opener, 0, false);
            _ = try expectIncremental(case[0], &b, &states, &cached);
            _ = try b.undo(t.allocator);
            _ = try expectIncremental(case[0], &b, &states, &cached);
            _ = try b.redo(t.allocator);
            _ = try expectIncremental(case[0], &b, &states, &cached);
        }
        try b.replace(t.allocator, 0, 0, "before\n", 0, false);
        _ = try expectIncremental(case[0], &b, &states, &cached);
    }
}

test "needsState derives only cross-line lexer features" {
    inline for (.{ &plain, &zig, &shell, &fish, &ruby, &lua, &diff, &data, &hash_data, &toml }) |lang| {
        try t.expect(!needsState(lang));
    }
    inline for (.{ &c_like, &js, &python, &rust, &go, &swift, &sql, &php, &dart, &css, &markdown, &html }) |lang| {
        try t.expect(needsState(lang));
    }
    inline for (.{ "block_comment", "triple", "backtick", "markdown", "html" }) |field| {
        var lang: Lang = .{};
        @field(lang, field) = true;
        try t.expect(needsState(&lang));
    }
}

test "stateless sync preserves invalidation and shifts without allocation" {
    inline for (.{ &plain, &zig, &shell, &fish, &ruby, &lua, &diff, &data, &hash_data, &toml }) |lang| {
        var b = try Buffer.init(t.allocator, "first\nsecond\nthird\nlast");
        defer b.deinit(t.allocator);
        var states: std.ArrayList(State) = .empty;
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
        const gpa = failing.allocator();
        defer states.deinit(gpa);
        const all = std.math.maxInt(usize);

        try t.expectEqual(Sync{ .from = 0, .end = all }, try syncStatesShift(gpa, lang, &b, &states, b.lines() - 1));
        try t.expectEqual(Sync{ .from = all, .end = all }, try syncStatesShift(gpa, lang, &b, &states, 0));
        const p1 = b.lineStart(1);
        try b.replace(t.allocator, p1, p1, "x", p1, false);
        try t.expectEqual(Sync{ .from = 1, .end = 2 }, try syncStatesShift(gpa, lang, &b, &states, 0));

        try b.replace(t.allocator, 0, 0, "x", 0, false);
        const p3 = b.lineStart(3);
        try b.replace(t.allocator, p3, p3, "y", p3, false);
        try t.expectEqual(Sync{ .from = 0, .end = 4 }, try syncStatesShift(gpa, lang, &b, &states, 0));

        const e0 = b.lineEnd(0);
        try b.replace(t.allocator, e0, e0, "\n", e0, false);
        try t.expectEqual(Sync{ .from = 0, .end = 2, .shift_at = 0, .delta = 1 }, try syncStatesShift(gpa, lang, &b, &states, 0));
        try b.replace(t.allocator, e0, e0 + 1, "", e0 + 1, false);
        try t.expectEqual(Sync{ .from = 0, .end = 1, .shift_at = 0, .delta = -1 }, try syncStatesShift(gpa, lang, &b, &states, 0));

        try b.replace(t.allocator, e0, e0, "\n", e0, false);
        try b.replace(t.allocator, e0 + 1, e0 + 1, "\n", e0 + 1, false);
        try t.expectEqual(Sync{ .from = 0, .end = all }, try syncStatesShift(gpa, lang, &b, &states, 0));

        // An earlier edit prevents shifting the whole suffix at touched.
        try b.replace(t.allocator, 0, 0, "x", 0, false);
        const e2 = b.lineEnd(2);
        try b.replace(t.allocator, e2, e2, "\n", e2, false);
        try t.expectEqual(Sync{ .from = 0, .end = all }, try syncStatesShift(gpa, lang, &b, &states, 0));
        try t.expectEqual(@as(usize, 0), states.items.len);
        try t.expectEqual(@as(usize, 0), states.capacity);
        try t.expectEqual(all, b.touched);
        try t.expectEqual(@as(usize, 0), b.touched_end);
        try t.expect(!b.lines_shifted);
        try t.expectEqual(@as(?isize, null), b.line_delta);
    }
}

test "language transitions release stateless caches and refresh token kinds" {
    var b = try Buffer.init(t.allocator, "/* open\nconst x = 1;\n*/\nlast");
    defer b.deinit(t.allocator);
    var states: std.ArrayList(State) = .empty;
    defer states.deinit(t.allocator);
    var cached: std.ArrayList([]Kind) = .empty;
    defer {
        for (cached.items) |k| t.allocator.free(k);
        cached.deinit(t.allocator);
    }
    const cases = .{
        .{ &c_like, Kind.comment },
        .{ &zig, Kind.keyword },
        .{ &data, Kind.text },
        .{ &markdown, Kind.text },
        .{ &shell, Kind.text },
        .{ &html, Kind.text },
        .{ &plain, Kind.text },
        .{ &c_like, Kind.comment },
    };
    inline for (cases) |case| {
        // The language picker invalidates all rows and resets stateful caches.
        if (needsState(case[0])) states.clearRetainingCapacity();
        b.touched = 0;
        b.touched_end = b.lines();
        _ = try expectIncremental(case[0], &b, &states, &cached);
        try t.expectEqual(case[1], cached.items[1][0]);
        if (needsState(case[0])) try t.expect(states.capacity > 0);
    }
}
