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
    /// The last `rebuild` hit `max_rows`; unread expanded folders may contain more rows.
    truncated: bool = false,
    /// All required reads and allocations succeeded, including deliberate truncation.
    complete: bool = false,

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
        t.complete = false;
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(gpa);
        path.appendSlice(gpa, root) catch return;
        t.complete = t.list(gpa, &path, root.len + 1, 0) catch return;
    }

    /// True when no folder the last `rebuild` read has changed since (its
    /// entries are the same) and the open folders are the same count, so
    /// the rows still match the disk. One stat per read folder, bounded by
    /// the open folders; `rebuild` resets it.
    pub fn fresh(t: *const Tree) bool {
        if (!t.complete or t.read_open != t.open.items.len) return false;
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

    fn list(t: *Tree, gpa: Allocator, path: *std.ArrayList(u8), rel: usize, depth: u16) !bool {
        const remaining = max_rows - t.rows.items.len;
        if (remaining == 0) {
            t.truncated = true;
            return true;
        }
        const a = t.arena.allocator();
        try path.append(gpa, 0);
        const dir = c.opendir(@ptrCast(path.items.ptr));
        path.items.len -= 1;
        const dh = dir orelse {
            if (depth == 0) t.unreadable = true;
            try t.read.append(a, .{ .path = try a.dupeSentinel(u8, path.items, 0), .stamp = null });
            return false;
        };
        var entries: std.ArrayList(Entry) = .empty;
        var emitted: usize = 0;
        var complete = true;
        defer {
            for (entries.items[emitted..]) |e| gpa.free(e.name);
            entries.deinit(gpa);
        }
        {
            defer _ = c.closedir(dh);
            const fd = dirfd(dh);
            var st: c.Stat = undefined;
            const stamp: ?files.Stamp = if (c.fstat(fd, &st) == 0) files.stampOf(st) else null;
            if (stamp == null) complete = false;
            try t.read.append(a, .{ .path = try a.dupeSentinel(u8, path.items, 0), .stamp = stamp });
            while (true) {
                c._errno().* = 0;
                const ent = c.readdir(dh) orelse {
                    if (c._errno().* != 0) complete = false;
                    break;
                };
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
                    if (c.fstatat(fd, @ptrCast(&ent.name), &est, 0) == 0) {
                        is_dir = est.mode & c.S.IFMT == c.S.IFDIR;
                    } else {
                        complete = false;
                    }
                }
                if (try retain(&entries, gpa, .{ .name = name, .dir = is_dir }, remaining)) t.truncated = true;
            }
        }
        const len = path.items.len;
        std.sort.heap(Entry, entries.items, {}, before);
        for (entries.items) |e| {
            if (t.rows.items.len >= max_rows) {
                t.truncated = true;
                return complete;
            }
            path.shrinkRetainingCapacity(len);
            try path.append(gpa, '/');
            try path.appendSlice(gpa, e.name);
            const r = try a.dupe(u8, path.items[rel..]);
            try t.rows.append(a, .{ .rel = r, .base = r.len - e.name.len, .depth = depth, .dir = e.dir });
            gpa.free(e.name);
            emitted += 1;
            if (e.dir and t.isOpen(r)) {
                if (t.rows.items.len == max_rows) {
                    t.truncated = true;
                    return complete;
                }
                complete = try t.list(gpa, path, rel, depth + 1) and complete;
            }
        }
        return complete;
    }

    /// Retain only the first `cap` entries in a max-heap. Read every entry
    /// to select the exact sorted prefix, but never copy a rejected name.
    /// True means this directory had more candidates than remaining rows.
    fn retain(entries: *std.ArrayList(Entry), gpa: Allocator, candidate: Entry, cap: usize) !bool {
        if (cap == 0) return true;
        const full = entries.items.len == cap;
        if (full and !before({}, candidate, entries.items[0])) return true;
        const own: Entry = .{ .name = try gpa.dupe(u8, candidate.name), .dir = candidate.dir };
        if (!full) {
            errdefer gpa.free(own.name);
            try entries.append(gpa, own);
            var at = entries.items.len - 1;
            while (at > 0) {
                const parent = (at - 1) / 2;
                if (!before({}, entries.items[parent], entries.items[at])) break;
                std.mem.swap(Entry, &entries.items[parent], &entries.items[at]);
                at = parent;
            }
        } else {
            gpa.free(entries.items[0].name);
            entries.items[0] = own;
            var at: usize = 0;
            while (at * 2 + 1 < entries.items.len) {
                var child = at * 2 + 1;
                if (child + 1 < entries.items.len and before({}, entries.items[child], entries.items[child + 1])) child += 1;
                if (!before({}, entries.items[at], entries.items[child])) break;
                std.mem.swap(Entry, &entries.items[at], &entries.items[child]);
                at = child;
            }
        }
        return full;
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
    const xr = x.len - i;
    const yr = y.len - j;
    if (xr != yr) return xr < yr;
    // Equal natural keys need the same cutoff regardless of readdir order.
    return std.mem.order(u8, x, y) == .lt;
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

test "bounded candidates match the full natural directory-first prefix in any arrival order" {
    const t = std.testing;
    var sorted = [_]Tree.Entry{
        .{ .name = "file10", .dir = false },
        .{ .name = "z10", .dir = true },
        .{ .name = "file2", .dir = false },
        .{ .name = "a", .dir = false },
        .{ .name = "file02", .dir = false },
        .{ .name = "z2", .dir = true },
        .{ .name = "File2", .dir = false },
    };
    std.sort.heap(Tree.Entry, &sorted, {}, Tree.before);
    const want = [_][]const u8{ "z2", "z10", "a", "File2", "file02", "file2", "file10" };
    for (sorted, want) |e, name| try t.expectEqualStrings(name, e.name);
    for (0..sorted.len + 1) |cap| {
        for (0..sorted.len * 2) |order| {
            var entries: std.ArrayList(Tree.Entry) = .empty;
            defer {
                for (entries.items) |e| t.allocator.free(e.name);
                entries.deinit(t.allocator);
            }
            var dropped = false;
            for (0..sorted.len) |i| {
                const index = (i + order) % sorted.len;
                const e = sorted[if (order < sorted.len) index else sorted.len - 1 - index];
                dropped = try Tree.retain(&entries, t.allocator, e, cap) or dropped;
                try t.expect(entries.items.len <= cap);
            }
            try t.expectEqual(cap < sorted.len, dropped);
            std.sort.heap(Tree.Entry, entries.items, {}, Tree.before);
            try t.expectEqual(cap, entries.items.len);
            for (entries.items, sorted[0..cap]) |got, expected| {
                try t.expectEqualStrings(expected.name, got.name);
                try t.expectEqual(expected.dir, got.dir);
            }
        }
    }
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
        _ = try files.write(z, "");
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
    _ = try files.write(z, "");
    try t.expect(!tr.fresh());
    tr.rebuild(t.allocator, root);
    try t.expect(tr.fresh());
    tr.toggle(t.allocator, "Alpha");
    try t.expect(!tr.fresh());

    // Seed an already emitted prefix without creating 50,000 files on disk.
    for (0..3) |remaining| {
        var capped: Tree = .init(t.allocator);
        defer capped.deinit(t.allocator);
        capped.toggle(t.allocator, "Alpha");
        try capped.rows.resize(capped.arena.allocator(), max_rows - remaining);
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(t.allocator);
        try path.appendSlice(t.allocator, root);
        capped.read_open = capped.open.items.len;
        capped.complete = try capped.list(t.allocator, &path, root.len + 1, 0);
        try t.expect(capped.complete);
        try t.expect(capped.fresh());
        try t.expect(capped.truncated);
        try t.expectEqual(@as(usize, max_rows), capped.rows.items.len);
        try t.expectEqual(remaining, capped.read.items.len);
        if (remaining > 0) try t.expectEqualStrings("Alpha", capped.rows.items[max_rows - remaining].rel);
        if (remaining == 2) try t.expectEqualStrings("Alpha/y.md", capped.rows.items[max_rows - 1].rel);
    }
}

test "root entry and child allocation failures remain stale and recover" {
    const t = std.testing;
    var buf: [80]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, "/tmp/ze-tree-allocation-test-{d}", .{c.getpid()});
    var p: [128]u8 = undefined;
    const leaf = try std.fmt.bufPrintSentinel(&p, "{s}/child/leaf", .{root}, 0);
    try files.makeParent(leaf);
    _ = try files.write(leaf, "");
    defer for ([_][]const u8{ "child/leaf", "child", "" }) |rel| {
        const z = std.fmt.bufPrintSentinel(&p, "{s}/{s}", .{ root, rel }, 0) catch continue;
        if (c.unlink(z) != 0) _ = c.rmdir(z);
    };

    var root_failed = false;
    var entry_failed = false;
    var child_failed = false;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        // Disable in-place growth so every allocation failure is reproducible.
        var failing = t.FailingAllocator.init(t.allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        const gpa = failing.allocator();
        var tr: Tree = .init(gpa);
        defer tr.deinit(t.allocator);
        tr.toggle(t.allocator, "child");
        try t.expect(!tr.fresh());
        tr.rebuild(gpa, root);
        if (!failing.has_induced_failure) {
            try t.expect(tr.complete);
            try t.expect(tr.fresh());
            break;
        }
        try t.expect(!tr.complete);
        try t.expect(!tr.fresh());
        if (fail_index == 0) {
            root_failed = true;
            try t.expectEqual(@as(usize, 0), tr.read.items.len);
            try t.expectEqual(@as(usize, 0), tr.rows.items.len);
        }
        if (tr.read.items.len == 1 and tr.rows.items.len == 0) entry_failed = true;
        if (tr.read.items.len == 2 and tr.rows.items.len == 1) child_failed = true;

        failing.fail_index = std.math.maxInt(usize);
        tr.rebuild(gpa, root);
        try t.expect(tr.complete);
        try t.expect(tr.fresh());
        try t.expectEqual(@as(usize, 2), tr.rows.items.len);
        try t.expectEqualStrings("child", tr.rows.items[0].rel);
        try t.expectEqualStrings("child/leaf", tr.rows.items[1].rel);

        // A warm successful tree must also lose freshness on the next failure.
        failing.fail_index = failing.alloc_index;
        tr.rebuild(gpa, root);
        try t.expect(!tr.complete);
        try t.expect(!tr.fresh());
        failing.fail_index = std.math.maxInt(usize);
        tr.rebuild(gpa, root);
        try t.expect(tr.complete);
        try t.expect(tr.fresh());
        try t.expectEqual(@as(usize, 2), tr.rows.items.len);
    }
    try t.expect(root_failed);
    try t.expect(entry_failed);
    try t.expect(child_failed);
}

test "failed root reads and entry stats remain stale and recover" {
    const t = std.testing;
    var buf: [80]u8 = undefined;
    const root = try std.fmt.bufPrintSentinel(&buf, "/tmp/ze-tree-read-test-{d}", .{c.getpid()}, 0);
    var tr: Tree = .init(t.allocator);
    defer tr.deinit(t.allocator);
    tr.rebuild(t.allocator, root);
    try t.expect(tr.unreadable);
    try t.expect(!tr.complete);
    try t.expect(!tr.fresh());

    try t.expect(c.mkdir(root, 0o700) == 0);
    defer _ = c.rmdir(root);
    tr.rebuild(t.allocator, root);
    try t.expect(!tr.unreadable);
    try t.expect(tr.complete);
    try t.expect(tr.fresh());
    try t.expectEqual(@as(usize, 0), tr.rows.items.len);

    const fd = c.open(root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try t.expect(fd >= 0);
    defer _ = c.close(fd);
    try t.expect(c.symlinkat("missing", fd, "link") == 0);
    defer _ = c.unlinkat(fd, "link", 0);
    tr.rebuild(t.allocator, root);
    try t.expect(!tr.complete);
    try t.expect(!tr.fresh());
    try t.expectEqual(@as(usize, 1), tr.rows.items.len);
    try t.expectEqualStrings("link", tr.rows.items[0].rel);

    var p: [128]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&p, "{s}/missing", .{root}, 0);
    _ = try files.write(target, "");
    defer _ = c.unlink(target);
    tr.rebuild(t.allocator, root);
    try t.expect(tr.complete);
    try t.expect(tr.fresh());
    try t.expectEqual(@as(usize, 2), tr.rows.items.len);
}
