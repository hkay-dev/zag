//! The text of one file: bytes, where each line starts, and undo history.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// One change: `old` at `pos` was replaced by `new`. `seq` tells saved
/// states apart; `before` is where the caret was.
const Edit = struct { pos: usize, old: []u8, new: []u8, before: usize, seq: u64 };

pub const Buffer = struct {
    text: std.ArrayList(u8) = .empty,
    /// Byte offset of each line's first byte. Always starts with 0.
    starts: std.ArrayList(u32) = .empty,
    undos: std.ArrayList(Edit) = .empty,
    redos: std.ArrayList(Edit) = .empty,
    seq: u64 = 0,
    saved: u64 = 0,
    /// The first line changed since the syntax cache last looked.
    touched: usize = 0,
    /// Screen rows of each line for soft wrap, kept by the view; empty while
    /// wrap is off. An edit zeroes the lines it touches, and `wraps_from` is
    /// the first line zeroed since the view last caught up.
    wraps: std.ArrayList(u32) = .empty,
    wraps_from: usize = std.math.maxInt(usize),

    pub fn init(gpa: Allocator, bytes: []const u8) !Buffer {
        var b: Buffer = .{};
        try b.text.appendSlice(gpa, bytes);
        try b.starts.append(gpa, 0);
        for (bytes, 0..) |c, i| if (c == '\n') try b.starts.append(gpa, @intCast(i + 1));
        return b;
    }

    pub fn deinit(b: *Buffer, gpa: Allocator) void {
        for (b.undos.items) |e| free(gpa, e);
        for (b.redos.items) |e| free(gpa, e);
        b.undos.deinit(gpa);
        b.redos.deinit(gpa);
        b.wraps.deinit(gpa);
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

    pub fn line(b: *const Buffer, i: usize) []const u8 {
        return b.text.items[b.lineStart(i)..b.lineEnd(i)];
    }

    /// The line that holds byte `pos`.
    pub fn lineOf(b: *const Buffer, pos: usize) usize {
        var lo: usize = 0;
        var hi: usize = b.starts.items.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (b.starts.items[mid] <= pos) lo = mid else hi = mid;
        }
        return lo;
    }

    pub fn dirty(b: *const Buffer) bool {
        return b.top() != b.saved;
    }

    pub fn markSaved(b: *Buffer) void {
        b.saved = b.top();
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
                last.new = try grow(gpa, last.new, last.new, new);
            } else if (new.len == 0 and last.new.len == 0 and end == last.pos) {
                last.old = try grow(gpa, last.old, old, last.old);
                last.pos = start;
            } else if (new.len == 0 and last.new.len == 0 and start == last.pos) {
                last.old = try grow(gpa, last.old, last.old, old);
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

    /// Undoes the last edit and returns where the caret goes.
    pub fn undo(b: *Buffer, gpa: Allocator) !?usize {
        const e = b.undos.pop() orelse return null;
        try b.redos.append(gpa, e);
        try b.splice(gpa, e.pos, e.pos + e.new.len, e.old);
        return e.before;
    }

    pub fn redo(b: *Buffer, gpa: Allocator) !?usize {
        const e = b.redos.pop() orelse return null;
        try b.undos.append(gpa, e);
        try b.splice(gpa, e.pos, e.pos + e.old.len, e.new);
        return e.pos + e.new.len;
    }

    /// Swaps the bytes and keeps `starts` in step without rescanning the file.
    fn splice(b: *Buffer, gpa: Allocator, start: usize, end: usize, new: []const u8) !void {
        const first = b.lineOf(start);
        const last = b.lineOf(end);
        try b.text.replaceRange(gpa, start, end - start, new);

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
        b.touched = @min(b.touched, first);
    }

    fn free(gpa: Allocator, e: Edit) void {
        gpa.free(e.old);
        gpa.free(e.new);
    }
};

/// `a ++ c` in place of `old`, which is freed.
fn grow(gpa: Allocator, old: []u8, a: []const u8, c: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, a.len + c.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], c);
    gpa.free(old);
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
        try t.expectEqual(b.lines(), b.wraps.items.len);
    }
}

test "undo walks typing back to the saved text and clears dirty" {
    var b = try Buffer.init(t.allocator, "hi");
    defer b.deinit(t.allocator);
    try b.replace(t.allocator, 2, 2, "!", 2, false);
    b.markSaved();
    for (" there", 3..) |c, i| try b.replace(t.allocator, i, i, &.{c}, i, true);
    try t.expect(b.dirty());
    try t.expectEqual(@as(?usize, 3), try b.undo(t.allocator));
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
}
