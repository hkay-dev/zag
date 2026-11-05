//! The settings file, `~/.config/ze/settings`: font, size, line height, soft
//! wrap, auto-closing pairs, the sidebar, light or dark, and the colors of both themes, as `key = value`
//! lines. ze writes every key into it the first time it's opened, and menu
//! toggles rewrite just their own line.
const std = @import("std");
const files = @import("files.zig");
const Allocator = std.mem.Allocator;

pub const Rgb = [3]f64;

pub const Theme = struct {
    bg: Rgb,
    fg: Rgb,
    muted: Rgb,
    /// Indexed by syntax.Kind; the first one is the text color.
    kinds: [7]Rgb,
    sel: Rgb,
    line: Rgb,
    caret: Rgb,
    match: Rgb,
    panel: Rgb,
    rule: Rgb,
};

fn rgb(comptime v: u24) Rgb {
    return .{ @as(f64, @floatFromInt(v >> 16)) / 255, @as(f64, @floatFromInt((v >> 8) & 0xff)) / 255, @as(f64, @floatFromInt(v & 0xff)) / 255 };
}

/// Warm paper in light mode.
pub const paper: Theme = .{
    .bg = rgb(0xF5F2EA),
    .fg = rgb(0x2E2C28),
    .muted = rgb(0x9A958A),
    .kinds = .{ rgb(0x2E2C28), rgb(0x9C3D26), rgb(0x4F7A3A), rgb(0xB3AEA3), rgb(0xA8642A), rgb(0x2F6587), rgb(0x7D4E86) },
    .sel = rgb(0xE3D9BF),
    .line = rgb(0xEFEADF),
    .caret = rgb(0xE8590C),
    .match = rgb(0xF2D98A),
    .panel = rgb(0xECE7DB),
    .rule = rgb(0xDDD6C7),
};

/// Ink in dark mode.
pub const ink: Theme = .{
    .bg = rgb(0x17171B),
    .fg = rgb(0xD9D4C7),
    .muted = rgb(0x6E6A61),
    .kinds = .{ rgb(0xD9D4C7), rgb(0xF08A6C), rgb(0xA7C080), rgb(0x5F5C56), rgb(0xE8B86B), rgb(0x8DB8D8), rgb(0xCFA3D8) },
    .sel = rgb(0x34343E),
    .line = rgb(0x1E1E24),
    .caret = rgb(0xFF8A3D),
    .match = rgb(0x5A4A24),
    .panel = rgb(0x202027),
    .rule = rgb(0x2A2A31),
};

/// Ayu Light, from the ayu theme family.
const ayu_light: Theme = .{
    .bg = rgb(0xF8F9FA),
    .fg = rgb(0x5C6166),
    .muted = rgb(0x8A9199),
    .kinds = .{ rgb(0x5C6166), rgb(0xFA8D3E), rgb(0x86B300), rgb(0xADAEB1), rgb(0xA37ACC), rgb(0xF2AE49), rgb(0x399EE6) },
    .sel = rgb(0xD3E1F4),
    .line = rgb(0xEDEFF0),
    .caret = rgb(0xFFAA33),
    .match = rgb(0xF5E1A8),
    .panel = rgb(0xF0F1F2),
    .rule = rgb(0xE6E8EA),
};

/// Ayu Dark.
const ayu_dark: Theme = .{
    .bg = rgb(0x0B0E14),
    .fg = rgb(0xBFBDB6),
    .muted = rgb(0x565B66),
    .kinds = .{ rgb(0xBFBDB6), rgb(0xFF8F40), rgb(0xAAD94C), rgb(0x646A72), rgb(0xD2A6FF), rgb(0xFFB454), rgb(0x59C2FF) },
    .sel = rgb(0x1B395A),
    .line = rgb(0x131721),
    .caret = rgb(0xE6B450),
    .match = rgb(0x4A3B1A),
    .panel = rgb(0x0F131A),
    .rule = rgb(0x1B1F29),
};

/// One Light, Atom's light theme.
const one_light: Theme = .{
    .bg = rgb(0xFAFAFA),
    .fg = rgb(0x383A42),
    .muted = rgb(0x9D9D9F),
    .kinds = .{ rgb(0x383A42), rgb(0xA626A4), rgb(0x50A14F), rgb(0xA0A1A7), rgb(0x986801), rgb(0x4078F2), rgb(0xC18401) },
    .sel = rgb(0xE5E5E6),
    .line = rgb(0xF0F0F1),
    .caret = rgb(0x526FFF),
    .match = rgb(0xF2E2A6),
    .panel = rgb(0xEFEFF0),
    .rule = rgb(0xDBDBDC),
};

/// One Dark, Atom's dark theme.
const one_dark: Theme = .{
    .bg = rgb(0x282C34),
    .fg = rgb(0xABB2BF),
    .muted = rgb(0x636D83),
    .kinds = .{ rgb(0xABB2BF), rgb(0xC678DD), rgb(0x98C379), rgb(0x5C6370), rgb(0xD19A66), rgb(0x61AFEF), rgb(0xE5C07B) },
    .sel = rgb(0x3E4451),
    .line = rgb(0x2C313C),
    .caret = rgb(0x528BFF),
    .match = rgb(0x314365),
    .panel = rgb(0x21252B),
    .rule = rgb(0x181A1F),
};

pub const Scheme = struct {
    /// How the settings file names it.
    key: []const u8,
    /// How the View menu names it.
    title: [:0]const u8,
    dark: bool,
    theme: Theme,
};

/// The built-in themes, light ones first. Either mode can use any of them.
pub const schemes = [_]Scheme{
    .{ .key = "paper", .title = "Paper", .dark = false, .theme = paper },
    .{ .key = "ayu-light", .title = "Ayu Light", .dark = false, .theme = ayu_light },
    .{ .key = "one-light", .title = "One Light", .dark = false, .theme = one_light },
    .{ .key = "ink", .title = "Ink", .dark = true, .theme = ink },
    .{ .key = "ayu-dark", .title = "Ayu Dark", .dark = true, .theme = ayu_dark },
    .{ .key = "one-dark", .title = "One Dark", .dark = true, .theme = one_dark },
};

fn schemeIndex(key: []const u8) ?u8 {
    for (schemes, 0..) |sc, i| if (std.mem.eql(u8, sc.key, key)) return @intCast(i);
    return null;
}

pub const default_size = 14.0;

/// Light or dark: `auto` follows the Mac.
pub const Look = enum { auto, light, dark };

/// The sidebar's width in points: where it starts, and how far the edge drags.
pub const sidebar_default = 250.0;
pub const sidebar_min = 150.0;
pub const sidebar_max = 500.0;

pub const Settings = struct {
    font_buf: [128]u8 = undefined,
    font_len: usize = 0,
    size: f64 = default_size,
    /// Line height as a multiple of the size.
    spacing: f64 = 1.75,
    wrap: bool = false,
    pairs: bool = true,
    /// The folder tree on the left of folder windows.
    sidebar: bool = true,
    sidebar_width: f64 = sidebar_default,
    look: Look = .auto,
    /// Indexes into `schemes`: the theme for light mode and for dark mode.
    light_scheme: u8 = 0,
    dark_scheme: u8 = 3,
    /// The chosen themes with the file's single-color lines on top.
    light: Theme = paper,
    dark: Theme = ink,

    /// A PostScript font name, or "" for the system's monospaced font.
    pub fn font(s: *const Settings) []const u8 {
        return s.font_buf[0..s.font_len];
    }

    pub fn setFont(s: *Settings, name: []const u8) void {
        const n = if (std.mem.eql(u8, name, "system")) "" else name;
        s.font_len = @min(n.len, s.font_buf.len);
        @memcpy(s.font_buf[0..s.font_len], n[0..s.font_len]);
    }
};

const colors = [_][]const u8{ "background", "text", "muted", "keyword", "string", "comment", "number", "function", "type", "selection", "line", "caret", "match", "panel", "rule" };

fn slot(th: *Theme, name: []const u8) ?*Rgb {
    const i = for (colors, 0..) |c, j| {
        if (std.mem.eql(u8, c, name)) break j;
    } else return null;
    return switch (i) {
        0 => &th.bg,
        1 => &th.fg,
        2 => &th.muted,
        3...8 => &th.kinds[i - 2],
        9 => &th.sel,
        10 => &th.line,
        11 => &th.caret,
        12 => &th.match,
        13 => &th.panel,
        else => &th.rule,
    };
}

fn parseHex(s: []const u8) ?Rgb {
    const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (h.len != 6) return null;
    const v = std.fmt.parseInt(u24, h, 16) catch return null;
    return .{ @as(f64, @floatFromInt(v >> 16)) / 255, @as(f64, @floatFromInt((v >> 8) & 0xff)) / 255, @as(f64, @floatFromInt(v & 0xff)) / 255 };
}

fn flag(s: []const u8) ?bool {
    for ([_][]const u8{ "on", "true", "yes" }) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    for ([_][]const u8{ "off", "false", "no" }) |w| if (std.ascii.eqlIgnoreCase(s, w)) return false;
    return null;
}

/// A plain decimal like 14 or 1.75. std's float parser and printer would
/// add about 16 KB to ze, and settings only need these.
fn number(s: []const u8) ?f64 {
    var v: f64 = 0;
    var scale: f64 = 0;
    if (s.len == 0) return null;
    for (s) |c| {
        if (c == '.' and scale == 0) {
            scale = 1;
        } else if (std.ascii.isDigit(c)) {
            v = v * 10 + @as(f64, @floatFromInt(c - '0'));
            if (scale > 0) scale *= 10;
        } else return null;
    }
    return if (scale > 0) v / scale else v;
}

/// `v` with up to two decimals, trailing zeros dropped.
pub fn decimal(buf: *[24]u8, v: f64) []const u8 {
    const hundredths: u64 = @intFromFloat(@round(@max(v, 0) * 100));
    const whole = hundredths / 100;
    const frac = hundredths % 100;
    if (frac == 0) return std.fmt.bufPrint(buf, "{d}", .{whole}) catch "";
    if (frac % 10 == 0) return std.fmt.bufPrint(buf, "{d}.{d}", .{ whole, frac / 10 }) catch "";
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ whole, frac }) catch "";
}

const Entry = struct { key: []const u8, val: []const u8 };

/// The next `key = value` line, skipping blanks, comments and nonsense.
fn nextEntry(it: *std.mem.SplitIterator(u8, .scalar)) ?Entry {
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        return .{ .key = std.mem.trim(u8, line[0..eq], " \t"), .val = std.mem.trim(u8, line[eq + 1 ..], " \t") };
    }
    return null;
}

/// Reads settings text. Lines it doesn't understand keep their defaults.
/// Single colors apply on top of the chosen themes wherever they sit.
pub fn parse(text: []const u8) Settings {
    var s: Settings = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (nextEntry(&it)) |e| {
        if (std.mem.eql(u8, e.key, "light-theme")) {
            s.light_scheme = schemeIndex(e.val) orelse s.light_scheme;
        } else if (std.mem.eql(u8, e.key, "dark-theme")) {
            s.dark_scheme = schemeIndex(e.val) orelse s.dark_scheme;
        }
    }
    s.light = schemes[s.light_scheme].theme;
    s.dark = schemes[s.dark_scheme].theme;
    it.reset();
    while (nextEntry(&it)) |e| {
        const key = e.key;
        const val = e.val;
        if (std.mem.eql(u8, key, "font")) {
            s.setFont(val);
        } else if (std.mem.eql(u8, key, "size")) {
            s.size = std.math.clamp(number(val) orelse s.size, 8, 40);
        } else if (std.mem.eql(u8, key, "line-height")) {
            s.spacing = std.math.clamp(number(val) orelse s.spacing, 1, 3);
        } else if (std.mem.eql(u8, key, "wrap")) {
            s.wrap = flag(val) orelse s.wrap;
        } else if (std.mem.eql(u8, key, "pairs")) {
            s.pairs = flag(val) orelse s.pairs;
        } else if (std.mem.eql(u8, key, "sidebar")) {
            s.sidebar = flag(val) orelse s.sidebar;
        } else if (std.mem.eql(u8, key, "sidebar-width")) {
            s.sidebar_width = std.math.clamp(number(val) orelse s.sidebar_width, sidebar_min, sidebar_max);
        } else if (std.mem.eql(u8, key, "appearance")) {
            s.look = std.meta.stringToEnum(Look, val) orelse s.look;
        } else {
            const dot = std.mem.indexOfScalar(u8, key, '.') orelse continue;
            const theme = if (std.mem.eql(u8, key[0..dot], "light")) &s.light else if (std.mem.eql(u8, key[0..dot], "dark")) &s.dark else continue;
            const c = parseHex(val) orelse continue;
            const p = slot(theme, key[dot + 1 ..]) orelse continue;
            p.* = c;
            if (p == &theme.fg) theme.kinds[0] = c;
        }
    }
    return s;
}

/// The whole file for `s`, with a comment on each group. Colors are written
/// only where they differ from the chosen theme.
pub fn render(gpa: Allocator, s: *const Settings) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    var wbuf: [24]u8 = undefined;
    try out.print(gpa,
        \\# ze settings. Save this file and every window picks up the change.
        \\
        \\# A font's PostScript name, like Menlo-Regular, or system for SF Mono.
        \\font = {s}
        \\size = {s}
        \\# Line height, as a multiple of the size.
        \\line-height = {s}
        \\# Wrap long lines at the window's edge: on or off.
        \\wrap = {s}
        \\# Close brackets and quotes as you type them: on or off.
        \\pairs = {s}
        \\# Show the folder's files on the left of the window: on or off.
        \\sidebar = {s}
        \\# How wide the sidebar is, in points: drag its edge to change it.
        \\sidebar-width = {s}
        \\
        \\# Light or dark: auto follows the Mac, light or dark keeps ze in that mode.
        \\appearance = {s}
        \\# The theme for each mode: paper, ayu-light, one-light,
        \\# ink, ayu-dark or one-dark.
        \\light-theme = {s}
        \\dark-theme = {s}
        \\
        \\# Change one color of a theme with a line like light.keyword = #9C3D26.
        \\# The names are background, text, muted, keyword, string, comment,
        \\# number, function, type, selection, line, caret, match, panel and rule.
        \\
    , .{
        if (s.font_len == 0) "system" else s.font(),
        decimal(&a, s.size),
        decimal(&b, s.spacing),
        if (s.wrap) "on" else "off",
        if (s.pairs) "on" else "off",
        if (s.sidebar) "on" else "off",
        decimal(&wbuf, s.sidebar_width),
        @tagName(s.look),
        schemes[s.light_scheme].key,
        schemes[s.dark_scheme].key,
    });
    for ([_][]const u8{ "light", "dark" }, 0..) |name, n| {
        var th = if (n == 0) s.light else s.dark;
        var base = schemes[if (n == 0) s.light_scheme else s.dark_scheme].theme;
        for (colors) |c| {
            const v = slot(&th, c).?.*;
            if (std.mem.eql(f64, &v, &slot(&base, c).?.*)) continue;
            try out.print(gpa, "{s}.{s} = #{X:0>2}{X:0>2}{X:0>2}\n", .{ name, c, byte(v[0]), byte(v[1]), byte(v[2]) });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn byte(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// `text` with the `key` line set to `value`, added at the end when missing.
pub fn setLine(gpa: Allocator, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var done = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=');
        if (!done and line.len > 0 and line[0] != '#' and eq != null and std.mem.eql(u8, std.mem.trim(u8, line[0..eq.?], " \t"), key)) {
            try out.print(gpa, "{s} = {s}", .{ key, value });
            done = true;
        } else try out.appendSlice(gpa, raw);
    }
    if (!done) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
        try out.print(gpa, "{s} = {s}\n", .{ key, value });
    }
    return out.toOwnedSlice(gpa);
}

/// `~/.config/ze/settings`. Owned by gpa.
pub fn path(gpa: Allocator) ![:0]u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHome);
    return std.fmt.allocPrintSentinel(gpa, "{s}/.config/ze/settings", .{home}, 0);
}

/// Reads the file at `p`; a missing or unreadable file gives the defaults.
pub fn load(gpa: Allocator, p: [:0]const u8) Settings {
    const text = files.read(gpa, p) catch return .{};
    defer gpa.free(text);
    return parse(text);
}

/// Makes sure the file exists, writing every key from `s` when it doesn't.
pub fn ensure(gpa: Allocator, p: [:0]const u8, s: *const Settings) !void {
    if (files.exists(p)) return;
    try files.makeParent(p);
    const text = try render(gpa, s);
    defer gpa.free(text);
    try files.write(p, text);
}

/// Rewrites one line of the file, creating the file from `s` first if needed.
pub fn store(gpa: Allocator, p: [:0]const u8, s: *const Settings, key: []const u8, value: []const u8) !void {
    try ensure(gpa, p, s);
    const text = try files.read(gpa, p);
    defer gpa.free(text);
    const next = try setLine(gpa, text, key, value);
    defer gpa.free(next);
    try files.write(p, next);
}

const t = std.testing;

test "settings read colors, flags and numbers and skip what they don't know" {
    const s = parse(
        \\# comment
        \\font = Menlo-Regular
        \\size = 99
        \\wrap = on
        \\pairs = off
        \\sidebar-width = 900
        \\light.comment = #102030
        \\dark.text = 0A0B0C
        \\dark.bogus = #FFFFFF
        \\nonsense line
    );
    try t.expectEqualStrings("Menlo-Regular", s.font());
    try t.expectEqual(@as(f64, 40), s.size);
    try t.expect(s.wrap and !s.pairs);
    try t.expectEqual(sidebar_max, s.sidebar_width);
    try t.expectEqual(@as(f64, 0x10) / 255, s.light.kinds[3][0]);
    try t.expectEqual(@as(f64, 0x0C) / 255, s.dark.fg[2]);
    try t.expectEqual(s.dark.fg, s.dark.kinds[0]);
    try t.expectEqual(ink.bg, s.dark.bg);
}

test "a written file reads back as the same settings" {
    var s: Settings = .{ .size = 16, .wrap = true, .look = .dark, .sidebar_width = 320 };
    s.setFont("Menlo-Regular");
    s.dark.caret = .{ 1, 0, 0 };
    const text = try render(t.allocator, &s);
    defer t.allocator.free(text);
    const back = parse(text);
    try t.expectEqualStrings("Menlo-Regular", back.font());
    try t.expectEqual(s.size, back.size);
    try t.expect(back.wrap);
    try t.expectEqual(@as(f64, 320), back.sidebar_width);
    try t.expectEqual(Look.dark, back.look);
    try t.expectEqual(s.dark.caret, back.dark.caret);
    try t.expectEqual(s.light, back.light);
}

test "setting a key rewrites only its line, or adds it" {
    const a = try setLine(t.allocator, "# size = 1\nsize = 14\nwrap = off\n", "size", "16");
    defer t.allocator.free(a);
    try t.expectEqualStrings("# size = 1\nsize = 16\nwrap = off\n", a);
    const b = try setLine(t.allocator, "wrap = off", "pairs", "on");
    defer t.allocator.free(b);
    try t.expectEqualStrings("wrap = off\npairs = on\n", b);
}

test "a single color applies on top of the chosen theme wherever its line sits" {
    const s = parse(
        \\dark.keyword = #010203
        \\dark-theme = one-dark
        \\light-theme = nonsense
    );
    try t.expectEqual(paper, s.light);
    try t.expectEqual(one_dark.bg, s.dark.bg);
    try t.expectEqual(@as(f64, 3) / 255, s.dark.kinds[1][2]);
    const text = try render(t.allocator, &s);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "dark-theme = one-dark\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "dark.background") == null);
    try t.expectEqual(s.dark, parse(text).dark);
}
