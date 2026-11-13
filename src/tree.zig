//! The sidebar's folder tree: the rows on show, rebuilt from disk when a
//! folder opens or closes or Zag comes forward. Only open folders are read.
const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
const files = @import("files.zig");
extern "c" fn dirfd(dir: *c.DIR) c_int;

/// Rows past this are left out, so a huge open folder can't stall drawing.
pub const max_rows = 50_000;

pub const Row = struct {
    /// Path relative to the root, like `src/view.zig`.
    rel: []const u8,
    /// Where the last part of `rel` starts.
    base: usize,
    depth: u16,
    dir: bool,
};

/// `stamp` is null when the folder couldn't be opened, so `fresh` tries it
/// again: a permission change moves ctime, not the mtime a stamp compares.
const Read = struct { path: [:0]const u8, stamp: ?files.Stamp };

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row) = .empty,
    /// Relative paths of the open folders. Owned by gpa.
    open: std.ArrayList([]u8) = .empty,
    /// Every folder the last `rebuild` read, with its stamp from just
    /// before the read. In the arena.
    read: std.ArrayList(Read) = .empty,
    read_open: usize = 0,
    /// Lists names that start with a dot too, except `.` and `..`.
    show_hidden: bool = false,
    /// The last `rebuild` couldn't open the root folder.
    unreadable: bool = false,
    /// The last `rebuild` stopped at `max_rows`, so rows are missing.
    truncated: bool = false,

    pub fn init(gpa: Allocator) Tree {
        return .{ .arena = .init(gpa) };
    }

    pub fn isOpen(t: *const Tree, rel: []const u8) bool {
        for (t.open.items) |o| if (std.mem.eql(u8, o, rel)) return true;
        return false;
    }

    /// Opens a closed folder or closes an open one. Folders inside keep
    /// their own state for when it opens again.
    pub fn toggle(t: *Tree, gpa: Allocator, rel: []const u8) void {
        for (t.open.items, 0..) |o, i| if (std.mem.eql(u8, o, rel)) {
            gpa.free(t.open.swapRemove(i));
            return;
        };
        const z = gpa.dupe(u8, rel) catch return;
        t.open.append(gpa, z) catch gpa.free(z);
    }

    /// Closes every expanded folder.
    pub fn closeAll(t: *Tree, gpa: Allocator) void {
        for (t.open.items) |o| gpa.free(o);
        t.open.clearRetainingCapacity();
    }

    /// Opens every folder above `rel`, so a file deep down shows. True when
    /// it opened one, so the rows need a rebuild.
    pub fn reveal(t: *Tree, gpa: Allocator, rel: []const u8) bool {
        var opened = false;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| : (i = slash + 1) {
            const s = rel[0..slash];
            if (!t.isOpen(s)) {
                const own = gpa.dupe(u8, s) catch continue;
                t.open.append(gpa, own) catch {
                    gpa.free(own);
                    continue;
                };
                opened = true;
            }
        }
        return opened;
    }

    /// The row for `rel`, when it's on the list.
    pub fn rowOf(t: *const Tree, rel: []const u8) ?usize {
        for (t.rows.items, 0..) |r, i| if (std.mem.eql(u8, r.rel, rel)) return i;
        return null;
    }

    /// Whether a row for `rel` is on the list.
    pub fn has(t: *const Tree, rel: []const u8) bool {
        return t.rowOf(rel) != null;
    }

    /// The row after `i` and all of its descendants.
    pub fn end(t: *const Tree, i: usize) usize {
        const rows = t.rows.items;
        var e = i + 1;
        while (e < rows.len and rows[e].depth > rows[i].depth) e += 1;
        return e;
    }

    /// Re-reads `root` and every open folder under it.
    pub fn rebuild(t: *Tree, gpa: Allocator, root: []const u8) void {
        _ = t.arena.reset(.retain_capacity);
        t.rows = .empty;
        t.read = .empty;
        t.read_open = t.open.items.len;
        t.unreadable = false;
        t.truncated = false;
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(gpa);
        path.appendSlice(gpa, root) catch return;
        t.list(gpa, &path, root.len + 1, 0) catch {};
    }

    /// True when no folder the last `rebuild` read has changed since (its
    /// entries are the same) and the open folders are the same count, so
    /// the rows still match the disk. One stat per read folder, bounded by
    /// the open folders; `rebuild` resets it.
    pub fn fresh(t: *const Tree) bool {
        if (t.read_open != t.open.items.len) return false;
        for (t.read.items) |d| {
            const now = files.stamp(d.path);
            if (now == null or d.stamp == null or !std.meta.eql(now.?, d.stamp.?)) return false;
        }
        return true;
    }

    pub fn deinit(t: *Tree, gpa: Allocator) void {
        t.closeAll(gpa);
        t.open.deinit(gpa);
        t.arena.deinit();
    }

    const Entry = struct { name: []const u8, dir: bool };

    fn list(t: *Tree, gpa: Allocator, path: *std.ArrayList(u8), rel: usize, depth: u16) !void {
        const a = t.arena.allocator();
        try path.append(gpa, 0);
        const dir = c.opendir(@ptrCast(path.items.ptr));
        path.items.len -= 1;
        const dh = dir orelse {
            try t.read.append(a, .{ .path = try a.dupeSentinel(u8, path.items, 0), .stamp = null });
            if (depth == 0) t.unreadable = true;
            return;
        };
        var entries: std.ArrayList(Entry) = .empty;
        {
            defer _ = c.closedir(dh);
            const fd = dirfd(dh);
            var st: c.Stat = undefined;
            const stamp: ?files.Stamp = if (c.fstat(fd, &st) == 0) files.stampOf(st) else null;
            try t.read.append(a, .{ .path = try a.dupeSentinel(u8, path.items, 0), .stamp = stamp });
            while (c.readdir(dh)) |ent| {
                const name = ent.name[0..ent.namlen];
                if (name.len == 0) continue;
                if (name[0] == '.') {
                    if (!t.show_hidden) continue;
                    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                }
                var is_dir = ent.type == c.DT.DIR;
                if (ent.type == c.DT.LNK or ent.type == c.DT.UNKNOWN) {
                    // A link to a folder shows as a folder, and a filesystem
                    // that doesn't report types gets a stat.
                    var est: c.Stat = undefined;
                    is_dir = c.fstatat(fd, @ptrCast(&ent.name), &est, 0) == 0 and est.mode & c.S.IFMT == c.S.IFDIR;
                }
                try entries.append(a, .{ .name = try a.dupe(u8, name), .dir = is_dir });
            }
        }
        const len = path.items.len;
        std.sort.heap(Entry, entries.items, {}, before);
        for (entries.items) |e| {
            if (t.rows.items.len >= max_rows) {
                t.truncated = true;
                return;
            }
            path.shrinkRetainingCapacity(len);
            try path.append(gpa, '/');
            try path.appendSlice(gpa, e.name);
            const r = try a.dupe(u8, path.items[rel..]);
            try t.rows.append(a, .{ .rel = r, .base = r.len - e.name.len, .depth = depth, .dir = e.dir });
            if (e.dir and t.isOpen(r)) try t.list(gpa, path, rel, depth + 1);
        }
    }

    /// Folders first, then names in letter order, ignoring case, with
    /// runs of digits compared as numbers so `file2` comes before `file10`.
    fn before(_: void, x: Entry, y: Entry) bool {
        if (x.dir != y.dir) return x.dir;
        return naturalLess(x.name, y.name);
    }
};

fn naturalLess(x: []const u8, y: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len and j < y.len) {
        if (std.ascii.isDigit(x[i]) and std.ascii.isDigit(y[j])) {
            while (i < x.len and x[i] == '0') i += 1;
            while (j < y.len and y[j] == '0') j += 1;
            const xs = i;
            const ys = j;
            while (i < x.len and std.ascii.isDigit(x[i])) i += 1;
            while (j < y.len and std.ascii.isDigit(y[j])) j += 1;
            const xn = x[xs..i];
            const yn = y[ys..j];
            if (xn.len != yn.len) return xn.len < yn.len;
            switch (std.mem.order(u8, xn, yn)) {
                .lt => return true,
                .gt => return false,
                .eq => continue,
            }
        }
        const a = std.ascii.toLower(x[i]);
        const b = std.ascii.toLower(y[j]);
        if (a != b) return a < b;
        i += 1;
        j += 1;
    }
    return x.len - i < y.len - j;
}

test "names with numbers sort by value, ignoring case" {
    const t = std.testing;
    try t.expect(naturalLess("file2", "file10"));
    try t.expect(!naturalLess("file10", "file2"));
    try t.expect(naturalLess("File2", "file10"));
    try t.expect(naturalLess("a", "B"));
    try t.expect(naturalLess("x9y", "x09z"));
    try t.expect(!naturalLess("abc", "ABC"));
    try t.expect(naturalLess("ab", "abc"));
}

test "folders first, names ignore case, hidden files skipped, open folders list inside" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, "/tmp/ze-tree-test-{d}", .{c.getpid()});
    var p: [128]u8 = undefined;
    const made = [_][]const u8{ "b.txt", "A.txt", ".hidden", "zeta/x.zig", "Alpha/y.md" };
    for (made) |rel| {
        const z = try std.fmt.bufPrintSentinel(&p, "{s}/{s}", .{ root, rel }, 0);
        try files.makeParent(z);
        try files.write(z, "");
    }
    defer for (made ++ [_][]const u8{ "zeta/new.txt", "zeta", "Alpha", "" }) |rel| {
        const z = std.fmt.bufPrintSentinel(&p, "{s}/{s}", .{ root, rel }, 0) catch continue;
        if (c.unlink(z) != 0) _ = c.rmdir(z);
    };
    var tr: Tree = .init(t.allocator);
    defer tr.deinit(t.allocator);
    tr.toggle(t.allocator, "zeta");
    tr.rebuild(t.allocator, root);
    const want = [_][]const u8{ "Alpha", "zeta", "zeta/x.zig", "A.txt", "b.txt" };
    try t.expectEqual(want.len, tr.rows.items.len);
    for (want, tr.rows.items) |w, row| try t.expectEqualStrings(w, row.rel);
    try t.expectEqual(@as(u16, 1), tr.rows.items[2].depth);
    try t.expectEqualStrings("x.zig", tr.rows.items[2].rel[tr.rows.items[2].base..]);
    try t.expectEqual(@as(usize, 1), tr.end(0));
    try t.expectEqual(@as(usize, 3), tr.end(1));
    try t.expectEqual(@as(usize, 3), tr.end(2));
    try t.expectEqual(tr.rows.items.len, tr.end(tr.rows.items.len - 1));

    // A read folder that changes makes the rows stale; a new open folder too.
    try t.expect(tr.fresh());
    const z = try std.fmt.bufPrintSentinel(&p, "{s}/zeta/new.txt", .{root}, 0);
    try files.write(z, "");
    try t.expect(!tr.fresh());
    tr.rebuild(t.allocator, root);
    try t.expect(tr.fresh());
    tr.toggle(t.allocator, "Alpha");
    try t.expect(!tr.fresh());
}
