//! The sidebar's folder tree: the rows on show, rebuilt from disk when a
//! folder opens or closes or Zag comes forward. Only open folders are read.
const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
const files = @import("files.zig");

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

const Read = struct { path: [:0]const u8, stamp: files.Stamp };

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row) = .empty,
    /// Relative paths of the open folders. Owned by gpa.
    open: std.ArrayList([]u8) = .empty,
    /// Every folder the last `rebuild` read, with its stamp from just
    /// before the read. In the arena.
    read: std.ArrayList(Read) = .empty,
    read_open: usize = 0,

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

    /// Opens every folder above `rel`, so a file deep down shows. True when
    /// it opened one, so the rows need a rebuild.
    pub fn reveal(t: *Tree, gpa: Allocator, rel: []const u8) bool {
        var opened = false;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| : (i = slash + 1) {
            if (!t.isOpen(rel[0..slash])) {
                t.toggle(gpa, rel[0..slash]);
                opened = true;
            }
        }
        return opened;
    }

    /// Whether a row for `rel` is on the list.
    pub fn has(t: *const Tree, rel: []const u8) bool {
        for (t.rows.items) |r| if (std.mem.eql(u8, r.rel, rel)) return true;
        return false;
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
            if (now == null or !std.meta.eql(now.?, d.stamp)) return false;
        }
        return true;
    }

    pub fn deinit(t: *Tree, gpa: Allocator) void {
        for (t.open.items) |o| gpa.free(o);
        t.open.deinit(gpa);
        t.arena.deinit();
    }

    const Entry = struct { name: []const u8, dir: bool };

    fn list(t: *Tree, gpa: Allocator, path: *std.ArrayList(u8), rel: usize, depth: u16) !void {
        const a = t.arena.allocator();
        try path.append(gpa, 0);
        const stamp = files.stamp(path.items[0 .. path.items.len - 1 :0]);
        const dir = c.opendir(@ptrCast(path.items.ptr));
        if (stamp) |s| try t.read.append(a, .{ .path = try a.dupeSentinel(u8, path.items[0 .. path.items.len - 1], 0), .stamp = s });
        path.items.len -= 1;
        const dh = dir orelse return;
        const len = path.items.len;
        var entries: std.ArrayList(Entry) = .empty;
        while (c.readdir(dh)) |ent| {
            const name = ent.name[0..ent.namlen];
            if (name[0] == '.') continue;
            var is_dir = ent.type == c.DT.DIR;
            if (ent.type == c.DT.LNK) {
                // A link to a folder shows as a folder.
                path.shrinkRetainingCapacity(len);
                try path.append(gpa, '/');
                try path.appendSlice(gpa, name);
                try path.append(gpa, 0);
                var st: c.Stat = undefined;
                is_dir = c.stat(@ptrCast(path.items.ptr), &st) == 0 and st.mode & c.S.IFMT == c.S.IFDIR;
            }
            try entries.append(a, .{ .name = try a.dupe(u8, name), .dir = is_dir });
        }
        _ = c.closedir(dh);
        std.mem.sort(Entry, entries.items, {}, before);
        for (entries.items) |e| {
            if (t.rows.items.len >= max_rows) return;
            path.shrinkRetainingCapacity(len);
            try path.append(gpa, '/');
            try path.appendSlice(gpa, e.name);
            const r = try a.dupe(u8, path.items[rel..]);
            try t.rows.append(a, .{ .rel = r, .base = r.len - e.name.len, .depth = depth, .dir = e.dir });
            if (e.dir and t.isOpen(r)) try t.list(gpa, path, rel, depth + 1);
        }
    }

    /// Folders first, then names in letter order, ignoring case.
    fn before(_: void, x: Entry, y: Entry) bool {
        if (x.dir != y.dir) return x.dir;
        return std.ascii.lessThanIgnoreCase(x.name, y.name);
    }
};

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
