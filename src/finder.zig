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

/// Lists files under `root`, relative to it.
pub fn scan(gpa: Allocator, root: []const u8) !Files {
    var f: Files = .{ .gpa = gpa, .arena = .init(gpa) };
    errdefer f.deinit();
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    try path.appendSlice(gpa, root);
    try walk(&f, gpa, &path, root.len + 1);
    return f;
}

fn walk(f: *Files, gpa: Allocator, path: *std.ArrayList(u8), rel: usize) !void {
    try path.append(gpa, 0);
    const dir = c.opendir(@ptrCast(path.items.ptr)) orelse return path.shrinkRetainingCapacity(path.items.len - 1);
    path.items.len -= 1;
    defer _ = c.closedir(dir);
    const len = path.items.len;
    while (c.readdir(dir)) |ent| {
        if (f.paths.items.len >= max_files) return;
        const name = ent.name[0..ent.namlen];
        if (name[0] == '.') continue;
        path.shrinkRetainingCapacity(len);
        try path.append(gpa, '/');
        try path.appendSlice(gpa, name);
        switch (ent.type) {
            c.DT.DIR => if (!isSkipped(name)) try walk(f, gpa, path, rel),
            c.DT.REG, c.DT.LNK => try f.paths.append(gpa, try f.arena.allocator().dupe(u8, path.items[rel..])),
            else => {},
        }
    }
}

fn isSkipped(name: []const u8) bool {
    for (skip) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// Scores `path` against `q`: null when `q` isn't a subsequence of it.
/// Rewards runs, starts of words, and matches in the file name.
pub fn score(path: []const u8, q: []const u8) ?i32 {
    return scoreWith(path, q, q);
}

/// `score` with `lower`, the query already lowercased, to match against.
fn scoreWith(path: []const u8, q: []const u8, lower: []const u8) ?i32 {
    if (q.len == 0) return 0;
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
    var s: i32 = 0;
    var qi: usize = 0;
    var prev: ?usize = null;
    for (path, 0..) |ch, i| {
        if (qi == q.len) break;
        if (std.ascii.toLower(ch) != lower[qi]) continue;
        s += 1;
        if (prev != null and prev.? + 1 == i) s += 6;
        if (i == 0 or std.mem.indexOfScalar(u8, "/_-. ", path[i - 1]) != null) s += 8;
        if (i >= base) s += 2;
        prev = i;
        qi += 1;
    }
    if (qi < q.len) return null;
    return s * 64 - @as(i32, @intCast(@min(path.len, 63)));
}

/// Fills `out` with the indexes of the best matches, best first.
pub fn best(paths: []const []const u8, q: []const u8, out: []usize) usize {
    var scores: [32]i32 = undefined;
    var n: usize = 0;
    // The query is lowercased once here, not for every character of every path.
    var low: [256]u8 = undefined;
    const lower = if (q.len <= low.len) std.ascii.lowerString(&low, q) else q;
    for (paths, 0..) |p, i| {
        const s = (if (q.len <= low.len) scoreWith(p, q, lower) else score(p, q)) orelse continue;
        var at = n;
        while (at > 0 and scores[at - 1] < s) at -= 1;
        if (at >= out.len) continue;
        if (n < out.len) n += 1;
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
