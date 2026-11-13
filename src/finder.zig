//! Quick open: every file under the root folder, and a fuzzy match over them.
const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;

pub const max_files = 100_000;

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

/// Lists files under `root`, relative to it, leaving out dotfiles.
pub fn scan(gpa: Allocator, root: []const u8) !Files {
    return scanWithOptions(gpa, root, false, &.{});
}

const Options = struct {
    include_hidden: bool,
    extra_skips: []const []const u8,
};

/// Lists files under `root`, relative to it. `include_hidden` lists dotfiles
/// and dot folders such as `.gitignore` and `.github/`, but never `.git`.
/// `extra_skips` names more folders to leave out, on top of the built-in list.
pub fn scanWithOptions(gpa: Allocator, root: []const u8, include_hidden: bool, extra_skips: []const []const u8) !Files {
    var f: Files = .{ .gpa = gpa, .arena = .init(gpa) };
    errdefer f.deinit();
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    try path.appendSlice(gpa, root);
    const opts: Options = .{ .include_hidden = include_hidden, .extra_skips = extra_skips };
    try walk(&f, gpa, &path, root.len + 1, isHome(root), &opts);
    return f;
}

/// True when `root` is the user's home folder, whose Library is all caches
/// and app data, and walking it trips macOS privacy prompts.
fn isHome(root: []const u8) bool {
    const home = std.mem.span(c.getenv("HOME") orelse return false);
    return home.len > 1 and std.mem.eql(u8, std.mem.trimEnd(u8, root, "/"), std.mem.trimEnd(u8, home, "/"));
}

fn walk(f: *Files, gpa: Allocator, path: *std.ArrayList(u8), rel: usize, home: bool, opts: *const Options) !void {
    try path.append(gpa, 0);
    const dir = c.opendir(@ptrCast(path.items.ptr)) orelse return path.shrinkRetainingCapacity(path.items.len - 1);
    path.items.len -= 1;
    defer _ = c.closedir(dir);
    const len = path.items.len;
    while (c.readdir(dir)) |ent| {
        if (f.paths.items.len >= max_files) return;
        const name = ent.name[0..ent.namlen];
        if (name.len == 0 or isAlwaysSkipped(name) or (name[0] == '.' and !opts.include_hidden)) continue;
        path.shrinkRetainingCapacity(len);
        try path.append(gpa, '/');
        try path.appendSlice(gpa, name);
        const kind = if (ent.type == c.DT.UNKNOWN) try typeOf(gpa, path, false) else ent.type;
        switch (kind) {
            c.DT.DIR => if (!isSkipped(name, opts.extra_skips) and !(home and std.mem.eql(u8, name, "Library"))) try walk(f, gpa, path, rel, false, opts),
            c.DT.REG => try f.paths.append(gpa, try f.arena.allocator().dupe(u8, path.items[rel..])),
            // A link to a folder isn't walked, so a link cycle can't fill the list.
            c.DT.LNK => if (try typeOf(gpa, path, true) == c.DT.REG) try f.paths.append(gpa, try f.arena.allocator().dupe(u8, path.items[rel..])),
            else => {},
        }
    }
}

/// The `DT` type of `path`, following a link only when `follow` is set.
fn typeOf(gpa: Allocator, path: *std.ArrayList(u8), follow: bool) !u8 {
    try path.append(gpa, 0);
    defer path.items.len -= 1;
    var st: c.Stat = undefined;
    if (c.fstatat(c.AT.FDCWD, @ptrCast(path.items.ptr), &st, if (follow) 0 else c.AT.SYMLINK_NOFOLLOW) != 0) return c.DT.UNKNOWN;
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

fn isSkipped(name: []const u8, extra: []const []const u8) bool {
    for (skip) |s| if (std.mem.eql(u8, s, name)) return true;
    for (extra) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// Scores `path` against `q`: null when a space-separated word of `q` isn't
/// a subsequence of it. Every word has to match.
/// Rewards runs, starts of words, camelCase humps, matches in the file name,
/// a file name that equals or starts with a word, and exact case when the
/// word has a capital in it.
pub fn score(path: []const u8, q: []const u8) ?i32 {
    var s: i32 = 0;
    var words = std.mem.tokenizeScalar(u8, q, ' ');
    var any = false;
    while (words.next()) |w| {
        s += wordScore(path, w) orelse return null;
        any = true;
    }
    if (!any) return 0;
    return s * 64 - @as(i32, @intCast(@min(path.len, 63)));
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
        s += 1;
        if (prev != null and prev.? + 1 == i) s += 6;
        if (i == 0 or std.mem.indexOfScalar(u8, "/_-. ", path[i - 1]) != null) {
            s += 8;
        } else if (std.ascii.isUpper(ch) and std.ascii.isLower(path[i - 1])) {
            s += 7;
        }
        if (i >= base) s += 2;
        if (has_upper and ch == q[qi]) s += 1;
        prev = i;
        qi += 1;
    }
    if (qi < q.len) return null;
    const name = path[base..];
    const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| (if (i > 0) name[0..i] else name) else name;
    if (std.ascii.eqlIgnoreCase(name, q) or std.ascii.eqlIgnoreCase(stem, q)) {
        s += 40;
    } else if (std.ascii.startsWithIgnoreCase(name, q)) {
        s += 20;
    }
    return s;
}

/// An extra score for one path in `bestWithBoost`, such as an open tab or a
/// recent file. `path` is compared with the scanned paths byte for byte.
pub const Boost = struct {
    path: []const u8,
    /// Added to the path's score; `score` counts 64 per matched-letter point.
    amount: i32,
};

/// Fills `out` (at most 32 long) with the indexes of the best matches, best first.
pub fn best(paths: []const []const u8, q: []const u8, out: []usize) usize {
    return bestWithBoost(paths, q, out, &.{});
}

/// Like `best`, but adds each matching `Boost` to a path's score, so open tabs
/// and recent files come first when `q` is empty and rank higher when it matches.
/// A boosted path still has to match `q`.
pub fn bestWithBoost(paths: []const []const u8, q: []const u8, out: []usize, boosts: []const Boost) usize {
    var scores: [32]i32 = undefined;
    const cap = @min(out.len, scores.len);
    var n: usize = 0;
    for (paths, 0..) |p, i| {
        var s = score(p, q) orelse continue;
        for (boosts) |b| {
            if (std.mem.eql(u8, b.path, p)) s +|= b.amount;
        }
        var at = n;
        while (at > 0 and scores[at - 1] < s) at -= 1;
        if (at >= cap) continue;
        if (n < cap) n += 1;
        var j = n - 1;
        while (j > at) : (j -= 1) {
            out[j] = out[j - 1];
            scores[j] = scores[j - 1];
        }
        out[at] = i;
        scores[at] = s;
    }
    return n;
}

const t = std.testing;

test "file name matches beat deep path matches" {
    const paths = [_][]const u8{ "src/editor/view_main.zig", "docs/main-notes.md", "src/main.zig", "README.md" };
    var out: [3]usize = undefined;
    const n = best(&paths, "main", &out);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqualStrings("src/main.zig", paths[out[0]]);
    try t.expect(score("README.md", "main") == null);
}

test "every word of a multi-word query has to match" {
    try t.expect(score("src/view.zig", "view zig") != null);
    try t.expect(score("src/view.zig", "view rs") == null);
    try t.expect(score("src/view.zig", "  ") == 0);
}

test "camelCase humps and exact file names score higher" {
    try t.expect(score("src/FileTree.swift", "ft").? > score("src/after.swift", "ft").?);
    try t.expect(score("src/main.zig", "main").? > score("src/mainframe.zig", "main").?);
    try t.expect(score("src/Main.zig", "Main").? > score("src/main.zig", "Main").?);
}

test "boosts lift open files to the top" {
    const paths = [_][]const u8{ "a.zig", "b.zig", "c.zig" };
    var out: [3]usize = undefined;
    const n = bestWithBoost(&paths, "", &out, &.{.{ .path = "c.zig", .amount = 1000 }});
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqualStrings("c.zig", paths[out[0]]);
}
