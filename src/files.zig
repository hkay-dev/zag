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

/// Writes a hidden temp file (`.name.ze-XXXXXX`) beside `path`, syncs it,
/// then renames it over `path`, so a crash mid-save leaves the old file whole
/// and the sidebar lists no leftover. Keeps the file's mode,
/// extended attributes (Finder tags among them) and ACL; a new file gets
/// 0666 less the umask, as `open` would give it.
pub fn write(path: [:0]const u8, data: []const u8) !void {
    var tmp_buf: [c.PATH_MAX + 32]u8 = undefined;
    const dir = std.fs.path.dirname(path) orelse ".";
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}/.{s}.ze-XXXXXX", .{ dir, std.fs.path.basename(path) }, 0);
    const fd = mkstemp(tmp.ptr);
    if (fd < 0) return error.WriteFailed;
    errdefer _ = c.unlink(tmp.ptr);
    {
        defer _ = c.close(fd);
        var n: usize = 0;
        while (n < data.len) {
            const r = c.write(fd, data[n..].ptr, data.len - n);
            if (r <= 0) return error.WriteFailed;
            n += @intCast(r);
        }
        var st: c.Stat = undefined;
        const old = c.stat(path, &st) == 0;
        const mode: c.mode_t = if (old) st.mode & 0o7777 else 0o666 & ~currentUmask();
        if (old) _ = copyfile(path, tmp.ptr, null, copy_acl | copy_xattr);
        if (c.fchmod(fd, mode) != 0 or c.fsync(fd) != 0) return error.WriteFailed;
    }
    if (c.rename(tmp.ptr, path) != 0) return error.WriteFailed;
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

/// Absolute path for `path`, following symlinks so a save lands on the real
/// file. A file that doesn't exist yet is joined onto the current folder.
pub fn absolute(gpa: Allocator, path: []const u8) ![:0]u8 {
    if (path.len <= c.PATH_MAX) {
        var z: [c.PATH_MAX:0]u8 = undefined;
        var buf: [c.PATH_MAX]u8 = undefined;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        if (c.realpath(z[0..path.len :0], &buf)) |p| return gpa.dupeSentinel(u8, std.mem.span(p), 0);
    }
    if (path.len > 0 and path[0] == '/') return gpa.dupeSentinel(u8, path, 0);
    const here = cwd(gpa) orelse return error.NoCwd;
    defer gpa.free(here);
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ here, path }, 0);
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
    buf: [64]u8 = undefined,
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
