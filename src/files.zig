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
const copy_stat = 1 << 1;
const copy_data = 1 << 3;
const copy_excl = 1 << 17;

const max_size = 1 << 30;

/// Caller-owned bytes and the descriptor revision that supplied them.
pub const Snapshot = struct { bytes: []u8, stamp: Stamp };

/// error.FileNotFound when absent; error.NotAFile for a pipe, socket or
/// device, opened without blocking. Rejects a changed descriptor with
/// error.UnstableSnapshot instead of accepting partial or mixed bytes.
pub fn read(gpa: Allocator, path: [:0]const u8) !Snapshot {
    return readWithHook(gpa, path, null);
}

fn readWithHook(gpa: Allocator, path: [:0]const u8, comptime after_stat: ?fn ([:0]const u8) anyerror!void) !Snapshot {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
    if (fd < 0) return if (c._errno().* == @intFromEnum(c.E.NOENT)) error.FileNotFound else error.ReadFailed;
    defer _ = c.close(fd);
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.ReadFailed;
    if (st.mode & c.S.IFMT != c.S.IFREG) return error.NotAFile;
    if (st.size > max_size) return error.FileTooBig;
    const before = stampOf(st);
    if (after_stat) |hook| try hook(path);
    const buf = try gpa.alloc(u8, @intCast(st.size));
    errdefer gpa.free(buf);
    var n: usize = 0;
    while (n < buf.len) {
        const r = c.read(fd, buf[n..].ptr, buf.len - n);
        if (r < 0) return error.ReadFailed;
        if (r == 0) return error.UnstableSnapshot;
        n += @intCast(r);
    }
    if (c.fstat(fd, &st) != 0) return error.ReadFailed;
    if (!std.meta.eql(before, stampOf(st))) return error.UnstableSnapshot;
    return .{ .bytes = buf, .stamp = before };
}

/// Writes a hidden temp file (`.ze-XXXXXX`) beside `path`, syncs it,
/// then renames it over `path`, so a crash mid-save leaves the old file whole
/// and the sidebar lists no leftover. Keeps the file's mode,
/// extended attributes (Finder tags among them) and ACL; a new file gets
/// 0666 less the umask, as `open` would give it. Returns a descriptor receipt
/// for these bytes, never a later lookup of the destination pathname.
/// Errors precede publication. If post-rename verification is uncertain,
/// returns the prepublication receipt so later edits remain unacknowledged.
pub fn write(name: [:0]const u8, data: []const u8) !Stamp {
    return writeWithHook(name, data, null);
}

fn writeWithHook(name: [:0]const u8, data: []const u8, comptime after_rename: ?fn (c_int, [:0]const u8, Stamp) anyerror!void) !Stamp {
    var path_buf: [c.PATH_MAX]u8 = undefined;
    const path = try resolvePath(name, &path_buf);
    return writeResolved(path, data, after_rename);
}

fn writeResolved(path: [:0]const u8, data: []const u8, comptime after_rename: ?fn (c_int, [:0]const u8, Stamp) anyerror!void) !Stamp {
    var tmp_buf: [c.PATH_MAX + 32]u8 = undefined;
    const dir = std.fs.path.dirname(path) orelse ".";
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}/.ze-XXXXXX", .{dir}, 0);
    const fd = mkstemp(tmp.ptr);
    if (fd < 0) return error.WriteFailed;
    defer {
        const saved_errno = c._errno().*;
        _ = c.close(fd);
        c._errno().* = saved_errno;
    }
    errdefer {
        const saved_errno = c._errno().*;
        _ = c.unlink(tmp.ptr);
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
    if (c.fstat(fd, &st) != 0) return error.WriteFailed;
    const written = stampOf(st);
    if (c.rename(tmp.ptr, path) != 0) return error.WriteFailed;
    if (after_rename) |hook| hook(fd, path, written) catch return written;
    return verifiedWriteStamp(fd, data) orelse written;
}

fn verifiedWriteStamp(fd: c_int, data: []const u8) ?Stamp {
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.size < 0 or @as(u64, @intCast(st.size)) != data.len) return null;
    const before = stampOf(st);
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    while (n < data.len) {
        const len = @min(buf.len, data.len - n);
        const r = c.pread(fd, &buf, len, @intCast(n));
        if (r <= 0) return null;
        const count: usize = @intCast(r);
        if (!std.mem.eql(u8, buf[0..count], data[n..][0..count])) return null;
        n += count;
    }
    if (c.fstat(fd, &st) != 0 or !std.meta.eql(before, stampOf(st))) return null;
    return before;
}

/// Trashes an independent backup before replacement without removing the current
/// file. A failed replacement may leave an extra backup in Trash.
pub fn writeTrashing(name: [:0]const u8, data: []const u8, trash: *const fn ([]const u8) bool) !Stamp {
    var path_buf: [c.PATH_MAX]u8 = undefined;
    const path = try resolvePath(name, &path_buf);
    {
        var dir_buf: [c.PATH_MAX + 32]u8 = undefined;
        const dir = try std.fmt.bufPrintSentinel(&dir_buf, "{s}/.ze-XXXXXX", .{std.fs.path.dirname(path).?}, 0);
        if (mkdtemp(dir.ptr) == null) return error.WriteFailed;
        defer {
            const saved_errno = c._errno().*;
            _ = c.rmdir(dir);
            c._errno().* = saved_errno;
        }
        var backup_buf: [c.PATH_MAX + 64]u8 = undefined;
        const backup = try std.fmt.bufPrintSentinel(&backup_buf, "{s}/{s}", .{ dir, std.fs.path.basename(path) }, 0);
        var st: c.Stat = undefined;
        if (c.stat(path, &st) != 0) {
            if (c._errno().* != @intFromEnum(c.E.NOENT)) return error.WriteFailed;
        } else {
            if (st.mode & c.S.IFMT != c.S.IFREG) return error.WriteFailed;
            const before = stampOf(st);
            defer {
                const saved_errno = c._errno().*;
                _ = c.unlink(backup);
                c._errno().* = saved_errno;
            }
            if (copyfile(path, backup, null, copy_acl | copy_stat | copy_xattr | copy_data | copy_excl) != 0)
                return error.WriteFailed;
            if (c.stat(path, &st) != 0 or !std.meta.eql(before, stampOf(st))) return error.UnstableSnapshot;
            if (!trash(backup)) return error.TrashFailed;
        }
    }
    return writeResolved(path, data, null);
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

/// Descriptor identity, size and modification/change times for outside edits.
pub const Stamp = struct {
    sec: i64,
    nsec: i64,
    size: i64,
    dev: c.dev_t,
    ino: c.ino_t,
    csec: i64,
    cnsec: i64,
};

pub fn stampOf(st: c.Stat) Stamp {
    const m = st.mtime();
    const changed = st.ctime();
    return .{
        .sec = m.sec,
        .nsec = m.nsec,
        .size = st.size,
        .dev = st.dev,
        .ino = st.ino,
        .csec = changed.sec,
        .cnsec = changed.nsec,
    };
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
    _ = try write(path, "old");
    try t.expectEqual(@as(c.mode_t, 0o644), modeOf(path));
    try t.expect(writable(path));
    _ = c.chmod(path, 0o755);
    try t.expectEqual(@as(c_int, 0), setxattr(path, "dev.hkay.zag.test", "red", 3, 0, 0));
    const saved = try write(path, "new text");
    var tag: [8]u8 = undefined;
    const n = getxattr(path, "dev.hkay.zag.test", &tag, tag.len, 0, 0);
    try t.expectEqualStrings("red", tag[0..@intCast(@max(n, 0))]);

    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("new text", got.bytes);
    try t.expect(std.meta.eql(saved, got.stamp));
    try t.expect(std.meta.eql(saved, stamp(path).?));
    try t.expectEqual(@as(c.mode_t, 0o755), modeOf(path));
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "a new file takes the umask and a read-only file reads as not writable" {
    var tmp: TestDir = .{};
    const path = tmp.file("secret.txt");
    defer tmp.deinit();
    const was = umask(0o077);
    defer _ = umask(was);
    _ = try write(path, "x");
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
    _ = try write(path, "original");
    try t.expectEqual(@as(c_int, 0), c.chmod(path, 0));
    defer _ = c.chmod(path, 0o600);
    try t.expectError(error.WriteFailed, write(path, "replacement"));
    try t.expectEqual(@intFromEnum(c.E.ACCES), c._errno().*);
    try t.expectEqual(@as(c.mode_t, 0), modeOf(path));
    try t.expectEqual(@as(c_int, 0), c.chmod(path, 0o600));
    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("original", got.bytes);
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "atomic save supports a maximum length basename" {
    var tmp: TestDir = .{};
    const name: [255]u8 = @splat('a');
    const path = tmp.file(&name);
    defer tmp.deinit();
    _ = try write(path, "old");
    _ = try write(path, "new");
    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("new", got.bytes);
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
    _ = try write(alias, "first");
    _ = try write(alias, "second");
    const got = try read(t.allocator, target);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("second", got.bytes);
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
    _ = try write(alias, "saved");
    const got = try read(t.allocator, target);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("saved", got.bytes);
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
    _ = try write(path, "original");
    try t.expectError(error.PathAlreadyExists, create(path));
    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("original", got.bytes);
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
    _ = try write(source, "source bytes");
    _ = try write(dest, "destination bytes");
    try t.expectError(error.PathAlreadyExists, renameNoReplace(source, dest));
    const got = try read(t.allocator, dest);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("destination bytes", got.bytes);
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
    defer t.allocator.free(moved.bytes);
    try t.expectEqualStrings("source bytes", moved.bytes);
}

test "exclusive rename supports case-only changes without losing the entry" {
    var tmp: TestDir = .{};
    const source = tmp.file("notes.txt");
    defer tmp.deinit();
    var dest_buf: [c.PATH_MAX]u8 = undefined;
    const dest = try std.fmt.bufPrintSentinel(&dest_buf, "{s}/Notes.txt", .{&tmp.dir}, 0);
    defer _ = c.unlink(dest);
    _ = try write(source, "notes");
    try renameNoReplace(source, dest);
    const got = try read(t.allocator, dest);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("notes", got.bytes);
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

test "read snapshot retains its identity after a same-size pathname replacement" {
    var tmp: TestDir = .{};
    const path = tmp.file("snapshot");
    defer tmp.deinit();
    _ = try write(path, "old");
    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    _ = try write(path, "new");
    const times: [2]c.timespec = @splat(.{ .sec = got.stamp.sec, .nsec = got.stamp.nsec });
    try t.expectEqual(@as(c_int, 0), c.utimensat(c.AT.FDCWD, path, &times, 0));
    const replaced = stamp(path).?;
    try t.expectEqualStrings("old", got.bytes);
    try t.expectEqual(got.stamp.size, replaced.size);
    try t.expectEqual(got.stamp.sec, replaced.sec);
    try t.expectEqual(got.stamp.nsec, replaced.nsec);
    try t.expect(got.stamp.ino != replaced.ino);
    try t.expect(!std.meta.eql(got.stamp, replaced));
}

test "write acknowledges its descriptor when another writer replaces the committed path" {
    const Replacement = struct {
        var committed: Stamp = undefined;
        fn replace(_: c_int, path: [:0]const u8, _: Stamp) !void {
            committed = stamp(path).?;
            _ = try write(path, "other");
        }
    };
    var tmp: TestDir = .{};
    const path = tmp.file("snapshot");
    defer tmp.deinit();
    const saved = try writeWithHook(path, "saved", Replacement.replace);
    try t.expectEqual(Replacement.committed.dev, saved.dev);
    try t.expectEqual(Replacement.committed.ino, saved.ino);
    try t.expectEqual(Replacement.committed.size, saved.size);
    try t.expect(saved.ino != stamp(path).?.ino);
    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("other", got.bytes);
    try t.expect(!std.meta.eql(saved, got.stamp));
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "read rejects shrink growth and same-size changes between descriptor checks" {
    inline for (.{ "", "longer", "new" }) |replacement| {
        const Change = struct {
            fn apply(path: [:0]const u8) !void {
                const fd = c.open(path, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true });
                try t.expect(fd >= 0);
                defer _ = c.close(fd);
                try t.expectEqual(@as(isize, replacement.len), c.write(fd, replacement, replacement.len));
                // Force a distinct mtime without waiting for the filesystem clock.
                const times: [2]c.timespec = @splat(.{ .sec = 2, .nsec = 0 });
                try t.expectEqual(@as(c_int, 0), c.futimens(fd, &times));
            }
        };
        var tmp: TestDir = .{};
        const path = tmp.file("unstable");
        defer tmp.deinit();
        _ = try write(path, "old");
        const times: [2]c.timespec = @splat(.{ .sec = 1, .nsec = 0 });
        try t.expectEqual(@as(c_int, 0), c.utimensat(c.AT.FDCWD, path, &times, 0));
        try t.expectError(error.UnstableSnapshot, readWithHook(t.allocator, path, Change.apply));
        const got = try read(t.allocator, path);
        defer t.allocator.free(got.bytes);
        try t.expectEqualStrings(replacement, got.bytes);
        try t.expect(std.meta.eql(got.stamp, stamp(path).?));
    }
}

test "stamp distinguishes device inode and ctime with unchanged mtime and size" {
    const original: c.Stat = std.mem.zeroes(c.Stat);
    const before = stampOf(original);
    inline for (.{ "dev", "ino" }) |field| {
        var changed = original;
        @field(changed, field) = 1;
        try t.expect(!std.meta.eql(before, stampOf(changed)));
    }
    inline for (.{ "sec", "nsec" }) |field| {
        var changed = original;
        @field(changed.ctimespec, field) = 1;
        const after = stampOf(changed);
        try t.expectEqual(before.sec, after.sec);
        try t.expectEqual(before.nsec, after.nsec);
        try t.expectEqual(before.size, after.size);
        try t.expect(!std.meta.eql(before, after));
    }
}

test "writeTrashing staging failure preserves the source and removes its temporary directory" {
    const Trash = struct {
        var called = false;
        fn reject(_: []const u8) bool {
            called = true;
            return false;
        }
    };
    Trash.called = false;
    var tmp: TestDir = .{};
    const path = tmp.file("directory");
    defer tmp.deinit();
    try t.expectEqual(@as(c_int, 0), c.mkdir(path, 0o700));
    defer _ = c.rmdir(path);
    try t.expectError(error.WriteFailed, writeTrashing(path, "defaults", Trash.reject));
    try t.expect(!Trash.called);
    try t.expect(isDir(path));
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "writeTrashing creates an absent file without invoking Trash" {
    const Trash = struct {
        fn reject(_: []const u8) bool {
            return false;
        }
    };
    var tmp: TestDir = .{};
    const path = tmp.file("config.toml");
    defer tmp.deinit();
    const saved = try writeTrashing(path, "defaults", Trash.reject);
    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("defaults", got.bytes);
    try t.expect(std.meta.eql(saved, got.stamp));
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
}

test "write returns its prior receipt for in-place overwrites even with restored mtime" {
    inline for (.{ false, true }) |restore_mtime| {
        const Overwrite = struct {
            var written: Stamp = undefined;
            fn apply(_: c_int, path: [:0]const u8, receipt: Stamp) !void {
                written = receipt;
                const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
                try t.expect(fd >= 0);
                defer _ = c.close(fd);
                try t.expectEqual(@as(isize, 5), c.write(fd, "other", 5));
                const times: [2]c.timespec = @splat(if (restore_mtime)
                    .{ .sec = receipt.sec, .nsec = receipt.nsec }
                else
                    .{ .sec = 1, .nsec = 0 });
                try t.expectEqual(@as(c_int, 0), c.futimens(fd, &times));
            }
        };
        var tmp: TestDir = .{};
        const path = tmp.file("snapshot");
        defer tmp.deinit();
        const saved = try writeWithHook(path, "saved", Overwrite.apply);
        try t.expect(std.meta.eql(Overwrite.written, saved));
        const got = try read(t.allocator, path);
        defer t.allocator.free(got.bytes);
        try t.expectEqualStrings("other", got.bytes);
        try t.expectEqual(saved.ino, got.stamp.ino);
        try t.expect(!std.meta.eql(saved, got.stamp));
        if (restore_mtime) {
            try t.expectEqual(saved.sec, got.stamp.sec);
            try t.expectEqual(saved.nsec, got.stamp.nsec);
        }
    }
}

test "write returns its prior receipt after postcommit descriptor verification fails" {
    const Close = struct {
        var written: Stamp = undefined;
        fn apply(fd: c_int, _: [:0]const u8, receipt: Stamp) !void {
            written = receipt;
            try t.expectEqual(@as(c_int, 0), c.close(fd));
        }
    };
    var tmp: TestDir = .{};
    const path = tmp.file("snapshot");
    defer tmp.deinit();
    const saved = try writeWithHook(path, "saved", Close.apply);
    try t.expect(std.meta.eql(Close.written, saved));
    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("saved", got.bytes);
}

test "empty write verification refuses a nonempty descriptor" {
    var tmp: TestDir = .{};
    const path = tmp.file("snapshot");
    defer tmp.deinit();
    const saved = try write(path, "");
    try t.expect(std.meta.eql(saved, stamp(path).?));
    _ = try write(path, "not empty");
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    try t.expect(fd >= 0);
    defer _ = c.close(fd);
    try t.expect(verifiedWriteStamp(fd, "") == null);
}

test "writeTrashing archives independent bytes before the live config changes" {
    const Trash = struct {
        var live: [:0]const u8 = undefined;
        var archived: [:0]const u8 = undefined;
        fn moveAndEdit(name: []const u8) bool {
            var buf: [c.PATH_MAX + 64]u8 = undefined;
            const from = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return false;
            if (c.rename(from, archived) != 0) return false;
            const fd = c.open(live, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
            if (fd < 0) return false;
            defer _ = c.close(fd);
            return c.write(fd, "modified", 8) == 8;
        }
    };
    var tmp: TestDir = .{};
    const path = tmp.file("config.toml");
    defer tmp.deinit();
    var archive_buf: [c.PATH_MAX]u8 = undefined;
    const archived = try std.fmt.bufPrintSentinel(&archive_buf, "{s}/archived", .{&tmp.dir}, 0);
    defer _ = c.unlink(archived);
    Trash.live = path;
    Trash.archived = archived;
    _ = try write(path, "original");
    try t.expectEqual(@as(c_int, 0), c.chmod(path, 0o640));
    try t.expectEqual(@as(c_int, 0), setxattr(path, "dev.hkay.zag.test", "red", 3, 0, 0));
    _ = try writeTrashing(path, "defaults", Trash.moveAndEdit);
    const backup = try read(t.allocator, archived);
    defer t.allocator.free(backup.bytes);
    try t.expectEqualStrings("original", backup.bytes);
    try t.expectEqual(@as(c.mode_t, 0o640), modeOf(archived));
    var tag: [3]u8 = undefined;
    try t.expectEqual(@as(isize, 3), getxattr(archived, "dev.hkay.zag.test", &tag, tag.len, 0, 0));
    try t.expectEqualStrings("red", &tag);
    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("defaults", got.bytes);
    try t.expect(backup.stamp.ino != got.stamp.ino);
    try t.expectEqual(@as(usize, 2), entries(&tmp.dir));
}

test "writeTrashing copy failure preserves the source and removes partial backup" {
    if (c.geteuid() == 0) return error.SkipZigTest;
    const Trash = struct {
        var called = false;
        fn reject(_: []const u8) bool {
            called = true;
            return false;
        }
    };
    Trash.called = false;
    var tmp: TestDir = .{};
    const path = tmp.file("config.toml");
    defer tmp.deinit();
    _ = try write(path, "original");
    try t.expectEqual(@as(c_int, 0), c.chmod(path, 0));
    defer _ = c.chmod(path, 0o600);
    try t.expectError(error.WriteFailed, writeTrashing(path, "defaults", Trash.reject));
    try t.expect(!Trash.called);
    try t.expectEqual(@as(usize, 1), entries(&tmp.dir));
    try t.expectEqual(@as(c_int, 0), c.chmod(path, 0o600));
    const got = try read(t.allocator, path);
    defer t.allocator.free(got.bytes);
    try t.expectEqualStrings("original", got.bytes);
}
