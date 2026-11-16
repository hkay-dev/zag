//! Reading and saving files straight through libc, which keeps std.Io (and
//! its size) out of the binary.
const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;

extern "c" fn mkstemp(template: [*:0]u8) c_int;
extern "c" fn copyfile(from: [*:0]const u8, to: [*:0]const u8, state: ?*anyopaque, flags: u32) c_int;
extern "c" fn umask(mask: c.mode_t) c.mode_t;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const w_ok = 2;
const copy_acl = 1 << 0;
const copy_xattr = 1 << 2;

const max_size = 1 << 30;

/// The whole file. error.FileNotFound when it doesn't exist yet, and
/// error.NotAFile for a pipe, socket or device, which it opens without
/// blocking so a FIFO with no writer can't hang the caller.
pub fn read(gpa: Allocator, path: [:0]const u8) ![]u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
    if (fd < 0) return if (c._errno().* == @intFromEnum(c.E.NOENT)) error.FileNotFound else error.ReadFailed;
    defer _ = c.close(fd);
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.ReadFailed;
    if (st.mode & c.S.IFMT != c.S.IFREG) return error.NotAFile;
    if (st.size > max_size) return error.FileTooBig;
    const buf = try gpa.alloc(u8, @intCast(st.size));
    errdefer gpa.free(buf);
    var n: usize = 0;
    while (n < buf.len) {
        const r = c.read(fd, buf[n..].ptr, buf.len - n);
        if (r < 0) return error.ReadFailed;
        if (r == 0) return gpa.realloc(buf, n); // the file shrank after fstat
        n += @intCast(r);
    }
    return buf;
}

/// Writes a hidden temp file (`.ze-XXXXXX`) beside `path`, syncs it,
/// then renames it over `path`, so a crash mid-save leaves the old file whole
/// and the sidebar lists no leftover. Keeps the file's mode,
/// extended attributes (Finder tags among them) and ACL; a new file gets
/// 0666 less the umask, as `open` would give it.
pub fn write(name: [:0]const u8, data: []const u8) !void {
    var path_buf: [c.PATH_MAX]u8 = undefined;
    const path = try resolvePath(name, &path_buf);
    var tmp_buf: [c.PATH_MAX + 32]u8 = undefined;
    const dir = std.fs.path.dirname(path) orelse ".";
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}/.ze-XXXXXX", .{dir}, 0);
    const fd = mkstemp(tmp.ptr);
    if (fd < 0) return error.WriteFailed;
    errdefer {
        const saved_errno = c._errno().*;
        _ = c.unlink(tmp.ptr);
        c._errno().* = saved_errno;
    }
    {
        defer {
            const saved_errno = c._errno().*;
            _ = c.close(fd);
            c._errno().* = saved_errno;
        }
        var n: usize = 0;
        while (n < data.len) {
            const r = c.write(fd, data[n..].ptr, data.len - n);
            if (r <= 0) return error.WriteFailed;
            n += @intCast(r);
        }
        var st: c.Stat = undefined;
        const old = c.stat(path, &st) == 0;
        if (!old and c._errno().* != @intFromEnum(c.E.NOENT)) return error.WriteFailed;
        const mode: c.mode_t = if (old) st.mode & 0o7777 else 0o666 & ~currentUmask();
        if (old and copyfile(path, tmp.ptr, null, copy_acl | copy_xattr) != 0) return error.WriteFailed;
        if (c.fchmod(fd, mode) != 0 or c.fsync(fd) != 0) return error.WriteFailed;
    }
    if (c.rename(tmp.ptr, path) != 0) return error.WriteFailed;
}

/// Creates an empty file without following or replacing an existing leaf.
pub fn create(path: [:0]const u8) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o666));
    if (fd < 0) return if (c._errno().* == @intFromEnum(c.E.EXIST)) error.PathAlreadyExists else error.WriteFailed;
    if (c.close(fd) != 0) return error.WriteFailed;
}

/// Darwin handles case-only changes atomically, but rejects any other
/// occupied destination, including dangling symlinks and distinct hardlinks.
pub fn renameNoReplace(from: [:0]const u8, to: [:0]const u8) !void {
    if (c.renameatx_np(c.AT.FDCWD, from, c.AT.FDCWD, to, .{ .EXCL = true }) != 0)
        return if (c._errno().* == @intFromEnum(c.E.EXIST)) error.PathAlreadyExists else error.RenameFailed;
}

/// The process umask. umask() only reads it by setting it, so this puts it
/// back, setting 0777 meanwhile so a file made in between is never looser.
fn currentUmask() c.mode_t {
    const m = umask(0o777);
    _ = umask(m);
    return m;
}

/// False when the user may not write `path`, such as a file set to 0444.
/// Saving renames over the file, which the folder's permissions allow, so
/// the caller asks first.
pub fn writable(path: [:0]const u8) bool {
    return access(path, w_ok) == 0;
}

/// Absolute path for `path`, following even a dangling leaf symlink.
/// Missing parents remain available for makeParent; other failures propagate.
pub fn absolute(gpa: Allocator, path: []const u8) ![:0]u8 {
    var buf: [c.PATH_MAX]u8 = undefined;
    return gpa.dupeSentinel(u8, try resolvePath(path, &buf), 0);
}

fn resolvePath(path: []const u8, buf: *[c.PATH_MAX]u8) ![:0]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path.len >= c.PATH_MAX) return error.NameTooLong;
    var work: [c.PATH_MAX]u8 = undefined;
    var current: [:0]u8 = if (path[0] == '/')
        try std.fmt.bufPrintSentinel(&work, "{s}", .{path}, 0)
    else blk: {
        const here = c.getcwd(buf, buf.len) orelse return error.NoCwd;
        break :blk try std.fmt.bufPrintSentinel(&work, "{s}/{s}", .{ std.mem.span(@as([*:0]u8, @ptrCast(here))), path }, 0);
    };
    var link: [c.PATH_MAX]u8 = undefined;
    var followed: usize = 0;
    while (true) {
        if (c.realpath(current, buf)) |p| return std.mem.span(p);
        const failure = c._errno().*;
        if (failure == @intFromEnum(c.E.LOOP)) return error.SymlinkLoop;
        if (failure != @intFromEnum(c.E.NOENT)) return error.ResolveFailed;
        // A trailing slash requires a directory, not a new regular file.
        if (current[current.len - 1] == '/') return error.NotAFile;
        const n = c.readlink(current, &link, link.len);
        if (n >= 0) {
            if (n == link.len) return error.NameTooLong;
            if (followed == 40) {
                c._errno().* = @intFromEnum(c.E.LOOP);
                return error.SymlinkLoop;
            }
            followed += 1;
            const target = link[0..@intCast(n)];
            if (target.len == 0) return error.InvalidPath;
            const next = if (target[0] == '/')
                try std.fmt.bufPrintSentinel(buf, "{s}", .{target}, 0)
            else
                try std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ std.fs.path.dirname(current).?, target }, 0);
            @memcpy(work[0 .. next.len + 1], buf[0 .. next.len + 1]);
            current = work[0..next.len :0];
            continue;
        }
        if (c._errno().* != @intFromEnum(c.E.NOENT)) return error.ResolveFailed;
        const parent = try std.fmt.bufPrintSentinel(buf, "{s}", .{std.fs.path.dirname(current).?}, 0);
        if (c.realpath(parent, &link)) |p|
            return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ std.mem.span(p), std.fs.path.basename(current) }, 0);
        if (c._errno().* != @intFromEnum(c.E.NOENT)) return error.ResolveFailed;
        @memcpy(buf[0 .. current.len + 1], work[0 .. current.len + 1]);
        return buf[0..current.len :0];
    }
}

pub fn isDir(path: [:0]const u8) bool {
    var st: c.Stat = undefined;
    return c.stat(path, &st) == 0 and st.mode & c.S.IFMT == c.S.IFDIR;
}

pub fn exists(path: [:0]const u8) bool {
    return stamp(path) != null;
}

/// Makes the folder that `path` goes in, and its parents.
pub fn makeParent(path: [:0]const u8) !void {
    var buf: [c.PATH_MAX]u8 = undefined;
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    for (1..dir.len) |i| if (buf[i] == '/') {
        buf[i] = 0;
        _ = c.mkdir(@ptrCast(&buf), 0o755);
        buf[i] = '/';
    };
    _ = c.mkdir(@ptrCast(&buf), 0o755);
    if (!isDir(buf[0..dir.len :0])) return error.MakeDirFailed;
}

/// When a file last changed and how big it is, to notice edits from other apps.
pub const Stamp = struct { sec: i64, nsec: i64, size: i64 };

pub fn stampOf(st: c.Stat) Stamp {
    const m = st.mtime();
    return .{ .sec = m.sec, .nsec = m.nsec, .size = st.size };
}

/// Null when the file doesn't exist.
pub fn stamp(path: [:0]const u8) ?Stamp {
    var st: c.Stat = undefined;
    return if (c.stat(path, &st) == 0) stampOf(st) else null;
}

pub fn cwd(gpa: Allocator) ?[]u8 {
    var buf: [c.PATH_MAX]u8 = undefined;
    const p = c.getcwd(&buf, buf.len) orelse return null;
    return gpa.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(p)))) catch null;
}

const t = std.testing;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

fn entries(dir: [:0]const u8) usize {
    const d = c.opendir(dir).?;
    defer _ = c.closedir(d);
    var n: usize = 0;
    while (c.readdir(d)) |e| {
        const name = std.mem.sliceTo(&e.name, 0);
        n += @intFromBool(!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."));
    }
    return n;
}

extern "c" fn setxattr(path: [*:0]const u8, name: [*:0]const u8, value: *const anyopaque, size: usize, position: u32, options: c_int) c_int;
extern "c" fn getxattr(path: [*:0]const u8, name: [*:0]const u8, value: ?*anyopaque, size: usize, position: u32, options: c_int) isize;

const TestDir = struct {
    dir: [19:0]u8 = "/tmp/ze-test-XXXXXX".*,
    buf: [c.PATH_MAX]u8 = undefined,
    fn file(d: *TestDir, name: []const u8) [:0]const u8 {
        _ = mkdtemp(&d.dir).?;
        return std.fmt.bufPrintSentinel(&d.buf, "{s}/{s}", .{ &d.dir, name }, 0) catch unreachable;
    }
    fn deinit(d: *TestDir) void {
        _ = c.unlink(@ptrCast(&d.buf));
        _ = c.rmdir(&d.dir);
    }
};

test "save replaces the text, keeps the file's mode and tags and leaves no temp file" {
    var tmp: TestDir = .{};
    const path = tmp.file("run.sh");
    defer tmp.deinit();
    const was = umask(0o022);
    defer _ = umask(was);
    try t.expectError(error.FileNotFound, read(t.allocator, path));
    try write(path, "old");
    try t.expectEqual(@as(c.mode_t, 0o644), modeOf(path));
    try t.expect(writable(path));
    _ = c.chmod(path, 0o755);
    try t.expectEqual(@as(c_int, 0), setxattr(path, "dev.hkay.zag.test", "red", 3, 0, 0));
    try write(path, "new text");
    var tag: [8]u8 = undefined;
    const n = getxattr(path, "dev.hkay.zag.test", &tag, tag.len, 0, 0);
    try t.expectEqualStrings("red", tag[0..@intCast(@max(n, 0))]);

    const got = try read(t.allocator, path);
    defer t.allocator.free(got);
    try t.expectEqualStrings("new text", got);
    try t.expectEqual(@as(c.mode_t, 0o755), modeOf(path));
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "a new file takes the umask and a read-only file reads as not writable" {
    var tmp: TestDir = .{};
    const path = tmp.file("secret.txt");
    defer tmp.deinit();
    const was = umask(0o077);
    defer _ = umask(was);
    try write(path, "x");
    try t.expectEqual(@as(c.mode_t, 0o600), modeOf(path));
    _ = c.chmod(path, 0o444);
    try t.expect(!writable(path));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: c.mode_t) c_int;

test "read turns down a FIFO with no writer instead of blocking" {
    var tmp: TestDir = .{};
    const path = tmp.file("pipe");
    defer tmp.deinit();
    try t.expectEqual(@as(c_int, 0), mkfifo(path, 0o644));
    try t.expectError(error.NotAFile, read(t.allocator, path));
    try t.expectError(error.NotAFile, read(t.allocator, "/dev/zero"));
}

fn modeOf(path: [:0]const u8) c.mode_t {
    var st: c.Stat = undefined;
    _ = c.stat(path, &st);
    return st.mode & 0o777;
}

test "metadata copy failure preserves the original bytes and removes the temporary" {
    if (c.geteuid() == 0) return error.SkipZigTest;
    var tmp: TestDir = .{};
    const path = tmp.file("protected.txt");
    defer tmp.deinit();
    try write(path, "original");
    try t.expectEqual(@as(c_int, 0), c.chmod(path, 0));
    defer _ = c.chmod(path, 0o600);
    try t.expectError(error.WriteFailed, write(path, "replacement"));
    try t.expectEqual(@intFromEnum(c.E.ACCES), c._errno().*);
    try t.expectEqual(@as(c.mode_t, 0), modeOf(path));
    try t.expectEqual(@as(c_int, 0), c.chmod(path, 0o600));
    const got = try read(t.allocator, path);
    defer t.allocator.free(got);
    try t.expectEqualStrings("original", got);
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "atomic save supports a maximum length basename" {
    var tmp: TestDir = .{};
    const name: [255]u8 = @splat('a');
    const path = tmp.file(&name);
    defer tmp.deinit();
    try write(path, "old");
    try write(path, "new");
    const got = try read(t.allocator, path);
    defer t.allocator.free(got);
    try t.expectEqualStrings("new", got);
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "save follows dangling relative leaf chains without replacing either link" {
    var tmp: TestDir = .{};
    const alias = tmp.file("alias");
    defer tmp.deinit();
    var middle_buf: [c.PATH_MAX]u8 = undefined;
    const middle = try std.fmt.bufPrintSentinel(&middle_buf, "{s}/middle", .{&tmp.dir}, 0);
    defer _ = c.unlink(middle);
    var target_buf: [c.PATH_MAX]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&target_buf, "{s}/target", .{&tmp.dir}, 0);
    defer _ = c.unlink(target);
    try t.expectEqual(@as(c_int, 0), c.symlink("middle", alias));
    try t.expectEqual(@as(c_int, 0), c.symlink("target", middle));
    const resolved = try absolute(t.allocator, alias);
    defer t.allocator.free(resolved);
    const expected = try absolute(t.allocator, target);
    defer t.allocator.free(expected);
    try t.expectEqualStrings(expected, resolved);
    try write(alias, "first");
    try write(alias, "second");
    const got = try read(t.allocator, target);
    defer t.allocator.free(got);
    try t.expectEqualStrings("second", got);
    var link: [32]u8 = undefined;
    try t.expectEqual(@as(isize, 6), c.readlink(alias, &link, link.len));
    try t.expectEqualStrings("middle", link[0..6]);
    try t.expectEqual(@as(isize, 6), c.readlink(middle, &link, link.len));
    try t.expectEqualStrings("target", link[0..6]);
    try t.expectEqual(@as(usize, 3), entries(&tmp.dir));
}

test "absolute dangling leaf targets allow creation of missing parents" {
    var tmp: TestDir = .{};
    const alias = tmp.file("alias");
    defer tmp.deinit();
    var dir_buf: [c.PATH_MAX]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "{s}/missing", .{&tmp.dir}, 0);
    defer _ = c.rmdir(dir);
    var target_buf: [c.PATH_MAX]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&target_buf, "{s}/target", .{dir}, 0);
    defer _ = c.unlink(target);
    try t.expectEqual(@as(c_int, 0), c.symlink(target, alias));
    const resolved = try absolute(t.allocator, alias);
    defer t.allocator.free(resolved);
    try t.expectEqualStrings(target, resolved);
    try makeParent(resolved);
    try write(alias, "saved");
    const got = try read(t.allocator, target);
    defer t.allocator.free(got);
    try t.expectEqualStrings("saved", got);
    var link: [c.PATH_MAX]u8 = undefined;
    try t.expectEqual(@as(isize, @intCast(target.len)), c.readlink(alias, &link, link.len));
    try t.expectEqualStrings(target, link[0..target.len]);
}

test "cyclic leaf links fail resolution and saving without replacement" {
    var tmp: TestDir = .{};
    const first = tmp.file("first");
    defer tmp.deinit();
    var second_buf: [c.PATH_MAX]u8 = undefined;
    const second = try std.fmt.bufPrintSentinel(&second_buf, "{s}/second", .{&tmp.dir}, 0);
    defer _ = c.unlink(second);
    try t.expectEqual(@as(c_int, 0), c.symlink("second", first));
    try t.expectEqual(@as(c_int, 0), c.symlink("first", second));
    try t.expectError(error.SymlinkLoop, absolute(t.allocator, first));
    try t.expectError(error.SymlinkLoop, write(first, "replacement"));
    var link: [32]u8 = undefined;
    try t.expectEqual(@as(isize, 6), c.readlink(first, &link, link.len));
    try t.expectEqualStrings("second", link[0..6]);
    try t.expectEqual(@as(usize, 2), entries(&tmp.dir));
}

test "exclusive creation refuses existing files and dangling symlinks" {
    var tmp: TestDir = .{};
    const path = tmp.file("new.txt");
    defer tmp.deinit();
    const was = umask(0o077);
    defer _ = umask(was);
    try create(path);
    try t.expectEqual(@as(c.mode_t, 0o600), modeOf(path));
    try write(path, "original");
    try t.expectError(error.PathAlreadyExists, create(path));
    const got = try read(t.allocator, path);
    defer t.allocator.free(got);
    try t.expectEqualStrings("original", got);
    try t.expectEqual(@as(c_int, 0), c.unlink(path));
    try t.expectEqual(@as(c_int, 0), c.symlink("missing", path));
    try t.expectError(error.PathAlreadyExists, create(path));
    var link: [32]u8 = undefined;
    try t.expectEqual(@as(isize, 7), c.readlink(path, &link, link.len));
    try t.expectEqualStrings("missing", link[0..7]);
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "exclusive rename refuses files dangling symlinks and distinct hardlinks" {
    var tmp: TestDir = .{};
    const source = tmp.file("source");
    defer tmp.deinit();
    var dest_buf: [c.PATH_MAX]u8 = undefined;
    const dest = try std.fmt.bufPrintSentinel(&dest_buf, "{s}/destination", .{&tmp.dir}, 0);
    defer _ = c.unlink(dest);
    try write(source, "source bytes");
    try write(dest, "destination bytes");
    try t.expectError(error.PathAlreadyExists, renameNoReplace(source, dest));
    const got = try read(t.allocator, dest);
    defer t.allocator.free(got);
    try t.expectEqualStrings("destination bytes", got);
    try t.expectEqual(@as(c_int, 0), c.unlink(dest));
    try t.expectEqual(@as(c_int, 0), c.symlink("missing", dest));
    try t.expectError(error.PathAlreadyExists, renameNoReplace(source, dest));
    var link: [32]u8 = undefined;
    try t.expectEqual(@as(isize, 7), c.readlink(dest, &link, link.len));
    try t.expectEqualStrings("missing", link[0..7]);
    try t.expectEqual(@as(c_int, 0), c.unlink(dest));
    try t.expectEqual(@as(c_int, 0), c.link(source, dest));
    try t.expectError(error.PathAlreadyExists, renameNoReplace(source, dest));
    try t.expectEqual(@as(c_int, 0), c.unlink(dest));
    try renameNoReplace(source, dest);
    try t.expect(!exists(source));
    const moved = try read(t.allocator, dest);
    defer t.allocator.free(moved);
    try t.expectEqualStrings("source bytes", moved);
}

test "exclusive rename supports case-only changes without losing the entry" {
    var tmp: TestDir = .{};
    const source = tmp.file("notes.txt");
    defer tmp.deinit();
    var dest_buf: [c.PATH_MAX]u8 = undefined;
    const dest = try std.fmt.bufPrintSentinel(&dest_buf, "{s}/Notes.txt", .{&tmp.dir}, 0);
    defer _ = c.unlink(dest);
    try write(source, "notes");
    try renameNoReplace(source, dest);
    const got = try read(t.allocator, dest);
    defer t.allocator.free(got);
    try t.expectEqualStrings("notes", got);
    const dir = c.opendir(&tmp.dir).?;
    defer _ = c.closedir(dir);
    var found = false;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        try t.expect(!std.mem.eql(u8, name, "notes.txt"));
        if (std.mem.eql(u8, name, "Notes.txt")) found = true;
    }
    try t.expect(found);
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "save refuses missing directory paths and directory-valued dangling links" {
    var tmp: TestDir = .{};
    const alias = tmp.file("alias");
    defer tmp.deinit();
    var target_buf: [c.PATH_MAX]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&target_buf, "{s}/missing", .{&tmp.dir}, 0);
    defer _ = c.unlink(target);
    var slash_buf: [c.PATH_MAX]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&slash_buf, "{s}/", .{target}, 0);
    try t.expectError(error.NotAFile, absolute(t.allocator, directory));
    try t.expectError(error.NotAFile, write(directory, "not a directory"));
    try t.expect(!exists(target));
    try t.expectEqual(@as(usize, 0), entries(&tmp.dir));
    try t.expectEqual(@as(c_int, 0), c.symlink("missing/", alias));
    try t.expectError(error.NotAFile, absolute(t.allocator, alias));
    try t.expectError(error.NotAFile, write(alias, "not a directory"));
    try t.expect(!exists(target));
    var link: [32]u8 = undefined;
    try t.expectEqual(@as(isize, 8), c.readlink(alias, &link, link.len));
    try t.expectEqualStrings("missing/", link[0..8]);
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}
