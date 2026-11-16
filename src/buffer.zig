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
    shift_at: usize = 0,
    line_delta: ?isize = null,
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

    /// Byte and UTF-16 line offsets must fit in u32, including EOF after a newline.
    const max_bytes: usize = std.math.maxInt(u32);

    fn prospectiveLength(current: usize, removed: usize, added: usize) error{BufferTooLarge}!usize {
        const result = @addWithOverflow(current - removed, added);
        if (result[1] != 0 or result[0] > max_bytes) return error.BufferTooLarge;
        return result[0];
    }

    pub fn init(gpa: Allocator, bytes: []const u8) !Buffer {
        _ = try prospectiveLength(0, 0, bytes.len);
        return initOwned(gpa, try gpa.dupe(u8, bytes));
    }

    /// Takes unconditional ownership of `bytes` and indexes its line starts.
    pub fn initOwned(gpa: Allocator, bytes: []u8) !Buffer {
        var b: Buffer = .{ .text = .fromOwnedSlice(bytes) };
        errdefer b.deinit(gpa);
        _ = try prospectiveLength(0, 0, bytes.len);
        try b.fillStarts(gpa);
        return b;
    }

    fn fillStarts(b: *Buffer, gpa: Allocator) !void {
        const bytes = b.text.items;
        try b.starts.ensureTotalCapacityPrecise(gpa, std.mem.count(u8, bytes, "\n") + 1);
        b.starts.appendAssumeCapacity(0);
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |i| {
            pos = i + 1;
            b.starts.appendAssumeCapacity(@intCast(pos));
        }
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
    /// Returns BufferTooLarge before allocating or changing state if indexes would overflow.
    pub fn replace(b: *Buffer, gpa: Allocator, start: usize, end: usize, new: []const u8, caret: usize, join: bool) !void {
        const new_len = try prospectiveLength(b.text.items.len, end - start, new.len);
        if (start == end and new.len == 0) return;
        // Never extend an edit that is the saved state, or undo would step past it.
        if (join and b.undos.items.len > 0 and b.top() != b.saved) {
            const last = &b.undos.items[b.undos.items.len - 1];
            const insert = start == end and last.old.len == 0 and start == last.pos + last.new.len;
            const prepend = new.len == 0 and last.new.len == 0 and end == last.pos;
            const append = new.len == 0 and last.new.len == 0 and start == last.pos;
            if (!insert and !prepend and !append) return b.record(gpa, start, end, new, caret, new_len);
            // Text growth can move a replacement borrowed from this buffer.
            const new_offset: ?usize = if (insert and @intFromPtr(new.ptr) >= @intFromPtr(b.text.items.ptr) and
                @intFromPtr(new.ptr) < @intFromPtr(b.text.items.ptr) + b.text.items.len)
                @intFromPtr(new.ptr) - @intFromPtr(b.text.items.ptr)
            else
                null;
            const change = try b.prepareSplice(gpa, start, end, new, new_len);
            var replacement: []const u8 = "";
            if (insert) {
                const previous_len = last.new.len;
                const extra = if (new_offset) |offset| b.text.items[offset..][0..new.len] else new;
                last.new = try grow(gpa, last.new, extra, false);
                replacement = last.new[previous_len..];
            } else {
                last.old = try grow(gpa, last.old, b.text.items[start..end], prepend);
                if (prepend) last.pos = start;
            }
            b.seq += 1;
            last.seq = b.seq;
            b.splice(gpa, start, end, replacement, change);
            for (b.redos.items) |r| free(gpa, r);
            b.redos.clearRetainingCapacity();
            return;
        }
        try b.record(gpa, start, end, new, caret, new_len);
    }

    fn record(b: *Buffer, gpa: Allocator, start: usize, end: usize, new: []const u8, caret: usize, new_len: usize) !void {
        const old = try gpa.dupe(u8, b.text.items[start..end]);
        errdefer gpa.free(old);
        const replacement = try gpa.dupe(u8, new);
        errdefer gpa.free(replacement);
        try b.undos.ensureUnusedCapacity(gpa, 1);
        const change = try b.prepareSplice(gpa, start, end, replacement, new_len);
        b.seq += 1;
        b.undos.appendAssumeCapacity(.{
            .pos = start,
            .old = old,
            .new = replacement,
            .before = caret,
            .seq = b.seq,
        });
        b.splice(gpa, start, end, replacement, change);
        for (b.redos.items) |r| free(gpa, r);
        b.redos.clearRetainingCapacity();
    }

    /// Undoes the last edit and returns the restored change.
    pub fn undo(b: *Buffer, gpa: Allocator) !?Edit {
        if (b.undos.items.len == 0) return null;
        const e = b.undos.items[b.undos.items.len - 1];
        const new_len = try prospectiveLength(b.text.items.len, e.new.len, e.old.len);
        try b.redos.ensureUnusedCapacity(gpa, 1);
        const change = try b.prepareSplice(gpa, e.pos, e.pos + e.new.len, e.old, new_len);
        _ = b.undos.pop();
        b.redos.appendAssumeCapacity(e);
        b.splice(gpa, e.pos, e.pos + e.new.len, e.old, change);
        return e;
    }

    pub fn redo(b: *Buffer, gpa: Allocator) !?Edit {
        if (b.redos.items.len == 0) return null;
        const e = b.redos.items[b.redos.items.len - 1];
        const new_len = try prospectiveLength(b.text.items.len, e.old.len, e.new.len);
        try b.undos.ensureUnusedCapacity(gpa, 1);
        const change = try b.prepareSplice(gpa, e.pos, e.pos + e.old.len, e.new, new_len);
        _ = b.redos.pop();
        b.undos.appendAssumeCapacity(e);
        b.splice(gpa, e.pos, e.pos + e.old.len, e.new, change);
        return e;
    }

    const Splice = struct { first: usize, last: usize, added: usize };

    /// Reserves authoritative storage for a checked byte length without changing logical state.
    fn prepareSplice(b: *Buffer, gpa: Allocator, start: usize, end: usize, new: []const u8, new_len: usize) !Splice {
        const first = b.lineOf(start);
        const last = b.lineOf(end);
        const added = std.mem.count(u8, new, "\n");
        const line_count = b.lines() - (last - first) + added;
        try b.starts.ensureTotalCapacity(gpa, line_count);
        if (b.wraps.items.len > 0) try b.wraps.ensureTotalCapacity(gpa, line_count);
        try b.text.ensureTotalCapacity(gpa, new_len);
        return .{ .first = first, .last = last, .added = added };
    }

    /// Commits a prepared edit; only the disposable UTF-16 cache can allocate.
    fn splice(b: *Buffer, gpa: Allocator, start: usize, end: usize, new: []const u8, change: Splice) void {
        const first = change.first;
        const last = change.last;
        const old_lines = last - first;
        const new_lines = change.added;
        const removed_words = if (b.words != null) wordStarts(b.text.items, start, @min(end + 1, b.text.items.len)) else 0;
        b.text.replaceRangeAssumeCapacity(start, end - start, new);
        if (b.words) |*w| w.* = w.* - removed_words + wordStarts(b.text.items, start, @min(start + new.len + 1, b.text.items.len));
        b.changes += 1;

        if (new_lines > old_lines) {
            _ = b.starts.addManyAtAssumeCapacity(first + 1, new_lines - old_lines);
        } else if (old_lines > new_lines) {
            b.starts.replaceRangeAssumeCapacity(first + 1, old_lines - new_lines, &.{});
        }
        var row = first + 1;
        for (new, 0..) |c, i| if (c == '\n') {
            b.starts.items[row] = @intCast(start + i + 1);
            row += 1;
        };
        if (b.wraps.items.len > 0) {
            if (new_lines > old_lines) {
                _ = b.wraps.addManyAtAssumeCapacity(first + 1, new_lines - old_lines);
            } else if (old_lines > new_lines) {
                b.wraps.replaceRangeAssumeCapacity(first + 1, old_lines - new_lines, &.{});
            }
            @memset(b.wraps.items[first .. first + new_lines + 1], 0);
            b.wraps_from = @min(b.wraps_from, first);
        }

        const delta: i64 = @as(i64, @intCast(new.len)) - @as(i64, @intCast(end - start));
        for (b.starts.items[first + 1 + new_lines ..]) |*s| s.* = @intCast(@as(i64, s.*) + delta);
        if (b.units.items.len > 0) b.spliceUnits(gpa, first, last, new_lines);
        const prev_end = b.touched_end;
        b.touched = @min(b.touched, first);
        b.touched_end = @max(b.touched_end, first + new_lines + 1);
        if (old_lines != new_lines) {
            const d_lines: isize = @as(isize, @intCast(new_lines)) - @as(isize, @intCast(old_lines));
            if (!b.lines_shifted) {
                b.lines_shifted = true;
                b.shift_at = first;
                b.line_delta = if (prev_end > first + 1) null else d_lines;
            } else {
                b.line_delta = null;
            }
        } else if (b.lines_shifted and first <= b.shift_at) {
            b.line_delta = null;
        }
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

test "initOwned takes ownership of bytes and builds exact line starts" {
    for ([_][]const u8{ "", "one", "\n", "one\ntwo\n", "one\r\n\r\ntwo" }) |src| {
        const owned = try t.allocator.dupe(u8, src);
        var b = try Buffer.initOwned(t.allocator, owned);
        defer b.deinit(t.allocator);
        try t.expectEqualStrings(src, b.text.items);
        try t.expectEqual(src.len, b.text.capacity);
        try t.expectEqual(std.mem.count(u8, src, "\n") + 1, b.starts.capacity);
        try expectStarts(&b);
    }
}

test "line_delta tracks single Return, Backspace line join, and stacked Returns" {
    var b = try Buffer.init(t.allocator, "one\ntwo\nthree");
    defer b.deinit(t.allocator);
    // Reset initial sync state as syntax sync does.
    b.touched = std.math.maxInt(usize);
    b.touched_end = 0;
    b.lines_shifted = false;
    b.line_delta = null;

    // Single Return at end of line 0.
    try b.replace(t.allocator, 3, 3, "\n", 3, false);
    try t.expect(b.lines_shifted);
    try t.expectEqual(@as(usize, 0), b.shift_at);
    try t.expectEqual(@as(?isize, 1), b.line_delta);

    // Same-line edit after shift_at keeps line_delta; at or before clears it.
    try b.replace(t.allocator, 5, 5, "x", 5, false);
    try t.expectEqual(@as(?isize, 1), b.line_delta);
    try b.replace(t.allocator, 0, 0, "y", 0, false);
    try t.expectEqual(@as(?isize, null), b.line_delta);

    // Reset and test Backspace line join.
    b.touched = std.math.maxInt(usize);
    b.touched_end = 0;
    b.lines_shifted = false;
    b.line_delta = null;
    try b.replace(t.allocator, 4, 5, "", 5, false);
    try t.expect(b.lines_shifted);
    try t.expectEqual(@as(usize, 0), b.shift_at);
    try t.expectEqual(@as(?isize, -1), b.line_delta);

    // Reset and test two stacked Returns.
    b.touched = std.math.maxInt(usize);
    b.touched_end = 0;
    b.lines_shifted = false;
    b.line_delta = null;
    try b.replace(t.allocator, 4, 4, "\n", 4, false);
    try t.expectEqual(@as(?isize, 1), b.line_delta);
    try b.replace(t.allocator, 5, 5, "\n", 5, false);
    try t.expect(b.lines_shifted);
    try t.expectEqual(@as(?isize, null), b.line_delta);
}

const AtomicPath = enum { record, fallback, typing, backward, forward, undo, redo };
const atomic_text = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\niota\nkappa\nlambda\nmu\nnu\nxi\nomicron\n";

fn atomicFixture(path: AtomicPath, caches: bool) !Buffer {
    var b = try Buffer.init(t.allocator, if (path == .undo) atomic_text else "one\ntwo\nthree");
    errdefer b.deinit(t.allocator);
    switch (path) {
        .record, .fallback, .typing => {
            try b.replace(t.allocator, 0, 0, "x", 0, false);
            try b.replace(t.allocator, b.text.items.len, b.text.items.len, "!", b.text.items.len, false);
            _ = try b.undo(t.allocator);
        },
        .backward => try b.replace(t.allocator, b.text.items.len - 1, b.text.items.len, "", b.text.items.len, false),
        .forward => try b.replace(t.allocator, 0, 1, "", 0, false),
        .undo => try b.replace(t.allocator, 0, b.text.items.len, "x", 0, false),
        .redo => {
            try b.replace(t.allocator, 0, b.text.items.len, atomic_text, 0, false);
            _ = try b.undo(t.allocator);
        },
    }
    switch (path) {
        .fallback, .typing, .backward, .forward => {},
        else => b.markSaved(),
    }
    if (caches) {
        _ = try b.unitStarts(t.allocator);
        try b.wraps.appendNTimes(t.allocator, 2, b.lines());
        b.wraps_cols = 80;
    }
    _ = b.wordCount();
    b.touched = std.math.maxInt(usize);
    b.touched_end = 0;
    b.lines_shifted = false;
    b.shift_at = 0;
    b.line_delta = null;
    b.wraps_from = std.math.maxInt(usize);
    // Force every growth path, including history transfers, to reserve storage.
    inline for (.{ "text", "starts", "units", "wraps", "undos", "redos" }) |field| {
        const list = &@field(b, field);
        list.* = .fromOwnedSlice(try list.toOwnedSlice(t.allocator));
    }
    return b;
}

fn atomicOperation(b: *Buffer, gpa: Allocator, path: AtomicPath) !void {
    // Enter coalescing, then reject the nonempty replacement as a joined edit.
    if (path == .fallback) try t.expect(b.undos.items.len > 0 and b.dirty());
    switch (path) {
        .record, .fallback => try b.replace(gpa, 1, 2, atomic_text, 2, path == .fallback),
        .typing => try b.replace(gpa, 1, 1, atomic_text, 1, true),
        .backward, .forward => try b.replace(gpa, 0, b.text.items.len, "", b.text.items.len, true),
        .undo => _ = try b.undo(gpa),
        .redo => _ = try b.redo(gpa),
    }
}

fn expectBufferState(want: *const Buffer, got: *const Buffer) !void {
    try t.expectEqualStrings(want.text.items, got.text.items);
    inline for (.{ "starts", "units", "wraps" }) |field| {
        try t.expectEqualSlices(u32, @field(want, field).items, @field(got, field).items);
    }
    inline for (.{ "undos", "redos" }) |field| {
        const expected = @field(want, field).items;
        const actual = @field(got, field).items;
        try t.expectEqual(expected.len, actual.len);
        for (expected, actual) |a, b| {
            try t.expectEqual(a.pos, b.pos);
            try t.expectEqualStrings(a.old, b.old);
            try t.expectEqualStrings(a.new, b.new);
            try t.expectEqual(a.before, b.before);
            try t.expectEqual(a.seq, b.seq);
        }
    }
    inline for (.{
        "seq", "saved", "changes", "touched", "touched_end", "lines_shifted",
        "shift_at", "line_delta", "words", "wraps_cols", "wraps_from",
    }) |field| {
        try t.expectEqual(@field(want, field), @field(got, field));
    }
    try t.expectEqual(want.dirty(), got.dirty());
}

test "buffer allocation failures leave edits and history atomic" {
    for ([_]AtomicPath{ .record, .fallback, .typing, .backward, .forward, .undo, .redo }) |path| {
        for ([_]bool{ false, true }) |caches| {
            var before = try atomicFixture(path, caches);
            defer before.deinit(t.allocator);
            var after = try atomicFixture(path, caches);
            defer after.deinit(t.allocator);
            try atomicOperation(&after, t.allocator, path);
            try expectStarts(&after);
            var failures: usize = 0;
            var discarded_units = false;
            var fail_index: usize = 0;
            while (true) : (fail_index += 1) {
                var b = try atomicFixture(path, caches);
                defer b.deinit(t.allocator);
                var failing = t.FailingAllocator.init(t.allocator, .{
                    .fail_index = fail_index,
                    .resize_fail_index = 0,
                });
                atomicOperation(&b, failing.allocator(), path) catch |err| {
                    try t.expectEqual(error.OutOfMemory, err);
                    try t.expect(failing.has_induced_failure);
                    try expectBufferState(&before, &b);
                    failures += 1;
                    continue;
                };
                if (failing.has_induced_failure) {
                    // A failed UTF-16 cache grow must not fail the committed edit.
                    try t.expect(caches);
                    try t.expectEqual(@as(usize, 0), b.units.items.len);
                    _ = try b.unitStarts(t.allocator);
                    discarded_units = true;
                }
                try expectBufferState(&after, &b);
                if (!failing.has_induced_failure) break;
            }
            try t.expect(failures > 0);
            if (caches and path != .backward and path != .forward) try t.expect(discarded_units);
        }
    }
}

test "joined edit after undo discards the abandoned redo branch" {
    var b = try atomicFixture(.typing, false);
    defer b.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), b.redos.items.len);
    try b.replace(t.allocator, 1, 1, "y", 1, true);
    try t.expectEqual(@as(usize, 0), b.redos.items.len);
    try t.expectEqual(@as(usize, 1), b.undos.items.len);
    try t.expect((try b.redo(t.allocator)) == null);
    _ = try b.undo(t.allocator);
    try t.expectEqualStrings("one\ntwo\nthree", b.text.items);
    try t.expect(!b.dirty());
    _ = try b.redo(t.allocator);
    try t.expectEqualStrings("xyone\ntwo\nthree", b.text.items);
    try t.expect(b.dirty());
}

test "joined typing can borrow replacement bytes from the buffer" {
    var b = try Buffer.init(t.allocator, "ab");
    defer b.deinit(t.allocator);
    try b.replace(t.allocator, 0, 0, "x", 0, true);
    b.text = .fromOwnedSlice(try b.text.toOwnedSlice(t.allocator));
    var relocating = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try b.replace(relocating.allocator(), 1, 1, b.text.items, 1, true);
    try t.expectEqualStrings("xxabab", b.text.items);
    _ = try b.undo(t.allocator);
    try t.expectEqualStrings("ab", b.text.items);
}

test "buffer prospective lengths fit u32 indexes without arithmetic overflow" {
    const max = Buffer.max_bytes;
    try t.expectEqual(@as(usize, 0), try Buffer.prospectiveLength(0, 0, 0));
    try t.expectEqual(max, try Buffer.prospectiveLength(0, 0, max));
    try t.expectEqual(max, try Buffer.prospectiveLength(max - 1, 0, 1));
    try t.expectEqual(max, try Buffer.prospectiveLength(max, 1, 1));
    try t.expectEqual(max, try Buffer.prospectiveLength(max, max, max));
    try t.expectEqual(max - 1, try Buffer.prospectiveLength(max, 1, 0));
    try t.expectError(error.BufferTooLarge, Buffer.prospectiveLength(0, 0, max + 1));
    try t.expectError(error.BufferTooLarge, Buffer.prospectiveLength(max, 0, 1));
    try t.expectError(error.BufferTooLarge, Buffer.prospectiveLength(1, 0, std.math.maxInt(usize)));
    try t.expectError(error.BufferTooLarge, Buffer.prospectiveLength(max, 1, std.math.maxInt(usize)));
}

test "buffer initialization rejects oversized bytes before allocation or access" {
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    // Only the length is read: no multi-gigabyte allocation or payload access.
    const oversized = @as([*]const u8, "x".ptr)[0 .. Buffer.max_bytes + 1];
    try t.expectError(error.BufferTooLarge, Buffer.init(failing.allocator(), oversized));
    try t.expect(!failing.has_induced_failure);
}

test "buffer oversized replacements preserve indexes history caches and dirty state" {
    for ([_]AtomicPath{ .record, .fallback, .typing }) |path| {
        for ([_]bool{ false, true }) |caches| {
            var before = try atomicFixture(path, caches);
            defer before.deinit(t.allocator);
            var b = try atomicFixture(path, caches);
            defer b.deinit(t.allocator);
            for ([_]usize{ Buffer.max_bytes, Buffer.max_bytes + 1, std.math.maxInt(usize) }) |len| {
                var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
                // Borrow the buffer pointer to cover rejection before alias handling.
                const oversized = b.text.items.ptr[0..len];
                const end: usize = if (path == .typing) 1 else 2;
                try t.expectError(error.BufferTooLarge, b.replace(failing.allocator(), 1, end, oversized, 2, path != .record));
                try t.expect(!failing.has_induced_failure);
                try expectBufferState(&before, &b);
            }
            try atomicOperation(&b, t.allocator, path);
            _ = try b.undo(t.allocator);
            _ = try b.redo(t.allocator);
            try expectStarts(&b);
        }
    }
}

test "buffer oversized history restores reject before allocation or stack transfer" {
    for ([_]AtomicPath{ .undo, .redo }) |path| {
        var before = try atomicFixture(path, true);
        defer before.deinit(t.allocator);
        var b = try atomicFixture(path, true);
        defer b.deinit(t.allocator);
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
        // Valid history cannot exceed the limit. Inject only its payload length
        // to exercise the guard without allocating or reading oversized bytes.
        const payload = if (path == .undo)
            &b.undos.items[b.undos.items.len - 1].old
        else
            &b.redos.items[b.redos.items.len - 1].new;
        const original = payload.*;
        payload.len = Buffer.max_bytes + 1;
        const result = if (path == .undo) b.undo(failing.allocator()) else b.redo(failing.allocator());
        const rejected_len = payload.len;
        payload.* = original;
        try t.expectError(error.BufferTooLarge, result);
        try t.expectEqual(Buffer.max_bytes + 1, rejected_len);
        try t.expect(!failing.has_induced_failure);
        try expectBufferState(&before, &b);
        try atomicOperation(&b, t.allocator, path);
        try expectStarts(&b);
    }
}
