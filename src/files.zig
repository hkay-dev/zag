//! Reading and saving files straight through libc, which keeps std.Io (and
//! its size) out of the binary.
const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;

extern "c" fn mkstemp(template: [*:0]u8) c_int;

pub const max_size = 1 << 30;

/// The whole file. error.FileNotFound when it doesn't exist yet.
pub fn read(gpa: Allocator, path: [:0]const u8) ![]u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return if (c._errno().* == @intFromEnum(c.E.NOENT)) error.FileNotFound else error.ReadFailed;
    defer _ = c.close(fd);
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.ReadFailed;
    if (st.size > max_size) return error.FileTooBig;
    const buf = try gpa.alloc(u8, @intCast(st.size));
    errdefer gpa.free(buf);
    var n: usize = 0;
    while (n < buf.len) {
        const r = c.read(fd, buf[n..].ptr, buf.len - n);
        if (r <= 0) return error.ReadFailed;
        n += @intCast(r);
    }
    return buf;
}

/// Writes a temp file beside `path`, syncs it, then renames it over `path`,
/// so a crash mid-save leaves the old file whole. Keeps the file's mode.
pub fn write(path: [:0]const u8, data: []const u8) !void {
    var tmp_buf: [c.PATH_MAX + 16]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}.ze-XXXXXX", .{path}, 0);
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
        const mode: c.mode_t = if (c.stat(path, &st) == 0) st.mode & 0o7777 else 0o644;
        if (c.fchmod(fd, mode) != 0 or c.fsync(fd) != 0) return error.WriteFailed;
    }
    if (c.rename(tmp.ptr, path) != 0) return error.WriteFailed;
}

/// Absolute path for `path`, following symlinks so a save lands on the real
/// file. A file that doesn't exist yet is joined onto the current folder.
pub fn absolute(gpa: Allocator, path: []const u8) ![:0]u8 {
    var buf: [c.PATH_MAX]u8 = undefined;
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    if (c.realpath(z, &buf)) |p| return gpa.dupeSentinel(u8, std.mem.span(p), 0);
    if (path.len > 0 and path[0] == '/') return gpa.dupeSentinel(u8, path, 0);
    const here = c.getcwd(&buf, buf.len) orelse return error.NoCwd;
    return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ std.mem.span(@as([*:0]u8, @ptrCast(here))), path }, 0);
}

pub fn isDir(path: [:0]const u8) bool {
    var st: c.Stat = undefined;
    return c.stat(path, &st) == 0 and st.mode & c.S.IFMT == c.S.IFDIR;
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
    while (c.readdir(d)) |e| n += @intFromBool(e.name[0] != '.');
    return n;
}

test "save replaces the text, keeps the file's mode and leaves no temp file" {
    var tmpl = "/tmp/ze-test-XXXXXX".*;
    const dir = std.mem.span(mkdtemp(&tmpl).?);
    defer _ = c.rmdir(dir);
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/run.sh", .{dir}, 0);
    defer _ = c.unlink(path);

    try t.expectError(error.FileNotFound, read(t.allocator, path));
    try write(path, "old");
    try t.expectEqual(@as(c.mode_t, 0o644), modeOf(path));
    _ = c.chmod(path, 0o755);
    try write(path, "new text");

    const got = try read(t.allocator, path);
    defer t.allocator.free(got);
    try t.expectEqualStrings("new text", got);
    try t.expectEqual(@as(c.mode_t, 0o755), modeOf(path));
    try t.expectEqual(@as(usize, 1), entries(dir));
}

fn modeOf(path: [:0]const u8) c.mode_t {
    var st: c.Stat = undefined;
    _ = c.stat(path, &st);
    return st.mode & 0o777;
}
