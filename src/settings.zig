//! The settings file, `~/.config/zag/config.toml`: font, size, line height, soft
//! wrap, auto-closing pairs, zen mode, the sidebar, light or dark, and the colors of both themes, as TOML
//! `key = value` lines. Zag adds every missing key at launch, menu toggles
//! rewrite just their own line, and the older `~/.config/ze/settings` is read
//! once to start the file and never written.
const std = @import("std");
const files = @import("files.zig");
const Allocator = std.mem.Allocator;

pub const Rgb = [3]f64;

/// A theme's colors, as `Rgb` at run time and as bytes in the built-in schemes.
fn ThemeOf(comptime C: type) type {
    return extern struct {
        bg: C,
        fg: C,
        muted: C,
        /// Indexed by syntax.Kind; the first one is the text color.
        kinds: [7]C,
        sel: C,
        line: C,
        caret: C,
        match: C,
        panel: C,
        rule: C,
        /// The card's header: a step lighter than the text's background on dark
        /// themes and a step darker on light ones.
        header: C,
    };
}

pub const Theme = ThemeOf(Rgb);
const Bytes = ThemeOf([3]u8);

fn rgb(comptime v: u24) [3]u8 {
    return .{ @intCast(v >> 16), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) };
}

fn wide(c: [3]u8) Rgb {
    return .{ @as(f64, @floatFromInt(c[0])) / 255, @as(f64, @floatFromInt(c[1])) / 255, @as(f64, @floatFromInt(c[2])) / 255 };
}

/// A built-in scheme's bytes as the `Rgb` theme that draws.
fn widen(b: Bytes) Theme {
    const from: *const [@sizeOf(Bytes) / 3][3]u8 = @ptrCast(&b);
    var th: Theme = undefined;
    const to: *[from.len]Rgb = @ptrCast(&th);
    for (to, from) |*o, c| o.* = wide(c);
    return th;
}

/// Warm paper in light mode.
const paper_c: Bytes = .{
    .bg = rgb(0xF5F2EA),
    .fg = rgb(0x2E2C28),
    .muted = rgb(0x736E64),
    .kinds = .{ rgb(0x2E2C28), rgb(0x9C3D26), rgb(0x4F7A3A), rgb(0x8A857A), rgb(0xA8642A), rgb(0x2F6587), rgb(0x7D4E86) },
    .sel = rgb(0xF1C7AC),
    .line = rgb(0xEFEADF),
    .caret = rgb(0xE8590C),
    .match = rgb(0xF2D98A),
    .panel = rgb(0xECE7DB),
    .rule = rgb(0xD6CDB9),
    .header = rgb(0xE3DBCA),
};

/// Ink in dark mode.
const ink_c: Bytes = .{
    .bg = rgb(0x17171B),
    .fg = rgb(0xD9D4C7),
    .muted = rgb(0x8A857B),
    .kinds = .{ rgb(0xD9D4C7), rgb(0xF08A6C), rgb(0xA7C080), rgb(0x7A766E), rgb(0xE8B86B), rgb(0x8DB8D8), rgb(0xCFA3D8) },
    .sel = rgb(0x5E3B26),
    .line = rgb(0x1E1E24),
    .caret = rgb(0xFF8A3D),
    .match = rgb(0x5A4A24),
    .panel = rgb(0x202027),
    .rule = rgb(0x2A2A31),
    .header = rgb(0x212128),
};

/// Ayu Light, from the ayu theme family.
const ayu_light: Bytes = .{
    .bg = rgb(0xF8F9FA),
    .fg = rgb(0x5C6166),
    .muted = rgb(0x6D7379),
    .kinds = .{ rgb(0x5C6166), rgb(0xFA8D3E), rgb(0x86B300), rgb(0x8A8D91), rgb(0xA37ACC), rgb(0xF2AE49), rgb(0x399EE6) },
    .sel = rgb(0xC2D6F2),
    .line = rgb(0xEDEFF0),
    .caret = rgb(0xFFAA33),
    .match = rgb(0xF5E1A8),
    .panel = rgb(0xF0F1F2),
    .rule = rgb(0xD6DADF),
    .header = rgb(0xE4E7EB),
};

/// Ayu Dark.
const ayu_dark: Bytes = .{
    .bg = rgb(0x0B0E14),
    .fg = rgb(0xBFBDB6),
    .muted = rgb(0x7C7F85),
    .kinds = .{ rgb(0xBFBDB6), rgb(0xFF8F40), rgb(0xAAD94C), rgb(0x646A72), rgb(0xD2A6FF), rgb(0xFFB454), rgb(0x59C2FF) },
    .sel = rgb(0x1F4470),
    .line = rgb(0x131721),
    .caret = rgb(0xE6B450),
    .match = rgb(0x4A3B1A),
    .panel = rgb(0x0F131A),
    .rule = rgb(0x1B1F29),
    .header = rgb(0x151A23),
};

/// One Light, Atom's light theme.
const one_light: Bytes = .{
    .bg = rgb(0xFAFAFA),
    .fg = rgb(0x383A42),
    .muted = rgb(0x727277),
    .kinds = .{ rgb(0x383A42), rgb(0xA626A4), rgb(0x50A14F), rgb(0x8A8B92), rgb(0x986801), rgb(0x4078F2), rgb(0xC18401) },
    .sel = rgb(0xD8DEFB),
    .line = rgb(0xF0F0F1),
    .caret = rgb(0x526FFF),
    .match = rgb(0xF2E2A6),
    .panel = rgb(0xEFEFF0),
    .rule = rgb(0xD5D5D8),
    .header = rgb(0xE6E6E9),
};

/// One Dark, Atom's dark theme.
const one_dark: Bytes = .{
    .bg = rgb(0x282C34),
    .fg = rgb(0xABB2BF),
    .muted = rgb(0x8B93A4),
    .kinds = .{ rgb(0xABB2BF), rgb(0xC678DD), rgb(0x98C379), rgb(0x6F7683), rgb(0xD19A66), rgb(0x61AFEF), rgb(0xE5C07B) },
    .sel = rgb(0x354871),
    .line = rgb(0x2C313C),
    .caret = rgb(0x528BFF),
    .match = rgb(0x314365),
    .panel = rgb(0x21252B),
    .rule = rgb(0x181A1F),
    .header = rgb(0x31363F),
};

/// Black for OLED screens: pure black with off-white text a step softer than
/// Ink's, since black raises the contrast, and Ink's hues pulled a tenth
/// toward black to sit with it.
const black_c: Bytes = .{
    .bg = rgb(0x000000),
    .fg = rgb(0xCBC6BA),
    .muted = rgb(0x7B776F),
    .kinds = .{ rgb(0xCBC6BA), rgb(0xD87C61), rgb(0x96AD73), rgb(0x6F6B63), rgb(0xD1A660), rgb(0x7FA6C2), rgb(0xBA93C2) },
    .sel = rgb(0x3A2416),
    .line = rgb(0x0A0A0B),
    .caret = rgb(0xE67A33),
    .match = rgb(0x3A3018),
    .panel = rgb(0x101012),
    .rule = rgb(0x1C1C20),
    .header = rgb(0x111113),
};

pub const paper = widen(paper_c);
pub const ink = widen(ink_c);
pub const black = widen(black_c);

pub const Scheme = struct {
    /// How the settings file names it.
    key: []const u8,
    /// How the View menu names it.
    title: [:0]const u8,
    dark: bool,
    colors: Bytes,
};

/// The built-in themes, light ones first. Either mode can use any of them.
pub const schemes = [_]Scheme{
    .{ .key = "paper", .title = "Paper", .dark = false, .colors = paper_c },
    .{ .key = "ayu-light", .title = "Ayu Light", .dark = false, .colors = ayu_light },
    .{ .key = "one-light", .title = "One Light", .dark = false, .colors = one_light },
    .{ .key = "ink", .title = "Ink", .dark = true, .colors = ink_c },
    .{ .key = "ayu-dark", .title = "Ayu Dark", .dark = true, .colors = ayu_dark },
    .{ .key = "one-dark", .title = "One Dark", .dark = true, .colors = one_dark },
    .{ .key = "black", .title = "Black", .dark = true, .colors = black_c },
};

fn schemeIndex(key: []const u8) ?u8 {
    for (schemes, 0..) |sc, i| if (std.mem.eql(u8, sc.key, key)) return @intCast(i);
    return null;
}

pub const default_size = 14.0;

/// Light or dark: `auto` follows the Mac.
pub const Look = enum { auto, light, dark };
pub const Focus = enum { off, line, sentence, paragraph };

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
    focus: Focus = .off,
    typewriter: bool = false,
    /// A column of line numbers beside the text.
    line_numbers: bool = true,
    /// Hides the window's chrome and centers an 80-column grey page.
    zen: bool = false,
    /// Late-Night Focus. The window applies `lateNight` to a copy of the
    /// fields around it, so the file keeps what the user chose.
    late_night: bool = false,
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

    /// Zen, typewriter, paragraph focus, a dark look and the Black theme, whatever else was chosen.
    pub fn lateNight(s: *Settings) void {
        const i = schemeIndex("black").?;
        s.zen = true;
        s.typewriter = true;
        s.focus = .paragraph;
        s.look = .dark;
        s.light_scheme = i;
        s.dark_scheme = i;
        s.dark = widen(schemes[i].colors);
    }
};

const colors = [_][]const u8{ "background", "text", "muted", "keyword", "string", "comment", "number", "function", "type", "selection", "line", "caret", "match", "panel", "rule", "header" };

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
        14 => &th.rule,
        else => &th.header,
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
/// add about 16 KB to Zag, and settings only need these.
pub fn number(s: []const u8) ?f64 {
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

/// The next `key = value` line, skipping blanks, comments and nonsense. The
/// value loses one pair of quotes, or else a trailing ` # comment`.
fn nextEntry(it: *std.mem.SplitIterator(u8, .scalar)) ?Entry {
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len > 0 and (val[0] == '"' or val[0] == '\'')) {
            val = if (std.mem.indexOfScalarPos(u8, val, 1, val[0])) |end| val[1..end] else val[1..];
        } else {
            for (val, 0..) |ch, i| if (ch == '#' and i > 0 and (val[i - 1] == ' ' or val[i - 1] == '\t')) {
                val = std.mem.trimEnd(u8, val[0..i], " \t");
                break;
            };
        }
        return .{ .key = std.mem.trim(u8, line[0..eq], " \t"), .val = val };
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
    s.light = widen(schemes[s.light_scheme].colors);
    s.dark = widen(schemes[s.dark_scheme].colors);
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
        } else if (std.mem.eql(u8, key, "focus")) {
            s.focus = std.meta.stringToEnum(Focus, val) orelse s.focus;
        } else if (std.mem.eql(u8, key, "typewriter")) {
            s.typewriter = flag(val) orelse s.typewriter;
        } else if (std.mem.eql(u8, key, "line-numbers")) {
            s.line_numbers = flag(val) orelse s.line_numbers;
        } else if (std.mem.eql(u8, key, "zen")) {
            s.zen = flag(val) orelse s.zen;
        } else if (std.mem.eql(u8, key, "late-night")) {
            s.late_night = flag(val) orelse s.late_night;
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

const Opt = enum { font, size, @"line-height", wrap, pairs, focus, typewriter, @"line-numbers", zen, @"late-night", sidebar, @"sidebar-width", appearance, @"light-theme", @"dark-theme" };
const Kind = enum { string, flag, number };

/// One line of the file: its comment above it, and a blank line before the
/// comment when `gap`. `render` and the launch-time fill-in share this list.
const Row = struct { opt: Opt, kind: Kind, gap: bool = false, note: []const u8 };

const options = [_]Row{
    .{ .opt = .font, .kind = .string, .note = "# A font's PostScript name, like Menlo-Regular, or system for SF Mono.\n" },
    .{ .opt = .size, .kind = .number, .note = "" },
    .{ .opt = .@"line-height", .kind = .number, .note = "# Line height, as a multiple of the size.\n" },
    .{ .opt = .wrap, .kind = .flag, .note = "# Wrap long lines at the window's edge: true or false.\n" },
    .{ .opt = .pairs, .kind = .flag, .note = "# Close brackets and quotes as you type them: true or false.\n" },
    .{ .opt = .focus, .kind = .string, .note = "# Fade text outside the caret's range: off, line, sentence or paragraph.\n" },
    .{ .opt = .typewriter, .kind = .flag, .note = "# Keep the caret's row in the middle as you type: true or false.\n" },
    .{ .opt = .@"line-numbers", .kind = .flag, .note = "# Number the lines beside the text: true or false.\n" },
    .{ .opt = .zen, .kind = .flag, .note = "# Hide the window's chrome and center an 80-column grey page: true or false.\n" },
    .{ .opt = .@"late-night", .kind = .flag, .note = "# Late-Night Focus: zen, typewriter, paragraph focus and Black on top of the above: true or false.\n" },
    .{ .opt = .sidebar, .kind = .flag, .note = "# Show the folder's files on the left of the window: true or false.\n" },
    .{ .opt = .@"sidebar-width", .kind = .number, .note = "# How wide the sidebar is, in points: drag its edge to change it.\n" },
    .{ .opt = .appearance, .kind = .string, .gap = true, .note = "# Light or dark: auto follows the Mac, light or dark keeps Zag in that mode.\n" },
    .{ .opt = .@"light-theme", .kind = .string, .note = "# The theme for each mode: paper, ayu-light, one-light,\n# ink, ayu-dark, one-dark or black.\n" },
    .{ .opt = .@"dark-theme", .kind = .string, .note = "" },
};

fn kindOf(key: []const u8) Kind {
    for (options) |row| if (std.mem.eql(u8, key, @tagName(row.opt))) return row.kind;
    return .string;
}

fn flagText(v: bool) []const u8 {
    return if (v) "true" else "false";
}

/// What `s` holds for `opt`, as the file writes it (before any quotes).
fn valueText(s: *const Settings, opt: Opt, buf: *[24]u8) []const u8 {
    return switch (opt) {
        .font => if (s.font_len == 0) "system" else s.font(),
        .size => decimal(buf, s.size),
        .@"line-height" => decimal(buf, s.spacing),
        .wrap => flagText(s.wrap),
        .pairs => flagText(s.pairs),
        .focus => @tagName(s.focus),
        .typewriter => flagText(s.typewriter),
        .@"line-numbers" => flagText(s.line_numbers),
        .zen => flagText(s.zen),
        .@"late-night" => flagText(s.late_night),
        .sidebar => flagText(s.sidebar),
        .@"sidebar-width" => decimal(buf, s.sidebar_width),
        .appearance => @tagName(s.look),
        .@"light-theme" => schemes[s.light_scheme].key,
        .@"dark-theme" => schemes[s.dark_scheme].key,
    };
}

fn writeOption(gpa: Allocator, out: *std.ArrayList(u8), s: *const Settings, row: Row) !void {
    var buf: [24]u8 = undefined;
    if (row.gap) try out.append(gpa, '\n');
    try out.appendSlice(gpa, row.note);
    const q: []const u8 = if (row.kind == .string) "\"" else "";
    try out.print(gpa, "{s} = {s}{s}{s}\n", .{ @tagName(row.opt), q, valueText(s, row.opt, &buf), q });
}

/// The whole file for `s`, in TOML, with a comment on each group. Colors are
/// written only where they differ from the chosen theme.
pub fn render(gpa: Allocator, s: *const Settings) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "# Zag settings. Save this file and every window picks up the change.\n\n");
    for (options) |row| try writeOption(gpa, &out, s, row);
    try out.appendSlice(gpa,
        \\
        \\# Change one color of a theme with a line like light.keyword = "#9C3D26".
        \\# The names are background, text, muted, keyword, string, comment,
        \\# number, function, type, selection, line, caret, match, panel, rule
        \\# and header.
        \\
    );
    for ([_][]const u8{ "light", "dark" }, 0..) |name, n| {
        var th = if (n == 0) s.light else s.dark;
        var base = widen(schemes[if (n == 0) s.light_scheme else s.dark_scheme].colors);
        for (colors) |c| {
            const v = slot(&th, c).?.*;
            if (std.mem.eql(f64, &v, &slot(&base, c).?.*)) continue;
            try out.print(gpa, "{s}.{s} = \"#{X:0>2}{X:0>2}{X:0>2}\"\n", .{ name, c, byte(v[0]), byte(v[1]), byte(v[2]) });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn byte(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// `text` with the `key` line set to `value`, added at the end when missing.
/// Flags (`true`, `false`) and numbers are written bare, everything else quoted.
pub fn setLine(gpa: Allocator, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const quote: []const u8 = if (kindOf(key) == .string) "\"" else "";
    var done = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=');
        if (!done and line.len > 0 and line[0] != '#' and eq != null and std.mem.eql(u8, std.mem.trim(u8, line[0..eq.?], " \t"), key)) {
            try out.print(gpa, "{s} = {s}{s}{s}", .{ key, quote, value, quote });
            done = true;
        } else try out.appendSlice(gpa, raw);
    }
    if (!done) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
        try out.print(gpa, "{s} = {s}{s}{s}\n", .{ key, quote, value, quote });
    }
    return out.toOwnedSlice(gpa);
}

/// `text` with every option it lacks added at the end, each under its
/// comment, with the value `parse` gives it. Null when none is missing.
fn withMissing(gpa: Allocator, text: []const u8) !?[]u8 {
    const s = parse(text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out.append(gpa, '\n');
    const base = out.items.len;
    for (options) |row| {
        var it = std.mem.splitScalar(u8, text, '\n');
        const present = while (nextEntry(&it)) |e| {
            if (std.mem.eql(u8, e.key, @tagName(row.opt))) break true;
        } else false;
        if (!present) try writeOption(gpa, &out, &s, row);
    }
    if (out.items.len == base) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

/// `~/.config/zag/config.toml`. Owned by gpa.
pub fn path(gpa: Allocator) ![:0]u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHome);
    return std.fmt.allocPrintSentinel(gpa, "{s}/.config/zag/config.toml", .{home}, 0);
}

/// The file older Zags used, `~/.config/ze/settings`. It is read once to
/// start the new file and never written. Owned by gpa.
fn oldPath(gpa: Allocator) ![:0]u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHome);
    return std.fmt.allocPrintSentinel(gpa, "{s}/.config/ze/settings", .{home}, 0);
}

/// Reads the file at `p`; a missing or unreadable file gives the defaults.
pub fn load(gpa: Allocator, p: [:0]const u8) Settings {
    const text = files.read(gpa, p) catch return .{};
    defer gpa.free(text);
    return parse(text);
}

/// Makes sure the file exists. It starts from the old settings file when
/// there is one (an old file that can't be read stops the write, so the new
/// file never starts from defaults over it), else from `s`.
pub fn ensure(gpa: Allocator, p: [:0]const u8, s: *const Settings) !void {
    if (files.exists(p)) return;
    try files.makeParent(p);
    const old = try oldPath(gpa);
    defer gpa.free(old);
    var from = s.*;
    if (files.exists(old)) {
        const old_text = try files.read(gpa, old);
        defer gpa.free(old_text);
        from = parse(old_text);
    }
    const text = try render(gpa, &from);
    defer gpa.free(text);
    try files.write(p, text);
}

/// At launch: creates the file (from the old one if it exists) and adds the
/// options it lacks. Existing lines and comments stay as they are; a file
/// that can't be read is left alone.
pub fn prepare(gpa: Allocator, p: [:0]const u8) void {
    ensure(gpa, p, &.{}) catch return;
    const text = files.read(gpa, p) catch return;
    defer gpa.free(text);
    const next = (withMissing(gpa, text) catch return) orelse return;
    defer gpa.free(next);
    files.write(p, next) catch {};
}

/// Rewrites one line of the file, creating it as `ensure` does first if needed.
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
    var s: Settings = .{ .size = 16, .wrap = true, .focus = .sentence, .typewriter = true, .zen = true, .look = .dark, .sidebar_width = 320 };
    s.setFont("Menlo-Regular");
    s.dark.caret = .{ 1, 0, 0 };
    const text = try render(t.allocator, &s);
    defer t.allocator.free(text);
    const back = parse(text);
    try t.expectEqualStrings("Menlo-Regular", back.font());
    try t.expectEqual(s.size, back.size);
    try t.expect(back.wrap);
    try t.expectEqual(s.focus, back.focus);
    try t.expectEqual(s.typewriter, back.typewriter);
    try t.expect(back.line_numbers);
    try t.expect(back.zen);
    try t.expectEqual(@as(f64, 320), back.sidebar_width);
    try t.expectEqual(Look.dark, back.look);
    try t.expectEqual(s.dark.caret, back.dark.caret);
    try t.expectEqual(s.light, back.light);
}

test "setting a key rewrites only its line, or adds it, in TOML" {
    const a = try setLine(t.allocator, "# size = 1\nsize = 14\nwrap = false\n", "size", "16");
    defer t.allocator.free(a);
    try t.expectEqualStrings("# size = 1\nsize = 16\nwrap = false\n", a);
    const b = try setLine(t.allocator, "wrap = false", "pairs", "true");
    defer t.allocator.free(b);
    try t.expectEqualStrings("wrap = false\npairs = true\n", b);
    const c = try setLine(t.allocator, "focus = \"line\"\n", "focus", "paragraph");
    defer t.allocator.free(c);
    try t.expectEqualStrings("focus = \"paragraph\"\n", c);
}

test "the reader takes quotes, trailing comments and the old forms" {
    const s = parse(
        \\font = "Menlo-Regular"  # my font
        \\size = 18 # big
        \\wrap = true
        \\pairs = "off"
        \\focus = 'line'
        \\light.keyword = "#102030" # rust
        \\dark.keyword = #010203
    );
    try t.expectEqualStrings("Menlo-Regular", s.font());
    try t.expectEqual(@as(f64, 18), s.size);
    try t.expect(s.wrap and !s.pairs);
    try t.expectEqual(Focus.line, s.focus);
    try t.expectEqual(@as(f64, 0x10) / 255, s.light.kinds[1][0]);
    try t.expectEqual(@as(f64, 3) / 255, s.dark.kinds[1][2]);
}

test "old settings migrate to TOML and read back equal" {
    const old =
        \\font = Menlo-Regular
        \\size = 19
        \\line-height = 2.25
        \\wrap = on
        \\pairs = off
        \\focus = sentence
        \\typewriter = on
        \\line-numbers = off
        \\zen = on
        \\late-night = on
        \\sidebar = off
        \\sidebar-width = 333
        \\appearance = dark
        \\light-theme = one-light
        \\dark-theme = ayu-dark
        \\light.keyword = #102030
        \\dark.caret = #FF0000
    ;
    const a = parse(old);
    const text = try render(t.allocator, &a);
    defer t.allocator.free(text);
    const b = parse(text);
    try t.expectEqualStrings("Menlo-Regular", b.font());
    try t.expectEqual(a.size, b.size);
    try t.expectEqual(a.spacing, b.spacing);
    try t.expectEqual(a.wrap, b.wrap);
    try t.expectEqual(a.pairs, b.pairs);
    try t.expectEqual(a.focus, b.focus);
    try t.expectEqual(a.typewriter, b.typewriter);
    try t.expectEqual(a.line_numbers, b.line_numbers);
    try t.expectEqual(a.zen, b.zen);
    try t.expectEqual(a.late_night, b.late_night);
    try t.expectEqual(a.sidebar, b.sidebar);
    try t.expectEqual(a.sidebar_width, b.sidebar_width);
    try t.expectEqual(a.look, b.look);
    try t.expectEqual(a.light_scheme, b.light_scheme);
    try t.expectEqual(a.dark_scheme, b.dark_scheme);
    try t.expectEqual(a.light, b.light);
    try t.expectEqual(a.dark, b.dark);
    try t.expect(a.size == 19 and a.spacing == 2.25 and !a.pairs and a.light_scheme == 2 and a.dark_scheme == 4);
    try t.expect(std.mem.indexOf(u8, text, "size = 19\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "late-night = true\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "font = \"Menlo-Regular\"\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "dark.caret = \"#FF0000\"\n") != null);
}

test "launch adds every missing key and keeps the lines and comments there" {
    const text = try withMissing(t.allocator, "# mine\nsize = 16 # keep\n") orelse return error.TestUnexpectedResult;
    defer t.allocator.free(text);
    try t.expect(std.mem.startsWith(u8, text, "# mine\nsize = 16 # keep\n"));
    for (options) |row| {
        var line: [40]u8 = undefined;
        const want = try std.fmt.bufPrint(&line, "\n{s} = ", .{@tagName(row.opt)});
        if (row.opt != .size) try t.expect(std.mem.indexOf(u8, text, want) != null);
    }
    try t.expectEqual(@as(?usize, null), std.mem.indexOf(u8, text[24..], "size = "));
    try t.expect(std.mem.indexOf(u8, text, "# Number the lines beside the text") != null);
    try t.expectEqual(@as(?[]u8, null), try withMissing(t.allocator, text));
}

test "a single color applies on top of the chosen theme wherever its line sits" {
    const s = parse(
        \\dark.keyword = #010203
        \\dark-theme = one-dark
        \\light-theme = nonsense
    );
    try t.expectEqual(paper, s.light);
    try t.expectEqual(widen(one_dark).bg, s.dark.bg);
    try t.expectEqual(@as(f64, 3) / 255, s.dark.kinds[1][2]);
    const text = try render(t.allocator, &s);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "dark-theme = \"one-dark\"\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "dark.background") == null);
    try t.expectEqual(s.dark, parse(text).dark);
}

/// WCAG relative luminance of a color.
fn luminance(c: Rgb) f64 {
    var l: f64 = 0;
    for (c, [3]f64{ 0.2126, 0.7152, 0.0722 }) |v, k| l += k * (if (v <= 0.03928) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4));
    return l;
}

fn contrastRatio(a: Rgb, b: Rgb) f64 {
    const x = luminance(a);
    const y = luminance(b);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}

test "every theme's muted text reads at 4.5:1 and its comments at 3:1 on the page" {
    for (schemes) |sc| {
        const th = widen(sc.colors);
        try t.expect(contrastRatio(th.muted, th.bg) >= 4.5);
        try t.expect(contrastRatio(th.kinds[3], th.bg) >= 3.0);
    }
}

test "late-night covers the saved look and is written back as a flag" {
    var s = parse("late-night = on\nzen = off\nappearance = light\nlight-theme = paper\nfocus = line\n");
    try t.expect(s.late_night and !s.zen and s.look == .light);
    s.lateNight();
    try t.expect(s.zen and s.typewriter and s.focus == .paragraph and s.look == .dark);
    try t.expectEqual(black, s.dark);
    const text = try render(t.allocator, &parse("late-night = on\n"));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "late-night = true\n") != null);
}
