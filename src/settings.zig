//! The settings file, `~/.config/zag/config.toml`: every option in `options`,
//! as TOML `key = value` lines. Zag adds every missing key at launch, and
//! menu toggles rewrite just their own line.
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

comptime {
    std.debug.assert(@sizeOf(Theme) == 17 * @sizeOf(Rgb));
}

pub fn all(th: *Theme) *[17]Rgb {
    return @ptrCast(th);
}

fn rgb(v: u24) [3]u8 {
    return .{ @intCast(v >> 16), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) };
}

pub fn wide(c: [3]u8) Rgb {
    return .{ @as(f64, @floatFromInt(c[0])) / 255, @as(f64, @floatFromInt(c[1])) / 255, @as(f64, @floatFromInt(c[2])) / 255 };
}

/// A built-in scheme's bytes as the `Rgb` theme that draws.
fn widen(b: Bytes) Theme {
    const from: *const [@sizeOf(Bytes) / 3][3]u8 = @ptrCast(&b);
    var th: Theme = undefined;
    for (all(&th), from) |*o, c| o.* = wide(c);
    return th;
}

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
    // Warm paper in light mode.
    .{ .key = "paper", .title = "Paper", .dark = false, .colors = .{
        .bg = rgb(0xF5F2EA), .fg = rgb(0x2E2C28), .muted = rgb(0x736E64),
        .kinds = .{ rgb(0x2E2C28), rgb(0x9C3D26), rgb(0x4F7A3A), rgb(0x736E64), rgb(0xA8642A), rgb(0x2F6587), rgb(0x7D4E86) },
        .sel = rgb(0xF1C7AC), .line = rgb(0xEFEADF), .caret = rgb(0xE8590C), .match = rgb(0xF2D98A), .panel = rgb(0xECE7DB), .rule = rgb(0xD6CDB9), .header = rgb(0xE3DBCA),
    } },
    // Ayu Light, from the ayu theme family, with its syntax colors darkened to read at 4.5:1 on the page.
    .{ .key = "ayu-light", .title = "Ayu Light", .dark = false, .colors = .{
        .bg = rgb(0xF8F9FA), .fg = rgb(0x5C6166), .muted = rgb(0x6D7379),
        .kinds = .{ rgb(0x5C6166), rgb(0xAA602A), rgb(0x5E7D00), rgb(0x717376), rgb(0x8664A8), rgb(0x956B2D), rgb(0x2B78AF) },
        .sel = rgb(0xC2D6F2), .line = rgb(0xEDEFF0), .caret = rgb(0xFFAA33), .match = rgb(0xF5E1A8), .panel = rgb(0xF0F1F2), .rule = rgb(0xD6DADF), .header = rgb(0xE4E7EB),
    } },
    // One Light, Atom's light theme, with its syntax colors darkened to read at 4.5:1 on the page.
    .{ .key = "one-light", .title = "One Light", .dark = false, .colors = .{
        .bg = rgb(0xFAFAFA), .fg = rgb(0x383A42), .muted = rgb(0x727277),
        .kinds = .{ rgb(0x383A42), rgb(0xA626A4), rgb(0x408140), rgb(0x727379), rgb(0x986801), rgb(0x3A6EDD), rgb(0x9B6A01) },
        .sel = rgb(0xD8DEFB), .line = rgb(0xF0F0F1), .caret = rgb(0x526FFF), .match = rgb(0xF2E2A6), .panel = rgb(0xEFEFF0), .rule = rgb(0xD5D5D8), .header = rgb(0xE6E6E9),
    } },
    // Solarized Light, Ethan Schoonover's palette, with its grey and green, cyan and yellow accents darkened to read on base3.
    .{ .key = "solarized-light", .title = "Solarized Light", .dark = false, .colors = .{
        .bg = rgb(0xFDF6E3), .fg = rgb(0x586E75), .muted = rgb(0x5F747C),
        .kinds = .{ rgb(0x586E75), rgb(0x798B00), rgb(0x26928A), rgb(0x697373), rgb(0xD33682), rgb(0x2589CF), rgb(0xA57D00) },
        .sel = rgb(0xDCD4BC), .line = rgb(0xF3ECD7), .caret = rgb(0xCB4B16), .match = rgb(0xF0DD9A), .panel = rgb(0xEEE8D5), .rule = rgb(0xDDD6C1), .header = rgb(0xE8E1CC),
    } },
    // Gruvbox Light, morhetz's retro palette, with its greys darkened.
    .{ .key = "gruvbox-light", .title = "Gruvbox Light", .dark = false, .colors = .{
        .bg = rgb(0xFBF1C7), .fg = rgb(0x3C3836), .muted = rgb(0x786B60),
        .kinds = .{ rgb(0x3C3836), rgb(0x9D0006), rgb(0x79740E), rgb(0x786C60), rgb(0x8F3F71), rgb(0x427B58), rgb(0xB57614) },
        .sel = rgb(0xE6D3A3), .line = rgb(0xF2E5BC), .caret = rgb(0xAF3A03), .match = rgb(0xF5D58A), .panel = rgb(0xF2E5BC), .rule = rgb(0xD5C4A1), .header = rgb(0xEBDBB2),
    } },
    // Ink in dark mode.
    .{ .key = "ink", .title = "Ink", .dark = true, .colors = .{
        .bg = rgb(0x17171B), .fg = rgb(0xD9D4C7), .muted = rgb(0x8A857B),
        .kinds = .{ rgb(0xD9D4C7), rgb(0xF08A6C), rgb(0xA7C080), rgb(0x838078), rgb(0xE8B86B), rgb(0x8DB8D8), rgb(0xCFA3D8) },
        .sel = rgb(0x5E3B26), .line = rgb(0x1E1E24), .caret = rgb(0xFF8A3D), .match = rgb(0x5A4A24), .panel = rgb(0x202027), .rule = rgb(0x2A2A31), .header = rgb(0x212128),
    } },
    // Ayu Dark.
    .{ .key = "ayu-dark", .title = "Ayu Dark", .dark = true, .colors = .{
        .bg = rgb(0x0B0E14), .fg = rgb(0xBFBDB6), .muted = rgb(0x7C7F85),
        .kinds = .{ rgb(0xBFBDB6), rgb(0xFF8F40), rgb(0xAAD94C), rgb(0x767B82), rgb(0xD2A6FF), rgb(0xFFB454), rgb(0x59C2FF) },
        .sel = rgb(0x1F4470), .line = rgb(0x131721), .caret = rgb(0xE6B450), .match = rgb(0x4A3B1A), .panel = rgb(0x0F131A), .rule = rgb(0x1B1F29), .header = rgb(0x151A23),
    } },
    // One Dark, Atom's dark theme.
    .{ .key = "one-dark", .title = "One Dark", .dark = true, .colors = .{
        .bg = rgb(0x282C34), .fg = rgb(0xABB2BF), .muted = rgb(0x8B93A4),
        .kinds = .{ rgb(0xABB2BF), rgb(0xC678DD), rgb(0x98C379), rgb(0x8D939D), rgb(0xD19A66), rgb(0x61AFEF), rgb(0xE5C07B) },
        .sel = rgb(0x354871), .line = rgb(0x2C313C), .caret = rgb(0x528BFF), .match = rgb(0x314365), .panel = rgb(0x21252B), .rule = rgb(0x181A1F), .header = rgb(0x31363F),
    } },
    // Solarized Dark, with its greys lightened to read on base03.
    .{ .key = "solarized-dark", .title = "Solarized Dark", .dark = true, .colors = .{
        .bg = rgb(0x002B36), .fg = rgb(0x93A1A1), .muted = rgb(0x7D9096),
        .kinds = .{ rgb(0x93A1A1), rgb(0x859900), rgb(0x2AA198), rgb(0x7F9095), rgb(0xD33682), rgb(0x268BD2), rgb(0xB58900) },
        .sel = rgb(0x174C5A), .line = rgb(0x073642), .caret = rgb(0xCB4B16), .match = rgb(0x3E4A1C), .panel = rgb(0x00252E), .rule = rgb(0x0D3D4A), .header = rgb(0x05313D),
    } },
    // Gruvbox Dark, with its comment grey lightened a step.
    .{ .key = "gruvbox-dark", .title = "Gruvbox Dark", .dark = true, .colors = .{
        .bg = rgb(0x282828), .fg = rgb(0xEBDBB2), .muted = rgb(0xA89984),
        .kinds = .{ rgb(0xEBDBB2), rgb(0xFB4934), rgb(0xB8BB26), rgb(0x9A8C7E), rgb(0xD3869B), rgb(0x83A598), rgb(0xFABD2F) },
        .sel = rgb(0x504945), .line = rgb(0x32302F), .caret = rgb(0xFE8019), .match = rgb(0x5B4A1E), .panel = rgb(0x1D2021), .rule = rgb(0x3C3836), .header = rgb(0x32302F),
    } },
    // Black for OLED screens: pure black with off-white text a step softer than Ink's, since black raises the contrast, and Ink's hues pulled a tenth toward black to sit with it.
    .{ .key = "black", .title = "Black", .dark = true, .colors = .{
        .bg = rgb(0x000000), .fg = rgb(0xCBC6BA), .muted = rgb(0x7B776F),
        .kinds = .{ rgb(0xCBC6BA), rgb(0xD87C61), rgb(0x96AD73), rgb(0x78746D), rgb(0xD1A660), rgb(0x7FA6C2), rgb(0xBA93C2) },
        .sel = rgb(0x3A2416), .line = rgb(0x0A0A0B), .caret = rgb(0xE67A33), .match = rgb(0x3A3018), .panel = rgb(0x101012), .rule = rgb(0x1C1C20), .header = rgb(0x111113),
    } },
};

fn schemeIndex(key: []const u8) ?u8 {
    for (schemes, 0..) |sc, i| if (std.mem.eql(u8, sc.key, key)) return @intCast(i);
    return null;
}

/// The default dark theme's index.
const ink_index = schemeIndex("ink").?;
pub const paper = widen(schemes[0].colors);
pub const ink = widen(schemes[ink_index].colors);

/// What `parse` couldn't use: how many lines, and the first one's line
/// number and why.
pub const Report = struct {
    count: u16 = 0,
    /// 1-based; 0 when every line read cleanly.
    first_line: u32 = 0,
    msg_buf: [128]u8 = undefined,
    msg_len: u8 = 0,

    pub fn firstMessage(r: *const Report) []const u8 {
        return r.msg_buf[0..r.msg_len];
    }

    fn add(r: *Report, line: u32, comptime fmt: []const u8, args: anytype) void {
        r.count +|= 1;
        if (r.count > 1) return;
        r.first_line = line;
        const m = std.fmt.bufPrint(&r.msg_buf, fmt, args) catch r.msg_buf[0..0];
        r.msg_len = @intCast(m.len);
    }
};

/// At most 32 bytes of `s`, cut between characters, so a report's message
/// fits its buffer and stays UTF-8.
fn clip(s: []const u8) []const u8 {
    if (s.len <= 32) return s;
    var n: usize = 32;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

pub const default_size = 14.0;
/// The text size's range, in points.
pub const size_min = 8.0;
pub const size_max = 40.0;

/// Light or dark: `auto` follows the Mac.
pub const Look = enum { auto, light, dark };
pub const Focus = enum { off, line, sentence, paragraph };
/// What the Tab key inserts.
pub const IndentWith = enum { spaces, tabs };
/// When the status bar counts words: `auto` counts them in prose files.
pub const WordCount = enum { auto, always, off };
pub const CaretStyle = enum { bar, block, underline };
/// Which spaces, tabs and line ends show as faint marks.
pub const Invisibles = enum { none, trailing, all };

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
    /// Columns per tab stop.
    tab_width: u8 = 4,
    indent_with: IndentWith = .spaces,
    /// Saving strips spaces and tabs at line ends.
    trim_trailing_whitespace: bool = false,
    /// Saving adds a newline at the end when the text lacks one.
    ensure_final_newline: bool = false,
    /// Wrapped rows start under their line's indent.
    hanging_indent: bool = false,
    caret_style: CaretStyle = .bar,
    /// The bar caret's width in points.
    caret_width: f64 = 2.0,
    caret_blink: bool = true,
    /// A band behind the caret's line.
    highlight_current_line: bool = true,
    show_invisibles: Invisibles = .none,
    /// Faint vertical lines at each indent level.
    indent_guides: bool = false,
    word_count: WordCount = .auto,
    /// The zen page's width in columns.
    zen_columns: u16 = 80,
    /// How far Focus fades the text outside the caret's range: 0 leaves it
    /// as it is, 1 would hide it.
    focus_dim: f64 = 0.78,
    /// Late-Night Focus also warms the colors.
    late_night_warmth: bool = false,
    /// The sidebar lists dotfiles and other hidden files.
    show_hidden: bool = false,
    look: Look = .auto,
    /// Indexes into `schemes`: the theme for light mode and for dark mode.
    light_scheme: u8 = 0,
    dark_scheme: u8 = ink_index,
    /// The chosen themes with the file's single-color lines on top.
    light: Theme = paper,
    dark: Theme = ink,
    /// The lines `parse` couldn't use.
    report: Report = .{},

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
        const i = comptime schemeIndex("black").?;
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
    // Skip kinds[0], which mirrors the text color and has no name.
    return &all(th)[if (i < 3) i else i + 1];
}

/// `#RRGGBB` or `#RGB`, with or without the `#`.
fn parseHex(s: []const u8) ?Rgb {
    const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
    var six: [6]u8 = undefined;
    const digits: []const u8 = switch (h.len) {
        6 => h,
        3 => blk: {
            for (h, 0..) |c, i| {
                six[2 * i] = c;
                six[2 * i + 1] = c;
            }
            break :blk &six;
        },
        else => return null,
    };
    for (digits) |c| if (!std.ascii.isHex(c)) return null;
    const v = std.fmt.parseInt(u24, digits, 16) catch return null;
    return wide(rgb(v));
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
    const head = std.fmt.bufPrint(buf, "{d}", .{whole}) catch return "";
    var n = head.len;
    if (frac != 0) {
        buf[n] = '.';
        buf[n + 1] = @intCast('0' + frac / 10);
        n += 2;
        if (frac % 10 != 0) {
            buf[n] = @intCast('0' + frac % 10);
            n += 1;
        }
    }
    return buf[0..n];
}

/// Splits the right-hand side of `key = rhs` into its unquoted value and any
/// trailing ` # comment` (keeping the spaces before `#`).
fn splitValue(rhs: []const u8) struct { val: []const u8, comment: []const u8 } {
    const s = std.mem.trim(u8, rhs, " \t\r");
    if (s.len > 0 and (s[0] == '"' or s[0] == '\'')) {
        const end = std.mem.indexOfScalarPos(u8, s, 1, s[0]) orelse return .{ .val = s[1..], .comment = "" };
        const rest = s[end + 1 ..];
        const trimmed = std.mem.trimStart(u8, rest, " \t");
        return .{ .val = s[1..end], .comment = if (trimmed.len > 0 and trimmed[0] == '#') rest else "" };
    }
    for (s, 0..) |ch, i| if (ch == '#' and i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\t')) {
        const val = std.mem.trimEnd(u8, s[0..i], " \t");
        return .{ .val = val, .comment = s[val.len..] };
    };
    return .{ .val = s, .comment = "" };
}

/// A `[section]` of the file: `[light]` and `[dark]` take color names as keys.
const Section = enum { root, light, dark, other };

const Entry = struct {
    /// A `key = value` line, a `[section]` header (its name in `key`), or a
    /// line that is neither (all of it in `key`).
    kind: enum { pair, header, junk } = .pair,
    key: []const u8,
    val: []const u8 = "",
    /// 1-based.
    line: u32,
    section: Section,
};

/// Walks the file's lines, skipping blanks and comments, and tracks the
/// section each line falls in.
const Reader = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    line: u32 = 0,
    section: Section = .root,

    fn init(text: []const u8) Reader {
        return .{ .it = std.mem.splitScalar(u8, text, '\n') };
    }

    fn reset(r: *Reader) void {
        r.it.reset();
        r.line = 0;
        r.section = .root;
    }

    /// The next line that says something. A value loses one pair of quotes,
    /// or else a trailing ` # comment`.
    fn next(r: *Reader) ?Entry {
        while (r.it.next()) |raw| {
            r.line +|= 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, ']') orelse line.len;
                const name = std.mem.trim(u8, line[1..end], " \t");
                r.section = if (std.mem.eql(u8, name, "light")) .light else if (std.mem.eql(u8, name, "dark")) .dark else .other;
                return .{ .kind = .header, .key = name, .line = r.line, .section = r.section };
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse
                return .{ .kind = .junk, .key = line, .line = r.line, .section = r.section };
            return .{ .key = std.mem.trim(u8, line[0..eq], " \t"), .val = splitValue(line[eq + 1 ..]).val, .line = r.line, .section = r.section };
        }
        return null;
    }
};

/// Where the file's top-level keys end: the start of its first `[section]`
/// line, or its end.
fn rootEnd(text: []const u8) usize {
    var at: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (line.len > 0 and line[0] == '[') return at;
        at += raw.len + 1;
    }
    return text.len;
}

fn flagOr(rep: *Report, e: Entry, cur: bool) bool {
    return flag(e.val) orelse {
        rep.add(e.line, "{s} = \"{s}\" isn't true or false", .{ clip(e.key), clip(e.val) });
        return cur;
    };
}

/// `E`'s values, as a list for a message.
fn choices(comptime E: type) []const u8 {
    comptime var out: []const u8 = "";
    inline for (@typeInfo(E).@"enum".field_names, 0..) |name, i| out = out ++ (if (i == 0) "" else ", ") ++ name;
    return out;
}

fn enumOr(comptime E: type, rep: *Report, e: Entry, cur: E) E {
    return enumOf(E, e.val) orelse {
        rep.add(e.line, "{s} = \"{s}\" isn't one of " ++ comptime choices(E), .{ clip(e.key), clip(e.val) });
        return cur;
    };
}

/// The value as a number from `lo` to `hi`: one outside is clamped, and
/// one that isn't a number leaves `cur`. Both go in the report.
fn ranged(rep: *Report, e: Entry, cur: f64, lo: f64, hi: f64) f64 {
    const v = number(e.val) orelse {
        rep.add(e.line, "{s} = \"{s}\" isn't a number", .{ clip(e.key), clip(e.val) });
        return cur;
    };
    if (v < lo or v > hi) {
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        rep.add(e.line, "{s} = {s} is outside {s} to {s}", .{ clip(e.key), clip(e.val), decimal(&a, lo), decimal(&b, hi) });
    }
    return std.math.clamp(v, lo, hi);
}

/// One color of `th`, named by `name`, from the entry's value.
fn setColor(rep: *Report, th: *Theme, e: Entry, name: []const u8) void {
    const p = slot(th, name) orelse return rep.add(e.line, "\"{s}\" isn't a color's name", .{clip(e.key)});
    const c = parseHex(e.val) orelse return rep.add(e.line, "{s} = \"{s}\" isn't a color like #9C3D26", .{ clip(e.key), clip(e.val) });
    p.* = c;
    if (p == &th.fg) th.kinds[0] = c;
}

/// Reads settings text. Lines it doesn't understand keep their defaults,
/// and `report` counts them. Single colors apply on top of the chosen
/// themes wherever they sit, as `light.keyword` lines or as `keyword`
/// lines under a `[light]` or `[dark]` header.
pub fn parse(text: []const u8) Settings {
    var s: Settings = .{};
    const rep = &s.report;
    var r = Reader.init(text);
    while (r.next()) |e| {
        if (e.kind != .pair or e.section != .root) continue;
        if (std.mem.eql(u8, e.key, "light-theme")) {
            s.light_scheme = schemeIndex(e.val) orelse s.light_scheme;
        } else if (std.mem.eql(u8, e.key, "dark-theme")) {
            s.dark_scheme = schemeIndex(e.val) orelse s.dark_scheme;
        }
    }
    s.light = widen(schemes[s.light_scheme].colors);
    s.dark = widen(schemes[s.dark_scheme].colors);
    r.reset();
    while (r.next()) |e| {
        switch (e.kind) {
            .pair => {},
            .header => {
                if (e.section == .other) rep.add(e.line, "[{s}] isn't a section: use [light] or [dark]", .{clip(e.key)});
                continue;
            },
            .junk => {
                rep.add(e.line, "\"{s}\" isn't a key = value line", .{clip(e.key)});
                continue;
            },
        }
        switch (e.section) {
            .root => {},
            .light => {
                setColor(rep, &s.light, e, e.key);
                continue;
            },
            .dark => {
                setColor(rep, &s.dark, e, e.key);
                continue;
            },
            .other => continue,
        }
        switch (enumOf(Opt, e.key) orelse {
            const dot = std.mem.indexOfScalar(u8, e.key, '.') orelse {
                rep.add(e.line, "\"{s}\" isn't a setting", .{clip(e.key)});
                continue;
            };
            const mode = e.key[0..dot];
            const theme = if (std.mem.eql(u8, mode, "light")) &s.light else if (std.mem.eql(u8, mode, "dark")) &s.dark else {
                rep.add(e.line, "\"{s}\" isn't a setting", .{clip(e.key)});
                continue;
            };
            setColor(rep, theme, e, e.key[dot + 1 ..]);
            continue;
        }) {
            .font => s.setFont(e.val),
            .@"light-theme", .@"dark-theme" => if (schemeIndex(e.val) == null)
                rep.add(e.line, "{s} = \"{s}\" isn't a theme", .{ clip(e.key), clip(e.val) }),
            inline else => |o| {
                const f = &@field(s, fieldName(o));
                const T = @FieldType(Settings, fieldName(o));
                f.* = switch (@typeInfo(T)) {
                    .bool => flagOr(rep, e, f.*),
                    .@"enum" => enumOr(T, rep, e, f.*),
                    .float => ranged(rep, e, f.*, options[@intFromEnum(o)].lo, options[@intFromEnum(o)].hi),
                    .int => @intFromFloat(@round(ranged(rep, e, @floatFromInt(f.*), options[@intFromEnum(o)].lo, options[@intFromEnum(o)].hi))),
                    else => comptime unreachable,
                };
            },
        }
    }
    return s;
}

pub const Opt = enum {
    font,
    size,
    @"line-height",
    wrap,
    pairs,
    focus,
    typewriter,
    @"line-numbers",
    zen,
    @"late-night",
    sidebar,
    @"sidebar-width",
    @"tab-width",
    @"indent-with",
    @"trim-trailing-whitespace",
    @"ensure-final-newline",
    @"hanging-indent",
    @"caret-style",
    @"caret-width",
    @"caret-blink",
    @"highlight-current-line",
    @"show-invisibles",
    @"indent-guides",
    @"word-count",
    @"zen-columns",
    @"focus-dim",
    @"late-night-warmth",
    @"show-hidden",
    appearance,
    @"light-theme",
    @"dark-theme",
};

pub fn fieldName(comptime opt: Opt) [:0]const u8 {
    return switch (opt) {
        .@"line-height" => "spacing",
        .appearance => "look",
        .@"light-theme" => "light_scheme",
        .@"dark-theme" => "dark_scheme",
        else => comptime blk: {
            var chars = @tagName(opt).*;
            std.mem.replaceScalar(u8, chars[0..], '-', '_');
            const out = chars;
            break :blk &out;
        },
    };
}

/// One line of the file: its comment above it, and a blank line before the
/// comment when `gap`. `render` and the launch-time fill-in share this list.
const Row = struct { opt: Opt, lo: f64 = 0, hi: f64 = 0, gap: bool = false, note: []const u8 };

const options = [_]Row{
    .{ .opt = .font, .note = "# A font's PostScript name, like Menlo-Regular, or system for SF Mono.\n" },
    .{ .opt = .size, .lo = size_min, .hi = size_max, .note = "# The text size in points, from 8 to 40.\n" },
    .{ .opt = .@"line-height", .lo = 1, .hi = 3, .note = "# Line height, as a multiple of the size, from 1 to 3.\n" },
    .{ .opt = .wrap, .note = "# Wrap long lines at the window's edge: true or false.\n" },
    .{ .opt = .pairs, .note = "# Close brackets and quotes as you type them: true or false.\n" },
    .{ .opt = .focus, .note = "# Fade text outside the caret's range: off, line, sentence or paragraph.\n" },
    .{ .opt = .typewriter, .note = "# Keep the caret's row in the middle as you type: true or false.\n" },
    .{ .opt = .@"line-numbers", .note = "# Number the lines beside the text: true or false.\n" },
    .{ .opt = .zen, .note = "# Hide the window's chrome and center a grey page zen-columns wide: true or false.\n" },
    .{ .opt = .@"late-night", .note = "# Late-Night Focus: zen, typewriter, paragraph focus and Black on top of the above: true or false.\n" },
    .{ .opt = .sidebar, .note = "# Show the folder's files on the left of the window: true or false.\n" },
    .{ .opt = .@"sidebar-width", .lo = sidebar_min, .hi = sidebar_max, .note = "# How wide the sidebar is, in points from 150 to 500: drag its edge to change it.\n" },
    .{ .opt = .@"tab-width", .lo = 1, .hi = 16, .gap = true, .note = "# Columns per tab stop, from 1 to 16.\n" },
    .{ .opt = .@"indent-with", .note = "# What the Tab key inserts: spaces or tabs.\n" },
    .{ .opt = .@"trim-trailing-whitespace", .note = "# Strip spaces and tabs at the ends of lines when saving: true or false.\n" },
    .{ .opt = .@"ensure-final-newline", .note = "# End the file with a newline when saving: true or false.\n" },
    .{ .opt = .@"hanging-indent", .note = "# Start wrapped rows under their line's indent: true or false.\n" },
    .{ .opt = .@"caret-style", .gap = true, .note = "# The caret's shape: bar, block or underline.\n" },
    .{ .opt = .@"caret-width", .lo = 1, .hi = 6, .note = "# The bar caret's width in points, from 1 to 6.\n" },
    .{ .opt = .@"caret-blink", .note = "# Blink the caret: true or false.\n" },
    .{ .opt = .@"highlight-current-line", .note = "# Shade the caret's line: true or false.\n" },
    .{ .opt = .@"show-invisibles", .note = "# Mark spaces, tabs and line ends: none, trailing or all.\n" },
    .{ .opt = .@"indent-guides", .note = "# Draw a faint line at each indent level: true or false.\n" },
    .{ .opt = .@"word-count", .note = "# Count words in the status bar: auto (prose files), always or off.\n" },
    .{ .opt = .@"zen-columns", .lo = 40, .hi = 160, .note = "# How wide zen's page is, in columns from 40 to 160.\n" },
    .{ .opt = .@"focus-dim", .lo = 0.2, .hi = 0.95, .note = "# How far Focus fades the text outside the caret's range, from 0.2 to 0.95.\n" },
    .{ .opt = .@"late-night-warmth", .note = "# Warm the colors in Late-Night Focus: true or false.\n" },
    .{ .opt = .@"show-hidden", .note = "# List hidden files and folders in the sidebar: true or false.\n" },
    .{ .opt = .appearance, .gap = true, .note = "# Light or dark: auto follows the Mac, light or dark keeps Zag in that mode.\n" },
    .{ .opt = .@"light-theme", .note = "# The theme for each mode: paper, ayu-light, one-light, solarized-light,\n# gruvbox-light, ink, ayu-dark, one-dark, solarized-dark, gruvbox-dark or black.\n" },
    .{ .opt = .@"dark-theme", .note = "" },
};

comptime {
    for (options, 0..) |row, i| std.debug.assert(@intFromEnum(row.opt) == i);
}

fn enumOf(comptime E: type, s: []const u8) ?E {
    for (@typeInfo(E).@"enum".field_names, std.enums.values(E)) |name, v| if (std.mem.eql(u8, s, name)) return v;
    return null;
}

fn quoted(opt: Opt) bool {
    return switch (opt) {
        .font, .@"light-theme", .@"dark-theme" => true,
        inline else => |o| @typeInfo(@FieldType(Settings, fieldName(o))) == .@"enum",
    };
}

/// What `s` holds for `opt`, as the file writes it (before any quotes).
fn valueText(s: *const Settings, opt: Opt, buf: *[24]u8) []const u8 {
    return switch (opt) {
        .font => if (s.font_len == 0) "system" else s.font(),
        .@"light-theme" => schemes[s.light_scheme].key,
        .@"dark-theme" => schemes[s.dark_scheme].key,
        inline else => |o| switch (@typeInfo(@FieldType(Settings, fieldName(o)))) {
            .bool => if (@field(s, fieldName(o))) "true" else "false",
            .@"enum" => @tagName(@field(s, fieldName(o))),
            .float => decimal(buf, @field(s, fieldName(o))),
            .int => decimal(buf, @floatFromInt(@field(s, fieldName(o)))),
            else => comptime unreachable,
        },
    };
}

/// Whether `a` and `b` hold the same value for `opt`.
pub fn same(a: *const Settings, b: *const Settings, opt: Opt) bool {
    return switch (opt) {
        .font => std.mem.eql(u8, a.font(), b.font()),
        inline else => |o| @field(a, fieldName(o)) == @field(b, fieldName(o)),
    };
}

fn writeOption(gpa: Allocator, out: *std.ArrayList(u8), s: *const Settings, row: Row) !void {
    var buf: [24]u8 = undefined;
    if (row.gap) try out.append(gpa, '\n');
    try out.appendSlice(gpa, row.note);
    const q: []const u8 = if (quoted(row.opt)) "\"" else "";
    try out.print(gpa, "{s} = {s}{s}{s}\n", .{ @tagName(row.opt), q, valueText(s, row.opt, &buf), q });
}

/// The whole file for `s`, in TOML, with a comment on each group. Colors are
/// written only where they differ from the chosen theme.
fn render(gpa: Allocator, s: *const Settings) ![]u8 {
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
        \\#
        \\# Or set a mode's colors under a section at the end of the file:
        \\# [dark]
        \\# keyword = "#F08A6C"
        \\# comment = "#888"
        \\
    );
    for ([_][]const u8{ "light", "dark" }, 0..) |name, n| {
        var th = if (n == 0) s.light else s.dark;
        var base = widen(schemes[if (n == 0) s.light_scheme else s.dark_scheme].colors);
        for (colors) |c| {
            const v = slot(&th, c).?.*;
            if (std.mem.eql(f64, &v, &slot(&base, c).?.*)) continue;
            const hex = std.fmt.bytesToHex([3]u8{ byte(v[0]), byte(v[1]), byte(v[2]) }, .upper);
            try out.print(gpa, "{s}.{s} = \"#{s}\"\n", .{ name, c, &hex });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn byte(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// `text` with the `opt` line set to `value`, added after the top-level keys
/// when missing. Flags (`true`, `false`) and numbers are written bare,
/// everything else quoted. The last top-level `opt` line is the one `parse`
/// reads, so that one changes, and its trailing comment stays.
pub fn setLine(gpa: Allocator, text: []const u8, opt: Opt, value: []const u8) ![]u8 {
    const key = @tagName(opt);
    const q: []const u8 = if (quoted(opt)) "\"" else "";
    const end = rootEnd(text);
    var hit: ?struct { a: usize, b: usize, comment: []const u8 } = null;
    var it = std.mem.splitScalar(u8, text[0..end], '\n');
    var pos: usize = 0;
    while (it.next()) |raw| : (pos += raw.len + 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (line[0] != '#' and std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key))
            hit = .{ .a = pos, .b = pos + raw.len, .comment = splitValue(line[eq + 1 ..]).comment };
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (hit) |h| {
        try out.print(gpa, "{s}{s} = {s}{s}{s}{s}{s}", .{ text[0..h.a], key, q, value, q, h.comment, text[h.b..] });
    } else {
        try out.appendSlice(gpa, text[0..end]);
        if (end > 0 and text[end - 1] != '\n') try out.append(gpa, '\n');
        try out.print(gpa, "{s} = {s}{s}{s}\n", .{ key, q, value, q });
        if (end < text.len) try out.append(gpa, '\n');
        try out.appendSlice(gpa, text[end..]);
    }
    return out.toOwnedSlice(gpa);
}

/// `text` with every option it lacks added after its top-level keys, each
/// under its comment, with the value `parse` gives it. Null when none is
/// missing.
fn withMissing(gpa: Allocator, text: []const u8) !?[]u8 {
    const s = parse(text);
    const end = rootEnd(text);
    var seen: [options.len]bool = @splat(false);
    var r = Reader.init(text[0..end]);
    while (r.next()) |e| {
        if (e.kind == .pair) if (enumOf(Opt, e.key)) |o| {
            seen[@intFromEnum(o)] = true;
        };
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, text[0..end]);
    if (end > 0 and text[end - 1] != '\n') try out.append(gpa, '\n');
    const base = out.items.len;
    for (options, seen) |row, ok| if (!ok) try writeOption(gpa, &out, &s, row);
    if (out.items.len == base) {
        out.deinit(gpa);
        return null;
    }
    if (end < text.len) {
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, text[end..]);
    }
    return try out.toOwnedSlice(gpa);
}

/// `~/.config/zag/config.toml`. Owned by gpa.
pub fn path(gpa: Allocator) ![:0]u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHome);
    return std.fmt.allocPrintSentinel(gpa, "{s}/.config/zag/config.toml", .{home}, 0);
}

/// Reads the file at `p`; a missing or unreadable file gives the defaults.
pub fn load(gpa: Allocator, p: [:0]const u8) Settings {
    const text = files.read(gpa, p) catch return .{};
    defer gpa.free(text);
    return parse(text);
}

/// Creates the file from `s` when missing.
pub fn ensure(gpa: Allocator, p: [:0]const u8, s: *const Settings) !void {
    if (files.exists(p)) return;
    try files.makeParent(p);
    const text = try render(gpa, s);
    defer gpa.free(text);
    try files.write(p, text);
}

/// At launch: creates the file and adds the options it lacks. Existing lines
/// and comments stay as they are; a file that can't be read is left alone.
pub fn prepare(gpa: Allocator, p: [:0]const u8) void {
    ensure(gpa, p, &.{}) catch return;
    const text = files.read(gpa, p) catch return;
    defer gpa.free(text);
    const next = (withMissing(gpa, text) catch return) orelse return;
    defer gpa.free(next);
    files.write(p, next) catch {};
}

/// Rewrites one line of the file, creating it as `ensure` does first if needed.
pub fn store(gpa: Allocator, p: [:0]const u8, s: *const Settings, opt: Opt, value: []const u8) !void {
    try ensure(gpa, p, s);
    const text = try files.read(gpa, p);
    defer gpa.free(text);
    const next = try setLine(gpa, text, opt, value);
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
        \\line-height = 2.25
        \\focus = sentence
        \\typewriter = true
        \\line-numbers = false
        \\zen = true
        \\late-night = true
        \\sidebar = false
        \\appearance = dark
        \\light-theme = one-light
        \\dark-theme = ayu-dark
        \\sidebar-width = 900
        \\light.comment = #102030
        \\dark.text = 0A0B0C
        \\dark.header = #010203
        \\light.selection = #040506
        \\light.type = #070809
        \\dark.bogus = #FFFFFF
        \\nonsense line
    );
    try t.expectEqualStrings("Menlo-Regular", s.font());
    try t.expectEqual(@as(f64, 40), s.size);
    try t.expect(s.wrap and !s.pairs);
    try t.expectEqual(@as(f64, 2.25), s.spacing);
    try t.expectEqual(Focus.sentence, s.focus);
    try t.expect(s.typewriter and !s.line_numbers and s.zen and s.late_night and !s.sidebar);
    try t.expectEqual(Look.dark, s.look);
    try t.expectEqual(@as(u8, 2), s.light_scheme);
    try t.expectEqual(schemeIndex("ayu-dark").?, s.dark_scheme);
    try t.expectEqual(sidebar_max, s.sidebar_width);
    try t.expectEqual(@as(f64, 0x10) / 255, s.light.kinds[3][0]);
    try t.expectEqual(@as(f64, 0x0C) / 255, s.dark.fg[2]);
    try t.expectEqual(s.dark.fg, s.dark.kinds[0]);
    try t.expectEqual(@as(f64, 0x03) / 255, s.dark.header[2]);
    try t.expectEqual(@as(f64, 0x06) / 255, s.light.sel[2]);
    try t.expectEqual(@as(f64, 0x09) / 255, s.light.kinds[6][2]);
    try t.expectEqual(widen(schemes[schemeIndex("ayu-dark").?].colors).bg, s.dark.bg);
    try t.expectEqual(@as(u16, 4), s.report.count);
    try t.expectEqual(@as(u32, 3), s.report.first_line);
    try t.expectEqualStrings("size = 99 is outside 8 to 40", s.report.firstMessage());
}

test "a written file reads back as the same settings" {
    var s: Settings = .{ .size = 16, .spacing = 2.25, .wrap = true, .pairs = false, .focus = .sentence, .typewriter = true, .line_numbers = false, .zen = true, .late_night = true, .sidebar = false, .look = .dark, .sidebar_width = 320, .tab_width = 8, .indent_with = .tabs, .trim_trailing_whitespace = true, .ensure_final_newline = true, .hanging_indent = true, .caret_style = .block, .caret_width = 3.5, .caret_blink = false, .highlight_current_line = false, .show_invisibles = .trailing, .indent_guides = true, .word_count = .always, .zen_columns = 100, .focus_dim = 0.5, .late_night_warmth = true, .show_hidden = true, .light_scheme = 2, .dark_scheme = schemeIndex("ayu-dark").?, .light = widen(schemes[schemeIndex("one-light").?].colors), .dark = widen(schemes[schemeIndex("ayu-dark").?].colors) };
    s.setFont("Menlo-Regular");
    s.dark.caret = .{ 1, 0, 0 };
    const text = try render(t.allocator, &s);
    defer t.allocator.free(text);
    const back = parse(text);
    try t.expect(std.mem.indexOf(u8, text, "\nsize = 16\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "font = \"Menlo-Regular\"\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "dark.caret = \"#FF0000\"\n") != null);
    try t.expectEqualStrings("Menlo-Regular", back.font());
    try t.expectEqual(s.size, back.size);
    try t.expectEqual(s.spacing, back.spacing);
    try t.expectEqual(s.pairs, back.pairs);
    try t.expect(back.wrap);
    try t.expectEqual(s.focus, back.focus);
    try t.expectEqual(s.typewriter, back.typewriter);
    try t.expectEqual(s.line_numbers, back.line_numbers);
    try t.expect(back.zen);
    try t.expectEqual(s.late_night, back.late_night);
    try t.expectEqual(s.sidebar, back.sidebar);
    try t.expectEqual(s.light_scheme, back.light_scheme);
    try t.expectEqual(s.dark_scheme, back.dark_scheme);
    try t.expectEqual(@as(f64, 320), back.sidebar_width);
    try t.expectEqual(Look.dark, back.look);
    try t.expectEqual(s.dark.caret, back.dark.caret);
    try t.expectEqual(s.light, back.light);
    try t.expectEqual(s.dark, back.dark);
    for (std.enums.values(Opt)) |o| try t.expect(same(&s, &back, o));
    try t.expectEqual(@as(u16, 0), back.report.count);
}

test "setting a key rewrites only its line, or adds it, in TOML" {
    const a = try setLine(t.allocator, "# size = 1\nsize = 14\nwrap = false\n", .size, "16");
    defer t.allocator.free(a);
    try t.expectEqualStrings("# size = 1\nsize = 16\nwrap = false\n", a);
    const b = try setLine(t.allocator, "wrap = false", .pairs, "true");
    defer t.allocator.free(b);
    try t.expectEqualStrings("wrap = false\npairs = true\n", b);
    const c = try setLine(t.allocator, "focus = \"line\"\n", .focus, "paragraph");
    defer t.allocator.free(c);
    try t.expectEqualStrings("focus = \"paragraph\"\n", c);
    const d = try setLine(t.allocator, "wrap = true # wrap prose\nfont = \"Menlo\"  # mine\n", .wrap, "false");
    defer t.allocator.free(d);
    try t.expectEqualStrings("wrap = false # wrap prose\nfont = \"Menlo\"  # mine\n", d);
    const e = try setLine(t.allocator, d, .font, "system");
    defer t.allocator.free(e);
    try t.expectEqualStrings("wrap = false # wrap prose\nfont = \"system\"  # mine\n", e);
    const f = try setLine(t.allocator, "wrap = false\nsize = 14\nwrap = true\n", .wrap, "false");
    defer t.allocator.free(f);
    try t.expectEqualStrings("wrap = false\nsize = 14\nwrap = false\n", f);
    try t.expect(!parse(f).wrap);
}

test "the reader takes quotes, trailing comments and bare values" {
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
    try t.expectEqual(widen(schemes[schemeIndex("one-dark").?].colors).bg, s.dark.bg);
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

test "every theme's muted text and comments read at 4.5:1 and its syntax at 3:1 on the page" {
    for (schemes) |sc| {
        const th = widen(sc.colors);
        try t.expect(contrastRatio(th.muted, th.bg) >= 4.5);
        try t.expect(contrastRatio(th.kinds[3], th.bg) >= 4.5);
        for (th.kinds) |k| try t.expect(contrastRatio(k, th.bg) >= 3.0);
    }
    for ([_]Bytes{ schemes[schemeIndex("ayu-light").?].colors, schemes[schemeIndex("one-light").?].colors }) |b| {
        const th = widen(b);
        for (th.kinds) |k| try t.expect(contrastRatio(k, th.bg) >= 4.5);
    }
}

test "[light] and [dark] sections set colors, and #RGB reads as #RRGGBB" {
    const text =
        \\size = 16
        \\[dark]
        \\keyword = "#F00"
        \\text = #0A0B0C
        \\bogus = #FFFFFF
        \\[light]
        \\comment = "#102030"
        \\wrap = true
        \\[other]
        \\keyword = #000000
    ;
    const s = parse(text);
    try t.expectEqual(@as(f64, 16), s.size);
    try t.expect(!s.wrap);
    try t.expectEqual(Rgb{ 1, 0, 0 }, s.dark.kinds[1]);
    try t.expectEqual(s.dark.fg, s.dark.kinds[0]);
    try t.expectEqual(@as(f64, 0x10) / 255, s.light.kinds[3][0]);
    try t.expectEqual(paper.kinds[1], s.light.kinds[1]);
    try t.expectEqual(@as(u16, 3), s.report.count);
    try t.expectEqual(@as(u32, 5), s.report.first_line);
    try t.expect(parseHex("#12") == null and parseHex("#GGG") == null and parseHex("+12345") == null);
    // New keys go above the sections, so they stay top-level.
    const a = try setLine(t.allocator, text, .pairs, "false");
    defer t.allocator.free(a);
    try t.expect(std.mem.startsWith(u8, a, "size = 16\npairs = false\n\n[dark]\n"));
    try t.expect(!parse(a).pairs);
    const b = try withMissing(t.allocator, text) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(b);
    const back = parse(b);
    try t.expectEqual(s.dark, back.dark);
    try t.expectEqual(s.report.count, back.report.count);
    try t.expect(std.mem.endsWith(u8, b, "\n\n" ++ text[10..]));
}

test "bad values keep their defaults and land in the report" {
    const s = parse("tab-width = 99\nindent-with = wide\ncaret-blink = maybe\nzen-columns = 120\nfocus-dim = 0.1\nnope = 1\nlight-theme = nonsense\n");
    try t.expectEqual(@as(u8, 16), s.tab_width);
    try t.expectEqual(IndentWith.spaces, s.indent_with);
    try t.expect(s.caret_blink);
    try t.expectEqual(@as(u16, 120), s.zen_columns);
    try t.expectEqual(@as(f64, 0.2), s.focus_dim);
    try t.expectEqual(@as(u16, 6), s.report.count);
    try t.expectEqual(@as(u32, 1), s.report.first_line);
    try t.expectEqualStrings("tab-width = 99 is outside 1 to 16", s.report.firstMessage());
    try t.expectEqualStrings("indent-with = \"wide\" isn't one of spaces, tabs", parse("indent-with = wide").report.firstMessage());
}

test "late-night covers the saved look and is written back as a flag" {
    var s = parse("late-night = on\nzen = off\nappearance = light\nlight-theme = paper\nfocus = line\n");
    try t.expect(s.late_night and !s.zen and s.look == .light);
    s.lateNight();
    try t.expect(s.zen and s.typewriter and s.focus == .paragraph and s.look == .dark);
    try t.expectEqual(widen(schemes[comptime schemeIndex("black").?].colors), s.dark);
    const text = try render(t.allocator, &parse("late-night = on\n"));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "late-night = true\n") != null);
}
