//! The text of one file: bytes, where each line starts, and undo history.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// One change: `old` at `pos` was replaced by `new`. `seq` tells saved
/// states apart; `before` is where the caret was.
pub const Edit = struct { pos: usize, old: []u8, new: []u8, before: usize, seq: u64 };

pub const Buffer = struct {
    text: std.ArrayList(u8) = .empty,
    /// Byte offset of each line's first byte. Always starts with 0.
    starts: std.ArrayList(u32) = .empty,
    /// UTF-16 units before each line's first byte, as NSString counts them,
    /// in step with `starts`. Empty until `unitStarts` first builds it.
    units: std.ArrayList(u32) = .empty,
    undos: std.ArrayList(Edit) = .empty,
    redos: std.ArrayList(Edit) = .empty,
    seq: u64 = 0,
    saved: u64 = 0,
    /// Counts every change to the text, undo and redo too.
    changes: u64 = 0,
    /// The first line changed since the syntax cache last looked.
    touched: usize = 0,
    /// Exclusive end of the changed lines; shifting line numbers invalidates
    /// the whole suffix instead. Both reset when the syntax cache catches up.
    touched_end: usize = 0,
    lines_shifted: bool = true,
    /// Runs of non-white-space bytes, counted on first `wordCount` and then
    /// maintained at the splice boundaries; null until something asks.
    words: ?usize = null,
    /// Screen rows of each line for soft wrap, kept by the view; empty while
    /// wrap is off. An edit zeroes the lines it touches, and `wraps_from` is
    /// the first line zeroed since the view last caught up.
    wraps: std.ArrayList(u32) = .empty,
    /// Column width the cached row counts were measured at.
    wraps_cols: usize = 0,
    wraps_from: usize = std.math.maxInt(usize),

    pub fn init(gpa: Allocator, bytes: []const u8) !Buffer {
        var b: Buffer = .{};
        errdefer b.deinit(gpa);
        try b.text.ensureTotalCapacityPrecise(gpa, bytes.len);
        b.text.appendSliceAssumeCapacity(bytes);
        try b.starts.ensureTotalCapacityPrecise(gpa, std.mem.count(u8, bytes, "\n") + 1);
        b.starts.appendAssumeCapacity(0);
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |i| {
            pos = i + 1;
            b.starts.appendAssumeCapacity(@intCast(pos));
        }
        return b;
    }

    pub fn deinit(b: *Buffer, gpa: Allocator) void {
        for (b.undos.items) |e| free(gpa, e);
        for (b.redos.items) |e| free(gpa, e);
        b.undos.deinit(gpa);
        b.redos.deinit(gpa);
        b.wraps.deinit(gpa);
        b.units.deinit(gpa);
        b.starts.deinit(gpa);
        b.text.deinit(gpa);
    }

    pub fn lines(b: *const Buffer) usize {
        return b.starts.items.len;
    }

    pub fn lineStart(b: *const Buffer, i: usize) usize {
        return b.starts.items[i];
    }

    /// End of line `i`, before its `\n` (and a `\r` in front of it).
    pub fn lineEnd(b: *const Buffer, i: usize) usize {
        if (i + 1 >= b.starts.items.len) return b.text.items.len;
        var e: usize = b.starts.items[i + 1] - 1;
        if (e > b.starts.items[i] and b.text.items[e - 1] == '\r') e -= 1;
        return e;
    }

    /// Start of the next line, or the end of the text.
    pub fn lineStop(b: *const Buffer, i: usize) usize {
        return if (i + 1 < b.lines()) b.lineStart(i + 1) else b.text.items.len;
    }

    pub fn line(b: *const Buffer, i: usize) []const u8 {
        return b.text.items[b.lineStart(i)..b.lineEnd(i)];
    }

    /// The line that holds byte `pos`.
    pub fn lineOf(b: *const Buffer, pos: usize) usize {
        return lastAtMost(b.starts.items, pos);
    }

    /// UTF-16 units before each line's start, built on first call and then
    /// maintained by every edit, so VoiceOver's ranges cost one line's walk.
    pub fn unitStarts(b: *Buffer, gpa: Allocator) ![]const u32 {
        if (b.units.items.len == 0) {
            try b.units.ensureTotalCapacityPrecise(gpa, b.lines());
            var u: u32 = 0;
            b.units.appendAssumeCapacity(0);
            for (b.starts.items[1..], b.starts.items[0 .. b.lines() - 1]) |s, prev| {
                u += @intCast(utf16Units(b.text.items, prev, s));
                b.units.appendAssumeCapacity(u);
            }
        }
        return b.units.items;
    }

    pub fn dirty(b: *const Buffer) bool {
        return b.top() != b.saved;
    }

    pub fn markSaved(b: *Buffer) void {
        b.saved = b.top();
    }

    pub fn markUnsaved(b: *Buffer) void {
        b.saved = std.math.maxInt(u64);
    }

    fn top(b: *const Buffer) u64 {
        return if (b.undos.items.len > 0) b.undos.items[b.undos.items.len - 1].seq else 0;
    }

    /// Replaces `start..end` with `new` and records it for undo. With `join`,
    /// typing or deleting next to the last edit extends it instead.
    pub fn replace(b: *Buffer, gpa: Allocator, start: usize, end: usize, new: []const u8, caret: usize, join: bool) !void {
        if (start == end and new.len == 0) return;
        const old = b.text.items[start..end];
        b.seq += 1;
        // Never extend an edit that is the saved state, or undo would step past it.
        if (join and b.undos.items.len > 0 and b.top() != b.saved) {
            const last = &b.undos.items[b.undos.items.len - 1];
            if (old.len == 0 and last.old.len == 0 and start == last.pos + last.new.len) {
                last.new = try grow(gpa, last.new, new, false);
            } else if (new.len == 0 and last.new.len == 0 and end == last.pos) {
                last.old = try grow(gpa, last.old, old, true);
                last.pos = start;
            } else if (new.len == 0 and last.new.len == 0 and start == last.pos) {
                last.old = try grow(gpa, last.old, old, false);
            } else return b.record(gpa, start, end, new, caret);
            try b.splice(gpa, start, end, new);
            return;
        }
        try b.record(gpa, start, end, new, caret);
    }

    fn record(b: *Buffer, gpa: Allocator, start: usize, end: usize, new: []const u8, caret: usize) !void {
        const e: Edit = .{
            .pos = start,
            .old = try gpa.dupe(u8, b.text.items[start..end]),
            .new = try gpa.dupe(u8, new),
            .before = caret,
            .seq = b.seq,
        };
        try b.undos.append(gpa, e);
        for (b.redos.items) |r| free(gpa, r);
        b.redos.clearRetainingCapacity();
        try b.splice(gpa, start, end, new);
    }

    /// Undoes the last edit and returns the restored change.
    pub fn undo(b: *Buffer, gpa: Allocator) !?Edit {
        const e = b.undos.pop() orelse return null;
        try b.redos.append(gpa, e);
        try b.splice(gpa, e.pos, e.pos + e.new.len, e.old);
        return e;
    }

    pub fn redo(b: *Buffer, gpa: Allocator) !?Edit {
        const e = b.redos.pop() orelse return null;
        try b.undos.append(gpa, e);
        try b.splice(gpa, e.pos, e.pos + e.old.len, e.new);
        return e;
    }

    /// Swaps the bytes and keeps `starts` in step without rescanning the file.
    fn splice(b: *Buffer, gpa: Allocator, start: usize, end: usize, new: []const u8) !void {
        const first = b.lineOf(start);
        const last = b.lineOf(end);
        const removed_words = if (b.words != null) wordStarts(b.text.items, start, @min(end + 1, b.text.items.len)) else 0;
        try b.text.replaceRange(gpa, start, end - start, new);
        if (b.words) |*w| w.* = w.* - removed_words + wordStarts(b.text.items, start, @min(start + new.len + 1, b.text.items.len));
        b.changes += 1;

        var added: std.ArrayList(u32) = .empty;
        defer added.deinit(gpa);
        for (new, 0..) |c, i| if (c == '\n') try added.append(gpa, @intCast(start + i + 1));
        try b.starts.replaceRange(gpa, first + 1, last - first, added.items);
        if (b.wraps.items.len > 0) {
            @memset(added.items, 0);
            try b.wraps.replaceRange(gpa, first + 1, last - first, added.items);
            b.wraps.items[first] = 0;
            b.wraps_from = @min(b.wraps_from, first);
        }

        const delta: i64 = @as(i64, @intCast(new.len)) - @as(i64, @intCast(end - start));
        for (b.starts.items[first + 1 + added.items.len ..]) |*s| s.* = @intCast(@as(i64, s.*) + delta);
        if (b.units.items.len > 0) b.spliceUnits(gpa, first, last, added.items.len);
        b.touched = @min(b.touched, first);
        b.touched_end = @max(b.touched_end, first + added.items.len + 1);
        b.lines_shifted = b.lines_shifted or last - first != added.items.len;
    }

    /// Recounts the edited lines' units and shifts the lines after them.
    /// Runs after `starts` is up to date; a failed grow drops the table.
    fn spliceUnits(b: *Buffer, gpa: Allocator, first: usize, last: usize, added: usize) void {
        b.units.replaceRange(gpa, first + 1, last - first, b.starts.items[first + 1 .. first + 1 + added]) catch {
            b.units.clearAndFree(gpa);
            return;
        };
        const s = b.starts.items;
        const u = b.units.items;
        const stop = first + 1 + added;
        for (first + 1..@min(stop + 1, u.len)) |k| {
            const n: u32 = @intCast(utf16Units(b.text.items, s[k - 1], s[k]));
            if (k == stop) {
                const delta = @as(i64, u[k - 1] + n) - u[k];
                for (u[stop..]) |*x| x.* = @intCast(@as(i64, x.*) + delta);
            } else u[k] = u[k - 1] + n;
        }
    }

    pub fn wordCount(b: *Buffer) usize {
        if (b.words == null) b.words = wordStarts(b.text.items, 0, b.text.items.len);
        return b.words.?;
    }

    fn free(gpa: Allocator, e: Edit) void {
        gpa.free(e.old);
        gpa.free(e.new);
    }
};

/// Index of the last sorted entry at or before `pos`; `v` starts with zero.
pub fn lastAtMost(v: []const u32, pos: usize) usize {
    var lo: usize = 0;
    var hi: usize = v.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (v[mid] <= pos) lo = mid else hi = mid;
    }
    return lo;
}

/// UTF-16 units in `s[from..to]`, both at character starts, as NSString
/// counts them; each bad byte is one U+FFFD, as `editor.decode` reads it.
pub fn utf16Units(s: []const u8, from: usize, to: usize) usize {
    var n: usize = 0;
    var i = from;
    while (i < to and i < s.len) {
        if (s[i] < 0x80) {
            n += 1;
            i += 1;
            continue;
        }
        const k = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const ok = k > 1 and i + k <= s.len and if (std.unicode.utf8Decode(s[i .. i + k])) |_| true else |_| false;
        n += if (ok and k == 4) 2 else 1;
        i += if (ok) k else 1;
    }
    return n;
}

/// Word starts whose byte lies in `start..end`, including boundary context.
fn wordStarts(s: []const u8, start: usize, end: usize) usize {
    var n: usize = 0;
    for (start..end) |i| {
        n += @intFromBool(!std.ascii.isWhitespace(s[i]) and (i == 0 or std.ascii.isWhitespace(s[i - 1])));
    }
    return n;
}

/// Extends `old` with the other slice, preserving it across reallocations.
fn grow(gpa: Allocator, old: []u8, extra: []const u8, prepend: bool) ![]u8 {
    const out = try gpa.realloc(old, old.len + extra.len);
    if (prepend) std.mem.copyBackwards(u8, out[extra.len..], out[0..old.len]);
    @memcpy(if (prepend) out[0..extra.len] else out[old.len..], extra);
    return out;
}

const t = std.testing;

fn expectStarts(b: *const Buffer) !void {
    var want: std.ArrayList(u32) = .empty;
    defer want.deinit(t.allocator);
    try want.append(t.allocator, 0);
    for (b.text.items, 0..) |c, i| if (c == '\n') try want.append(t.allocator, @intCast(i + 1));
    try t.expectEqualSlices(u32, want.items, b.starts.items);
}

test "initial text and line starts have exact capacity" {
    for ([_][]const u8{ "", "one", "\n", "one\ntwo\n", "one\r\n\r\ntwo" }) |bytes| {
        var b = try Buffer.init(t.allocator, bytes);
        defer b.deinit(t.allocator);
        try t.expectEqualStrings(bytes, b.text.items);
        try t.expectEqual(bytes.len, b.text.capacity);
        try t.expectEqual(std.mem.count(u8, bytes, "\n") + 1, b.starts.capacity);
        try expectStarts(&b);
    }
}

test "line starts stay right through random edits, undo and redo" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var b = try Buffer.init(t.allocator, "one\ntwo\n\nthree\r\nfour");
    defer b.deinit(t.allocator);
    try b.wraps.appendNTimes(t.allocator, 1, b.lines());
    const pieces = [_][]const u8{ "", "x", "\n", "a\nb", "\n\n", "long piece\nwith\nlines\n" };
    for (0..400) |_| {
        const n = b.text.items.len;
        const s = r.uintAtMost(usize, n);
        const e = s + r.uintAtMost(usize, @min(n - s, 6));
        switch (r.uintLessThan(u8, 4)) {
            0 => _ = try b.undo(t.allocator),
            1 => _ = try b.redo(t.allocator),
            else => try b.replace(t.allocator, s, e, pieces[r.uintLessThan(usize, pieces.len)], s, r.boolean()),
        }
        try expectStarts(&b);
        var words = std.mem.tokenizeAny(u8, b.text.items, " \t\n\r\x0b\x0c");
        var count: usize = 0;
        while (words.next() != null) count += 1;
        try t.expectEqual(count, b.wordCount());
        try t.expectEqual(b.lines(), b.wraps.items.len);
    }
}

test "UTF-16 line offsets match a fresh count through random edits, undo and redo" {
    try t.expectEqual(@as(usize, 8), utf16Units("a\xc3\xa9\xf0\x9f\x98\x80\xff\xe2\x82\n", 0, 11));
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    var b = try Buffer.init(t.allocator, "one\nt\xc3\xa9o\n\n\xf0\x9f\x98\x80\r\nfour");
    defer b.deinit(t.allocator);
    _ = try b.unitStarts(t.allocator);
    const pieces = [_][]const u8{ "", "x", "\n", "\xc3\xa9", "\xf0\x9f\x98\x80\n", "\xff", "a\n\xe2\x82\xacb\n" };
    for (0..600) |_| {
        const n = b.text.items.len;
        const s = r.uintAtMost(usize, n);
        const e = s + r.uintAtMost(usize, @min(n - s, 6));
        switch (r.uintLessThan(u8, 4)) {
            0 => _ = try b.undo(t.allocator),
            1 => _ = try b.redo(t.allocator),
            else => try b.replace(t.allocator, s, e, pieces[r.uintLessThan(usize, pieces.len)], s, r.boolean()),
        }
        var fresh = try Buffer.init(t.allocator, b.text.items);
        defer fresh.deinit(t.allocator);
        try t.expectEqualSlices(u32, try fresh.unitStarts(t.allocator), b.units.items);
    }
}

test "undo walks typing back to the saved text and clears dirty" {
    var b = try Buffer.init(t.allocator, "hi");
    defer b.deinit(t.allocator);
    try b.replace(t.allocator, 2, 2, "!", 2, false);
    b.markSaved();
    for (" there", 3..) |c, i| try b.replace(t.allocator, i, i, &.{c}, i, true);
    try t.expect(b.dirty());
    try t.expectEqual(@as(usize, 3), (try b.undo(t.allocator)).?.before);
    try t.expectEqualStrings("hi!", b.text.items);
    try t.expect(!b.dirty());
    _ = try b.redo(t.allocator);
    try t.expectEqualStrings("hi! there", b.text.items);
    try t.expect(b.dirty());
}

test "joining an edit after a save still leaves the buffer dirty" {
    var b = try Buffer.init(t.allocator, "");
    defer b.deinit(t.allocator);
    try b.replace(t.allocator, 0, 0, "a", 0, true);
    b.markSaved();
    try b.replace(t.allocator, 1, 1, "b", 1, true);
    try t.expect(b.dirty());
}

test "lineEnd stops before a CRLF" {
    var b = try Buffer.init(t.allocator, "ab\r\ncd");
    defer b.deinit(t.allocator);
    try t.expectEqualStrings("ab", b.line(0));
    try t.expectEqualStrings("cd", b.line(1));
    try t.expectEqual(@as(usize, 4), b.lineStop(0));
    try t.expectEqual(@as(usize, 6), b.lineStop(1));
}

test "joined typing and both deletion directions undo and redo whole runs" {
    for (0..3) |mode| {
        var b = try Buffer.init(t.allocator, if (mode == 0) "" else "abcdef");
        defer b.deinit(t.allocator);
        for (0..6) |i| {
            if (mode == 0) {
                try b.replace(t.allocator, i, i, "abcdef"[i .. i + 1], i, true);
            } else {
                const start = if (mode == 1) 5 - i else 0;
                try b.replace(t.allocator, start, start + 1, "", start + 1, true);
            }
        }
        try t.expectEqualStrings(if (mode == 0) "abcdef" else "", b.text.items);
        _ = try b.undo(t.allocator);
        try t.expectEqualStrings(if (mode == 0) "" else "abcdef", b.text.items);
        _ = try b.redo(t.allocator);
        try t.expectEqualStrings(if (mode == 0) "abcdef" else "", b.text.items);
    }
}

test "word count tracks splitting and joining words at either boundary" {
    var b = try Buffer.init(t.allocator, "one two");
    defer b.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), b.wordCount());
    try b.replace(t.allocator, 3, 4, "", 3, false);
    try t.expectEqual(@as(?usize, 1), b.words);
    try b.replace(t.allocator, 2, 2, "\t", 2, false);
    try t.expectEqual(@as(?usize, 2), b.words);
    try b.replace(t.allocator, 0, b.text.items.len, "", 0, false);
    try t.expectEqual(@as(?usize, 0), b.words);
    _ = try b.undo(t.allocator);
    try t.expectEqual(@as(?usize, 2), b.words);
    _ = try b.redo(t.allocator);
    try t.expectEqual(@as(?usize, 0), b.words);
}
