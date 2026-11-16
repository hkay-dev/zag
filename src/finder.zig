//! Quick open: every file under the root folder, and a fuzzy match over them.
const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
extern "c" fn dirfd(dir: *c.DIR) c_int;

pub const max_files = 100_000;

const walk_batch = 64;
const live_cursors = 16;
const Pending = struct {
    rel: [:0]u8,
    dir: ?*c.DIR = null,
    /// Number of raw readdir entries consumed; null marks a completed folder.
    consumed: ?usize = 0,
};

/// Folders that are never worth opening from quick open.
const skip = [_][]const u8{ "node_modules", "zig-out", "target", "build", "dist", "DerivedData", "Pods", "__pycache__", "vendor" };

pub const Files = struct {
    gpa: Allocator,
    /// The path strings live in the arena; the list of them grows on `gpa`,
    /// so an outgrown buffer is freed instead of left behind in the arena.
    arena: std.heap.ArenaAllocator,
    paths: std.ArrayList([]const u8) = .empty,

    pub fn deinit(f: *Files) void {
        f.paths.deinit(f.gpa);
        f.arena.deinit();
    }
};

/// Lists files under `root`, relative to it. `include_hidden` lists dotfiles
/// and dot folders such as `.gitignore` and `.github/`, but never `.git`.
pub fn scan(gpa: Allocator, root: []const u8, include_hidden: bool) !Files {
    var f: Files = .{ .gpa = gpa, .arena = .init(gpa) };
    errdefer f.deinit();
    const root_z = try gpa.dupeSentinel(u8, root, 0);
    defer gpa.free(root_z);
    const root_fd = c.open(root_z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (root_fd < 0) return f;
    defer _ = c.close(root_fd);
    var pending: std.ArrayList(Pending) = .empty;
    defer {
        for (pending.items) |p| {
            if (p.dir) |dir| _ = c.closedir(dir);
            gpa.free(p.rel);
        }
        pending.deinit(gpa);
    }
    {
        const rel = try gpa.dupeSentinel(u8, "", 0);
        errdefer gpa.free(rel);
        try pending.append(gpa, .{ .rel = rel });
    }
    const home = isHome(root);
    var live: usize = 0;
    while (pending.items.len > 0 and f.paths.items.len < max_files) {
        const index = pending.items.len - 1;
        const p = pending.items[index];
        const consumed = p.consumed orelse {
            gpa.free(pending.pop().?.rel);
            continue;
        };
        var dir = p.dir;
        if (dir == null) {
            // Ordinary wide folders resume their open cursor directly. Only
            // deep traversal spills the oldest live ancestor.
            if (live == live_cursors) {
                for (pending.items) |*ancestor| {
                    if (ancestor.dir) |old| {
                        _ = c.closedir(old);
                        ancestor.dir = null;
                        live -= 1;
                        break;
                    }
                }
            }
            const fd = openRelative(root_fd, p.rel);
            if (fd < 0) {
                gpa.free(pending.pop().?.rel);
                continue;
            }
            const opened = c.fdopendir(fd) orelse {
                _ = c.close(fd);
                gpa.free(pending.pop().?.rel);
                continue;
            };
            // A spilled frame replays its prefix instead of reusing opaque
            // telldir cookies from a closed DIR stream.
            var skipped: usize = 0;
            while (skipped < consumed) : (skipped += 1) {
                if (c.readdir(opened) == null) break;
            }
            dir = opened;
            pending.items[index].dir = opened;
            live += 1;
        }
        // walk may grow pending, so reacquire the parent by index afterward.
        const next = try walk(&f, gpa, dir.?, p.rel, consumed, &pending, home and p.rel.len == 0, include_hidden);
        pending.items[index].consumed = next;
        if (next == null) {
            _ = c.closedir(dir.?);
            pending.items[index].dir = null;
            live -= 1;
        }
    }
    return f;
}

/// True when `root` is the user's home folder, whose Library is all caches
/// and app data, and walking it trips macOS privacy prompts.
fn isHome(root: []const u8) bool {
    const home = std.mem.span(c.getenv("HOME") orelse return false);
    return home.len > 1 and std.mem.eql(u8, std.mem.trimEnd(u8, root, "/"), std.mem.trimEnd(u8, home, "/"));
}

// Reopen one component at a time: NOFOLLOW also protects queued ancestors
// replaced by symlinks. Reopening uses at most two transient descriptors in
// addition to root and the bounded live cursor set.
fn openRelative(root_fd: c.fd_t, rel: [:0]u8) c.fd_t {
    const flags: c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true };
    if (rel.len == 0) return c.openat(root_fd, ".", flags);
    var fd = root_fd;
    var start: usize = 0;
    while (start < rel.len) {
        const end = std.mem.indexOfScalarPos(u8, rel, start, '/') orelse rel.len;
        const saved = rel[end];
        rel[end] = 0;
        const next = c.openat(fd, @ptrCast(rel.ptr + start), flags);
        rel[end] = saved;
        if (fd != root_fd) _ = c.close(fd);
        if (next < 0) return -1;
        fd = next;
        start = end + 1;
    }
    return fd;
}

// Queue one bounded batch and retain the caller-owned cursor for its next
// batch. Only depth-spilled cursors reread prefixes; concurrent directory
// edits can shift those prefixes because discovery is not a snapshot.
fn walk(f: *Files, gpa: Allocator, dir: *c.DIR, rel: []const u8, consumed: usize, pending: *std.ArrayList(Pending), home: bool, include_hidden: bool) !?usize {
    const dir_fd = dirfd(dir);
    var read = consumed;
    var queued: usize = 0;
    // Batch size bounds storage, not traversal: no directory-only branch is
    // dropped to satisfy the file cap or the pending-path budget.
    while (c.readdir(dir)) |ent| {
        if (f.paths.items.len >= max_files) return null;
        read += 1;
        const name = ent.name[0..ent.namlen];
        if (name.len == 0 or isAlwaysSkipped(name) or (name[0] == '.' and !include_hidden)) continue;
        const name_z: [*:0]const u8 = @ptrCast(&ent.name);
        const kind = if (ent.type == c.DT.UNKNOWN) typeOf(dir_fd, name_z, false) else ent.type;
        switch (kind) {
            c.DT.DIR => if (!isSkipped(name) and !(home and std.mem.eql(u8, name, "Library"))) {
                const sub = try dupeRel(gpa, rel, name);
                errdefer gpa.free(sub);
                try pending.append(gpa, .{ .rel = sub });
                queued += 1;
                if (queued == walk_batch) return read;
            },
            c.DT.REG => try f.paths.append(gpa, try dupeRel(f.arena.allocator(), rel, name)),
            // A link to a folder isn't walked, so a link cycle can't fill the list.
            c.DT.LNK => if (typeOf(dir_fd, name_z, true) == c.DT.REG) try f.paths.append(gpa, try dupeRel(f.arena.allocator(), rel, name)),
            else => {},
        }
    }
    return null;
}

fn dupeRel(arena: Allocator, prefix: []const u8, name: []const u8) ![:0]u8 {
    if (prefix.len == 0) return arena.dupeSentinel(u8, name, 0);
    const len = prefix.len + 1 + name.len;
    const buf = try arena.alloc(u8, len + 1);
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '/';
    @memcpy(buf[prefix.len + 1 .. len], name);
    buf[len] = 0;
    return buf[0..len :0];
}

/// The `DT` type of `name_z` under `dir_fd`, following a link only when `follow` is set.
fn typeOf(dir_fd: c.fd_t, name_z: [*:0]const u8, follow: bool) u8 {
    var st: c.Stat = undefined;
    if (c.fstatat(dir_fd, name_z, &st, if (follow) 0 else c.AT.SYMLINK_NOFOLLOW) != 0) return c.DT.UNKNOWN;
    return switch (st.mode & c.S.IFMT) {
        c.S.IFDIR => c.DT.DIR,
        c.S.IFREG => c.DT.REG,
        c.S.IFLNK => c.DT.LNK,
        else => c.DT.UNKNOWN,
    };
}

/// `.` and `..` would loop, and `.git` is all objects nobody opens by hand.
fn isAlwaysSkipped(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.eql(u8, name, ".git");
}

fn isSkipped(name: []const u8) bool {
    for (skip) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// Scores `path` against `q`: null when a space-separated word of `q` isn't
/// a subsequence of it. Every word has to match.
/// Rewards runs, starts of words, camelCase humps, matches in the file name,
/// a file name that equals or starts with a word, and exact case when the
/// word has a capital in it.
pub fn score(path: []const u8, q: []const u8) ?i32 {
    var s: i64 = 0;
    var words = std.mem.tokenizeScalar(u8, q, ' ');
    var any = false;
    while (words.next()) |w| {
        s +|= wordScore(path, w) orelse return null;
        any = true;
    }
    if (!any) return 0;
    return @intCast(@min(std.math.maxInt(i32), s *| 64 - @as(i64, @intCast(@min(path.len, 63)))));
}

fn wordScore(path: []const u8, q: []const u8) ?i32 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
    var has_upper = false;
    for (q) |ch| {
        if (std.ascii.isUpper(ch)) has_upper = true;
    }
    var s: i32 = 0;
    var qi: usize = 0;
    var prev: ?usize = null;
    for (path, 0..) |ch, i| {
        if (qi == q.len) break;
        if (std.ascii.toLower(ch) != std.ascii.toLower(q[qi])) continue;
        s +|= 1;
        if (prev != null and prev.? + 1 == i) s +|= 6;
        if (i == 0 or std.mem.indexOfScalar(u8, "/_-. ", path[i - 1]) != null) {
            s +|= 8;
        } else if (std.ascii.isUpper(ch) and std.ascii.isLower(path[i - 1])) {
            s +|= 7;
        }
        if (i >= base) s +|= 2;
        if (has_upper and ch == q[qi]) s +|= 1;
        prev = i;
        qi += 1;
    }
    if (qi < q.len) return null;
    const name = path[base..];
    const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| (if (i > 0) name[0..i] else name) else name;
    if (std.ascii.eqlIgnoreCase(name, q) or std.ascii.eqlIgnoreCase(stem, q)) {
        s +|= 40;
    } else if (std.ascii.startsWithIgnoreCase(name, q)) {
        s +|= 20;
    }
    return s;
}

/// An extra score for one path in `best`, such as an open tab or a
/// recent file. `path` is compared with the scanned paths byte for byte.
pub const Boost = struct {
    path: []const u8,
    /// Added to the path's score; `score` counts 64 per matched-letter point.
    amount: i32,
};

/// Fills `out` (at most 32 long) with the indexes of the best matches in
/// `paths`, best first, adding each matching `Boost` to a path's score (a
/// boosted path still has to match `q`). When `matched` is non-null, sets
/// `matched.*` to the total number of matching paths in the same pass.
pub fn best(paths: []const []const u8, q: []const u8, boosts: []const Boost, out: []usize, matched: ?*usize) usize {
    var max_boost: i32 = 0;
    for (boosts, 0..) |b, bi| {
        if (b.amount <= 0) continue;
        var sum: i32 = b.amount;
        for (boosts[bi + 1 ..]) |b2| {
            if (b2.amount > 0 and std.mem.eql(u8, b.path, b2.path)) sum +|= b2.amount;
        }
        max_boost = @max(max_boost, sum);
    }
    var scores: [32]i32 = undefined;
    const cap = @min(out.len, scores.len);
    var n: usize = 0;
    var total: usize = 0;
    for (paths, 0..) |p, i| {
        var s = score(p, q) orelse continue;
        total += 1;
        if (cap == 0) continue;
        if (n == cap and s +| max_boost <= scores[cap - 1]) continue;
        for (boosts) |b| {
            if (std.mem.eql(u8, b.path, p)) s +|= b.amount;
        }
        if (n == cap and s <= scores[cap - 1]) continue;
        var at = n;
        while (at > 0 and scores[at - 1] < s) at -= 1;
        if (n < cap) n += 1;
        var j = n - 1;
        while (j > at) : (j -= 1) {
            out[j] = out[j - 1];
            scores[j] = scores[j - 1];
        }
        out[at] = i;
        scores[at] = s;
    }
    if (matched) |m| m.* = total;
    return n;
}

const t = std.testing;

test "queued paths reopen components without following symlink ancestors" {
    var buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrintSentinel(&buf, "/tmp/ze-finder-test-{d}", .{c.getpid()}, 0);
    try t.expect(c.mkdir(root, 0o700) == 0);
    defer _ = c.rmdir(root);
    const flags: c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const root_fd = c.open(root, flags);
    try t.expect(root_fd >= 0);
    defer _ = c.close(root_fd);
    try t.expect(c.mkdirat(root_fd, "real", 0o700) == 0);
    defer _ = c.unlinkat(root_fd, "real", c.AT.REMOVEDIR);
    const real_fd = c.openat(root_fd, "real", flags);
    try t.expect(real_fd >= 0);
    defer _ = c.close(real_fd);
    try t.expect(c.mkdirat(real_fd, "child", 0o700) == 0);
    defer _ = c.unlinkat(real_fd, "child", c.AT.REMOVEDIR);
    try t.expect(c.symlinkat("real", root_fd, "alias") == 0);
    defer _ = c.unlinkat(root_fd, "alias", 0);

    const rel = try dupeRel(t.allocator, "real", "child");
    defer t.allocator.free(rel);
    const fd = openRelative(root_fd, rel);
    try t.expect(fd >= 0);
    defer _ = c.close(fd);
    try t.expectEqualStrings("real/child", rel);
    const alias = try dupeRel(t.allocator, "alias", "child");
    defer t.allocator.free(alias);
    try t.expect(openRelative(root_fd, alias) < 0);
    try t.expectEqualStrings("alias/child", alias);

    var found = try scan(t.allocator, root, false);
    defer found.deinit();
    try t.expectEqual(@as(usize, 0), found.paths.items.len);
}

test "wide directory-only parents resume bounded batches and visit every child" {
    const count = walk_batch + 3;
    var buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrintSentinel(&buf, "/tmp/ze-finder-wide-{d}", .{c.getpid()}, 0);
    try t.expect(c.mkdir(root, 0o700) == 0);
    defer _ = c.rmdir(root);
    const flags: c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const root_fd = c.open(root, flags);
    try t.expect(root_fd >= 0);
    defer _ = c.close(root_fd);
    var name_buf: [64]u8 = undefined;
    defer for (0..count) |i| {
        const file = std.fmt.bufPrintSentinel(&name_buf, "d{d}/marker", .{i}, 0) catch continue;
        _ = c.unlinkat(root_fd, file, 0);
        const name = std.fmt.bufPrintSentinel(&name_buf, "d{d}", .{i}, 0) catch continue;
        _ = c.unlinkat(root_fd, name, c.AT.REMOVEDIR);
    };
    for (0..count) |i| {
        const name = try std.fmt.bufPrintSentinel(&name_buf, "d{d}", .{i}, 0);
        try t.expect(c.mkdirat(root_fd, name, 0o700) == 0);
        const file = try std.fmt.bufPrintSentinel(&name_buf, "d{d}/marker", .{i}, 0);
        const fd = c.openat(root_fd, file, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        try t.expect(fd >= 0);
        _ = c.close(fd);
    }

    const reader_fd = c.openat(root_fd, ".", flags);
    try t.expect(reader_fd >= 0);
    const dir = c.fdopendir(reader_fd) orelse {
        _ = c.close(reader_fd);
        return error.OpenDirectoryFailed;
    };
    defer _ = c.closedir(dir);
    var partial: Files = .{ .gpa = t.allocator, .arena = .init(t.allocator) };
    defer partial.deinit();
    var pending: std.ArrayList(Pending) = .empty;
    defer {
        for (pending.items) |p| t.allocator.free(p.rel);
        pending.deinit(t.allocator);
    }
    const next = (try walk(&partial, t.allocator, dir, "", 0, &pending, false, false)).?;
    try t.expectEqual(@as(usize, walk_batch), pending.items.len);
    for (pending.items) |p| t.allocator.free(p.rel);
    pending.clearRetainingCapacity();
    try t.expect((try walk(&partial, t.allocator, dir, "", next, &pending, false, false)) == null);
    try t.expectEqual(@as(usize, 3), pending.items.len);

    var found = try scan(t.allocator, root, false);
    defer found.deinit();
    try t.expectEqual(@as(usize, count), found.paths.items.len);
    for (0..count) |i| {
        const want = try std.fmt.bufPrint(&name_buf, "d{d}/marker", .{i});
        var matched = false;
        for (found.paths.items) |path| {
            if (std.mem.eql(u8, want, path)) {
                matched = true;
                break;
            }
        }
        try t.expect(matched);
    }
}

test "file name matches beat deep path matches" {
    const paths = [_][]const u8{ "src/editor/view_main.zig", "docs/main-notes.md", "src/main.zig", "README.md" };
    var out: [3]usize = undefined;
    const n = best(&paths, "main", &.{}, &out, null);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqualStrings("src/main.zig", paths[out[0]]);
    try t.expect(score("README.md", "main") == null);
}

test "every word of a multi-word query has to match" {
    try t.expect(score("src/view.zig", "view zig") != null);
    try t.expect(score("src/view.zig", "view rs") == null);
    try t.expect(score("src/view.zig", "  ") == 0);
}

test "pasted repeated tokens saturate without changing normal scores or accepting a later mismatch" {
    try t.expectEqual(@as(i32, 3263), score("a", "a").?);
    try t.expectEqual(@as(i32, 6527), score("a", "a a").?);
    const query = try t.allocator.alloc(u8, 700_000 * 2);
    defer t.allocator.free(query);
    for (query, 0..) |*ch, i| ch.* = if (i % 2 == 0) 'a' else ' ';
    try t.expectEqual(std.math.maxInt(i32), score("a", query).?);
    const paths = [_][]const u8{ "aa", "a" };
    var out: [2]usize = undefined;
    try t.expectEqual(@as(usize, 2), best(&paths, query, &.{.{ .path = "a", .amount = 1000 }}, &out, null));
    try t.expectEqual(@as(usize, 1), out[0]);
    query[query.len - 2] = 'b';
    try t.expect(score("a", query) == null);
}

test "camelCase humps and exact file names score higher" {
    try t.expect(score("src/FileTree.swift", "ft").? > score("src/after.swift", "ft").?);
    try t.expect(score("src/main.zig", "main").? > score("src/mainframe.zig", "main").?);
    try t.expect(score("src/Main.zig", "Main").? > score("src/main.zig", "Main").?);
}

test "boosts lift open files to the top" {
    const paths = [_][]const u8{ "a.zig", "b.zig", "c.zig" };
    var out: [3]usize = undefined;
    const n = best(&paths, "", &.{.{ .path = "c.zig", .amount = 1000 }}, &out, null);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqualStrings("c.zig", paths[out[0]]);
}

test "best counts all matches even beyond output capacity and skips below boost bound" {
    const paths = [_][]const u8{ "a.zig", "b.zig", "c.zig", "d.zig", "README.md" };
    var out: [2]usize = undefined;
    var matched: usize = 0;
    const n = best(&paths, "zig", &.{.{ .path = "d.zig", .amount = 1000 }}, &out, &matched);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(@as(usize, 4), matched);
    try t.expectEqualStrings("d.zig", paths[out[0]]);
    try t.expectEqualStrings("a.zig", paths[out[1]]);

    var zero_out: [0]usize = undefined;
    try t.expectEqual(@as(usize, 0), best(&paths, "zig", &.{}, &zero_out, &matched));
    try t.expectEqual(@as(usize, 4), matched);
}
