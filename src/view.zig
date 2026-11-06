//! The windows: an NSView subclass that draws a sidebar and one or more
//! cards, each a pane with its own tabs, the text in CoreText glyph runs on
//! a monospace grid, and turns key and mouse events into editor commands.
//! A card's bottom line is the prompt for find, go to line, quick open and
//! the command palette.
const std = @import("std");
const objc = @import("objc.zig");
const editor = @import("editor.zig");
const syntax = @import("syntax.zig");
const finder = @import("finder.zig");
const files = @import("files.zig");
const settings = @import("settings.zig");
const tree_mod = @import("tree.zig");
const preview = @import("preview.zig");
const access = @import("access.zig");
const Editor = editor.Editor;
const Id = objc.Id;
const Sel = objc.Sel;
const Rect = objc.Rect;
const Point = objc.Point;
const msg = objc.msg;

pub const gpa = std.heap.c_allocator;
/// The folder quick open lists and the sidebar shows. Owned by gpa.
pub var root: ?[]const u8 = null;
/// The sidebar's rows, shared by every window.
var tree: tree_mod.Tree = .init(gpa);

/// Makes `dir` (owned by gpa) the folder, and shows it in the sidebar.
pub fn setRoot(dir: []const u8) void {
    if (root) |r| gpa.free(r);
    root = dir;
    // The header's folder is written relative to the open folder.
    for (docs.items) |d| dropHead(d);
    for (tree.open.items) |o| gpa.free(o);
    tree.open.clearRetainingCapacity();
    for (wins.items) |w| w.side_y = 0;
    rebuildTree();
    for (wins.items) |w| msg(void, w.window, "invalidateCursorRectsForView:", .{w.view});
    refreshAll();
}

fn rebuildTree() void {
    if (root) |r| tree.rebuild(gpa, r);
    tree_gen +%= 1;
    dropSideLines();
}

/// Counts tree rebuilds, so a window knows when to look up its selected row again.
var tree_gen: u32 = 0;

/// Set while `restoreSession` opens last session's tabs: `install` leaves
/// the folder read and the redraw to one pass at its end, and marks
/// `tree_stale` when the folders need reading again.
var restoring = false;
var tree_stale = false;

/// `p` relative to the folder, when it's inside it.
fn relOf(p: []const u8) ?[]const u8 {
    const r = root orelse return null;
    if (p.len <= r.len + 1 or !std.mem.startsWith(u8, p, r) or p[r.len] != '/') return null;
    return p[r.len + 1 ..];
}

fn refreshAll() void {
    for (docs.items) |d| refresh(d);
}

const shift_key: usize = 1 << 17;
const cmd_key: usize = 1 << 20;
const ctrl_key: usize = 1 << 18;
const opt_key: usize = 1 << 19;

// ---- look ----

const Rgb = settings.Rgb;
const Theme = settings.Theme;

const pad_x = 28.0;
/// The text sits in a card with rounded corners, this far in from the
/// window's edges and the sidebar. The cards' corners nest inside the
/// window's: their radius is the window's less the gap, read from AppKit
/// on each draw (`fitTitlebar`).
const gap = 8.0;
var card_radius: f64 = 18.0;
/// The card's header holds the file's name; the text starts a little below it.
/// Its middle sits on the traffic lights' line, which the window's empty
/// toolbar sets, so `fitTitlebar` measures it.
var head_h: f64 = 36.0;
var top_h: f64 = gap + 36.0 + 6;
/// The sidebar button's center, right of the traffic lights, and where the
/// header's tabs can start without one; both follow the lights.
var toggle_x: f64 = 96.0;
var tabs_from: f64 = 91.0;
/// The sidebar's width, shared by every window and kept in the settings file.
var side_w: f64 = settings.sidebar_default;
/// While the sidebar's edge is dragged past a limit it stretches, `side_stretch`
/// pixels beyond `side_rest`, the width it stretches from; letting go springs
/// it back. Dragging it in past `side_collapse` shuts the sidebar.
var side_stretch: Spring = .{ .k = spring_k, .c = spring_c, .eps = 0.05 };
var side_rest: f64 = settings.sidebar_default;
const side_collapse = 100.0;
/// The most it stretches, and how much of the mouse's travel it follows.
const side_stretch_max = 24.0;
const side_stretch_pull = 0.3;
/// How far either side of the sidebar's edge grabs it.
const edge_grab = 4.0;
/// The sidebar's selection sits this far in from its edges, with rounded corners.
const side_inset = 8.0;
const side_radius = 7.0;
/// The size of a file's icon in the sidebar.
const side_icon = 16.0;

/// The sidebar shows when there's a folder, it's turned on, and the window
/// is wide enough to keep room for the text.
fn sideShown(w: *const Win) bool {
    return !conf.zen and conf.sidebar and root != null and msg(Rect, w.view, "bounds", .{}).w >= side_w + 360;
}

/// A card's right edge in its pane, which it sits a gap inside of.
fn rightEdge(d: *const Doc) f64 {
    return d.size.x - gap;
}

/// From the card's left edge to the text. Zen pads it so an 80-column page
/// sits in the middle of the card.
fn padL(d: *const Doc) f64 {
    const z = std.math.clamp(d.win.z.x, 0, 1);
    return pad_x + (@max(pad_x, (d.size.x - 80 * cw) / 2 - gap) - pad_x) * z;
}

/// Soft wrap is on, or zen wraps at 80 columns.
fn wrapping() bool {
    return conf.wrap or conf.zen;
}

/// Where the text ends: the card's bottom, or the prompt line above it.
fn bottom(d: *const Doc) f64 {
    return d.size.y - gap - if (d.mode == .edit) 0 else barH();
}

/// The window's own color around the card: the theme's background, a
/// step darker. Zen leaves no edge around the card, and z (0..1, the zen
/// spring) eases between the two.
fn chrome(th: *const Theme, dark: bool, z: f64) Rgb {
    const k: f64 = if (dark) 0.78 else 0.955;
    const m = 1 - (1 - k) * (1 - std.math.clamp(z, 0, 1));
    return .{ th.bg[0] * m, th.bg[1] * m, th.bg[2] * m };
}

/// `a` toward `b` by `t`.
fn mixRgb(a: Rgb, b: Rgb, t: f64) Rgb {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

/// How much of the chrome color paints over the sidebar material: the rest
/// shows through. Zen covers the material completely. (The material can't
/// be hidden: Zag's view lives inside it.)
fn chromeAlpha(dark: bool, z: f64) f64 {
    const a: f64 = if (dark) 0.7 else 0.6;
    return a + (1 - a) * std.math.clamp(z, 0, 1);
}

/// Font, size, colors and toggles, from the settings file.
var conf: settings.Settings = .{};
/// The themes that draw: the settings' colors, turned grey in zen.
var themes: [2]Theme = .{ settings.paper, settings.ink };
var conf_path: ?[:0]u8 = null;
var conf_stamp: ?files.Stamp = null;
/// View menu items that show a checkmark, set by the menu builder.
pub var wrap_item: Id = null;
pub var pairs_item: Id = null;
pub var sidebar_item: Id = null;
pub var focus_items: [4]Id = @splat(null);
pub var typewriter_item: Id = null;
pub var zen_item: Id = null;
/// View > Theme items, in `settings.schemes` order.
pub var scheme_items: [settings.schemes.len]Id = @splat(null);
/// View > Theme's Appearance items: Auto, Light, Dark.
pub var look_items: [3]Id = @splat(null);

var font: Id = null;
var bold: Id = null;
var cw: f64 = 8;
var lh: f64 = 22;
var baseline: f64 = 15;
var ascii: [2][95]u16 = undefined;
const Fallback = struct { font: Id, glyph: u16 };
var fallbacks: std.AutoHashMapUnmanaged(u21, Fallback) = .empty;
/// The sidebar's fonts: the system font for file names, a heavier one for
/// the folder's name and the card's header, and a small one for the line
/// above the folder. Rows are `side_h` tall, with the baseline that centers
/// the text in one.
var side_font: Id = null;
var name_font: Id = null;
var head_font: Id = null;
var side_h: f64 = 30;
var side_base: f64 = 19;
/// From the header's middle line down to the baseline of its text.
var name_off: f64 = 4;
/// The header's fonts: tab names regular, the active one medium, with every
/// tab as wide as its medium name so switching never moves a tab; the
/// folder after a lone tab's name small and regular, `path_off` above its
/// baseline like `name_off`.
var tab_font: Id = null;
var tab_bold: Id = null;
var path_font: Id = null;
var path_off: f64 = 3;

fn barH() f64 {
    return lh + 12;
}

/// Loads the font the settings name, or the system monospace font.
fn setFont() void {
    if (font != null) _ = msg(void, font, "release", .{});
    if (bold != null) _ = msg(void, bold, "release", .{});
    const NSFont = objc.class("NSFont");
    font = null;
    bold = null;
    var name: [129:0]u8 = undefined;
    const want = conf.font();
    if (want.len > 0) {
        @memcpy(name[0..want.len], want);
        name[want.len] = 0;
        font = msg(Id, NSFont, "fontWithName:size:", .{ objc.str(name[0..want.len :0]), conf.size });
        if (font != null) bold = msg(Id, msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{}), "convertFont:toHaveTrait:", .{ font, @as(usize, 2) });
    }
    if (font == null or bold == null) {
        font = msg(Id, NSFont, "monospacedSystemFontOfSize:weight:", .{ conf.size, @as(f64, 0) });
        bold = msg(Id, NSFont, "monospacedSystemFontOfSize:weight:", .{ conf.size, @as(f64, 0.3) });
    }
    font = msg(Id, font, "retain", .{});
    bold = msg(Id, bold, "retain", .{});
    var chars: [95]u16 = undefined;
    for (&chars, 0..) |*ch, i| ch.* = @intCast(0x20 + i);
    _ = objc.CTFontGetGlyphsForCharacters(font, &chars, &ascii[0], 95);
    _ = objc.CTFontGetGlyphsForCharacters(bold, &chars, &ascii[1], 95);
    const zero = [1]u16{ascii[0]['0' - 0x20]};
    cw = objc.CTFontGetAdvancesForGlyphs(font, 0, &zero, null, 1);
    const asc = objc.CTFontGetAscent(font);
    const desc = objc.CTFontGetDescent(font);
    lh = @round(conf.size * conf.spacing);
    baseline = @round((lh - asc - desc) / 2 + asc);
    for ([_]*Id{ &side_font, &name_font, &head_font }) |p| if (p.* != null) msg(void, p.*, "release", .{});
    side_font = msg(Id, msg(Id, NSFont, "systemFontOfSize:", .{conf.size - 1}), "retain", .{});
    name_font = msg(Id, msg(Id, NSFont, "systemFontOfSize:weight:", .{ conf.size - 1, @as(f64, 0.3) }), "retain", .{});
    head_font = msg(Id, msg(Id, NSFont, "systemFontOfSize:weight:", .{ conf.size - 3, @as(f64, 0.3) }), "retain", .{});
    side_h = @round((conf.size - 1) * 2.3);
    side_base = @round((side_h - objc.CTFontGetAscent(side_font) - objc.CTFontGetDescent(side_font)) / 2 + objc.CTFontGetAscent(side_font));
    name_off = (objc.CTFontGetAscent(name_font) - objc.CTFontGetDescent(name_font)) / 2;
    for (&tab_dots) |*p| if (p.*) |l| {
        objc.CFRelease(l);
        p.* = null;
    };
    for ([_]*Id{ &tab_font, &tab_bold, &path_font }) |p| if (p.* != null) msg(void, p.*, "release", .{});
    tab_font = msg(Id, msg(Id, NSFont, "systemFontOfSize:weight:", .{ conf.size - 1, @as(f64, 0) }), "retain", .{});
    tab_bold = msg(Id, msg(Id, NSFont, "systemFontOfSize:weight:", .{ conf.size - 1, @as(f64, 0.23) }), "retain", .{});
    path_font = msg(Id, msg(Id, NSFont, "systemFontOfSize:weight:", .{ conf.size - 3, @as(f64, 0) }), "retain", .{});
    path_off = (objc.CTFontGetAscent(path_font) - objc.CTFontGetDescent(path_font)) / 2;
    dropSideLines();
    for (docs.items) |d| dropHead(d);
    var it = fallbacks.valueIterator();
    while (it.next()) |fb| if (fb.font != font) objc.CFRelease(fb.font.?);
    fallbacks.clearRetainingCapacity();
    msg(void, msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{}), "setSelectedFont:isMultiple:", .{ font, false });
}

fn utf16(cp: u21, out: *[2]u16) usize {
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

/// The font and glyph that draw `cp`, falling back to a system font that
/// has it (emoji, CJK).
fn glyph(cp: u21, heavy: bool) Fallback {
    if (cp >= 0x20 and cp < 0x7f) return .{ .font = if (heavy) bold else font, .glyph = ascii[@intFromBool(heavy)][cp - 0x20] };
    var units: [2]u16 = undefined;
    const n = utf16(cp, &units);
    var g: [2]u16 = .{ 0, 0 };
    if (objc.CTFontGetGlyphsForCharacters(font, &units, &g, @intCast(n)) and g[0] != 0) return .{ .font = font, .glyph = g[0] };
    const e = fallbacks.getOrPut(gpa, cp) catch return .{ .font = font, .glyph = 0 };
    if (!e.found_existing) {
        e.value_ptr.* = .{ .font = font, .glyph = 0 };
        const fb = objc.fallbackFont(font, units[0..n]);
        if (fb != null and objc.CTFontGetGlyphsForCharacters(fb, &units, &g, @intCast(n))) {
            e.value_ptr.* = .{ .font = fb, .glyph = g[0] };
        } else if (fb != null) objc.CFRelease(fb.?);
    }
    return e.value_ptr.*;
}

/// Batches glyphs that share a font and color into one draw call.
const Ink = struct {
    ctx: Id,
    font: Id = null,
    color: Rgb = .{ -1, -1, -1 },
    glyphs: [512]u16 = undefined,
    pos: [512]Point = undefined,
    n: usize = 0,
    focus: ?Focus = null,
    offset: usize = 0,
    selected: [2]usize = .{ 0, 0 },

    fn put(k: *Ink, g: Fallback, color: Rgb, x: f64, y: f64) void {
        if (k.n == k.glyphs.len or g.font != k.font or !std.mem.eql(f64, &color, &k.color)) {
            k.flush();
            k.font = g.font;
            k.color = color;
        }
        k.glyphs[k.n] = g.glyph;
        // Positions go through the flipped text matrix too, so y flips back.
        k.pos[k.n] = .{ .x = x, .y = -y };
        k.n += 1;
    }

    fn flush(k: *Ink) void {
        if (k.n == 0) return;
        objc.CGContextSetRGBFillColor(k.ctx, k.color[0], k.color[1], k.color[2], 1);
        objc.CTFontDrawGlyphs(k.font, &k.glyphs, &k.pos, k.n, k.ctx);
        k.n = 0;
    }

    /// Draws `s` from cell `skip` on, at most `max` cells, with its left
    /// edge at `x`. Colors come from `kinds` when given. Returns the cells used.
    fn text(k: *Ink, s: []const u8, kinds: ?[]const syntax.Kind, th: *const Theme, color: Rgb, x: f64, y: f64, skip: usize, max: usize) usize {
        return k.run(s, 0, s.len, 0, kinds, th, color, x, y, skip, max);
    }

    /// Like `text`, for the bytes `from..to` of `s`, which start at display
    /// column `col0` (a wrapped row). `kinds` covers all of `s`.
    fn run(k: *Ink, s: []const u8, from: usize, to: usize, col0: usize, kinds: ?[]const syntax.Kind, th: *const Theme, color: Rgb, x: f64, y: f64, skip: usize, max: usize) usize {
        var col = col0;
        var i = from;
        while (i < to) {
            const c = editor.cells(s, i, col);
            const rel = col - col0;
            if (rel >= skip + max) break;
            if (rel >= skip and s[i] >= 0x20 and s[i] != 0x7f) {
                const cp: u21 = if (s[i] < 0x80) s[i] else editor.decode(s, i).cp;
                const kind: syntax.Kind = if (kinds) |ks| ks[i] else .text;
                var paint = if (kinds != null) th.kinds[@intFromEnum(kind)] else color;
                if (k.focus) |fo| {
                    const at = k.offset + i;
                    if (at < k.selected[0] or at >= k.selected[1]) {
                        const in_new: f64 = if (at >= fo.new[0] and at < fo.new[1]) 1 else 0;
                        const in_old: f64 = if (at >= fo.old[0] and at < fo.old[1]) 1 else 0;
                        const a = 1 - fo.amt * (0.78 - 0.78 * (in_new * fo.t + in_old * (1 - fo.t)));
                        for (&paint, th.bg) |*v, bg| v.* = bg + (v.* - bg) * a;
                    }
                }
                k.put(glyph(cp, kind == .keyword), paint, x + f(rel - skip) * cw, y);
            }
            col += c.w;
            i += c.len;
        }
        return (col - col0) -| skip;
    }
};

/// Focus mode's lit text: the byte range it's fading to, the one it's
/// fading from, and how far along the fade is.
const Focus = struct { new: [2]usize, old: [2]usize, t: f64, amt: f64 };
/// Focus mode fades from one span to the next at an even rate.
const focus_time = 0.25;

fn f(n: usize) f64 {
    return @floatFromInt(n);
}

fn fill(ctx: Id, c: Rgb, x: f64, y: f64, w: f64, h: f64) void {
    fillA(ctx, c, 1, x, y, w, h);
}

fn fillA(ctx: Id, c: Rgb, a: f64, x: f64, y: f64, w: f64, h: f64) void {
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    objc.CGContextFillRect(ctx, .{ .x = x, .y = y, .w = w, .h = h });
}

/// The window's points per device pixel, set at the start of each draw.
var dev_px: f64 = 0.5;

/// One device pixel in points: separators and outlines are this thick.
fn hair() f64 {
    return dev_px;
}

/// A rounded rectangle: the card, the sidebar's selection, the icon tiles.
fn pill(ctx: Id, c: Rgb, a: f64, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const path = objc.CGPathCreateWithRoundedRect(.{ .x = x, .y = y, .w = w, .h = h }, radius, radius, null);
    defer if (path) |p| objc.CFRelease(p);
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    objc.CGContextAddPath(ctx, path);
    objc.CGContextFillPath(ctx);
}

/// The hairline outline of the rounded rectangle `pill` fills: one device
/// pixel thick.
fn ring(ctx: Id, c: Rgb, a: f64, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const t = hair();
    const outer = objc.CGPathCreateWithRoundedRect(.{ .x = x, .y = y, .w = w, .h = h }, radius, radius, null);
    defer if (outer) |p| objc.CFRelease(p);
    const inner = objc.CGPathCreateWithRoundedRect(.{ .x = x + t, .y = y + t, .w = w - 2 * t, .h = h - 2 * t }, radius - t, radius - t, null);
    defer if (inner) |p| objc.CFRelease(p);
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    objc.CGContextAddPath(ctx, outer);
    objc.CGContextAddPath(ctx, inner);
    objc.CGContextEOFillPath(ctx);
}

/// The Mac's Increase Contrast setting: stronger outlines and muted text.
var contrast = false;

/// The ambient shadow under a card, as nine slices cut from one small image
/// drawn once for light and once for dark: black at 0.06 or 0.35, blurred 6
/// points, 1 point down. Stretching the slices costs no blur per frame.
/// The image is `shadow_m` of shadow, `shadow_core` of card, `shadow_m` of
/// shadow, in points, drawn at twice that many pixels.
const shadow_m = 12.0;
const shadow_core = 40.0;
var shadow_cells: [2][9]?*anyopaque = @splat(@splat(null));

/// The nine slices of the card shadow for light or dark, made on first use.
fn shadowCells(dark: bool) *const [9]?*anyopaque {
    const cells = &shadow_cells[@intFromBool(dark)];
    if (cells[0] != null) return cells;
    const side = 2 * (shadow_core + 2 * shadow_m);
    const pixels: usize = @intFromFloat(side);
    const space = objc.CGColorSpaceCreateDeviceRGB();
    defer if (space) |s| objc.CFRelease(s);
    const bm = objc.CGBitmapContextCreate(null, pixels, pixels, 8, 0, space, 1);
    defer if (bm) |b| objc.CFRelease(b);
    const m = 2 * shadow_m;
    const core = 2 * shadow_core;
    const path = objc.CGPathCreateWithRoundedRect(.{ .x = m, .y = m, .w = core, .h = core }, 2 * card_radius, 2 * card_radius, null);
    defer if (path) |p| objc.CFRelease(p);
    // Draw the card's shape with its shadow, then clear the shape again so
    // only the shadow stays and the card's own edge isn't darkened.
    objc.CGContextSaveGState(bm);
    const col = objc.CGColorCreateGenericGray(0, if (dark) 0.35 else 0.06);
    defer if (col) |cc| objc.CFRelease(cc);
    objc.CGContextSetShadowWithColor(bm, .{ .w = 0, .h = -2 }, 12, col);
    objc.CGContextSetRGBFillColor(bm, 0, 0, 0, 1);
    objc.CGContextAddPath(bm, path);
    objc.CGContextFillPath(bm);
    objc.CGContextRestoreGState(bm);
    objc.CGContextSetBlendMode(bm, 16);
    objc.CGContextAddPath(bm, path);
    objc.CGContextFillPath(bm);
    const img = objc.CGBitmapContextCreateImage(bm);
    defer if (img) |i| objc.CFRelease(i);
    // Image rows run top down; the corners are `m + radius` pixels wide.
    const edge = m + 2 * card_radius;
    const cuts = [4]f64{ 0, edge, side - edge, side };
    for (0..3) |r| for (0..3) |c| {
        cells[r * 3 + c] = objc.CGImageCreateWithImageInRect(img, .{ .x = cuts[c], .y = cuts[r], .w = cuts[c + 1] - cuts[c], .h = cuts[r + 1] - cuts[r] });
    };
    return cells;
}

/// Draws the card shadow around the card at `x`, `y`, `w` by `h` at
/// `alpha`. The slices of the card's corners keep their size and the middle
/// ones stretch.
fn cardShadow(ctx: Id, dark: bool, alpha: f64, x: f64, y: f64, w: f64, h: f64) void {
    const edge = shadow_m + card_radius;
    if (w < 2 * card_radius or h < 2 * card_radius) return;
    const cells = shadowCells(dark);
    const xs = [4]f64{ x - shadow_m, x - shadow_m + edge, x + w + shadow_m - edge, x + w + shadow_m };
    const ys = [4]f64{ y - shadow_m, y - shadow_m + edge, y + h + shadow_m - edge, y + h + shadow_m };
    objc.CGContextSaveGState(ctx);
    objc.CGContextSetAlpha(ctx, alpha);
    for (0..3) |r| for (0..3) |c| {
        const dw = xs[c + 1] - xs[c];
        const dh = ys[r + 1] - ys[r];
        objc.CGContextSaveGState(ctx);
        // The view is flipped and images draw upside down in a flipped
        // context, so flip the slice back.
        objc.CGContextTranslateCTM(ctx, xs[c], ys[r + 1]);
        objc.CGContextScaleCTM(ctx, 1, -1);
        objc.CGContextDrawImage(ctx, .{ .w = dw, .h = dh }, cells[r * 3 + c]);
        objc.CGContextRestoreGState(ctx);
    };
    objc.CGContextRestoreGState(ctx);
}

/// Limits drawing to a rounded rectangle until the state is restored.
fn clipRound(ctx: Id, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const path = objc.CGPathCreateWithRoundedRect(.{ .x = x, .y = y, .w = w, .h = h }, radius, radius, null);
    defer if (path) |p| objc.CFRelease(p);
    objc.CGContextAddPath(ctx, path);
    objc.CGContextClip(ctx);
}

fn nscolor(c: Rgb) Id {
    return msg(Id, objc.class("NSColor"), "colorWithDeviceRed:green:blue:alpha:", .{ c[0], c[1], c[2], @as(f64, 1) });
}

// ---- motion ----

extern fn CACurrentMediaTime() f64;
extern const NSRunLoopCommonModes: Id;

/// A value that eases from where it is to a new target over `dur` seconds.
/// A display link redraws while any of them move.
///
/// The curve is a cubic from `from` at speed `v0` to `to` at rest. From rest
/// it starts at three times the average speed, which is ease-out cubic. A new
/// target mid-glide keeps the current speed, so held keys don't stutter.
const Tween = struct {
    from: f64 = 0,
    to: f64 = 0,
    t0: f64 = 0,
    v0: f64 = 0,
    dur: f64,

    fn at(w: Tween, now: f64) f64 {
        const s = std.math.clamp((now - w.t0) / w.dur, 0, 1);
        const s2 = s * s;
        const s3 = s2 * s;
        return (2 * s3 - 3 * s2 + 1) * w.from + (s3 - 2 * s2 + s) * w.dur * w.v0 + (3 * s2 - 2 * s3) * w.to;
    }

    fn speed(w: Tween, now: f64) f64 {
        if (!w.moving(now)) return 0;
        const s = std.math.clamp((now - w.t0) / w.dur, 0, 1);
        const s2 = s * s;
        return (6 * s - 6 * s2) * (w.to - w.from) / w.dur + (3 * s2 - 4 * s + 1) * w.v0;
    }

    fn aim(w: *Tween, to: f64, now: f64) void {
        if (to == w.to) return;
        const v = w.speed(now);
        w.from = w.at(now);
        w.to = to;
        w.t0 = now;
        const ease = 3 * (to - w.from) / w.dur;
        // Slower than ease-out keeps its speed and picks up smoothly, and the
        // other way it turns around; faster is capped so it doesn't overshoot.
        w.v0 = if (v == 0 or ((v > 0) == (ease > 0) and @abs(v) > @abs(ease))) ease else v;
    }

    fn snap(w: *Tween, to: f64) void {
        w.from = to;
        w.to = to;
        w.v0 = 0;
    }

    /// Moves the whole glide by `by`, so it keeps its place on screen when the
    /// page under it jumps.
    fn shift(w: *Tween, by: f64) void {
        w.from += by;
        w.to += by;
    }

    fn moving(w: Tween, now: f64) bool {
        return w.from != w.to and now < w.t0 + w.dur;
    }
};

const scroll_time = 0.16;
/// The header turning from a file's name into tabs and back.
const tab_time = 0.22;

/// A value that springs to its target, overshooting a little before it
/// settles, for motion that should feel playful: a tab popping in, the
/// active tab's highlight hopping over.
const Spring = struct {
    x: f64 = 0,
    v: f64 = 0,
    to: f64 = 0,
    t: f64 = 0,
    k: f64 = 300,
    c: f64 = 24,
    /// Close enough to call it settled.
    eps: f64 = 0.002,

    fn aim(s: *Spring, to: f64, now: f64) void {
        if (s.settled()) s.t = now;
        s.to = to;
    }

    fn snap(s: *Spring, to: f64) void {
        s.x = to;
        s.to = to;
        s.v = 0;
    }

    /// Moves it on to `now` and returns where it is.
    fn step(s: *Spring, now: f64) f64 {
        var dt = std.math.clamp(now - s.t, 0, 1.0 / 20.0);
        s.t = now;
        while (dt > 0) {
            const h = @min(dt, 1.0 / 240.0);
            dt -= h;
            s.v += (-s.k * (s.x - s.to) - s.c * s.v) * h;
            s.x += s.v * h;
        }
        if (s.settled()) s.snap(s.to);
        return s.x;
    }

    fn settled(s: Spring) bool {
        return @abs(s.x - s.to) < s.eps and @abs(s.v) < s.eps * 10;
    }
};

/// A tab in the header as drawn. It pops in, and when its file goes it
/// stays to fold shut.
const Slot = struct {
    id: u32,
    /// 0 to 1 with a little bounce on the way in; its width follows, and its
    /// icon and name grow from 0.92 to full size on it.
    grow: Spring = .{ .k = 280, .c = 25 },
    hov: Tween = .{ .dur = fade_time },
    /// The close button's square, fading in while the mouse is over the ×.
    xhov: Tween = .{ .dur = fade_time },
    /// The unsaved dot, 0 to 1: it grows in with a little bounce and
    /// shrinks away as it fades.
    dot: Spring = .{ .k = 420, .c = 22 },
    /// Its file's name in medium, which sets its width, and in regular for
    /// while it isn't the active tab, made on first draw.
    line: Id = null,
    thin: Id = null,
    /// The names cut short with an ellipsis to `cut_w`, when the tab is squeezed.
    cut: Id = null,
    thin_cut: Id = null,
    cut_w: f64 = -1,
    /// Its file kind's icon, from `iconFor`.
    icon: Id = null,
    gone: bool = false,
    /// Where it last laid out, before `shift`.
    x: f64 = 0,
    w: f64 = 0,
    /// Its name's width, springing to a new name's instead of jumping.
    wid: Spring = .{ .k = 420, .c = 34, .eps = 0.05 },
    sized: bool = false,
    /// How far it's drawn from where it lays out: it slides into a new
    /// place after the tabs reorder, and follows the mouse while dragged.
    shift: Spring = .{ .k = 420, .c = 30, .eps = 0.05 },
    /// Where it was drawn when the tabs reordered, to slide from.
    flip: ?f64 = null,

    fn drop(s: *Slot) void {
        for ([_]*Id{ &s.line, &s.thin, &s.cut, &s.thin_cut }) |p| if (p.*) |l| {
            objc.CFRelease(l);
            p.* = null;
        };
        s.cut_w = -1;
    }
};

/// The caret's glide: `caret_time` for a step, longer for a long jump, up
/// to `caret_max`. Shorter than 0.09 s reads as a jump at 120 Hz (zag#me3c).
const caret_time = 0.09;
const caret_max = 0.14;
const fade_time = 0.12;
const panel_time = 0.14;
/// A button's fill after a click fades this slowly once the mouse lets go.
const press_time = 0.15;
/// The outline on a right-clicked row or tab fades in and out this slowly,
/// so it reads as easing off rather than blinking.
const menu_time = 0.24;
/// The sidebar slides in and out, and the card's left edge rides with it.
const slide_time = 0.24;
/// A file freshly read from disk fades in over this long, rising this far.
/// A tab switch just fades from `swap_from`, over `fade_time`, with no rise.
const load_time = 0.18;
const load_rise = 6.0;
const swap_from = 0.35;
/// The scroll bar stays a second after the page stops, then fades. It
/// arrives over `bar_in` and leaves over `bar_time`.
const bar_hold = 1.0;
const bar_in = 0.08;
const bar_time = 0.25;
/// The prompt band slides up over `panel_time` and down over `band_out`;
/// its words rise `words_lag` after the band starts.
const band_out = 0.12;
const words_lag = 0.03;
/// "No matches" shakes the prompt's words, and a refused split its card,
/// this long.
const shake_time = 0.3;
/// An empty window's hint appears after `hint_delay`, over `hint_in`, and
/// leaves over `fade_time`.
const hint_delay = 0.4;
const hint_in = 0.3;
const hint_alpha = 0.6;
const bar_w = 7.0;
const bar_alpha = 0.45;
/// Keyboard scrolls this many rows or fewer (stepping past the edge) snap.
const glide_rows = 3;

/// Aims the caret. A new spot glides there; a caret that was hidden, a
/// mouse drag, or the same spot somewhere new (the text moved under it)
/// snaps. A redraw with the caret where it's going leaves its glide alone.
/// In the text the caret lives in page coordinates, so it rides along with
/// a gliding scroll.
fn placeCaret(d: *Doc, now: f64, x: f64, y: f64, in_text: bool, spot: [3]usize, show: bool) void {
    const moved = !std.mem.eql(usize, &spot, &d.spot);
    if (in_text != d.c_text) {
        const sign: f64 = if (in_text) 1 else -1;
        d.cx.snap(d.cx.at(now) + sign * d.vx);
        d.cy.snap(d.cy.at(now) + sign * d.vy);
        d.c_text = in_text;
    }
    if (moved and d.shown and show and !d.snap) {
        const glide = glideTime(x - d.cx.to, y - d.cy.to);
        d.cx.dur = glide;
        d.cy.dur = if (conf.typewriter and in_text) scroll_time else glide;
        d.cx.aim(x, now);
        d.cy.aim(y, now);
    } else if (moved or !d.shown or !show or d.snap or d.cx.to != x or d.cy.to != y) {
        d.cx.snap(x);
        d.cy.snap(y);
    }
    if (show and (moved or !d.shown)) blink(d.caret);
    d.spot = spot;
    d.shown = show;
    d.snap = false;
    moveCaret(d, now);
}

/// How long the caret takes to glide by (`dx`, `dy`): longer jumps take a
/// little longer so they read as travel.
fn glideTime(dx: f64, dy: f64) f64 {
    return std.math.clamp(caret_time + 0.025 * @log2(1 + @sqrt(dx * dx + dy * dy) / lh), caret_time, caret_max);
}

/// Puts the caret layer where its glide is at `now`, hidden outside the text.
fn moveCaret(d: *Doc, now: f64) void {
    var x = d.cx.at(now);
    var y = d.cy.at(now);
    if (d.c_text) {
        x -= d.vx;
        y -= d.vy;
    }
    const visible = d.shown and (!d.c_text or (x >= gap + padL(d) - 2 and x < rightEdge(d) and y >= top_h - 2 and y + lh - 4 <= bottom(d)));
    const frame = Rect{ .x = d.org.x + x, .y = d.org.y + y, .w = 2, .h = lh - 4 };
    if (d.caret_at) |was| if (std.meta.eql(was, frame) and d.caret_off == !visible) return;
    d.caret_at = frame;
    d.caret_off = !visible;
    const t = objc.class("CATransaction");
    msg(void, t, "begin", .{});
    msg(void, t, "setDisableActions:", .{true});
    msg(void, d.caret, "setFrame:", .{frame});
    msg(void, d.caret, "setHidden:", .{!visible});
    msg(void, t, "commit", .{});
}

var fade_anim: Id = null;
var blink_anim: Id = null;

/// Fades the layer in from clear over `dur`, as an opacity animation.
/// The animation is made once; adding it copies it.
fn fadeIn(layer: Id, dur: f64) void {
    if (fade_anim == null) {
        const num = objc.class("NSNumber");
        const a = msg(Id, objc.class("CABasicAnimation"), "animationWithKeyPath:", .{objc.str("opacity")});
        msg(void, a, "setFromValue:", .{msg(Id, num, "numberWithDouble:", .{@as(f64, 0)})});
        msg(void, a, "setToValue:", .{msg(Id, num, "numberWithDouble:", .{@as(f64, 1)})});
        fade_anim = msg(Id, a, "retain", .{});
    }
    msg(void, fade_anim, "setDuration:", .{dur});
    msg(void, layer, "addAnimation:forKey:", .{ fade_anim, objc.str("fade") });
}

/// Holds the caret solid for half a second, then fades it out, rests it
/// dark, and fades it back in, once a second. The animation is made once.
fn blink(caret: Id) void {
    if (blink_anim == null) {
        const num = objc.class("NSNumber");
        const arr = objc.class("NSArray");
        const levels = [_]f64{ 1, 1, 0, 0, 1 };
        const times = [_]f64{ 0, 0.5, 0.62, 0.9, 1 };
        var values: [5]Id = undefined;
        var stops: [5]Id = undefined;
        for (levels, times, &values, &stops) |lv, tm, *v, *s| {
            v.* = msg(Id, num, "numberWithDouble:", .{lv});
            s.* = msg(Id, num, "numberWithDouble:", .{tm});
        }
        const fn_class = objc.class("CAMediaTimingFunction");
        const eases = [_][:0]const u8{ "linear", "easeIn", "linear", "easeOut" };
        var curves: [4]Id = undefined;
        for (eases, &curves) |name, *c| c.* = msg(Id, fn_class, "functionWithName:", .{objc.str(name)});
        const a = msg(Id, objc.class("CAKeyframeAnimation"), "animationWithKeyPath:", .{objc.str("opacity")});
        msg(void, a, "setValues:", .{msg(Id, arr, "arrayWithObjects:count:", .{ &values, @as(usize, 5) })});
        msg(void, a, "setKeyTimes:", .{msg(Id, arr, "arrayWithObjects:count:", .{ &stops, @as(usize, 5) })});
        msg(void, a, "setTimingFunctions:", .{msg(Id, arr, "arrayWithObjects:count:", .{ &curves, @as(usize, 4) })});
        msg(void, a, "setDuration:", .{@as(f64, 1)});
        msg(void, a, "setRepeatCount:", .{std.math.inf(f32)});
        blink_anim = msg(Id, a, "retain", .{});
    }
    msg(void, caret, "addAnimation:forKey:", .{ blink_anim, objc.str("blink") });
}

const max_flash = 64;
const flash_alpha = 0.28;
const flash_hold = 0.1;
const flash_time = 0.45;

/// Clears the flash and starts a new one now; add its spans with `flashAdd`.
fn flashStart(d: *Doc) void {
    d.flash_n = 0;
    d.flash_t0 = CACurrentMediaTime();
}

/// Adds the bytes `lo..hi` of the text to the flash, up to `max_flash` spans.
fn flashAdd(d: *Doc, lo: usize, hi: usize) void {
    if (lo >= hi or d.flash_n == max_flash) return;
    d.flash[d.flash_n] = .{ lo, hi };
    d.flash_n += 1;
}

/// The flash's opacity at `now`: held, then easing out.
fn flashAlpha(d: *const Doc, now: f64) f64 {
    const age = now - d.flash_t0;
    if (d.flash_n == 0 or age >= flash_hold + flash_time) return 0;
    if (age < flash_hold) return flash_alpha;
    const rest = 1 - (age - flash_hold) / flash_time;
    return flash_alpha * rest * rest;
}

const find_light: Rgb = .{ @as(f64, 0xF7) / 255.0, @as(f64, 0xD4) / 255.0, @as(f64, 0x4C) / 255.0 };
const find_dark: Rgb = .{ @as(f64, 0xE8) / 255.0, @as(f64, 0xB8) / 255.0, @as(f64, 0x4A) / 255.0 };
const find_ink: Rgb = .{ @as(f64, 0x1A) / 255.0, @as(f64, 0x1A) / 255.0, @as(f64, 0x1A) / 255.0 };
/// Other find matches are drawn at this opacity.
const match_alpha = 0.55;
/// The nearest match fades in first; each row of distance waits this long, up to the cap.
const stag_row = 0.008;
const stag_cap = 0.12;
/// A new current match starts its pop at this speed: it peaks near 1.14.
const pop_kick = 6.0;

/// Draws the find indicator over row `sg` of line `l` (which starts at byte
/// `ls`): bytes `m` of the file as an opaque pill with its glyphs redrawn
/// dark, grown by `scale` about its center and `a` opaque.
fn pillOver(k: *Ink, th: *const Theme, dark: bool, l: []const u8, ls: usize, sg: Seg, m: [2]usize, ox: f64, skip: usize, y: f64, scale: f64, a: f64) void {
    if (m[0] > ls + l.len or m[1] <= ls) return;
    const lo = std.math.clamp(@max(m[0], ls) - ls, sg.start, sg.end);
    const hi = std.math.clamp(@min(m[1], ls + l.len) - ls, sg.start, sg.end);
    if (lo >= hi) return;
    const col = colAt(l, sg.start, sg.col, lo);
    const x0 = ox + (f(col - sg.col) - f(skip)) * cw;
    const x1 = ox + (f(colAt(l, sg.start, sg.col, hi) - sg.col) - f(skip)) * cw;
    const ctx = k.ctx;
    k.flush();
    objc.CGContextSaveGState(ctx);
    const cx = (x0 + x1) / 2;
    const cy = y + lh / 2;
    if (scale != 1) {
        objc.CGContextTranslateCTM(ctx, cx, cy);
        objc.CGContextScaleCTM(ctx, scale, scale);
        objc.CGContextTranslateCTM(ctx, -cx, -cy);
    }
    pill(ctx, if (dark) find_dark else find_light, a, x0 - 2, y + 1, x1 - x0 + 4, lh - 2, 3);
    var ink: Rgb = undefined;
    for (&ink, th.fg, find_ink) |*c, fg, dk| c.* = fg + (dk - fg) * a;
    const was = k.focus;
    k.focus = null;
    _ = k.run(l, lo, hi, col, null, th, ink, x0, y + baseline, 0, 1 << 16);
    k.flush();
    k.focus = was;
    objc.CGContextRestoreGState(ctx);
}

/// A tap on a Force Touch trackpad, felt only while a finger presses it:
/// `.alignment` when something snaps or hits a limit, `.level` when a drag
/// crosses into a new kind of drop. It lands with the next frame. Never for
/// typing, clicks or scrolling.
fn haptic(kind: enum { alignment, level }) void {
    const p = msg(Id, objc.class("NSHapticFeedbackManager"), "defaultPerformer", .{});
    const pattern: isize = switch (kind) {
        .alignment => 1,
        .level => 2,
    };
    msg(void, p, "performFeedbackPattern:performanceTime:", .{ pattern, @as(usize, 2) });
}

/// How long the file on show fades in: a fresh one rises slower than a tab switch.
fn loadDur(d: *const Doc) f64 {
    return if (d.rise) load_time else fade_time;
}

/// True while scrolling, the line band, a selection fade or the quick open
/// list still has frames to draw.
fn scenery(d: *const Doc, now: f64) bool {
    const stretched = d.relax and (d.ov[0] != 0 or d.ov[1] != 0);
    return stretched or d.ys.moving(now) or d.xs.moving(now) or d.band.moving(now) or d.band_a.moving(now) or now < d.focus_t0 + focus_time or d.focus_a.moving(now) or d.panel.moving(now) or d.lit.moving(now) or
        d.inked.moving(now) or
        d.prompt_t.moving(now) or d.pbar.moving(now) or now < d.shake_t0 + shake_time or now < d.card_shake_t0 + shake_time or d.hint.moving(now) or (d.blank_t0 >= 0 and now < d.blank_t0 + hint_delay) or
        d.plus_t.moving(now) or !d.pick_s.settled() or tabsMoving(d, now) or
        (d.pick_live and (now < d.rows_t0 + row_lag * 5 + row_fade or now < d.pick_t0 + xfade_time)) or
        !d.pop.settled() or now < d.prev_t0 + fade_time or now < d.stag_t0 + stag_cap + fade_time or (d.flash_n > 0 and now < d.flash_t0 + flash_hold + flash_time) or
        now < d.load_t + loadDur(d) or (d.had_sel and now < d.sel_t0 + fade_time) or d.bar.moving(now) or
        d.sel_out.moving(now) or
        now < d.fresh_t0 + fade_time;
}

const spring_k = 380.0;
const spring_c = 33.0;
/// AppKit's rubber band: the stretch grows at this share of finger travel,
/// less as it nears its limit.
const band_c = 0.55;
/// The top and bottom stretch stays under this many lines.
const band_lines = 3;

/// Moves the stretch back to rest with a damped spring; settled values snap to 0.
fn springBack(d: *Doc, now: f64) void {
    var dt = @min(now - d.ov_t, 1.0 / 20.0);
    d.ov_t = now;
    if (!d.relax) return;
    while (dt > 0) {
        const h = @min(dt, 1.0 / 240.0);
        dt -= h;
        for (&d.ov, &d.ov_v) |*o, *v| {
            v.* += (-spring_k * o.* - spring_c * v.*) * h;
            o.* += v.* * h;
        }
    }
    for (&d.ov, &d.ov_v) |*o, *v| if (@abs(o.*) < 0.25 and @abs(v.*) < 4) {
        o.* = 0;
        v.* = 0;
    };
}

/// Applies a trackpad delta to one axis: inside the page it follows the
/// fingers exactly, past an end it stretches with resistance, never as far
/// as `dim`.
fn pull(pos: *f64, o: *f64, delta: f64, lo: f64, hi: f64, dim: f64) void {
    const most = dim * 0.95;
    var rest = delta;
    if (o.* != 0) {
        const room = 1 - @abs(o.*) / dim;
        const k = band_c * room * room;
        const moved = rest * k;
        if (o.* * moved >= 0 or @abs(moved) < @abs(o.*)) {
            o.* = std.math.clamp(o.* + moved, -most, most);
            return;
        }
        rest += o.* / k;
        o.* = 0;
    }
    pos.* += rest;
    if (pos.* < lo) {
        o.* = @max((pos.* - lo) * band_c, -most);
        pos.* = lo;
    } else if (pos.* > hi) {
        o.* = @min((pos.* - hi) * band_c, most);
        pos.* = hi;
    }
}

/// Redraws the window's sidebar strip alone.
fn redrawSide(w: *Win) void {
    msg(void, w.view, "setNeedsDisplayInRect:", .{Rect{ .w = side_w, .h = msg(Rect, w.view, "bounds", .{}).h }});
}

/// Whether the sidebar button sits in the sidebar's strip: the sidebar
/// fully shown and wide enough to hold it. Otherwise it's over the cards.
fn toggleInSide(shown: bool, slid: f64) bool {
    return shown and slid >= 1 and toggle_x + 14 <= side_w;
}

/// Redraws for a change of the hot button (`hot` has its old and new bits
/// or'd): the strip alone when every button involved is in it, else the window.
fn redrawHot(w: *Win, hot: u8) void {
    const shown = sideShown(w);
    const slid = w.side_a.at(CACurrentMediaTime());
    if (shown and slid >= 1 and (hot & 1 == 0 or toggleInSide(shown, slid))) return redrawSide(w);
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// Display link callback: redraws while the scenery moves, otherwise just
/// moves the carets, and pauses once everything has settled.
fn tick(self: Id, _: Sel, _: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    const now = CACurrentMediaTime();
    if (w.busy) {
        if (w.part) {
            for (docs.items) |d| if (d.win == w) moveCaret(d, now);
            return redrawSide(w);
        }
        return msg(void, self, "setNeedsDisplay:", .{true});
    }
    var gliding = false;
    for (docs.items) |d| if (d.win == w) {
        moveCaret(d, now);
        if (d.cx.moving(now) or d.cy.moving(now)) gliding = true;
    };
    if (!gliding) msg(void, w.link, "setPaused:", .{true});
}

/// The scroll bar's hold is over: one redraw, and the fade out takes it from there.
fn barHold(self: Id, _: Sel, _: Id) callconv(.c) void {
    msg(void, self, "setNeedsDisplay:", .{true});
}

/// Whether two rectangles overlap.
fn hits(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

// ---- documents ----

const Mode = enum { edit, find, line, open, replace, command };
const Drag = enum { char, word, line };

/// A file a window holds but isn't showing: its other tabs, edits and all.
const Page = struct {
    ed: Editor,
    path: ?[:0]u8,
    lang: *const syntax.Lang,
    stamp: ?files.Stamp,
    sx: f64,
    sy: f64,
    /// Its tab's id, which stays with the file while the window holds it.
    id: u32,
    /// An untitled file's draft, saved as it changes, and the
    /// `buf.changes` it last saved.
    draft: ?[:0]u8 = null,
    drafted: u64 = 0,
    /// Just read from disk, so showing it rises in; set by the loaders.
    fresh: bool = false,
    /// Its sidebar row's unsaved dot, 0 to 1.
    dot: Tween = .{ .dur = fade_time },

    /// Closing its tab: an untitled file's draft goes too.
    fn deinit(p: *Page) void {
        p.ed.deinit(gpa);
        if (p.path) |s| gpa.free(s);
        dropDraft(&p.draft);
    }
};

/// Tabs, pages and windows get ids from here.
var next_id: u32 = 1;

fn newId() u32 {
    next_id += 1;
    return next_id;
}

const Doc = struct {
    ed: Editor,
    /// The file on show's tab, and where it sits among the window's tabs:
    /// `pages` are the others, in tab order with this one taken out.
    id: u32 = 0,
    at: usize = 0,
    /// The header's tabs as drawn, folding ones included, and the active
    /// tab's highlight (x and width), which springs from tab to tab.
    slots: std.ArrayList(Slot) = .empty,
    hl: [2]Spring = @splat(.{ .k = 420, .c = 30, .eps = 0.05 }),
    /// 1 with two tabs or more, 0 with one, when the header is just the file's name.
    tabbed: Tween = .{ .dur = tab_time },
    /// How far the tabs are scrolled when they don't fit.
    tab_x: Tween = .{ .dur = scroll_time },
    slots_seen: bool = false,
    /// The tab under the mouse, and whether it's over its close button.
    hover: u32 = 0,
    hover_x: bool = false,
    /// A gap opening among the tabs for a tab dragged over them: before
    /// which tab, how wide, how far open, and how wide it drew last.
    open_at: usize = 0,
    open_w: f64 = 0,
    opening: Spring = .{ .k = 420, .c = 30, .eps = 0.01 },
    open_px: f64 = 0,
    /// Where the + after the tabs last drew.
    plus_x: f64 = -100,
    /// The mouse is on that +, and its hover highlight.
    plus_on: bool = false,
    plus_t: Tween = .{ .dur = fade_time },
    /// A click on the +: its fill shows at once and fades after the release.
    plus_down: Tween = .{ .dur = press_time },
    /// Absolute path, or null while untitled.
    path: ?[:0]u8 = null,
    /// Its sidebar row's unsaved dot, 0 to 1; goes with the file between pages.
    dot: Tween = .{ .dur = fade_time },
    /// While untitled, where its draft is kept; see `Page.draft`.
    draft: ?[:0]u8 = null,
    drafted: u64 = 0,
    lang: *const syntax.Lang = &syntax.plain,
    /// The window it's a card in, and that window's NSWindow and view.
    win: *Win = undefined,
    window: Id = null,
    view: Id = null,
    /// The card's pane in the view: where it is now, its size now, and the
    /// size it's headed for, which wrapping uses. The card sits a gap in
    /// from the pane's edges, so it draws in its pane's coordinates.
    org: Point = .{},
    size: Point = .{},
    fin: Point = .{},
    /// 1 while the card takes typing in a window with others, for its ring.
    lit: Tween = .{ .dur = tab_time },
    /// 1 while the card is the key window's focus, for its header and prompt ink.
    inked: Tween = .{ .dur = tab_time },
    /// Folding away after its last tab closed.
    closing: bool = false,
    /// When a refused split last shook this card.
    card_shake_t0: f64 = -1,
    /// Where scrolling is headed; vx and vy are where it shows right now.
    sx: f64 = 0,
    sy: f64 = 0,
    vx: f64 = 0,
    vy: f64 = 0,
    /// Typewriter mode last centered on this caret offset and text height.
    center_at: usize = std.math.maxInt(usize),
    center_h: f64 = 0,
    xs: Tween = .{ .dur = scroll_time },
    ys: Tween = .{ .dur = scroll_time },
    /// The caret line's band, in page coordinates.
    band: Tween = .{ .dur = caret_time },
    band_on: bool = false,
    /// The band's opacity: it fades out while a prompt is open.
    band_a: Tween = .{ .dur = panel_time, .from = 1, .to = 1 },
    /// Focus mode's lit span, the one it's fading from, and when the fade began.
    focus_new: [2]usize = .{ 0, 0 },
    focus_old: [2]usize = .{ 0, 0 },
    focus_t0: f64 = 0,
    /// How much of the dimming shows: 0 with Focus off, 1 with it on.
    focus_a: Tween = .{ .dur = focus_time },
    focus_on: bool = false,
    had_sel: bool = false,
    sel_t0: f64 = 0,
    /// The selection as last drawn and the buffer's change count then: when the
    /// selection collapses with the text untouched, `sel_last` fades out on
    /// `sel_out` (1 to 0) instead of cutting.
    sel_last: [2]usize = .{ 0, 0 },
    sel_chg: u64 = 0,
    sel_out: Tween = .{ .dur = fade_time, .from = 0, .to = 0 },
    /// Height of the quick open list.
    panel: Tween = .{ .dur = panel_time },
    /// The quick open list's picked row highlight, which springs from row to
    /// row once the list is up.
    pick_s: Spring = .{ .k = 520, .c = 34, .eps = 0.05 },
    pick_live: bool = false,
    /// When the list opened (its first rows stagger in), the picks shown
    /// before the last typing, and when the picks last changed.
    rows_t0: f64 = 0,
    prev_picks: [10]usize = undefined,
    prev_n: usize = 0,
    /// Whether those last picks were none, so "No matches" was on show.
    prev_none: bool = false,
    pick_t0: f64 = -1,
    /// The prompt line's words, rising in as it opens.
    prompt_t: Tween = .{ .dur = panel_time },
    prompt_on: bool = false,
    /// The prompt's band, sliding up from the card's bottom (0 hidden, 1 in
    /// place), and when it began opening. What it showed is kept in `held_*`
    /// so it keeps drawing as it slides away.
    pbar: Tween = .{ .dur = panel_time },
    pbar_t0: f64 = 0,
    held: std.ArrayList(u8) = .empty,
    held_with: std.ArrayList(u8) = .empty,
    held_mode: Mode = .find,
    held_id: u32 = 0,
    held_which: u1 = 0,
    held_tally: [64]u8 = undefined,
    held_n: usize = 0,
    /// Find has no matches, and when its words last shook for it.
    nomatch: bool = false,
    shake_t0: f64 = -1,
    /// The scroll bar's opacity, when the page last moved, and where it was.
    bar: Tween = .{ .dur = bar_time },
    bar_t0: f64 = 0,
    bar_vy: f64 = 0,
    cx: Tween = .{ .dur = caret_time },
    cy: Tween = .{ .dur = caret_time },
    /// The caret tween is in page coordinates (else window coordinates).
    c_text: bool = true,
    /// The last draw had scenery still moving.
    busy: bool = false,
    /// How far a trackpad stretched the page past its ends in pixels (x, y;
    /// negative before the top or left edge), and how fast it springs back.
    ov: [2]f64 = .{ 0, 0 },
    ov_v: [2]f64 = .{ 0, 0 },
    ov_t: f64 = 0,
    /// Fingers are off the pad, so the stretch springs back.
    relax: bool = false,
    /// Soft wrap: the first screen row of each line, plus the total at the
    /// end, for rows `cols` cells wide.
    vfirst: std.ArrayList(u32) = .empty,
    cols: usize = 0,
    /// The file's change time and size when Zag last read or wrote it.
    stamp: ?files.Stamp = null,
    mode: Mode = .edit,
    prompt: std.ArrayList(u8) = .empty,
    /// Find and replace: the replacement, and which field takes typing.
    with: std.ArrayList(u8) = .empty,
    which: u1 = 0,
    /// The prompt still shows its starting text; typing replaces it.
    fresh: bool = false,
    /// That selection's band as last drawn, for fading out: its width, whether
    /// it was showing, and when it began to fade.
    fresh_w: f64 = 0,
    fresh_shown: bool = false,
    fresh_t0: f64 = 0,
    /// The last find, for find next and previous.
    query: std.ArrayList(u8) = .empty,
    /// Where the caret was when find opened.
    origin: usize = 0,
    /// The find indicator: the current match's span as last drawn, the span
    /// it is fading out of and when that began, and a find jump just made.
    cur_m: ?[2]usize = null,
    prev_m: [2]usize = .{ 0, 0 },
    prev_t0: f64 = -1e9,
    jumped: bool = false,
    /// The current match pill's pop: scale is 1 plus this, kicked on arrival.
    pop: Spring = .{ .k = 600, .c = 22, .eps = 0.01 },
    /// Find is open and drawn, and when the other matches began fading in.
    find_seen: bool = false,
    stag_t0: f64 = -1e9,
    /// Ranges to flash behind after undo, redo, Replace All or a big paste.
    flash: [max_flash][2]usize = undefined,
    flash_n: usize = 0,
    flash_t0: f64 = 0,
    found: [2]usize = .{ 0, 0 },
    list: ?finder.Files = null,
    picks: [10]usize = undefined,
    npicks: usize = 0,
    pick: usize = 0,
    /// The list shows menu commands (⌘K) rather than files.
    palette: bool = false,
    /// A word for the status bar, cleared by the next key or click.
    note: []const u8 = "",
    drag: Drag = .char,
    drag_from: [2]usize = .{ 0, 0 },
    /// Syntax state at the start of each line, known for this many lines.
    states: std.ArrayList(syntax.State) = .empty,
    /// Syntax kinds of the lines that the last frame drew in `lex[0]`, so
    /// a frame lexes only the lines that it didn't draw before; `lex[1]` is
    /// the frame before, swapped in as the next one fills. Bound: the
    /// visible lines. Dropped from the edited line down and with `states`.
    lex: [2]Kinds = .{ .{}, .{} },
    /// The caret's color was set for dark mode or light.
    dark: ?bool = null,
    /// The caret is a Core Animation layer, so its glide and blink run in
    /// the window server instead of redrawing the text.
    caret: Id = null,
    /// The frame and hidden state the caret layer was last given; null when
    /// the layer was changed some other way, so the next move lands.
    caret_at: ?Rect = null,
    caret_off: bool = true,
    /// What the caret last stood for: mode, then row and column or prompt width.
    spot: [3]usize = .{ std.math.maxInt(usize), 0, 0 },
    shown: bool = false,
    /// Place the caret without gliding (mouse drags).
    snap: bool = false,
    /// The window's other files, in tab order.
    pages: std.ArrayList(Page) = .empty,
    /// When the window's file was last swapped in, for its text to fade in:
    /// rising when it was just read from disk, else a plain fade. The caret
    /// fades in with it.
    load_t: f64 = -1,
    rise: bool = false,
    caret_fade: bool = false,
    /// An empty window's hint: its opacity, and since when the card has
    /// been blank (-1 when it isn't).
    hint: Tween = .{ .dur = hint_in },
    blank_t0: f64 = -1,
    /// The header's folder as a CoreText line fitting `head_w`, from
    /// `headLine`, with the middles of the gaps between its folders, where
    /// chevrons go, in `head_marks`. It was built for `head_w` of room (-1
    /// for none yet), is `head_lw` wide, and `head_cut` when that loses a
    /// folder or its end.
    head: Id = null,
    head_w: f64 = -1,
    head_lw: f64 = 0,
    head_cut: bool = false,
    head_marks: [max_marks]f64 = undefined,
    head_n: usize = 0,

    /// An untitled file goes by its first line, kept in `title` as it's typed.
    title: [48]u8 = undefined,
    title_len: usize = 0,

    fn name(d: *const Doc) []const u8 {
        return if (d.path) |p| std.fs.path.basename(p) else if (d.title_len > 0) d.title[0..d.title_len] else "Untitled";
    }

    /// Unsaved changes to a file, on show or in any page. Untitled files
    /// keep themselves as drafts, so they don't count.
    fn dirty(d: *const Doc) bool {
        if (d.path != null and d.ed.buf.dirty()) return true;
        for (d.pages.items) |p| if (p.path != null and p.ed.buf.dirty()) return true;
        return false;
    }

    fn deinit(d: *Doc) void {
        d.ed.deinit(gpa);
        if (d.path) |p| gpa.free(p);
        dropDraft(&d.draft);
        if (d.list) |*l| l.deinit();
        d.prompt.deinit(gpa);
        d.with.deinit(gpa);
        d.held.deinit(gpa);
        d.held_with.deinit(gpa);
        d.query.deinit(gpa);
        d.states.deinit(gpa);
        for (&d.lex) |*x| x.deinit();
        d.vfirst.deinit(gpa);
        dropHead(d);
        for (d.pages.items) |*p| p.deinit();
        d.pages.deinit(gpa);
        for (d.slots.items) |*s| s.drop();
        d.slots.deinit(gpa);
    }
};

var docs: std.ArrayList(*Doc) = .empty;
var view_class: Id = null;
var win_ivar: usize = 0;

/// A window: the sidebar on its left, and the cards right of it, laid out
/// by a tree of splits. Each card is a Doc.
const Win = struct {
    window: Id,
    view: Id,
    link: Id = null,
    cards: *Node,
    /// The card that takes typing, the menu commands and sidebar clicks.
    focus: *Doc,
    /// The last draw had scenery still moving.
    busy: bool = false,
    /// Only the sidebar's strip has frames to draw, so `tick` redraws just that.
    part: bool = false,
    /// How far the sidebar is scrolled.
    side_y: f64 = 0,
    /// The mouse went down outside the cards' text (the sidebar, the title
    /// band, a gap), so drags don't select text.
    side_down: bool = false,
    /// The mouse went down on the sidebar's edge and is dragging it.
    side_drag: bool = false,
    /// Which limit the sidebar's edge is at while dragged: -1 least, 1 most, 0 none.
    side_lim: i8 = 0,
    /// The gap between two cards that the mouse is dragging.
    grab: ?*Node = null,
    /// Which snap point or limit the dragged gap sits on, 0 for none, so the
    /// trackpad taps once on arriving.
    grab_hit: u8 = 0,
    /// Until when the dragged gap eases instead of tracking the mouse.
    grab_ease: f64 = 0,
    /// Scroll the sidebar to the focused card's file on the next draw.
    side_find: bool = false,
    /// The open folders pinned under the folder's name, and where each drew.
    stuck: [max_stuck]usize = undefined,
    stuck_y: [max_stuck]f64 = undefined,
    nstuck: usize = 0,
    /// A sidebar scroll that glides, like a click on a pinned folder.
    side_t: Tween = .{ .dur = scroll_time },
    /// How far the sidebar has slid in, 0 to 1, and the cards' left edge
    /// that rides with it. Wrapping uses where it ends up.
    side_a: Tween = .{ .dur = slide_time },
    lx: f64 = gap,
    side_seen: bool = false,
    /// The sidebar's selection: the row it marks (looked up again when the
    /// tree or the focused file changes), the row it marked last draw, where
    /// it springs to in the list, and how far it's faded in.
    sel_row: ?usize = null,
    /// The selected row's name in bold, made for row `bold_row` of tree
    /// `bold_gen`. Owned: CFRelease it.
    bold: Id = null,
    bold_row: usize = 0,
    bold_gen: u32 = 0,
    /// The name the selection just left, kept while its highlight fades off it.
    bold_old: Id = null,
    bold_old_row: usize = 0,
    bold_old_gen: u32 = 0,
    sel_was: ?usize = null,
    sel_gen: u32 = 0,
    sel_id: u32 = 0,
    sel: Spring = .{ .k = 420, .c = 30, .eps = 0.05 },
    sel_a: Tween = .{ .dur = fade_time },
    /// The button by the traffic lights (1) or the sidebar's + (2) under the
    /// mouse, and each one's hover highlight.
    hot: u8 = 0,
    hot_t: [2]Tween = @splat(.{ .dur = fade_time }),
    /// The button the mouse pressed, 1 or 2 like `hot`, and its fill, there
    /// at once on the click and fading after the release.
    press: u8 = 0,
    press_t: Tween = .{ .dur = press_time },
    /// The tab the mouse is dragging, if any.
    tdrag: ?TabDrag = null,
    /// The drop preview, in the view: where it springs to (x, y, width,
    /// height) and how far it's faded in. The dragged tab's copy under the
    /// mouse fades in with `ghost_a` once it leaves its row.
    pv: [4]Spring = @splat(.{ .k = 420, .c = 30, .eps = 0.05 }),
    pv_a: Tween = .{ .dur = fade_time },
    /// A split drop just happened, so the preview's ring fades out quicker.
    pv_cross: bool = false,
    ghost_a: Tween = .{ .dur = fade_time },
    /// The dragged tab's copy grows to 1.04 as it's picked up and settles
    /// back to 1 as it lands.
    lift: Spring = .{ .x = 1, .to = 1, .k = 500, .c = 28 },
    /// How strongly the cards' shadows show: fading to half while the
    /// window isn't key.
    key_a: Tween = .{ .dur = 0.2, .from = 1, .to = 1 },
    /// The sidebar row (of tree `menu_gen`) or the card's tab that a
    /// right-click menu is open on, and its outline fading in or out.
    menu_row: ?usize = null,
    menu_gen: u32 = 0,
    menu_card: ?*Doc = null,
    menu_tab: u32 = 0,
    menu_a: Tween = .{ .dur = menu_time },
    /// The sidebar has drawn once, so later moves to the focused file glide.
    side_drawn: bool = false,
    /// A dragged copy finishing its trip after the mouse let go.
    fly: ?Fly = null,
    /// Zen blended in, 0 to 1: the text's margin, the header and the
    /// traffic lights follow it. And the lights' alpha as last set.
    z: Spring = .{ .k = 200, .c = 28, .eps = 0.002 },
    lights_a: f64 = 1,
    /// The sidebar row under the mouse (of tree `hov_gen`), the row the
    /// hover highlight last went to, where it springs to in the list, and
    /// how far it's faded in.
    hov_row: ?usize = null,
    hov_gen: u32 = 0,
    hov_last: ?usize = null,
    hov: Spring = .{ .k = 700, .c = 53, .eps = 0.05 },
    hov_a: Tween = .{ .dur = fade_time },
};

/// A dragged tab's or file's copy after the mouse lets go: it slides into
/// the gap among the tabs it landed in, or back to where it came from when
/// it landed nowhere, or fades where it landed on a card.
const Fly = struct {
    /// Retained: see `endFly`.
    line: Id,
    icon: Id,
    w: f64,
    from: Point,
    to: Point,
    t0: f64,
    fade: bool = false,
    /// The tab that stays faint until its copy is back, or the sidebar row
    /// that stays dim until its copy is gone.
    card: ?*Doc = null,
    id: u32 = 0,
    row: ?usize = null,
};

const fly_time = 0.3;

/// A gap dragged past its limit stretches at this share of the pull, up to
/// `grab_stretch` points. A split gap snaps to 1/2, 1/3 and 2/3 within
/// `snap_reach` points.
const grab_pull = 0.3;
const grab_stretch = 24.0;
const snap_reach = 6.0;
/// How long the gap eases after entering or leaving a snap point.
const snap_ease = 0.15;

/// Where a dragged tab lands: among a card's tabs, on the card itself, or
/// in a new card split off one of its edges.
const Zone = enum { tabs, whole, left, right, top, bottom };
const Drop = struct { card: *Doc, zone: Zone, k: usize = 0 };

const TabDrag = struct {
    /// The card whose tab it is, or null for a file dragged from the sidebar.
    from: ?*Doc,
    id: u32 = 0,
    /// Where the mouse went down and where it is, in the view, and how far
    /// right of the tab's left edge it went down.
    down: Point,
    at: Point,
    grab: f64,
    /// It moved far enough to be a drag rather than a click.
    live: bool = false,
    /// It left its card's tab row, so it drops by `drop`.
    out: bool = false,
    drop: ?Drop = null,
    /// A sidebar file: its path, its name for the copy under the mouse, and
    /// whether ⌘ was down, for a click that opens it. Owned: see `freeDrag`.
    file: ?[:0]u8 = null,
    name: Id = null,
    cmd: bool = false,
    /// The sidebar row it came from, which dims while it's out.
    row: ?usize = null,
};

var wins: std.ArrayList(*Win) = .empty;

/// The cards' layout: a card, or a split of two, side by side or one above
/// the other, with the first taking `share` of the room. A new card grows in
/// from nothing and a closing one folds away as the share springs.
const Node = struct {
    pane: ?*Doc = null,
    down: bool = false,
    kids: [2]*Node = undefined,
    up: ?*Node = null,
    share: Spring = .{ .k = 260, .c = 30, .eps = 0.0005 },
    /// The kid folding away, dropped once the share settles.
    going: ?u1 = null,
    /// Where it laid out last, for grabbing the gap between its kids.
    r: Rect = .{},
};

/// A card keeps at least this much room when splitting or dragging a gap.
const min_card_w: f64 = 220;
const min_card_h: f64 = 140;

fn winOf(self: Id) ?*Win {
    const slot: *?*Win = @ptrFromInt(@intFromPtr(self.?) + win_ivar);
    return slot.*;
}

fn setWin(self: Id, w: ?*Win) void {
    const slot: *?*Win = @ptrFromInt(@intFromPtr(self.?) + win_ivar);
    slot.* = w;
}

/// The window's focused card: menu commands and typing go there.
fn docOf(self: Id) ?*Doc {
    return (winOf(self) orelse return null).focus;
}

/// The card's pane, in its own coordinates.
fn bounds(d: *const Doc) Rect {
    return .{ .w = d.size.x, .h = d.size.y };
}

fn textH(d: *const Doc) f64 {
    return @max(bottom(d) - top_h, lh);
}

fn pageLines(d: *const Doc) usize {
    return @max(@as(usize, @intFromFloat(textH(d) / lh)), 2) - 1;
}

/// Opens `path` (a file or a folder). A file shows in `into`, in a new tab
/// right of the one on show, or else in a new window. A file that a card
/// already holds comes forward there.
pub fn open(path: []const u8, into: ?*Doc) void {
    const abs = files.absolute(gpa, path) catch return;
    if (files.isDir(abs)) {
        setRoot(abs);
        const d = into orelse keyDoc() orelse newDoc() orelse return;
        if (sideShown(d.win)) refreshAll() else startPrompt(d, .open);
        return;
    }
    defer gpa.free(abs);
    for (docs.items) |o| {
        if (o.closing) continue;
        if (o.path != null and std.mem.eql(u8, o.path.?, abs)) return front(o);
        if (pageIndex(o, abs)) |i| {
            showPage(o, i);
            return front(o);
        }
    }
    var pg = loadPage(abs) orelse return;
    const d = into orelse newDoc() orelse return pg.deinit();
    if (!park(d, true)) return pg.deinit();
    install(d, pg);
    noteRecent(abs);
    front(d);
}

/// Brings `d`'s window forward with `d` as its focused card.
fn front(d: *Doc) void {
    focus(d);
    showWin(d.window);
}

/// Set for a Dev build (`Zag Dev`, bundle id ending in `.dev`), which runs
/// behind Harsha's windows and never takes the keys.
pub var background = false;

/// Shows `win` in front and key, or for a Dev build, behind every window.
fn showWin(win: Id) void {
    if (background) msg(void, win, "orderBack:", .{@as(Id, null)}) else msg(void, win, "makeKeyAndOrderFront:", .{@as(Id, null)});
}

/// Makes `d` the card that takes typing in its window. Its ring lights up
/// and the other cards' carets go out.
fn focus(d: *Doc) void {
    const w = d.win;
    if (w.focus == d) return;
    const old = w.focus;
    w.focus = d;
    access.focused(d);
    w.side_find = true;
    named(d);
    refresh(old);
    refresh(d);
}

/// Reads a file into a page, at the caret and scroll it had last time.
fn loadPage(abs: [:0]const u8) ?Page {
    const bytes = files.read(gpa, abs) catch |err| switch (err) {
        error.FileNotFound => gpa.alloc(u8, 0) catch return null,
        else => {
            alert("Couldn't open this file.", abs);
            return null;
        },
    };
    defer gpa.free(bytes);
    if (std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8000)], 0) != null) {
        alert("This looks like a binary file.", abs);
        return null;
    }
    var ed = Editor.init(gpa, bytes) catch return null;
    const z = gpa.dupeSentinel(u8, abs, 0) catch {
        ed.deinit(gpa);
        return null;
    };
    var sy: f64 = 0;
    if (placeOf(abs)) |pl| {
        var c = @min(pl.cur, bytes.len);
        while (c > 0 and c < bytes.len and bytes[c] & 0xC0 == 0x80) c -= 1;
        ed.select(c, c);
        sy = pl.sy;
    }
    return .{ .ed = ed, .path = z, .lang = syntax.forPath(abs), .stamp = files.stamp(abs), .sx = 0, .sy = sy, .id = newId(), .fresh = true };
}

fn pageIndex(d: *const Doc, abs: []const u8) ?usize {
    for (d.pages.items, 0..) |p, i| if (p.path != null and std.mem.eql(u8, p.path.?, abs)) return i;
    return null;
}

fn isBlank(d: *const Doc) bool {
    return d.path == null and d.ed.text().len == 0;
}

/// The card's only tab is an empty untitled file, which the next file it
/// opens takes the place of. An empty one beside other tabs stays until
/// it's closed.
fn replaceable(d: *const Doc) bool {
    return isBlank(d) and d.pages.items.len == 0;
}

/// Sets the window's file aside as a page in its tab's place, for
/// `install` to replace right after, which goes in a new tab to its right
/// when `after`. A `replaceable` file is dropped instead. False when it
/// can't.
fn park(d: *Doc, after: bool) bool {
    if (replaceable(d)) {
        d.ed.deinit(gpa);
        dropDraft(&d.draft);
        return true;
    }
    d.pages.insert(gpa, d.at, asPage(d)) catch return false;
    rememberPlace(d);
    if (after) d.at += 1;
    return true;
}

/// Shows `pg` in the window, which must have just been parked.
fn install(d: *Doc, pg: Page) void {
    d.ed = pg.ed;
    d.path = pg.path;
    d.lang = pg.lang;
    d.stamp = pg.stamp;
    d.sx = pg.sx;
    d.sy = pg.sy;
    d.id = pg.id;
    d.draft = pg.draft;
    d.drafted = pg.drafted;
    d.dot = pg.dot;
    d.center_at = std.math.maxInt(usize);
    clearSyntax(d);
    d.vfirst.clearRetainingCapacity();
    d.cols = 0;
    d.mode = .edit;
    d.note = "";
    d.ys.snap(d.sy);
    d.xs.snap(d.sx);
    d.band_on = false;
    d.had_sel = false;
    d.sel_out.snap(0);
    d.snap = true;
    d.load_t = CACurrentMediaTime();
    d.rise = pg.fresh;
    d.caret_fade = true;
    if (d.path) |p| if (relOf(p)) |rel| {
        // The folders are only read again when one had to open or the file
        // isn't listed yet (made since the last read).
        if (tree.reveal(gpa, rel) or (!tree_stale and !tree.has(rel))) {
            if (restoring) tree_stale = true else rebuildTree();
        }
        if (d.win.focus == d) d.win.side_find = true;
    };
    named(d);
    if (!restoring) refreshAll();
}

/// Shows page `i` of the window. The file it had keeps its tab, even an
/// empty untitled one: it's set aside while page `i` is still there, so
/// `park` never drops it.
fn showPage(d: *Doc, i: usize) void {
    const tab = if (i < d.at) i else i + 1;
    if (!park(d, false)) return;
    const pg = d.pages.orderedRemove(tab);
    d.at = tab;
    install(d, pg);
    checkOutside(d);
}

// ---- tabs ----

fn tabCount(d: *const Doc) usize {
    return d.pages.items.len + 1;
}

/// The page that tab `j` holds; the active tab has none.
fn pageOf(d: *const Doc, j: usize) usize {
    return if (j < d.at) j else j - 1;
}

fn tabId(d: *const Doc, j: usize) u32 {
    return if (j == d.at) d.id else d.pages.items[pageOf(d, j)].id;
}

fn tabDraft(d: *const Doc, j: usize) ?[]const u8 {
    return if (j == d.at) d.draft else d.pages.items[pageOf(d, j)].draft;
}

/// The file on show as a page, for moving it; the card still points at it.
fn asPage(d: *const Doc) Page {
    return .{ .ed = d.ed, .path = d.path, .lang = d.lang, .stamp = d.stamp, .sx = d.sx, .sy = d.sy, .id = d.id, .draft = d.draft, .drafted = d.drafted, .dot = d.dot };
}

fn tabPath(d: *const Doc, j: usize) ?[]const u8 {
    return if (j == d.at) d.path else d.pages.items[pageOf(d, j)].path;
}

/// Tab `j` shows the dot of unsaved changes: a file with edits. An
/// untitled file keeps itself as a draft, so it never does.
fn tabDirty(d: *const Doc, j: usize) bool {
    return tabPath(d, j) != null and if (j == d.at) d.ed.buf.dirty() else d.pages.items[pageOf(d, j)].ed.buf.dirty();
}

/// Closing tab `j` would lose something: edits to a file, or an untitled
/// file's text, whose draft goes with it.
fn tabLoses(d: *const Doc, j: usize) bool {
    return if (j == d.at) loses(d.path, &d.ed) else loses(d.pages.items[pageOf(d, j)].path, &d.pages.items[pageOf(d, j)].ed);
}

fn loses(path: ?[:0]const u8, ed: *const Editor) bool {
    return if (path == null) ed.text().len > 0 else ed.buf.dirty();
}

fn tabIndex(d: *const Doc, id: u32) ?usize {
    for (0..tabCount(d)) |j| if (tabId(d, j) == id) return j;
    return null;
}

fn showTab(d: *Doc, j: usize) void {
    if (j != d.at) showPage(d, pageOf(d, j));
}

/// ⌃Tab and ⌃⇧Tab: the next or previous tab, around the ends.
pub fn stepTab(by: isize) void {
    const d = keyDoc() orelse return;
    const n: isize = @intCast(tabCount(d));
    showTab(d, @intCast(@mod(@as(isize, @intCast(d.at)) + by, n)));
}

/// ⌘T: an untitled file in a new tab right of the one on show.
fn newTab(d: *Doc) void {
    if (isBlank(d)) return;
    const ed = Editor.init(gpa, "") catch return;
    if (!park(d, true)) {
        var e = ed;
        return e.deinit(gpa);
    }
    install(d, .{ .ed = ed, .path = null, .lang = &syntax.plain, .stamp = null, .sx = 0, .sy = 0, .id = newId() });
}

/// Closes tab `j`, asking first when it has unsaved changes. A card's last
/// tab folds the card away, or closes the window when it's the only card.
/// The tab to the right takes the active one's place, or the one to the
/// left at the end.
fn closeTab(d: *Doc, at: usize) void {
    if (tabCount(d) == 1) {
        if (d.win.cards.pane != null) return msg(void, d.window, "performClose:", .{@as(Id, null)});
        if (loses(d.path, &d.ed) and !keepOrDrop(d)) return;
        return foldCard(d);
    }
    var j = at;
    if (tabLoses(d, j)) {
        showTab(d, j);
        j = d.at;
        if (!keepOrDrop(d)) return;
    }
    if (j != d.at) {
        var pg = d.pages.orderedRemove(pageOf(d, j));
        pg.deinit();
        if (j < d.at) d.at -= 1;
        return refreshAll();
    }
    rememberPlace(d);
    d.ed.deinit(gpa);
    if (d.path) |p| gpa.free(p);
    d.path = null;
    dropDraft(&d.draft);
    const next = if (d.at < d.pages.items.len) d.at else d.at - 1;
    const pg = d.pages.orderedRemove(next);
    d.at = next;
    install(d, pg);
    checkOutside(d);
}

/// Asks whether to save the file on show before it goes. False to keep it.
fn keepOrDrop(d: *Doc) bool {
    front(d);
    const a = objc.new("NSAlert");
    var buf: [300]u8 = undefined;
    msg(void, a, "setMessageText:", .{objc.str(std.fmt.bufPrint(&buf, "Save changes to {s}?", .{d.name()}) catch "Save changes?")});
    msg(void, a, "setInformativeText:", .{objc.str("Your changes are lost if you don't save them.")});
    _ = msg(Id, a, "addButtonWithTitle:", .{objc.str("Save")});
    _ = msg(Id, a, "addButtonWithTitle:", .{objc.str("Don't Save")});
    _ = msg(Id, a, "addButtonWithTitle:", .{objc.str("Cancel")});
    const r = msg(isize, a, "runModal", .{});
    msg(void, a, "release", .{});
    return switch (r) {
        1000 => save(d, false),
        1001 => true,
        else => false,
    };
}

/// Drops the header's lines, and when `d` is its window's focused card,
/// titles the window after its file.
fn named(d: *Doc) void {
    dropHead(d);
    retitle(d);
    refresh(d);
    if (d.win.focus != d) return;
    msg(void, d.window, "setTitle:", .{objc.str(d.name())});
    // Window menu, Mission Control and the Dock show the title; the card's header shows the name.
    const url = if (d.path) |p| msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(p)}) else null;
    msg(void, d.window, "setRepresentedURL:", .{url});
}

/// The key window's focused card. A Dev build never has a key window, so
/// there it's the front one of Zag's windows.
pub fn keyDoc() ?*Doc {
    const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const kw = msg(Id, app, "keyWindow", .{});
    for (wins.items) |w| if (w.window == kw) return w.focus;
    if (!background) return null;
    const order = msg(Id, app, "orderedWindows", .{});
    for (0..msg(usize, order, "count", .{})) |i| {
        const o = msg(Id, order, "objectAtIndex:", .{i});
        for (wins.items) |w| if (w.window == o) return w.focus;
    }
    return null;
}

// ---- cards ----

/// ⌘D and ⇧⌘D: a new card right of or under the focused one, springing in
/// while this one makes room. It takes the tab on show when there are
/// others to leave behind, else it starts with quick open.
fn split(d: *Doc, down: bool) void {
    const e = splitOff(d, down, false, false) orelse {
        d.card_shake_t0 = CACurrentMediaTime();
        refresh(d);
        return msg(void, objc.class("NSSound"), "beep", .{});
    };
    if (tabCount(d) > 1) {
        if (takeTab(d, d.at)) |pg| putTab(e, pg, 0);
    } else startPrompt(e, .open);
    focus(e);
}

/// Whether card `d` has room to split in two along its width or (`down`) height.
fn roomFor(d: *const Doc, down: bool) bool {
    const room = if (down) d.fin.y - 3 * gap else d.fin.x - 3 * gap;
    return room >= 2 * (if (down) min_card_h else min_card_w);
}

/// Splits card `d` and returns the new card, with a blank untitled file,
/// right of or under it, or left of or above it when `before`. It springs
/// in from a sliver at that edge while `d` makes room, or when `dropped`
/// (a drop showed its half) starts as that half and settles with a kick.
/// Null without room.
fn splitOff(d: *Doc, down: bool, before: bool, dropped: bool) ?*Doc {
    const w = d.win;
    const leaf = nodeOf(w.cards, d) orelse return null;
    if (!roomFor(d, down)) return null;
    const room = if (down) d.fin.y - 3 * gap else d.fin.x - 3 * gap;
    const e = newPane(w) orelse return null;
    const a = gpa.create(Node) catch return null;
    const b = gpa.create(Node) catch {
        gpa.destroy(a);
        return null;
    };
    a.* = .{ .pane = d, .up = leaf };
    b.* = .{ .pane = e, .up = leaf };
    leaf.pane = null;
    leaf.down = down;
    leaf.kids = if (before) .{ b, a } else .{ a, b };
    const now = CACurrentMediaTime();
    if (dropped) {
        leaf.share.snap(0.5);
        leaf.share.aim(0.5, now);
        leaf.share.v = if (before) 0.3 else -0.3;
        const half = divide(.{ .x = d.org.x, .y = d.org.y, .w = d.size.x, .h = d.size.y }, 0.5, down)[if (before) 0 else 1];
        e.org = .{ .x = half.x, .y = half.y };
        e.size = .{ .x = half.w, .y = half.h };
        w.pv_cross = true;
        e.lit.dur = 0.15;
    } else {
        leaf.share.snap(if (before) 0 else 1);
        leaf.share.aim(0.5, now);
        // It starts as a sliver at its edge, already the size it'll wrap at.
        const far: Point = if (before) .{} else if (down) .{ .y = d.size.y - 2 * gap } else .{ .x = d.size.x - 2 * gap };
        e.org = .{ .x = d.org.x + far.x, .y = d.org.y + far.y };
        e.size = if (down) .{ .x = d.size.x, .y = 2 * gap } else .{ .x = 2 * gap, .y = d.size.y };
    }
    e.fin = if (down) .{ .x = d.fin.x, .y = room / 2 + 2 * gap } else .{ .x = room / 2 + 2 * gap, .y = d.fin.y };
    msg(void, d.window, "invalidateCursorRectsForView:", .{d.view});
    return e;
}

/// Takes tab `j` out of card `d`, edits and all. When it's the tab on show,
/// the tab to its right takes its place; a card's last tab leaves it with
/// a blank untitled file, for the caller to fold away.
fn takeTab(d: *Doc, j: usize) ?Page {
    if (j != d.at) {
        const pg = d.pages.orderedRemove(pageOf(d, j));
        if (j < d.at) d.at -= 1;
        refreshAll();
        return pg;
    }
    var blank: ?Editor = null;
    if (tabCount(d) == 1) blank = Editor.init(gpa, "") catch return null;
    const pg = asPage(d);
    d.path = null;
    d.draft = null;
    if (blank) |ed| {
        install(d, .{ .ed = ed, .path = null, .lang = &syntax.plain, .stamp = null, .sx = 0, .sy = 0, .id = newId() });
    } else {
        const next = if (d.at < d.pages.items.len) d.at else d.at - 1;
        const other = d.pages.orderedRemove(next);
        d.at = next;
        install(d, other);
    }
    return pg;
}

/// Puts `pg` in card `e` as its tab `k` (or last) and shows it. A blank
/// untitled file on show in `e` makes way for it.
fn putTab(e: *Doc, pg: Page, k: usize) void {
    if (!park(e, false)) {
        var p = pg;
        return p.deinit();
    }
    e.at = @min(k, e.pages.items.len);
    install(e, pg);
    checkOutside(e);
}

/// Moves card `d`'s tab `j` to place `k` among its tabs. The other tabs
/// slide over to make room.
fn reorderTab(d: *Doc, j: usize, k: usize) void {
    if (j == k) return;
    const id = tabId(d, j);
    if (j == d.at) {
        d.at = k;
    } else {
        const pg = d.pages.orderedRemove(pageOf(d, j));
        if (j < d.at) d.at -= 1;
        if (k <= d.at) {
            d.pages.insert(gpa, k, pg) catch return;
            d.at += 1;
        } else d.pages.insert(gpa, k - 1, pg) catch return;
    }
    // Each tab slides from where it's drawn now to its new place.
    for (d.slots.items) |*s| s.flip = s.x + s.shift.x;
    const i = slotOf(d, id) orelse return;
    const s = d.slots.orderedRemove(i);
    const at = if (k + 1 < tabCount(d)) slotOf(d, tabId(d, k + 1)) orelse 0 else d.slots.items.len;
    d.slots.insert(gpa, at, s) catch {};
    refresh(d);
}

/// A closing card's split springs it shut (without a bounce) while its
/// neighbor takes the room, and the neighbor takes typing.
fn foldCard(d: *Doc) void {
    const w = d.win;
    const leaf = nodeOf(w.cards, d) orelse return;
    const up = leaf.up orelse return;
    if (up.going != null) return;
    const g: u1 = if (up.kids[0] == leaf) 0 else 1;
    up.going = g;
    up.share.c = 2 * @sqrt(up.share.k);
    up.share.aim(if (g == 0) 0 else 1, CACurrentMediaTime());
    d.closing = true;
    d.shown = false;
    msg(void, d.caret, "setHidden:", .{true});
    d.caret_at = null;
    focus(firstPane(up.kids[1 - g]));
    msg(void, d.window, "invalidateCursorRectsForView:", .{d.view});
}

fn nodeOf(n: *Node, d: *const Doc) ?*Node {
    if (n.pane) |p| return if (p == d) n else null;
    return nodeOf(n.kids[0], d) orelse nodeOf(n.kids[1], d);
}

fn firstPane(n: *const Node) *Doc {
    return n.pane orelse firstPane(n.kids[0]);
}

/// The panes of the first `s` and the rest of `r`, along its width or
/// (`down`) its height. Each card sits a gap in from its pane's edges, so
/// the two panes overlap by a gap and their cards are a gap apart.
fn divide(r: Rect, s: f64, down: bool) [2]Rect {
    const len = if (down) r.h else r.w;
    const first = (len - 3 * gap) * std.math.clamp(s, 0, 1) + 2 * gap;
    const at = first - gap;
    if (down) return .{ .{ .x = r.x, .y = r.y, .w = r.w, .h = first }, .{ .x = r.x, .y = r.y + at, .w = r.w, .h = r.h - at } };
    return .{ .{ .x = r.x, .y = r.y, .w = first, .h = r.h }, .{ .x = r.x + at, .y = r.y, .w = r.w - at, .h = r.h } };
}

/// Lays the cards out in `r` as they are now, and in `fin` as they'll end
/// up, which wrapping uses so text doesn't rewrap while a card springs.
fn place(n: *Node, r: Rect, fin: Rect, now: f64) void {
    n.r = r;
    if (n.pane) |d| {
        d.org = .{ .x = r.x, .y = r.y };
        d.size = .{ .x = r.w, .y = r.h };
        d.fin = .{ .x = fin.w, .y = fin.h };
        return;
    }
    const a = divide(r, n.share.step(now), n.down);
    const b = divide(fin, n.share.to, n.down);
    place(n.kids[0], a[0], b[0], now);
    place(n.kids[1], a[1], b[1], now);
}

fn cardsMoving(n: *const Node) bool {
    if (n.pane != null) return false;
    return !n.share.settled() or cardsMoving(n.kids[0]) or cardsMoving(n.kids[1]);
}

/// Takes out the cards that have folded away: their split hands its place
/// to the other kid.
fn dropFolded(w: *Win, n: *Node) void {
    if (n.pane != null) return;
    if (n.going) |g| if (n.share.settled()) {
        const gone = n.kids[g];
        const keep = n.kids[1 - g];
        closePane(gone.pane.?);
        gpa.destroy(gone);
        const up = n.up;
        n.* = keep.*;
        n.up = up;
        if (n.pane == null) for (n.kids) |kid| {
            kid.up = n;
        };
        gpa.destroy(keep);
        w.grab = null;
        msg(void, w.window, "invalidateCursorRectsForView:", .{w.view});
        return dropFolded(w, n);
    };
    dropFolded(w, n.kids[0]);
    dropFolded(w, n.kids[1]);
}

fn freeNodes(n: *Node) void {
    if (n.pane == null) for (n.kids) |kid| freeNodes(kid);
    gpa.destroy(n);
}

/// Lets go of a card that's out of its window's layout, or whose window closed.
fn closePane(d: *Doc) void {
    rememberPlace(d);
    msg(void, d.caret, "removeFromSuperlayer", .{});
    access.drop(d);
    for (docs.items, 0..) |x, i| if (x == d) {
        _ = docs.orderedRemove(i);
        break;
    };
    d.deinit();
    gpa.destroy(d);
}

/// The card under `p`, in the view's coordinates. Cards that are folding
/// away don't count.
fn paneAt(w: *const Win, p: Point) ?*Doc {
    var near: ?*Doc = null;
    for (docs.items) |d| if (d.win == w and !d.closing) {
        const x = p.x - d.org.x;
        const y = p.y - d.org.y;
        if (x < 0 or y < 0 or x >= d.size.x or y >= d.size.y) continue;
        if (x >= gap and y >= gap and x < d.size.x - gap and y < d.size.y - gap) return d;
        near = d;
    };
    return near;
}

/// `p` in `d`'s pane.
fn inPane(d: *const Doc, p: Point) Point {
    return .{ .x = p.x - d.org.x, .y = p.y - d.org.y };
}

/// The gap between two cards, where it splits `n`, in the view.
fn gapRect(n: *const Node) Rect {
    const b = divide(n.r, n.share.x, n.down)[1];
    if (n.down) return .{ .x = n.r.x + gap, .y = b.y, .w = n.r.w - 2 * gap, .h = gap };
    return .{ .x = b.x, .y = n.r.y + gap, .w = gap, .h = n.r.h - 2 * gap };
}

/// The split whose gap is under `p`, a few points either side.
fn gapAt(n: *Node, p: Point) ?*Node {
    if (n.pane != null) return null;
    if (n.going == null) {
        const g = gapRect(n);
        if (p.x >= g.x - 3 and p.x < g.x + g.w + 3 and p.y >= g.y - 3 and p.y < g.y + g.h + 3) return n;
    }
    return gapAt(n.kids[0], p) orelse gapAt(n.kids[1], p);
}

/// Moves split `n`'s gap to `p`, keeping each side's card a usable size.
fn dragGap(w: *Win, n: *Node, p: Point) void {
    const len = @max((if (n.down) n.r.h else n.r.w) - 3 * gap, 1);
    var at = (if (n.down) p.y - n.r.y else p.x - n.r.x) - 1.5 * gap;
    const lo = @min(0.5, (if (n.down) min_card_h else min_card_w) / len) * len;
    const hi = len - lo;
    // Past a limit the gap stretches with resistance; near 1/2, 1/3 or
    // 2/3 it snaps. Either way the trackpad taps once on arriving.
    var hit: u8 = 0;
    if (at <= lo) {
        at = lo - @min((lo - at) * grab_pull, grab_stretch);
        hit = 1;
    } else if (at >= hi) {
        at = hi + @min((at - hi) * grab_pull, grab_stretch);
        hit = 2;
    } else for ([_]f64{ 1.0 / 2.0, 1.0 / 3.0, 2.0 / 3.0 }, 3..) |s, id| {
        if (@abs(at - s * len) < snap_reach and s * len > lo and s * len < hi) {
            at = s * len;
            hit = @intCast(id);
            break;
        }
    }
    if (hit != 0 and hit != w.grab_hit) haptic(.alignment);
    const now = CACurrentMediaTime();
    // The share eases into and out of a snap point, and tracks the mouse 1:1 otherwise.
    if (hit != w.grab_hit and (hit >= 3 or w.grab_hit >= 3)) w.grab_ease = now + snap_ease;
    w.grab_hit = hit;
    const to = at / len;
    if (now >= w.grab_ease) n.share.x += to - n.share.to;
    n.share.aim(to, now);
    msg(void, if (hit == 1 or hit == 2) limitCursor(n.down, hit == 1) else resizeCursor(n.down), "set", .{});
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// Lets go of a gap dragged past its limit: the share springs back.
fn releaseGap(n: *Node, now: f64) void {
    const len = @max((if (n.down) n.r.h else n.r.w) - 3 * gap, 1);
    const lo = @min(0.5, (if (n.down) min_card_h else min_card_w) / len);
    n.share.aim(std.math.clamp(n.share.to, lo, 1 - lo), now);
}

/// The gaps' cursors: left-right between cards side by side, up-down
/// between cards one above the other.
fn gapCursors(view: Id, n: *const Node) void {
    if (n.pane != null) return;
    if (n.going == null) msg(void, view, "addCursorRect:cursor:", .{ gapRect(n), resizeCursor(n.down) });
    gapCursors(view, n.kids[0]);
    gapCursors(view, n.kids[1]);
}

fn resizeCursor(down: bool) Id {
    const c = objc.class("NSCursor");
    return if (down) msg(Id, c, "resizeUpDownCursor", .{}) else msg(Id, c, "resizeLeftRightCursor", .{});
}

/// The cursor at a gap's limit, which only moves one way: toward the
/// bigger first card at its smallest (`low`), away from it at its biggest.
fn limitCursor(down: bool, low: bool) Id {
    const c = objc.class("NSCursor");
    if (down) return if (low) msg(Id, c, "resizeDownCursor", .{}) else msg(Id, c, "resizeUpCursor", .{});
    return if (low) msg(Id, c, "resizeRightCursor", .{}) else msg(Id, c, "resizeLeftCursor", .{});
}

/// ⌘] and ⌘[: typing moves to the next or previous card, in layout order.
fn stepCard(d: *Doc, by: isize) void {
    var list: [64]*Doc = undefined;
    const n = listPanes(d.win.cards, &list, 0);
    if (n < 2) return;
    const i = std.mem.indexOfScalar(*Doc, list[0..n], d) orelse return;
    const ni: isize = @intCast(n);
    focus(list[@intCast(@mod(@as(isize, @intCast(i)) + by, ni))]);
}

fn listPanes(n: *const Node, out: []*Doc, at: usize) usize {
    if (n.pane) |p| {
        if (p.closing or at >= out.len) return at;
        out[at] = p;
        return at + 1;
    }
    return listPanes(n.kids[1], out, listPanes(n.kids[0], out, at));
}

/// A doc nothing has been typed into, for a file to open into.
pub fn blankDoc() ?*Doc {
    const d = keyDoc() orelse return null;
    return if (d.path == null and d.ed.text().len == 0) d else null;
}

/// How many windows are open.
pub fn count() usize {
    return wins.items.len;
}

/// A new window with one card holding an empty untitled file.
pub fn newDoc() ?*Doc {
    const leaf = gpa.create(Node) catch return null;
    const w = gpa.create(Win) catch return null;
    wins.append(gpa, w) catch return null;

    const frame: Rect = .{ .w = 880, .h = 720 };
    const style: usize = 1 | 2 | 4 | 8 | (1 << 15);
    const win = msg(Id, msg(Id, objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ frame, style, @as(usize, 2), false });
    const view = msg(Id, msg(Id, view_class, "alloc", .{}), "initWithFrame:", .{frame});
    w.* = .{ .window = win, .view = view, .cards = leaf, .focus = undefined };
    setWin(view, w);
    msg(void, view, "setWantsLayer:", .{true});
    msg(void, view, "registerForDraggedTypes:", .{msg(Id, objc.class("NSArray"), "arrayWithObject:", .{NSPasteboardTypeFileURL})});
    // Hovering a tab lights it and shows its close button: mouse moves and
    // exits while Zag is in front, over the whole view at any size.
    const area = msg(Id, msg(Id, objc.class("NSTrackingArea"), "alloc", .{}), "initWithRect:options:owner:userInfo:", .{ Rect{}, @as(usize, 0x01 | 0x02 | 0x40 | 0x200), view, @as(Id, null) });
    msg(void, view, "addTrackingArea:", .{area});
    msg(void, area, "release", .{});
    w.link = msg(Id, view, "displayLinkWithTarget:selector:", .{ view, objc.sel_registerName("tick:") });
    msg(void, w.link, "addToRunLoop:forMode:", .{ msg(Id, objc.class("NSRunLoop"), "mainRunLoop", .{}), NSRunLoopCommonModes });
    msg(void, w.link, "setPaused:", .{true});
    const d = newPane(w) orelse return null;
    leaf.* = .{ .pane = d };
    w.focus = d;
    d.size = .{ .x = frame.w, .y = frame.h };
    d.fin = d.size;
    msg(void, win, "setTitlebarAppearsTransparent:", .{true});
    msg(void, win, "setTitleVisibility:", .{@as(isize, 1)});
    // An empty toolbar, so AppKit itself centers the traffic lights on the
    // header's line and gives the window the corners the cards nest in.
    const bar = msg(Id, msg(Id, objc.class("NSToolbar"), "alloc", .{}), "initWithIdentifier:", .{objc.str("ze")});
    msg(void, win, "setToolbar:", .{bar});
    msg(void, bar, "release", .{});
    msg(void, win, "setToolbarStyle:", .{@as(isize, 3)});
    msg(void, win, "setTitlebarSeparatorStyle:", .{@as(isize, 1)});
    msg(void, win, "setMinSize:", .{Point{ .x = 360, .y = 240 }});
    // The sidebar material sits behind the view, which paints its chrome
    // over it with some of the material showing through.
    const fx = msg(Id, msg(Id, objc.class("NSVisualEffectView"), "alloc", .{}), "initWithFrame:", .{frame});
    msg(void, fx, "setMaterial:", .{@as(isize, 7)});
    msg(void, fx, "setBlendingMode:", .{@as(isize, 0)});
    msg(void, fx, "setState:", .{@as(isize, 0)});
    msg(void, view, "setAutoresizingMask:", .{@as(usize, 2 | 16)});
    msg(void, fx, "addSubview:", .{view});
    msg(void, win, "setContentView:", .{fx});
    msg(void, fx, "release", .{});
    msg(void, win, "setOpaque:", .{false});
    msg(void, win, "setBackgroundColor:", .{msg(Id, objc.class("NSColor"), "clearColor", .{})});
    setLights(w, if (conf.zen) 0 else 1);
    msg(void, view, "release", .{});
    msg(void, win, "setDelegate:", .{view});
    msg(void, win, "makeFirstResponder:", .{view});
    if (wins.items.len == 1) {
        msg(void, win, "center", .{});
        _ = msg(bool, win, "setFrameAutosaveName:", .{objc.str("ze")});
    } else {
        const fr = msg(Rect, wins.items[wins.items.len - 2].window, "frame", .{});
        msg(void, win, "setFrame:display:", .{ fr, false });
        msg(void, win, "setFrameTopLeftPoint:", .{Point{ .x = fr.x + 24, .y = fr.y + fr.h - 24 }});
    }
    named(d);
    showWin(win);
    return d;
}

/// A card for window `w` with an empty untitled file and its own caret.
/// The caller puts it in the layout.
fn newPane(w: *Win) ?*Doc {
    const d = gpa.create(Doc) catch return null;
    d.* = .{ .ed = Editor.init(gpa, "") catch return null, .id = newId(), .win = w, .window = w.window, .view = w.view };
    if (conf.focus != .off) d.focus_a.snap(1);
    docs.append(gpa, d) catch return null;
    d.caret = msg(Id, objc.class("CALayer"), "layer", .{});
    msg(void, d.caret, "setCornerRadius:", .{@as(f64, 1)});
    msg(void, d.caret, "setHidden:", .{true});
    msg(void, msg(Id, w.view, "layer", .{}), "addSublayer:", .{d.caret});
    return d;
}

fn alert(text: []const u8, detail: []const u8) void {
    const a = objc.new("NSAlert");
    msg(void, a, "setMessageText:", .{objc.str(text)});
    msg(void, a, "setInformativeText:", .{objc.str(detail)});
    _ = msg(isize, a, "runModal", .{});
    msg(void, a, "release", .{});
}

/// Asks to save the window's unsaved files: the one on show and its pages.
/// Closing the window asks about untitled files' text too, since their
/// drafts go with it; quitting keeps the drafts for next time and doesn't.
/// False when the user cancels.
fn settle(d: *Doc, quit: bool) bool {
    var n: usize = @intFromBool(asks(quit, d.path, &d.ed));
    var page: usize = 0;
    for (d.pages.items, 0..) |*p, i| if (asks(quit, p.path, &p.ed)) {
        n += 1;
        page = i;
    };
    if (n == 0) return true;
    if (n == 1 and !asks(quit, d.path, &d.ed)) showPage(d, page);
    front(d);
    const a = objc.new("NSAlert");
    var buf: [300]u8 = undefined;
    const title = if (n == 1)
        std.fmt.bufPrint(&buf, "Save changes to {s}?", .{d.name()}) catch "Save changes?"
    else
        std.fmt.bufPrint(&buf, "Save changes to {d} files?", .{n}) catch "Save changes?";
    msg(void, a, "setMessageText:", .{objc.str(title)});
    msg(void, a, "setInformativeText:", .{objc.str("Your changes are lost if you don't save them.")});
    _ = msg(Id, a, "addButtonWithTitle:", .{objc.str(if (n == 1) "Save" else "Save All")});
    _ = msg(Id, a, "addButtonWithTitle:", .{objc.str("Don't Save")});
    _ = msg(Id, a, "addButtonWithTitle:", .{objc.str("Cancel")});
    const r = msg(isize, a, "runModal", .{});
    msg(void, a, "release", .{});
    return switch (r) {
        1000 => saveAll(d, quit),
        1001 => true,
        else => false,
    };
}

fn asks(quit: bool, path: ?[:0]const u8, ed: *const Editor) bool {
    return if (quit) path != null and ed.buf.dirty() else loses(path, ed);
}

/// Saves the file on show, then each page `settle` asked about in turn.
fn saveAll(d: *Doc, quit: bool) bool {
    if (asks(quit, d.path, &d.ed) and !save(d, false)) return false;
    while (true) {
        const i = for (d.pages.items, 0..) |*p, j| {
            if (asks(quit, p.path, &p.ed)) break j;
        } else return true;
        showPage(d, i);
        if (!save(d, false)) return false;
    }
}

/// For quitting: every window with unsaved changes to files asks first.
pub fn settleAll() bool {
    for (docs.items) |d| if (!settle(d, true)) return false;
    return true;
}

fn save(d: *Doc, as: bool) bool {
    if (d.path == null or as) {
        const p = msg(Id, objc.class("NSSavePanel"), "savePanel", .{});
        msg(void, p, "setNameFieldStringValue:", .{objc.str(d.name())});
        if (root) |r| msg(void, p, "setDirectoryURL:", .{msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(r)})});
        if (msg(isize, p, "runModal", .{}) != 1) return false;
        const path = objc.utf8(msg(Id, msg(Id, p, "URL", .{}), "path", .{}));
        const z = gpa.dupeSentinel(u8, path, 0) catch return false;
        preview.rename(d.window, d.path orelse "", z);
        if (d.path) |old| gpa.free(old);
        d.path = z;
        d.lang = syntax.forPath(z);
        clearSyntax(d);
        named(d);
    }
    files.write(d.path.?, d.ed.text()) catch {
        alert("Couldn't save this file.", d.path.?);
        return false;
    };
    d.ed.buf.markSaved();
    dropDraft(&d.draft);
    d.stamp = files.stamp(d.path.?);
    d.note = "saved";
    noteRecent(d.path.?);
    if (conf_path != null and std.mem.eql(u8, d.path.?, conf_path.?)) loadSettings();
    // A new file shows in the tree, and its dot goes away.
    rebuildTree();
    refreshAll();
    return true;
}

pub fn openPanel() void {
    const p = msg(Id, objc.class("NSOpenPanel"), "openPanel", .{});
    msg(void, p, "setCanChooseDirectories:", .{true});
    msg(void, p, "setAllowsMultipleSelection:", .{true});
    if (root) |r| msg(void, p, "setDirectoryURL:", .{msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(r)})});
    if (msg(isize, p, "runModal", .{}) != 1) return;
    const urls = msg(Id, p, "URLs", .{});
    for (0..msg(usize, urls, "count", .{})) |i| {
        const path = objc.utf8(msg(Id, msg(Id, urls, "objectAtIndex:", .{i}), "path", .{}));
        open(path, blankDoc());
    }
}

/// File > Open Recent: the last files opened or saved, newest first.
fn noteRecent(p: []const u8) void {
    if (conf_path != null and std.mem.eql(u8, p, conf_path.?)) return;
    const s = objc.str(p);
    const out = msg(Id, objc.class("NSMutableArray"), "arrayWithObject:", .{s});
    const old = recentFiles();
    for (0..msg(usize, old, "count", .{})) |i| {
        if (msg(usize, out, "count", .{}) >= 15) break;
        const o = msg(Id, old, "objectAtIndex:", .{i});
        if (!msg(bool, o, "isEqualToString:", .{s})) msg(void, out, "addObject:", .{o});
    }
    msg(void, defaults(), "setObject:forKey:", .{ out, objc.str("recent") });
}

pub fn recentFiles() Id {
    const list = msg(Id, defaults(), "stringArrayForKey:", .{objc.str("recent")});
    return if (list != null) list else msg(Id, objc.class("NSArray"), "array", .{});
}

pub fn clearRecent() void {
    msg(void, defaults(), "removeObjectForKey:", .{objc.str("recent")});
}

// ---- places and sessions ----

fn defaults() Id {
    return msg(Id, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
}

const Place = struct { cur: usize, sy: f64 };

/// Splits a saved "a\tb\tpath" entry.
fn fields(s: []const u8, comptime n: usize) ?[n + 1][]const u8 {
    var out: [n + 1][]const u8 = undefined;
    var rest = s;
    for (0..n) |i| {
        const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
        out[i] = rest[0..tab];
        rest = rest[tab + 1 ..];
    }
    out[n] = rest;
    return out;
}

/// Where the caret and scroll were in recent files, newest first, as
/// "cur\tsy\tpath" lines, at most 100. Read from the defaults on first use
/// and written back a second after a change (and at quit), so switching
/// tabs doesn't rewrite the defaults each time.
var places: std.ArrayList([]u8) = .empty;
var places_read = false;
var places_due = false;

extern var _dispatch_main_q: anyopaque;
extern fn dispatch_time(when: u64, delta: i64) u64;
extern fn dispatch_after_f(when: u64, queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

fn loadPlaces() void {
    if (places_read) return;
    places_read = true;
    const list = msg(Id, defaults(), "stringArrayForKey:", .{objc.str("places")});
    if (list == null) return;
    for (0..msg(usize, list, "count", .{})) |i| {
        const s = objc.utf8(msg(Id, list, "objectAtIndex:", .{i}));
        if (fields(s, 2) == null) continue;
        const own = gpa.dupe(u8, s) catch return;
        places.append(gpa, own) catch return gpa.free(own);
    }
}

/// Remembers where the caret and scroll were in `d`'s file, newest first.
fn rememberPlace(d: *const Doc) void {
    const p = d.path orelse return;
    loadPlaces();
    var buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "{d}\t{d}\t", .{ d.ed.cur, @as(i64, @intFromFloat(d.sy)) }) catch return;
    const entry = std.mem.concat(gpa, u8, &.{ head, p }) catch return;
    var i: usize = 0;
    while (i < places.items.len) {
        if (std.mem.eql(u8, fields(places.items[i], 2).?[2], p)) gpa.free(places.orderedRemove(i)) else i += 1;
    }
    places.insert(gpa, 0, entry) catch return gpa.free(entry);
    while (places.items.len > 100) gpa.free(places.pop().?);
    if (places_due) return;
    places_due = true;
    dispatch_after_f(dispatch_time(0, std.time.ns_per_s), &_dispatch_main_q, null, writePlaces);
}

/// Puts `places` in the defaults.
fn writePlaces(_: ?*anyopaque) callconv(.c) void {
    places_due = false;
    const out = msg(Id, objc.class("NSMutableArray"), "arrayWithCapacity:", .{places.items.len});
    for (places.items) |s| msg(void, out, "addObject:", .{objc.str(s)});
    msg(void, defaults(), "setObject:forKey:", .{ out, objc.str("places") });
}

fn placeOf(p: []const u8) ?Place {
    loadPlaces();
    for (places.items) |s| {
        const fs = fields(s, 2).?;
        if (!std.mem.eql(u8, fs[2], p)) continue;
        return .{
            .cur = std.fmt.parseInt(usize, fs[0], 10) catch 0,
            .sy = @floatFromInt(std.fmt.parseInt(i64, fs[1], 10) catch 0),
        };
    }
    return null;
}

/// On quit: every window's frame and cards, back to front, for next launch.
/// A window is its frame, then its layout, tab-separated: a split is
/// `|r` or `|d` (side by side or one above the other) and the first
/// card's share, followed by its two halves; a card is `#n,a,f` (n tabs,
/// the tab on show, 1 when it has the focus) followed by its n files, an
/// untitled one as `*` and its draft. Empty untitled tabs aren't kept.
pub fn saveSession() void {
    saveDrafts();
    quitting = true;
    for (docs.items) |d| rememberPlace(d);
    if (places_due) writePlaces(null);
    const out = msg(Id, objc.class("NSMutableArray"), "array", .{});
    const order = msg(Id, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "orderedWindows", .{});
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    var i = msg(usize, order, "count", .{});
    while (i > 0) {
        i -= 1;
        const w = msg(Id, order, "objectAtIndex:", .{i});
        for (wins.items) |wn| if (wn.window == w) {
            line.clearRetainingCapacity();
            line.appendSlice(gpa, objc.utf8(msg(Id, w, "stringWithSavedFrame", .{}))) catch continue;
            const kept = saveLayout(wn, wn.cards, &line) catch continue;
            if (kept > 0) msg(void, out, "addObject:", .{objc.str(line.items)});
        };
    }
    msg(void, defaults(), "setObject:forKey:", .{ out, objc.str("session") });
    if (root) |r| {
        msg(void, defaults(), "setObject:forKey:", .{ objc.str(r), objc.str("root") });
    } else msg(void, defaults(), "removeObjectForKey:", .{objc.str("root")});
}

/// Writes `n`'s part of the session line. Returns how many files it kept.
fn saveLayout(w: *const Win, n: *const Node, out: *std.ArrayList(u8)) !usize {
    if (n.pane) |d| {
        var kept: usize = 0;
        var on: usize = 0;
        for (0..tabCount(d)) |j| if (tabPath(d, j) != null or tabDraft(d, j) != null) {
            if (j == d.at) on = kept;
            kept += 1;
        };
        try out.print(gpa, "\t#{d},{d},{d}", .{ kept, on, @intFromBool(w.focus == d) });
        for (0..tabCount(d)) |j| {
            if (tabPath(d, j)) |p| {
                try out.print(gpa, "\t{s}", .{p});
            } else if (tabDraft(d, j)) |p| try out.print(gpa, "\t*{s}", .{p});
        }
        return kept;
    }
    // A card folding away is already gone.
    if (n.going) |g| return saveLayout(w, n.kids[1 - g], out);
    // Thousandths in integers: std's float printer is about 16 KB of Zag.
    const m: u32 = @intFromFloat(@round(std.math.clamp(n.share.to, 0, 1) * 1000));
    try out.print(gpa, "\t|{c}{d}.{d:0>3}", .{ @as(u8, if (n.down) 'd' else 'r'), m / 1000, m % 1000 });
    return try saveLayout(w, n.kids[0], out) + try saveLayout(w, n.kids[1], out);
}

/// Reopens last session's windows where they were, with their cards and
/// tabs, and its folder when Zag started without one. False when no window
/// opened.
pub fn restoreSession() bool {
    if (root == null) {
        const saved = msg(Id, defaults(), "stringForKey:", .{objc.str("root")});
        if (saved != null) {
            const z = gpa.dupeSentinel(u8, objc.utf8(saved), 0) catch return false;
            if (files.isDir(z)) setRoot(z) else gpa.free(z);
        }
    }
    const list = msg(Id, defaults(), "stringArrayForKey:", .{objc.str("session")});
    if (list == null) return false;
    restoring = true;
    for (0..msg(usize, list, "count", .{})) |i| {
        const entry = objc.utf8(msg(Id, list, "objectAtIndex:", .{i}));
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse continue;
        var it = std.mem.splitScalar(u8, entry[tab + 1 ..], '\t');
        restoreWindow(entry[0..tab], &it);
    }
    restoring = false;
    if (tree_stale) {
        tree_stale = false;
        rebuildTree();
    }
    refreshAll();
    return docs.items.len > 0;
}

/// A window from one session line, or none when none of its files are left.
fn restoreWindow(frame: []const u8, it: *std.mem.SplitIterator(u8, .scalar)) void {
    const blank = newDoc() orelse return;
    const w = blank.win;
    var lit: ?*Doc = null;
    const n = restoreNode(w, it, &lit) orelse return msg(void, w.window, "close", .{});
    // The restored cards take the place of the blank one the window came with.
    closePane(blank);
    freeNodes(w.cards);
    w.cards = n;
    w.focus = lit orelse firstPane(n);
    named(w.focus);
    msg(void, w.window, "setFrameFromString:", .{objc.str(frame)});
}

/// The cards that `it` describes next, leaving out files that are gone and
/// cards left with none. A line from before cards is just a file.
fn restoreNode(w: *Win, it: *std.mem.SplitIterator(u8, .scalar), lit: *?*Doc) ?*Node {
    const tok = it.next() orelse return null;
    if (tok.len > 1 and tok[0] == '|') {
        const a = restoreNode(w, it, lit);
        const b = restoreNode(w, it, lit);
        if (a == null or b == null) return a orelse b;
        const n = gpa.create(Node) catch return a;
        n.* = .{ .down = tok[1] == 'd', .kids = .{ a.?, b.? } };
        n.share.snap(std.math.clamp(settings.number(tok[2..]) orelse 0.5, 0.05, 0.95));
        a.?.up = n;
        b.?.up = n;
        return n;
    }
    var head: [3]usize = .{ 1, 0, 0 };
    var first: ?[]const u8 = tok;
    if (tok.len > 0 and tok[0] == '#') {
        first = null;
        var nums = std.mem.splitScalar(u8, tok[1..], ',');
        for (&head) |*v| v.* = std.fmt.parseInt(usize, nums.next() orelse "0", 10) catch 0;
    }
    const d = newPane(w) orelse return null;
    var on: ?usize = null;
    for (0..head[0]) |i| {
        const p = (if (i == 0) first else null) orelse it.next() orelse break;
        const draft = p.len > 0 and p[0] == '*';
        const z = gpa.dupeSentinel(u8, if (draft) p[1..] else p, 0) catch continue;
        defer gpa.free(z);
        if (!files.exists(z)) continue;
        var pg = (if (draft) loadDraft(z) else loadPage(z)) orelse continue;
        if (!park(d, true)) {
            // A draft that can't open stays on disk for `adoptDrafts`.
            if (pg.draft) |s| gpa.free(s);
            pg.draft = null;
            pg.deinit();
            continue;
        }
        install(d, pg);
        if (i == head[1] or on == null) on = d.at;
    }
    if (on == null) {
        closePane(d);
        return null;
    }
    showTab(d, on.?);
    if (head[2] == 1) lit.* = d;
    const n = gpa.create(Node) catch {
        closePane(d);
        return null;
    };
    n.* = .{ .pane = d };
    return n;
}

// ---- drafts ----

/// Untitled files keep their text in a draft file here as it changes, so
/// it's never lost: `~/Library/Application Support/ze/Drafts`.
fn draftsDir(buf: []u8) ?[:0]const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    return std.fmt.bufPrintSentinel(buf, "{s}/Library/Application Support/ze/Drafts", .{home}, 0) catch null;
}

/// Saves the drafts a second after the typing stops.
fn laterDrafts(view: Id) void {
    const sel = objc.sel_registerName("saveDrafts:");
    msg(void, objc.class("NSObject"), "cancelPreviousPerformRequestsWithTarget:selector:object:", .{ view, sel, @as(Id, null) });
    msg(void, view, "performSelector:withObject:afterDelay:", .{ sel, @as(Id, null), @as(f64, 1) });
}

fn saveDraftsNow(_: Id, _: Sel, _: Id) callconv(.c) void {
    saveDrafts();
}

/// Writes every untitled file that changed since its draft last did. One
/// that's empty again loses its draft.
fn saveDrafts() void {
    for (docs.items) |d| {
        keepDraft(d.path, &d.ed, &d.draft, &d.drafted);
        for (d.pages.items) |*p| keepDraft(p.path, &p.ed, &p.draft, &p.drafted);
    }
}

fn keepDraft(path: ?[:0]u8, ed: *const Editor, draft: *?[:0]u8, drafted: *u64) void {
    if (path != null or ed.buf.changes == drafted.*) return;
    if (ed.text().len == 0) {
        dropDraft(draft);
        drafted.* = ed.buf.changes;
        return;
    }
    if (draft.* == null) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = draftsDir(&buf) orelse return;
        const secs: u64 = @intFromFloat(@max(msg(f64, objc.class("NSDate"), "timeIntervalSinceReferenceDate", .{}), 0));
        draft.* = std.fmt.allocPrintSentinel(gpa, "{s}/{d}-{d}.txt", .{ dir, secs, newId() }, 0) catch return;
        files.makeParent(draft.*.?) catch return;
    }
    files.write(draft.*.?, ed.text()) catch return;
    drafted.* = ed.buf.changes;
}

/// Deletes a draft once its text is saved to a file or its tab is closed.
/// Not while quitting, though: AppKit closes the windows on the way out,
/// and their drafts are for next time.
fn dropDraft(draft: *?[:0]u8) void {
    const p = draft.* orelse return;
    if (!quitting) _ = std.c.unlink(p);
    gpa.free(p);
    draft.* = null;
}

/// Set once the session is saved on the way out.
var quitting = false;

/// An untitled tab with the text of the draft at `abs`.
fn loadDraft(abs: [:0]const u8) ?Page {
    const bytes = files.read(gpa, abs) catch return null;
    defer gpa.free(bytes);
    var ed = Editor.init(gpa, bytes) catch return null;
    const own = gpa.dupeSentinel(u8, abs, 0) catch {
        ed.deinit(gpa);
        return null;
    };
    return .{ .ed = ed, .path = null, .lang = &syntax.plain, .stamp = null, .sx = 0, .sy = 0, .id = newId(), .draft = own, .drafted = ed.buf.changes, .fresh = true };
}

/// At launch: drafts that no tab holds, left by a crash or a start that
/// opened files instead of the last session, come back as tabs in the front
/// window.
pub fn adoptDrafts() void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = draftsDir(&buf) orelse return;
    const dh = std.c.opendir(dir) orelse return;
    defer _ = std.c.closedir(dh);
    while (std.c.readdir(dh)) |e| {
        const name = std.mem.sliceTo(&e.name, 0);
        if (name.len == 0 or name[0] == '.' or !std.mem.endsWith(u8, name, ".txt")) continue;
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const abs = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (draftHeld(abs)) continue;
        var pg = loadDraft(abs) orelse continue;
        const d = keyDoc() orelse (if (docs.items.len > 0) docs.items[0] else newDoc()) orelse {
            if (pg.draft) |s| gpa.free(s);
            pg.draft = null;
            return pg.deinit();
        };
        if (!park(d, true)) {
            if (pg.draft) |s| gpa.free(s);
            pg.draft = null;
            pg.deinit();
            continue;
        }
        install(d, pg);
    }
}

fn draftHeld(abs: []const u8) bool {
    for (docs.items) |d| {
        if (d.draft) |p| if (std.mem.eql(u8, p, abs)) return true;
        for (d.pages.items) |pg| if (pg.draft) |p| if (std.mem.eql(u8, p, abs)) return true;
    }
    return false;
}

// ---- changes from outside ----

fn sameStamp(a: ?files.Stamp, b: ?files.Stamp) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

/// When Zag comes forward: picks up settings and files that other apps changed.
pub fn recheckAll() void {
    if (conf_path) |p| if (!sameStamp(files.stamp(p), conf_stamp)) loadSettings();
    for (docs.items) |d| checkOutside(d);
    // The rows and their cached lines stay unless a read folder moved on
    // disk or the open set changed (see `Tree.fresh`).
    if (!tree.fresh()) rebuildTree();
    refreshAll();
}

/// A clean doc reloads from disk; one with unsaved changes asks first. A
/// deleted file leaves the text as unsaved changes.
fn checkOutside(d: *Doc) void {
    const p = d.path orelse return;
    const now = files.stamp(p);
    if (sameStamp(now, d.stamp)) return;
    d.stamp = now;
    if (now == null) {
        d.ed.buf.saved = std.math.maxInt(u64);
        d.note = "deleted on disk";
        return refresh(d);
    }
    if (d.ed.buf.dirty() and !askReload(d)) return;
    const bytes = files.read(gpa, p) catch return;
    defer gpa.free(bytes);
    d.ed.reload(gpa, bytes) catch return;
    d.note = "reloaded";
    refresh(d);
}

fn askReload(d: *Doc) bool {
    // A Dev build never puts an alert in front of Harsha: it keeps its copy.
    if (background) return false;
    msg(void, d.window, "makeKeyAndOrderFront:", .{@as(Id, null)});
    const a = objc.new("NSAlert");
    var buf: [300]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "{s} changed in another app.", .{d.name()}) catch "This file changed in another app.";
    msg(void, a, "setMessageText:", .{objc.str(title)});
    msg(void, a, "setInformativeText:", .{objc.str("Reloading it loses your unsaved changes here.")});
    _ = msg(Id, a, "addButtonWithTitle:", .{objc.str("Keep Mine")});
    _ = msg(Id, a, "addButtonWithTitle:", .{objc.str("Reload")});
    const r = msg(isize, a, "runModal", .{});
    msg(void, a, "release", .{});
    return r == 1001;
}

// ---- settings ----

/// Sets the colors that draw from the settings' themes: grey in zen, and
/// with Increase Contrast on, muted text lifted to the text color at 0.8.
fn buildThemes() void {
    themes = .{ conf.light, conf.dark };
    if (conf.zen) for (&themes) |*th| {
        inline for (@typeInfo(Theme).@"struct".field_names) |name| {
            const c = &@field(th, name);
            if (@TypeOf(c.*) == Rgb) desaturate(c) else for (c) |*k| desaturate(k);
        }
    };
    if (contrast) for (&themes) |*th| {
        for (&th.muted, th.bg, th.fg) |*m, back, text| m.* = back + 0.8 * (text - back);
    };
}

/// Crossfades the window to what draws next, for a theme or appearance
/// change: one fade over the view's layer and each caret layer.
fn fadeTheme(w: *Win) void {
    const t = msg(Id, objc.class("CATransition"), "animation", .{});
    msg(void, t, "setType:", .{objc.str("fade")});
    msg(void, t, "setDuration:", .{@as(f64, 0.25)});
    msg(void, t, "setTimingFunction:", .{msg(Id, objc.class("CAMediaTimingFunction"), "functionWithName:", .{objc.str("easeInEaseOut")})});
    msg(void, msg(Id, w.view, "layer", .{}), "addAnimation:forKey:", .{ t, objc.str("theme") });
    for (docs.items) |d| if (d.win == w) msg(void, d.caret, "addAnimation:forKey:", .{ t, objc.str("theme") });
}

/// Reads the settings file and applies it to every window.
pub fn loadSettings() void {
    if (conf_path == null) conf_path = settings.path(gpa) catch null;
    // Once the file exists, use the path open() gives it (/tmp is /private/tmp).
    if (conf_path != null and files.exists(conf_path.?)) {
        if (files.absolute(gpa, conf_path.?)) |abs| {
            gpa.free(conf_path.?);
            conf_path = abs;
        } else |_| {}
    }
    const p = conf_path orelse return;
    const old_lh = lh;
    const old_themes = themes;
    const old_look = conf.look;
    const old_zen = conf.zen;
    conf = settings.load(gpa, p);
    buildThemes();
    // A theme or appearance pick crossfades; zen's own change doesn't.
    const crossfade = conf.look != old_look or (conf.zen == old_zen and !std.meta.eql(old_themes, themes));
    side_w = conf.sidebar_width;
    conf_stamp = files.stamp(p);
    setFont();
    if (wrap_item != null) msg(void, wrap_item, "setState:", .{@as(isize, @intFromBool(conf.wrap))});
    if (pairs_item != null) msg(void, pairs_item, "setState:", .{@as(isize, @intFromBool(conf.pairs))});
    if (sidebar_item != null) msg(void, sidebar_item, "setState:", .{@as(isize, @intFromBool(conf.sidebar))});
    if (typewriter_item != null) msg(void, typewriter_item, "setState:", .{@as(isize, @intFromBool(conf.typewriter))});
    for (focus_items, 0..) |it, i| {
        if (it != null) msg(void, it, "setState:", .{@as(isize, @intFromBool(i == @intFromEnum(conf.focus)))});
    }
    if (zen_item != null) msg(void, zen_item, "setState:", .{@as(isize, @intFromBool(conf.zen))});
    dropIcons();
    for (scheme_items, 0..) |it, i| {
        if (it != null) msg(void, it, "setState:", .{@as(isize, @intFromBool(i == conf.light_scheme or i == conf.dark_scheme))});
    }
    for (look_items, 0..) |it, i| {
        if (it != null) msg(void, it, "setState:", .{@as(isize, @intFromBool(i == @intFromEnum(conf.look)))});
    }
    // Auto leaves it to the Mac; Light and Dark pin every window.
    const look: Id = switch (conf.look) {
        .auto => null,
        .light => msg(Id, objc.class("NSAppearance"), "appearanceNamed:", .{objc.str("NSAppearanceNameAqua")}),
        .dark => msg(Id, objc.class("NSAppearance"), "appearanceNamed:", .{objc.str("NSAppearanceNameDarkAqua")}),
    };
    msg(void, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "setAppearance:", .{look});
    for (wins.items) |w| {
        if (crossfade) fadeTheme(w);
        w.side_find = true;
        msg(void, w.window, "invalidateCursorRectsForView:", .{w.view});
    }
    for (docs.items) |d| {
        d.dark = null;
        d.sy = d.sy / old_lh * lh;
        d.ys.snap(d.sy);
        d.band_on = false;
        d.snap = true;
        reveal(d);
        refresh(d);
    }
}

/// Rewrites one line of the settings file and applies it.
fn store(key: []const u8, value: []const u8) void {
    const p = conf_path orelse return;
    settings.store(gpa, p, &conf, key, value) catch return alert("Couldn't write the settings file.", p);
    loadSettings();
    for (docs.items) |d| if (d.path != null and std.mem.eql(u8, d.path.?, conf_path.?)) checkOutside(d);
}

pub fn openSettings() void {
    const p = conf_path orelse return;
    settings.ensure(gpa, p, &conf) catch return alert("Couldn't write the settings file.", p);
    loadSettings();
    open(conf_path.?, blankDoc());
}

pub fn toggleWrap() void {
    store("wrap", if (conf.wrap) "off" else "on");
}

pub fn togglePairs() void {
    store("pairs", if (conf.pairs) "off" else "on");
}

pub fn toggleSidebar() void {
    store("sidebar", if (conf.sidebar) "off" else "on");
}

pub fn toggleTypewriter() void {
    store("typewriter", if (conf.typewriter) "off" else "on");
}

pub fn pickFocus(i: usize) void {
    if (i < focus_items.len) store("focus", @tagName(@as(settings.Focus, @enumFromInt(i))));
}

pub fn toggleZen() void {
    store("zen", if (conf.zen) "off" else "on");
}

fn desaturate(c: *Rgb) void {
    c.* = @splat(c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722);
}

/// Makes built-in theme `i` the one for its own mode, light or dark.
pub fn pickScheme(i: usize) void {
    if (i >= settings.schemes.len) return;
    const sc = settings.schemes[i];
    store(if (sc.dark) "dark-theme" else "light-theme", sc.key);
}

/// View > Theme > Appearance: 0 Auto, 1 Light, 2 Dark.
pub fn pickLook(i: usize) void {
    if (i > 2) return;
    store("appearance", @tagName(@as(settings.Look, @enumFromInt(i))));
}

// ---- prompt ----

fn startPrompt(d: *Doc, m: Mode) void {
    d.mode = m;
    d.prompt.clearRetainingCapacity();
    d.fresh = false;
    d.fresh_shown = false;
    d.fresh_w = 0;
    d.note = "";
    const was_palette = d.palette;
    switch (m) {
        .find, .replace => {
            d.which = 0;
            const s = d.ed.sel();
            const picked = d.ed.text()[s[0]..s[1]];
            const seed = if (picked.len > 0 and std.mem.indexOfScalar(u8, picked, '\n') == null) picked else d.query.items;
            d.prompt.appendSlice(gpa, seed) catch {};
            d.fresh = true;
            d.origin = s[0];
            countFound(d);
        },
        .open => {
            if (d.list) |*l| l.deinit();
            d.list = null;
            // Without a folder, quick open lists the folder of the file on screen.
            const r = root orelse blk: {
                const p = d.path orelse {
                    d.mode = .edit;
                    d.note = "open a folder first (⌘O)";
                    return refresh(d);
                };
                setRoot(gpa.dupe(u8, std.fs.path.dirname(p) orelse "/") catch return);
                break :blk root.?;
            };
            d.list = finder.scan(gpa, r) catch null;
            d.palette = false;
            pickFiles(d);
        },
        .command => {
            listCommands();
            d.palette = true;
            pickFiles(d);
        },
        else => {},
    }
    // The old picks index the other list, so the new one fades in fresh.
    if (d.palette != was_palette) {
        d.prev_n = 0;
        d.prev_none = false;
    }
    refresh(d);
}

/// The names quick open or the palette picks from, while it's open.
fn listing(d: *const Doc) ?[]const []const u8 {
    return switch (d.mode) {
        .open => if (d.list) |l| l.paths.items else null,
        .command => cmd_names.items,
        else => null,
    };
}

fn pickFiles(d: *Doc) void {
    const names = listing(d) orelse return;
    // Rows that change under the typing crossfade from the last picks.
    d.prev_picks = d.picks;
    d.prev_n = if (d.pick_live) d.npicks else 0;
    d.prev_none = d.pick_live and d.npicks == 0;
    d.pick_t0 = CACurrentMediaTime();
    d.npicks = finder.best(names, d.prompt.items, &d.picks);
    d.pick = 0;
}

// ---- command palette ----

/// A menu item the palette lists, with its shortcut and whether it's checked.
const Command = struct { item: Id, keys: []const u8, on: bool };
var cmd_arena: std.heap.ArenaAllocator = .init(gpa);
var cmd_names: std.ArrayList([]const u8) = .empty;
var cmds: std.ArrayList(Command) = .empty;

/// Lists every command in the menu bar, the View menu's first since the
/// palette is mostly for settings. Running one runs its menu item, so the
/// palette never needs its own copy of a command.
fn listCommands() void {
    _ = cmd_arena.reset(.retain_capacity);
    cmd_names = .empty;
    cmds = .empty;
    const bar = msg(Id, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "mainMenu", .{});
    const n: usize = @intCast(msg(isize, bar, "numberOfItems", .{}));
    for (0..2) |pass| for (0..n) |i| {
        const it = msg(Id, bar, "itemAtIndex:", .{@as(isize, @intCast(i))});
        const sub = msg(Id, it, "submenu", .{});
        if (sub == null) continue;
        const view_menu = std.mem.eql(u8, objc.utf8(msg(Id, it, "title", .{})), "View");
        if (view_menu == (pass == 0)) addCommands(sub, "");
    };
}

/// Adds `menu`'s items. A submenu's items are named after it ("Theme: Dark"),
/// or after the greyed-out heading above them ("Light Mode: Paper").
fn addCommands(menu: Id, prefix: []const u8) void {
    const a = cmd_arena.allocator();
    var section = prefix;
    const n: usize = @intCast(msg(isize, menu, "numberOfItems", .{}));
    for (0..n) |i| {
        const it = msg(Id, menu, "itemAtIndex:", .{@as(isize, @intCast(i))});
        if (msg(bool, it, "isSeparatorItem", .{})) {
            section = prefix;
            continue;
        }
        if (msg(bool, it, "isHidden", .{})) continue;
        const title = objc.utf8(msg(Id, it, "title", .{}));
        const sub = msg(Id, it, "submenu", .{});
        if (sub != null) {
            // Open Recent fills itself only as it opens.
            if (msg(Id, sub, "delegate", .{}) == null) addCommands(sub, title);
            continue;
        }
        const act = msg(Sel, it, "action", .{});
        if (act == null or objc.sel_getName(act)[0] == 0) {
            section = title;
            continue;
        }
        if (act == objc.sel_registerName("commandPalette:")) continue;
        const name = (if (section.len > 0) std.fmt.allocPrint(a, "{s}: {s}", .{ section, title }) else a.dupe(u8, title)) catch return;
        cmd_names.append(a, name) catch return;
        cmds.append(a, .{ .item = it, .keys = keysOf(a, it) catch "", .on = msg(isize, it, "state", .{}) == 1 }) catch return;
    }
}

/// A menu item's shortcut as the menu shows it, like ⇧⌘S.
fn keysOf(a: std.mem.Allocator, it: Id) ![]const u8 {
    const key = objc.utf8(msg(Id, it, "keyEquivalent", .{}));
    if (key.len == 0) return "";
    const mods = msg(usize, it, "keyEquivalentModifierMask", .{});
    var out: std.ArrayList(u8) = .empty;
    if (mods & ctrl_key != 0) try out.appendSlice(a, "⌃");
    if (mods & opt_key != 0) try out.appendSlice(a, "⌥");
    if (mods & shift_key != 0) try out.appendSlice(a, "⇧");
    if (mods & cmd_key != 0) try out.appendSlice(a, "⌘");
    if (std.mem.eql(u8, key, "\t") or std.mem.eql(u8, key, "\x19")) {
        try out.appendSlice(a, "⇥");
    } else for (key) |ch| try out.append(a, std.ascii.toUpper(ch));
    return out.items;
}

/// Runs a palette pick after the event that chose it, so a command that
/// closes the window doesn't pull the window out from under the prompt.
fn runCommand(_: Id, _: Sel, it: Id) callconv(.c) void {
    const menu = msg(Id, it, "menu", .{});
    if (menu == null) return;
    const i = msg(isize, menu, "indexOfItem:", .{it});
    if (i >= 0) msg(void, menu, "performActionForItemAtIndex:", .{i});
}

fn countFound(d: *Doc) void {
    const t = d.ed.text();
    const q = d.prompt.items;
    d.found = .{ editor.countMatches(t[0..d.ed.sel()[0]], q) + 1, editor.countMatches(t, q) };
}

/// The prompt field that takes typing: the replacement, or the search.
fn field(d: *Doc) *std.ArrayList(u8) {
    return if (d.mode == .replace and d.which == 1) &d.with else &d.prompt;
}

fn promptType(d: *Doc, s: []const u8) void {
    const into = field(d);
    if (d.fresh) into.clearRetainingCapacity();
    d.fresh = false;
    if (d.mode == .line) {
        for (s) |c| if (std.ascii.isDigit(c)) into.append(gpa, c) catch {};
    } else into.appendSlice(gpa, s) catch {};
    promptChanged(d);
}

fn promptChanged(d: *Doc) void {
    switch (d.mode) {
        .find, .replace => if (d.which == 0) {
            if (!d.ed.find(d.prompt.items, d.origin, false)) d.ed.select(d.origin, d.origin);
            remember(d);
            countFound(d);
            center(d);
        },
        .open, .command => pickFiles(d),
        else => {},
    }
}

/// Keeps the search for ⌘G after the prompt closes.
fn remember(d: *Doc) void {
    d.query.clearRetainingCapacity();
    d.query.appendSlice(gpa, d.prompt.items) catch {};
}

/// Enter in the prompt.
fn accept(d: *Doc) void {
    const q = d.prompt.items;
    switch (d.mode) {
        .find => {
            remember(d);
            d.fresh = false;
            findAgain(d, shiftHeld());
        },
        .line => {
            d.mode = .edit;
            const n = std.fmt.parseInt(usize, q, 10) catch return;
            const row = @min(@max(n, 1), d.ed.buf.lines()) - 1;
            d.ed.moveTo(d.ed.buf.lineStart(row), false);
            center(d);
        },
        .open => {
            if (d.npicks == 0) return;
            d.mode = .edit;
            const rel = d.list.?.paths.items[d.picks[d.pick]];
            var buf: [std.c.PATH_MAX]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root.?, rel }) catch return;
            open(path, d);
        },
        .command => {
            if (d.npicks == 0) return;
            d.mode = .edit;
            const it = cmds.items[d.picks[d.pick]].item;
            msg(void, d.view, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("runCommand:"), it, @as(f64, 0) });
        },
        .replace => {
            remember(d);
            d.fresh = false;
            const s = d.ed.sel();
            const replaced = d.ed.replaceOne(gpa, q, d.with.items) catch false;
            if (d.ed.find(q, if (replaced) d.ed.cur else s[0], false)) d.jumped = true;
            countFound(d);
            center(d);
        },
        .edit => {},
    }
}

var note_buf: [40]u8 = undefined;

/// ⌥Return in find and replace.
fn replaceAll(d: *Doc) void {
    remember(d);
    // Where each replacement will stand once the earlier ones are in.
    var spots: [max_flash][2]usize = undefined;
    var ns: usize = 0;
    const q = d.prompt.items;
    const old = d.ed.text();
    var i: usize = 0;
    while (q.len > 0 and ns < max_flash and i + q.len <= old.len) {
        if (!editor.matchAt(old, i, q)) {
            i += 1;
            continue;
        }
        const lo: usize = @intCast(@as(isize, @intCast(i)) + @as(isize, @intCast(ns)) * (@as(isize, @intCast(d.with.items.len)) - @as(isize, @intCast(q.len))));
        spots[ns] = .{ lo, lo + d.with.items.len };
        ns += 1;
        i += q.len;
    }
    const n = d.ed.replaceAll(gpa, q, d.with.items) catch 0;
    if (n > 0) {
        flashStart(d);
        for (spots[0..ns]) |sp| flashAdd(d, sp[0], sp[1]);
    }
    d.mode = .edit;
    d.note = std.fmt.bufPrint(&note_buf, "replaced {d}", .{n}) catch "";
    center(d);
}

fn findAgain(d: *Doc, back: bool) void {
    const finding = d.mode == .find or d.mode == .replace;
    const q = if (finding) d.prompt.items else d.query.items;
    if (q.len == 0) return startPrompt(d, .find);
    const s = d.ed.sel();
    if (d.ed.find(q, if (back) s[0] else s[0] + 1, back)) d.jumped = true else d.note = "no matches";
    if (finding) countFound(d);
    center(d);
}

fn shiftHeld() bool {
    const ev = msg(Id, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "currentEvent", .{});
    return msg(usize, ev, "modifierFlags", .{}) & shift_key != 0;
}

/// Key commands while the prompt is open.
fn promptCommand(d: *Doc, name: []const u8) void {
    if (is(name, "insertNewline")) return accept(d);
    if (is(name, "insertNewlineIgnoringFieldEditor")) return if (d.mode == .replace) replaceAll(d) else accept(d);
    if (is(name, "cancelOperation")) {
        d.mode = .edit;
        return;
    }
    if (d.mode == .replace and (is(name, "insertTab") or is(name, "insertBacktab"))) {
        d.which ^= 1;
        d.fresh = false;
        return;
    }
    const into = field(d);
    if (is(name, "deleteBackward")) {
        d.fresh = false;
        into.items.len = editor.prevChar(into.items, into.items.len);
    } else if (is(name, "deleteWordBackward") or is(name, "deleteToBeginningOfLine")) {
        into.clearRetainingCapacity();
    } else if (listing(d) != null and (is(name, "moveUp") or is(name, "moveDown"))) {
        if (is(name, "moveUp")) d.pick -|= 1 else d.pick = @min(d.pick + 1, d.npicks -| 1);
        return;
    } else return;
    promptChanged(d);
}

fn is(name: []const u8, comptime want: []const u8) bool {
    return std.mem.eql(u8, name, want);
}

// ---- soft wrap ----

/// One screen row of a line: bytes `start..end`, with display columns
/// `col..ecol`. Without wrap every line is one row.
const Seg = struct { k: usize = 0, start: usize = 0, col: usize = 0, end: usize = 0, ecol: usize = 0 };

/// Rows wrap at the card's width once it's done springing, so a card that
/// grows or shrinks doesn't rewrap every frame.
fn wrapCols(d: *const Doc) usize {
    const cols = @max(@as(usize, @intFromFloat((d.fin.x - 2 * gap - 2 * pad_x) / cw)), 8);
    return if (conf.zen) @min(cols, 80) else cols;
}

/// Brings the row counts up to date after edits, a resize or a font change.
fn layout(d: *Doc) void {
    const b = &d.ed.buf;
    if (!wrapping()) {
        if (b.wraps.items.len > 0) b.wraps.clearAndFree(gpa);
        d.vfirst.clearAndFree(gpa);
        return;
    }
    const cols = wrapCols(d);
    if (cols != d.cols or b.wraps.items.len != b.lines() or d.vfirst.items.len != b.lines() + 1) {
        d.cols = cols;
        b.wraps.resize(gpa, b.lines()) catch return;
        @memset(b.wraps.items, 0);
        b.wraps_from = 0;
    }
    if (b.wraps_from == std.math.maxInt(usize)) return;
    var from = b.wraps_from;
    b.wraps_from = std.math.maxInt(usize);
    for (b.wraps.items[from..], from..) |*w, i| {
        if (w.* == 0) w.* = @intCast(editor.rowCount(b.line(i), cols));
    }
    const old = d.vfirst.items.len;
    d.vfirst.resize(gpa, b.lines() + 1) catch return;
    if (from >= old) from = 0;
    var acc: u32 = if (from == 0) 0 else d.vfirst.items[from];
    for (from..b.lines()) |i| {
        d.vfirst.items[i] = acc;
        acc += b.wraps.items[i];
    }
    d.vfirst.items[b.lines()] = acc;
}

fn totalRows(d: *const Doc) usize {
    return if (wrapping()) d.vfirst.items[d.vfirst.items.len - 1] else d.ed.buf.lines();
}

fn rowOfLine(d: *const Doc, i: usize) usize {
    return if (wrapping()) d.vfirst.items[i] else i;
}

fn lineOfRow(d: *const Doc, r: usize) usize {
    if (!wrapping()) return @min(r, d.ed.buf.lines() - 1);
    const v = d.vfirst.items[0 .. d.vfirst.items.len - 1];
    var lo: usize = 0;
    var hi: usize = v.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (v[mid] <= r) lo = mid else hi = mid;
    }
    return lo;
}

/// Fills in where a row that starts at `s.start` ends.
fn segFrom(d: *const Doc, l: []const u8, s: Seg) Seg {
    if (!wrapping()) return .{ .end = l.len };
    const r = editor.rowEnd(l, s.start, s.col, d.cols);
    return .{ .k = s.k, .start = s.start, .col = s.col, .end = r.end, .ecol = r.col };
}

fn nextSeg(d: *const Doc, l: []const u8, s: Seg) Seg {
    return segFrom(d, l, .{ .k = s.k + 1, .start = s.end, .col = s.ecol });
}

/// The row of line `l` that holds byte `p`; a byte at a wrap starts the next row.
fn segOf(d: *const Doc, l: []const u8, p: usize) Seg {
    var s = segFrom(d, l, .{});
    while (p >= s.end and s.end < l.len) s = nextSeg(d, l, s);
    return s;
}

/// Row `k` of line `l`, or its last row.
fn segN(d: *const Doc, l: []const u8, k: usize) Seg {
    var s = segFrom(d, l, .{});
    while (s.k < k and s.end < l.len) s = nextSeg(d, l, s);
    return s;
}

/// The last place the caret can sit in a row: before the wrap, or the line end.
fn caretEnd(l: []const u8, s: Seg) usize {
    return if (s.end < l.len) editor.prevChar(l, s.end) else l.len;
}

/// Display column of byte `p`, counting from byte `from` at column `col0`.
fn colAt(l: []const u8, from: usize, col0: usize, p: usize) usize {
    var c = col0;
    var i = from;
    while (i < p and i < l.len) {
        const x = editor.cells(l, i, c);
        c += x.w;
        i += x.len;
    }
    return c;
}

/// The caret's screen row, and its column within that row.
fn caretRow(d: *Doc) struct { row: usize, col: usize } {
    layout(d);
    const b = &d.ed.buf;
    const i = b.lineOf(d.ed.cur);
    const l = b.line(i);
    const p = d.ed.cur - b.lineStart(i);
    const s = segOf(d, l, p);
    return .{ .row = rowOfLine(d, i) + s.k, .col = colAt(l, s.start, s.col, p) - s.col };
}

/// Up and down by screen rows while wrapped, keeping the column.
fn vmove(d: *Doc, delta: isize, extend: bool) void {
    const e = &d.ed;
    const b = &e.buf;
    const here = caretRow(d);
    const want = e.want orelse here.col;
    const to = @as(isize, @intCast(here.row)) + delta;
    if (to < 0) return e.moveTo(0, extend);
    if (to >= totalRows(d)) return e.moveTo(e.text().len, extend);
    const r: usize = @intCast(to);
    const i = lineOfRow(d, r);
    const l = b.line(i);
    const s = segN(d, l, r - rowOfLine(d, i));
    const byte = std.math.clamp(editor.byteAtCol(l, f(s.col + want)), s.start, caretEnd(l, s));
    e.moveTo(b.lineStart(i) + byte, extend);
    e.want = want;
}

/// ⌘← and ⌘→ while wrapped: the ends of the screen row. False on a line's
/// first row going left, where the editor's smart home takes over.
fn rowEdge(d: *Doc, right: bool, extend: bool) bool {
    const b = &d.ed.buf;
    const i = b.lineOf(d.ed.cur);
    const l = b.line(i);
    const s = segOf(d, l, d.ed.cur - b.lineStart(i));
    if (!right and s.k == 0) return false;
    d.ed.moveTo(b.lineStart(i) + if (right) caretEnd(l, s) else s.start, extend);
    return true;
}

// ---- scrolling ----

/// Lines of blank page that the scroll goes past the last row.
const past_end = 3;

/// The scroll's top and bottom. Typewriter mode lets the first and last
/// rows reach the middle, so the top can be negative.
fn scrollRange(d: *Doc) [2]f64 {
    const lo = if (conf.typewriter) (lh - textH(d)) / 2 else 0;
    const hi = if (conf.typewriter) lo + f(totalRows(d) -| 1) * lh else f(totalRows(d) + past_end) * lh - textH(d);
    return .{ lo, @max(lo, hi) };
}

fn clampScroll(d: *Doc) void {
    const range = scrollRange(d);
    d.sy = std.math.clamp(d.sy, range[0], range[1]);
    d.sx = if (wrapping()) 0 else @max(d.sx, 0);
}

/// Centers the caret's row in typewriter mode; otherwise scrolls just
/// enough to show it.
fn reveal(d: *Doc) void {
    const c = caretRow(d);
    const y = f(c.row) * lh;
    const th = textH(d);
    if (conf.typewriter) {
        d.sy = y - (th - lh) / 2;
    } else {
        if (y < d.sy) d.sy = y;
        if (y + lh > d.sy + th) d.sy = y + lh - th;
    }
    if (!wrapping()) {
        const x = f(c.col) * cw;
        const tw = rightEdge(d) - gap - 2 * pad_x;
        if (x < d.sx) d.sx = @max(0, x - 8 * cw);
        if (x > d.sx + tw - cw) d.sx = x - tw + 8 * cw;
    }
    clampScroll(d);
}

/// Puts the caret a third of the way down when it's off screen.
fn center(d: *Doc) void {
    const y = f(caretRow(d).row) * lh;
    if (y < d.sy or y + lh > d.sy + textH(d)) d.sy = y - textH(d) / 3;
    reveal(d);
}

/// Redraws `d`'s window, which shows the dot of unsaved changes in its
/// close button when any of its cards has some.
fn refresh(d: *Doc) void {
    // Typewriter mode recenters when the caret moves or the text changes,
    // but not after a wheel scroll alone.
    if (conf.typewriter and (d.center_at != d.ed.cur or d.ed.buf.touched != std.math.maxInt(usize))) reveal(d);
    d.center_at = d.ed.cur;
    if (conf.focus != .off) {
        const b = &d.ed.buf;
        const text = d.ed.text();
        var lo = b.lineOf(d.ed.cur);
        var hi = lo;
        if (conf.focus != .line and std.mem.trim(u8, b.line(lo), " \t\r").len > 0) {
            while (lo > 0 and std.mem.trim(u8, b.line(lo - 1), " \t\r").len > 0) lo -= 1;
            while (hi + 1 < b.lines() and std.mem.trim(u8, b.line(hi + 1), " \t\r").len > 0) hi += 1;
        }
        var start = b.lineStart(lo);
        var end = b.lineStart(hi) + b.line(hi).len;
        if (conf.focus == .sentence) {
            var i = start;
            while (i < end) : (i += 1) {
                if (std.mem.indexOfScalar(u8, ".!?", text[i]) == null) continue;
                if (i >= d.ed.cur) {
                    end = i + 1;
                    break;
                }
                start = i + 1;
            }
            while (start < end and std.ascii.isWhitespace(text[start])) start += 1;
        }
        // A new span fades in as the old one fades out; typing that only
        // moves the span's end doesn't fade.
        if (!d.focus_on) {
            d.focus_new = .{ start, end };
            d.focus_old = d.focus_new;
            d.focus_t0 = 0;
        } else if (start != d.focus_new[0]) {
            d.focus_old = d.focus_new;
            d.focus_new = .{ start, end };
            d.focus_t0 = CACurrentMediaTime();
        } else d.focus_new[1] = end;
    }
    d.focus_on = conf.focus != .off;
    msg(void, d.view, "setNeedsDisplay:", .{true});
    if (d.path == null) {
        if (d.ed.buf.changes != d.drafted) laterDrafts(d.view);
        // An untitled file is renamed after its first line once typing
        // pauses, or at once when the caret leaves that line, as Return
        // does, so its tab doesn't change width with each letter.
        var nb: [48]u8 = undefined;
        if (!std.mem.eql(u8, untitledName(&d.ed, &nb), d.name())) {
            const row = nameRow(&d.ed);
            const sel = objc.sel_registerName("retitle:");
            msg(void, objc.class("NSObject"), "cancelPreviousPerformRequestsWithTarget:selector:object:", .{ d.view, sel, @as(Id, null) });
            if (row != null and row.? != d.ed.buf.lineOf(d.ed.cur)) retitle(d) else msg(void, d.view, "performSelector:withObject:afterDelay:", .{ sel, @as(Id, null), @as(f64, 0.6) });
        }
    }
    preview.update(d, &themes);
    var edited = false;
    for (docs.items) |o| if (o.win == d.win and o.dirty()) {
        edited = true;
    };
    msg(void, d.window, "setDocumentEdited:", .{edited});
    access.changed(d);
}

/// What VoiceOver's elements in `access.zig` read from the window, in the
/// view's coordinates. Nothing here runs unless VoiceOver asks.
pub const ax = struct {
    pub const Card = Doc;
    pub const Window = Win;

    pub fn winOfView(view: Id) ?*Win {
        return winOf(view);
    }

    pub fn alive(d: *const Doc) bool {
        return std.mem.indexOfScalar(*Doc, docs.items, @constCast(d)) != null and !d.closing;
    }

    pub fn winAlive(w: *const Win) bool {
        return std.mem.indexOfScalar(*Win, wins.items, @constCast(w)) != null;
    }

    /// Gives card `d` the typing.
    pub fn focusCard(d: *Doc) void {
        focus(d);
    }

    /// The window's cards in layout order, leaving out ones folding away.
    pub fn cards(w: *const Win, out: []*Doc) usize {
        return listPanes(w.cards, out, 0);
    }

    pub fn name(d: *const Doc) []const u8 {
        return d.name();
    }

    /// Where the text shows in the card.
    pub fn textRect(d: *const Doc) Rect {
        return .{ .x = d.org.x + gap, .y = d.org.y + top_h, .w = rightEdge(d) - gap, .h = @max(bottom(d) - top_h, 0) };
    }

    /// The cell of the character at byte `pos`, one column wide.
    pub fn cell(d: *Doc, pos: usize) Rect {
        layout(d);
        const b = &d.ed.buf;
        const i = b.lineOf(pos);
        const l = b.line(i);
        const p = @min(pos - b.lineStart(i), l.len);
        const s = segOf(d, l, p);
        const row = rowOfLine(d, i) + s.k;
        const col = colAt(l, s.start, s.col, p) - s.col;
        return .{ .x = d.org.x + gap + padL(d) + f(col) * cw - d.vx, .y = d.org.y + top_h + f(row) * lh - d.vy, .w = cw, .h = lh };
    }

    /// The byte nearest `p`.
    pub fn posAtPoint(d: *Doc, p: Point) usize {
        return posAt(d, inPane(d, p));
    }

    /// The bytes on show, from the top row's start to the bottom row's end.
    pub fn visible(d: *Doc) [2]usize {
        return .{ posAt(d, .{ .y = top_h }), posAt(d, .{ .x = 1e9, .y = bottom(d) - 1 }) };
    }

    /// Selects `anchor` to `cur` and brings the caret into view.
    pub fn select(d: *Doc, anchor: usize, cur: usize) void {
        d.ed.select(anchor, cur);
        reveal(d);
        refresh(d);
    }

    /// The card shows its tabs, rather than its file's name alone.
    pub fn tabsShown(d: *const Doc) bool {
        return !conf.zen and d.tabbed.to == 1;
    }

    pub fn tabs(d: *const Doc) usize {
        return tabCount(d);
    }

    pub fn tabAtIndex(d: *const Doc, j: usize) u32 {
        return tabId(d, j);
    }

    pub fn tabOf(d: *const Doc, id: u32) ?usize {
        return tabIndex(d, id);
    }

    pub fn tabTitle(d: *const Doc, j: usize, buf: *[48]u8) []const u8 {
        return tabName(d, j, buf);
    }

    /// Where tab `id` last drew.
    pub fn tabRect(d: *const Doc, id: u32) Rect {
        const s = d.slots.items[slotOf(d, id) orelse return .{}];
        return .{ .x = d.org.x + s.x, .y = d.org.y + gap + head_h / 2 - 12, .w = s.w, .h = 24 };
    }

    /// The tab under `p`, by id.
    pub fn tabUnder(d: *const Doc, p: Point) ?u32 {
        const hit = tabAt(d, inPane(d, p)) orelse return null;
        return tabId(d, hit.j);
    }

    /// Shows tab `id` in its card, as a click on it does.
    pub fn pressTab(d: *Doc, id: u32) bool {
        const j = tabIndex(d, id) orelse return false;
        focus(d);
        showTab(d, j);
        return true;
    }

    pub fn paneUnder(w: *const Win, p: Point) ?*Doc {
        return paneAt(w, p);
    }

    pub fn sidebar(w: *const Win) bool {
        return sideShown(w);
    }

    pub fn sideRect(w: *const Win) Rect {
        return .{ .y = top_h, .w = side_w, .h = @max(msg(Rect, w.view, "bounds", .{}).h - top_h, 0) };
    }

    pub fn rows() []const tree_mod.Row {
        return tree.rows.items;
    }

    /// Counts tree rebuilds, so a row knows when to look itself up again.
    pub fn treeGen() u32 {
        return tree_gen;
    }

    pub fn rowOpen(i: usize) bool {
        const row = tree.rows.items[i];
        return row.dir and tree.isOpen(row.rel);
    }

    /// Where row `i` last drew: pinned under the folder's name, or in the list.
    pub fn rowRect(w: *const Win, i: usize) Rect {
        for (w.stuck[0..w.nstuck], w.stuck_y[0..w.nstuck]) |k, y| if (k == i) return .{ .y = y, .w = side_w, .h = side_h };
        return .{ .y = listTop() + f(i) * side_h - w.side_y, .w = side_w, .h = side_h };
    }

    pub fn rowUnder(w: *const Win, p: Point) ?usize {
        return if (sideShown(w) and p.x < side_w) sideRow(w, p.y) else null;
    }

    /// Opens the file at `rel` in the focused card, or opens or shuts the
    /// folder, as a click on its row does.
    pub fn pressRow(w: *Win, rel: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (rel.len > buf.len) return false;
        @memcpy(buf[0..rel.len], rel);
        const want = buf[0..rel.len];
        // Shutting a folder rebuilds the rows, so look the row up after.
        for (&folds) |*o| if (o.closing) finishFold(o);
        const i = for (tree.rows.items, 0..) |row, k| {
            if (std.mem.eql(u8, row.rel, want)) break k;
        } else return false;
        if (tree.rows.items[i].dir) {
            startFold(i);
            refreshAll();
            return true;
        }
        const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root orelse return false, want }) catch return false;
        defer gpa.free(path);
        open(path, w.focus);
        return true;
    }
};

// ---- drawing ----

fn syncStates(d: *Doc, upto: usize) void {
    const b = &d.ed.buf;
    if (b.touched < d.states.items.len) d.states.shrinkRetainingCapacity(b.touched + 1);
    if (b.touched != std.math.maxInt(usize)) d.lex[0].drop(b.touched);
    b.touched = std.math.maxInt(usize);
    if (d.lang == &syntax.plain) return;
    if (d.states.items.len == 0) d.states.append(gpa, .normal) catch return;
    while (d.states.items.len <= upto and d.states.items.len < b.lines()) {
        const i = d.states.items.len - 1;
        d.states.append(gpa, syntax.lexLine(d.lang, b.line(i), d.states.items[i], null)) catch return;
    }
}

/// Syntax kinds for some lines, in line order.
const Kinds = struct {
    /// Each line and where its kinds start in `kinds`.
    lines: std.ArrayList(struct { line: usize, at: usize }) = .empty,
    kinds: std.ArrayList(syntax.Kind) = .empty,

    fn deinit(x: *Kinds) void {
        x.lines.deinit(gpa);
        x.kinds.deinit(gpa);
    }

    fn clear(x: *Kinds) void {
        x.lines.clearRetainingCapacity();
        x.kinds.clearRetainingCapacity();
    }

    /// Forgets line `from` and every line after it.
    fn drop(x: *Kinds, from: usize) void {
        for (x.lines.items, 0..) |e, i| if (e.line >= from) {
            x.lines.shrinkRetainingCapacity(i);
            x.kinds.shrinkRetainingCapacity(e.at);
            return;
        };
    }
};

/// For a new language or file: every line lexes again.
fn clearSyntax(d: *Doc) void {
    d.states.clearRetainingCapacity();
    for (&d.lex) |*x| x.clear();
}

/// Line `i`'s kinds for this frame, added to `lex[0]`: copied from the last
/// frame when it drew the line, else lexed. `walk` steps through the last
/// frame's lines, as the frame asks for lines in order.
fn lineKinds(d: *Doc, i: usize, l: []const u8, walk: *usize) ?[]const syntax.Kind {
    const now = &d.lex[0];
    const old = d.lex[1].lines.items;
    const at = now.kinds.items.len;
    now.lines.append(gpa, .{ .line = i, .at = at }) catch return null;
    now.kinds.resize(gpa, at + l.len) catch {
        now.lines.items.len -= 1;
        return null;
    };
    const out = now.kinds.items[at..];
    while (walk.* < old.len and old[walk.*].line < i) walk.* += 1;
    if (walk.* < old.len and old[walk.*].line == i) {
        @memcpy(out, d.lex[1].kinds.items[old[walk.*].at..][0..l.len]);
    } else _ = syntax.lexLine(d.lang, l, d.states.items[i], out);
    return out;
}

/// The first line with words on it, which names an untitled file.
fn nameRow(ed: *const Editor) ?usize {
    const b = &ed.buf;
    for (0..b.lines()) |i| if (std.mem.trim(u8, b.line(i), " \t\r#>*-").len > 0) return i;
    return null;
}

/// An untitled file's name: its first line with words on it, cut short
/// with an ellipsis, or "Untitled" while it has none.
fn untitledName(ed: *const Editor, buf: *[48]u8) []const u8 {
    const i = nameRow(ed) orelse return "Untitled";
    const l = std.mem.trim(u8, ed.buf.line(i), " \t\r#>*-");
    var n = @min(l.len, 40);
    while (n < l.len and n > 0 and l[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(buf[0..n], l[0..n]);
    if (n == l.len) return buf[0..n];
    const dots = "…";
    @memcpy(buf[n..][0..dots.len], dots);
    return buf[0 .. n + dots.len];
}

/// Gives an untitled `d` the name its text has now, in its tab and, when
/// it's the focused card, the window's title.
fn retitle(d: *Doc) void {
    if (d.path != null) return;
    var nb: [48]u8 = undefined;
    const nm = untitledName(&d.ed, &nb);
    if (std.mem.eql(u8, nm, d.name())) return;
    @memcpy(d.title[0..nm.len], nm);
    d.title_len = nm.len;
    if (slotOf(d, d.id)) |k| d.slots.items[k].drop();
    if (d.win.focus == d) msg(void, d.window, "setTitle:", .{objc.str(nm)});
    msg(void, d.view, "setNeedsDisplay:", .{true});
}

/// The untitled cards in a window take their new names once typing has
/// paused.
fn retitleNow(self: Id, _: Sel, _: Id) callconv(.c) void {
    for (docs.items) |d| if (d.view == self) retitle(d);
}

fn tabName(d: *const Doc, j: usize, buf: *[48]u8) []const u8 {
    if (tabPath(d, j)) |p| return std.fs.path.basename(p);
    return if (j == d.at) d.name() else untitledName(&d.pages.items[pageOf(d, j)].ed, buf);
}

// ---- sidebar ----

const Icon = enum { closed, opened, sidebar, plus, close, folder, parents, crumb };
/// SF Symbols, which come with macOS, so they cost Zag no size.
const icon_names = [_][:0]const u8{ "chevron.right", "chevron.down", "sidebar.left", "plus", "xmark", "folder.fill", "chevron.down", "chevron.forward" };
/// Symbol images for the light and dark themes, tinted and made on first use.
var icons: [2][icon_names.len]Id = @splat(@splat(null));

/// After the colors or the font size change.
fn dropIcons() void {
    for (&icons) |*set| for (set) |*i| if (i.* != null) {
        msg(void, i.*, "release", .{});
        i.* = null;
    };
}

/// The Mac's own icon for a file of `name`'s kind, the same one Finder
/// shows. Made on first use per extension and kept.
fn iconFor(name: []const u8) Id {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse 0;
    var low: [16]u8 = undefined;
    const ext = if (dot > 0 and name.len - dot - 1 <= low.len) name[dot + 1 ..] else "";
    const key = std.ascii.lowerString(low[0..ext.len], ext);
    if (kind_icons.get(key)) |img| return img;
    const ut = objc.class("UTType");
    const ty = if (key.len > 0) msg(Id, ut, "typeWithFilenameExtension:", .{objc.str(key)}) else null;
    const ws = msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const img = msg(Id, msg(Id, ws, "iconForContentType:", .{ty orelse msg(Id, ut, "typeWithIdentifier:", .{objc.str("public.plain-text")})}), "retain", .{});
    const owned = gpa.dupe(u8, key) catch return img;
    kind_icons.put(gpa, owned, img) catch gpa.free(owned);
    return img;
}

/// By lowercase extension, "" for none.
var kind_icons: std.StringHashMapUnmanaged(Id) = .empty;

fn icon(which: Icon, dark: bool, th: *const Theme) Id {
    const slot = &icons[@intFromBool(dark)][@intFromEnum(which)];
    if (slot.* != null) return slot.*;
    const scale: f64, const weight: f64 = switch (which) {
        .closed, .opened => .{ 0.6, 0.3 },
        .close => .{ 0.55, 0.3 },
        .crumb => .{ 0.64, 0.23 },
        .sidebar, .plus => .{ 1.0, 0 },
        .folder => .{ 15.0 / conf.size, 0 },
        .parents => .{ 9.0 / conf.size, 0.4 },
    };
    const cfg = objc.class("NSImageSymbolConfiguration");
    const sized = msg(Id, cfg, "configurationWithPointSize:weight:", .{ conf.size * scale, weight });
    // Folders take the caret's color in shades of it; the rest are muted.
    const tint = if (which == .folder)
        msg(Id, cfg, "configurationWithHierarchicalColor:", .{msg(Id, nscolor(th.caret), "colorWithAlphaComponent:", .{@as(f64, if (dark) 0.85 else 0.75)})})
    else
        msg(Id, cfg, "configurationWithPaletteColors:", .{msg(Id, objc.class("NSArray"), "arrayWithObject:", .{nscolor(th.muted)})});
    const img = msg(Id, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{ objc.str(icon_names[@intFromEnum(which)]), @as(Id, null) });
    if (img == null) return null;
    const made = msg(Id, img, "imageWithSymbolConfiguration:", .{msg(Id, sized, "configurationByApplyingConfiguration:", .{tint})});
    slot.* = msg(Id, made, "retain", .{});
    return slot.*;
}

fn tileSize() f64 {
    return @round(conf.size + 5);
}

/// A file's icon from `iconFor`, `tileSize` square, with its top left at `x`, `y`.
fn tile(img: Id, x: f64, y: f64) void {
    tileAt(img, x, y, tileSize());
}

/// `tile` with sides of `s`.
fn tileAt(img: Id, x: f64, y: f64, s: f64) void {
    if (img != null) msg(void, img, "drawInRect:fromRect:operation:fraction:respectFlipped:hints:", .{ Rect{ .x = x, .y = y, .w = s, .h = s }, Rect{}, @as(usize, 2), @as(f64, 1), true, @as(Id, null) });
}

/// A capsule behind a button under the mouse, centered on `cx`, `cy`: `a`
/// is how far the hover has faded in and `down` how much of a click's
/// stronger fill is left.
fn hoverPill(ctx: Id, th: *const Theme, a: f64, down: f64, cx: f64, cy: f64) void {
    const alpha = @max(0.08 * a, 0.14 * down);
    if (alpha > 0.001) pill(ctx, th.fg, alpha, cx - 14, cy - 14, 28, 28, 14);
}

/// At most this many chevrons in the header's folder.
const max_marks = 8;

/// The header's folder for `d`'s file as a line in `path_font` that fits
/// `room`: relative to the open folder inside it, with the home folder as
/// ~ outside it, and a gap between folders whose middle it notes in
/// `d.head_marks` for a chevron. Too long a path loses its first folders
/// to an ellipsis, keeping the ones nearest the file. Null for an untitled
/// file or one at the top of the open folder.
fn headLine(d: *Doc, room: f64) Id {
    d.head_n = 0;
    d.head_lw = 0;
    d.head_cut = false;
    const p = d.path orelse return null;
    const dir = std.fs.path.dirname(p) orelse "/";
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    var rel = tilde(&pbuf, dir);
    if (root) |r| {
        if (std.mem.eql(u8, dir, r)) return null;
        if (dir.len > r.len and std.mem.startsWith(u8, dir, r) and dir[r.len] == '/') rel = dir[r.len + 1 ..];
    }
    // The folders, last first, then put in order.
    var parts: [max_marks + 1][]const u8 = undefined;
    var n: usize = 0;
    var dropped = false;
    var it = std.mem.splitBackwardsScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (n == parts.len) {
            dropped = true;
            break;
        }
        parts[n] = part;
        n += 1;
    }
    if (n == 0) return null;
    std.mem.reverse([]const u8, parts[0..n]);
    const sep = "    ";
    const sep_line = uiLine(sep, path_font, 1e9);
    const sep_w = if (sep_line != null) objc.CTLineGetTypographicBounds(sep_line, null, null, null) else 0;
    if (sep_line) |l| objc.CFRelease(l);
    // Drop folders from the start until the rest fits, down to the last one.
    var from: usize = if (dropped) 1 else 0;
    var tbuf: [std.fs.max_path_bytes + 64]u8 = undefined;
    while (true) : (from += 1) {
        var len: usize = 0;
        var marks: [max_marks]usize = undefined;
        var m: usize = 0;
        const lead = from > 0 and from < n;
        if (lead) {
            @memcpy(tbuf[0.."…".len], "…");
            len = "…".len;
        }
        for (parts[@min(from, n - 1)..n], 0..) |part, i| {
            if (i > 0 or lead) {
                if (m < max_marks) {
                    marks[m] = len;
                    m += 1;
                }
                @memcpy(tbuf[len..][0..sep.len], sep);
                len += sep.len;
            }
            @memcpy(tbuf[len..][0..part.len], part);
            len += part.len;
        }
        const text = tbuf[0..len];
        const last = from + 1 >= n;
        var line = uiLine(text, path_font, 1e9);
        if (line != null and objc.CTLineGetTypographicBounds(line, null, null, null) > room) {
            objc.CFRelease(line.?);
            if (!last) continue;
            line = uiLine(text, path_font, room);
            d.head_cut = true;
        }
        if (line == null) return null;
        d.head_cut = d.head_cut or from > 0;
        // The last try is cut at its end to fit; a chevron the cut reached goes too.
        const lw = objc.CTLineGetTypographicBounds(line, null, null, null);
        d.head_lw = lw;
        for (marks[0..m]) |at| {
            const pre = uiLine(text[0..at], path_font, 1e9);
            const x = if (pre != null) objc.CTLineGetTypographicBounds(pre, null, null, null) else 0;
            if (pre) |l| objc.CFRelease(l);
            if (x + sep_w > lw) break;
            d.head_marks[d.head_n] = x + sep_w / 2;
            d.head_n += 1;
        }
        return line;
    }
}

/// Draws `img` centered in the square at `x`, `y` with side `s`.
fn drawIcon(img: Id, x: f64, y: f64, s: f64) void {
    drawIconIn(img, x, y, s, s, 1);
}

/// Draws `img` centered in the `w` by `h` box at `x`, `y`, at opacity `a`.
fn drawIconIn(img: Id, x: f64, y: f64, w: f64, h: f64, a: f64) void {
    if (img == null) return;
    const size = msg(Point, img, "size", .{});
    const r: Rect = .{ .x = @round(x + (w - size.x) / 2), .y = @round(y + (h - size.y) / 2), .w = size.x, .h = size.y };
    msg(void, img, "drawInRect:fromRect:operation:fraction:respectFlipped:hints:", .{ r, Rect{}, @as(usize, 2), a, true, @as(Id, null) });
}

/// The palette and quick open rows: 26pt tall, with the list 4pt in from
/// its top and bottom.
const prow = 26.0;
const ppad = 4.0;
/// Rows fade in a step apart (the first six), each over `row_fade`.
const row_lag = 0.012;
const row_fade = 0.12;
/// Rows that change while typing crossfade over this long.
const xfade_time = 0.08;
/// Width of one glyph cell in a shortcut, and of the checkmark column.
const key_cell = 13.0;
const check_col = 18.0;
var panel_font: Id = null;
var panel_small: Id = null;
var check_img: Id = null;
var check_rgb: Rgb = .{ -1, -1, -1 };

/// `c` mixed toward `bg` by `1 - a`, for text fading in over a flat panel.
fn faded(c: Rgb, bg: Rgb, a: f64) Rgb {
    return .{ bg[0] + (c[0] - bg[0]) * a, bg[1] + (c[1] - bg[1]) * a, bg[2] + (c[2] - bg[2]) * a };
}

/// How many rows the panel's height holds: the picks, or the one "No matches".
fn panelRows(d: *const Doc) usize {
    return @max(d.npicks, 1);
}

/// The row fonts, made on first use.
fn panelFonts() void {
    if (panel_font != null) return;
    panel_font = msg(Id, msg(Id, objc.class("NSFont"), "systemFontOfSize:", .{@as(f64, 13)}), "retain", .{});
    panel_small = msg(Id, msg(Id, objc.class("NSFont"), "systemFontOfSize:", .{@as(f64, 12)}), "retain", .{});
}

/// The baseline of text in `fnt`, centered in a row's height from its top.
fn rowBase(fnt: Id) f64 {
    return @round((prow - objc.CTFontGetAscent(fnt) - objc.CTFontGetDescent(fnt)) / 2 + objc.CTFontGetAscent(fnt));
}

/// Draws `s` in `fnt` with its left edge at `x`, cut to `room`, vertically
/// centered in a row whose top is `y`. Returns its width.
fn rowText(ctx: Id, s: []const u8, fnt: Id, c: Rgb, x: f64, y: f64, room: f64) f64 {
    if (room < 4 or s.len == 0) return 0;
    const line = rowLine(s, fnt, room);
    const base = rowBase(fnt);
    return drawLine(ctx, line, c, x, y + base);
}

/// The lines the palette and quick open drew lately, so an open panel
/// doesn't lay its rows out again every frame. Keyed by text, font and room;
/// a full cache lets its oldest line go. Lines take the context's color, so
/// a theme change doesn't touch them.
const RowLine = struct { key: u64 = 0, line: Id = null };
var row_lines: [128]RowLine = @splat(.{});
var row_next: usize = 0;

/// `uiLine(s, fnt, room)` from `row_lines`, made on a miss. The cache owns it.
fn rowLine(s: []const u8, fnt: Id, room: f64) Id {
    var h = std.hash.Fnv1a_64.init();
    h.update(std.mem.asBytes(&fnt));
    h.update(std.mem.asBytes(&room));
    h.update(s);
    const key = h.final() | 1;
    for (row_lines) |e| if (e.key == key) return e.line;
    const e = &row_lines[row_next];
    row_next = (row_next + 1) % row_lines.len;
    if (e.line) |l| objc.CFRelease(l);
    e.* = .{ .key = key, .line = uiLine(s, fnt, room) };
    return e.line;
}

/// The caret-colored checkmark symbol, made again when the caret color changes.
fn checkImage(th: *const Theme) Id {
    if (check_img != null and std.mem.eql(f64, &check_rgb, &th.caret)) return check_img;
    if (check_img != null) msg(void, check_img, "release", .{});
    check_img = null;
    check_rgb = th.caret;
    const cfg = objc.class("NSImageSymbolConfiguration");
    const sized = msg(Id, cfg, "configurationWithPointSize:weight:", .{ @as(f64, 11), @as(f64, 0.3) });
    const tint = msg(Id, cfg, "configurationWithPaletteColors:", .{msg(Id, objc.class("NSArray"), "arrayWithObject:", .{nscolor(th.caret)})});
    const img = msg(Id, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{ objc.str("checkmark"), @as(Id, null) });
    if (img == null) return null;
    const made = msg(Id, img, "imageWithSymbolConfiguration:", .{msg(Id, sized, "configurationByApplyingConfiguration:", .{tint})});
    check_img = msg(Id, made, "retain", .{});
    return check_img;
}

/// The row shown when nothing matches: one dim "No matches" in the row font,
/// with its top at `top` (pushed down by `rise`), drawn at opacity `a`.
fn panelNone(ctx: Id, th: *const Theme, left: f64, top: f64, a: f64, rise: f64) void {
    if (a < 0.01) return;
    panelFonts();
    _ = rowText(ctx, "No matches", panel_font, faded(th.muted, th.panel, a), left, top + rise, 1e5);
}

/// One row of the palette or quick open list, picked by `p`, whose content
/// runs from `left` to `right`, with its top at `y` (pushed down by `rise`),
/// drawn at opacity `a`.
fn panelRow(ctx: Id, d: *const Doc, th: *const Theme, p: usize, left: f64, right: f64, top: f64, a: f64, rise: f64) void {
    if (a < 0.01) return;
    panelFonts();
    const y = top + rise;
    const ink = faded(th.fg, th.panel, a);
    const dim = faded(th.muted, th.panel, a);
    if (d.palette) {
        if (p >= cmds.items.len) return;
        const c = cmds.items[p];
        const x = left + check_col;
        if (c.on) drawIconIn(checkImage(th), left, y, check_col, prow, a);
        // Shortcuts: one glyph to a cell, flush right like a menu's.
        const cells = std.unicode.utf8CountCodepoints(c.keys) catch 0;
        const keys_w = f(cells) * key_cell;
        var at = right - keys_w;
        var it = (std.unicode.Utf8View.init(c.keys) catch return).iterator();
        while (it.nextCodepointSlice()) |g| : (at += key_cell) {
            const line = rowLine(g, panel_small, 1e5);
            const gw = if (line != null) objc.CTLineGetTypographicBounds(line, null, null, null) else 0;
            const base = rowBase(panel_small);
            _ = drawLine(ctx, line, dim, at + (key_cell - gw) / 2, y + base);
        }
        const room = right - keys_w - (if (cells > 0) @as(f64, 12) else 0) - x;
        const name = cmd_names.items[p];
        if (std.mem.indexOf(u8, name, ": ")) |j| {
            const pw = rowText(ctx, name[0 .. j + 1], panel_font, dim, x, y, room);
            _ = rowText(ctx, name[j + 2 ..], panel_font, ink, x + pw + 4, y, room - pw - 4);
        } else _ = rowText(ctx, name, panel_font, ink, x, y, room);
        return;
    }
    const paths = d.list.?.paths.items;
    if (p >= paths.len) return;
    const path = paths[p];
    const slash = if (std.mem.lastIndexOfScalar(u8, path, '/')) |j| j + 1 else 0;
    const nw = rowText(ctx, path[slash..], panel_font, ink, left, y, right - left);
    _ = rowText(ctx, path[0..slash], panel_small, dim, left + nw + 8, y, right - left - nw - 8);
}

/// How much of `rel`'s unsaved dot shows (0 to 1), from whichever card holds it.
fn rowDot(w: *const Win, rel: []const u8, now: f64) f64 {
    for (docs.items) |d| if (d.win == w) {
        if (d.path) |p| if (relOf(p)) |r| if (std.mem.eql(u8, r, rel)) return std.math.clamp(d.dot.at(now), 0, 1);
        for (d.pages.items) |pg| if (pg.path) |p| if (relOf(p)) |r| if (std.mem.eql(u8, r, rel)) return std.math.clamp(pg.dot.at(now), 0, 1);
    };
    return 0;
}

/// Aims each file's dot at its unsaved state. True while any is fading.
fn sideDotsBusy(w: *const Win, now: f64) bool {
    var busy = false;
    for (docs.items) |d| if (d.win == w) {
        d.dot.aim(if (d.path != null and d.ed.buf.dirty()) 1 else 0, now);
        busy = busy or d.dot.moving(now);
        for (d.pages.items) |*pg| {
            pg.dot.aim(if (pg.path != null and pg.ed.buf.dirty()) 1 else 0, now);
            busy = busy or pg.dot.moving(now);
        }
    };
    return busy;
}

/// `p` with the home folder written as ~.
fn tilde(buf: []u8, p: []const u8) []const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return p);
    if (home.len < 2 or !std.mem.startsWith(u8, p, home)) return p;
    if (p.len > home.len and p[home.len] != '/') return p;
    return std.fmt.bufPrint(buf, "~{s}", .{p[home.len..]}) catch p;
}

/// The sidebar's rows start under its pinned top: the folder's name, which
/// stays put while the rows scroll.
fn listTop() f64 {
    return top_h + side_h;
}

/// At most this many open folders pin under the folder's name.
const max_stuck = 3;

/// The open folders that hold the first row in view, outermost first, into
/// `out`. An open folder pins the moment its row reaches its slot, so it never
/// slides under the ones above. They pin over the rows they cover, so the row
/// they hold is the one under them: a few passes settle it.
fn stuckRows(sy: f64, out: *[max_stuck]usize) usize {
    const rows = tree.rows.items;
    var n: usize = 0;
    for (0..max_stuck + 1) |_| {
        const t = @as(usize, @intFromFloat(@max(@floor(sy / side_h), 0))) + n;
        if (t >= rows.len) break;
        var m: usize = 0;
        // Only once it has moved past its slot: sitting exactly on it, the row draws itself.
        const past = rows[t].depth >= n and sy > @as(f64, @floatFromInt(t - n)) * side_h;
        if (past and t + 1 < rows.len and rows[t + 1].depth > rows[t].depth and rows[t].depth < max_stuck) {
            out[rows[t].depth] = t;
            m += 1;
        }
        // Walking back from a row, the first one a level up is its folder.
        var need = @as(isize, rows[t].depth) - 1;
        var i = t;
        while (need >= 0 and i > 0) {
            i -= 1;
            if (rows[i].depth != need) continue;
            if (need < max_stuck) {
                out[@intCast(need)] = i;
                m += 1;
            }
            need -= 1;
        }
        if (m == n) break;
        n = m;
    }
    return n;
}

/// The tree row under `y`: a pinned folder, or a row in the list.
fn sideRow(w: *const Win, y: f64) ?usize {
    for (w.stuck[0..w.nstuck], w.stuck_y[0..w.nstuck]) |i, sy| if (y >= sy and y < sy + side_h) return i;
    if (y < listTop()) return null;
    // Rows after a folding folder have slid up by how far it's shut, so a
    // click lands on the row it shows, in the tree's own numbering.
    var ly = y - listTop() + w.side_y;
    var vs: [2]FoldView = undefined;
    const vn = foldViews(tree.rows.items, CACurrentMediaTime(), &vs);
    if (vn == 2 and vs[0].rest > vs[1].rest) std.mem.swap(FoldView, &vs[0], &vs[1]);
    var cum: f64 = 0;
    for (vs[0..vn]) |v| {
        if (ly < f(v.rest) * side_h - cum - v.off) break;
        cum += v.off;
    }
    ly += cum;
    const at = @floor(ly / side_h);
    if (at < 0 or at >= f(tree.rows.items.len)) return null;
    return @intFromFloat(at);
}

/// Folders open and close over this long: the rows below slide while the
/// folder's own rows fade in or out under it, and its chevron turns.
const fold_time = 0.2;

/// The folder opening or closing in every window's sidebar. An opening
/// folder's rows are in the tree from the start; a closing one keeps its
/// rows on show until it's shut.
const Fold = struct {
    at: usize = 0,
    /// The rows it holds.
    n: usize = 0,
    /// How far open, 0 to 1.
    t: Tween = .{ .dur = fold_time },
    closing: bool = false,
    rel: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,
};

/// The folders folding now. Slot 0 is the latest click's; a folder still
/// closing when another click comes moves to slot 1 and finishes there,
/// so clicks are never held up by a closing folder.
var folds: [2]Fold = .{ .{}, .{} };

/// A folding folder as drawn: its row, where its rows end, how far open it
/// is and how far the rows after it have slid up.
const FoldView = struct { at: usize, rest: usize, n: usize, p: f64, off: f64 };

/// The folders that are folding on screen, by `rows`, into `out`.
fn foldViews(rows: []const tree_mod.Row, now: f64, out: *[2]FoldView) usize {
    var nv: usize = 0;
    for (&folds) |*o| {
        if (!o.t.moving(now) or o.at >= rows.len or !std.mem.eql(u8, rows[o.at].rel, o.rel[0..o.len])) continue;
        const p = std.math.clamp(o.t.at(now), 0, 1);
        out[nv] = .{ .at = o.at, .rest = o.at + o.n + 1, .n = o.n, .p = p, .off = (1 - p) * f(o.n) * side_h };
        nv += 1;
    }
    return nv;
}

/// How far row `i` has slid up, by the folders folding above it.
fn shiftOf(vs: []const FoldView, i: usize) f64 {
    var s: f64 = 0;
    for (vs) |v| if (i >= v.rest) {
        s += v.off;
    };
    return s;
}

/// The folder folding that holds row `i` among its rows.
fn insideOf(vs: []const FoldView, i: usize) ?FoldView {
    for (vs) |v| if (i > v.at and i < v.rest) return v;
    return null;
}

/// True while any folder opens or closes.
fn foldsBusy(now: f64) bool {
    for (folds) |o| if (o.t.moving(now) or o.closing) return true;
    return false;
}

/// Finds folder `o`'s row again after the tree changed. A folder that's
/// gone from the list stops folding.
fn refindFold(o: *Fold, now: f64) void {
    if (!o.closing and !o.t.moving(now)) return;
    const rows = tree.rows.items;
    for (rows, 0..) |row, i| if (std.mem.eql(u8, row.rel, o.rel[0..o.len])) {
        o.at = i;
        var e = i + 1;
        while (e < rows.len and rows[e].depth > row.depth) e += 1;
        o.n = e - i - 1;
        return;
    };
    o.closing = false;
    o.t.snap(1);
}

/// Opens or closes the folder at row `i`. A folder that's still folding
/// turns around from where it got to; one still closing keeps going on
/// its own record.
fn startFold(i: usize) void {
    const now = CACurrentMediaTime();
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = rel_buf[0..tree.rows.items[i].rel.len];
    @memcpy(rel, tree.rows.items[i].rel);
    for (&folds) |*o| if (o.t.moving(now) and std.mem.eql(u8, rel, o.rel[0..o.len])) {
        o.closing = !o.closing;
        return o.t.aim(if (o.closing) 0 else 1, now);
    };
    // A closing folder the new one reaches into, or a third folder
    // closing at once, is shut right away.
    var at = i;
    while (true) {
        const rows = tree.rows.items;
        var e = at + 1;
        while (e < rows.len and rows[e].depth > rows[at].depth) e += 1;
        const crowded = folds[0].closing and folds[0].t.moving(now) and folds[1].closing and folds[1].t.moving(now);
        var hit: ?*Fold = null;
        for (&folds, 0..) |*o, s| if (o.closing and o.t.moving(now) and ((o.at < e and at < o.at + o.n + 1) or (crowded and s == 1))) {
            hit = o;
        };
        finishFold(hit orelse break);
        at = for (tree.rows.items, 0..) |row, j| {
            if (std.mem.eql(u8, row.rel, rel)) break j;
        } else return;
    }
    const shut = tree.isOpen(rel);
    if (folds[0].closing and folds[0].t.moving(now)) folds[1] = folds[0];
    const fo = &folds[0];
    @memcpy(fo.rel[0..rel.len], rel);
    fo.len = rel.len;
    fo.at = at;
    fo.closing = shut;
    if (!shut) {
        tree.toggle(gpa, rel);
        rebuildTree();
        refindFold(&folds[1], now);
    }
    fo.t.snap(if (shut) 1 else 0);
    fo.t.aim(if (shut) 0 else 1, now);
    const rows = tree.rows.items;
    var e = at + 1;
    while (e < rows.len and rows[e].depth > rows[at].depth) e += 1;
    fo.n = e - at - 1;
}

/// Shuts folder `o` for good: the tree drops its rows, and the other
/// folder still folding finds its row again.
fn finishFold(o: *Fold) void {
    o.closing = false;
    tree.toggle(gpa, o.rel[0..o.len]);
    rebuildTree();
    const now = CACurrentMediaTime();
    for (&folds) |*x| if (x != o) refindFold(x, now);
    refreshAll();
}

/// Shuts the closing folders whose rows have folded away.
fn finishFolds(now: f64) void {
    for (&folds) |*o| if (o.closing and !o.t.moving(now)) finishFold(o);
}

/// The sidebar's selection: a soft rounded fill with no outline, fainter
/// when the window isn't key.
fn selPill(ctx: Id, th: *const Theme, dark: bool, key: bool, y: f64) void {
    selFill(ctx, th, dark, key, 1, side_inset, y, side_w - 2 * side_inset - 2, side_h, side_radius);
}

/// The fill the sidebar's selection and the palette's picked row share: a
/// soft rounded fill, fainter when the window isn't key, with a ring under
/// Increase Contrast. `fade` (0 to 1) scales both.
fn selFill(ctx: Id, th: *const Theme, dark: bool, key: bool, fade: f64, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const a: f64 = if (contrast) 0.16 else if (dark) (if (key) 0.12 else 0.07) else (if (key) 0.09 else 0.05);
    pill(ctx, th.fg, a * fade, x, y, w, h, radius);
    if (contrast) ring(ctx, th.fg, 0.4 * fade, x, y, w, h, radius);
}

/// One row of the tree with its top at `y`: chevron, icon, name and dot.
/// `turn` is how far a folding folder's chevron has turned, 0 to 1. The file
/// on show in the focused card has its name in bold, which fades in as the
/// selection's highlight arrives and out as it leaves.
fn drawRow(w: *Win, ctx: Id, th: *const Theme, dark: bool, i: usize, y: f64, turn: ?f64) void {
    const row = tree.rows.items[i];
    const s = side_icon;
    const now = CACurrentMediaTime();
    const x = 16 + f(row.depth) * 16;
    if (w.menu_row == i and w.menu_gen == tree_gen) {
        const ma = w.menu_a.at(now);
        if (ma > 0.01) menuMark(ctx, th, ma, side_inset, y, side_w - 2 * side_inset - 2, side_h, side_radius);
    }
    const iy = y + (side_h - s) / 2;
    if (row.dir) {
        const cx = x - 4;
        const cy = iy + (s - 12) / 2;
        if (turn) |t| {
            objc.CGContextSaveGState(ctx);
            objc.CGContextTranslateCTM(ctx, cx + 6, cy + 6);
            objc.CGContextRotateCTM(ctx, t * std.math.pi / 2);
            objc.CGContextTranslateCTM(ctx, -cx - 6, -cy - 6);
            drawIcon(icon(.closed, dark, th), cx, cy, 12);
            objc.CGContextRestoreGState(ctx);
        } else drawIcon(icon(if (tree.isOpen(row.rel)) .opened else .closed, dark, th), cx, cy, 12);
    }
    // A row whose file is being dragged out dims, and comes back as its copy goes.
    const lift = rowLift(w, i, now);
    if (lift > 0.01) {
        objc.CGContextSaveGState(ctx);
        objc.CGContextSetAlpha(ctx, 1 - 0.6 * lift);
    }
    if (row.dir) drawIcon(icon(.folder, dark, th), x + 10, iy, s) else tileAt(iconFor(row.rel[row.base..]), x + 10, iy, s);
    const nx = x + 10 + s + 8;
    const room = side_w - nx - if (row.dir) @as(f64, 14) else 26;
    const plain = &side_lines.items[i];
    if (plain.* == null) plain.* = uiLine(row.rel[row.base..], side_font, room);
    // How far the selection's highlight is on this row, for the bold name.
    const bp: f64 = if (row.dir or w.sel_row == null) 0 else (1 - std.math.clamp(@abs(w.sel.x - f(i) * side_h) / side_h, 0, 1)) * std.math.clamp(w.sel_a.at(now), 0, 1);
    var nw = drawLineA(ctx, plain.*, th.fg, 1 - bp, nx, y + side_base);
    if (bp > 0.001) {
        const selected = w.sel_row == i;
        if (selected and (w.bold == null or w.bold_row != i or w.bold_gen != tree_gen)) {
            // The row it leaves keeps its bold name for the length of the hop.
            if (w.bold_old) |l| objc.CFRelease(l);
            w.bold_old = w.bold;
            w.bold_old_row = w.bold_row;
            w.bold_old_gen = w.bold_gen;
            w.bold = uiLine(row.rel[row.base..], name_font, room);
            w.bold_row = i;
            w.bold_gen = tree_gen;
        }
        const kept = if (w.bold != null and w.bold_row == i and w.bold_gen == tree_gen) w.bold else if (w.bold_old != null and w.bold_old_row == i and w.bold_old_gen == tree_gen) w.bold_old else null;
        const line = kept orelse uiLine(row.rel[row.base..], name_font, room);
        defer if (kept == null) if (line) |l| objc.CFRelease(l);
        const bw = drawLineA(ctx, line, th.fg, bp, nx, y + side_base);
        nw += (bw - nw) * bp;
    }
    if (lift > 0.01) objc.CGContextRestoreGState(ctx);
    const da = if (row.dir) 0 else rowDot(w, row.rel, now);
    if (da > 0.001) {
        if (side_dot == null) side_dot = uiLine(" •", font, side_w);
        _ = drawLineA(ctx, side_dot, th.caret, da, nx + nw, y + side_base);
    }
}

/// The folder's name pinned at the top, then a row per file and open
/// folder down to the window's bottom. The open folders holding the rows
/// at the top pin under the name, and the next folder pushes them up.
/// `fade` is the sidebar's alpha while it slides.
fn drawSide(w: *Win, ctx: Id, th: *const Theme, dark: bool, key: bool, bg: Rgb, fade: f64, now: f64) void {
    const rows = tree.rows.items;
    const lt = listTop();
    const full_h = msg(Rect, w.view, "bounds", .{}).h;
    const view_h = full_h - lt;
    const cur = if (w.focus.path) |p| relOf(p) else null;
    // The list glides to a focused file that's out of view, once it's
    // been drawn; on the first draw it's just there.
    const was = if (w.side_t.moving(now)) w.side_t.at(now) else w.side_y;
    var glide = false;
    if (w.side_find) {
        w.side_find = false;
        if (cur) |c| for (rows, 0..) |row, i| if (std.mem.eql(u8, row.rel, c)) {
            const y = f(i) * side_h;
            if (y < w.side_y or y + side_h > w.side_y + view_h) {
                w.side_y = y - view_h / 3;
                glide = w.side_drawn;
            }
            break;
        };
    }
    w.side_drawn = true;
    w.side_y = std.math.clamp(w.side_y, 0, @max(0, f(rows.len + 1) * side_h - view_h));
    if (glide and was != w.side_y) {
        w.side_t.snap(was);
        w.side_t.aim(w.side_y, now);
    } else if (w.side_t.to != w.side_y) w.side_t.snap(w.side_y);
    const sy = if (w.side_t.moving(now)) w.side_t.at(now) else w.side_y;
    if (side_lines.items.len < rows.len) side_lines.appendNTimes(gpa, null, rows.len - side_lines.items.len) catch return;

    objc.CGContextSaveGState(ctx);
    objc.CGContextClipToRect(ctx, .{ .y = top_h - 6, .w = side_w - 2, .h = full_h - top_h + 6 });
    if (side_head == null) side_head = uiLine(std.fs.path.basename(root.?), name_font, side_w - 32 - 14);
    const hw = drawLine(ctx, side_head, th.fg, 16, top_h + side_base);
    drawIcon(icon(.parents, dark, th), 16 + hw + 5, top_h + (side_h - 12) / 2, 12);

    objc.CGContextClipToRect(ctx, .{ .y = lt, .w = side_w - 2, .h = view_h });
    var vs: [2]FoldView = undefined;
    const vn = foldViews(rows, now, &vs);
    var moved: f64 = 0;
    for (vs[0..vn]) |v| moved += v.off;

    // A faint highlight follows the mouse down the list, sliding from row
    // to row on a spring that settles without a bounce. It fades in where
    // the mouse comes in and fades out where it leaves.
    const hov_a = w.hov_a.at(now);
    if (w.hov_row != null and w.hov_gen == tree_gen and w.hov_row.? < rows.len) {
        const i = w.hov_row.?;
        const ty = f(i) * side_h - shiftOf(vs[0..vn], i);
        if (hov_a < 0.05) {
            w.hov.snap(ty);
        } else if (w.hov_last != i) {
            w.hov.aim(ty, now);
        } else {
            w.hov.x += ty - w.hov.to;
            w.hov.to = ty;
        }
        w.hov_last = i;
        w.hov_a.aim(1, now);
    } else w.hov_a.aim(0, now);
    if (hov_a > 0.01) pill(ctx, th.fg, (if (dark) @as(f64, 0.035) else 0.025) * (if (key) @as(f64, 1) else 0.7) * hov_a * fade, side_inset, lt + w.hov.step(now) - sy, side_w - 2 * side_inset - 2, side_h, side_radius);

    // The selection hops from row to row with a little bounce, and rides
    // along when folders above it open or close.
    if (w.sel_gen != tree_gen or w.sel_id != w.focus.id) {
        w.sel_gen = tree_gen;
        w.sel_id = w.focus.id;
        w.sel_row = null;
        if (cur) |c| for (rows, 0..) |row, i| if (std.mem.eql(u8, row.rel, c)) {
            w.sel_row = i;
            break;
        };
    }
    if (w.sel_row) |i| {
        const ty = f(i) * side_h - shiftOf(vs[0..vn], i);
        if (w.sel_a.to == 0 or w.sel_was == null) {
            w.sel.snap(ty);
        } else if (w.sel_was.? != i) {
            w.sel.aim(ty, now);
        } else {
            w.sel.x += ty - w.sel.to;
            w.sel.to = ty;
        }
        w.sel_a.aim(1, now);
    } else w.sel_a.aim(0, now);
    w.sel_was = w.sel_row;
    const sel_a = w.sel_a.at(now) * if (w.sel_row) |sr| (if (insideOf(vs[0..vn], sr)) |v| v.p else 1.0) else 1.0;
    if (sel_a > 0.01) {
        objc.CGContextSaveGState(ctx);
        objc.CGContextSetAlpha(ctx, sel_a * fade);
        selPill(ctx, th, dark, key, lt + w.sel.step(now) - sy);
        objc.CGContextRestoreGState(ctx);
    }

    // A folding folder's own rows stay put and show only as far as it's
    // open, fading in or out, and the rows after them slide to match.
    const from: usize = @intFromFloat(@max(@floor(sy / side_h), 0));
    const to: usize = @min(rows.len, @as(usize, @intFromFloat(@max(@ceil((sy + moved + view_h) / side_h), 0))));
    for (@min(from, to)..to) |i| {
        const sh = shiftOf(vs[0..vn], i);
        const y = lt + f(i) * side_h - sy - sh;
        if (y > lt + view_h or y + side_h < lt) continue;
        if (insideOf(vs[0..vn], i)) |v| {
            objc.CGContextSaveGState(ctx);
            objc.CGContextClipToRect(ctx, .{ .y = lt + f(v.at + 1) * side_h - sy - sh, .w = side_w, .h = f(v.n) * side_h - v.off });
            objc.CGContextSetAlpha(ctx, fade * v.p);
            drawRow(w, ctx, th, dark, i, y, null);
            objc.CGContextRestoreGState(ctx);
            continue;
        }
        var turn: ?f64 = null;
        for (vs[0..vn]) |v| if (v.at == i) {
            turn = v.p;
        };
        drawRow(w, ctx, th, dark, i, y, turn);
    }

    // Pinned folders, each held up by the end of its rows, the outer ones
    // drawn last so they stay on top.
    w.nstuck = stuckRows(sy, &w.stuck);
    var low = lt;
    var j = w.nstuck;
    while (j > 0) {
        j -= 1;
        const a = w.stuck[j];
        var e = a + 1;
        while (e < rows.len and rows[e].depth > rows[a].depth) e += 1;
        const y = @min(lt + f(j) * side_h, lt + f(e) * side_h - sy - side_h);
        w.stuck_y[j] = y;
        objc.CGContextClearRect(ctx, .{ .y = y, .w = side_w, .h = side_h });
        fillA(ctx, bg, chromeAlpha(dark, w.z.x), 0, y, side_w, side_h);
        var turn: ?f64 = null;
        for (vs[0..vn]) |v| if (v.at == a) {
            turn = v.p;
        };
        drawRow(w, ctx, th, dark, a, y, turn);
        low = @max(low, y + side_h);
    }
    // A hairline under whatever is pinned, once rows pass under it.
    const shade = std.math.clamp(sy / side_h, 0, 1);
    if (shade > 0) fillA(ctx, th.fg, 0.08 * shade, 12, low - 1, side_w - 24, 1);
    objc.CGContextRestoreGState(ctx);
}

/// The sidebar's text as CoreText lines in the system font, made on first
/// draw: the folder's name, then one per tree row. Dropped when the tree or
/// the font changes; drawing one costs no layout.
var side_head: Id = null;
var side_lines: std.ArrayList(Id) = .empty;
/// The unsaved dot after a file's name, one line shared by every row.
var side_dot: Id = null;

fn dropSideLines() void {
    if (side_dot) |l| objc.CFRelease(l);
    side_dot = null;
    for (wins.items) |w| {
        if (w.bold) |l| objc.CFRelease(l);
        if (w.bold_old) |l| objc.CFRelease(l);
        w.bold = null;
        w.bold_old = null;
    }
    if (side_head) |l| {
        objc.CFRelease(l);
        side_head = null;
    }
    for (side_lines.items) |l| if (l) |p| objc.CFRelease(p);
    side_lines.clearRetainingCapacity();
}

/// Drops the header's folder and the tabs' names, made again on next draw.
/// Folding tabs keep theirs, having no file left to make it from.
fn dropHead(d: *Doc) void {
    if (d.head) |l| objc.CFRelease(l);
    d.head = null;
    d.head_w = -1;
    for (d.slots.items) |*s| if (!s.gone) s.drop();
}

/// `s` as a line in `fnt` that takes the context's fill color, cut with an
/// ellipsis past `width`. Owned: CFRelease it.
fn uiLine(s: []const u8, fnt: Id, width: f64) Id {
    return uiLineCut(s, fnt, width, 1);
}

/// `uiLine`, with the ellipsis at the start (0), end (1) or middle (2).
fn uiLineCut(s: []const u8, fnt: Id, width: f64, at: u32) Id {
    const attrs = uiAttrs(fnt);
    const text = attributed(s, attrs);
    defer msg(void, text, "release", .{});
    const line = objc.CTLineCreateWithAttributedString(text);
    if (line == null or objc.CTLineGetTypographicBounds(line, null, null, null) <= width) return line;
    const token = ellipsis(fnt);
    defer if (token) |t| objc.CFRelease(t);
    const short = objc.CTLineCreateTruncatedLine(line, width, at, token);
    if (short == null) return line;
    objc.CFRelease(line.?);
    return short;
}

fn uiAttrs(fnt: Id) Id {
    const objs = [2]Id{ fnt, msg(Id, objc.class("NSNumber"), "numberWithBool:", .{true}) };
    const keys = [2]Id{ objc.str("NSFont"), objc.str("CTForegroundColorFromContext") };
    return msg(Id, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &objs, &keys, @as(usize, 2) });
}

/// The ellipsis `uiLine` ends a cut line with, in `fnt`. Owned: CFRelease it.
fn ellipsis(fnt: Id) Id {
    const dots = attributed("…", uiAttrs(fnt));
    defer msg(void, dots, "release", .{});
    return objc.CTLineCreateWithAttributedString(dots);
}

/// The tab names' ellipses, bold then thin, made on first use and kept until
/// the fonts change.
var tab_dots: [2]Id = .{ null, null };

/// `line` (a tab's whole name, made by `uiLine`) cut to `width` the way
/// `uiLine` cuts it, from the ellipsis kept in `tab_dots[k]` (0 for the bold
/// name, 1 for the thin). Owned: CFRelease it; `line` retained when it fits.
fn cutTab(line: Id, k: usize, width: f64) Id {
    const l = line orelse return null;
    if (tab_dots[k] == null) tab_dots[k] = ellipsis(if (k == 0) tab_bold else tab_font);
    if (objc.CTLineGetTypographicBounds(l, null, null, null) > width) {
        if (objc.CTLineCreateTruncatedLine(l, width, 1, tab_dots[k])) |short| return short;
    }
    return objc.CFRetain(l);
}

fn attributed(s: []const u8, attrs: Id) Id {
    return msg(Id, msg(Id, objc.class("NSAttributedString"), "alloc", .{}), "initWithString:attributes:", .{ objc.str(s), attrs });
}

/// Draws a `uiLine` with its baseline at `y`, in `c`. Returns its width.
fn drawLine(ctx: Id, line: Id, c: Rgb, x: f64, y: f64) f64 {
    return drawLineA(ctx, line, c, 1, x, y);
}

/// `drawLine` at `a` of full strength.
fn drawLineA(ctx: Id, line: Id, c: Rgb, a: f64, x: f64, y: f64) f64 {
    if (line == null) return 0;
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    objc.CGContextSetTextPosition(ctx, x, y);
    objc.CTLineDraw(line, ctx);
    // The grid's glyph runs read the text matrix's offset too, so put it back.
    objc.flipText(ctx);
    return objc.CTLineGetTypographicBounds(line, null, null, null);
}

/// A folder opens or closes; a file shows in the focused card, or with ⌘
/// in a new window.
fn sideClick(w: *Win, p: Point, flags: usize) void {
    finishFolds(CACurrentMediaTime());
    const i = sideRow(w, p.y) orelse return;
    // A pinned folder scrolls back to where its rows start.
    if (std.mem.indexOfScalar(usize, w.stuck[0..w.nstuck], i) != null and p.y < listTop() + f(w.nstuck) * side_h) {
        w.side_t.snap(w.side_y);
        w.side_y = f(i) * side_h;
        w.side_t.aim(w.side_y, CACurrentMediaTime());
        return redrawSide(w);
    }
    const row = tree.rows.items[i];
    if (row.dir) {
        startFold(i);
        return refreshAll();
    }
    // A file opens when the mouse comes up, unless it's dragged to a card.
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ root.?, row.rel }, 0) catch return;
    const ix = 16 + f(row.depth) * 16 + 10;
    w.tdrag = .{ .from = null, .file = path, .cmd = flags & cmd_key != 0, .down = p, .at = p, .grab = p.x - ix + tab_pad, .name = uiLine(row.rel[row.base..], name_font, 1e5), .row = i };
}

fn isDark(view: Id) bool {
    const name = objc.utf8(msg(Id, msg(Id, view, "effectiveAppearance", .{}), "name", .{}));
    return std.mem.indexOf(u8, name, "Dark") != null;
}

const VRow = struct { line: usize, seg: Seg };

/// Draws a window: its chrome, each card in its pane, then the sidebar and
/// the buttons by the traffic lights.
fn draw(w: *Win, ctx: Id, dirty: Rect) void {
    const now = CACurrentMediaTime();
    const dark = isDark(w.view);
    const th = &themes[@intFromBool(dark)];
    const r = msg(Rect, w.view, "bounds", .{});
    dev_px = 1 / @max(1, msg(f64, w.window, "backingScaleFactor", .{}));
    fitTitlebar(w);
    // A stretched sidebar edge springs back to its limit.
    if (side_stretch.x != 0 or side_stretch.v != 0) {
        _ = side_stretch.step(now);
        if (side_stretch.to == 0 and side_stretch.settled()) side_stretch.snap(0);
        const stretched = @round(side_rest + side_stretch.x);
        if (stretched != side_w) {
            side_w = stretched;
            dropSideLines();
        }
    }
    // A closing folder shuts once its rows have folded away.
    finishFolds(now);
    // The sidebar slides in and out, on the first draw it's just there.
    const shown = sideShown(w);
    const want: f64 = if (shown) 1 else 0;
    const zen_to: f64 = if (conf.zen) 1 else 0;
    if (w.side_seen) {
        w.side_a.aim(want, now);
        w.z.aim(zen_to, now);
    } else {
        w.side_a.snap(want);
        w.z.snap(zen_to);
        w.focus.inked.snap(if (msg(bool, w.window, "isKeyWindow", .{})) 1 else 0);
    }
    w.side_seen = true;
    // Zen eases in: the lights follow it, the margin and header in drawPane.
    _ = w.z.step(now);
    const la = 1 - std.math.clamp(w.z.x, 0, 1);
    if (la != w.lights_a) {
        setLights(w, la);
        w.lights_a = la;
    }
    const slid = std.math.clamp(w.side_a.at(now), 0, 1);
    // Once a sidebar that was dragged shut has slid away, its width goes
    // back to the saved one for when it opens again.
    if (!conf.sidebar and slid <= 0 and side_w != conf.sidebar_width) {
        side_w = conf.sidebar_width;
        dropSideLines();
    }
    w.lx = @max(gap, side_w * slid);
    // The cards fill the room right of the sidebar, their panes reaching a
    // gap back over it so each card sits a gap in.
    dropFolded(w, w.cards);
    const end_lx: f64 = if (shown) side_w else gap;
    place(w.cards, .{ .x = w.lx - gap, .w = r.w - w.lx + gap, .h = r.h }, .{ .x = end_lx - gap, .w = r.w - end_lx + gap, .h = r.h }, now);
    objc.CGContextClipToRect(ctx, dirty);
    objc.CGContextClearRect(ctx, .{ .w = r.w, .h = r.h });
    // Text upright for every draw: a strip-only one skips the cards, whose drawPane also sets it.
    objc.flipText(ctx);
    fillA(ctx, chrome(th, dark, w.z.x), chromeAlpha(dark, w.z.x), 0, 0, r.w, r.h);
    const key = msg(bool, w.window, "isKeyWindow", .{});
    const many = w.cards.pane == null;
    for (&w.hot_t, 1..) |*t, i| t.aim(if (w.hot == i) 1 else 0, now);
    w.key_a.aim(if (key) 1 else 0, now);
    // The sidebar's own motion (its picked and hovered rows, the + button,
    // its scroll and folding folders) redraws only its strip; anything else
    // redraws the window.
    var busy = w.side_a.moving(now) or cardsMoving(w.cards) or
        (w.hot_t[0].moving(now) and !toggleInSide(shown, slid)) or
        w.pv_a.moving(now) or w.ghost_a.moving(now) or w.menu_a.moving(now) or w.fly != null or
        !w.lift.settled() or w.key_a.moving(now) or !side_stretch.settled() or !w.z.settled();
    const dots_busy = sideDotsBusy(w, now) and shown;
    const side_busy = w.side_t.moving(now) or foldsBusy(now) or !w.sel.settled() or w.sel_a.moving(now) or w.hot_t[1].moving(now) or !w.hov.settled() or w.hov_a.moving(now)
        or dots_busy or (w.hot_t[0].moving(now) and toggleInSide(shown, slid));
    for (w.pv) |s| busy = busy or !s.settled();
    busy = busy or w.press_t.moving(now);
    const down = w.press_t.at(now);
    var gliding = false;
    for (docs.items) |d| if (d.win == w) {
        // A card springing in or folding away fades with its size.
        const grown = std.math.clamp(@min((d.size.x - 2 * gap) / 160, (d.size.y - 2 * gap) / 100), 0, 1);
        if (grown <= 0.01) continue;
        // A strip redraw that doesn't reach this card leaves it be, and one
        // that reaches only its shadow draws just that.
        const body: Rect = .{ .x = d.org.x + gap, .y = d.org.y, .w = d.size.x - gap, .h = d.size.y };
        const shade: Rect = .{ .x = body.x - shadow_m, .y = body.y, .w = body.w - gap + 2 * shadow_m, .h = body.h };
        if (!hits(dirty, shade)) {
            busy = busy or d.busy;
            gliding = gliding or d.cx.moving(now) or d.cy.moving(now);
            continue;
        }
        objc.CGContextSaveGState(ctx);
        objc.CGContextTranslateCTM(ctx, d.org.x, d.org.y);
        const shaking = (now - d.card_shake_t0) / shake_time;
        if (shaking >= 0 and shaking < 1) objc.CGContextTranslateCTM(ctx, 6 * @sin(2 * std.math.pi * 3 * shaking) * (1 - shaking), 0);
        if (grown < 1) {
            objc.CGContextSetAlpha(ctx, grown);
            objc.CGContextBeginTransparencyLayer(ctx, null);
        }
        if (hits(dirty, body)) drawPane(d, ctx, th, dark, key, many, now) else if (w.z.x < 1) {
            cardShadow(ctx, dark, (1 - std.math.clamp(w.z.x, 0, 1)) * (0.5 + 0.5 * w.key_a.at(now)), gap, gap, d.size.x - 2 * gap, d.size.y - 2 * gap);
        }
        if (grown < 1) objc.CGContextEndTransparencyLayer(ctx);
        objc.CGContextRestoreGState(ctx);
        busy = busy or d.busy or (shaking >= 0 and shaking < 1);
        gliding = gliding or d.cx.moving(now) or d.cy.moving(now);
    };
    // The sidebar, and the buttons by the traffic lights, each with a soft
    // highlight under the mouse.
    const hy = gap + head_h / 2;
    if (slid > 0.002 and root != null) {
        objc.CGContextSaveGState(ctx);
        objc.CGContextClipToRect(ctx, .{ .w = side_w * slid, .h = r.h });
        objc.CGContextTranslateCTM(ctx, side_w * (slid - 1), 0);
        if (slid < 1) objc.CGContextSetAlpha(ctx, slid * slid);
        drawSide(w, ctx, th, dark, key, chrome(th, dark, w.z.x), if (slid < 1) slid * slid else 1, now);
        hoverPill(ctx, th, w.hot_t[1].at(now), if (w.press == 2) down else 0, side_w - gap - 20, hy);
        drawIcon(icon(.plus, dark, th), side_w - gap - 30, hy - 10, 20);
        objc.CGContextRestoreGState(ctx);
    }
    // In zen it fades out with the lights, on the same spring.
    if (root != null and la > 0.01) {
        if (la < 1) objc.CGContextSetAlpha(ctx, la);
        hoverPill(ctx, th, w.hot_t[0].at(now), if (w.press == 1) down else 0, toggle_x, hy);
        drawIcon(icon(.sidebar, dark, th), toggle_x - 10, hy - 10, 20);
        if (la < 1) objc.CGContextSetAlpha(ctx, 1);
    }
    drawDrag(w, ctx, th, now);
    // Only the sidebar's strip moves when its rows' highlights are all that does.
    w.part = !busy and side_busy and shown and slid >= 1;
    w.busy = busy or side_busy;
    if (w.busy or gliding) msg(void, w.link, "setPaused:", .{false});
}

/// Draws a card in its pane's coordinates: the text, the prompt line and
/// the header. `win_key` says whether its window is key, and `many`
/// whether the window has other cards, which lights the focused one's ring.
fn drawPane(d: *Doc, ctx: Id, th: *const Theme, dark: bool, win_key: bool, many: bool, now: f64) void {
    if (d.dark != dark) {
        d.dark = dark;
        msg(void, d.caret, "setBackgroundColor:", .{msg(Id, nscolor(th.caret), "CGColor", .{})});
        preview.update(d, &themes);
    }
    const r = bounds(d);
    const focused = d.win.focus == d;
    // The caret only shows in the key window's focused card.
    const key = win_key and focused and !d.closing;
    d.lit.aim(if (focused and many and win_key) 1 else 0, now);
    if (d.lit.dur != tab_time and !d.lit.moving(now)) {
        d.lit.snap(d.lit.to);
        d.lit.dur = tab_time;
    }
    d.inked.aim(if (key) 1 else 0, now);
    const ka = d.inked.at(now);
    const b = &d.ed.buf;
    layout(d);
    if (conf.typewriter and d.center_h != textH(d)) reveal(d);
    d.center_h = textH(d);
    d.band.dur = if (conf.typewriter) scroll_time else caret_time;
    clampScroll(d);
    // Jumps glide the scroll. Stepping past the edge a few rows at a time and
    // live resizing snap it (the trackpad snaps in scrollWheel), and the caret
    // and band move with the page so they don't bounce back to the edge.
    const resizing = msg(bool, d.view, "inLiveResize", .{});
    if (d.sy != d.ys.to) {
        if (resizing or (!conf.typewriter and !d.ys.moving(now) and @abs(d.sy - d.ys.to) <= glide_rows * lh)) {
            const by = d.sy - d.ys.at(now);
            d.ys.snap(d.sy);
            d.band.shift(by);
            if (d.c_text) d.cy.shift(by);
        } else d.ys.aim(d.sy, now);
    }
    if (d.sx != d.xs.to) {
        if (resizing or (!d.xs.moving(now) and @abs(d.sx - d.xs.to) <= 16 * cw)) {
            const by = d.sx - d.xs.at(now);
            d.xs.snap(d.sx);
            if (d.c_text) d.cx.shift(by);
        } else d.xs.aim(d.sx, now);
    }
    springBack(d, now);
    d.vy = d.ys.at(now) + d.ov[1];
    d.vx = d.xs.at(now) + d.ov[0];
    // The card that holds the text, header and prompt line, which draw
    // inside its rounded corners.
    const lx = gap;
    const card: Rect = .{ .x = lx, .y = gap, .w = rightEdge(d) - lx, .h = r.h - 2 * gap };
    const zen_k = 1 - std.math.clamp(d.win.z.x, 0, 1);
    if (zen_k > 0) cardShadow(ctx, dark, zen_k * (0.5 + 0.5 * d.win.key_a.at(now)), card.x, card.y, card.w, card.h);
    pill(ctx, th.bg, 1, card.x, card.y, card.w, card.h, card_radius);
    objc.CGContextSaveGState(ctx);
    clipRound(ctx, card.x, card.y, card.w, card.h, card_radius);
    objc.flipText(ctx);

    const total = totalRows(d);
    const last = @min(total, @as(usize, @intFromFloat(@max(@ceil((d.vy + textH(d)) / lh), 0))) + 1);
    const first: usize = @min(@as(usize, @intFromFloat(@max(@floor(d.vy / lh), 0))), last);
    const skip: usize = @intFromFloat(@max(@ceil(d.vx / cw), 0));
    const tx = lx + padL(d);
    const ox = tx + f(skip) * cw - d.vx;
    // Text stops a whole column inside the same margin on the right as on
    // the left, rather than running into the card's border.
    const cols: usize = @intFromFloat(@max(@floor((card.x + card.w - pad_x - ox) / cw), 0));
    const s = d.ed.sel();
    const here = caretRow(d);
    const finding = (d.mode == .find or d.mode == .replace) and d.prompt.items.len > 0;

    // The screen rows in view, and the line and part of it each one shows.
    var vis: [400]VRow = undefined;
    var nvis: usize = 0;
    if (first < last) {
        var i = lineOfRow(d, first);
        var sg = segN(d, b.line(i), first - rowOfLine(d, i));
        while (nvis < @min(last - first, vis.len)) {
            vis[nvis] = .{ .line = i, .seg = sg };
            nvis += 1;
            const l = b.line(i);
            if (sg.end < l.len) {
                sg = nextSeg(d, l, sg);
            } else {
                i += 1;
                if (i >= b.lines()) break;
                sg = segFrom(d, b.line(i), .{});
            }
        }
    }
    syncStates(d, if (nvis > 0) vis[nvis - 1].line else 0);

    // A file freshly read from disk fades in, rising a few points into
    // place. A tab switch just fades from a little dim, with no rise.
    const load = std.math.clamp((now - d.load_t) / loadDur(d), 0, 1);
    const loaded = 1 - (1 - load) * (1 - load) * (1 - load);
    objc.CGContextSaveGState(ctx);
    if (loaded < 1) {
        if (d.rise) {
            objc.CGContextSetAlpha(ctx, loaded);
            objc.CGContextTranslateCTM(ctx, 0, (1 - loaded) * load_rise);
        } else objc.CGContextSetAlpha(ctx, swap_from + (1 - swap_from) * loaded);
    }

    // The caret line's band slides after the caret, and stays on its line
    // under a selection, which draws over it in its own color.
    const band_on = d.mode == .edit;
    if (band_on and d.band_on) d.band.aim(f(here.row) * lh, now) else d.band.snap(f(here.row) * lh);
    d.band_on = band_on;
    d.band_a.aim(if (band_on) 1 else 0, now);
    const band_alpha = d.band_a.at(now);
    if (band_alpha > 0) fillA(ctx, th.line, band_alpha, lx, top_h + d.band.at(now) - d.vy, card.w, lh);
    objc.CGContextClipToRect(ctx, .{ .x = card.x, .y = card.y, .w = ox + f(cols) * cw - card.x, .h = card.h });

    // A new selection fades in.
    const has_sel = s[0] != s[1];
    const was_sel = d.had_sel;
    if (has_sel and !was_sel) d.sel_t0 = now;
    d.had_sel = has_sel;
    const fade = std.math.clamp((now - d.sel_t0) / fade_time, 0, 1);
    const sel_a = 1 - (1 - fade) * (1 - fade) * (1 - fade);
    if (d.ed.buf.changes != d.sel_chg) d.sel_out.snap(0);
    // A selection that collapses with the text untouched (a click, an arrow, Escape)
    // fades out where it was; an edit under it cuts, and a new selection replaces it.
    if (has_sel) {
        d.sel_out.snap(0);
        d.sel_last = s;
    } else if (was_sel and d.ed.buf.changes == d.sel_chg) {
        d.sel_out.snap(sel_a);
        d.sel_out.aim(0, now);
    }
    d.sel_chg = d.ed.buf.changes;
    const out_a = d.sel_out.at(now);

    // The find indicator marks the current match: the selection while it is a
    // match of the search, or the selection a find jump just made.
    var cur_m: ?[2]usize = null;
    if (finding) {
        const want = d.prompt.items;
        if (s[1] - s[0] == want.len and editor.matchAt(d.ed.text(), s[0], want)) cur_m = s;
    } else if (d.mode == .edit and has_sel) {
        const kept = if (d.cur_m) |h| h[0] == s[0] and h[1] == s[1] else false;
        if (d.jumped or kept) cur_m = s;
    }
    const jumped = d.jumped;
    d.jumped = false;
    if (cur_m) |c| {
        // It pops when it first appears and on every jump to a match.
        if (d.cur_m == null or jumped) {
            if (d.pop.settled()) d.pop.t = now;
            d.pop.v = pop_kick;
        }
        if (d.cur_m) |h| if (jumped and h[0] != c[0]) {
            d.prev_m = h;
            d.prev_t0 = now;
        };
    } else if (d.cur_m) |h| {
        d.prev_m = h;
        d.prev_t0 = now;
    }
    d.cur_m = cur_m;
    const pop = 1 + (if (d.pop.settled()) 0 else d.pop.step(now));
    const prev_a = std.math.clamp(1 - (now - d.prev_t0) / fade_time, 0, 1);
    // Opening find on prefilled text starts the matches' staggered fade-in.
    if (!finding) {
        d.find_seen = false;
    } else if (!d.find_seen) {
        d.find_seen = true;
        if (d.fresh) d.stag_t0 = now;
    }
    const flash_a = flashAlpha(d, now);

    // The other matches' pills stay while the find bar slides away, fading with it.
    const closing_find = d.mode == .edit and d.held_id == d.id and (d.held_mode == .find or d.held_mode == .replace) and d.pbar.at(now) > 0.002;
    const pills: []const u8 = if (finding) d.prompt.items else if (closing_find) d.held.items else "";
    const pills_a: f64 = if (finding) 1 else d.pbar.at(now);

    // Backgrounds: selection, find matches.
    for (vis[0..nvis], first..) |v, row| {
        const y = top_h + f(row) * lh - d.vy;
        const ls = b.lineStart(v.line);
        const l = b.line(v.line);
        const sg = v.seg;
        const xat = struct {
            fn x(line: []const u8, g: Seg, p: usize, o: f64, sk: usize) f64 {
                return o + (f(colAt(line, g.start, g.col, p) - g.col) - f(sk)) * cw;
            }
        }.x;
        // Fills the part of `rg` that falls on this row, with a tail past the
        // line's end when `rg` runs on to the next line.
        const span = struct {
            fn fill(c: Id, col: Rgb, a: f64, rg: [2]usize, ls_: usize, line: []const u8, g: Seg, o: f64, sk: usize, y_: f64) void {
                if (rg[0] > ls_ + line.len or rg[1] <= ls_) return;
                const lo = std.math.clamp(@max(rg[0], ls_) - ls_, g.start, g.end);
                const hi = std.math.clamp(@min(rg[1], ls_ + line.len) - ls_, g.start, g.end);
                const tail: f64 = if (rg[1] > ls_ + line.len and g.end == line.len) 0.6 * cw else 0;
                const x0 = xat(line, g, lo, o, sk);
                const w = xat(line, g, hi, o, sk) - x0 + tail;
                if (w > 0) fillA(c, col, a, x0, y_, w, lh);
            }
        }.fill;
        if (has_sel) span(ctx, th.sel, sel_a, s, ls, l, sg, ox, skip, y);
        if (out_a > 0) span(ctx, th.sel, out_a, d.sel_last, ls, l, sg, ox, skip, y);
        if (flash_a > 0) for (d.flash[0..d.flash_n]) |fr| span(ctx, th.caret, flash_a, fr, ls, l, sg, ox, skip, y);
        if (pills.len > 0) {
            // Opening find on prefilled text fades the matches in, the nearest first.
            const dist = if (row > here.row) row - here.row else here.row - row;
            const m_a = std.math.clamp((now - d.stag_t0 - @min(stag_row * f(dist), stag_cap)) / fade_time, 0, 1) * pills_a;
            var j = sg.start -| (pills.len - 1);
            while (j < sg.end and j + pills.len <= l.len) : (j += 1) if (editor.matchAt(l, j, pills)) {
                const lo = @max(j, sg.start);
                const hi = @min(j + pills.len, sg.end);
                if (lo < hi and ls + j != s[0]) {
                    const x0 = xat(l, sg, lo, ox, skip);
                    pill(ctx, th.match, match_alpha * m_a, x0, y + 2, xat(l, sg, hi, ox, skip) - x0, lh - 4, 3);
                }
                j += pills.len - 1;
            };
        }
    }

    // Text.
    var k: Ink = .{ .ctx = ctx };
    d.focus_a.aim(if (d.focus_on) 1 else 0, now);
    const focus_amt = d.focus_a.at(now);
    if (d.focus_on or focus_amt > 0) k.focus = .{ .new = d.focus_new, .old = d.focus_old, .t = std.math.clamp((now - d.focus_t0) / focus_time, 0, 1), .amt = focus_amt };
    k.selected = s;
    std.mem.swap(Kinds, &d.lex[0], &d.lex[1]);
    d.lex[0].clear();
    var walk: usize = 0;
    var lexed: usize = std.math.maxInt(usize);
    var kinds: ?[]const syntax.Kind = null;
    for (vis[0..nvis], first..) |v, row| {
        const l = b.line(v.line);
        if (v.line != lexed) {
            lexed = v.line;
            kinds = if (d.lang != &syntax.plain and v.line < d.states.items.len) lineKinds(d, v.line, l, &walk) else null;
        }
        k.offset = b.lineStart(v.line);
        const row_y = top_h + f(row) * lh - d.vy;
        _ = k.run(l, v.seg.start, v.seg.end, v.seg.col, kinds, th, th.fg, ox, row_y + baseline, skip, cols);
        if (prev_a > 0) pillOver(&k, th, dark, l, k.offset, v.seg, d.prev_m, ox, skip, row_y, 1, prev_a);
        if (cur_m) |m| pillOver(&k, th, dark, l, k.offset, v.seg, m, ox, skip, row_y, pop, 1);
    }
    k.flush();
    k.focus = null;
    objc.CGContextRestoreGState(ctx);

    // The overlay scroll bar fades in while the page moves, and out a second
    // after it stops. The hold costs no frames: `drawPane`'s end sets a
    // one-shot timer that redraws once it's over.
    // Nothing draws or waits when the whole file fits.
    const bar_room = textH(d);
    const range = scrollRange(d);
    const bar_span = range[1] - range[0];
    if (bar_span > 0) {
        if (d.vy != d.bar_vy) {
            d.bar_vy = d.vy;
            d.bar_t0 = now;
            if (d.bar.to != 1) d.bar.dur = bar_in;
            d.bar.aim(1, now);
        }
        if (now >= d.bar_t0 + bar_hold) {
            if (d.bar.to != 0) d.bar.dur = bar_time;
            d.bar.aim(0, now);
        }
        const alpha = d.bar.at(now);
        if (alpha > 0.01) {
            const track = bar_room - 4;
            const knob = @min(@max(@round(track * bar_room / (bar_span + bar_room)), 24), track);
            const at_y = @round((track - knob) * std.math.clamp((d.vy - range[0]) / bar_span, 0, 1));
            pill(ctx, th.fg, bar_alpha * alpha, card.x + card.w - bar_w - 3, top_h + 2 + at_y, bar_w, knob, bar_w * 0.5);
        }
    }

    const by = bottom(d);
    if (d.mode == .edit) {
        const spot: [3]usize = .{ 0, here.row, here.col };
        // A shift-move that extends a selection snaps, like the selection's edge.
        if (has_sel and !std.mem.eql(usize, &spot, &d.spot)) d.snap = true;
        placeCaret(d, now, tx + f(here.col) * cw - 1, top_h + f(here.row) * lh + 2, true, spot, key);
        // A newly shown file's caret fades in with its text.
        if (d.caret_fade and key) {
            d.caret_fade = false;
            fadeIn(d.caret, loadDur(d));
        }
    }

    // The quick open list, rising out of the prompt line.
    const band_y = card.y + card.h - barH();
    const ty = band_y + 6 + baseline;
    const want_ph: f64 = if (listing(d) != null) f(panelRows(d)) * prow + 2 * ppad else 0;
    d.panel.aim(want_ph, now);
    const ph = d.panel.at(now);
    const closing = listing(d) == null;
    // The rows and highlight stay as they were while the panel slides shut.
    if (closing and ph <= 0.5) {
        d.pick_live = false;
        d.pick_s.snap(d.pick_s.to);
    }
    if (ph > 0.5 and (d.palette or d.list != null)) {
        const px = card.x + 6;
        const pw = card.w - 12;
        // Nothing of the page shows beside or just above the inset panel.
        fill(ctx, th.bg, card.x, by - ph - 10, card.w, ph + 10);
        // A soft shadow above the panel instead of a rule.
        for (0..10) |sh| {
            const fall = 1 - (f(sh) + 0.5) / 10;
            fillA(ctx, th.fg, 0.06 * fall * fall, px + 4, by - ph - f(sh) - 1, pw - 8, 1);
        }
        objc.CGContextSaveGState(ctx);
        objc.CGContextClipToRect(ctx, .{ .x = px, .y = by - ph, .w = pw, .h = ph });
        clipRound(ctx, px, by - ph, pw, ph + 8, 8);
        fill(ctx, th.panel, px, by - ph, pw, ph);
        // The picked row's highlight springs from row to row.
        if (!closing) {
            const pick_y = f(d.pick) * prow;
            if (d.pick_live) d.pick_s.aim(pick_y, now) else d.pick_s.snap(pick_y);
            if (!d.pick_live) d.rows_t0 = now;
            d.pick_live = true;
        }
        // The first rows fade in a step apart; rows that changed under the
        // typing crossfade from what was there, and rows that came or went
        // fade in or out in place. A fresh open starts its rows after the
        // picks were made, so it never crosses.
        const swap = std.math.clamp((now - d.pick_t0) / xfade_time, 0, 1);
        const crossing = swap < 1 and d.rows_t0 < d.pick_t0;
        if (d.npicks > 0 or (crossing and d.prev_n > 0)) {
            const keep: f64 = if (d.npicks > 0) 1 else 1 - swap;
            selFill(ctx, th, dark, win_key, keep, px + 6, by - ph + ppad + d.pick_s.step(now), pw - 12, prow, 6);
        } else d.pick_s.snap(d.pick_s.to);
        const shown = if (crossing) @max(d.npicks, d.prev_n) else d.npicks;
        for (0..shown) |i| {
            const y = by - ph + ppad + f(i) * prow;
            const lag = row_lag * f(@min(i, 5));
            const t = std.math.clamp((now - d.rows_t0 - lag) / row_fade, 0, 1);
            const a = t * t * (3 - 2 * t);
            const rise = (1 - a) * 2;
            if (i >= d.npicks) {
                panelRow(ctx, d, th, d.prev_picks[i], px + 14, px + pw - 14, y, a * (1 - swap), rise);
                continue;
            }
            const p = d.picks[i];
            if (crossing and i >= d.prev_n) {
                panelRow(ctx, d, th, p, px + 14, px + pw - 14, y, a * swap, rise);
            } else if (crossing and d.prev_picks[i] != p) {
                panelRow(ctx, d, th, d.prev_picks[i], px + 14, px + pw - 14, y, a * (1 - swap), rise);
                panelRow(ctx, d, th, p, px + 14, px + pw - 14, y, a * swap, rise);
            } else panelRow(ctx, d, th, p, px + 14, px + pw - 14, y, a, rise);
        }
        // No match leaves one dim row, so the panel keeps a row's height. It
        // fades in as the rows it replaces fade out, and out as rows return.
        if (d.npicks == 0 or (crossing and d.prev_none)) {
            const lone: f64 = if (d.npicks > 0) 1 - swap else if (crossing and !d.prev_none) swap else 1;
            const t = std.math.clamp((now - d.rows_t0) / row_fade, 0, 1);
            const a = t * t * (3 - 2 * t);
            panelNone(ctx, th, px + 14, by - ph + ppad, a * lone, (1 - a) * 2);
        }
        k.flush();
        objc.CGContextRestoreGState(ctx);
    }

    // The prompt line: find, replace, go to line, quick open and the palette.
    // Its band slides up from the card's bottom as it opens and back down as
    // it closes, drawing what it last showed until it's gone. The text above
    // already uses the final `bottom()`.
    var buf: [64]u8 = undefined;
    // A window that isn't key dims its header and prompt a step.
    const ink = mixRgb(th.muted, th.fg, ka);
    const prompting = d.mode != .edit;
    const nomatch = prompting and finding and d.found[1] == 0;
    if (nomatch and !d.nomatch) d.shake_t0 = now;
    d.nomatch = nomatch;
    // "No matches" shakes the words sideways, settling over `shake_time`.
    const shake_p = (now - d.shake_t0) / shake_time;
    const shake = if (shake_p >= 0 and shake_p < 1) 6 * @sin(2 * std.math.pi * 3 * shake_p) * (1 - shake_p) else 0;
    if (prompting) {
        if (!d.prompt_on) {
            d.prompt_t.snap(0);
            d.pbar_t0 = now;
        }
        d.prompt_on = true;
        if (d.pbar.to != 1) d.pbar.dur = panel_time;
        d.pbar.aim(1, now);
        // The words rise a beat after the band starts.
        if (now >= d.pbar_t0 + words_lag) d.prompt_t.aim(1, now);
        var tally: []const u8 = "";
        if (finding) tally = if (d.found[1] == 0) "no matches" else std.fmt.bufPrint(&buf, "{d} of {d}", .{ @min(d.found[0], d.found[1]), d.found[1] }) catch "";
        if (d.mode == .open and d.list != null) tally = std.fmt.bufPrint(&buf, "{d} files", .{d.list.?.paths.items.len}) catch "";
        if (d.mode == .command) tally = std.fmt.bufPrint(&buf, "{d} commands", .{cmds.items.len}) catch "";
        d.held_n = @min(tally.len, d.held_tally.len);
        @memcpy(d.held_tally[0..d.held_n], tally[0..d.held_n]);
        d.held_mode = d.mode;
        d.held_id = d.id;
        d.held_which = d.which;
        d.held.clearRetainingCapacity();
        d.held.appendSlice(gpa, d.prompt.items) catch {};
        d.held_with.clearRetainingCapacity();
        d.held_with.appendSlice(gpa, d.with.items) catch {};
    } else {
        d.prompt_on = false;
        if (d.pbar.to != 0) d.pbar.dur = band_out;
        d.pbar.aim(0, now);
    }
    const slide = d.pbar.at(now);
    if (prompting or slide > 0.002) {
        const drop = (1 - slide) * barH();
        objc.CGContextSaveGState(ctx);
        objc.CGContextTranslateCTM(ctx, 0, drop);
        fill(ctx, th.bg, card.x, band_y, card.w, barH());
        fill(ctx, th.rule, card.x, band_y, card.w, hair());
        // The prompt's words rise into place as it opens.
        const rise = d.prompt_t.at(now);
        if (rise < 1) {
            objc.CGContextSetAlpha(ctx, rise);
            objc.CGContextTranslateCTM(ctx, 0, (1 - rise) * 6);
        }
        var x: f64 = tx + shake;
        const label = switch (d.held_mode) {
            .find, .replace => "find",
            .line => "line",
            .command => "run",
            else => "open",
        };
        x += f(k.text(label, null, th, th.caret, x, ty, 0, 8) + 1) * cw;
        // A prefilled selection fades out over `fade_time` once typing or a
        // click ends it, at the width it had.
        if (prompting and d.fresh) {
            d.fresh_w = f(editor.colOf(d.held.items, d.held.items.len)) * cw;
            d.fresh_shown = true;
        } else if (d.fresh_shown) {
            d.fresh_shown = false;
            d.fresh_t0 = now;
        }
        const band_a = if (d.fresh_shown) 1 else 1 - std.math.clamp((now - d.fresh_t0) / fade_time, 0, 1);
        if (band_a > 0 and d.fresh_w > 0) {
            k.flush();
            fillA(ctx, th.sel, band_a, x, band_y + 6, d.fresh_w, lh);
        }
        x += f(k.text(d.held.items, null, th, ink, x, ty, 0, 400)) * cw;
        var cx = x;
        if (d.held_mode == .replace) {
            x += 2 * cw;
            x += f(k.text("with", null, th, th.caret, x, ty, 0, 8) + 1) * cw;
            x += f(k.text(d.held_with.items, null, th, ink, x, ty, 0, 400)) * cw;
            if (d.held_which == 1) cx = x;
        }
        k.flush();
        if (prompting) {
            const width = if (d.which == 1 and d.mode == .replace) d.with.items.len else d.prompt.items.len;
            placeCaret(d, now, cx, band_y + 8 + drop, false, .{ 1 + @as(usize, @intFromEnum(d.mode)) * 2 + d.which, width, 0 }, key);
        }
        const tally = d.held_tally[0..d.held_n];
        _ = k.text(tally, null, th, th.muted, card.x + card.w - pad_x - f(tally.len) * cw, ty, 0, 64);
        k.flush();
        objc.CGContextRestoreGState(ctx);
    } else d.fresh_shown = false;

    // An empty window says what to do: its hint fades in after a pause, so
    // a restored session never flashes it, and out on the first key.
    const blank = isBlank(d) and d.mode == .edit and !d.closing;
    if (blank) {
        if (d.blank_t0 < 0) d.blank_t0 = now;
        if (now >= d.blank_t0 + hint_delay) {
            if (d.hint.to != 1) d.hint.dur = hint_in;
            d.hint.aim(1, now);
        }
    } else {
        d.blank_t0 = -1;
        if (d.hint.to != 0) d.hint.dur = fade_time;
        d.hint.aim(0, now);
    }
    const hint_a = d.hint.at(now);
    if (hint_a > 0.01) {
        const line = "⌘P Quick Open   ⌘O Open   ⌘K Commands";
        const n = std.unicode.utf8CountCodepoints(line) catch line.len;
        k.flush();
        objc.CGContextSaveGState(ctx);
        objc.CGContextSetAlpha(ctx, hint_alpha * hint_a);
        _ = k.text(line, null, th, th.muted, @round(card.x + (card.w - f(n) * cw) / 2), @round((top_h + by - lh) / 2) + baseline, 0, 80);
        k.flush();
        objc.CGContextRestoreGState(ctx);
    }

    // The header, over any text scrolled under it: the file's name and
    // folder, or the window's tabs.
    // The header has its own shade and a hairline under it, set apart from the text.
    // Zen blends the header out into a plain margin.
    const zt = std.math.clamp(d.win.z.x, 0, 1);
    fill(ctx, th.bg, card.x, card.y, card.w, top_h - gap);
    if (zt < 0.999) {
        if (zt > 0.001) {
            objc.CGContextSetAlpha(ctx, 1 - zt);
            objc.CGContextBeginTransparencyLayer(ctx, null);
        }
        fill(ctx, th.header, card.x, card.y, card.w, head_h);
        fill(ctx, th.rule, card.x, card.y + head_h, card.w, hair());
        fill(ctx, th.bg, card.x, card.y + head_h + hair(), card.w, top_h - gap - head_h - hair());
        const hy = gap + head_h / 2;
        const mono_y = @round(hy - lh / 2 + baseline);
        const right = card.x + card.w - 10;
        objc.CGContextClipToRect(ctx, .{ .x = card.x, .y = card.y, .w = @max(right - card.x, 0), .h = head_h });
        // The traffic lights and the sidebar button sit on a card at the window's top left.
        const lights_end: f64 = if (root != null) toggle_x + 22 else tabs_from;
        drawTabs(d, ctx, th, &k, dark, ka, @max(card.x + 14, if (d.org.y < 1) lights_end - d.org.x else 0), right, mono_y, now);
        k.flush();
        if (zt > 0.001) objc.CGContextEndTransparencyLayer(ctx);
    }
    objc.CGContextRestoreGState(ctx);

    // The card's outline. In a window with more than one, the card that
    // takes typing also gets a ring in the caret's color, which fades
    // from card to card. Zen fades both out.
    const calm = 1 - zt;
    if (calm > 0.01) {
        const ring_a: f64 = if (contrast) 0.35 else if (dark) 0.16 else 0.14;
        ring(ctx, th.fg, ring_a * calm, card.x, card.y, card.w, card.h, card_radius);
        // Dark cards catch a faint light along their top edge, just inside the ring.
        if (dark) {
            objc.CGContextSaveGState(ctx);
            clipRound(ctx, card.x, card.y, card.w, card.h, card_radius);
            fillA(ctx, .{ 1, 1, 1 }, 0.05 * calm, card.x, card.y + hair(), card.w, hair());
            objc.CGContextRestoreGState(ctx);
        }
        const lit = d.lit.at(now);
        if (lit > 0.01) ring(ctx, th.caret, 0.55 * lit * calm, card.x, card.y, card.w, card.h, card_radius);
    }
    d.busy = scenery(d, now);
    // The scroll bar's hold has no frames to draw: a one-shot timer redraws
    // when it's over, and the fade out takes it from there.
    if (d.bar.to == 1 and !d.busy) {
        const left = @max(d.bar_t0 + bar_hold - now, 0) + 0.02;
        msg(void, d.view, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("barHold:"), @as(Id, null), left });
    }
}

/// The sidebar button by the traffic lights, or the + at the sidebar's
/// top right, under `p` in the view: anywhere on its capsule.
fn toolAt(w: *const Win, p: Point) ?Icon {
    if (conf.zen or @abs(p.y - (gap + head_h / 2)) > 14) return null;
    if (root != null and @abs(p.x - toggle_x) <= 14) return .sidebar;
    if (sideShown(w) and @abs(p.x - (side_w - gap - 20)) <= 14) return .plus;
    return null;
}

/// Whether `p`, in the card's pane, is on the + after its tabs.
fn onTabPlus(d: *const Doc, p: Point) bool {
    return !conf.zen and d.tabbed.to == 1 and @abs(p.y - (gap + head_h / 2)) <= 14 and @abs(p.x - d.plus_x) <= 14;
}

/// Brings the header's slots in line with the window's tabs: a new tab
/// pops in right after the tab before it, and a closed one folds away.
fn syncSlots(d: *Doc, now: f64) void {
    for (d.slots.items) |*s| if (!s.gone and tabIndex(d, s.id) == null) {
        s.gone = true;
        // Folding shut doesn't bounce.
        s.grow.c = 2 * @sqrt(s.grow.k);
        s.grow.aim(0, now);
    };
    for (0..tabCount(d)) |j| {
        const id = tabId(d, j);
        if (slotOf(d, id) != null) continue;
        const pos = if (j == 0) 0 else slotOf(d, tabId(d, j - 1)).? + 1;
        var s: Slot = .{ .id = id };
        if (d.slots_seen) s.grow.aim(1, now) else s.grow.snap(1);
        d.slots.insert(gpa, pos, s) catch return;
    }
    d.slots_seen = true;
    var i: usize = 0;
    while (i < d.slots.items.len) {
        const s = &d.slots.items[i];
        if (s.gone and s.grow.settled()) {
            s.drop();
            _ = d.slots.orderedRemove(i);
        } else i += 1;
    }
}

fn slotOf(d: *const Doc, id: u32) ?usize {
    for (d.slots.items, 0..) |s, i| if (s.id == id and !s.gone) return i;
    return null;
}

/// True while a tab pops, folds, fades, resizes or the highlight springs,
/// or the + after the tabs fades from a click.
fn tabsMoving(d: *const Doc, now: f64) bool {
    if (d.tabbed.moving(now) or d.tab_x.moving(now) or !d.hl[0].settled() or !d.hl[1].settled()) return true;
    if (!d.opening.settled() or d.plus_down.moving(now)) return true;
    for (d.slots.items) |s| if (s.gone or !s.grow.settled() or !s.shift.settled() or s.hov.moving(now) or s.xhov.moving(now) or !s.dot.settled() or !s.wid.settled()) return true;
    return false;
}

/// Room the header keeps in a tab for the close button, either side of
/// it, and between tabs; with one tab, none.
const tab_pad = 10.0;
const tab_shut = 18.0;
const tab_space = 4.0;

/// A tab's width at rest: its padding, tile, name and close button, and
/// with one tab the unsaved dot after the name. The name's part springs
/// (`Slot.wid`), so a renamed tab eases to its new width.
fn tabWidth(s: *const Slot, a: f64) f64 {
    return 2 * tab_pad * a + tileSize() + 7 + s.wid.x + tab_shut * a + 14 * (1 - a) * std.math.clamp(s.dot.x, 0, 1);
}

/// The header's left side, from `x0` to `x1`. With one tab it's the file's
/// name, unsaved dot and folder; with more, a row of tabs and a + after
/// them, which the one tab grows into. The active tab's highlight springs
/// from tab to tab, and the row scrolls to keep it in view.
fn drawTabs(d: *Doc, ctx: Id, th: *const Theme, k: *Ink, dark: bool, ka: f64, x0: f64, x1: f64, mono_y: f64, now: f64) void {
    const n = tabCount(d);
    const want: f64 = if (n > 1) 1 else 0;
    if (d.slots_seen) d.tabbed.aim(want, now) else d.tabbed.snap(want);
    syncSlots(d, now);
    const a = std.math.clamp(d.tabbed.at(now), 0, 1);
    const ts = tileSize();
    const hy = gap + head_h / 2;
    const pad = tab_pad * a;
    for (d.slots.items) |*s| {
        if (s.line == null) {
            if (tabIndex(d, s.id)) |j| {
                var nb: [48]u8 = undefined;
                const nm = tabName(d, j, &nb);
                s.line = uiLine(nm, tab_bold, 1e5);
                s.thin = uiLine(nm, tab_font, 1e5);
                s.icon = iconFor(if (tabPath(d, j) != null) nm else "");
            }
        }
        const nw = if (s.line != null) objc.CTLineGetTypographicBounds(s.line, null, null, null) else 0;
        if (s.sized) s.wid.aim(nw, now) else s.wid.snap(nw);
        s.sized = true;
        _ = s.wid.step(now);
        const dirty = !s.gone and if (tabIndex(d, s.id)) |j| tabDirty(d, j) else false;
        s.dot.aim(if (dirty) 1 else 0, now);
        _ = s.dot.step(now);
    }

    // Squeeze the tabs to a common cap when they don't all fit, down to
    // enough for the tile and a few letters.
    const room = x1 - x0 - 28 * a;
    var cap: f64 = 1e9;
    if (n > 1) {
        var lo: f64 = 2 * pad + ts + tab_shut * a + 36;
        var hi: f64 = 1e4;
        for (0..24) |_| {
            const mid = (lo + hi) / 2;
            var sum: f64 = 0;
            for (d.slots.items) |*s| if (!s.gone) {
                sum += @min(tabWidth(s, a), mid) + tab_space * a;
            };
            if (sum <= room) lo = mid else hi = mid;
        }
        cap = lo;
    }

    // Where each tab sits, popping ones at their bounce, with a gap opening
    // for a tab dragged over the row.
    const off = d.tab_x.at(now);
    var x = x0 - pad - off;
    var act: [2]f64 = .{ x, 0 };
    d.open_px = d.open_w * @max(d.opening.step(now), 0);
    var live: usize = 0;
    for (d.slots.items) |*s| {
        if (!s.gone) {
            if (live == d.open_at) x += d.open_px;
            live += 1;
        }
        const g = @max(s.grow.step(now), 0);
        s.x = x;
        s.w = @min(tabWidth(s, a), cap) * g;
        x += s.w + tab_space * a * @min(g, 1);
    }
    if (live <= d.open_at) x += d.open_px;
    const end = x;
    // Reordered tabs slide from where they were drawn; the dragged one
    // follows the mouse along the row, then springs into its place.
    const dragged = draggedTab(d);
    var held_id: u32 = 0;
    for (d.slots.items) |*s| {
        if (s.flip) |was| {
            s.shift.snap(was - s.x);
            s.flip = null;
        }
        if (dragged) |t| if (!t.out and s.id == t.id) {
            held_id = s.id;
            const left = std.math.clamp(t.at.x - d.org.x - t.grab, x0 - pad, @max(end - tab_space * a - s.w, x0 - pad));
            s.shift.snap(left - s.x);
        };
        if (s.id != held_id) s.shift.aim(0, now);
        _ = s.shift.step(now);
        if (!s.gone and s.id == d.id) act = .{ s.x, s.w };
    }
    const span = end + off - (x0 - pad);
    d.tab_x.aim(std.math.clamp(act[0] + off - (x0 - pad) + act[1] / 2 - room / 2, 0, @max(span - room, 0)), now);
    if (slotOf(d, d.id)) |i| act[0] += d.slots.items[i].shift.x;

    // The tab being dragged, or springing back into place, draws last on
    // its own backing, over the ones it slides past, and the highlight
    // stays under it. Off its row it's faint.
    const top_id = if (held_id != 0) held_id else if (slotOf(d, d.id)) |i| (if (d.slots.items[i].shift.settled()) 0 else d.id) else 0;

    // The active tab's highlight, with one tab sitting on it unseen.
    for (&d.hl, act) |*h, v| if (a < 0.01 or top_id == d.id) h.snap(v) else h.aim(v, now);
    const hx = d.hl[0].step(now);
    const hw = d.hl[1].step(now);
    if (a > 0.01) {
        pill(ctx, th.fg, (0.05 + 0.03 * ka) * a, hx, hy - 11, hw, 22, 7);
        ring(ctx, th.fg, (0.06 + 0.04 * ka) * a, hx, hy - 11, hw, 22, 7);
    }

    for (0..2) |pass| {
        for (d.slots.items) |*s| {
            if ((s.id == top_id) != (pass == 1)) continue;
            const back = if (d.win.fly) |fl| fl.card == d and fl.id == s.id else false;
            drawTab(d, s, ctx, th, dark, ka, a, cap, x0, x1, now, back or (dragged != null and dragged.?.out and s.id == dragged.?.id), pass == 1);
        }
    }

    // With one tab, the folder after the name; with more, the + after the
    // tabs. One goes before the other comes, so they never overlap.
    const folder_a = std.math.clamp(1 - 2 * a, 0, 1);
    const plus_a = std.math.clamp(2 * a - 1, 0, 1);
    var nx = end + 8;
    if (folder_a > 0.01) {
        const note_w = if (d.note.len > 0) f(d.note.len + 2) * cw else 0;
        const head_room = @max(@floor(x1 - nx - note_w), 24);
        // Made again when `dropHead` clears it, when the room shrinks below
        // the line, or when the room changes for a line that was cut; one
        // that fit whole stays right in more room. A file at the top of the
        // open folder has none.
        if (d.head_w < 0 or (d.head_w != head_room and (d.head_cut or head_room < d.head_lw))) {
            if (d.head) |l| objc.CFRelease(l);
            d.head = headLine(d, head_room);
            d.head_w = head_room;
        }
        objc.CGContextSaveGState(ctx);
        objc.CGContextSetAlpha(ctx, folder_a);
        const fx = nx + 6 * (1 - folder_a);
        const fw = drawLine(ctx, d.head, th.muted, fx, @round(hy + path_off));
        for (d.head_marks[0..d.head_n]) |m| drawIcon(icon(.crumb, dark, th), fx + m - 5, hy - 5, 10);
        if (fw > 0) nx += fw + 2 * cw;
        objc.CGContextRestoreGState(ctx);
    }
    d.plus_x = if (a > 0.5) end + 14 else -100;
    if (plus_a > 0.01) {
        objc.CGContextSaveGState(ctx);
        objc.CGContextSetAlpha(ctx, plus_a);
        d.plus_t.aim(if (d.plus_on) 1 else 0, now);
        const px = end + 4 - 8 * (1 - plus_a);
        hoverPill(ctx, th, d.plus_t.at(now), d.plus_down.at(now), px + 10, hy);
        drawIcon(icon(.plus, dark, th), px, hy - 10, 20);
        objc.CGContextRestoreGState(ctx);
        nx = @max(nx, end + 36);
    }
    if (d.note.len > 0) _ = k.text(d.note, null, th, th.muted, nx, mono_y, 0, 200);
    k.flush();
}

/// One tab of `d`'s header, where it lays out plus its slide; `a` is how
/// far the header has turned into tabs and `cap` the squeezed tabs' width.
/// Its name lights up, from regular at 0.62 to medium at full ink, as the
/// active tab's highlight lands on it, and its contents grow in with it.
fn drawTab(d: *Doc, s: *Slot, ctx: Id, th: *const Theme, dark: bool, ka: f64, a: f64, cap: f64, x0: f64, x1: f64, now: f64, faint: bool, lifted: bool) void {
    const hy = gap + head_h / 2;
    const ts = tileSize();
    const pad = tab_pad * a;
    const sx = s.x + s.shift.x;
    if (s.w < 0.5 or sx > x1 or sx + s.w < x0 - pad) return;
    const j = if (s.gone) null else tabIndex(d, s.id);
    const on = j != null and j.? == d.at;
    const hovered = j != null and s.id == d.hover;
    s.hov.aim(if (hovered) 1 else 0, now);
    s.xhov.aim(if (hovered and d.hover_x) 1 else 0, now);
    const hv = s.hov.at(now) * a;
    const g = std.math.clamp(s.grow.x, 0, 1);
    objc.CGContextSaveGState(ctx);
    objc.CGContextClipToRect(ctx, .{ .x = sx, .y = hy - 12, .w = s.w, .h = 24 });
    const alpha = g * @as(f64, if (faint) 0.35 else 1);
    if (alpha < 1) objc.CGContextSetAlpha(ctx, alpha);
    if (lifted) {
        pill(ctx, th.header, 1, sx, hy - 11, s.w, 22, 7);
        pill(ctx, th.fg, (0.05 + 0.03 * ka) * a, sx, hy - 11, s.w, 22, 7);
        ring(ctx, th.fg, (0.06 + 0.04 * ka) * a, sx, hy - 11, s.w, 22, 7);
    }
    if (hv > 0.01 and !on) pill(ctx, th.fg, 0.05 * hv, sx, hy - 11, s.w, 22, 7);
    if (d.win.menu_card == d and d.win.menu_tab == s.id) {
        const ma = d.win.menu_a.at(now);
        if (ma > 0.01) menuMark(ctx, th, ma, sx, hy - 11, s.w, 22, 7);
    }
    // The icon, name, dot and × grow from 0.92 on the tab's spring.
    const sc = 0.92 + 0.08 * std.math.clamp(s.grow.x, 0, 1.2);
    if (@abs(sc - 1) > 0.001) {
        objc.CGContextTranslateCTM(ctx, sx + s.w / 2, hy);
        objc.CGContextScaleCTM(ctx, sc, sc);
        objc.CGContextTranslateCTM(ctx, -(sx + s.w / 2), -hy);
    }
    tile(s.icon, sx + pad, @round(hy - ts / 2));
    const nx = sx + pad + ts + 7;
    const nw = if (s.line != null) objc.CTLineGetTypographicBounds(s.line, null, null, null) else 0;
    // The name stops short of the close button.
    const shut_x = sx + s.w - pad - tab_shut * a;
    objc.CGContextSaveGState(ctx);
    const fit = shut_x - nx;
    objc.CGContextClipToRect(ctx, .{ .x = nx, .y = hy - 12, .w = @max(fit + 1, 0), .h = 24 });
    // A squeezed tab's name ends in an ellipsis; one popping in or
    // folding away is just cut off.
    const room_w = @floor(cap - 2 * pad - ts - 7 - tab_shut * a);
    const squeezed = j != null and room_w + 1 < nw;
    if (squeezed and room_w != s.cut_w) {
        for ([_]*Id{ &s.cut, &s.thin_cut }) |l| if (l.*) |old| objc.CFRelease(old);
        s.cut = cutTab(s.line, 0, room_w);
        s.thin_cut = cutTab(s.thin, 1, room_w);
        s.cut_w = room_w;
    }
    // How much the highlight covers this tab, so a tab that it only sits
    // next to stays unlit; a lone tab is the window's title.
    const cover = @min(d.hl[0].x + d.hl[1].x, sx + s.w) - @max(d.hl[0].x, sx);
    const lit = if (a < 0.5) 1 else std.math.clamp(cover / @max(s.w, d.hl[1].x, 1), 0, 1);
    const ink_a = 1 + (0.62 + 0.38 * @max(lit, hv) - 1) * ka;
    const ink = mixRgb(th.muted, th.fg, ka);
    const by = @round(hy + name_off);
    // The weight switches halfway while the ink brightens: the two weights
    // have different widths, so drawing both at once smears the name.
    objc.CGContextSetAlpha(ctx, alpha * ink_a);
    const name = if (lit >= 0.5)
        (if (squeezed and s.cut != null) s.cut else s.line)
    else
        (if (squeezed and s.thin_cut != null) s.thin_cut else s.thin);
    _ = drawLine(ctx, name, ink, nx, by);
    objc.CGContextRestoreGState(ctx);
    // The unsaved dot sits after the name with one tab and slides into
    // the close button's place with more; hovering trades it for the ×.
    const cx = shut_x + tab_shut * a / 2;
    const dv = std.math.clamp(s.dot.x, 0, 1.3);
    // On the active tab the × and the dot trade places as the dot comes and goes.
    const cross = a * @max(hv, if (on) 1 - @min(dv, 1) else 0);
    if (dv > 0.01 and cross < 0.5) {
        const dx = nx + s.wid.x + 9 + (cx - nx - s.wid.x - 9) * a;
        const r = 3 * dv;
        pill(ctx, th.caret, (1 - 2 * cross) * @min(dv, 1), dx - r, hy - r, 2 * r, 2 * r, r);
    }
    if (cross > 0.01) {
        const xv = s.xhov.at(now) * a;
        if (xv > 0.01) pill(ctx, th.fg, 0.1 * xv, cx - 8, hy - 8, 16, 16, 5);
        objc.CGContextSetAlpha(ctx, alpha * cross);
        drawIcon(icon(.close, dark, th), cx - 6, hy - 6, 12);
    }
    objc.CGContextRestoreGState(ctx);
}

/// The drag of one of `d`'s tabs, once the mouse has moved far enough.
fn draggedTab(d: *const Doc) ?*TabDrag {
    if (d.win.tdrag) |*t| if (t.from) |x| if (x == d and t.live) return t;
    return null;
}

const TabHit = struct { j: usize, id: u32, close: bool };

/// The tab under `p`, and whether it's over the tab's close button. Only
/// with two tabs or more; one is the window's title.
fn tabAt(d: *const Doc, p: Point) ?TabHit {
    if (conf.zen or d.tabbed.to != 1 or @abs(p.y - (gap + head_h / 2)) > 12) return null;
    for (d.slots.items) |s| {
        if (s.gone or p.x < s.x or p.x >= s.x + s.w) continue;
        const j = tabIndex(d, s.id) orelse return null;
        return .{ .j = j, .id = s.id, .close = p.x >= s.x + s.w - tab_pad - tab_shut };
    }
    return null;
}

/// With more than one card, a card's lone file name drags like a tab.
fn loneTab(d: *const Doc, p: Point) ?TabHit {
    return if (d.win.cards.pane != null) null else titleTab(d, p);
}

/// The card's lone file name under `p`, when it has one tab.
fn titleTab(d: *const Doc, p: Point) ?TabHit {
    if (conf.zen or d.tabbed.to != 0 or @abs(p.y - (gap + head_h / 2)) > 12) return null;
    const s = d.slots.items[slotOf(d, d.id) orelse return null];
    if (p.x < s.x or p.x >= s.x + s.w) return null;
    return .{ .j = 0, .id = d.id, .close = false };
}

// ---- dragging tabs ----

/// Follows a tab drag to `p` in the view. Along its own row the tab
/// trades places with the tabs it passes; anywhere else, and for a file
/// from the sidebar, it shows where it would drop.
fn dragTab(w: *Win, p: Point) void {
    const t = &w.tdrag.?;
    if (t.from) |d| if (d.closing) return endDrag(w);
    t.at = p;
    if (!t.live) {
        if (@abs(p.x - t.down.x) < 4 and @abs(p.y - t.down.y) < 4) return;
        t.live = true;
    }
    const was: ?Zone = if (t.drop) |x| x.zone else null;
    t.drop = null;
    t.out = true;
    if (t.from) |d| {
        const lp = inPane(d, p);
        t.out = tabCount(d) == 1 or lp.x < 0 or lp.x >= d.size.x or lp.y < 0 or lp.y >= top_h + 8;
        if (!t.out) if (tabIndex(d, t.id)) |j| {
            // It trades places with a tab once its middle passes that tab's.
            const s = d.slots.items[slotOf(d, t.id).?];
            const mid = lp.x - t.grab + s.w / 2;
            var k: usize = 0;
            for (d.slots.items) |o| if (!o.gone and o.id != t.id and o.x + o.w / 2 < mid) {
                k += 1;
            };
            if (k != j) haptic(.alignment);
            reorderTab(d, j, k);
        };
    }
    if (t.out) t.drop = dropAt(w, t, p);
    const now_zone: ?Zone = if (t.drop) |x| x.zone else null;
    if (was != now_zone) haptic(.level);
    aimPreview(w, CACurrentMediaTime());
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// Ends the drag in `w` without dropping it.
fn endDrag(w: *Win) void {
    const t = w.tdrag orelse return;
    w.tdrag = null;
    freeDrag(t);
}

fn freeDrag(t: TabDrag) void {
    if (t.file) |p| gpa.free(p);
    if (t.name) |l| objc.CFRelease(l);
}

/// Where a tab dragged off its row to `p` would land: among another
/// card's tabs, in a new card off the nearest edge of the card under it
/// when `p` is within a quarter of that edge and there's room, or else
/// on that card. Null over the sidebar, the gaps, or its own card's
/// middle, and its own card's edges when it's that card's only tab. A
/// file from the sidebar splits off the nearest edge from anywhere over
/// the text, and lands on the card only when there's no room.
fn dropAt(w: *Win, t: *const TabDrag, p: Point) ?Drop {
    if (sideShown(w) and p.x < side_w) return null;
    const c = paneAt(w, p) orelse return null;
    const own = if (t.from) |x| x == c else false;
    const lp = inPane(c, p);
    if (lp.y < top_h) {
        if (own) return null;
        var k: usize = 0;
        for (c.slots.items) |o| if (!o.gone and o.x + o.w / 2 < lp.x) {
            k += 1;
        };
        return .{ .card = c, .zone = .tabs, .k = k };
    }
    const u = (lp.x - gap) / @max(c.size.x - 2 * gap, 1);
    const v = (lp.y - gap) / @max(c.size.y - 2 * gap, 1);
    const near = [4]f64{ u, 1 - u, v, 1 - v };
    const edges = [4]Zone{ .left, .right, .top, .bottom };
    var best: ?usize = null;
    for (near, 0..) |x, i| if ((t.from == null or x < 0.25) and (best == null or x < near[best.?])) {
        best = i;
    };
    if (best) |i| if ((!own or tabCount(c) > 1) and roomFor(c, i >= 2)) return .{ .card = c, .zone = edges[i] };
    if (own) return null;
    return .{ .card = c, .zone = .whole, .k = c.at + 1 };
}

/// The drop preview for `dr`, in the view: the gap that opens among the
/// tabs, `gw` wide, or the card or the half of it that the new card takes.
fn dropRect(dr: Drop, gw: f64) Rect {
    const c = dr.card;
    const r: Rect = .{ .x = c.org.x + gap, .y = c.org.y + gap, .w = c.size.x - 2 * gap, .h = c.size.y - 2 * gap };
    return switch (dr.zone) {
        .tabs => {
            // Where tab `k` starts with no gap open, from where it drew.
            var x: f64 = r.x + 14;
            var i: usize = 0;
            for (c.slots.items) |o| if (!o.gone) {
                const was = if (i >= c.open_at) c.open_px else 0;
                if (i == dr.k) {
                    x = o.x - was;
                    break;
                }
                x = o.x + o.w + tab_space - was;
                i += 1;
            };
            return .{ .x = c.org.x + x, .y = c.org.y + gap + head_h / 2 - 11, .w = gw, .h = 22 };
        },
        .whole => .{ .x = r.x + 6, .y = r.y + 6, .w = r.w - 12, .h = r.h - 12 },
        .left => .{ .x = r.x, .y = r.y, .w = r.w / 2, .h = r.h },
        .right => .{ .x = r.x + r.w / 2, .y = r.y, .w = r.w / 2, .h = r.h },
        .top => .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h / 2 },
        .bottom => .{ .x = r.x, .y = r.y + r.h / 2, .w = r.w, .h = r.h / 2 },
    };
}

/// Where the dragged copy's tab pill lands when `dr` splits off a new card:
/// the title spot of the half the card will take, in the view.
fn titleSpot(dr: Drop) Point {
    const r = dropRect(dr, 0);
    // A card at the window's top left clears the traffic lights.
    const lights_end: f64 = if (root != null) toggle_x + 22 else tabs_from;
    const x = if (r.y < gap + 1) @max(r.x + 14, lights_end) else r.x + 14;
    return .{ .x = x, .y = r.y + head_h / 2 - 11 };
}

/// The dragged tab's or file's name and icon, for its copy under the mouse.
fn ghostOf(t: *const TabDrag) ?struct { line: Id, icon: Id } {
    if (t.from) |d| {
        const s = d.slots.items[slotOf(d, t.id) orelse return null];
        return .{ .line = s.line, .icon = s.icon };
    }
    return .{ .line = t.name, .icon = iconFor(std.fs.path.basename(t.file.?)) };
}

/// The width of the dragged tab's copy under the mouse.
fn ghostW(t: *const TabDrag) f64 {
    const g = ghostOf(t) orelse return 80;
    const nw = if (g.line != null) objc.CTLineGetTypographicBounds(g.line, null, null, null) else 0;
    return 2 * tab_pad + tileSize() + 7 + nw;
}

/// Springs the drop preview to where the drag would land, opens a gap in
/// the tab row it's over (the tabs there slide aside), and fades the
/// dragged tab's copy in off its row. A preview that was out grows into
/// place from a little smaller.
fn aimPreview(w: *Win, now: f64) void {
    const t = if (w.tdrag) |*p| p else null;
    const dr: ?Drop = if (t) |x| x.drop else null;
    const gw = if (t) |x| ghostW(x) else 0;
    w.ghost_a.aim(if (t != null and t.?.live and t.?.out) 1 else 0, now);
    if (dr) |x| {
        const r = dropRect(x, gw);
        const to = [4]f64{ r.x, r.y, r.w, r.h };
        if (w.pv_a.to == 0 and w.pv_a.at(now) < 0.05) {
            const from = [4]f64{ r.x + r.w * 0.06, r.y + r.h * 0.06, r.w * 0.88, r.h * 0.88 };
            for (&w.pv, from) |*s, v| s.snap(v);
        }
        for (&w.pv, to) |*s, v| s.aim(v, now);
        if (w.pv_a.to != 1) w.pv_a.dur = fade_time;
        w.pv_a.aim(1, now);
    } else {
        // A split drop's preview ring fades out into the new card's ring.
        if (w.pv_a.to != 0) w.pv_a.dur = if (w.pv_cross) 0.15 else fade_time;
        w.pv_cross = false;
        w.pv_a.aim(0, now);
    }
    for (docs.items) |d| if (d.win == w) {
        const over = dr != null and dr.?.zone == .tabs and dr.?.card == d;
        if (over and d.open_at != dr.?.k) {
            // The gap moves: the tabs between slide from where they are.
            if (d.opening.x > 0.01) for (d.slots.items) |*s| {
                s.flip = s.x + s.shift.x;
            };
            d.open_at = dr.?.k;
        }
        if (over) d.open_w = gw + tab_space;
        d.opening.aim(if (over) 1 else 0, now);
        if (!d.opening.settled()) refresh(d);
    };
}

/// Ends a tab drag: a tab dragged along its row springs into its place,
/// and one dropped elsewhere moves there and takes typing. A card left
/// with no tabs folds away. A file from the sidebar that didn't move far
/// enough opens as a click does.
fn dropTab(w: *Win, t: TabDrag) void {
    if (t.file) |path| {
        if (!t.live) return open(path, if (t.cmd) null else w.focus);
        if (t.drop) |dr| placeFile(w, path, dr);
        return;
    }
    const from = t.from.?;
    if (!t.live or from.closing) return;
    const dr = t.drop orelse return refresh(from);
    moveTab(from, tabIndex(from, t.id) orelse return, dr);
}

fn splitZone(z: Zone) bool {
    return switch (z) {
        .tabs, .whole => false,
        .left, .right, .top, .bottom => true,
    };
}

/// Moves card `from`'s tab `j` to where `dr` says, taking typing there.
/// A card left with no tabs folds away.
fn moveTab(from: *Doc, j: usize, dr: Drop) void {
    const last = tabCount(from) == 1;
    if (last and dr.card == from) return;
    const to = if (splitZone(dr.zone)) splitOff(dr.card, dr.zone == .top or dr.zone == .bottom, dr.zone == .left or dr.zone == .top, true) orelse return else dr.card;
    const pg = takeTab(from, j) orelse return;
    putTab(to, pg, dr.k);
    if (last) foldCard(from);
    focus(to);
}

/// Shows file `path` in window `w` where `dr` says: as a new tab, or in a
/// new card split off an edge. A file a card there already holds moves
/// there instead, and one open in another window comes forward in it.
fn placeFile(w: *Win, path: [:0]const u8, dr: Drop) void {
    for (docs.items) |o| {
        if (o.closing) continue;
        const j = if (o.path != null and std.mem.eql(u8, o.path.?, path)) o.at else if (pageIndex(o, path)) |i| (if (i < o.at) i else i + 1) else continue;
        if (o.win != w) return open(path, null);
        if (o == dr.card and !splitZone(dr.zone)) {
            showTab(o, j);
            return focus(o);
        }
        return moveTab(o, j, dr);
    }
    var pg = loadPage(path) orelse return;
    const to = if (splitZone(dr.zone)) splitOff(dr.card, dr.zone == .top or dr.zone == .bottom, dr.zone == .left or dr.zone == .top, true) orelse return pg.deinit() else dr.card;
    putTab(to, pg, dr.k);
    noteRecent(path);
    focus(to);
}

/// The drop preview, the dragged tab's copy under the mouse, and a copy
/// finishing its trip after the mouse let go.
fn drawDrag(w: *Win, ctx: Id, th: *const Theme, now: f64) void {
    var r: [4]f64 = undefined;
    // Picked up, the copy lifts to 1.04; once it lets go it settles to 1.
    const held = if (w.tdrag) |td| td.live and td.out else false;
    w.lift.aim(if (held) 1.04 else 1, now);
    const lift = w.lift.step(now);
    for (&w.pv, &r) |*s, *v| v.* = s.step(now);
    const pa = w.pv_a.at(now);
    if (pa > 0.01) {
        const rad: f64 = if (r[3] < 30) 7 else card_radius;
        pill(ctx, th.caret, 0.12 * pa, r[0], r[1], r[2], r[3], rad);
        ring(ctx, th.caret, 0.6 * pa, r[0], r[1], r[2], r[3], rad);
    }
    if (w.fly) |fl| {
        const p = flyDone(fl, now);
        if (p >= 1) return endFly(w);
        const e = 1 - (1 - p) * (1 - p) * (1 - p);
        // Back on its tab it just settles; into a gap or back to the
        // sidebar it fades as it arrives; on a card it fades where it is.
        const alpha = if (fl.fade) 1 - e else if (fl.card != null) 1 else std.math.clamp((1 - p) / 0.4, 0, 1);
        ghost(ctx, th, fl.icon, fl.line, fl.w, fl.from.x + (fl.to.x - fl.from.x) * e, fl.from.y + (fl.to.y - fl.from.y) * e, alpha, lift);
    }
    const t = w.tdrag orelse return;
    const ga = w.ghost_a.at(now);
    if (ga < 0.01) return;
    const g = ghostOf(&t) orelse return;
    const gw = ghostW(&t);
    ghost(ctx, th, g.icon, g.line, gw, t.at.x - std.math.clamp(t.grab, 10, gw - 10), t.at.y - 11, ga, lift);
}

/// A tab's copy lifted off the page, `gw` wide with its top left at `x`, `y`,
/// grown by `lift` about its middle.
fn ghost(ctx: Id, th: *const Theme, img: Id, line: Id, gw: f64, x: f64, y: f64, alpha: f64, lift: f64) void {
    const ts = tileSize();
    objc.CGContextSaveGState(ctx);
    objc.CGContextSetAlpha(ctx, alpha);
    objc.CGContextTranslateCTM(ctx, x + gw / 2, y + 11);
    objc.CGContextScaleCTM(ctx, lift, lift);
    objc.CGContextTranslateCTM(ctx, -(x + gw / 2), -(y + 11));
    // A real shadow under it, so it reads as lifted off the page.
    objc.CGContextSaveGState(ctx);
    const shade = objc.CGColorCreateGenericGray(0, 0.22);
    defer if (shade) |s| objc.CFRelease(s);
    objc.CGContextSetShadowWithColor(ctx, .{ .w = 0, .h = -4 }, 12, shade);
    pill(ctx, th.header, 1, x, y, gw, 22, 7);
    objc.CGContextRestoreGState(ctx);
    ring(ctx, th.fg, 0.3, x, y, gw, 22, 7);
    tile(img, x + tab_pad, @round(y + 11 - ts / 2));
    _ = drawLine(ctx, line, th.fg, x + tab_pad + ts + 7, @round(y + 11 + name_off));
    objc.CGContextRestoreGState(ctx);
}

/// Sets the dragged copy off on its last trip as drag `t` ends: into the
/// gap among the tabs it's dropped on, back to its tab or sidebar row when
/// it lands nowhere, or fading where it's dropped on a card.
fn startFly(w: *Win, t: TabDrag) void {
    endFly(w);
    if (!t.live or !t.out) return;
    const g = ghostOf(&t) orelse return;
    const line = g.line orelse return;
    const gw = ghostW(&t);
    const left = std.math.clamp(t.grab, 10, gw - 10);
    const at: Point = .{ .x = t.at.x - left, .y = t.at.y - 11 };
    var fl: Fly = .{ .line = objc.CFRetain(line), .icon = g.icon, .w = gw, .from = at, .to = at, .t0 = CACurrentMediaTime(), .row = t.row };
    if (t.drop) |dr| {
        if (dr.zone == .tabs) {
            const r = dropRect(dr, gw);
            fl.to = .{ .x = r.x, .y = r.y };
        } else if (splitZone(dr.zone)) {
            fl.to = titleSpot(dr);
        } else fl.fade = true;
    } else if (t.from) |d| {
        if (slotOf(d, t.id)) |i| {
            const s = d.slots.items[i];
            fl.to = .{ .x = d.org.x + s.x + s.shift.x, .y = d.org.y + gap + head_h / 2 - 11 };
            fl.card = d;
            fl.id = t.id;
        } else fl.fade = true;
    } else fl.to = .{ .x = t.down.x - left, .y = t.down.y - 11 };
    w.fly = fl;
}

fn endFly(w: *Win) void {
    const fl = w.fly orelse return;
    w.fly = null;
    if (fl.line) |l| objc.CFRelease(l);
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// How far along its trip `fl` is, 0 to 1.
fn flyDone(fl: Fly, now: f64) f64 {
    const dur: f64 = if (fl.fade) fade_time * 1.5 else fly_time;
    return std.math.clamp((now - fl.t0) / dur, 0, 1);
}

/// How far sidebar row `i` is dimmed, 0 to 1: while its file is dragged
/// out, and until the copy is gone after.
fn rowLift(w: *const Win, i: usize, now: f64) f64 {
    if (w.tdrag) |t| if (t.row == i and t.live) return w.ghost_a.at(now);
    if (w.fly) |fl| if (fl.row == i) return 1 - flyDone(fl, now);
    return 0;
}

/// Zen fades the traffic lights out as `a` falls to 0, and hides them
/// once they're gone; the window still closes, zooms and drags.
fn setLights(w: *Win, a: f64) void {
    for (0..3) |i| {
        const b = msg(Id, w.window, "standardWindowButton:", .{i});
        msg(void, b, "setAlphaValue:", .{a});
        msg(void, b, "setHidden:", .{a < 0.01});
    }
}

/// Reads where AppKit put the traffic lights, which it centers in the
/// window's empty toolbar, so the header's middle sits on their line and
/// its tabs start past them; and the window's corner radius, so the cards'
/// corners nest inside it a gap in. Full screen keeps the last values.
fn fitTitlebar(w: *Win) void {
    if (msg(usize, w.window, "styleMask", .{}) & (1 << 14) != 0) return;
    const last = msg(Id, w.window, "standardWindowButton:", .{@as(usize, 2)});
    if (last == null) return;
    const at = msg(Rect, last, "convertRect:toView:", .{ msg(Rect, last, "bounds", .{}), w.view });
    head_h = std.math.clamp(@round(2 * (at.y + at.h / 2 - gap)), 28, 44);
    top_h = gap + head_h + 6;
    toggle_x = at.x + at.w + 27;
    tabs_from = at.x + at.w + 22;
    // AppKit's own radius for this window, private, so asked for with care;
    // macOS 26's radius for a window with a toolbar otherwise.
    const frame = msg(Id, w.view, "superview", .{});
    const ask = objc.sel_registerName("_getCachedWindowCornerRadius");
    const asked: f64 = if (frame != null and msg(bool, frame, "respondsToSelector:", .{ask})) msg(f64, frame, "_getCachedWindowCornerRadius", .{}) else 0;
    card_radius = std.math.clamp((if (asked >= 1) asked else 26) - gap, 6, 24);
}

/// In full screen the empty toolbar hides with the menu bar, so the cards
/// keep the top of the screen.
fn fullScreenOptions(_: Id, _: Sel, _: Id, proposed: usize) callconv(.c) usize {
    return proposed | (1 << 11);
}

// ---- NSView methods ----

fn drawRect(self: Id, _: Sel, dirty: Rect) callconv(.c) void {
    const w = winOf(self) orelse return;
    const gc = msg(Id, objc.class("NSGraphicsContext"), "currentContext", .{});
    draw(w, msg(Id, gc, "CGContext", .{}), dirty);
}

fn yes(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

fn no(_: Id, _: Sel) callconv(.c) bool {
    return false;
}

fn keyDown(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    d.note = "";
    d.flash_n = 0;
    const flags = msg(usize, ev, "modifierFlags", .{});
    const code = msg(u16, ev, "keyCode", .{});
    // ⌥Z for Soft Wrap: menus only see option keys after the text has typed them.
    if (flags & (cmd_key | opt_key | ctrl_key) == opt_key and code == 6) return toggleWrap();
    // Command keys that the menu didn't take: only arrows and delete mean something.
    if (flags & cmd_key != 0) {
        if (std.mem.indexOfScalar(u16, &.{ 51, 117, 115, 119, 123, 124, 125, 126 }, code) == null) return;
    }
    // Like NSTextView: the pointer hides while typing and returns when the mouse moves.
    if (code < 123 or code > 126) msg(void, objc.class("NSCursor"), "setHiddenUntilMouseMoves:", .{true});
    const arr = msg(Id, objc.class("NSArray"), "arrayWithObject:", .{ev});
    msg(void, self, "interpretKeyEvents:", .{arr});
}

fn insertText(self: Id, _: Sel, s: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    const ns = if (msg(bool, s, "isKindOfClass:", .{objc.class("NSAttributedString")})) msg(Id, s, "string", .{}) else s;
    const bytes = objc.utf8(ns);
    if (d.mode != .edit) {
        promptType(d, bytes);
    } else {
        (if (conf.pairs) d.ed.typePaired(gpa, bytes) else d.ed.insert(gpa, bytes)) catch {};
        reveal(d);
    }
    refresh(d);
}

const moves = [_]struct { []const u8, editor.Motion }{
    .{ "moveLeft", .left },                     .{ "moveBackward", .left },            .{ "moveRight", .right },
    .{ "moveForward", .right },                 .{ "moveUp", .up },                    .{ "moveDown", .down },
    .{ "moveWordLeft", .word_left },            .{ "moveWordBackward", .word_left },   .{ "moveWordRight", .word_right },
    .{ "moveWordForward", .word_right },        .{ "moveToBeginningOfLine", .home },   .{ "moveToLeftEndOfLine", .home },
    .{ "moveToEndOfLine", .end },               .{ "moveToRightEndOfLine", .end },     .{ "moveToBeginningOfParagraph", .line_start },
    .{ "moveParagraphBackward", .line_start },  .{ "moveToEndOfParagraph", .end },     .{ "moveParagraphForward", .end },
    .{ "moveToBeginningOfDocument", .top },     .{ "moveToEndOfDocument", .bottom },   .{ "pageUp", .page_up },
    .{ "pageDown", .page_down },
};

fn doCommand(self: Id, _: Sel, sel: Sel) callconv(.c) void {
    const d = docOf(self) orelse return;
    var name: []const u8 = std.mem.span(objc.sel_getName(sel));
    if (name.len > 0 and name[name.len - 1] == ':') name.len -= 1;
    if (d.mode != .edit) {
        promptCommand(d, name);
        return refresh(d);
    }
    var extend = false;
    if (std.mem.indexOf(u8, name, "AndModifySelection")) |i| {
        extend = true;
        name = name[0..i];
    }
    if (edit(d, name, extend) catch true) reveal(d);
    refresh(d);
}

/// Runs a key command. Returns whether the caret should be scrolled to.
fn edit(d: *Doc, name: []const u8, extend: bool) !bool {
    const e = &d.ed;
    for (moves) |m| if (std.mem.eql(u8, m[0], name)) {
        if (wrapping()) switch (m[1]) {
            .up, .down => {
                vmove(d, if (m[1] == .up) -1 else 1, extend);
                return true;
            },
            .page_up, .page_down => {
                const n: isize = @intCast(pageLines(d));
                vmove(d, if (m[1] == .page_up) -n else n, extend);
                return true;
            },
            .home, .end => if (!is(name, "moveToEndOfParagraph") and !is(name, "moveParagraphForward") and rowEdge(d, m[1] == .end, extend)) return true,
            else => {},
        };
        e.move(m[1], extend, pageLines(d));
        return true;
    };
    if (is(name, "deleteBackward") or is(name, "deleteBackwardByDecomposingPreviousCharacter")) {
        if (!(conf.pairs and try e.deletePair(gpa))) try e.deleteBack(gpa, .char);
    } else if (is(name, "deleteWordBackward")) {
        try e.deleteBack(gpa, .word);
    } else if (is(name, "deleteToBeginningOfLine") or is(name, "deleteToBeginningOfParagraph")) {
        try e.deleteBack(gpa, .line);
    } else if (is(name, "deleteForward")) {
        try e.deleteForward(gpa, .char);
    } else if (is(name, "deleteWordForward")) {
        try e.deleteForward(gpa, .word);
    } else if (is(name, "deleteToEndOfLine") or is(name, "deleteToEndOfParagraph")) {
        try e.deleteForward(gpa, .line);
    } else if (is(name, "insertNewline") or is(name, "insertLineBreak") or is(name, "insertNewlineIgnoringFieldEditor")) {
        try e.newline(gpa);
    } else if (is(name, "insertTab")) {
        try e.tab(gpa);
    } else if (is(name, "insertBacktab")) {
        try e.outdent(gpa);
    } else if (is(name, "cancelOperation")) {
        e.select(e.cur, e.cur);
    } else if (is(name, "scrollPageUp") or is(name, "scrollPageDown")) {
        d.sy += if (is(name, "scrollPageUp")) -textH(d) + lh else textH(d) - lh;
        clampScroll(d);
        return false;
    } else if (is(name, "scrollToBeginningOfDocument") or is(name, "scrollToEndOfDocument")) {
        d.sy = if (is(name, "scrollToBeginningOfDocument")) 0 else std.math.inf(f64);
        clampScroll(d);
        return false;
    } else if (is(name, "centerSelectionInVisibleArea")) {
        d.sy = std.math.inf(f64);
        center(d);
        return false;
    } else return false;
    return true;
}

fn posAt(d: *Doc, p: Point) usize {
    layout(d);
    const b = &d.ed.buf;
    const yy = p.y - top_h + d.vy;
    const row: usize = if (yy < 0) 0 else @min(@as(usize, @intFromFloat(yy / lh)), totalRows(d) - 1);
    const i = lineOfRow(d, row);
    const l = b.line(i);
    const s = segN(d, l, row - rowOfLine(d, i));
    const x = @max((p.x - gap - padL(d) + d.vx) / cw, 0);
    return b.lineStart(i) + std.math.clamp(editor.byteAtCol(l, f(s.col) + x), s.start, caretEnd(l, s));
}

fn local(self: Id, ev: Id) Point {
    return msg(Point, self, "convertPoint:fromView:", .{ msg(Point, ev, "locationInWindow", .{}), @as(Id, null) });
}

/// The word or line around `pos`, for double- and triple-click drags.
fn unitAt(d: *Doc, pos: usize) [2]usize {
    const e = &d.ed;
    const keep = .{ e.anchor, e.cur };
    if (d.drag == .word) e.selectWord(pos) else e.selectLine(pos);
    const r = e.sel();
    e.anchor = keep[0];
    e.cur = keep[1];
    return r;
}

/// The header and the band over the sidebar stand in for the hidden title
/// bar: they drag the window, and a double-click does what the Mac's
/// Desktop & Dock setting says, like any title bar.
fn titleStrip(w: *Win, ev: Id) void {
    w.side_down = true;
    if (msg(isize, ev, "clickCount", .{}) == 2) {
        const act = objc.utf8(msg(Id, defaults(), "stringForKey:", .{objc.str("AppleActionOnDoubleClick")}));
        if (is(act, "Minimize")) return msg(void, w.window, "performMiniaturize:", .{@as(Id, null)});
        if (!is(act, "None")) msg(void, w.window, "performZoom:", .{@as(Id, null)});
        return;
    }
    msg(void, w.window, "performWindowDragWithEvent:", .{ev});
}

/// The buttons by the traffic lights, the sidebar and its edge, the gaps
/// between cards, then the card under the mouse, which takes typing from
/// then on.
fn mouseDown(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    const p = local(self, ev);
    w.side_down = true;
    w.grab = null;
    endDrag(w);
    endFly(w);
    if (toolAt(w, p)) |t| {
        w.press = if (t == .sidebar) 1 else 2;
        w.press_t.snap(1);
        if (t == .sidebar) toggleSidebar() else newTab(w.focus);
        return;
    }
    const side = sideShown(w);
    if (side and p.y >= top_h and @abs(p.x - side_w) <= edge_grab) {
        w.side_drag = true;
        w.side_lim = 0;
        if (side_stretch.x == 0) side_rest = side_w;
        side_stretch.snap(0);
        side_w = side_rest;
        return;
    }
    if (side and p.x < side_w) {
        if (p.y < top_h) return titleStrip(w, ev);
        if (p.y < listTop()) return parentsMenu(w);
        return sideClick(w, p, msg(usize, ev, "modifierFlags", .{}));
    }
    if (gapAt(w.cards, p)) |n| {
        w.grab = n;
        w.grab_hit = 0;
        w.grab_ease = 0;
        return;
    }
    const d = paneAt(w, p) orelse return titleStrip(w, ev);
    focus(d);
    cardDown(d, inPane(d, p), ev);
}

/// A click in card `d`, at `p` in its pane: its tabs and +, the quick open
/// list, or the text.
fn cardDown(d: *Doc, p: Point, ev: Id) void {
    const by = bottom(d);
    d.note = "";
    if (p.y < top_h) {
        if (onTabPlus(d, p)) {
            d.plus_down.snap(1);
            return newTab(d);
        }
        const hit = tabAt(d, p) orelse loneTab(d, p) orelse return titleStrip(d.win, ev);
        if (hit.close) return closeTab(d, hit.j);
        showTab(d, hit.j);
        // Held, the tab can be dragged along its row or to another card.
        const s = d.slots.items[slotOf(d, hit.id) orelse return];
        const at: Point = .{ .x = p.x + d.org.x, .y = p.y + d.org.y };
        d.win.tdrag = .{ .from = d, .id = hit.id, .down = at, .at = at, .grab = p.x - (s.x + s.shift.x) };
        return;
    }
    d.win.side_down = false;
    if (listing(d) != null) {
        const top = by - f(panelRows(d)) * prow - ppad;
        if (p.y >= top and p.y < by) {
            d.pick = @min(@as(usize, @intFromFloat((p.y - top) / prow)), d.npicks -| 1);
            accept(d);
            return refresh(d);
        }
    }
    if (p.y >= by) {
        d.win.side_down = true;
        return;
    }
    d.mode = .edit;
    const pos = posAt(d, p);
    switch (msg(isize, ev, "clickCount", .{})) {
        2 => d.drag = .word,
        3 => d.drag = .line,
        else => {
            d.drag = .char;
            d.ed.moveTo(pos, msg(usize, ev, "modifierFlags", .{}) & shift_key != 0);
        },
    }
    if (d.drag != .char) {
        d.drag_from = unitAt(d, pos);
        d.ed.select(d.drag_from[0], d.drag_from[1]);
    }
    refresh(d);
}

/// Moves the sidebar's edge to `x` in every window, within its limits and
/// leaving room for the text. Past a limit it stretches against the
/// mouse, and dragged right in, the sidebar shuts.
fn resizeSide(w: *Win, x: f64) void {
    if (x < side_collapse) {
        const was = side_w;
        w.side_drag = false;
        w.side_lim = 0;
        side_stretch.snap(0);
        toggleSidebar();
        // It slides away at the width it had.
        side_w = was;
        for (wins.items) |o| msg(void, o.window, "invalidateCursorRectsForView:", .{o.view});
        return;
    }
    const room = msg(Rect, w.view, "bounds", .{}).w - 360;
    const lo = settings.sidebar_min;
    const hi = @max(lo, @min(settings.sidebar_max, room));
    const to = @round(std.math.clamp(x, lo, hi));
    const over: f64 = if (x < lo)
        -@min(side_stretch_max, (lo - x) * side_stretch_pull)
    else if (x > hi)
        @min(@max(0, @min(side_stretch_max, room - hi)), (x - hi) * side_stretch_pull)
    else
        0;
    const lim: i8 = if (x <= lo) -1 else if (x >= hi) 1 else 0;
    if (lim != w.side_lim) {
        w.side_lim = lim;
        if (lim != 0) haptic(.alignment);
    }
    // At a limit the edge can only go one way.
    const NSCursor = objc.class("NSCursor");
    const cursor = if (lim < 0) msg(Id, NSCursor, "resizeRightCursor", .{}) else if (lim > 0) msg(Id, NSCursor, "resizeLeftCursor", .{}) else msg(Id, NSCursor, "resizeLeftRightCursor", .{});
    msg(void, cursor, "set", .{});
    side_rest = to;
    side_stretch.snap(over);
    const now_w = @round(to + over);
    if (now_w == side_w) return;
    side_w = now_w;
    dropSideLines();
    refreshAll();
}

/// Lights the button, tab or tab's close button under the mouse, in
/// whichever card it's over.
fn mouseMoved(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    const p = local(self, ev);
    const tool = toolAt(w, p);
    const hot: u8 = if (tool) |t| (if (t == .sidebar) 1 else 2) else 0;
    if (hot != w.hot) {
        redrawHot(w, w.hot | hot);
        w.hot = hot;
    }
    const over = if (tool == null) paneAt(w, p) else null;
    for (docs.items) |d| if (d.win == w) {
        const lp = inPane(d, p);
        const hit = if (d == over and lp.y < top_h) tabAt(d, lp) else null;
        setHover(d, if (hit) |h| h.id else 0, if (hit) |h| h.close else false, d == over and onTabPlus(d, lp));
    };
    sideHover(w, p);
}

/// Points the sidebar's hover highlight at the row under `p`: a row of the
/// list, not a pinned folder, the header or the sidebar's edge, and none
/// while something's dragged.
fn sideHover(w: *Win, p: Point) void {
    var row: ?usize = null;
    if (sideShown(w) and p.x < side_w - edge_grab and p.y >= listTop() and w.tdrag == null) {
        const pinned = for (w.stuck_y[0..w.nstuck]) |y| {
            if (p.y >= y and p.y < y + side_h) break true;
        } else false;
        if (!pinned) row = sideRow(w, p.y);
    }
    if (row == w.hov_row and w.hov_gen == tree_gen) return;
    w.hov_row = row;
    w.hov_gen = tree_gen;
    redrawSide(w);
}

fn setHover(d: *Doc, id: u32, shut: bool, plus: bool) void {
    if (id == d.hover and shut == d.hover_x and plus == d.plus_on) return;
    d.hover = id;
    d.hover_x = shut;
    d.plus_on = plus;
    msg(void, d.view, "setNeedsDisplay:", .{true});
}

fn mouseExited(self: Id, _: Sel, _: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    if (w.hot != 0) {
        redrawHot(w, w.hot);
        w.hot = 0;
    }
    for (docs.items) |d| if (d.win == w) setHover(d, 0, false, false);
    if (w.hov_row != null) {
        w.hov_row = null;
        redrawSide(w);
    }
}

/// The mouse lets go of a button it pressed: the button's fill fades.
fn letGo(w: *Win) void {
    const now = CACurrentMediaTime();
    var held = w.press_t.to != 0;
    w.press_t.aim(0, now);
    for (docs.items) |d| if (d.win == w and d.plus_down.to != 0) {
        held = true;
        d.plus_down.aim(0, now);
    };
    if (held) msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// Ends a drag of the sidebar's edge by saving the width, so new windows
/// and the next launch use it, or of a gap between cards.
fn mouseUp(self: Id, _: Sel, _: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    letGo(w);
    if (w.tdrag) |t| {
        w.tdrag = null;
        startFly(w, t);
        dropTab(w, t);
        freeDrag(t);
        aimPreview(w, CACurrentMediaTime());
        return msg(void, w.view, "setNeedsDisplay:", .{true});
    }
    if (w.grab) |n| {
        releaseGap(n, CACurrentMediaTime());
        w.grab = null;
        msg(void, w.view, "setNeedsDisplay:", .{true});
        return msg(void, w.window, "invalidateCursorRectsForView:", .{w.view});
    }
    if (!w.side_drag) return;
    w.side_drag = false;
    w.side_lim = 0;
    for (wins.items) |o| msg(void, o.window, "invalidateCursorRectsForView:", .{o.view});
    if (side_rest != conf.sidebar_width) {
        var buf: [24]u8 = undefined;
        store("sidebar-width", settings.decimal(&buf, side_rest));
    }
    // Let go past a limit and the edge springs back.
    if (side_stretch.x != 0) {
        side_stretch.aim(0, CACurrentMediaTime());
        refreshAll();
    }
}

fn mouseDragged(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    if (w.side_drag) return resizeSide(w, local(self, ev).x);
    if (w.tdrag != null) return dragTab(w, local(self, ev));
    if (w.grab) |n| return dragGap(w, n, local(self, ev));
    if (w.side_down) return;
    const d = w.focus;
    d.snap = true;
    const p = inPane(d, local(self, ev));
    if (p.y < top_h) d.sy -= lh;
    if (p.y > bottom(d)) d.sy += lh;
    clampScroll(d);
    d.ys.snap(d.sy);
    const pos = posAt(d, p);
    if (d.drag == .char) {
        d.ed.moveTo(pos, true);
    } else {
        const u = unitAt(d, pos);
        if (u[0] < d.drag_from[0]) d.ed.select(d.drag_from[1], u[0]) else d.ed.select(d.drag_from[0], @max(u[1], d.drag_from[1]));
    }
    refresh(d);
}

/// Scrolls the sidebar or the card under the mouse, focused or not.
fn scrollWheel(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    const at = local(self, ev);
    if (sideShown(w) and at.x < side_w) {
        const dy = msg(f64, ev, "scrollingDeltaY", .{});
        w.side_y -= if (msg(bool, ev, "hasPreciseScrollingDeltas", .{})) dy else dy * lh;
        sideHover(w, at);
        return redrawSide(w);
    }
    const d = paneAt(w, at) orelse return;
    var dx = msg(f64, ev, "scrollingDeltaX", .{});
    var dy = msg(f64, ev, "scrollingDeltaY", .{});
    const now = CACurrentMediaTime();
    if (msg(bool, ev, "hasPreciseScrollingDeltas", .{})) {
        // The trackpad stretches past the ends while the fingers or momentum
        // push, and springs back once the fingers are off the pad.
        const touching: usize = 1 | 2 | 4 | 32; // began, stationary, changed, may begin
        d.relax = msg(usize, ev, "phase", .{}) & touching == 0;
        if (!d.relax) d.ov_v = .{ 0, 0 };
        d.ov_t = now;
        if (!wrapping()) pull(&d.sx, &d.ov[0], -dx, 0, std.math.inf(f64), @max(rightEdge(d) - gap, cw));
        const range = scrollRange(d);
        pull(&d.sy, &d.ov[1], -dy, range[0], range[1], band_lines * lh);
    } else {
        dx *= lh;
        dy *= lh;
        d.relax = true;
        d.sx -= dx;
        d.sy -= dy;
    }
    clampScroll(d);
    d.ys.snap(d.sy);
    d.xs.snap(d.sx);
    refresh(d);
}

/// An I-beam over each card's text, resize arrows on the sidebar's edge
/// and the gaps between cards; the headers keep the arrow.
fn resetCursorRects(self: Id, _: Sel) callconv(.c) void {
    const w = winOf(self) orelse return;
    const r = msg(Rect, self, "bounds", .{});
    for (docs.items) |d| if (d.win == w and !d.closing) {
        msg(void, self, "addCursorRect:cursor:", .{ Rect{ .x = d.org.x + gap, .y = d.org.y + top_h, .w = @max(d.size.x - 2 * gap, 0), .h = @max(d.size.y - gap - top_h, 0) }, msg(Id, objc.class("NSCursor"), "IBeamCursor", .{}) });
    };
    gapCursors(self, w.cards);
    if (sideShown(w)) {
        msg(void, self, "addCursorRect:cursor:", .{ Rect{ .x = side_w - edge_grab, .y = top_h, .w = 2 * edge_grab, .h = r.h - top_h }, msg(Id, objc.class("NSCursor"), "resizeLeftRightCursor", .{}) });
    }
}

/// Also the window delegate's key and resign key calls, so the caret shows
/// only in the key window.
fn appearanceChanged(self: Id, _: Sel) callconv(.c) void {
    msg(void, self, "setNeedsDisplay:", .{true});
}

/// The system's light or dark look changed: crossfade to the new colors.
/// A window that isn't on screen yet has nothing to fade from.
fn lookChanged(self: Id, _: Sel) callconv(.c) void {
    if (winOf(self)) |w| if (msg(bool, w.window, "isVisible", .{})) fadeTheme(w);
    msg(void, self, "setNeedsDisplay:", .{true});
}

extern const NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification: Id;

/// The Mac's Increase Contrast setting changed: read it again and redraw.
fn contrastChanged(_: Id, _: Sel, _: Id) callconv(.c) void {
    contrast = msg(bool, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "accessibilityDisplayShouldIncreaseContrast", .{});
    buildThemes();
    for (wins.items) |w| msg(void, w.view, "setNeedsDisplay:", .{true});
    for (docs.items) |d| preview.update(d, &themes);
}

extern const NSPasteboardTypeFileURL: Id;
extern const NSPasteboardURLReadingFileURLsOnlyKey: Id;

/// Files dragged over the window from Finder copy-drop, which opens them.
fn draggingEntered(_: Id, _: Sel, _: Id) callconv(.c) usize {
    return 1;
}

/// Opens each dropped file or folder the way the Dock does: in this window
/// when it's blank, else in a new one.
fn performDrag(_: Id, _: Sel, sender: Id) callconv(.c) bool {
    const pb = msg(Id, sender, "draggingPasteboard", .{});
    const classes = msg(Id, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    const opts = msg(Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ msg(Id, objc.class("NSNumber"), "numberWithBool:", .{true}), NSPasteboardURLReadingFileURLsOnlyKey });
    const urls = msg(Id, pb, "readObjectsForClasses:options:", .{ classes, opts });
    const n = if (urls != null) msg(usize, urls, "count", .{}) else 0;
    for (0..n) |i| open(objc.utf8(msg(Id, msg(Id, urls, "objectAtIndex:", .{i}), "path", .{})), blankDoc());
    return n > 0;
}

// ---- context menus ----

/// Built on the first right-click and kept. Their items have no target, so
/// they reach the key window's view through the responder chain.
var text_menu: Id = null;
var side_menu: Id = null;
var side_items: [3]Id = @splat(null);
var tab_menu: Id = null;
var tab_items: [6]Id = @splat(null);
/// The file of the sidebar row or tab the menu was opened on, its window,
/// and for a tab, its card and id.
var menu_path: [std.fs.max_path_bytes:0]u8 = undefined;
var menu_len: usize = 0;
var menu_win: ?*Win = null;
var menu_doc: ?*Doc = null;
var menu_id: u32 = 0;

fn menuItem(menu: Id, title: []const u8, sel: [:0]const u8, key: []const u8) Id {
    const it = msg(Id, msg(Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{ objc.str(title), objc.sel_registerName(sel), objc.str(key) });
    if (key.len > 0) msg(void, it, "setKeyEquivalentModifierMask:", .{cmd_key});
    msg(void, menu, "addItem:", .{it});
    msg(void, it, "release", .{});
    return it;
}

fn newMenu() Id {
    return objc.new("NSMenu");
}

fn separator(m: Id) void {
    msg(void, m, "addItem:", .{msg(Id, objc.class("NSMenuItem"), "separatorItem", .{})});
}

/// A click on the folder's name: a menu of the folder and the folders above
/// it, each with its icon. Picking one shows it in Finder.
fn parentsMenu(w: *Win) void {
    const m = newMenu();
    defer msg(void, m, "release", .{});
    const ws = msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const fm = msg(Id, objc.class("NSFileManager"), "defaultManager", .{});
    var path: []const u8 = root.?;
    var n: isize = 0;
    while (true) : (n += 1) {
        const at = objc.str(path);
        const it = menuItem(m, objc.utf8(msg(Id, fm, "displayNameAtPath:", .{at})), "sideParent:", "");
        msg(void, it, "setTag:", .{n});
        const img = msg(Id, msg(Id, ws, "iconForFile:", .{at}), "copy", .{});
        msg(void, img, "setSize:", .{Point{ .x = 16, .y = 16 }});
        msg(void, it, "setImage:", .{img});
        msg(void, img, "release", .{});
        if (path.len <= 1) break;
        path = std.fs.path.dirname(path) orelse break;
    }
    _ = msg(bool, m, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(Id, null), Point{ .x = 16, .y = listTop() }, w.view });
}

/// A folder picked in the folder name's menu, by how many levels above the
/// open folder it is (its tag).
fn sideParent(_: Id, _: Sel, item: Id) callconv(.c) void {
    var path: []const u8 = root orelse return;
    for (0..@as(usize, @intCast(msg(isize, item, "tag", .{})))) |_| path = std.fs.path.dirname(path) orelse break;
    if (!setMenuPath(path)) return;
    revealInFinder(null, null, null);
}

fn setMenuPath(p: []const u8) bool {
    if (p.len >= menu_path.len) return false;
    @memcpy(menu_path[0..p.len], p);
    menu_path[p.len] = 0;
    menu_len = p.len;
    return true;
}

fn menuFile() [:0]const u8 {
    return menu_path[0..menu_len :0];
}

/// Outlines the row or tab the menu is open on while it's open. `self`
/// hears when it closes, and the outline fades out.
fn markMenu(self: Id, w: *Win, m: Id, same: bool) Id {
    menu_win = w;
    // Another row or tab starts from nothing rather than taking over a fade.
    if (!same) w.menu_a.snap(0);
    w.menu_a.aim(1, CACurrentMediaTime());
    msg(void, m, "setDelegate:", .{self});
    msg(void, self, "setNeedsDisplay:", .{true});
    return m;
}

fn menuDidClose(_: Id, _: Sel, m: Id) callconv(.c) void {
    msg(void, m, "setDelegate:", .{@as(Id, null)});
    const w = menu_win orelse return;
    w.menu_a.aim(0, CACurrentMediaTime());
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// The right-click outline: a hairline ring in the accent over a faint
/// accent wash, `a` faded in.
fn menuMark(ctx: Id, th: *const Theme, a: f64, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    pill(ctx, th.caret, 0.07 * a, x, y, w, h, r);
    ring(ctx, th.caret, 0.45 * a, x, y, w, h, r);
}

/// Right-click and control-click: Edit's commands over a card's text, which
/// takes typing from then on, the tab's commands over a tab, the file's
/// commands over a sidebar row, and nothing elsewhere. A tab or row keeps
/// an outline while its menu is open.
fn menuForEvent(self: Id, _: Sel, ev: Id) callconv(.c) Id {
    const w = winOf(self) orelse return null;
    const p = local(self, ev);
    if (!sideShown(w) or p.x >= side_w) {
        const d = paneAt(w, p) orelse return null;
        const lp = inPane(d, p);
        if (lp.y < top_h) return tabMenu(self, w, d, lp);
        if (lp.y >= bottom(d)) return null;
        focus(d);
        if (text_menu == null) {
            const m = newMenu();
            _ = menuItem(m, "Cut", "cut:", "x");
            _ = menuItem(m, "Copy", "copy:", "c");
            _ = menuItem(m, "Paste", "paste:", "v");
            _ = menuItem(m, "Select All", "selectAll:", "a");
            separator(m);
            _ = menuItem(m, "Toggle Comment", "toggleComment:", "/");
            text_menu = m;
        }
        return text_menu;
    }
    if (p.y < top_h) return null;
    const i = sideRow(w, p.y) orelse return null;
    const row = tree.rows.items[i];
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (!setMenuPath(std.fmt.bufPrint(&buf, "{s}/{s}", .{ root.?, row.rel }) catch return null)) return null;
    if (side_menu == null) {
        const m = newMenu();
        msg(void, m, "setAutoenablesItems:", .{false});
        side_items = .{
            menuItem(m, "Open in New Tab", "openInNewTab:", ""),
            menuItem(m, "Open in New Split", "openInNewSplit:", ""),
            menuItem(m, "Open in New Window", "openInNewWindow:", ""),
        };
        separator(m);
        _ = menuItem(m, "Reveal in Finder", "revealInFinder:", "");
        _ = menuItem(m, "Copy Path", "copyPath:", "");
        side_menu = m;
    }
    for (side_items) |it| msg(void, it, "setEnabled:", .{!row.dir});
    const same = w.menu_card == null and w.menu_row == i and w.menu_gen == tree_gen;
    w.menu_card = null;
    w.menu_row = i;
    w.menu_gen = tree_gen;
    return markMenu(self, w, side_menu, same);
}

/// The menu for card `d`'s tab (or lone file name) under `lp`, in its pane.
fn tabMenu(self: Id, w: *Win, d: *Doc, lp: Point) Id {
    const hit = tabAt(d, lp) orelse titleTab(d, lp) orelse return null;
    const n = tabCount(d);
    const path = tabPath(d, hit.j);
    const has_path = if (path) |x| setMenuPath(x) else false;
    if (tab_menu == null) {
        const m = newMenu();
        msg(void, m, "setAutoenablesItems:", .{false});
        _ = menuItem(m, "Close Tab", "tabClose:", "");
        tab_items[0] = menuItem(m, "Close Other Tabs", "tabCloseOthers:", "");
        tab_items[1] = menuItem(m, "Close Tabs to the Right", "tabCloseRight:", "");
        separator(m);
        tab_items[2] = menuItem(m, "Split Right", "tabSplitRight:", "");
        tab_items[3] = menuItem(m, "Split Down", "tabSplitDown:", "");
        separator(m);
        tab_items[4] = menuItem(m, "Reveal in Finder", "revealInFinder:", "");
        tab_items[5] = menuItem(m, "Copy Path", "copyPath:", "");
        tab_menu = m;
    }
    const on = [6]bool{ n > 1, hit.j + 1 < n, n > 1 and roomFor(d, false), n > 1 and roomFor(d, true), has_path, has_path };
    for (tab_items, on) |it, x| msg(void, it, "setEnabled:", .{x});
    menu_doc = d;
    menu_id = hit.id;
    const same = w.menu_card == d and w.menu_tab == hit.id;
    w.menu_row = null;
    w.menu_card = d;
    w.menu_tab = hit.id;
    return markMenu(self, w, tab_menu, same);
}

/// The card and tab index the tab menu was opened on, while both are there.
fn menuTab() ?struct { d: *Doc, j: usize } {
    const d = menu_doc orelse return null;
    if (std.mem.indexOfScalar(*Doc, docs.items, d) == null or d.closing) return null;
    return .{ .d = d, .j = tabIndex(d, menu_id) orelse return null };
}

fn tabClose(_: Id, _: Sel, _: Id) callconv(.c) void {
    const t = menuTab() orelse return;
    closeTab(t.d, t.j);
}

fn tabCloseOthers(_: Id, _: Sel, _: Id) callconv(.c) void {
    const t = menuTab() orelse return;
    closeAround(t.d, menu_id, true);
}

fn tabCloseRight(_: Id, _: Sel, _: Id) callconv(.c) void {
    const t = menuTab() orelse return;
    closeAround(t.d, menu_id, false);
}

fn tabSplitRight(_: Id, _: Sel, _: Id) callconv(.c) void {
    const t = menuTab() orelse return;
    moveTab(t.d, t.j, .{ .card = t.d, .zone = .right });
}

fn tabSplitDown(_: Id, _: Sel, _: Id) callconv(.c) void {
    const t = menuTab() orelse return;
    moveTab(t.d, t.j, .{ .card = t.d, .zone = .bottom });
}

/// Closes card `d`'s tabs right of tab `id`, and with `left` the ones left
/// of it too, then shows it. Each one with something to lose asks first,
/// and Cancel stops there.
fn closeAround(d: *Doc, id: u32, left: bool) void {
    while (tabIndex(d, id)) |j| {
        if (j + 1 >= tabCount(d)) break;
        const n = tabCount(d);
        closeTab(d, j + 1);
        if (tabCount(d) == n) return;
    }
    while (left) {
        const j = tabIndex(d, id) orelse return;
        if (j == 0) break;
        const n = tabCount(d);
        closeTab(d, 0);
        if (tabCount(d) == n) return;
    }
    showTab(d, tabIndex(d, id) orelse return);
}

fn openInNewTab(_: Id, _: Sel, _: Id) callconv(.c) void {
    const w = menu_win orelse return;
    placeFile(w, menuFile(), .{ .card = w.focus, .zone = .tabs, .k = w.focus.at + 1 });
}

/// Splits the focused card right, or down when it's too narrow, or opens a
/// tab when it's too small for either.
fn openInNewSplit(_: Id, _: Sel, _: Id) callconv(.c) void {
    const w = menu_win orelse return;
    const c = w.focus;
    const zone: Zone = if (roomFor(c, false)) .right else if (roomFor(c, true)) .bottom else .tabs;
    placeFile(w, menuFile(), .{ .card = c, .zone = zone, .k = c.at + 1 });
}

fn openInNewWindow(_: Id, _: Sel, _: Id) callconv(.c) void {
    open(menuFile(), null);
}

fn revealInFinder(_: Id, _: Sel, _: Id) callconv(.c) void {
    const url = msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(menu_path[0..menu_len])});
    const urls = msg(Id, objc.class("NSArray"), "arrayWithObject:", .{url});
    msg(void, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "activateFileViewerSelectingURLs:", .{urls});
}

fn copyPath(_: Id, _: Sel, _: Id) callconv(.c) void {
    const pb = pasteboard();
    _ = msg(isize, pb, "clearContents", .{});
    _ = msg(bool, pb, "setString:forType:", .{ objc.str(menu_path[0..menu_len]), NSPasteboardTypeString });
}

/// Each card with unsaved changes asks first.
fn windowShouldClose(self: Id, _: Sel, _: Id) callconv(.c) bool {
    const w = winOf(self) orelse return true;
    for (docs.items) |d| if (d.win == w and !d.closing and !settle(d, false)) return false;
    return true;
}

fn windowWillClose(self: Id, _: Sel, _: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    preview.close(w.window);
    endDrag(w);
    endFly(w);
    if (menu_win == w) menu_win = null;
    msg(void, w.link, "invalidate", .{});
    access.dropWin(w);
    setWin(self, null);
    msg(void, w.window, "setDelegate:", .{@as(Id, null)});
    var i = docs.items.len;
    while (i > 0) {
        i -= 1;
        if (docs.items[i].win == w) closePane(docs.items[i]);
    }
    freeNodes(w.cards);
    if (w.bold) |l| objc.CFRelease(l);
    if (w.bold_old) |l| objc.CFRelease(l);
    for (wins.items, 0..) |x, j| if (x == w) {
        _ = wins.orderedRemove(j);
        break;
    };
    gpa.destroy(w);
}

// ---- menu actions ----

fn action(comptime run: fn (*Doc) void) *const anyopaque {
    return @ptrCast(&struct {
        fn imp(self: Id, _: Sel, _: Id) callconv(.c) void {
            const d = docOf(self) orelse return;
            d.note = "";
            run(d);
            // Closing the last tab closes the window, and the card with it.
            if (std.mem.indexOfScalar(*Doc, docs.items, d) != null) refresh(d);
        }
    }.imp);
}

fn pasteboard() Id {
    return msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
}

extern const NSPasteboardTypeString: Id;

fn copy(d: *Doc) void {
    const s = d.ed.sel();
    if (d.mode != .edit or s[0] == s[1]) return;
    const pb = pasteboard();
    _ = msg(isize, pb, "clearContents", .{});
    _ = msg(bool, pb, "setString:forType:", .{ objc.str(d.ed.text()[s[0]..s[1]]), NSPasteboardTypeString });
}

fn cut(d: *Doc) void {
    if (d.mode != .edit) return;
    copy(d);
    d.ed.deleteSelection(gpa) catch {};
    reveal(d);
}

fn paste(d: *Doc) void {
    const s = objc.utf8(msg(Id, pasteboard(), "stringForType:", .{NSPasteboardTypeString}));
    if (d.mode != .edit) return promptType(d, s);
    const at = d.ed.sel()[0];
    d.ed.insert(gpa, s) catch {};
    if (std.mem.indexOfScalar(u8, s, '\n') != null or s.len > 40) {
        flashStart(d);
        flashAdd(d, at, d.ed.cur);
    }
    reveal(d);
}

fn selectAll(d: *Doc) void {
    if (d.mode == .edit) d.ed.selectAll();
}

fn undo(d: *Doc) void {
    d.mode = .edit;
    const us = d.ed.buf.undos.items;
    const span: [2]usize = if (us.len > 0) .{ us[us.len - 1].pos, us[us.len - 1].pos + us[us.len - 1].old.len } else .{ 0, 0 };
    d.ed.undo(gpa) catch {};
    flashStart(d);
    flashAdd(d, span[0], span[1]);
    reveal(d);
}

fn redo(d: *Doc) void {
    d.mode = .edit;
    const rs = d.ed.buf.redos.items;
    const span: [2]usize = if (rs.len > 0) .{ rs[rs.len - 1].pos, rs[rs.len - 1].pos + rs[rs.len - 1].new.len } else .{ 0, 0 };
    d.ed.redo(gpa) catch {};
    flashStart(d);
    flashAdd(d, span[0], span[1]);
    reveal(d);
}

fn saveDoc(d: *Doc) void {
    _ = save(d, false);
}

fn saveAs(d: *Doc) void {
    _ = save(d, true);
}

fn find(d: *Doc) void {
    startPrompt(d, .find);
}

fn findReplace(d: *Doc) void {
    startPrompt(d, .replace);
}

fn findNext(d: *Doc) void {
    findAgain(d, false);
}

fn findPrev(d: *Doc) void {
    findAgain(d, true);
}

fn gotoLine(d: *Doc) void {
    startPrompt(d, .line);
}

fn quickOpen(d: *Doc) void {
    startPrompt(d, .open);
}

fn palette(d: *Doc) void {
    startPrompt(d, .command);
}

fn closeActive(d: *Doc) void {
    closeTab(d, d.at);
}

fn splitRight(d: *Doc) void {
    split(d, false);
}

fn splitDown(d: *Doc) void {
    split(d, true);
}

fn nextCard(d: *Doc) void {
    stepCard(d, 1);
}

fn previousCard(d: *Doc) void {
    stepCard(d, -1);
}

fn markdownPreview(d: *Doc) void {
    preview.toggle(d.window, d.path orelse "", d.ed.text(), &themes[@intFromBool(isDark(d.view))]);
}

fn comment(d: *Doc) void {
    if (d.mode != .edit) return;
    d.ed.toggleComment(gpa, d.lang.line_comment) catch {};
}

fn zoom(by: f64) void {
    const size = if (by == 0) settings.default_size else std.math.clamp(conf.size + by, 8, 40);
    var buf: [24]u8 = undefined;
    store("size", settings.decimal(&buf, size));
}

fn zoomIn(_: *Doc) void {
    zoom(1);
}

fn zoomOut(_: *Doc) void {
    zoom(-1);
}

fn zoomReset(_: *Doc) void {
    zoom(0);
}

/// The Font panel's choice, saved to the settings file.
fn changeFont(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const picked = msg(Id, sender, "convertFont:", .{font});
    if (picked == null) return;
    const name = objc.utf8(msg(Id, picked, "fontName", .{}));
    // The system font's private name can't be asked for by name.
    store("font", if (name.len == 0 or name[0] == '.') "system" else name);
    var buf: [24]u8 = undefined;
    store("size", settings.decimal(&buf, @round(msg(f64, picked, "pointSize", .{}))));
}

/// Registers the view class and loads the font. Call once at launch.
pub fn setup() void {
    contrast = msg(bool, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "accessibilityDisplayShouldIncreaseContrast", .{});
    loadSettings();
    const c = objc.ClassBuilder.begin("NSView", "ZeView");
    c.ivar("win");
    c.method("drawRect:", @ptrCast(&drawRect), "v@:{CGRect=dddd}");
    c.method("isFlipped", @ptrCast(&yes), "c@:");
    c.method("isOpaque", @ptrCast(&no), "c@:");
    c.method("acceptsFirstResponder", @ptrCast(&yes), "c@:");
    c.method("keyDown:", @ptrCast(&keyDown), "v@:@");
    c.method("insertText:", @ptrCast(&insertText), "v@:@");
    c.method("doCommandBySelector:", @ptrCast(&doCommand), "v@::");
    c.method("mouseDown:", @ptrCast(&mouseDown), "v@:@");
    c.method("mouseDragged:", @ptrCast(&mouseDragged), "v@:@");
    c.method("mouseUp:", @ptrCast(&mouseUp), "v@:@");
    c.method("mouseMoved:", @ptrCast(&mouseMoved), "v@:@");
    c.method("mouseExited:", @ptrCast(&mouseExited), "v@:@");
    c.method("scrollWheel:", @ptrCast(&scrollWheel), "v@:@");
    c.method("resetCursorRects", @ptrCast(&resetCursorRects), "v@:");
    c.method("viewDidChangeEffectiveAppearance", @ptrCast(&lookChanged), "v@:");
    c.method("windowDidBecomeKey:", @ptrCast(&appearanceChanged), "v@:@");
    c.method("windowDidResignKey:", @ptrCast(&appearanceChanged), "v@:@");
    c.method("draggingEntered:", @ptrCast(&draggingEntered), "Q@:@");
    c.method("performDragOperation:", @ptrCast(&performDrag), "c@:@");
    c.method("windowShouldClose:", @ptrCast(&windowShouldClose), "c@:@");
    c.method("windowWillClose:", @ptrCast(&windowWillClose), "v@:@");
    c.method("window:willUseFullScreenPresentationOptions:", @ptrCast(&fullScreenOptions), "Q@:@Q");
    c.method("retitle:", @ptrCast(&retitleNow), "v@:@");
    c.method("tick:", @ptrCast(&tick), "v@:@");
    c.method("barHold:", @ptrCast(&barHold), "v@:@");
    c.method("saveDrafts:", @ptrCast(&saveDraftsNow), "v@:@");
    c.method("changeFont:", @ptrCast(&changeFont), "v@:@");
    c.method("menuForEvent:", @ptrCast(&menuForEvent), "@@:@");
    c.method("openInNewWindow:", @ptrCast(&openInNewWindow), "v@:@");
    c.method("openInNewTab:", @ptrCast(&openInNewTab), "v@:@");
    c.method("openInNewSplit:", @ptrCast(&openInNewSplit), "v@:@");
    c.method("tabClose:", @ptrCast(&tabClose), "v@:@");
    c.method("tabCloseOthers:", @ptrCast(&tabCloseOthers), "v@:@");
    c.method("tabCloseRight:", @ptrCast(&tabCloseRight), "v@:@");
    c.method("tabSplitRight:", @ptrCast(&tabSplitRight), "v@:@");
    c.method("tabSplitDown:", @ptrCast(&tabSplitDown), "v@:@");
    c.method("menuDidClose:", @ptrCast(&menuDidClose), "v@:@");
    c.method("revealInFinder:", @ptrCast(&revealInFinder), "v@:@");
    c.method("sideParent:", @ptrCast(&sideParent), "v@:@");
    c.method("copyPath:", @ptrCast(&copyPath), "v@:@");
    c.method("runCommand:", @ptrCast(&runCommand), "v@:@");
    access.addViewMethods(c);
    const actions = .{
        .{ "copy:", copy },             .{ "cut:", cut },               .{ "paste:", paste },
        .{ "selectAll:", selectAll },   .{ "undo:", undo },             .{ "redo:", redo },
        .{ "saveDocument:", saveDoc },      .{ "saveDocumentAs:", saveAs }, .{ "findText:", find },
        .{ "findNext:", findNext },         .{ "findPrevious:", findPrev }, .{ "gotoLine:", gotoLine },
        .{ "quickOpen:", quickOpen },       .{ "toggleComment:", comment }, .{ "zoomIn:", zoomIn },
        .{ "zoomOut:", zoomOut },           .{ "zoomReset:", zoomReset },   .{ "findAndReplace:", findReplace },
        .{ "commandPalette:", palette },    .{ "newTab:", newTab },         .{ "closeTab:", closeActive },
        .{ "splitRight:", splitRight },     .{ "splitDown:", splitDown },   .{ "nextCard:", nextCard },
        .{ "previousCard:", previousCard },
        .{ "markdownPreview:", markdownPreview },
    };
    inline for (actions) |a| c.method(a[0], action(a[1]), "v@:@");
    view_class = c.finish();
    win_ivar = objc.ivarOffset(view_class, "win");
    // Increase Contrast turning on or off redraws every window.
    const watcher = objc.ClassBuilder.begin("NSObject", "ZeContrast");
    watcher.method("contrastChanged:", @ptrCast(&contrastChanged), "v@:@");
    const watch_class = watcher.finish();
    const watch = msg(Id, msg(Id, watch_class, "alloc", .{}), "init", .{});
    const notes = msg(Id, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "notificationCenter", .{});
    msg(void, notes, "addObserver:selector:name:object:", .{ watch, objc.sel_registerName("contrastChanged:"), NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification, @as(Id, null) });
}
