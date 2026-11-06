//! Caret, selection and the edit commands, on top of a Buffer. Knows
//! nothing about windows or drawing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;

pub const tab_width = 4;

pub const Motion = enum { left, right, up, down, word_left, word_right, home, end, line_start, top, bottom, page_up, page_down };

pub const Editor = struct {
    buf: Buffer,
    cur: usize = 0,
    anchor: usize = 0,
    /// Display column that up/down try to keep.
    want: ?usize = null,
    /// The last edit was typing, so the next keystroke joins its undo step.
    typing: bool = false,
    indent: []const u8 = "    ",
    eol: []const u8 = "\n",

    pub fn init(gpa: Allocator, bytes: []const u8) !Editor {
        var e: Editor = .{ .buf = try Buffer.init(gpa, bytes) };
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |i| {
            if (i > 0 and bytes[i - 1] == '\r') e.eol = "\r\n";
        }
        if (std.mem.indexOf(u8, bytes, "\n\t") != null and std.mem.indexOf(u8, bytes, "\n    ") == null) e.indent = "\t";
        return e;
    }

    pub fn deinit(e: *Editor, gpa: Allocator) void {
        e.buf.deinit(gpa);
    }

    pub fn text(e: *const Editor) []const u8 {
        return e.buf.text.items;
    }

    pub fn sel(e: *const Editor) [2]usize {
        return .{ @min(e.cur, e.anchor), @max(e.cur, e.anchor) };
    }

    pub fn hasSel(e: *const Editor) bool {
        return e.cur != e.anchor;
    }

    pub fn select(e: *Editor, anchor: usize, cur: usize) void {
        e.anchor = anchor;
        e.cur = cur;
        e.want = null;
        e.typing = false;
    }

    pub fn moveTo(e: *Editor, pos: usize, extend: bool) void {
        e.select(if (extend) e.anchor else pos, pos);
    }

    pub fn move(e: *Editor, m: Motion, extend: bool, page: usize) void {
        const b = &e.buf;
        const t = e.text();
        const row = b.lineOf(e.cur);
        if (!extend and e.hasSel() and (m == .left or m == .right)) {
            const s = e.sel();
            return e.select(s[@intFromBool(m == .right)], s[@intFromBool(m == .right)]);
        }
        const pos: usize = switch (m) {
            .left => if (e.cur == b.lineStart(row) and row > 0) b.lineEnd(row - 1) else prevChar(t, e.cur),
            .right => if (e.cur == b.lineEnd(row) and row + 1 < b.lines()) b.lineStart(row + 1) else nextChar(t, e.cur),
            .word_left => wordLeft(t, e.cur),
            .word_right => wordRight(t, e.cur),
            .home => blk: {
                const ls = b.lineStart(row);
                var nb = ls;
                while (nb < b.lineEnd(row) and (t[nb] == ' ' or t[nb] == '\t')) nb += 1;
                break :blk if (e.cur == nb) ls else nb;
            },
            .line_start => b.lineStart(row),
            .end => b.lineEnd(row),
            .top => 0,
            .bottom => t.len,
            .up, .down, .page_up, .page_down => {
                const col = e.want orelse colOf(b.line(row), e.cur - b.lineStart(row));
                const step: usize = if (m == .up or m == .down) 1 else @max(page, 1);
                const to: usize = if (m == .up or m == .page_up) row -| step else @min(row + step, b.lines() - 1);
                const p = if (to == row and (m == .up or m == .page_up)) 0 else if (to == row) t.len else b.lineStart(to) + byteAtCol(b.line(to), @floatFromInt(col));
                e.moveTo(p, extend);
                e.want = col;
                return;
            },
        };
        e.moveTo(pos, extend);
    }

    /// Replaces the selection with `s`.
    pub fn insert(e: *Editor, gpa: Allocator, s: []const u8) !void {
        const r = e.sel();
        // One typed character, ASCII or not, joins the typing run; a newline
        // starts the next one.
        const one = s.len > 0 and (std.unicode.utf8ByteSequenceLength(s[0]) catch 0) == s.len;
        try e.buf.replace(gpa, r[0], r[1], s, e.cur, e.typing and !e.hasSel() and one and s[0] != '\n');
        e.select(r[0] + s.len, r[0] + s.len);
        e.typing = one;
    }

    /// Newline that keeps the current line's indentation.
    pub fn newline(e: *Editor, gpa: Allocator) !void {
        const t = e.text();
        const ls = e.buf.lineStart(e.buf.lineOf(e.cur));
        var i = ls;
        while (i < e.cur and (t[i] == ' ' or t[i] == '\t')) i += 1;
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(gpa);
        try s.appendSlice(gpa, e.eol);
        try s.appendSlice(gpa, t[ls..i]);
        try e.insert(gpa, s.items);
    }

    pub const Unit = enum { char, word, line };

    pub fn deleteBack(e: *Editor, gpa: Allocator, unit: Unit) !void {
        if (!e.hasSel()) {
            const t = e.text();
            const row = e.buf.lineOf(e.cur);
            const ls = e.buf.lineStart(row);
            e.anchor = switch (unit) {
                .char => if (e.cur == ls and row > 0) e.buf.lineEnd(row - 1) else prevChar(t, e.cur),
                .word => wordLeft(t, e.cur),
                .line => if (e.cur != ls) ls else if (row > 0) e.buf.lineEnd(row - 1) else ls,
            };
        }
        try e.cut(gpa, unit == .char);
    }

    pub fn deleteForward(e: *Editor, gpa: Allocator, unit: Unit) !void {
        if (!e.hasSel()) {
            const t = e.text();
            const row = e.buf.lineOf(e.cur);
            const le = e.buf.lineEnd(row);
            e.anchor = switch (unit) {
                .char => if (e.cur == le and row + 1 < e.buf.lines()) e.buf.lineStart(row + 1) else nextChar(t, e.cur),
                .word => wordRight(t, e.cur),
                .line => if (e.cur != le) le else if (row + 1 < e.buf.lines()) e.buf.lineStart(row + 1) else le,
            };
        }
        try e.cut(gpa, unit == .char);
    }

    /// Deletes the selection.
    fn cut(e: *Editor, gpa: Allocator, join: bool) !void {
        const r = e.sel();
        if (r[0] == r[1]) return;
        try e.buf.replace(gpa, r[0], r[1], "", e.cur, join and e.typing);
        e.select(r[0], r[0]);
        e.typing = join;
    }

    pub fn deleteSelection(e: *Editor, gpa: Allocator) !void {
        try e.cut(gpa, false);
    }

    /// Tab: indents the selected lines, or inserts an indent at the caret.
    pub fn tab(e: *Editor, gpa: Allocator) !void {
        const r = e.sel();
        if (e.buf.lineOf(r[0]) == e.buf.lineOf(r[1])) {
            if (e.indent[0] == '\t') return e.insert(gpa, "\t");
            const col = colOf(e.buf.line(e.buf.lineOf(e.cur)), e.cur - e.buf.lineStart(e.buf.lineOf(e.cur)));
            return e.insert(gpa, "    "[0 .. tab_width - col % tab_width]);
        }
        try e.eachLine(gpa, .indent);
    }

    pub fn outdent(e: *Editor, gpa: Allocator) !void {
        try e.eachLine(gpa, .outdent);
    }

    pub fn toggleComment(e: *Editor, gpa: Allocator, prefix: []const u8) !void {
        if (prefix.len > 0) try e.eachLine(gpa, .{ .comment = prefix });
    }

    const LineOp = union(enum) { indent, outdent, comment: []const u8 };

    /// Rewrites every line the selection touches as one undo step, and
    /// selects the rewritten lines.
    fn eachLine(e: *Editor, gpa: Allocator, op: LineOp) !void {
        const b = &e.buf;
        const r = e.sel();
        const first = b.lineOf(r[0]);
        var last = b.lineOf(r[1]);
        if (last > first and r[1] == b.lineStart(last)) last -= 1;
        const start = b.lineStart(first);
        const end = b.lineEnd(last);
        const t = e.text();

        // Comments go in at the shallowest indent; the toggle removes them only
        // when every non-blank line has one.
        var min_ws: usize = std.math.maxInt(usize);
        var all = true;
        for (first..last + 1) |i| {
            const l = b.line(i);
            const ws = leadingWs(l);
            if (ws == l.len) continue;
            min_ws = @min(min_ws, ws);
            if (op == .comment and !std.mem.startsWith(u8, l[ws..], op.comment)) all = false;
        }
        if (min_ws == std.math.maxInt(usize)) min_ws = 0;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        for (first..last + 1) |i| {
            if (i > first) try out.appendSlice(gpa, t[b.lineEnd(i - 1)..b.lineStart(i)]);
            const l = b.line(i);
            const ws = leadingWs(l);
            switch (op) {
                .indent => {
                    if (l.len > 0) try out.appendSlice(gpa, e.indent);
                    try out.appendSlice(gpa, l);
                },
                .outdent => {
                    var n: usize = 0;
                    if (n < l.len and l[0] == '\t') n = 1 else while (n < l.len and n < tab_width and l[n] == ' ') n += 1;
                    try out.appendSlice(gpa, l[n..]);
                },
                .comment => |p| if (ws == l.len) {
                    try out.appendSlice(gpa, l);
                } else if (all) {
                    var cut_end = ws + p.len;
                    if (cut_end < l.len and l[cut_end] == ' ') cut_end += 1;
                    try out.appendSlice(gpa, l[0..ws]);
                    try out.appendSlice(gpa, l[cut_end..]);
                } else {
                    try out.appendSlice(gpa, l[0..min_ws]);
                    try out.appendSlice(gpa, p);
                    try out.append(gpa, ' ');
                    try out.appendSlice(gpa, l[min_ws..]);
                },
            }
        }
        if (std.mem.eql(u8, out.items, t[start..end])) return;
        try b.replace(gpa, start, end, out.items, e.cur, false);
        e.select(start, start + out.items.len);
    }

    pub fn undo(e: *Editor, gpa: Allocator) !void {
        if (try e.buf.undo(gpa)) |p| e.select(p, p);
    }

    pub fn redo(e: *Editor, gpa: Allocator) !void {
        if (try e.buf.redo(gpa)) |p| e.select(p, p);
    }

    pub fn selectWord(e: *Editor, pos: usize) void {
        const t = e.text();
        var a = pos;
        var z = pos;
        const k = if (pos < t.len) class(t[pos]) else if (pos > 0) class(t[pos - 1]) else return;
        while (a > 0 and t[a - 1] != '\n' and class(t[a - 1]) == k) a -= 1;
        while (z < t.len and t[z] != '\n' and class(t[z]) == k) z += 1;
        e.select(a, z);
    }

    pub fn selectLine(e: *Editor, pos: usize) void {
        const row = e.buf.lineOf(pos);
        e.select(e.buf.lineStart(row), if (row + 1 < e.buf.lines()) e.buf.lineStart(row + 1) else e.text().len);
    }

    pub fn selectAll(e: *Editor) void {
        e.select(0, e.text().len);
    }

    /// Selects the next match of `q` after the selection, or before it when
    /// `back`, wrapping around. False when there is none.
    pub fn find(e: *Editor, q: []const u8, from: usize, back: bool) bool {
        const p = search(e.text(), q, from, back) orelse return false;
        e.select(p, p + q.len);
        return true;
    }

    /// Typing with auto-closing pairs: an opener adds its closer (or wraps
    /// the selection), and a closer steps over the same closer after the caret.
    pub fn typePaired(e: *Editor, gpa: Allocator, s: []const u8) !void {
        if (s.len != 1) return e.insert(gpa, s);
        const t = e.text();
        const c = s[0];
        const next: u8 = if (e.cur < t.len) t[e.cur] else '\n';
        const close = closerOf(c);
        const quote = c == '"' or c == '\'' or c == '`';
        if (!e.hasSel() and (quote or close == null) and isCloser(c) and next == c) {
            return e.moveTo(e.cur + 1, false);
        }
        const pair = close orelse return e.insert(gpa, s);
        if (e.hasSel()) {
            const r = e.sel();
            const inner = try std.mem.concat(gpa, u8, &.{ s, t[r[0]..r[1]], &.{pair} });
            defer gpa.free(inner);
            try e.buf.replace(gpa, r[0], r[1], inner, e.cur, false);
            e.select(r[0] + 1, r[0] + inner.len - 1);
            return;
        }
        const prev: u8 = if (e.cur > 0) t[e.cur - 1] else ' ';
        const open_after = next == ' ' or next == '\t' or next == '\n' or next == '\r' or isCloser(next) or next == ',' or next == ';';
        // A quote after a letter is an apostrophe (it's, don't).
        if (!open_after or (quote and (class(prev) == 0 or prev == c))) return e.insert(gpa, s);
        try e.insert(gpa, &.{ c, pair });
        e.select(e.cur - 1, e.cur - 1);
    }

    /// Backspace between an empty pair deletes both halves. False when the
    /// caret isn't between one.
    pub fn deletePair(e: *Editor, gpa: Allocator) !bool {
        const t = e.text();
        if (e.hasSel() or e.cur == 0 or e.cur >= t.len) return false;
        if (closerOf(t[e.cur - 1]) != t[e.cur]) return false;
        e.select(e.cur + 1, e.cur - 1);
        try e.cut(gpa, false);
        return true;
    }

    /// Replaces the selection with `with` when it's a match of `q`.
    pub fn replaceOne(e: *Editor, gpa: Allocator, q: []const u8, with: []const u8) !bool {
        const s = e.sel();
        if (q.len == 0 or s[1] - s[0] != q.len or !matchAt(e.text(), s[0], q, caseSensitive(q))) return false;
        e.typing = false;
        try e.insert(gpa, with);
        return true;
    }

    /// Replaces every match of `q` as one undo step. Returns how many.
    pub fn replaceAll(e: *Editor, gpa: Allocator, q: []const u8, with: []const u8) !usize {
        const t = e.text();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var n: usize = 0;
        var first: ?usize = null;
        var done: usize = 0;
        var i: usize = 0;
        const sensitive = caseSensitive(q);
        while (q.len > 0 and i + q.len <= t.len) {
            if (!matchAt(t, i, q, sensitive)) {
                i += 1;
                continue;
            }
            if (first == null) {
                first = i;
                done = i;
            }
            try out.appendSlice(gpa, t[done..i]);
            try out.appendSlice(gpa, with);
            n += 1;
            i += q.len;
            done = i;
        }
        const start = first orelse return 0;
        try e.buf.replace(gpa, start, done, out.items, e.cur, false);
        e.select(start, start);
        return n;
    }

    /// Swaps in a file's new text from disk as one undoable edit of just the
    /// part that changed, so the caret stays put, and marks it saved.
    pub fn reload(e: *Editor, gpa: Allocator, bytes: []const u8) !void {
        const t = e.text();
        var a: usize = 0;
        while (a < t.len and a < bytes.len and t[a] == bytes[a]) a += 1;
        while (a > 0 and a < t.len and t[a] & 0xC0 == 0x80) a -= 1;
        var z: usize = 0;
        while (z < t.len - a and z < bytes.len - a and t[t.len - 1 - z] == bytes[bytes.len - 1 - z]) z += 1;
        const old_len = t.len;
        const fix = struct {
            fn at(p: usize, keep: usize, tail: usize, from: usize, to: usize) usize {
                if (p <= keep) return p;
                if (p >= from - tail) return p + to - from;
                return keep;
            }
        }.at;
        const anchor = fix(e.anchor, a, z, old_len, bytes.len);
        const cur = fix(e.cur, a, z, old_len, bytes.len);
        try e.buf.replace(gpa, a, old_len - z, bytes[a .. bytes.len - z], e.cur, false);
        e.buf.markSaved();
        e.select(anchor, cur);
    }
};

/// Matching ignores case unless the query has an uppercase letter.
pub fn caseSensitive(q: []const u8) bool {
    for (q) |c| if (std.ascii.isUpper(c)) return true;
    return false;
}

pub fn matchAt(t: []const u8, i: usize, q: []const u8, sensitive: bool) bool {
    if (i + q.len > t.len) return false;
    if (sensitive) return std.mem.eql(u8, t[i .. i + q.len], q);
    return std.ascii.eqlIgnoreCase(t[i .. i + q.len], q);
}

pub fn search(t: []const u8, q: []const u8, from: usize, back: bool) ?usize {
    if (q.len == 0 or q.len > t.len) return null;
    const end = t.len - q.len + 1;
    const start = @min(from, end);
    const sensitive = caseSensitive(q);
    const cases = [2]u8{ std.ascii.toLower(q[0]), std.ascii.toUpper(q[0]) };
    for (0..2) |pass| {
        const prefix = back == (pass == 0);
        var i: usize = if (prefix) 0 else start;
        const stop = if (prefix) start else end;
        var found: ?usize = null;
        while (i < stop) {
            const p = (if (sensitive)
                std.mem.indexOfPos(u8, t[0 .. stop + q.len - 1], i, q)
            else
                std.mem.indexOfAnyPos(u8, t[0..stop], i, &cases)) orelse break;
            if (matchAt(t, p, q, sensitive)) {
                if (!back) return p;
                found = p;
            }
            i = p + 1;
        }
        if (found) |p| return p;
    }
    return null;
}

/// Non-overlapping matches ending at or before `before`, and in all the text.
pub fn countMatches(t: []const u8, q: []const u8, before: usize) [2]usize {
    var n = [2]usize{ 0, 0 };
    if (q.len == 0 or q.len > t.len) return n;
    const sensitive = caseSensitive(q);
    const cases = [2]u8{ std.ascii.toLower(q[0]), std.ascii.toUpper(q[0]) };
    var i: usize = 0;
    while (i <= t.len - q.len) {
        const p = (if (sensitive)
            std.mem.indexOfPos(u8, t, i, q)
        else
            std.mem.indexOfAnyPos(u8, t, i, &cases)) orelse break;
        if (matchAt(t, p, q, sensitive)) {
            n[0] += @intFromBool(p + q.len <= before);
            n[1] += 1;
            i = p + q.len;
        } else i = p + 1;
    }
    return n;
}

fn leadingWs(l: []const u8) usize {
    var i: usize = 0;
    while (i < l.len and (l[i] == ' ' or l[i] == '\t')) i += 1;
    return i;
}

fn class(c: u8) u8 {
    if (std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80) return 0;
    if (c == ' ' or c == '\t') return 1;
    if (c == '\n' or c == '\r') return 2;
    return 3;
}

fn closerOf(c: u8) ?u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"', '\'', '`' => c,
        else => null,
    };
}

fn isCloser(c: u8) bool {
    return c == ')' or c == ']' or c == '}' or c == '"' or c == '\'' or c == '`';
}

fn wordLeft(t: []const u8, from: usize) usize {
    var i = from;
    while (i > 0 and class(t[i - 1]) == 1) i -= 1;
    if (i > 0 and t[i - 1] == '\n') return if (i > 1 and t[i - 2] == '\r') i - 2 else i - 1;
    if (i == 0) return 0;
    const k = class(t[i - 1]);
    while (i > 0 and class(t[i - 1]) == k) i -= 1;
    return i;
}

fn wordRight(t: []const u8, from: usize) usize {
    var i = from;
    while (i < t.len and class(t[i]) == 1) i += 1;
    if (i < t.len and class(t[i]) == 2) return if (t[i] == '\r' and i + 1 < t.len) i + 2 else i + 1;
    if (i == t.len) return i;
    const k = class(t[i]);
    while (i < t.len and class(t[i]) == k) i += 1;
    return i;
}

pub fn nextChar(t: []const u8, i: usize) usize {
    if (i >= t.len) return t.len;
    var j = i + 1;
    while (j < t.len and t[j] & 0xC0 == 0x80) j += 1;
    return j;
}

pub fn prevChar(t: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and t[j] & 0xC0 == 0x80) j -= 1;
    return j;
}

/// The codepoint at `i` and its byte length; bad bytes read as U+FFFD.
pub fn decode(t: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(t[i]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + n > t.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(t[i .. i + n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// How many cells a codepoint takes: 2 for East Asian wide and emoji.
pub fn width(cp: u21) usize {
    return switch (cp) {
        0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD => 2,
        else => 1,
    };
}

/// The codepoint, byte length and cells taken at column `col`.
pub fn cells(l: []const u8, i: usize, col: usize) struct { cp: u21, w: usize, len: usize } {
    if (l[i] == '\t') return .{ .cp = '\t', .w = tab_width - col % tab_width, .len = 1 };
    if (l[i] < 0x80) return .{ .cp = l[i], .w = 1, .len = 1 };
    const d = decode(l, i);
    return .{ .cp = d.cp, .w = width(d.cp), .len = d.len };
}

/// Display column of byte `n` in line `l`.
pub fn colOf(l: []const u8, n: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < n and i < l.len) {
        const c = cells(l, i, col);
        col += c.w;
        i += c.len;
    }
    return col;
}

/// The byte in `l` nearest to display column `x`.
pub fn byteAtCol(l: []const u8, x: f64) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < l.len) {
        const c = cells(l, i, col);
        if (x < @as(f64, @floatFromInt(col)) + @as(f64, @floatFromInt(c.w)) / 2) return i;
        col += c.w;
        i += c.len;
    }
    return l.len;
}

/// The end of a screen row: its last byte (exclusive) and the line's display
/// column there, which is where the next row starts.
pub const RowEnd = struct { end: usize, col: usize };

/// Where the screen row that starts at byte `start` of `line`, at display
/// column `col`, ends when rows are `cols` cells wide: after the last space
/// that fits, or mid-word when a word is longer than a row. Ends at
/// `line.len` when the rest fits.
pub fn rowEnd(line: []const u8, start: usize, col: usize, cols: usize) RowEnd {
    var i = start;
    var c = col;
    var brk: ?RowEnd = null;
    while (i < line.len) {
        const x = cells(line, i, c);
        if (c + x.w > col + cols and i > start) return brk orelse .{ .end = i, .col = c };
        c += x.w;
        i += x.len;
        if (line[i - 1] == ' ' or line[i - 1] == '\t') brk = .{ .end = i, .col = c };
    }
    return .{ .end = line.len, .col = c };
}

/// How many screen rows `line` takes at `cols` cells a row.
pub fn rowCount(line: []const u8, cols: usize) usize {
    if (line.len <= cols and std.mem.indexOfScalar(u8, line, '\t') == null) return 1;
    var n: usize = 1;
    var r: RowEnd = .{ .end = 0, .col = 0 };
    while (true) {
        r = rowEnd(line, r.end, r.col, cols);
        if (r.end >= line.len) return n;
        n += 1;
    }
}

const t_ = std.testing;
const gpa_t = t_.allocator;

test "cells returns the decoded codepoint with its width and byte length" {
    const cases = .{
        .{ "a", 0, @as(u21, 'a'), 1, 1 },
        .{ "\t", 1, @as(u21, '\t'), tab_width - 1, 1 },
        .{ "ü", 0, @as(u21, 'ü'), 1, 2 },
        .{ "漢", 0, @as(u21, '漢'), 2, 3 },
        .{ "😀", 0, @as(u21, 0x1F600), 2, 4 },
        .{ "\xff", 0, @as(u21, 0xFFFD), 1, 1 },
        .{ "\xe2\x82", 0, @as(u21, 0xFFFD), 1, 1 },
    };
    inline for (cases) |c| {
        const got = cells(c[0], 0, c[1]);
        try t_.expectEqual(c[2], got.cp);
        try t_.expectEqual(@as(usize, c[3]), got.w);
        try t_.expectEqual(@as(usize, c[4]), got.len);
    }
}

test "newline keeps indentation and undo is one step per typing run" {
    var e = try Editor.init(gpa_t, "fn x() {\n    a");
    defer e.deinit(gpa_t);
    e.move(.bottom, false, 0);
    try e.newline(gpa_t);
    for ("bc") |c| try e.insert(gpa_t, &.{c});
    try t_.expectEqualStrings("fn x() {\n    a\n    bc", e.text());
    try e.undo(gpa_t);
    try t_.expectEqualStrings("fn x() {\n    a\n    ", e.text());
    try e.undo(gpa_t);
    try t_.expectEqualStrings("fn x() {\n    a", e.text());
}

test "CRLF files get CRLF newlines" {
    var e = try Editor.init(gpa_t, "a\r\nb");
    defer e.deinit(gpa_t);
    e.move(.end, false, 0);
    try e.newline(gpa_t);
    try t_.expectEqualStrings("a\r\n\r\nb", e.text());
}

test "line deletes at a line's edge take the whole CRLF break" {
    var e = try Editor.init(gpa_t, "a\r\nb\r\n");
    defer e.deinit(gpa_t);
    e.select(3, 3);
    try e.deleteBack(gpa_t, .line);
    try t_.expectEqualStrings("ab\r\n", e.text());
    e.select(2, 2);
    try e.deleteForward(gpa_t, .line);
    try t_.expectEqualStrings("ab", e.text());
}

test "typed characters outside ASCII join the typing run" {
    var e = try Editor.init(gpa_t, "");
    defer e.deinit(gpa_t);
    for ([_][]const u8{ "ü", "b", "😀", "r" }) |s| try e.insert(gpa_t, s);
    try e.undo(gpa_t);
    try t_.expectEqualStrings("", e.text());
}

test "comment toggle adds at the shallowest indent and removes again" {
    var e = try Editor.init(gpa_t, "  a\n\n    b\n");
    defer e.deinit(gpa_t);
    e.select(0, 9);
    try e.toggleComment(gpa_t, "//");
    try t_.expectEqualStrings("  // a\n\n  //   b\n", e.text());
    try e.toggleComment(gpa_t, "//");
    try t_.expectEqualStrings("  a\n\n    b\n", e.text());
}

test "indent and outdent a block, skipping a line the selection only touches" {
    var e = try Editor.init(gpa_t, "a\nb\nc");
    defer e.deinit(gpa_t);
    e.select(0, 4);
    try e.tab(gpa_t);
    try t_.expectEqualStrings("    a\n    b\nc", e.text());
    try e.outdent(gpa_t);
    try t_.expectEqualStrings("a\nb\nc", e.text());
}

test "up and down keep the column across short lines and wide chars" {
    var e = try Editor.init(gpa_t, "abcdef\nx\n漢字abc");
    defer e.deinit(gpa_t);
    e.moveTo(5, false);
    e.move(.down, false, 0);
    try t_.expectEqual(@as(usize, 8), e.cur);
    e.move(.down, false, 0);
    try t_.expectEqual(@as(usize, 9 + 7), e.cur);
}

test "search wraps and backs up past the current match" {
    const s = "foo bar Foo";
    try t_.expectEqual(@as(?usize, 8), search(s, "foo", 1, false));
    try t_.expectEqual(@as(?usize, 0), search(s, "foo", 9, false));
    try t_.expectEqual(@as(?usize, 8), search(s, "foo", 0, true));
    try t_.expectEqual(@as(?usize, 8), search(s, "Foo", 0, false));
    try t_.expectEqual([2]usize{ 2, 2 }, countMatches(s, "foo", s.len));
    try t_.expectEqual([2]usize{ 1, 2 }, countMatches(s, "foo", 8));
    try t_.expectEqual([2]usize{ 0, 2 }, countMatches(s, "foo", 2));
    try t_.expectEqual([2]usize{ 0, 1 }, countMatches(s, "Foo", 8));
    try t_.expectEqual([2]usize{ 1, 2 }, countMatches("aaaaa", "aa", 3));
    try t_.expectEqual([2]usize{ 0, 0 }, countMatches(s, "", 0));
}

test "search jumps with punctuation, case folding and wrapping in both directions" {
    const s = ".no .Foo .fOO .foo";
    try t_.expectEqual(@as(?usize, 4), search(s, ".foo", 0, false));
    try t_.expectEqual(@as(?usize, 4), search(s, ".foo", s.len, false));
    try t_.expectEqual(@as(?usize, 14), search(s, ".foo", 0, true));
    try t_.expectEqual(@as(?usize, 9), search(s, ".foo", 14, true));
    try t_.expectEqual(@as(?usize, 14), search(s, ".foo", 4, true));
    try t_.expectEqual(@as(?usize, 4), search(s, ".Foo", 4, true));
    try t_.expectEqual(@as(?usize, null), search(s, ".missing", 0, true));
    try t_.expectEqual(@as(?usize, 1), search("aaaa", "aa", 2, true));
    try t_.expectEqual([2]usize{ 1, 3 }, countMatches(s, ".foo", 8));
    try t_.expectEqual([2]usize{ 1, 1 }, countMatches(s, ".Foo", 8));
}

test "word motion stops at punctuation and line ends" {
    const s = "foo.bar  baz\nq";
    try t_.expectEqual(@as(usize, 3), wordRight(s, 0));
    try t_.expectEqual(@as(usize, 4), wordRight(s, 3));
    try t_.expectEqual(@as(usize, 13), wordRight(s, 12));
    try t_.expectEqual(@as(usize, 9), wordLeft(s, 12));
    try t_.expectEqual(@as(usize, 12), wordLeft(s, 13));
}

test "pairs close openers, step over closers, wrap selections and delete empty pairs" {
    var e = try Editor.init(gpa_t, "it");
    defer e.deinit(gpa_t);
    e.moveTo(2, false);
    try e.typePaired(gpa_t, "'");
    try t_.expectEqualStrings("it'", e.text());
    try e.typePaired(gpa_t, " ");
    try e.typePaired(gpa_t, "(");
    try e.typePaired(gpa_t, "\"");
    try t_.expectEqualStrings("it' (\"\")", e.text());
    try e.typePaired(gpa_t, "\"");
    try e.typePaired(gpa_t, ")");
    try t_.expectEqualStrings("it' (\"\")", e.text());
    try t_.expectEqual(@as(usize, 8), e.cur);
    e.moveTo(6, false);
    try t_.expect(try e.deletePair(gpa_t));
    try t_.expectEqualStrings("it' ()", e.text());
    e.select(0, 2);
    try e.typePaired(gpa_t, "[");
    try t_.expectEqualStrings("[it]' ()", e.text());
    try t_.expectEqual([2]usize{ 1, 3 }, e.sel());
}

test "replace all is one undo step and keeps the case rule" {
    var e = try Editor.init(gpa_t, "a foo b FOO foo");
    defer e.deinit(gpa_t);
    try t_.expectEqual(@as(usize, 3), try e.replaceAll(gpa_t, "foo", "x"));
    try t_.expectEqualStrings("a x b x x", e.text());
    try e.undo(gpa_t);
    try t_.expectEqualStrings("a foo b FOO foo", e.text());
    try t_.expectEqual(@as(usize, 1), try e.replaceAll(gpa_t, "FOO", "y"));
    try t_.expectEqualStrings("a foo b y foo", e.text());
}

test "rows break after the last space that fits, or mid-word" {
    const l = "aaa bbb ccccccccc d";
    try t_.expectEqual(@as(usize, 8), rowEnd(l, 0, 0, 9).end);
    try t_.expectEqual(@as(usize, 17), rowEnd(l, 8, 8, 9).end);
    try t_.expectEqual(@as(usize, 3), rowCount(l, 9));
    try t_.expectEqual(@as(usize, 1), rowCount("", 9));
    try t_.expectEqual(@as(usize, 1), rowCount("abc", 9));
}

test "short tab-free lines fit by bytes, but tabs can overflow" {
    try t_.expectEqual(@as(usize, 1), rowCount("abcdefgh", 8));
    try t_.expectEqual(@as(usize, 1), rowCount("漢😀a", 8));
    try t_.expectEqual(@as(usize, 1), rowCount("\xff", 1));
    try t_.expect(rowCount("a\tb", 3) > 1);
}

test "newline keeps untouched wrap counts and incremental counts match a full count" {
    var e = try Editor.init(gpa_t, "abcdefghijklmnop\nabcde fghij\nabcdefghijklmnopqrst");
    defer e.deinit(gpa_t);
    const b = &e.buf;
    b.wraps_cols = 8;
    try b.wraps.resize(gpa_t, b.lines());
    for (b.wraps.items, 0..) |*w, i| w.* = @intCast(rowCount(b.line(i), b.wraps_cols));
    try t_.expectEqualSlices(u32, &.{ 2, 2, 3 }, b.wraps.items);
    e.moveTo(b.starts.items[1] + 5, false);
    try e.insert(gpa_t, "\n");
    try t_.expectEqualSlices(u32, &.{ 2, 0, 0, 3 }, b.wraps.items);
    try t_.expectEqual(@as(usize, 1), b.wraps_from);
    for (b.wraps.items[b.wraps_from..], b.wraps_from..) |*w, i| {
        if (w.* == 0) w.* = @intCast(rowCount(b.line(i), b.wraps_cols));
    }
    for (b.wraps.items, 0..) |w, i| {
        try t_.expectEqual(@as(u32, @intCast(rowCount(b.line(i), b.wraps_cols))), w);
    }
}

test "reload keeps the caret and undoes back to the old text" {
    var e = try Editor.init(gpa_t, "one\ntwo\nthree\n");
    defer e.deinit(gpa_t);
    e.moveTo(10, false);
    try e.reload(gpa_t, "zero\none\ntwo\nthree\n");
    try t_.expectEqualStrings("zero\none\ntwo\nthree\n", e.text());
    try t_.expectEqual(@as(usize, 15), e.cur);
    try t_.expect(!e.buf.dirty());
    try e.reload(gpa_t, "zero\none\nTWO\nthree\n");
    try t_.expectEqual(@as(usize, 15), e.cur);
    try e.undo(gpa_t);
    try t_.expectEqualStrings("zero\none\ntwo\nthree\n", e.text());
}
