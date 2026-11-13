//! Caret, selection and the edit commands, on top of a Buffer. Knows
//! nothing about windows or drawing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;

/// Columns between tab stops when an editor doesn't set its own.
pub const default_tab_width = 4;
const spaces: [256]u8 = @splat(' ');

pub const Motion = enum { left, right, word_left, word_right, home, end, line_start, line_end, top, bottom };

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
    /// Columns between tab stops, and the width of one spaces indent.
    tab_width: u8 = default_tab_width,

    pub fn init(gpa: Allocator, bytes: []const u8) !Editor {
        var e: Editor = .{ .buf = try Buffer.init(gpa, bytes) };
        e.detectStyle(bytes);
        return e;
    }

    /// Picks the line ending and indent that Return and Tab insert from the
    /// file's own text.
    fn detectStyle(e: *Editor, bytes: []const u8) void {
        e.eol = "\n";
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |i| {
            if (i > 0 and bytes[i - 1] == '\r') e.eol = "\r\n";
        }
        e.indent = "    ";
        if (std.mem.indexOf(u8, bytes, "\n\t") != null and std.mem.indexOf(u8, bytes, "\n    ") == null) e.indent = "\t";
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

    pub fn move(e: *Editor, m: Motion, extend: bool) void {
        if (!extend and e.hasSel() and (m == .left or m == .right)) {
            const s = e.sel();
            return e.select(s[@intFromBool(m == .right)], s[@intFromBool(m == .right)]);
        }
        e.moveTo(e.target(m), extend);
    }

    fn target(e: *const Editor, m: Motion) usize {
        const b = &e.buf;
        const t = e.text();
        const row = b.lineOf(e.cur);
        return switch (m) {
            .left => if (e.cur == b.lineStart(row) and row > 0) b.lineEnd(row - 1) else prevCluster(t, e.cur),
            .right => if (e.cur == b.lineEnd(row) and row + 1 < b.lines()) b.lineStart(row + 1) else nextCluster(t, e.cur),
            .word_left => wordLeft(t, e.cur),
            .word_right => wordRight(t, e.cur),
            .home => blk: {
                const ls = b.lineStart(row);
                var nb = ls;
                while (nb < b.lineEnd(row) and (t[nb] == ' ' or t[nb] == '\t')) nb += 1;
                break :blk if (e.cur == nb) ls else nb;
            },
            .line_start => b.lineStart(row),
            .end, .line_end => b.lineEnd(row),
            .top => 0,
            .bottom => t.len,
        };
    }

    /// Replaces the selection with `s`.
    pub fn insert(e: *Editor, gpa: Allocator, s: []const u8) !void {
        const r = e.sel();
        // One typed character, ASCII or not and including emoji built from
        // several code points, joins the typing run; a newline starts the
        // next one.
        const one = oneCluster(s);
        try e.buf.replace(gpa, r[0], r[1], s, e.cur, e.typing and !e.hasSel() and one and s[0] != '\n');
        e.select(r[0] + s.len, r[0] + s.len);
        e.typing = one;
    }

    /// Inserts pasted text with its `\n` and `\r\n` breaks turned into the
    /// file's own line ending.
    pub fn paste(e: *Editor, gpa: Allocator, s: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var rest = s;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
            try out.appendSlice(gpa, rest[0 .. if (i > 0 and rest[i - 1] == '\r') i - 1 else i]);
            try out.appendSlice(gpa, e.eol);
            rest = rest[i + 1 ..];
        }
        try out.appendSlice(gpa, rest);
        try e.insert(gpa, out.items);
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
            const row = e.buf.lineOf(e.cur);
            const ls = e.buf.lineStart(row);
            e.anchor = switch (unit) {
                .char => e.target(.left),
                .word => e.target(.word_left),
                .line => if (e.cur != ls) ls else e.target(.left),
            };
        }
        try e.cut(gpa, unit == .char);
    }

    pub fn deleteForward(e: *Editor, gpa: Allocator, unit: Unit) !void {
        if (!e.hasSel()) {
            const row = e.buf.lineOf(e.cur);
            const le = e.buf.lineEnd(row);
            e.anchor = switch (unit) {
                .char => e.target(.right),
                .word => e.target(.word_right),
                .line => if (e.cur != le) le else e.target(.right),
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
    /// A selection of one whole line indents it, whichever way it was dragged.
    pub fn tab(e: *Editor, gpa: Allocator) !void {
        const r = e.sel();
        const first = e.buf.lineOf(r[0]);
        const whole = r[0] != r[1] and r[0] == e.buf.lineStart(first) and r[1] == e.buf.lineEnd(first);
        if (!whole and first == e.buf.lineOf(r[1])) {
            if (e.indent[0] == '\t') return e.insert(gpa, "\t");
            const row = e.buf.lineOf(e.cur);
            const tw = e.tabWidth();
            const col = colOfTab(e.buf.line(row), 0, 0, e.cur - e.buf.lineStart(row), tw);
            return e.insert(gpa, spaces[0 .. tw - col % tw]);
        }
        try e.eachLine(gpa, .indent);
    }

    /// The tab width, never below one column.
    pub fn tabWidth(e: *const Editor) usize {
        return @max(1, e.tab_width);
    }

    /// What one level of indent inserts: a tab, or `tab_width` spaces.
    fn indentUnit(e: *const Editor) []const u8 {
        return if (e.indent.len > 0 and e.indent[0] == '\t') "\t" else spaces[0..e.tabWidth()];
    }

    pub fn outdent(e: *Editor, gpa: Allocator) !void {
        try e.eachLine(gpa, .outdent);
    }

    pub fn toggleComment(e: *Editor, gpa: Allocator, prefix: []const u8) !void {
        if (prefix.len > 0) try e.eachLine(gpa, .{ .comment = prefix });
    }

    /// Lays out the selection, or the whole file, as indented JSON in one
    /// undo step, keeping key order and how each number and string is
    /// written. Returns false, changing nothing, when it isn't valid JSON.
    pub fn formatJson(e: *Editor, gpa: Allocator) !bool {
        const t = e.text();
        const r = if (e.hasSel()) e.sel() else [2]usize{ 0, t.len };
        const ws = " \t\r\n";
        const a = r[1] - std.mem.trimStart(u8, t[r[0]..r[1]], ws).len;
        const z = r[0] + std.mem.trimEnd(u8, t[r[0]..r[1]], ws).len;
        if (a >= z or !try std.json.validate(gpa, t[a..z])) return false;

        // Nested lines start from the indent of the line the JSON starts on.
        const ls = e.buf.lineStart(e.buf.lineOf(a));
        const base = t[ls .. ls + leadingWs(t[ls..a])];
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var depth: usize = 0;
        // Where the caret lands in the new text: the same token, or the
        // same byte inside a string, it sat on or just before.
        const cur = e.cur;
        var at: ?usize = if (cur < a) cur else null;
        var i = a;
        while (i < z) : (i += 1) {
            if (at == null and cur <= i) at = a + out.items.len;
            const c = t[i];
            switch (c) {
                ' ', '\t', '\r', '\n' => {},
                '"' => {
                    const s = i;
                    i += 1;
                    while (t[i] != '"') i += if (t[i] == '\\') 2 else 1;
                    if (at == null and cur <= i) at = a + out.items.len + cur - s;
                    try out.appendSlice(gpa, t[s .. i + 1]);
                },
                '{', '[' => {
                    var j = i + 1;
                    while (std.mem.indexOfScalar(u8, ws, t[j]) != null) j += 1;
                    if (t[j] == c + 2) {
                        try out.appendSlice(gpa, &.{ c, c + 2 });
                        i = j;
                    } else {
                        try out.append(gpa, c);
                        depth += 1;
                        try e.breakLine(gpa, &out, base, depth);
                    }
                },
                '}', ']' => {
                    depth -= 1;
                    const mark = a + out.items.len;
                    try e.breakLine(gpa, &out, base, depth);
                    if (at == mark) at = a + out.items.len;
                    try out.append(gpa, c);
                },
                ',' => {
                    try out.append(gpa, c);
                    try e.breakLine(gpa, &out, base, depth);
                },
                ':' => try out.appendSlice(gpa, ": "),
                else => try out.append(gpa, c),
            }
        }
        if (std.mem.eql(u8, out.items, t[a..z])) return true;
        try e.buf.replace(gpa, a, z, out.items, e.cur, false);
        const caret = at orelse cur - z + a + out.items.len;
        if (e.hasSel()) e.select(a, a + out.items.len) else e.select(caret, caret);
        return true;
    }

    fn breakLine(e: *const Editor, gpa: Allocator, out: *std.ArrayList(u8), base: []const u8, depth: usize) !void {
        try out.appendSlice(gpa, e.eol);
        try out.appendSlice(gpa, base);
        for (0..depth) |_| try out.appendSlice(gpa, e.indentUnit());
    }

    const LineOp = union(enum) { indent, outdent, comment: []const u8 };

    /// The first and last rows the selection touches, leaving out a last row
    /// the selection only reaches the start of.
    fn selRows(e: *const Editor) [2]usize {
        const b = &e.buf;
        const r = e.sel();
        const first = b.lineOf(r[0]);
        var last = b.lineOf(r[1]);
        if (last > first and r[1] == b.lineStart(last)) last -= 1;
        return .{ first, last };
    }

    /// Rewrites every line the selection touches as one undo step, and
    /// selects the rewritten lines. With only a caret, the caret stays on the
    /// same character instead.
    fn eachLine(e: *Editor, gpa: Allocator, op: LineOp) !void {
        const b = &e.buf;
        const rows = e.selRows();
        const first = rows[0];
        const last = rows[1];
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

        // The one change on the caret's line: `del` bytes at column `at`
        // became `add` bytes.
        var at: usize = 0;
        var del: usize = 0;
        var add: usize = 0;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        for (first..last + 1) |i| {
            if (i > first) try out.appendSlice(gpa, t[b.lineEnd(i - 1)..b.lineStart(i)]);
            const l = b.line(i);
            const ws = leadingWs(l);
            switch (op) {
                .indent => {
                    const unit = e.indentUnit();
                    if (l.len > 0) add = unit.len;
                    try out.appendSlice(gpa, unit[0..add]);
                    try out.appendSlice(gpa, l);
                },
                .outdent => {
                    if (del < l.len and l[0] == '\t') del = 1 else while (del < l.len and del < e.tabWidth() and l[del] == ' ') del += 1;
                    try out.appendSlice(gpa, l[del..]);
                },
                .comment => |p| if (ws == l.len) {
                    try out.appendSlice(gpa, l);
                } else if (all) {
                    at = ws;
                    del = p.len;
                    if (at + del < l.len and l[at + del] == ' ') del += 1;
                    try out.appendSlice(gpa, l[0..at]);
                    try out.appendSlice(gpa, l[at + del ..]);
                } else {
                    at = min_ws;
                    add = p.len + 1;
                    try out.appendSlice(gpa, l[0..at]);
                    try out.appendSlice(gpa, p);
                    try out.append(gpa, ' ');
                    try out.appendSlice(gpa, l[at..]);
                },
            }
            if (i < last) {
                at = 0;
                del = 0;
                add = 0;
            }
        }
        if (std.mem.eql(u8, out.items, t[start..end])) return;
        const had_sel = e.hasSel();
        const col = e.cur - start;
        try b.replace(gpa, start, end, out.items, e.cur, false);
        if (had_sel) return e.select(start, start + out.items.len);
        const c = start + if (col < at) col else if (col < at + del) at + add else col - del + add;
        e.select(c, c);
    }

    pub fn undo(e: *Editor, gpa: Allocator) !?[2]usize {
        const step = try e.buf.undo(gpa) orelse return null;
        e.select(step.before, step.before);
        return .{ step.pos, step.pos + step.old.len };
    }

    pub fn redo(e: *Editor, gpa: Allocator) !?[2]usize {
        const step = try e.buf.redo(gpa) orelse return null;
        const p = step.pos + step.new.len;
        e.select(p, p);
        return .{ step.pos, step.pos + step.new.len };
    }

    pub fn wordAt(e: *const Editor, pos: usize) ?[2]usize {
        const t = e.text();
        var a = pos;
        var z = pos;
        const k = if (pos < t.len) class(t[pos]) else if (pos > 0) class(t[pos - 1]) else return null;
        // A line break (`\n`, or the `\r` of CRLF) is never part of a word.
        if (k == 2) return .{ pos, pos };
        while (a > 0 and class(t[a - 1]) == k) a -= 1;
        while (z < t.len and class(t[z]) == k) z += 1;
        return .{ a, z };
    }

    pub fn lineAt(e: *const Editor, pos: usize) [2]usize {
        const row = e.buf.lineOf(pos);
        return .{ e.buf.lineStart(row), e.buf.lineStop(row) };
    }

    pub fn selectAll(e: *Editor) void {
        e.select(0, e.text().len);
    }

    /// Selects the next match of `q` at or after `from`, or before `from` when
    /// `back`, wrapping around. False when there is none.
    pub fn find(e: *Editor, q: []const u8, from: usize, back: bool) bool {
        return e.findWith(q, from, back, .{});
    }

    /// `find` with a case rule and whole-word matching.
    pub fn findWith(e: *Editor, q: []const u8, from: usize, back: bool, opts: SearchOpts) bool {
        const p = searchWith(e.text(), q, from, back, opts) orelse return false;
        e.select(p, p + q.len);
        return true;
    }

    /// The bracket next to the caret and its partner, `( )`, `[ ]` or
    /// `{ }` counting nesting, as `.{ bracket, partner }`. The bracket after
    /// the caret goes first; the one before it is the fallback. Null when
    /// neither has a partner.
    pub fn matchingBracket(e: *const Editor) ?[2]usize {
        const t = e.text();
        if (matchingBracketAt(t, e.cur)) |m| return .{ e.cur, m };
        if (e.cur > 0) if (matchingBracketAt(t, e.cur - 1)) |m| return .{ e.cur - 1, m };
        return null;
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
        return e.replaceOneWith(gpa, q, with, .{});
    }

    /// `replaceOne` with a case rule and whole-word matching.
    pub fn replaceOneWith(e: *Editor, gpa: Allocator, q: []const u8, with: []const u8, opts: SearchOpts) !bool {
        const s = e.sel();
        if (q.len == 0 or s[1] - s[0] != q.len or !matches(e.text(), s[0], q, opts.sensitive(q), opts.whole_word)) return false;
        e.typing = false;
        try e.insert(gpa, with);
        return true;
    }

    /// Replaces every match of `q` as one undo step. Returns how many.
    pub fn replaceAll(e: *Editor, gpa: Allocator, q: []const u8, with: []const u8, spots: [][2]usize) !usize {
        return e.replaceAllWith(gpa, q, with, spots, .{});
    }

    /// `replaceAll` with a case rule and whole-word matching.
    pub fn replaceAllWith(e: *Editor, gpa: Allocator, q: []const u8, with: []const u8, spots: [][2]usize, opts: SearchOpts) !usize {
        const t = e.text();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var n: usize = 0;
        var first: ?usize = null;
        var done: usize = 0;
        var i: usize = 0;
        const sensitive = opts.sensitive(q);
        while (q.len > 0 and i + q.len <= t.len) {
            if (!matches(t, i, q, sensitive, opts.whole_word)) {
                i += 1;
                continue;
            }
            if (first == null) {
                first = i;
                done = i;
            }
            try out.appendSlice(gpa, t[done..i]);
            if (n < spots.len) {
                const start = first.? + out.items.len;
                spots[n] = .{ start, start + with.len };
            }
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

    /// Copies the selected lines, or the caret's line, below themselves as
    /// one undo step, and moves the caret or selection onto the copy.
    pub fn duplicateLine(e: *Editor, gpa: Allocator) !void {
        const b = &e.buf;
        const rows = e.selRows();
        const t = e.text();
        const end = b.lineEnd(rows[1]);
        const block = t[b.lineStart(rows[0])..end];
        const add = try std.mem.concat(gpa, u8, &.{ e.eol, block });
        defer gpa.free(add);
        const anchor = e.anchor;
        const cur = e.cur;
        try b.replace(gpa, end, end, add, cur, false);
        e.select(anchor + add.len, cur + add.len);
    }

    /// Swaps the selected lines, or the caret's line, with the line above,
    /// as one undo step. The caret and selection move with the lines.
    pub fn moveLinesUp(e: *Editor, gpa: Allocator) !void {
        const rows = e.selRows();
        if (rows[0] == 0) return;
        try e.swapLines(gpa, rows[0] - 1, rows[0], rows[1], false);
    }

    /// Swaps the selected lines, or the caret's line, with the line below,
    /// as one undo step. The caret and selection move with the lines.
    pub fn moveLinesDown(e: *Editor, gpa: Allocator) !void {
        const rows = e.selRows();
        if (rows[1] + 1 >= e.buf.lines()) return;
        try e.swapLines(gpa, rows[0], rows[1], rows[1] + 1, true);
    }

    /// Swaps the block of rows `a..m` with row `z` below it (`down`), or row
    /// `a` with the block of rows `m..z` below it (up), keeping the line
    /// break between the two parts where it was.
    fn swapLines(e: *Editor, gpa: Allocator, a: usize, m: usize, z: usize, down: bool) !void {
        const b = &e.buf;
        const t = e.text();
        // Up: the lone line is `a`, the block `m..z`. Down: the block is
        // `a..m`, the lone line `z`.
        const top_end = if (down) b.lineEnd(m) else b.lineEnd(a);
        const bot_start = if (down) b.lineStart(z) else b.lineStart(m);
        const start = b.lineStart(a);
        const end = b.lineEnd(z);
        const top = t[start..top_end];
        const brk = t[top_end..bot_start];
        const bot = t[bot_start..end];
        const out = try std.mem.concat(gpa, u8, &.{ bot, brk, top });
        defer gpa.free(out);
        const anchor = e.anchor;
        const cur = e.cur;
        // The selection's lines move by the other part and the break. A
        // selection end at the start of the row after the block goes to the
        // start of the row after the block's new place.
        const by = brk.len + if (down) bot.len else top.len;
        const hi = if (down) top_end else end;
        const past = if (down) b.lineStop(z) else start + bot.len + brk.len;
        try b.replace(gpa, start, end, out, cur, false);
        e.select(mapSwap(anchor, hi, by, down, past), mapSwap(cur, hi, by, down, past));
    }

    /// Joins the selected lines, or the caret's line and the next, into one
    /// as one undo step: each line break and the next line's indent become
    /// one space, or nothing next to a blank line or trailing space. The
    /// caret goes to the first join; a selection covers the joined line.
    pub fn joinLines(e: *Editor, gpa: Allocator) !void {
        const b = &e.buf;
        const rows = e.selRows();
        const first = rows[0];
        const last = if (rows[1] > first) rows[1] else first + 1;
        if (last >= b.lines()) return;
        const t = e.text();
        const start = b.lineEnd(first);
        const end = b.lineEnd(last);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        const head = b.line(first);
        var bare = head.len == 0 or head[head.len - 1] == ' ' or head[head.len - 1] == '\t';
        for (first + 1..last + 1) |i| {
            const l = b.line(i);
            const rest = l[leadingWs(l)..];
            if (rest.len == 0) continue;
            if (!bare) try out.append(gpa, ' ');
            try out.appendSlice(gpa, rest);
            bare = rest[rest.len - 1] == ' ' or rest[rest.len - 1] == '\t';
        }
        if (std.mem.eql(u8, out.items, t[start..end])) return;
        const had_sel = e.hasSel();
        const sel_start = e.sel()[0];
        try b.replace(gpa, start, end, out.items, e.cur, false);
        if (had_sel) return e.select(sel_start, start + out.items.len);
        e.select(start, start);
    }

    /// Deletes the selected lines, or the caret's line, with their line
    /// break as one undo step. The caret keeps its byte column on the line
    /// that takes their place.
    pub fn deleteLine(e: *Editor, gpa: Allocator) !void {
        const b = &e.buf;
        const rows = e.selRows();
        var start = b.lineStart(rows[0]);
        const end = b.lineStop(rows[1]);
        // The last line has no break of its own, so it takes the one before.
        if (end == e.text().len and rows[0] > 0) start = b.lineEnd(rows[0] - 1);
        if (start == end) return;
        const col = e.cur - b.lineStart(b.lineOf(e.cur));
        try b.replace(gpa, start, end, "", e.cur, false);
        const row = b.lineOf(@min(start, e.text().len));
        const ls = b.lineStart(row);
        const c = charStart(e.text(), @min(ls + col, b.lineEnd(row)));
        e.select(c, c);
    }

    /// Removes spaces and tabs at the ends of lines as one undo step, leaving
    /// the caret and selection on the same characters.
    pub fn trimTrailingWhitespace(e: *Editor, gpa: Allocator) !void {
        const b = &e.buf;
        const t = e.text();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        // The rewritten span runs from the first trimmed run to the last.
        var from: ?usize = null;
        var done: usize = 0;
        // Bytes removed before the anchor and the caret.
        var anchor_cut: usize = 0;
        var cur_cut: usize = 0;
        for (0..b.lines()) |i| {
            const le = b.lineEnd(i);
            var ws = le;
            while (ws > b.lineStart(i) and (t[ws - 1] == ' ' or t[ws - 1] == '\t')) ws -= 1;
            if (ws == le) continue;
            if (from == null) {
                from = ws;
                done = ws;
            }
            try out.appendSlice(gpa, t[done..ws]);
            done = le;
            if (e.anchor > ws) anchor_cut += @min(e.anchor, le) - ws;
            if (e.cur > ws) cur_cut += @min(e.cur, le) - ws;
        }
        const a = from orelse return;
        try b.replace(gpa, a, done, out.items, e.cur, false);
        e.select(e.anchor - anchor_cut, e.cur - cur_cut);
    }

    /// Adds the file's line ending after the last line when the text doesn't
    /// end with one. Empty text stays empty.
    pub fn ensureFinalNewline(e: *Editor, gpa: Allocator) !void {
        const t = e.text();
        if (t.len == 0 or t[t.len - 1] == '\n') return;
        try e.buf.replace(gpa, t.len, t.len, e.eol, e.cur, false);
        e.select(e.anchor, e.cur);
    }

    /// Swaps in a file's new text from disk as one undoable edit of just the
    /// part that changed, so the caret stays put, and marks it saved.
    pub fn reload(e: *Editor, gpa: Allocator, bytes: []const u8) !void {
        const t = e.text();
        var a: usize = 0;
        while (a < t.len and a < bytes.len and t[a] == bytes[a]) a += 1;
        a = charStart(t, a);
        var z: usize = 0;
        while (z < t.len - a and z < bytes.len - a and t[t.len - 1 - z] == bytes[bytes.len - 1 - z]) z += 1;
        while (z > 0 and t[t.len - z] & 0xC0 == 0x80) z -= 1;
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
        e.detectStyle(bytes);
        e.select(anchor, cur);
    }
};

/// How a search matches: its case rule, and whether a match must be a whole
/// word.
pub const SearchOpts = struct {
    pub const CaseMode = enum { smart, sensitive, insensitive };

    /// `smart` ignores case unless the query has an uppercase letter.
    case_mode: CaseMode = .smart,
    /// A match that starts or ends with a word character must not continue
    /// a word on that side.
    whole_word: bool = false,

    pub fn sensitive(o: SearchOpts, q: []const u8) bool {
        return switch (o.case_mode) {
            .smart => caseSensitive(q),
            .sensitive => true,
            .insensitive => false,
        };
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

/// `matchAt` that, with `whole`, also needs word boundaries on each side
/// of the match that starts or ends with a word character.
pub fn matches(t: []const u8, i: usize, q: []const u8, sensitive: bool, whole: bool) bool {
    if (!matchAt(t, i, q, sensitive)) return false;
    if (!whole or q.len == 0) return true;
    const z = i + q.len;
    if (class(q[0]) == 0 and i > 0 and class(t[i - 1]) == 0) return false;
    if (class(q[q.len - 1]) == 0 and z < t.len and class(t[z]) == 0) return false;
    return true;
}

/// First index at or after `from` holding byte `a` or `b`, 32 bytes at a time.
fn findEither(t: []const u8, from: usize, a: u8, b: u8) ?usize {
    const V = @Vector(32, u8);
    var i = from;
    while (i + 32 <= t.len) : (i += 32) {
        const v: V = t[i..][0..32].*;
        const hit = (v == @as(V, @splat(a))) | (v == @as(V, @splat(b)));
        if (std.simd.firstTrue(hit)) |k| return i + k;
    }
    while (i < t.len) : (i += 1) if (t[i] == a or t[i] == b) return i;
    return null;
}

/// Next spot at or after `i`, before `stop`, where `q` could start.
fn candidate(t: []const u8, i: usize, stop: usize, q: []const u8, sensitive: bool) ?usize {
    if (sensitive) return std.mem.indexOfPos(u8, t[0 .. stop + q.len - 1], i, q);
    return findEither(t[0..stop], i, std.ascii.toLower(q[0]), std.ascii.toUpper(q[0]));
}

fn search(t: []const u8, q: []const u8, from: usize, back: bool) ?usize {
    return searchWith(t, q, from, back, .{});
}

/// The match of `q` at or after `from`, or the last one before `from` when
/// `back`, wrapping around.
pub fn searchWith(t: []const u8, q: []const u8, from: usize, back: bool, opts: SearchOpts) ?usize {
    if (q.len == 0 or q.len > t.len) return null;
    const end = t.len - q.len + 1;
    const start = @min(from, end);
    const sensitive = opts.sensitive(q);
    for (0..2) |pass| {
        const prefix = back == (pass == 0);
        var i: usize = if (prefix) 0 else start;
        const stop = if (prefix) start else end;
        var found: ?usize = null;
        while (i < stop) {
            const p = candidate(t, i, stop, q, sensitive) orelse break;
            if (matches(t, p, q, sensitive, opts.whole_word)) {
                if (!back) return p;
                found = p;
            }
            i = p + 1;
        }
        if (found) |p| return p;
    }
    return null;
}

/// Counting stops at this many matches, so a one-letter query in a huge
/// file returns within a frame.
pub const count_cap = 10_000;

/// Non-overlapping matches ending at or before `before`, and in all the
/// text, both counted up to `count_cap`.
pub fn countMatches(t: []const u8, q: []const u8, before: usize) [2]usize {
    return countMatchesWith(t, q, before, .{});
}

/// `countMatches` with a case rule and whole-word matching.
pub fn countMatchesWith(t: []const u8, q: []const u8, before: usize, opts: SearchOpts) [2]usize {
    var n = [2]usize{ 0, 0 };
    if (q.len == 0 or q.len > t.len) return n;
    const sensitive = opts.sensitive(q);
    const end = t.len - q.len + 1;
    var i: usize = 0;
    while (i < end and n[1] < count_cap) {
        const p = candidate(t, i, end, q, sensitive) orelse break;
        if (matches(t, p, q, sensitive, opts.whole_word)) {
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

pub fn wordLeft(t: []const u8, from: usize) usize {
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
    if (i < t.len and class(t[i]) == 2) return if (t[i] == '\r' and i + 1 < t.len and t[i + 1] == '\n') i + 2 else i + 1;
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

pub fn charStart(t: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and j < t.len and t[j] & 0xC0 == 0x80) j -= 1;
    return j;
}

pub fn prevChar(t: []const u8, i: usize) usize {
    return if (i == 0) 0 else charStart(t, i - 1);
}

/// The codepoint at `i` and its byte length; bad bytes read as U+FFFD.
pub fn decode(t: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(t[i]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + n > t.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(t[i .. i + n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Whether `cp` is a regional indicator, half of a flag.
fn isFlag(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// Whether `cp` belongs to the character before it, taking no cells of its
/// own: combining marks, the zero width joiner, variation selectors, skin
/// tones, tags, and Hangul vowel and final consonant jamo.
fn isExtend(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, 0x1160...0x11FF, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x200D, 0x20D0...0x20FF, 0xD7B0...0xD7FF, 0xFE00...0xFE0F, 0xFE20...0xFE2F, 0x1F3FB...0x1F3FF, 0xE0020...0xE007F, 0xE0100...0xE01EF => true,
        else => false,
    };
}

/// The end of the user-visible character that starts at `i`: a code point
/// with the extending code points after it, the code points that zero width
/// joiners join to it, or both halves of a flag. Control characters, line
/// breaks among them, always stand alone.
pub fn nextCluster(t: []const u8, i: usize) usize {
    if (i >= t.len) return t.len;
    if (t[i] < 0x80 and (t[i] < 0x20 or i + 1 == t.len or t[i + 1] < 0x80)) return i + 1;
    const first = decode(t, i);
    var j = i + first.len;
    if (isFlag(first.cp) and j < t.len) {
        const d = decode(t, j);
        if (isFlag(d.cp)) return j + d.len;
    }
    var joined = first.cp == 0x200D;
    while (j < t.len) {
        const d = decode(t, j);
        if (d.cp < 0x20 or !(joined or isExtend(d.cp))) break;
        joined = d.cp == 0x200D;
        j += d.len;
    }
    return j;
}

/// The start of the user-visible character that ends at `i`; the reverse of
/// `nextCluster`.
pub fn prevCluster(t: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var p = prevChar(t, i);
    while (p > 0) {
        const d = decode(t, p);
        if (d.cp < 0x20) break;
        const q = prevChar(t, p);
        const before = decode(t, q).cp;
        if (before < 0x20) break;
        if (isExtend(d.cp) or before == 0x200D) {
            p = q;
            continue;
        }
        if (isFlag(d.cp)) {
            // Flags pair up from the first of a run, so `p` is a second
            // half when an odd number of them comes before it.
            var n: usize = 0;
            var k = p;
            while (k > 0) {
                const s = prevChar(t, k);
                if (!isFlag(decode(t, s).cp)) break;
                n += 1;
                k = s;
            }
            if (n % 2 == 1) p = q;
        }
        break;
    }
    return p;
}

/// Whether `s` is one user-visible character, by `nextCluster`.
fn oneCluster(s: []const u8) bool {
    return s.len > 0 and nextCluster(s, 0) == s.len;
}

/// How many cells a codepoint takes: 2 for East Asian wide and emoji.
fn width(cp: u21) usize {
    return switch (cp) {
        0x1100...0x115F, 0x2600...0x27BF, 0x2E80...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F1E6...0x1F1FF, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x3FFFD => 2,
        else => 1,
    };
}

/// One user-visible character on screen: its first codepoint, the cells it
/// takes and its byte length.
pub const Cell = struct { cp: u21, w: usize, len: usize };

/// The character at byte `i`, at column `col`, with tab stops every
/// `default_tab_width` columns.
pub fn cells(l: []const u8, i: usize, col: usize) Cell {
    return cellsTab(l, i, col, default_tab_width);
}

/// `cells` with tab stops every `tw` columns. A character's extending code
/// points take no cells of their own, and an emoji variation selector makes
/// it two cells wide.
pub fn cellsTab(l: []const u8, i: usize, col: usize, tw: usize) Cell {
    if (l[i] == '\t') return .{ .cp = '\t', .w = tw - col % tw, .len = 1 };
    if (l[i] < 0x80 and (l[i] < 0x20 or i + 1 == l.len or l[i + 1] < 0x80)) return .{ .cp = l[i], .w = 1, .len = 1 };
    const d = decode(l, i);
    const end = nextCluster(l, i);
    var w = width(d.cp);
    if (w == 1 and std.mem.indexOf(u8, l[i + d.len .. end], "\u{FE0F}") != null) w = 2;
    return .{ .cp = d.cp, .w = w, .len = end - i };
}

/// Display column of byte `n`, starting at byte `from` and column `col0`.
pub fn colOf(l: []const u8, from: usize, col0: usize, n: usize) usize {
    return colOfTab(l, from, col0, n, default_tab_width);
}

/// `colOf` with tab stops every `tw` columns.
pub fn colOfTab(l: []const u8, from: usize, col0: usize, n: usize, tw: usize) usize {
    var col = col0;
    var i = from;
    while (i < n and i < l.len) {
        const c = cellsTab(l, i, col, tw);
        col += c.w;
        i += c.len;
    }
    return col;
}

/// The byte in `l` nearest to display column `x`, never inside a character.
pub fn byteAtCol(l: []const u8, x: f64) usize {
    return byteAtColTab(l, x, default_tab_width);
}

/// `byteAtCol` with tab stops every `tw` columns.
pub fn byteAtColTab(l: []const u8, x: f64, tw: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < l.len) {
        const c = cellsTab(l, i, col, tw);
        if (x < @as(f64, @floatFromInt(col)) + @as(f64, @floatFromInt(c.w)) / 2) return i;
        col += c.w;
        i += c.len;
    }
    return l.len;
}

/// How far a bracket match looks before giving up, so a stray bracket in a
/// huge file costs a bounded scan.
pub const bracket_scan_cap = 1 << 20;

/// The partner of the bracket at byte `pos`, counting nesting of the same
/// kind. Null when `pos` isn't a bracket or its partner isn't within
/// `bracket_scan_cap` bytes.
pub fn matchingBracketAt(t: []const u8, pos: usize) ?usize {
    if (pos >= t.len) return null;
    const c = t[pos];
    const other: u8 = switch (c) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        else => return null,
    };
    const fwd = c == '(' or c == '[' or c == '{';
    var depth: usize = 0;
    var i = pos;
    for (0..bracket_scan_cap) |_| {
        if (fwd) {
            i += 1;
            if (i >= t.len) return null;
        } else {
            if (i == 0) return null;
            i -= 1;
        }
        if (t[i] == c) {
            depth += 1;
        } else if (t[i] == other) {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    return null;
}

/// Where a position in or just past a block of swapped lines goes: `by`
/// bytes down or up, or to `past` when it was after the block's end `hi`.
fn mapSwap(p: usize, hi: usize, by: usize, down: bool, past: usize) usize {
    if (p > hi) return past;
    return if (down) p + by else p - by;
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

test "word and line queries leave selection and motion state alone" {
    var e = try Editor.init(gpa_t, "one two\r\n漢字");
    defer e.deinit(gpa_t);
    e.select(0, 3);
    e.want = 5;
    e.typing = true;
    try t_.expectEqual(@as(?[2]usize, .{ 4, 7 }), e.wordAt(5));
    try t_.expectEqual(@as(?[2]usize, .{ 7, 7 }), e.wordAt(7));
    try t_.expectEqual([2]usize{ 0, 9 }, e.lineAt(5));
    try t_.expectEqual([2]usize{ 9, 15 }, e.lineAt(15));
    try t_.expectEqual([2]usize{ 0, 3 }, e.sel());
    try t_.expectEqual(@as(?usize, 5), e.want);
    try t_.expect(e.typing);
    try t_.expectEqual(@as(usize, 9), charStart(e.text(), 11));
    try t_.expectEqual(@as(usize, 15), charStart(e.text(), 15));
    try t_.expectEqual(@as(usize, 12), prevChar(e.text(), 15));
    try t_.expectEqual(@as(usize, 6), colOf("漢\t字", 3, 2, 7));
    var empty = try Editor.init(gpa_t, "");
    defer empty.deinit(gpa_t);
    try t_.expectEqual(@as(?[2]usize, null), empty.wordAt(0));
    try t_.expectEqual([2]usize{ 0, 0 }, empty.lineAt(0));
    try t_.expectEqual(@as(?[2]usize, null), try empty.undo(gpa_t));
    try t_.expectEqual(@as(?[2]usize, null), try empty.redo(gpa_t));
}

test "cells returns the decoded codepoint with its width and byte length" {
    const cases = .{
        .{ "a", 0, @as(u21, 'a'), 1, 1 },
        .{ "\t", 1, @as(u21, '\t'), default_tab_width - 1, 1 },
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
    try t_.expectEqual(@as(usize, 7), byteAtCol("漢字abc", 5.0));
}

test "newline keeps indentation and undo is one step per typing run" {
    var e = try Editor.init(gpa_t, "fn x() {\n    a");
    defer e.deinit(gpa_t);
    e.move(.bottom, false);
    try e.newline(gpa_t);
    for ("bc") |c| try e.insert(gpa_t, &.{c});
    try t_.expectEqualStrings("fn x() {\n    a\n    bc", e.text());
    _ = try e.undo(gpa_t);
    try t_.expectEqualStrings("fn x() {\n    a\n    ", e.text());
    _ = try e.undo(gpa_t);
    try t_.expectEqualStrings("fn x() {\n    a", e.text());
}

test "CRLF files get CRLF newlines" {
    var e = try Editor.init(gpa_t, "a\r\nb");
    defer e.deinit(gpa_t);
    e.move(.end, false);
    try e.newline(gpa_t);
    try t_.expectEqualStrings("a\r\n\r\nb", e.text());
}

test "pasted breaks take the file's line ending" {
    var crlf = try Editor.init(gpa_t, "a\r\nb");
    defer crlf.deinit(gpa_t);
    crlf.moveTo(1, false);
    try crlf.paste(gpa_t, "x\ny\r\nz");
    try t_.expectEqualStrings("ax\r\ny\r\nz\r\nb", crlf.text());
    var lf = try Editor.init(gpa_t, "a\nb");
    defer lf.deinit(gpa_t);
    lf.moveTo(1, false);
    try lf.paste(gpa_t, "x\r\ny\n");
    try t_.expectEqualStrings("ax\ny\n\nb", lf.text());
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
    _ = try e.undo(gpa_t);
    try t_.expectEqualStrings("", e.text());
}

test "emoji built from several code points join the typing run" {
    var e = try Editor.init(gpa_t, "");
    defer e.deinit(gpa_t);
    for ([_][]const u8{ "h", "\u{2764}\u{FE0F}", "\u{1F44D}\u{1F3FD}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F1EF}\u{1F1F5}", "e\u{0301}", "x" }) |s| try e.insert(gpa_t, s);
    _ = try e.undo(gpa_t);
    try t_.expectEqualStrings("", e.text());
    for ([_][]const u8{ "ab", "\u{1F1EF}\u{1F1F5}\u{1F1EF}", "\r\n" }) |s| try t_.expect(!oneCluster(s));
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

test "comment toggle and outdent with only a caret keep the caret on its character" {
    var e = try Editor.init(gpa_t, "    ab\n");
    defer e.deinit(gpa_t);
    e.select(5, 5);
    try e.toggleComment(gpa_t, "//");
    try t_.expectEqualStrings("    // ab\n", e.text());
    try t_.expectEqual([2]usize{ 8, 8 }, e.sel());
    try e.toggleComment(gpa_t, "//");
    try t_.expectEqual([2]usize{ 5, 5 }, e.sel());
    try e.outdent(gpa_t);
    try t_.expectEqualStrings("ab\n", e.text());
    try t_.expectEqual([2]usize{ 1, 1 }, e.sel());
}

test "format JSON indents nesting and keeps keys, numbers and strings as written" {
    var e = try Editor.init(gpa_t, "\n{\"b\":[1.50,{},[ ]],\"a\":\"x\\\"{,\"}\n");
    defer e.deinit(gpa_t);
    try t_.expect(try e.formatJson(gpa_t));
    try t_.expectEqualStrings("\n{\n    \"b\": [\n        1.50,\n        {},\n        []\n    ],\n    \"a\": \"x\\\"{,\"\n}\n", e.text());
    _ = try e.undo(gpa_t);
    try t_.expectEqualStrings("\n{\"b\":[1.50,{},[ ]],\"a\":\"x\\\"{,\"}\n", e.text());
}

test "format JSON keeps the caret on the token or string byte it was on" {
    const src = "\n{\"b\":[1.50,{},[ ]],\"a\":\"x\\\"{,\"}\n";
    for ([_][2]usize{ .{ 9, 24 }, .{ 28, 71 }, .{ 31, 75 }, .{ 32, 76 }, .{ 0, 0 } }) |c| {
        var e = try Editor.init(gpa_t, src);
        defer e.deinit(gpa_t);
        e.select(c[0], c[0]);
        try t_.expect(try e.formatJson(gpa_t));
        try t_.expectEqual([2]usize{ c[1], c[1] }, e.sel());
    }
}

test "format JSON leaves text that isn't JSON alone and works on a selection" {
    var e = try Editor.init(gpa_t, "x = {\"a\":1}\n{oops}");
    defer e.deinit(gpa_t);
    try t_.expect(!try e.formatJson(gpa_t));
    try t_.expectEqualStrings("x = {\"a\":1}\n{oops}", e.text());
    e.select(4, 11);
    try t_.expect(try e.formatJson(gpa_t));
    try t_.expectEqualStrings("x = {\n    \"a\": 1\n}\n{oops}", e.text());
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

test "tab indents one whole selected line in either direction" {
    var e = try Editor.init(gpa_t, "ab\nc");
    defer e.deinit(gpa_t);
    e.select(0, 2);
    try e.tab(gpa_t);
    try t_.expectEqualStrings("    ab\nc", e.text());
    e.select(6, 0);
    try e.tab(gpa_t);
    try t_.expectEqualStrings("        ab\nc", e.text());
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

test "search finds folded matches past the 32-byte blocks and counting stops at the cap" {
    var buf: [116]u8 = @splat('x');
    @memcpy(buf[70..73], "Foo");
    @memcpy(buf[113..], "fOO");
    const long: []const u8 = &buf;
    try t_.expectEqual(@as(?usize, 70), search(long, "foo", 0, false));
    try t_.expectEqual(@as(?usize, 113), search(long, "foo", 71, false));
    try t_.expectEqual(@as(?usize, 113), search(long, "foo", 0, true));
    try t_.expectEqual([2]usize{ 1, 2 }, countMatches(long, "foo", 100));
    const many: [count_cap + 5]u8 = @splat('a');
    try t_.expectEqual([2]usize{ 3, count_cap }, countMatches(&many, "a", 3));
    try t_.expectEqual([2]usize{ count_cap, count_cap }, countMatches(&many, "a", many.len));
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
    var spots: [2][2]usize = undefined;
    try t_.expectEqual(@as(usize, 3), try e.replaceAll(gpa_t, "foo", "x", &spots));
    try t_.expectEqual([2][2]usize{ .{ 2, 3 }, .{ 6, 7 } }, spots);
    try t_.expectEqualStrings("a x b x x", e.text());
    try t_.expectEqual(@as(?[2]usize, .{ 2, 15 }), try e.undo(gpa_t));
    try t_.expectEqualStrings("a foo b FOO foo", e.text());
    try t_.expectEqual(@as(usize, 1), try e.replaceAll(gpa_t, "FOO", "y", &.{}));
    try t_.expectEqualStrings("a foo b y foo", e.text());
    _ = try e.undo(gpa_t);
    try t_.expectEqual(@as(usize, 3), try e.replaceAll(gpa_t, "foo", "longer", &spots));
    try t_.expectEqual([2][2]usize{ .{ 2, 8 }, .{ 11, 17 } }, spots);
    try t_.expectEqual(@as(?[2]usize, .{ 2, 15 }), try e.undo(gpa_t));
    try t_.expectEqual(@as(?[2]usize, .{ 2, 24 }), try e.redo(gpa_t));
    try t_.expectEqual(@as(usize, 24), e.cur);
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
    _ = try e.undo(gpa_t);
    try t_.expectEqualStrings("zero\none\ntwo\nthree\n", e.text());
}

test "reload picks up the new file's line ending and indent" {
    var e = try Editor.init(gpa_t, "a\r\n\tb\r\n");
    defer e.deinit(gpa_t);
    try t_.expectEqualStrings("\r\n", e.eol);
    try t_.expectEqualStrings("\t", e.indent);
    try e.reload(gpa_t, "a\n    b\n");
    try t_.expectEqualStrings("\n", e.eol);
    try t_.expectEqualStrings("    ", e.indent);
}

test "reload keeps a changed multi-byte character whole for undo and redo" {
    var e = try Editor.init(gpa_t, "\xC3\xA1");
    defer e.deinit(gpa_t);
    try e.reload(gpa_t, "\xC2\xA1");
    _ = try e.undo(gpa_t);
    try t_.expectEqualStrings("\xC3\xA1", e.text());
    _ = try e.redo(gpa_t);
    try t_.expectEqualStrings("\xC2\xA1", e.text());
    try t_.expectEqual(@as(usize, 2), e.cur);
}

test "matching bracket prefers the one after the caret and counts nesting" {
    var e = try Editor.init(gpa_t, "f(a[b]{c})");
    defer e.deinit(gpa_t);
    e.moveTo(1, false);
    try t_.expectEqual(@as(?[2]usize, .{ 1, 9 }), e.matchingBracket());
    e.moveTo(10, false);
    try t_.expectEqual(@as(?[2]usize, .{ 9, 1 }), e.matchingBracket());
    e.moveTo(4, false);
    try t_.expectEqual(@as(?[2]usize, .{ 3, 5 }), e.matchingBracket());
    e.moveTo(0, false);
    try t_.expectEqual(@as(?[2]usize, null), e.matchingBracket());
    try t_.expectEqual(@as(?usize, null), matchingBracketAt("(()", 0));
}

test "clusters keep combining marks, joined emoji and flags whole" {
    const accent = "e\u{0301}x";
    try t_.expectEqual(@as(usize, 3), nextCluster(accent, 0));
    try t_.expectEqual(@as(usize, 0), prevCluster(accent, 3));
    const family = "\u{1F468}\u{200D}\u{1F469}";
    try t_.expectEqual(@as(usize, family.len), nextCluster(family, 0));
    try t_.expectEqual(@as(usize, 0), prevCluster(family, family.len));
    const flags = "\u{1F1EF}\u{1F1F5}\u{1F1EF}\u{1F1F5}";
    try t_.expectEqual(@as(usize, 8), nextCluster(flags, 0));
    try t_.expectEqual(@as(usize, 8), prevCluster(flags, 16));
    try t_.expectEqual(@as(usize, 0), prevCluster(flags, 8));
    try t_.expectEqual(@as(usize, 2), nextCluster("a\n\u{0301}", 1));
    const c = cells(accent, 0, 0);
    try t_.expectEqual(@as(usize, 1), c.w);
    try t_.expectEqual(@as(usize, 3), c.len);
    try t_.expectEqual(@as(usize, 2), colOf(accent, 0, 0, accent.len));
    try t_.expectEqual(@as(usize, 3), byteAtCol(accent, 0.9));
    try t_.expectEqual(@as(usize, 2), cells("\u{2764}\u{FE0F}", 0, 0).w);
    try t_.expectEqual(@as(usize, 2), cells("\u{1F680}", 0, 0).w);
    try t_.expectEqual(@as(usize, 2), cells("\u{1F1EF}\u{1F1F5}", 0, 0).w);
    try t_.expectEqual(@as(usize, 9), colOfTab("\tx", 0, 0, 2, 8));
}

test "caret motion and backspace step over a whole emoji with a skin tone" {
    var e = try Editor.init(gpa_t, "a\u{1F44D}\u{1F3FD}b");
    defer e.deinit(gpa_t);
    e.moveTo(1, false);
    e.move(.right, false);
    try t_.expectEqual(@as(usize, 9), e.cur);
    e.move(.left, false);
    try t_.expectEqual(@as(usize, 1), e.cur);
    e.moveTo(9, false);
    try e.deleteBack(gpa_t, .char);
    try t_.expectEqualStrings("ab", e.text());
}

test "search options set the case rule and whole-word matching" {
    const s = "foo food Foo";
    try t_.expectEqual([2]usize{ 2, 2 }, countMatchesWith(s, "foo", s.len, .{ .whole_word = true }));
    try t_.expectEqual([2]usize{ 2, 2 }, countMatchesWith(s, "foo", s.len, .{ .case_mode = .sensitive }));
    try t_.expectEqual([2]usize{ 1, 1 }, countMatchesWith(s, "foo", s.len, .{ .case_mode = .sensitive, .whole_word = true }));
    try t_.expectEqual([2]usize{ 3, 3 }, countMatchesWith(s, "Foo", s.len, .{ .case_mode = .insensitive }));
    try t_.expectEqual(@as(?usize, 9), searchWith(s, "foo", 1, false, .{ .whole_word = true }));
    try t_.expectEqual([2]usize{ 1, 1 }, countMatchesWith("x.foo", ".foo", 5, .{ .whole_word = true }));
    var e = try Editor.init(gpa_t, "foo food foo");
    defer e.deinit(gpa_t);
    try t_.expectEqual(@as(usize, 2), try e.replaceAllWith(gpa_t, "foo", "x", &.{}, .{ .whole_word = true }));
    try t_.expectEqualStrings("x food x", e.text());
    try t_.expect(e.findWith("FOOD", 0, false, .{ .case_mode = .insensitive }));
    try t_.expect(try e.replaceOneWith(gpa_t, "FOOD", "y", .{ .case_mode = .insensitive }));
    try t_.expectEqualStrings("x y x", e.text());
}

test "duplicate, move, join and delete lines are one undo step each" {
    var e = try Editor.init(gpa_t, "a\nb");
    defer e.deinit(gpa_t);
    e.moveTo(1, false);
    try e.duplicateLine(gpa_t);
    try t_.expectEqualStrings("a\na\nb", e.text());
    try t_.expectEqual([2]usize{ 3, 3 }, e.sel());
    _ = try e.undo(gpa_t);
    try t_.expectEqualStrings("a\nb", e.text());

    var m = try Editor.init(gpa_t, "a\nb\nc");
    defer m.deinit(gpa_t);
    try m.moveLinesUp(gpa_t);
    try t_.expectEqualStrings("a\nb\nc", m.text());
    try m.moveLinesDown(gpa_t);
    try t_.expectEqualStrings("b\na\nc", m.text());
    try t_.expectEqual([2]usize{ 2, 2 }, m.sel());
    try m.moveLinesUp(gpa_t);
    try t_.expectEqualStrings("a\nb\nc", m.text());
    try t_.expectEqual([2]usize{ 0, 0 }, m.sel());
    m.select(0, 4);
    try m.moveLinesDown(gpa_t);
    try t_.expectEqualStrings("c\na\nb", m.text());
    try t_.expectEqual([2]usize{ 2, 5 }, m.sel());
    _ = try m.undo(gpa_t);
    try t_.expectEqualStrings("a\nb\nc", m.text());

    var j = try Editor.init(gpa_t, "a\n  b\n\nc ");
    defer j.deinit(gpa_t);
    try j.joinLines(gpa_t);
    try t_.expectEqualStrings("a b\n\nc ", j.text());
    try t_.expectEqual([2]usize{ 1, 1 }, j.sel());
    j.selectAll();
    try j.joinLines(gpa_t);
    try t_.expectEqualStrings("a b c ", j.text());
    try t_.expectEqual([2]usize{ 0, 6 }, j.sel());

    var d = try Editor.init(gpa_t, "a\nbc\nd");
    defer d.deinit(gpa_t);
    d.moveTo(3, false);
    try d.deleteLine(gpa_t);
    try t_.expectEqualStrings("a\nd", d.text());
    try t_.expectEqual([2]usize{ 3, 3 }, d.sel());
    try d.deleteLine(gpa_t);
    try t_.expectEqualStrings("a", d.text());
    try t_.expectEqual([2]usize{ 1, 1 }, d.sel());
}

test "trim trailing whitespace and final newline keep the caret on its character" {
    var e = try Editor.init(gpa_t, "a  \n b\t\r\nc");
    defer e.deinit(gpa_t);
    e.select(2, 9);
    try e.trimTrailingWhitespace(gpa_t);
    try t_.expectEqualStrings("a\n b\r\nc", e.text());
    try t_.expectEqual([2]usize{ 1, 6 }, e.sel());
    try e.ensureFinalNewline(gpa_t);
    try t_.expectEqualStrings("a\n b\r\nc\n", e.text());
    try e.ensureFinalNewline(gpa_t);
    try t_.expectEqualStrings("a\n b\r\nc\n", e.text());
    var empty = try Editor.init(gpa_t, "");
    defer empty.deinit(gpa_t);
    try empty.ensureFinalNewline(gpa_t);
    try t_.expectEqualStrings("", empty.text());
}

test "tab width sets tab stops, indent and outdent" {
    var e = try Editor.init(gpa_t, "x");
    defer e.deinit(gpa_t);
    e.tab_width = 2;
    e.moveTo(1, false);
    try e.tab(gpa_t);
    try t_.expectEqualStrings("x ", e.text());
    e.select(0, 2);
    try e.tab(gpa_t);
    try t_.expectEqualStrings("  x ", e.text());
    var o = try Editor.init(gpa_t, "    a");
    defer o.deinit(gpa_t);
    o.tab_width = 2;
    try o.outdent(gpa_t);
    try t_.expectEqualStrings("  a", o.text());
}
