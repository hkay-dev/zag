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
        const join = e.typing and !e.hasSel() and s.len == 1 and s[0] != '\n';
        try e.buf.replace(gpa, r[0], r[1], s, e.cur, join);
        e.select(r[0] + s.len, r[0] + s.len);
        e.typing = s.len == 1;
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
                .line => if (e.cur == ls) prevChar(t, e.cur) else ls,
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
                .line => if (e.cur == le) nextChar(t, e.cur) else le,
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
};

/// Matching ignores case unless the query has an uppercase letter.
pub fn matchAt(t: []const u8, i: usize, q: []const u8) bool {
    if (i + q.len > t.len) return false;
    for (q) |c| if (std.ascii.isUpper(c)) return std.mem.eql(u8, t[i .. i + q.len], q);
    return std.ascii.eqlIgnoreCase(t[i .. i + q.len], q);
}

pub fn search(t: []const u8, q: []const u8, from: usize, back: bool) ?usize {
    if (q.len == 0 or q.len > t.len) return null;
    const last = t.len - q.len;
    var n: usize = 0;
    var i = @min(from, last + 1);
    while (n <= last) : (n += 1) {
        if (back) {
            i = if (i == 0) last else i - 1;
        } else if (i > last) i = 0;
        if (matchAt(t, i, q)) return i;
        if (!back) i += 1;
    }
    return null;
}

pub fn countMatches(t: []const u8, q: []const u8) usize {
    if (q.len == 0) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + q.len <= t.len) : (i += 1) {
        if (matchAt(t, i, q)) {
            n += 1;
            i += q.len - 1;
        }
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

/// Cells taken by the char at `i` when it starts at column `col`.
pub fn cells(l: []const u8, i: usize, col: usize) struct { w: usize, len: usize } {
    if (l[i] == '\t') return .{ .w = tab_width - col % tab_width, .len = 1 };
    if (l[i] < 0x80) return .{ .w = 1, .len = 1 };
    const d = decode(l, i);
    return .{ .w = width(d.cp), .len = d.len };
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

const t_ = std.testing;
const gpa_t = t_.allocator;

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
    try t_.expectEqual(@as(usize, 2), countMatches(s, "foo"));
}

test "word motion stops at punctuation and line ends" {
    const s = "foo.bar  baz\nq";
    try t_.expectEqual(@as(usize, 3), wordRight(s, 0));
    try t_.expectEqual(@as(usize, 4), wordRight(s, 3));
    try t_.expectEqual(@as(usize, 13), wordRight(s, 12));
    try t_.expectEqual(@as(usize, 9), wordLeft(s, 12));
    try t_.expectEqual(@as(usize, 12), wordLeft(s, 13));
}
