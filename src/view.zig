//! The windows: an NSView subclass that draws a sidebar and one or more
//! cards, each a pane with its own tabs, the text in CoreText glyph runs on
//! a monospace grid, and turns key and mouse events into editor commands.
//! A card's bottom line is the prompt for find, go to line, quick open and
//! the command palette.
const std = @import("std");
const objc = @import("objc.zig");
const editor = @import("editor.zig");
const buffer = @import("buffer.zig");
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

/// Adopts an owned folder path; its tree rows will be read before display.
pub fn adoptRoot(dir: []const u8) void {
    if (root) |r| gpa.free(r);
    root = dir;
    tree_stale = true;
}

/// Makes `dir` (owned by gpa) the folder, and shows it in the sidebar.
pub fn setRoot(dir: []const u8) void {
    adoptRoot(dir);
    noteRecentFolder(dir);
    // A quick open on show lists the new folder. Otherwise the old list stays
    // for a panel still sliding shut; the next ⌘P reads the folder again anyway.
    if (quick != null) for (docs.items) |d| if (d.mode == .open) {
        rescanQuick(dir, null);
        break;
    };
    // The header's folder is written relative to the open folder.
    for (docs.items) |d| dropHead(d);
    tree.closeAll(gpa);
    for (wins.items) |w| {
        w.side_y = 0;
        w.side_cur = null;
        // The sidebar crossfades from the old folder's rows to the new one's.
        if (sideShown(w) and msg(bool, w.window, "isVisible", .{})) msg(void, msg(Id, w.view, "layer", .{}), "addAnimation:forKey:", .{ themeFade(), objc.str("root") });
    }
    dropSideLines();
    rebuildTree();
    for (wins.items) |w| msg(void, w.window, "invalidateCursorRectsForView:", .{w.view});
    refreshAll();
}

var quick_root: ?[:0]u8 = null;
var quick_hidden: bool = false;
var quick_gen: u64 = 0;

extern fn dispatch_get_global_queue(identifier: isize, flags: usize) *anyopaque;
extern fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

const QuickJob = struct {
    dir: [:0]u8,
    show_hidden: bool,
    gen: u64,
    files: ?finder.Files = null,
};

var quick_busy: bool = false;

fn bgRescanQuick(dir: []const u8, show_hidden: bool) void {
    if (quick_busy) return;
    quick_gen +%= 1;
    const job = gpa.create(QuickJob) catch return;
    job.* = .{
        .dir = gpa.dupeSentinel(u8, dir, 0) catch {
            gpa.destroy(job);
            return;
        },
        .show_hidden = show_hidden,
        .gen = quick_gen,
    };
    quick_busy = true;
    dispatch_async_f(dispatch_get_global_queue(0, 0), job, bgRescanWork);
}

fn bgRescanWork(ctx: ?*anyopaque) callconv(.c) void {
    const job: *QuickJob = @ptrCast(@alignCast(ctx orelse return));
    job.files = finder.scanWithOptions(gpa, job.dir, job.show_hidden, &.{}) catch null;
    dispatch_async_f(&_dispatch_main_q, job, bgRescanDone);
}

fn bgRescanDone(ctx: ?*anyopaque) callconv(.c) void {
    const job: *QuickJob = @ptrCast(@alignCast(ctx orelse return));
    defer {
        quick_busy = false;
        gpa.free(job.dir);
        if (job.files) |*fl| fl.deinit();
        gpa.destroy(job);
    }
    if (job.gen != quick_gen) return;
    const qr = quick_root orelse return;
    if (!std.mem.eql(u8, qr, job.dir) or conf.show_hidden != job.show_hidden) return;
    const scanned = job.files orelse return;
    job.files = null;
    var old_quick = quick;
    defer if (old_quick) |*oq| oq.deinit();
    quick = scanned;
    for (docs.items) |o| {
        if (o.mode != .open) continue;
        var saved: ?[]const u8 = null;
        if (old_quick) |*oq| {
            if (o.pick < o.npicks) {
                const idx = o.picks[o.pick];
                if (idx < oq.paths.items.len) saved = oq.paths.items[idx];
            }
        }
        pickFiles(o, true);
        if (saved) |sp| {
            const new_paths = quick.?.paths.items;
            for (o.picks[0..o.npicks], 0..) |idx, k| {
                if (idx < new_paths.len and std.mem.eql(u8, new_paths[idx], sp)) {
                    o.pick = k;
                    break;
                }
            }
        }
        refresh(o);
    }
}

/// Scans quick open again; `fresh` must not crossfade picks from the palette.
fn rescanQuick(dir: []const u8, _: ?*Doc) void {
    quick_gen +%= 1;
    if (quick) |*q| q.deinit();
    quick = finder.scanWithOptions(gpa, dir, conf.show_hidden, &.{}) catch null;
    if (quick_root) |r| gpa.free(r);
    quick_root = if (quick != null) gpa.dupeSentinel(u8, dir, 0) catch null else null;
    quick_hidden = conf.show_hidden;
    for (docs.items) |o| if (o.mode == .open) pickFiles(o, true);
}

/// Reads the rows again. The row under each window's mouse and its keyboard
/// cursor stay on the same files, wherever those rows move to.
fn rebuildTree() void {
    var held: [8][2]?[]u8 = @splat(.{ null, null });
    const n = @min(wins.items.len, held.len);
    for (wins.items[0..n], held[0..n]) |w, *h| {
        h[0] = heldRel(w.hov.row, w.hov.gen);
        h[1] = heldRel(w.side_cur, w.side_cur_gen);
    }
    defer for (held) |h| {
        for (h) |r| if (r) |s| gpa.free(s);
    };
    rebuildRows();
    for (wins.items[0..n], held[0..n]) |w, h| {
        if (h[0]) |rel| if (tree.rowOf(rel)) |i| {
            w.hov.row = i;
            w.hov.last = i;
            w.hov.gen = tree_gen;
        };
        if (h[1]) |rel| if (tree.rowOf(rel)) |i| {
            w.side_cur = i;
            w.kc.last = i;
            w.side_cur_gen = tree_gen;
        };
    }
}

/// A copy of row `row`'s path while it's from the current tree.
fn heldRel(row: ?usize, gen: u32) ?[]u8 {
    const i = row orelse return null;
    if (gen != tree_gen or i >= tree.rows.items.len) return null;
    return gpa.dupe(u8, tree.rows.items[i].rel) catch null;
}

fn rebuildRows() void {
    tree_stale = false;
    const r = root orelse return;
    var kept: std.StringHashMapUnmanaged(usize) = .empty;
    defer kept.deinit(gpa);
    for (side_lines.items, 0..) |line, i| if (line.full != null) {
        kept.put(gpa, tree.rows.items[i].rel, i) catch {
            dropSideLines();
            return rebuildRows();
        };
    };
    if (kept.count() == 0) {
        tree.rebuild(gpa, r);
        tree_gen +%= 1;
        dropSideLines();
        return;
    }
    // The map borrows the old paths until every surviving line has moved.
    var old_arena = tree.arena;
    defer old_arena.deinit();
    tree.arena = .init(gpa);
    tree.rebuild(gpa, r);
    tree_gen +%= 1;
    var old_lines = side_lines;
    side_lines = .empty;
    defer {
        for (old_lines.items) |*line| freeSideLine(line);
        old_lines.deinit(gpa);
    }
    for (wins.items) |w| {
        for (&w.bold) |*b| freeSideLine(&b.line);
    }
    side_lines.resize(gpa, tree.rows.items.len) catch return;
    @memset(side_lines.items, .{});
    for (tree.rows.items, side_lines.items) |row, *line| {
        if (kept.get(row.rel)) |i| {
            line.* = old_lines.items[i];
            old_lines.items[i] = .{};
        }
    }
}

/// Counts tree rebuilds, so a window knows when to look up its selected row again.
var tree_gen: u32 = 0;

/// Session restore defers reading folders and redrawing until its end.
var restoring = false;
/// The rows no longer match the root or the set of open folders.
var tree_stale = false;
var modal = false;

/// Quick open's file list, one for every card: each open reads it again.
var quick: ?finder.Files = null;

/// `p` relative to the folder, when it's inside it.
fn relOf(p: []const u8) ?[]const u8 {
    const r = root orelse return null;
    if (p.len <= r.len + 1 or !std.mem.startsWith(u8, p, r) or p[r.len] != '/') return null;
    return p[r.len + 1 ..];
}

fn revealFile(rel: []const u8) void {
    if (tree.reveal(gpa, rel) or (!tree_stale and !tree.has(rel))) tree_stale = true;
}

fn refreshAll() void {
    for (docs.items) |d| refresh(d);
    for (wins.items) |w| msg(void, w.view, "setNeedsDisplay:", .{true});
}

fn refreshWin(w: *Win) void {
    for (docs.items) |d| if (d.win == w) refresh(d);
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

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
/// It uses the split gap's stretch and pull, with its own spring.
var side_stretch: Spring = .{ .k = 380, .c = 33, .eps = 0.05 };
var side_rest: f64 = settings.sidebar_default;
const side_collapse = 100.0;
const text_room = 360.0;
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
    return sideShownAt(msg(Rect, w.view, "bounds", .{}).w);
}

/// `sideShown` for a view width the caller already has.
fn sideShownAt(width: f64) bool {
    return !conf.zen and conf.sidebar and root != null and width >= side_w + text_room;
}

fn overSide(w: *const Win, p: Point) bool {
    return sideShown(w) and p.x < side_w;
}

/// A card's right edge in its pane, which it sits a gap inside of.
fn rightEdge(d: *const Doc) f64 {
    return d.size.x - gap;
}

/// From the card's left edge to the text. Zen pads it so an 80-column page
/// sits in the middle of the card, measured at the width the card springs
/// to, the same width `wrapCols` wraps at.
fn padL(d: *const Doc) f64 {
    const z = zen(d.win);
    const room = if (d.fin.x > 0) d.fin.x else d.size.x;
    return pad_x + (@max(pad_x, (room - f(conf.zen_columns) * cw) / 2 - gap) - pad_x) * z + d.gw;
}

/// The line numbers' width in columns: the line count's digits, at least
/// two, and a gap and a half before the text. Zero with them off.
fn gutCols(d: *const Doc) f64 {
    if (!conf.line_numbers) return 0;
    var digits: usize = 2;
    var n = d.file.ed.buf.lines();
    while (n >= 100) : (n /= 10) digits += 1;
    return f(digits) + 1.5;
}

/// The gutter's width once it's done easing; zen has none.
fn gutter(d: *const Doc) f64 {
    return if (conf.zen) 0 else gutCols(d) * cw;
}

/// Soft wrap is on, or zen wraps at 80 columns.
fn wrapping() bool {
    return conf.wrap or conf.zen;
}

/// Where the text ends: the card's bottom, or the prompt line above it.
fn bottom(d: *const Doc) f64 {
    return d.size.y - gap - if (d.mode == .edit) stripH(d) else barH();
}

/// Where the text ends right now, for drawing: `bottom` eased with the
/// prompt band as it slides in and out, so what sits on the band's edge
/// (the quick open list, the sideways scroll bar) rides it. Layout keeps
/// using `bottom`, where the band ends up.
fn edgeAt(d: *const Doc, now: f64) f64 {
    const s = stripH(d);
    return d.size.y - gap - (s + (barH() - s) * std.math.clamp(d.pbar.at(now), 0, 1));
}

/// The status strip along the card's bottom, easing away with Zen.
const strip_h = 22.0;
fn stripH(d: *const Doc) f64 {
    return strip_h * (1 - zen(d.win));
}

fn zen(w: *const Win) f64 {
    return std.math.clamp(w.z.x, 0, 1);
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
/// shows through. Zen covers the material completely, and so does a theme
/// whose background is pure black (Black), so no grey shows. (The material
/// can't be hidden: Zag's view lives inside it.)
fn chromeAlpha(th: *const Theme, dark: bool, z: f64) f64 {
    if (th.bg[0] + th.bg[1] + th.bg[2] == 0) return 1;
    const a: f64 = if (dark) 0.7 else 0.6;
    return a + (1 - a) * std.math.clamp(z, 0, 1);
}

/// Font, size, colors and toggles, from the settings file.
var conf: settings.Settings = .{};
/// The file's own values: what writes use, while `conf` has Late-Night laid over them.
var conf_saved: settings.Settings = .{};
/// The themes that draw: the settings' colors, turned grey in zen.
var themes: [2]Theme = .{ settings.paper, settings.ink };
var conf_path: ?[:0]u8 = null;
var conf_stamp: ?files.Stamp = null;
var font: Id = null;
var bold: Id = null;
var cw: f64 = 8;
var lh: f64 = 22;
var baseline: f64 = 15;
var ascii: [2][95]u16 = undefined;
const Fallback = struct { font: Id, glyph: u16 };
const FallbackEntry = struct { cp: u21, fb: Fallback };
var fallbacks: std.ArrayList(FallbackEntry) = .empty;
/// The sidebar's fonts: the system font for file names and a heavier one
/// for the folder's name and the card's header. Rows are `side_h` tall,
/// with the baseline that centers the text in one.
var side_font: Id = null;
var name_font: Id = null;
var side_h: f64 = 30;
var side_base: f64 = 19;
/// From the header's middle line down to the baseline of its text.
var name_off: f64 = 4;
/// The header's fonts: tab names regular in `side_font`, the active one
/// medium, with every tab as wide as its medium name so switching never
/// moves a tab; the folder after a lone tab's name small and regular,
/// `path_off` above its baseline like `name_off`.
var tab_bold: Id = null;
var path_font: Id = null;
var path_off: f64 = 3;

fn barH() f64 {
    return lh + 12;
}

/// Loads the font the settings name, or the system monospace font.
fn setFont() void {
    dropAttrs();
    for (fallbacks.items) |e| if (e.fb.font != font) objc.CFRelease(e.fb.font.?);
    fallbacks.clearRetainingCapacity();
    for ([_]*Id{ &font, &bold, &side_font, &name_font, &tab_bold, &path_font }) |p| if (p.* != null) msg(void, p.*, "release", .{});
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
    lh = @round(conf.size * conf.spacing);
    baseline = baseIn(font, lh);
    side_font = msg(Id, msg(Id, NSFont, "systemFontOfSize:", .{conf.size - 1}), "retain", .{});
    name_font = msg(Id, msg(Id, NSFont, "systemFontOfSize:weight:", .{ conf.size - 1, @as(f64, 0.3) }), "retain", .{});
    side_h = @round((conf.size - 1) * 2.3);
    side_base = baseIn(side_font, side_h);
    name_off = midOff(name_font);
    tab_bold = msg(Id, msg(Id, NSFont, "systemFontOfSize:weight:", .{ conf.size - 1, @as(f64, 0.23) }), "retain", .{});
    path_font = msg(Id, msg(Id, NSFont, "systemFontOfSize:weight:", .{ conf.size - 3, @as(f64, 0) }), "retain", .{});
    path_off = midOff(path_font);
    dropSideLines();
    for (docs.items) |d| {
        dropHead(d);
        for (d.slots.items) |*s| if (!s.gone) s.drop();
    }
    msg(void, msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{}), "setSelectedFont:isMultiple:", .{ font, false });
    // The Markdown preview's type follows the editor's.
    preview.setTypography(conf.font(), conf.size, conf.spacing);
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
    var lo: usize = 0;
    var hi = fallbacks.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (fallbacks.items[mid].cp < cp) lo = mid + 1 else hi = mid;
    }
    if (lo < fallbacks.items.len and fallbacks.items[lo].cp == cp) return fallbacks.items[lo].fb;
    fallbacks.ensureUnusedCapacity(gpa, 1) catch return .{ .font = font, .glyph = 0 };
    var units: [2]u16 = undefined;
    const n = utf16(cp, &units);
    var g: [2]u16 = .{ 0, 0 };
    var fb: Fallback = .{ .font = font, .glyph = 0 };
    if (objc.CTFontGetGlyphsForCharacters(font, &units, &g, @intCast(n)) and g[0] != 0) {
        fb.glyph = g[0];
    } else {
        const alt = objc.fallbackFont(font, units[0..n]);
        if (alt != null and objc.CTFontGetGlyphsForCharacters(alt, &units, &g, @intCast(n))) {
            fb = .{ .font = alt, .glyph = g[0] };
        } else if (alt != null) objc.CFRelease(alt.?);
    }
    fallbacks.insertAssumeCapacity(lo, .{ .cp = cp, .fb = fb });
    return fb;
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
    /// Columns per tab stop, the editor's `tabWidth` for its text.
    tw: usize = editor.default_tab_width,
    /// Which spaces and tabs draw as faint dots and arrows, in `invis_ink`.
    invis: settings.Invisibles = .none,
    invis_ink: Rgb = .{ 0, 0, 0 },

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
    const Cut = struct { target: usize, byte: usize = 0, col: usize = 0 };

    fn run(k: *Ink, s: []const u8, from: usize, to: usize, col0: usize, kinds: ?[]const syntax.Kind, th: *const Theme, color: Rgb, x: f64, y: f64, skip: usize, max: usize) usize {
        return k.runCut(s, from, to, col0, kinds, th, color, x, y, skip, max, null);
    }

    inline fn runCut(k: *Ink, s: []const u8, from: usize, to: usize, col0: usize, kinds: ?[]const syntax.Kind, th: *const Theme, color: Rgb, x: f64, y: f64, skip: usize, max: usize, cut_out: ?*Cut) usize {
        // Trailing marks start after the last character that isn't a space or tab.
        const trail = if (k.invis == .trailing) std.mem.trimEnd(u8, s, " \t\r").len else 0;
        var col = col0;
        var i = from;
        if (cut_out) |ct| {
            ct.byte = from;
            ct.col = col0;
        }
        while (i < to) {
            const c = editor.cellsTab(s, i, col, k.tw);
            const rel = col - col0;
            if (cut_out) |ct| if (rel <= ct.target) {
                ct.byte = i;
                ct.col = col;
            };
            if (rel >= skip + max) break;
            const blank = s[i] == ' ' or s[i] == '\t';
            const mark = blank and k.invis != .none and (k.invis == .all or i >= trail);
            if (rel >= skip and (mark or (!blank and s[i] >= 0x20 and s[i] != 0x7f))) {
                const kind: syntax.Kind = if (kinds) |ks| ks[i] else .text;
                var paint = if (mark) k.invis_ink else if (kinds != null) th.kinds[@intFromEnum(kind)] else color;
                if (k.focus) |fo| {
                    const at = k.offset + i;
                    if (at < k.selected[0] or at >= k.selected[1]) {
                        const a = fo.dim(at >= fo.new[0] and at < fo.new[1], at >= fo.old[0] and at < fo.old[1]);
                        paint = mixRgb(th.bg, paint, a);
                    }
                }
                const gx = x + f(rel - skip) * cw;
                if (mark) {
                    // A space is a centered dot; a tab an arrow at its stop's start.
                    k.put(glyph(@as(u21, if (s[i] == '\t') 0x2192 else 0x00B7), false), paint, gx, y);
                } else if (c.len > c.cp_len) {
                    // A cluster of several code points (a decomposed accent, a
                    // joined emoji) draws as one line so Core Text shapes it.
                    k.flush();
                    const line = uiLine(s[i .. i + c.len], if (kind == .keyword) bold else font, 1e9);
                    defer if (line) |l| objc.CFRelease(l);
                    paintLine(k.ctx, line, paint, 1, gx, y);
                } else k.put(glyph(c.cp, kind == .keyword), paint, gx, y);
            }
            col += c.w;
            i += c.len;
        }
        if (cut_out) |ct| if (i == to and col - col0 <= ct.target) {
            ct.byte = i;
            ct.col = col;
        };
        return (col - col0) -| skip;
    }
};

/// Focus mode's lit text: the byte range it's fading to, the one it's
/// fading from, and how far along the fade is.
const Focus = struct {
    new: [2]usize,
    old: [2]usize,
    t: f64,
    amt: f64,

    fn dim(fo: Focus, in_new: bool, in_old: bool) f64 {
        return 1 - fo.amt * (conf.focus_dim - conf.focus_dim * (f(@intFromBool(in_new)) * fo.t + f(@intFromBool(in_old)) * (1 - fo.t)));
    }
};
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

/// `v` rounded to the nearest device pixel.
fn snapPx(v: f64) f64 {
    return @round(v / dev_px) * dev_px;
}

/// Like `roundPath` with each corner's own radius: top left, top right,
/// bottom right, bottom left.
fn cornerPath(ctx: Id, x: f64, y: f64, w: f64, h: f64, radii: [4]f64) void {
    var r: [4]f64 = undefined;
    for (radii, &r) |a, *b| b.* = @max(0, @min(a, w / 2, h / 2));
    const k = 0.4477152502; // a quarter circle's bezier handle, from the corner
    const x1 = x + w;
    const y1 = y + h;
    objc.CGContextMoveToPoint(ctx, x + r[0], y);
    objc.CGContextAddLineToPoint(ctx, x1 - r[1], y);
    objc.CGContextAddCurveToPoint(ctx, x1 - r[1] * k, y, x1, y + r[1] * k, x1, y + r[1]);
    objc.CGContextAddLineToPoint(ctx, x1, y1 - r[2]);
    objc.CGContextAddCurveToPoint(ctx, x1, y1 - r[2] * k, x1 - r[2] * k, y1, x1 - r[2], y1);
    objc.CGContextAddLineToPoint(ctx, x + r[3], y1);
    objc.CGContextAddCurveToPoint(ctx, x + r[3] * k, y1, x, y1 - r[3] * k, x, y1 - r[3]);
    objc.CGContextAddLineToPoint(ctx, x, y + r[0]);
    objc.CGContextAddCurveToPoint(ctx, x, y + r[0] * k, x + r[0] * k, y, x + r[0], y);
    objc.CGContextClosePath(ctx);
}

/// Adds a rounded rectangle to the context's path, with no path object made.
fn roundPath(ctx: Id, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const r = @max(0, @min(radius, w / 2, h / 2));
    const o = r * 0.4477152502; // a quarter circle's bezier handle, from the corner
    const x1 = x + w;
    const y1 = y + h;
    objc.CGContextMoveToPoint(ctx, x + r, y);
    objc.CGContextAddLineToPoint(ctx, x1 - r, y);
    objc.CGContextAddCurveToPoint(ctx, x1 - o, y, x1, y + o, x1, y + r);
    objc.CGContextAddLineToPoint(ctx, x1, y1 - r);
    objc.CGContextAddCurveToPoint(ctx, x1, y1 - o, x1 - o, y1, x1 - r, y1);
    objc.CGContextAddLineToPoint(ctx, x + r, y1);
    objc.CGContextAddCurveToPoint(ctx, x + o, y1, x, y1 - o, x, y1 - r);
    objc.CGContextAddLineToPoint(ctx, x, y + r);
    objc.CGContextAddCurveToPoint(ctx, x, y + o, x + o, y, x + r, y);
    objc.CGContextClosePath(ctx);
}

/// A rounded rectangle: the card, the sidebar's selection, the icon tiles.
fn pill(ctx: Id, c: Rgb, a: f64, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    roundPath(ctx, x, y, w, h, radius);
    objc.CGContextFillPath(ctx);
}

/// The hairline outline of the rounded rectangle `pill` fills: one device
/// pixel thick.
fn ring(ctx: Id, c: Rgb, a: f64, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const t = hair();
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    roundPath(ctx, x, y, w, h, radius);
    roundPath(ctx, x + t, y + t, w - 2 * t, h - 2 * t, radius - t);
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
/// The `card_radius` the slices were made for.
var shadow_for: f64 = 0;

/// The nine slices of the card shadow for light or dark, made on first use.
fn shadowCells(dark: bool) *const [9]?*anyopaque {
    // The slices follow the card's corner radius, so a new radius makes them again.
    if (shadow_for != card_radius) {
        for (&shadow_cells) |*set| for (set) |*cell| {
            if (cell.*) |i| objc.CFRelease(i);
            cell.* = null;
        };
        shadow_for = card_radius;
    }
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
    // The view is flipped and images draw upside down in a flipped context,
    // so flip the slices back, once.
    objc.CGContextScaleCTM(ctx, 1, -1);
    for (0..3) |r| for (0..3) |c| {
        if (r == 1 and c == 1) continue;
        const dw = xs[c + 1] - xs[c];
        const dh = ys[r + 1] - ys[r];
        objc.CGContextDrawImage(ctx, .{ .x = xs[c], .y = -ys[r + 1], .w = dw, .h = dh }, cells[r * 3 + c]);
    };
    objc.CGContextRestoreGState(ctx);
}

/// Limits drawing to a rounded rectangle until the state is restored.
fn clipRound(ctx: Id, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    roundPath(ctx, x, y, w, h, radius);
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

    fn aimOver(w: *Tween, to: f64, dur: f64, now: f64) void {
        if (to == w.to) return;
        w.dur = dur;
        w.aim(to, now);
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
    k: f64,
    c: f64,
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

    fn ride(s: *Spring, to: f64) void {
        s.x += to - s.to;
        s.to = to;
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
    name: [2]SideLine = .{ .{}, .{} },
    /// Its file kind's icon, from `iconFor`.
    icon: Id = null,
    gone: bool = false,
    /// Where it last laid out, before `shift`.
    x: f64 = 0,
    w: f64 = 0,
    /// Its name's width, springing to a new name's instead of jumping.
    wid: Spring = .{ .k = 420, .c = 34, .eps = 0.05 },
    sized: bool = false,
    /// Its width as squeezed among the others, springing when the squeeze
    /// or the active tab changes; at its own width it follows that at once.
    fit: Spring = .{ .k = 420, .c = 34, .eps = 0.05 },
    fitted: bool = false,
    /// Its file is untitled, so its dot is the fainter draft dot.
    draft: bool = false,
    /// How far it's drawn from where it lays out: it slides into a new
    /// place after the tabs reorder, and follows the mouse while dragged.
    shift: Spring = .{ .k = 420, .c = 30, .eps = 0.05 },
    /// Where it was drawn when the tabs reordered, to slide from.
    flip: ?f64 = null,

    fn drop(s: *Slot) void {
        for (&s.name) |*n| freeSideLine(n);
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
/// a gliding scroll. An inactive caret (a card without the keys) shows as
/// a dim hollow box that doesn't blink.
fn placeCaret(d: *Doc, now: f64, x: f64, y: f64, in_text: bool, spot: [3]usize, show: bool, active: bool) void {
    const moved = !std.mem.eql(usize, &spot, &d.spot);
    if (in_text != d.c_text) {
        const sign: f64 = if (in_text) 1 else -1;
        d.cx.snap(d.cx.at(now) + sign * d.vx);
        d.cy.snap(d.cy.at(now) + sign * d.vy);
        d.c_text = in_text;
        d.caret_at = null;
    }
    if (moved and d.shown and show and !d.snap) {
        const glide = glideTime(x - d.cx.to, y - d.cy.to);
        d.cx.aimOver(x, glide, now);
        d.cy.aimOver(y, if (conf.typewriter and in_text) scroll_time else glide, now);
    } else if (moved or !d.shown or !show or d.snap or d.cx.to != x or d.cy.to != y) {
        d.cx.snap(x);
        d.cy.snap(y);
    }
    if (show and active and (moved or !d.shown or !d.caret_on)) blink(d.caret);
    if (!active and d.caret_on and blink_key != null) msg(void, d.caret, "removeAnimationForKey:", .{blink_key});
    if (active != d.caret_on) d.caret_at = null;
    d.caret_on = active;
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

/// Puts the caret layer where its glide is at `now`. Crossing the text's
/// edges it fades out over half a row (a column sideways) rather than
/// cutting; its frame lands on whole device pixels.
fn moveCaret(d: *Doc, now: f64) void {
    var x = d.cx.at(now);
    var y = d.cy.at(now);
    if (d.c_text) {
        x -= d.vx;
        y -= d.vy;
    }
    var a: f64 = 1;
    if (d.c_text) {
        const ramp = lh / 2;
        a = std.math.clamp((x - (gap + padL(d) - 2) + cw) / cw, 0, 1) *
            std.math.clamp((rightEdge(d) - x) / cw, 0, 1) *
            std.math.clamp((y - (top_h - 2) + ramp) / ramp, 0, 1) *
            std.math.clamp((edgeAt(d, now) - (y + lh - 4) + ramp) / ramp, 0, 1);
        a = @round(a * 16) / 16;
    }
    const visible = d.shown and a > 0;
    const active = d.caret_on or !d.c_text;
    // In the text the caret takes the settings' shape, as wide as the
    // character under it; in a prompt it's always a bar. An inactive one is
    // a hollow box around the character.
    const wide = cw * f(d.caret_cells);
    const shape: Rect = if (!d.c_text) .{ .w = 2, .h = lh - 4 } else if (!active) .{ .x = 1, .w = wide, .h = lh - 4 } else switch (conf.caret_style) {
        .bar => .{ .w = conf.caret_width, .h = lh - 4 },
        .block => .{ .x = 1, .w = wide, .h = lh - 4 },
        .underline => .{ .x = 1, .y = lh - 6, .w = wide, .h = 2 },
    };
    const x0 = snapPx(d.org.x + x + shape.x);
    const y0 = snapPx(d.org.y + y + shape.y);
    const frame = Rect{ .x = x0, .y = y0, .w = snapPx(shape.w), .h = snapPx(shape.h) };
    if (d.caret_at) |was| if (std.meta.eql(was, frame) and d.caret_off == !visible and d.caret_a == a) return;
    const restyle = d.caret_at == null or d.caret_a != a;
    d.caret_at = frame;
    d.caret_off = !visible;
    d.caret_a = a;
    const t = objc.class("CATransaction");
    msg(void, t, "begin", .{});
    msg(void, t, "setDisableActions:", .{true});
    msg(void, d.caret, "setFrame:", .{frame});
    msg(void, d.caret, "setHidden:", .{!visible});
    if (restyle) {
        const ink = nscolor(d.caret_ink);
        if (active) {
            // A block caret is see-through, so the letter under it shows.
            const solid: f64 = if (d.c_text and conf.caret_style == .block) 0.45 else 1;
            msg(void, d.caret, "setBackgroundColor:", .{msg(Id, msg(Id, ink, "colorWithAlphaComponent:", .{solid * a}), "CGColor", .{})});
            msg(void, d.caret, "setBorderWidth:", .{@as(f64, 0)});
        } else {
            msg(void, d.caret, "setBackgroundColor:", .{@as(Id, null)});
            msg(void, d.caret, "setBorderWidth:", .{@max(@as(f64, 1), 2 * hair())});
            msg(void, d.caret, "setBorderColor:", .{msg(Id, msg(Id, ink, "colorWithAlphaComponent:", .{0.5 * a}), "CGColor", .{})});
        }
    }
    msg(void, t, "commit", .{});
}

var fade_anim: Id = null;
var fade_anim_key: Id = null;
var blink_anim: Id = null;
var blink_key: Id = null;

/// Fades the layer in from clear over `dur`, as an opacity animation.
/// The animation is made once; adding it copies it.
fn fadeIn(layer: Id, dur: f64) void {
    if (fade_anim == null) {
        const num = objc.class("NSNumber");
        const a = msg(Id, objc.class("CABasicAnimation"), "animationWithKeyPath:", .{objc.str("opacity")});
        msg(void, a, "setFromValue:", .{msg(Id, num, "numberWithDouble:", .{@as(f64, 0)})});
        msg(void, a, "setToValue:", .{msg(Id, num, "numberWithDouble:", .{@as(f64, 1)})});
        fade_anim = msg(Id, a, "retain", .{});
        fade_anim_key = msg(Id, objc.str("fade"), "retain", .{});
    }
    msg(void, fade_anim, "setDuration:", .{dur});
    msg(void, layer, "addAnimation:forKey:", .{ fade_anim, fade_anim_key });
}

/// Holds the caret solid for half a second, then fades it out, rests it
/// dark, and fades it back in, once a second. The animation is made once.
/// With blinking off in the settings the caret stays solid.
fn blink(caret: Id) void {
    if (!conf.caret_blink) {
        if (blink_key != null) msg(void, caret, "removeAnimationForKey:", .{blink_key});
        return;
    }
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
        blink_key = msg(Id, objc.str("blink"), "retain", .{});
    }
    msg(void, caret, "addAnimation:forKey:", .{ blink_anim, blink_key });
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

/// Adds the bytes `lo..hi` of the text to the flash, up to `max_flash`
/// spans. An empty span (a deletion, an undone insertion) flashes as a
/// bar where the text was.
fn flashAdd(d: *Doc, lo: usize, hi: usize) void {
    if (lo > hi or d.flash_n == max_flash) return;
    if (d.flash_n == 0) msg(void, d.win.view, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("holdRedraw:"), @as(Id, null), @max(d.flash_t0 + flash_hold - CACurrentMediaTime(), 0) });
    d.flash[d.flash_n] = .{ lo, hi };
    d.flash_n += 1;
}

/// Holds a flash that hasn't begun fading while the page still glides to
/// it, so it plays once its text is in view.
fn flashWait(d: *Doc, now: f64) void {
    if (d.flash_n == 0 or !d.ys.moving(now) or now >= d.flash_t0 + flash_hold) return;
    d.flash_t0 = now;
    msg(void, d.win.view, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("holdRedraw:"), @as(Id, null), @as(f64, flash_hold + 0.01) });
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

const RowSpan = struct { x0: f64, x1: f64, lo: usize, hi: usize, col: usize };

/// Where file bytes `m` fall on row `sg` of line `l`, starting at byte `ls`.
fn rowSpan(l: []const u8, ls: usize, sg: Seg, m: [2]usize, ox: f64, skip: usize) ?RowSpan {
    if (m[0] > ls + l.len or m[1] <= ls) return null;
    const lo = std.math.clamp(@max(m[0], ls) - ls, sg.start, sg.end);
    const hi = std.math.clamp(@min(m[1], ls + l.len) - ls, sg.start, sg.end);
    const col = editor.colOfTab(l, sg.start, sg.col, lo, sg.tw);
    const x0 = ox + (f(col - sg.col + sg.ind) - f(skip)) * cw;
    return .{ .x0 = x0, .x1 = ox + (f(editor.colOfTab(l, lo, col, hi, sg.tw) - sg.col + sg.ind) - f(skip)) * cw, .lo = lo, .hi = hi, .col = col };
}

/// Fills a row span, with a tail when the range runs on to the next line.
/// The range's first row rounds its top corners and its last row its
/// bottom ones, so a selection over several rows reads as one shape.
fn fillSpan(ctx: Id, col: Rgb, a: f64, rg: [2]usize, ls: usize, l: []const u8, sg: Seg, ox: f64, skip: usize, y: f64) void {
    const sp = rowSpan(l, ls, sg, rg, ox, skip) orelse return;
    const tail: f64 = if (rg[1] > ls + l.len and sg.end == l.len) 0.6 * cw else 0;
    const w = sp.x1 - sp.x0 + tail;
    if (w <= 0) return;
    const r = @min(4.0, lh / 5);
    const top: f64 = if (rg[0] >= ls + sg.start) r else 0;
    const end: f64 = if (tail == 0 and rg[1] <= ls + sg.end) r else 0;
    objc.CGContextSetRGBFillColor(ctx, col[0], col[1], col[2], a);
    cornerPath(ctx, sp.x0, y, w, lh, .{ top, top, end, end });
    objc.CGContextFillPath(ctx);
}

/// Draws the find indicator over row `sg` of line `l` (which starts at byte
/// `ls`): bytes `m` of the file as an opaque pill with its glyphs redrawn
/// dark, grown by `scale` about its center and `a` opaque.
fn pillOver(k: *Ink, th: *const Theme, dark: bool, l: []const u8, ls: usize, sg: Seg, m: [2]usize, ox: f64, skip: usize, y: f64, scale: f64, a: f64) void {
    const sp = rowSpan(l, ls, sg, m, ox, skip) orelse return;
    if (sp.lo >= sp.hi) return;
    const ctx = k.ctx;
    k.flush();
    objc.CGContextSaveGState(ctx);
    const cx = (sp.x0 + sp.x1) / 2;
    const cy = y + lh / 2;
    if (scale != 1) {
        objc.CGContextTranslateCTM(ctx, cx, cy);
        objc.CGContextScaleCTM(ctx, scale, scale);
        objc.CGContextTranslateCTM(ctx, -cx, -cy);
    }
    pill(ctx, if (dark) find_dark else find_light, a, sp.x0 - 2, y + 1, sp.x1 - sp.x0 + 4, lh - 2, 3);
    const ink = mixRgb(th.fg, find_ink, a);
    const was = k.focus;
    k.focus = null;
    _ = k.run(l, sp.lo, sp.hi, sp.col, null, th, ink, sp.x0, y + baseline, 0, 1 << 16);
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

/// True while scrolling, the line band, a selection fade or the quick open
/// list still has frames to draw.
fn scenery(d: *const Doc, now: f64) bool {
    return d.ys.moving(now) or d.xs.moving(now) or d.band.moving(now) or d.band_a.moving(now) or now < d.focus_t0 + focus_time or d.focus_a.moving(now) or d.panel.moving(now) or d.lit.moving(now) or
        d.inked.moving(now) or
        d.gut.moving(now) or
        d.prompt_t.moving(now) or d.pbar.moving(now) or now < d.shake_t0 + shake_time or now < d.card_shake_t0 + shake_time or now < d.ring_t0 + ring_pulse or d.hint.moving(now) or
        d.plus_t.moving(now) or !d.pick_s.settled() or (zen(d.win) < 0.999 and tabsMoving(d, now)) or
        (d.pick_live and (now < d.rows_t0 + row_lag * 5 + row_fade or now < d.pick_t0 + xfade_time)) or
        !d.pop.settled() or now < d.prev_t0 + fade_time or now < d.stag_t0 + stag_cap + fade_time or (d.flash_n > 0 and now >= d.flash_t0 + flash_hold and now < d.flash_t0 + flash_hold + flash_time) or
        d.load.moving(now) or (d.had_sel and d.sel_in.moving(now)) or d.bar.moving(now) or
        d.sel_out.moving(now) or
        now < d.pband_t0 + fade_time or d.hint_hot_t.moving(now) or
        d.tog_t[0].moving(now) or d.tog_t[1].moving(now) or now < d.wrap_t0 + wrap_time or
        d.plist.moving(now) or d.phov_t.moving(now) or now < d.stat_t0 + fade_time;
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
        w.hov_stale = true;
        if (w.part) {
            for (docs.items) |d| if (d.win == w) moveCaret(d, now);
            return redrawSide(w);
        }
        if (w.cards_only) {
            var any = false;
            for (docs.items) |d| if (d.win == w) {
                const shaking = (now - d.card_shake_t0) / shake_time;
                if (d.busy or (shaking >= 0 and shaking < 1)) {
                    msg(void, self, "setNeedsDisplayInRect:", .{cardDirtyRect(d)});
                    any = true;
                } else moveCaret(d, now);
            };
            if (!any) msg(void, self, "setNeedsDisplay:", .{true});
            return;
        }
        return msg(void, self, "setNeedsDisplay:", .{true});
    }
    // Tabs or rows that slid under a still mouse: look again once, as
    // the motion ends.
    if (w.hov_stale) {
        w.hov_stale = false;
        hoverNow(w);
    }
    var gliding = false;
    for (docs.items) |d| if (d.win == w) {
        moveCaret(d, now);
        if (d.cx.moving(now) or d.cy.moving(now)) gliding = true;
    };
    if (!gliding) msg(void, w.link, "setPaused:", .{true});
}

/// A hold is over: one redraw, and any fade out takes it from there.
fn holdRedraw(self: Id, _: Sel, _: Id) callconv(.c) void {
    msg(void, self, "setNeedsDisplay:", .{true});
}

/// Whether two rectangles overlap.
fn hits(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

// ---- documents ----

const Mode = enum { edit, find, line, open, replace, command };
const Drag = enum { char, word, line };

/// A file held by a card, on show or parked in another tab.
const Page = struct {
    ed: Editor,
    path: ?[:0]u8 = null,
    lang: *const syntax.Lang = &syntax.plain,
    states: std.ArrayList(syntax.State) = .empty,
    stamp: ?files.Stamp = null,
    sx: f64 = 0,
    sy: f64 = 0,
    /// Its tab's id, which stays with the file while the card holds it.
    id: u32,
    /// An untitled file's draft, saved as it changes, and the
    /// `buf.changes` it last saved.
    draft: ?[:0]u8 = null,
    drafted: u64 = 0,
    draft_armed: u64 = 0,
    /// Just read from disk, so showing it rises in; set by the loaders.
    rise: bool = false,
    /// Its sidebar row's unsaved dot, 0 to 1.
    dot: Tween = .{ .dur = fade_time },
    /// An untitled file's first line, updated after typing pauses.
    title: [48]u8 = undefined,
    title_len: usize = 0,
    /// The file can't be written by this user, so its header shows a lock.
    locked: bool = false,
    /// The file didn't exist when it opened; the header says New until it's saved.
    new_file: bool = false,
    /// A blank untitled file's number when its card has another: "Untitled 2".
    num: u32 = 0,
    num_name: [24]u8 = undefined,
    num_len: usize = 0,
    /// Named by hand from its tab, so its text doesn't rename it.
    hand: bool = false,
    /// The `syntax.languages` entry picked by hand from View > Language.
    lang_i: ?u8 = null,

    fn name(p: *const Page) []const u8 {
        return if (p.path) |path| std.fs.path.basename(path) else if (p.title_len > 0) p.title[0..p.title_len] else if (p.num_len > 0) p.num_name[0..p.num_len] else "Untitled";
    }

    /// An untitled file whose text names it differently now.
    fn stale(p: *const Page) bool {
        if (p.path != null or p.hand) return false;
        if (nameRow(&p.ed) == null) return p.title_len > 0;
        var nb: [48]u8 = undefined;
        return !std.mem.eql(u8, untitledName(&p.ed, &nb), p.name());
    }

    /// Takes the name its text has now; true when it changed. With no
    /// words it goes back to "Untitled", or its number.
    fn rename(p: *Page) bool {
        if (!p.stale()) return false;
        var nb: [48]u8 = undefined;
        const nm = if (nameRow(&p.ed) == null) "" else untitledName(&p.ed, &nb);
        @memcpy(p.title[0..nm.len], nm);
        p.title_len = nm.len;
        return true;
    }

    fn number(p: *Page, n: u32) void {
        p.num = n;
        p.num_len = if (std.fmt.bufPrint(&p.num_name, "Untitled {d}", .{n})) |s| s.len else |_| 0;
    }

    /// Untitled files keep drafts, so only named files show an unsaved dot.
    fn edited(p: *const Page) bool {
        return p.path != null and p.ed.buf.dirty();
    }

    /// An untitled file with text, which its tab marks with a faint draft dot.
    fn drafting(p: *const Page) bool {
        return p.path == null and p.ed.text().len > 0;
    }

    /// Closing an untitled file also discards its draft.
    fn loses(p: *const Page) bool {
        return if (p.path == null) p.ed.text().len > 0 else p.ed.buf.dirty();
    }

    /// Closing its tab: an untitled file's draft goes too.
    fn deinit(p: *Page) void {
        p.ed.deinit(gpa);
        p.states.deinit(gpa);
        if (p.path) |s| gpa.free(s);
        dropDraft(&p.draft);
    }

    /// Dropping it while an untitled file's draft stays on disk.
    fn deinitKeepDraft(p: *Page) void {
        if (p.draft) |s| gpa.free(s);
        p.draft = null;
        p.deinit();
    }
};

pub const TabRef = struct { d: *Doc, j: usize };

/// Tabs and draft file names get ids from here.
var next_id: u32 = 1;

fn newId() u32 {
    next_id += 1;
    return next_id;
}

const Doc = struct {
    file: Page,
    /// The shown file's place among the card's tabs:
    /// `pages` are the others, in tab order with this one taken out.
    at: usize = 0,
    /// The card's other files, in tab order.
    pages: std.ArrayList(Page) = .empty,
    /// The header's tabs as drawn, folding ones included, and the active
    /// tab's highlight (x and width), which springs from tab to tab.
    slots: std.ArrayList(Slot) = .empty,
    hl: [2]Spring = @splat(.{ .k = 420, .c = 30, .eps = 0.05 }),
    /// 1 with two tabs or more, 0 with one, when the header is just the file's name.
    tabbed: Tween = .{ .dur = tab_time },
    /// How far the tabs are scrolled when they don't fit.
    tab_x: Tween = .{ .dur = scroll_time },
    slots_seen: bool = false,
    was_dirty: bool = false,
    wide_line: usize = 0,
    wide_id: u32 = 0,
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
    /// The chevron after the + while the tabs overflow, whose menu lists
    /// them all: its middle in the pane, the mouse on it, its hover
    /// highlight, and how far it's shown.
    chev_x: f64 = -100,
    chev_on: bool = false,
    chev_t: Tween = .{ .dur = fade_time },
    chev_a: Tween = .{ .dur = tab_time },
    /// The squeezed tabs' width as last drawn, and the width a click on a ×
    /// holds until the mouse leaves the tab row, so the next × slides under it.
    cap: f64 = 1e9,
    held_cap: ?f64 = null,
    /// Where the tab row starts and stops in the pane, and how far its tabs
    /// run past the room they have.
    tabs_l: f64 = 0,
    tabs_r: f64 = 1e9,
    tab_over: f64 = 0,
    /// Where a wheel scrolled the tab row to, kept while tab `tab_user_id` stays on show.
    tab_user: ?f64 = null,
    tab_user_id: u32 = 0,
    /// A tab pulsing because ⌘T found it already blank, and since when.
    pulse_id: u32 = 0,
    pulse_t0: f64 = -1,
    /// When a dropped tab last landed in the card, which pulses its ring.
    ring_t0: f64 = -1,
    /// The text the card showed before a tab switch, dissolving away over
    /// the new tab's text. Retained: see `dropDissolve`.
    dissolve: Id = null,
    /// The window this card belongs to.
    win: *Win = undefined,
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
    /// Where scrolling shows right now.
    vx: f64 = 0,
    vy: f64 = 0,
    /// Typewriter mode last centered on this caret, buffer change and text height.
    center_at: usize = std.math.maxInt(usize),
    center_changes: u64 = 0,
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
    /// The line numbers' width in columns, and in points as drawn (eased, and
    /// scaled away by zen).
    gut: Tween = .{ .dur = tab_time },
    gw: f64 = 0,
    had_sel: bool = false,
    sel_in: Tween = .{ .dur = fade_time, .from = 1, .to = 1 },
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
    prev_picks: [max_picks]usize = undefined,
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
    /// The status strip's line, made again when what it shows changes; it's
    /// cut with an ellipsis to the room.
    stat: Id = null,
    /// What `stat` was made for (caret, anchor, changes, doc, length, room,
    /// and the language, indent and line endings).
    stat_at: [7]u64 = @splat(std.math.maxInt(u64)),
    stat_w: f64 = 0,
    /// The line `stat` replaced when what the strip says changed in kind
    /// (another tab, a selection, a language), fading out from `stat_t0`,
    /// and how wide it was; `stat_kind` is the kind the strip says now.
    stat_old: Id = null,
    stat_old_w: f64 = 0,
    stat_t0: f64 = -1e9,
    stat_kind: u64 = 0,
    /// Where "Ln, Col" starts in the pane (-1 while the strip is hidden) and
    /// how wide it is: a click there opens Go to Line.
    stat_x: f64 = -1,
    stat_ln_w: f64 = 0,
    /// Find has no matches, and when its words last shook for it.
    nomatch: bool = false,
    shake_t0: f64 = -1,
    /// The scroll bar's opacity, when the page last moved, where it was, and
    /// the move its hold timer is armed for.
    bar: Tween = .{ .dur = bar_time },
    bar_t0: f64 = 0,
    bar_vy: f64 = 0,
    bar_armed: f64 = -1,
    /// The horizontal bar: the sideways scroll it last saw, and the
    /// longest line's length in bytes, worked out again after edits.
    bar_vx: f64 = 0,
    wide: usize = 0,
    wide_chg: u64 = std.math.maxInt(u64),
    /// The pointer is near the card's right or bottom edge, which shows the bars.
    bar_hover: bool = false,
    /// A bar's knob held by the mouse, and where on the knob it was grabbed.
    bar_drag: enum { none, v, h } = .none,
    bar_off: f64 = 0,
    /// Where the bars last drew, in pane coordinates: knob and track for each.
    vknob: Rect = .{},
    vtrack: Rect = .{},
    hknob: Rect = .{},
    htrack: Rect = .{},
    /// How far the text scrolls sideways at most, as the horizontal bar last drew.
    hmax: f64 = 0,
    cx: Tween = .{ .dur = caret_time },
    cy: Tween = .{ .dur = caret_time },
    /// The caret tween is in page coordinates (else window coordinates).
    c_text: bool = true,
    /// The last draw had scenery still moving.
    busy: bool = false,
    /// Soft wrap: the first screen row of each line, plus the total at the
    /// end, for rows `wraps_cols` cells wide.
    vfirst: std.ArrayList(u32) = .empty,
    mode: Mode = .edit,
    prompt: std.ArrayList(u8) = .empty,
    /// Find and replace: the replacement, and which field takes typing.
    with: std.ArrayList(u8) = .empty,
    which: u1 = 0,
    /// Each prompt field's caret and anchor in bytes ([0] the search, line,
    /// path or command, [1] the replacement), and how far it's scrolled
    /// sideways, in columns.
    pcur: [2]usize = .{ 0, 0 },
    panc: [2]usize = .{ 0, 0 },
    pscroll: [2]usize = .{ 0, 0 },
    /// Where each field's text starts in the pane, as last drawn, for clicks.
    pfx: [2]f64 = .{ 0, 0 },
    /// The mouse went down in a field and is selecting, by words after a
    /// double-click, from the word it went down on.
    pdrag: bool = false,
    pdrag_word: bool = false,
    pdrag_from: [2]usize = .{ 0, 0 },
    /// The fields' undo and redo steps, and whether the last edit was
    /// typing, which the next letter joins.
    pundo: std.ArrayList(PromptStep) = .empty,
    predo: std.ArrayList(PromptStep) = .empty,
    ptyping: bool = false,
    /// Recent-query browsing with ↑ and ↓: how far back (an index into the
    /// field's history), and what was typed before it began.
    hist_at: ?usize = null,
    hist_draft: std.ArrayList(u8) = .empty,
    /// The field's selection band as last drawn, for fading out: its left
    /// edge and width, whether it was showing, and when it began to fade.
    pband_x: f64 = 0,
    pband_w: f64 = 0,
    pband_shown: bool = false,
    pband_t0: f64 = -1e9,
    /// The last find, for find next and previous.
    query: std.ArrayList(u8) = .empty,
    /// Where the caret was when find opened, and the selection and scroll
    /// then, which Escape goes back to unless Return or ⌘G stepped to a match.
    origin: usize = 0,
    origin_sel: [2]usize = .{ 0, 0 },
    origin_sy: f64 = 0,
    stepped: bool = false,
    /// When find last wrapped past the file's end or its start.
    wrap_t0: f64 = -1e9,
    /// Find's match-case and whole-word pills: where each drew (x and
    /// width, in the pane) and how lit it is.
    tog_x: [2][2]f64 = @splat(.{ 0, 0 }),
    tog_t: [2]Tween = @splat(.{ .dur = fade_time }),
    /// Find's ticks along the card's right edge: the screen row of each
    /// match, and what they were found for.
    ticks: std.ArrayList(u32) = .empty,
    ticks_key: u64 = 0,
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
    picks: [max_picks]usize = undefined,
    npicks: usize = 0,
    pick: usize = 0,
    /// How many names match the typing in all, of which `picks` are the best.
    pmatches: usize = 0,
    /// How far the list is scrolled, in points, gliding as the pick moves
    /// past its ends; and where its first row's top drew in the pane.
    plist: Tween = .{ .dur = scroll_time },
    plist_top: f64 = 0,
    /// The list row under the mouse, the row its highlight is on, and how
    /// far that has faded in.
    phover: ?usize = null,
    phov_row: usize = 0,
    phov_t: Tween = .{ .dur = fade_time },
    /// The list shows menu commands (⌘K) rather than files.
    palette: bool = false,
    drag: Drag = .char,
    drag_from: [2]usize = .{ 0, 0 },
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
    /// The caret has the keys (else it draws hollow), its edge fade as last
    /// set, its color, and how many cells the character under it takes.
    caret_on: bool = true,
    caret_a: f64 = 1,
    caret_ink: Rgb = .{ 0, 0, 0 },
    caret_cells: usize = 1,
    /// The bracket pair beside the caret, for the caret and change count it was found at.
    br: ?[2]usize = null,
    br_at: [2]u64 = @splat(std.math.maxInt(u64)),
    /// What the caret last stood for: mode, then row and column or prompt width.
    spot: [3]usize = .{ std.math.maxInt(usize), 0, 0 },
    shown: bool = false,
    /// Place the caret without gliding (mouse drags).
    snap: bool = false,
    /// The card's fade-in: rising when its file was just read from disk, else
    /// a plain fade. The caret fades in with it.
    load: Tween = .{ .dur = load_time, .from = 1, .to = 1 },
    caret_fade: bool = false,
    /// An empty card's hint: its opacity, and since when the card has
    /// been blank (-1 when it isn't).
    hint: Tween = .{ .dur = hint_in },
    blank_t0: f64 = -1,
    /// The header's folder line and its chevron positions.
    head: Head = .{},
    /// The empty card's clickable lines: where each drew in the pane, what it
    /// does, the one under the mouse, and that one's highlight.
    hints: [max_hints]Hint = undefined,
    hint_n: usize = 0,
    hint_hot: ?usize = null,
    hint_lit: usize = 0,
    hint_hot_t: Tween = .{ .dur = fade_time },
    dissolve_rep: Id = null,
    dissolve_w: f64 = 0,
    dissolve_h: f64 = 0,
    dissolve_scale: f64 = 0,
    wrap_ptr: usize = 0,
    wrap_len: usize = 0,
    wrap_chg: u64 = std.math.maxInt(u64),
    wrap_cols: usize = 0,
    wrap_tw: usize = 0,
    wrap_hang: bool = false,
    wrap_segs: std.ArrayList(Seg) = .empty,

    /// Unsaved changes to a file, on show or in any page. Untitled files
    /// keep themselves as drafts, so they don't count.
    fn dirty(d: *Doc) bool {
        for (0..tabCount(d)) |j| if (tabPage(d, j).edited()) return true;
        return false;
    }

    fn deinit(d: *Doc) void {
        d.file.deinit();
        d.prompt.deinit(gpa);
        d.with.deinit(gpa);
        d.held.deinit(gpa);
        d.held_with.deinit(gpa);
        d.query.deinit(gpa);
        d.hist_draft.deinit(gpa);
        d.ticks.deinit(gpa);
        dropSteps(&d.pundo);
        dropSteps(&d.predo);
        d.pundo.deinit(gpa);
        d.predo.deinit(gpa);
        for (&d.lex) |*x| x.deinit();
        d.vfirst.deinit(gpa);
        d.wrap_segs.deinit(gpa);
        dropDissolve(d);
        if (d.dissolve_rep != null) msg(void, d.dissolve_rep, "release", .{});
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
    edited: bool = false,
    /// The last draw had scenery still moving.
    busy: bool = false,
    /// The look, dark or not, until it next changes.
    dark: ?bool = null,
    /// What `fitTitlebar` measured, for the window's size it was measured at.
    tb: struct { ok: bool = false, w: f64 = 0, h: f64 = 0, head: f64 = 0, toggle: f64 = 0, tabs: f64 = 0, radius: f64 = 0 } = .{},
    /// Motion ran since the hover was last resolved, so `tick` looks it up
    /// again when the motion ends.
    hov_stale: bool = false,
    /// Only the sidebar's strip has frames to draw, so `tick` redraws just that.
    part: bool = false,
    /// Only one or more cards have frames to draw, so `tick` invalidates just their rects.
    cards_only: bool = false,
    /// How far the sidebar is scrolled.
    side_y: f64 = 0,
    /// The mouse went down outside the cards' text (the sidebar, the title
    /// band, a gap), so drags don't select text.
    side_down: bool = false,
    /// Where a text selection drag last was in the view, while the button
    /// is down, so a pointer held above or below the text goes on scrolling.
    sel_at: ?Point = null,
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
    /// How far from the gap's middle the mouse took hold of it, so the gap
    /// doesn't jump to center under the pointer.
    grab_off: f64 = 0,
    /// The split whose gap just snapped to 1/2, 1/3 or 2/3, and when, for
    /// the guide that flashes along it.
    guide: ?*Node = null,
    guide_t0: f64 = -1,
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
    /// The sidebar's selected row and its highlight.
    sel: Mark = .{ .s = .{ .k = 420, .c = 30, .eps = 0.05 } },
    sel_id: u32 = 0,
    /// The selected name and the one it left, kept during the hop.
    bold: [2]Bold = .{ .{}, .{} },
    /// The button by the traffic lights (1), the sidebar's + (2) or the
    /// folder's name at the sidebar's top (4) under the mouse, and each
    /// one's hover highlight.
    hot: u8 = 0,
    hot_t: [3]Tween = @splat(.{ .dur = fade_time }),
    /// The button the mouse pressed, 1, 2 or 4 like `hot`, and its fill, there
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
    z: Spring = .{ .k = 200, .c = 28 },
    lights_a: f64 = 1,
    /// The lights peeking back in Zen: 1 while the mouse is in the window's
    /// top-left corner and for a hold after it leaves (`peek_out`).
    peek: Tween = .{ .dur = 0.2 },
    peek_in: bool = false,
    peek_out: f64 = 0,
    /// The sidebar row under the mouse and its highlight.
    hov: Mark = .{ .s = .{ .k = 700, .c = 53, .eps = 0.05 } },
    /// The pinned folder under the mouse (a tree row) and its highlight, which
    /// fades on `pin_row` after the mouse leaves it.
    hov_pin: ?usize = null,
    pin_row: usize = 0,
    pin_t: Tween = .{ .dur = fade_time },
    /// The folder's name at the sidebar's top, as wide as it last drew.
    head_w: f64 = 0,
    /// The sidebar takes the arrow keys, Return and typing: the row its
    /// outline is on (of tree `side_cur_gen`), and the outline's spring.
    side_key: bool = false,
    side_cur: ?usize = null,
    side_cur_gen: u32 = 0,
    kc: Mark = .{ .s = .{ .k = 700, .c = 53, .eps = 0.05 } },
    /// Letters typed in the sidebar pick the next row starting with them;
    /// a pause starts a new name.
    seek: [32]u8 = undefined,
    seek_len: usize = 0,
    seek_t: f64 = 0,
    /// Files from Finder are over the window, and its outline for them.
    drop_on: bool = false,
    drop_t: Tween = .{ .dur = fade_time },
    /// A short message in a pill near the window's bottom: it fades in, holds
    /// for `toast_hold` and fades out.
    toast_buf: [160]u8 = undefined,
    toast_len: usize = 0,
    toast_t0: f64 = -1e9,
    toast_t: Tween = .{ .dur = fade_time },
    toast_line: Id = null,
    /// The sidebar button's alpha: dimmed while the sidebar is on but the
    /// window is too narrow to show it.
    tog_dim: Tween = .{ .dur = fade_time, .from = 1, .to = 1 },
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
    /// Going back where it came from, it rides the tabs' spring, 0 to 1,
    /// instead of easing over `fly_time`.
    spring: bool = false,
    sp: Spring = .{ .k = 420, .c = 30 },
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
/// How long a snapped gap's guide shows.
const guide_time = 0.45;
/// A tab that ⌘T found blank pulses this long, and so does a card's ring
/// when a dropped tab lands in it.
const pulse_time = 0.5;
const ring_pulse = 0.4;
/// A drop zone holds on this many points past its edge, so a pointer on
/// the border doesn't flicker between zones.
const zone_slack = 6.0;

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
    w: f64 = 0,
    icon: Id = null,
    cmd: bool = false,
    /// The sidebar row it came from, which dims while it's out.
    row: ?usize = null,
    /// The tab's place in its row when the mouse went down, where ⎋ puts it back.
    start: usize = 0,
};

var wins: std.ArrayList(*Win) = .empty;
/// The dragged copy's shadow, light and dark: darker on dark cards, where a
/// faint one doesn't show.
var ghost_shades: [2]Id = .{ null, null };

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
    /// Its share before Maximize Card took it, to go back to.
    held: ?f64 = null,
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
        if (!sideShown(d.win)) startPrompt(d, .open);
        return;
    }
    defer gpa.free(abs);
    if (holder(abs)) |h| {
        showTab(h.d, h.j);
        return front(h.d);
    }
    var pg = loadPage(abs) orelse return;
    const d = into orelse newDoc() orelse return pg.deinit();
    putTab(d, pg, d.at + 1);
    noteRecent(abs);
    front(d);
}

/// Opens into the key window's untouched card, else a new window.
pub fn openFile(path: []const u8) void {
    open(path, blankDoc());
}

/// The first live card and tab holding `abs`.
fn holder(abs: []const u8) ?TabRef {
    for (docs.items) |d| {
        if (d.closing) continue;
        for (0..tabCount(d)) |j| {
            const p = tabPage(d, j);
            if (p.path != null and std.mem.eql(u8, p.path.?, abs)) return .{ .d = d, .j = j };
        }
    }
    return null;
}

/// Brings `d`'s window forward with `d` as its focused card.
fn front(d: *Doc) void {
    focus(d);
    showWin(d.win.window);
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
    redrawSide(w);
}

/// Reads a file into a page, at the caret and scroll it had last time. A
/// path with no file yet opens empty, as a new file.
fn loadPage(abs: [:0]const u8) ?Page {
    var missing = false;
    const bytes = files.read(gpa, abs) catch |err| switch (err) {
        error.FileNotFound => blk: {
            missing = true;
            break :blk gpa.alloc(u8, 0) catch return null;
        },
        else => {
            var ib: [std.fs.max_path_bytes + 160]u8 = undefined;
            const why = if (err == error.NotAFile) "It isn't a regular file" else if (err == error.FileTooBig) "It's bigger than 1 GB" else osError();
            alert("Couldn't open this file.", std.fmt.bufPrint(&ib, "{s}.\n\n{s}", .{ why, abs }) catch abs);
            return null;
        },
    };
    if (looksBinary(bytes)) {
        gpa.free(bytes);
        alert("This looks like a binary file.", abs);
        return null;
    }
    var ed = Editor.initOwned(gpa, bytes) catch return null;
    styleEditor(&ed);
    const z = gpa.dupeSentinel(u8, abs, 0) catch {
        ed.deinit(gpa);
        return null;
    };
    const t = ed.text();
    var sy: f64 = 0;
    if (placeOf(abs)) |pl| {
        const c = editor.charStart(t, @min(pl.cur, t.len));
        ed.select(c, c);
        sy = pl.sy;
    }
    return .{ .ed = ed, .path = z, .lang = syntax.detect(abs, firstLine(t)), .stamp = files.stamp(abs), .sy = sy, .id = newId(), .rise = true, .new_file = missing, .locked = !missing and !files.writable(abs) };
}

/// The text's first line, which `syntax.detect` reads for a `#!` or `<?php`.
fn firstLine(t: []const u8) []const u8 {
    return t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
}

/// The page's language for `path`: the one picked by hand, else what its
/// name or first line says.
fn langOf(p: *const Page, path: []const u8) *const syntax.Lang {
    if (p.lang_i) |i| return syntax.languages[i].lang;
    return syntax.detect(path, firstLine(p.ed.text()));
}

fn blankPage() ?Page {
    var ed = Editor.init(gpa, "") catch return null;
    styleEditor(&ed);
    return .{ .ed = ed, .id = newId() };
}

/// Gives an editor the settings' tab width, and their indent when its text
/// doesn't show one of its own.
fn styleEditor(ed: *Editor) void {
    ed.tab_width = conf.tab_width;
    const m = editor.indentMarks(&ed.buf);
    if (!m.tab and !m.two) {
        ed.indent = if (conf.indent_with == .tabs) "\t" else "    ";
    }
}

fn isBlank(d: *const Doc) bool {
    return d.file.path == null and d.file.ed.text().len == 0;
}

/// The card's only tab is an empty untitled file, which the next file it
/// opens takes the place of. An empty one beside other tabs stays until
/// it's closed.
fn replaceable(d: *const Doc) bool {
    return isBlank(d) and d.pages.items.len == 0;
}

/// Sets the card's file aside as a page in its tab's place, for
/// `install` to replace right after. A `replaceable` file is dropped
/// instead. False when it can't.
fn park(d: *Doc) bool {
    if (replaceable(d)) {
        d.file.deinit();
        return true;
    }
    // Flush its name so its tab shows the name its text has now.
    retitle(d);
    d.pages.insert(gpa, d.at, asPage(d)) catch return false;
    rememberPlace(&d.file);
    return true;
}

/// Shows `pg` in the card, which must have just been parked, and picks
/// up a change another app made to it.
fn install(d: *Doc, pg: Page) void {
    d.file = pg;
    d.center_at = std.math.maxInt(usize);
    for (&d.lex) |*x| x.clear();
    d.vfirst.clearRetainingCapacity();
    d.wrap_ptr = 0;
    d.mode = .edit;
    d.ys.snap(d.file.sy);
    d.xs.snap(d.file.sx);
    d.band_on = false;
    d.had_sel = false;
    d.focus_on = false;
    d.sel_out.snap(0);
    d.snap = true;
    d.drag = .char;
    d.drag_from = .{ 0, 0 };
    d.cur_m = null;
    d.prev_t0 = -1e9;
    d.jumped = false;
    d.pop.snap(0);
    d.flash_n = 0;
    d.gut.snap(gutCols(d));
    const now = CACurrentMediaTime();
    d.load.snap(if (pg.rise) 0 else swap_from);
    d.load.aimOver(1, if (pg.rise) load_time else fade_time, now);
    d.caret_fade = true;
    var rebuilt = false;
    if (d.file.path) |p| if (relOf(p)) |rel| {
        revealFile(rel);
        if (d.win.focus == d) d.win.side_find = true;
    };
    if (!restoring and tree_stale) {
        rebuildTree();
        rebuilt = true;
    }
    named(d);
    if (!restoring) {
        if (rebuilt) refreshAll() else refreshWin(d.win);
        checkOutside(d);
    }
}

/// Takes page `tab` out of the pages and shows it in the card, whose
/// file must have just been parked or gone.
fn swapIn(d: *Doc, tab: usize) void {
    const pg = d.pages.orderedRemove(tab);
    d.at = tab;
    install(d, pg);
}

/// `swapIn` for the tab right of the one that's going, or the left one at the end.
fn swapNext(d: *Doc) void {
    swapIn(d, if (d.at < d.pages.items.len) d.at else d.at - 1);
}

/// Takes the page of tab `j`, which isn't on show, out of the pages.
fn dropPage(d: *Doc, j: usize) Page {
    const pg = d.pages.orderedRemove(pageOf(d, j));
    if (j < d.at) d.at -= 1;
    return pg;
}

// ---- tabs ----

fn tabCount(d: *const Doc) usize {
    return d.pages.items.len + 1;
}

/// The page that tab `j` holds; the active tab has none.
fn pageOf(d: *const Doc, j: usize) usize {
    return if (j < d.at) j else j - 1;
}

fn tabPage(d: *Doc, j: usize) *Page {
    return if (j == d.at) &d.file else &d.pages.items[pageOf(d, j)];
}

/// The file on show as a page, for moving it; the card still points at it.
fn asPage(d: *const Doc) Page {
    var pg = d.file;
    pg.rise = false;
    return pg;
}

fn tabIndex(d: *Doc, id: u32) ?usize {
    for (0..tabCount(d)) |j| if (tabPage(d, j).id == id) return j;
    return null;
}

/// Shows tab `j`. The file it had keeps its tab, even an empty untitled
/// one: with another tab there `park` never drops it.
fn showTab(d: *Doc, j: usize) void {
    if (j == d.at) return;
    if (!park(d)) return;
    swapIn(d, j);
}

/// `showTab` for a switch the user asked for (a click, ⌃Tab, ⌘1): the text
/// on show dissolves into the new tab's, which shows at full strength under it.
fn switchTab(d: *Doc, j: usize) void {
    if (j == d.at) return;
    const crossed = dissolveFrom(d);
    showTab(d, j);
    if (crossed) d.load.snap(1);
}

/// Lays a picture of card `d`'s text as it shows now over the card, and
/// fades it out: what draws under it next shows through. False when the
/// card isn't on screen to take a picture of.
fn dissolveFrom(d: *Doc) bool {
    const w = d.win;
    if (restoring or d.closing or !d.slots_seen or !msg(bool, w.window, "isVisible", .{})) return false;
    const r: Rect = .{ .x = d.org.x + gap, .y = d.org.y + top_h, .w = @max(d.size.x - 2 * gap, 0), .h = @max(bottom(d) - top_h, 0) };
    if (r.w < 1 or r.h < 1) return false;
    dropDissolve(d);
    const scale = @max(msg(f64, w.window, "backingScaleFactor", .{}), 1);
    const rep = if (d.dissolve_rep != null and d.dissolve_w == r.w and d.dissolve_h == r.h and d.dissolve_scale == scale)
        d.dissolve_rep
    else blk: {
        if (d.dissolve_rep != null) {
            msg(void, d.dissolve_rep, "release", .{});
            d.dissolve_rep = null;
        }
        const created = msg(Id, w.view, "bitmapImageRepForCachingDisplayInRect:", .{r});
        if (created == null) return false;
        d.dissolve_rep = msg(Id, created, "retain", .{});
        d.dissolve_w = r.w;
        d.dissolve_h = r.h;
        d.dissolve_scale = scale;
        break :blk d.dissolve_rep;
    };
    msg(void, w.view, "cacheDisplayInRect:toBitmapImageRep:", .{ r, rep });
    const img = msg(Id, rep, "CGImage", .{});
    if (img == null) return false;
    const layer = msg(Id, objc.class("CALayer"), "layer", .{});
    const t = objc.class("CATransaction");
    msg(void, t, "begin", .{});
    msg(void, t, "setDisableActions:", .{true});
    msg(void, layer, "setFrame:", .{r});
    msg(void, layer, "setContents:", .{img});
    msg(void, layer, "setOpacity:", .{@as(f32, 0)});
    msg(void, msg(Id, w.view, "layer", .{}), "insertSublayer:below:", .{ layer, d.caret });
    msg(void, t, "commit", .{});
    const num = objc.class("NSNumber");
    const a = msg(Id, objc.class("CABasicAnimation"), "animationWithKeyPath:", .{objc.str("opacity")});
    msg(void, a, "setFromValue:", .{msg(Id, num, "numberWithDouble:", .{@as(f64, 1)})});
    msg(void, a, "setToValue:", .{msg(Id, num, "numberWithDouble:", .{@as(f64, 0)})});
    msg(void, a, "setDuration:", .{@as(f64, fade_time)});
    msg(void, a, "setTimingFunction:", .{msg(Id, objc.class("CAMediaTimingFunction"), "functionWithName:", .{objc.str("easeInEaseOut")})});
    msg(void, layer, "addAnimation:forKey:", .{ a, objc.str("fade") });
    d.dissolve = msg(Id, layer, "retain", .{});
    // `d.caret` stands in for the card: `later` needs a per-card object to cancel by.
    objc.later(w.view, "endDissolve:", d.caret, fade_time + 0.05);
    return true;
}

fn dropDissolve(d: *Doc) void {
    const l = d.dissolve orelse return;
    d.dissolve = null;
    msg(void, l, "removeFromSuperlayer", .{});
    msg(void, l, "release", .{});
}

/// A dissolve is over: its picture goes.
fn endDissolve(_: Id, _: Sel, caret: Id) callconv(.c) void {
    for (docs.items) |d| if (d.caret == caret) dropDissolve(d);
}

/// ⌃Tab and ⌃⇧Tab: the next or previous tab, around the ends.
pub fn stepTab(d: *Doc, by: isize) void {
    const n: isize = @intCast(tabCount(d));
    switchTab(d, @intCast(@mod(@as(isize, @intCast(d.at)) + by, n)));
}

/// ⌘1 to ⌘8 show that tab, when there is one; ⌘9 the last.
fn jumpTab(d: *Doc, i: usize) void {
    const n = tabCount(d);
    if (i == 8) return switchTab(d, n - 1);
    if (i < n) switchTab(d, i);
}

/// ⌘T: an untitled file in a new tab right of the one on show, numbered
/// when the card already has a blank one. When the file on show is blank
/// already its tab pulses instead.
fn newTab(d: *Doc) void {
    if (isBlank(d)) {
        d.pulse_id = d.file.id;
        d.pulse_t0 = CACurrentMediaTime();
        return refresh(d);
    }
    var pg = blankPage() orelse return;
    var top: u32 = 0;
    var blank = false;
    for (0..tabCount(d)) |j| {
        const p = tabPage(d, j);
        if (p.path != null or p.title_len > 0 or p.hand) continue;
        blank = true;
        top = @max(top, @max(p.num, 1));
    }
    if (blank) pg.number(top + 1);
    putTab(d, pg, d.at + 1);
}

/// Files whose tabs closed, the newest last, for Reopen Closed Tab.
var closed: std.ArrayList([:0]u8) = .empty;
const max_closed = 20;

fn noteClosed(p: *const Page) void {
    const path = p.path orelse return;
    const own = gpa.dupeSentinel(u8, path, 0) catch return;
    if (closed.items.len >= max_closed) gpa.free(closed.orderedRemove(0));
    closed.append(gpa, own) catch gpa.free(own);
}

/// File > Reopen Closed Tab: the last closed file that's still on disk
/// opens again in the card, or comes forward where a card has it.
fn reopenTab(d: *Doc) void {
    while (closed.pop()) |p| {
        defer gpa.free(p);
        if (!files.exists(p)) continue;
        return open(p, d);
    }
    toast(d.win, "no closed tabs");
}

/// Closes tab `j`, asking first when it has unsaved changes. A card's last
/// tab folds the card away, or closes the window when it's the only card.
/// The tab to the right takes the active one's place, or the one to the
/// left at the end. A tab in the background asks from where it is: the tab
/// on show stays on show, and the one asked about is outlined.
fn closeTab(d: *Doc, at: usize) void {
    if (tabCount(d) == 1) {
        // The card next to it may still be folding away: finish that first,
        // so closing the last card left closes the window.
        endSiblingFold(d);
        if (d.win.cards.pane != null) return msg(void, d.win.window, "performClose:", .{@as(Id, null)});
        if (d.file.loses() and !keepOrDrop(d)) return;
        noteClosed(&d.file);
        return foldCard(d);
    }
    var j = at;
    if (tabPage(d, j).loses()) {
        if (j == d.at) {
            if (!keepOrDrop(d)) return;
            // A Save As can close tabs left of it, so take its place after saving.
            j = d.at;
        } else {
            const keep = d.file.id;
            const id = tabPage(d, j).id;
            switch (askSaveTab(d, j)) {
                1000 => {
                    showTab(d, j);
                    if (d.at != j or !save(d, false)) return;
                    showTab(d, tabIndex(d, keep) orelse d.at);
                },
                1001 => {},
                else => return,
            }
            j = tabIndex(d, id) orelse return;
        }
        if (tabCount(d) == 1) return closeTab(d, j);
    }
    var pg = takeTab(d, j) orelse return;
    noteClosed(&pg);
    pg.deinit();
}

/// Asks whether to save the file on show before it goes. False to keep it.
fn keepOrDrop(d: *Doc) bool {
    return switch (askSave(d, d.file.name(), 1)) {
        1000 => save(d, false),
        1001 => true,
        else => false,
    };
}

/// Asks whether to save card `d`'s tab `j`, which isn't on show, with that
/// tab outlined while the question is up.
fn askSaveTab(d: *Doc, j: usize) isize {
    const w = d.win;
    const pg = tabPage(d, j);
    w.menu_row = null;
    w.menu_card = d;
    w.menu_tab = pg.id;
    w.menu_a.snap(0);
    w.menu_a.aim(1, CACurrentMediaTime());
    redrawMenuMark(w);
    defer {
        w.menu_a.aim(0, CACurrentMediaTime());
        redrawMenuMark(w);
    }
    return askSave(d, pg.name(), 1);
}

/// Drops the header's lines, and when `d` is its window's focused card,
/// titles the window after its file.
fn named(d: *Doc) void {
    dropHead(d);
    retitle(d);
    if (d.win.focus != d) return;
    msg(void, d.win.window, "setTitle:", .{objc.str(d.file.name())});
    // Window menu, Mission Control and the Dock show the title; the card's header shows the name.
    const url = if (d.file.path) |p| msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(p)}) else null;
    msg(void, d.win.window, "setRepresentedURL:", .{url});
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
        // No room: the card shakes and the trackpad taps, without a beep.
        d.card_shake_t0 = CACurrentMediaTime();
        haptic(.level);
        return refresh(d);
    };
    if (tabCount(d) > 1) {
        putTab(e, takeTab(d, d.at).?, 0);
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
    msg(void, d.win.window, "invalidateCursorRectsForView:", .{d.win.view});
    return e;
}

/// Takes tab `j` out of card `d`, edits and all. When it's the tab on show,
/// the tab to its right takes its place; a card's last tab leaves it with
/// a blank untitled file, for the caller to fold away.
fn takeTab(d: *Doc, j: usize) ?Page {
    if (j != d.at) {
        const pg = dropPage(d, j);
        refreshWin(d.win);
        return pg;
    }
    const pg = asPage(d);
    rememberPlace(&pg);
    if (tabCount(d) == 1) {
        install(d, blankPage() orelse return null);
    } else {
        swapNext(d);
    }
    return pg;
}

/// Puts `pg` in card `e` as its tab `k` (or last) and shows it. A blank
/// untitled file on show in `e` makes way for it. A page it can't take keeps
/// its draft on disk.
fn putTab(e: *Doc, pg: Page, k: usize) void {
    if (!park(e)) {
        var p = pg;
        return p.deinitKeepDraft();
    }
    e.at = @min(k, e.pages.items.len);
    install(e, pg);
}

/// Moves card `d`'s tab `j` to place `k` among its tabs. The other tabs
/// slide over to make room.
fn reorderTab(d: *Doc, j: usize, k: usize) void {
    if (j == k) return;
    const id = tabPage(d, j).id;
    if (j == d.at) {
        d.at = k;
    } else {
        const pg = dropPage(d, j);
        if (k <= d.at) {
            d.pages.insert(gpa, k, pg) catch return;
            d.at += 1;
        } else d.pages.insert(gpa, k - 1, pg) catch return;
    }
    // Each tab slides from where it's drawn now to its new place.
    for (d.slots.items) |*s| s.flip = s.x + s.shift.x;
    const i = slotOf(d, id) orelse return;
    const s = d.slots.orderedRemove(i);
    const at = if (k + 1 < tabCount(d)) slotOf(d, tabPage(d, k + 1).id) orelse 0 else d.slots.items.len;
    d.slots.insert(gpa, at, s) catch {};
    refresh(d);
}

/// Snaps shut the fold of `d`'s sibling card, if one is under way, and
/// takes the folded card out.
fn endSiblingFold(d: *Doc) void {
    const w = d.win;
    const leaf = nodeOf(w.cards, d) orelse return;
    const up = leaf.up orelse return;
    const g = up.going orelse return;
    if (up.kids[g] == leaf) return;
    up.share.snap(up.share.to);
    dropFolded(w, w.cards);
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
    msg(void, d.win.window, "invalidateCursorRectsForView:", .{d.win.view});
}

fn nodeOf(n: *Node, d: *const Doc) ?*Node {
    if (n.pane) |p| return if (p == d) n else null;
    return nodeOf(n.kids[0], d) orelse nodeOf(n.kids[1], d);
}

/// The first card under `n` that isn't folding away.
fn firstPane(n: *const Node) *Doc {
    if (n.pane) |p| return p;
    return firstPane(n.kids[if (n.going) |g| 1 - g else 0]);
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
        if (w.focus == gone.pane.?) focus(firstPane(keep));
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
        w.guide = null;
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
    rememberPlace(&d.file);
    dropDissolve(d);
    msg(void, d.caret, "removeFromSuperlayer", .{});
    access.drop(d);
    if (std.mem.indexOfScalar(*Doc, docs.items, d)) |i| _ = docs.orderedRemove(i);
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
    return gapRectAt(n, n.share.x);
}

/// The gap of split `n` at share `s`, in the view.
fn gapRectAt(n: *const Node, s: f64) Rect {
    const b = divide(n.r, s, n.down)[1];
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

fn gapLimits(n: *const Node) struct { len: f64, lo: f64 } {
    const len = @max((if (n.down) n.r.h else n.r.w) - 3 * gap, 1);
    return .{ .len = len, .lo = @min(0.5, (if (n.down) min_card_h else min_card_w) / len) };
}

/// Moves split `n`'s gap to `p`, keeping each side's card a usable size.
fn dragGap(w: *Win, n: *Node, p: Point) void {
    const lim = gapLimits(n);
    const len = lim.len;
    var at = (if (n.down) p.y - n.r.y else p.x - n.r.x) - 1.5 * gap - w.grab_off;
    const lo = lim.lo * len;
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
    // Arriving on 1/2, 1/3 or 2/3 flashes a faint guide along the gap.
    if (hit >= 3 and hit != w.grab_hit) {
        w.guide = n;
        w.guide_t0 = now;
    }
    // The share eases into and out of a snap point, and tracks the mouse 1:1 otherwise.
    if (hit != w.grab_hit and (hit >= 3 or w.grab_hit >= 3)) w.grab_ease = now + snap_ease;
    w.grab_hit = hit;
    const to = at / len;
    if (now >= w.grab_ease) n.share.x += to - n.share.to;
    n.share.aim(to, now);
    msg(void, if (hit == 1 or hit == 2) limitCursor(n.down, hit == 1) else resizeCursor(n.down), "set", .{});
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// Lets go of a gap dragged past its limit: the share springs back, and
/// the trackpad taps.
fn releaseGap(n: *Node, now: f64) void {
    const lim = gapLimits(n);
    const to = std.math.clamp(n.share.to, lim.lo, 1 - lim.lo);
    if (to != n.share.to) haptic(.level);
    n.share.aim(to, now);
}

/// The gaps' cursors: left-right between cards side by side, up-down
/// between cards one above the other. Each reaches the same few points
/// either side as `gapAt`, where the gap is headed.
fn gapCursors(view: Id, n: *const Node) void {
    if (n.pane != null) return;
    if (n.going == null) {
        const g = gapRectAt(n, n.share.to);
        msg(void, view, "addCursorRect:cursor:", .{ Rect{ .x = g.x - 3, .y = g.y - 3, .w = g.w + 6, .h = g.h + 6 }, resizeCursor(n.down) });
    }
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

/// ⌥⌘ and an arrow: typing moves to the nearest card that way, the one
/// most in line with this one first.
fn focusToward(d: *Doc, dir: Zone) void {
    var list: [64]*Doc = undefined;
    const n = listPanes(d.win.cards, &list, 0);
    const cx = d.org.x + d.size.x / 2;
    const cy = d.org.y + d.size.y / 2;
    var best: ?*Doc = null;
    var score = std.math.inf(f64);
    for (list[0..n]) |o| if (o != d) {
        const dx = o.org.x + o.size.x / 2 - cx;
        const dy = o.org.y + o.size.y / 2 - cy;
        const v: [2]f64 = switch (dir) {
            .left => .{ -dx, dy },
            .right => .{ dx, dy },
            .top => .{ -dy, dx },
            .bottom => .{ dy, dx },
            .tabs, .whole => return,
        };
        if (v[0] < 1) continue;
        const sc = v[0] + 2 * @abs(v[1]);
        if (sc < score) {
            score = sc;
            best = o;
        }
    };
    if (best) |o| focus(o);
}

/// Close Card: the card and all its tabs, asking first about unsaved ones.
/// A window's only card closes the window.
fn closeCard(d: *Doc) void {
    endSiblingFold(d);
    if (d.win.cards.pane != null) return msg(void, d.win.window, "performClose:", .{@as(Id, null)});
    var n: usize = 0;
    var one: usize = 0;
    for (0..tabCount(d)) |j| if (tabPage(d, j).loses()) {
        n += 1;
        one = j;
    };
    if (n > 0) {
        if (n == 1) showTab(d, one);
        switch (askSave(d, d.file.name(), n)) {
            1000 => if (!saveAll(d, false)) return,
            1001 => {},
            else => return,
        }
    }
    for (0..tabCount(d)) |j| noteClosed(tabPage(d, j));
    foldCard(d);
}

/// Maximize or Restore Card: the card takes its window's room while the
/// others shrink away, and again the splits spring back as they were.
fn maximizeCard(d: *Doc) void {
    const w = d.win;
    if (w.cards.pane != null) return;
    const now = CACurrentMediaTime();
    if (!restoreShares(w.cards, now)) {
        var n = nodeOf(w.cards, d) orelse return;
        while (n.up) |up| {
            up.held = up.share.to;
            up.share.aim(if (up.kids[0] == n) 1 else 0, now);
            n = up;
        }
    }
    msg(void, w.window, "invalidateCursorRectsForView:", .{w.view});
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// Springs every split that Maximize Card took back to its share; false
/// when none was taken.
fn restoreShares(n: *Node, now: f64) bool {
    if (n.pane != null) return false;
    var any = false;
    if (n.held) |s| {
        n.share.aim(s, now);
        n.held = null;
        any = true;
    }
    const a = restoreShares(n.kids[0], now);
    const b = restoreShares(n.kids[1], now);
    return any or a or b;
}

/// Move Tab to Next or Previous Card: the tab on show joins that card's
/// tabs, after its active one.
fn tabToCard(d: *Doc, by: isize) void {
    var list: [64]*Doc = undefined;
    const n = listPanes(d.win.cards, &list, 0);
    if (n < 2) {
        toast(d.win, "no other card");
        return;
    }
    const i = std.mem.indexOfScalar(*Doc, list[0..n], d) orelse return;
    const ni: isize = @intCast(n);
    const to = list[@intCast(@mod(@as(isize, @intCast(i)) + by, ni))];
    moveTab(d, d.at, .{ .card = to, .zone = .tabs, .k = to.at + 1 });
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
    return if (isBlank(d)) d else null;
}

/// How many windows are open.
pub fn count() usize {
    return wins.items.len;
}

/// A new window with one card holding an empty untitled file.
pub fn newDoc() ?*Doc {
    const leaf = gpa.create(Node) catch return null;
    const w = newWin(leaf) orelse return null;
    const d = newPane(w) orelse return null;
    leaf.* = .{ .pane = d };
    w.focus = d;
    const fr = defaultFrame();
    d.size = .{ .x = fr.w, .y = fr.h };
    d.fin = d.size;
    finishWin(w);
    named(d);
    refresh(d);
    showWin(w.window);
    return d;
}

/// A new window's size: a share of the main screen's room, so it's neither
/// a postage stamp on a big display nor past the edges of a small one.
fn defaultFrame() Rect {
    const screen = msg(Id, objc.class("NSScreen"), "mainScreen", .{});
    if (screen == null) return .{ .w = 880, .h = 720 };
    const vis = msg(Rect, screen, "visibleFrame", .{});
    return .{ .w = @round(@min(std.math.clamp(vis.w * 0.5, 720, 1200), vis.w)), .h = @round(@min(std.math.clamp(vis.h * 0.82, 520, 1100), vis.h)) };
}

/// A window with the layout `leaf` and no card yet. The caller sets the
/// layout and the focused card, then `finishWin`s it.
fn newWin(leaf: *Node) ?*Win {
    const w = gpa.create(Win) catch return null;
    wins.append(gpa, w) catch return null;

    const frame = defaultFrame();
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
    msg(void, win, "setTitlebarAppearsTransparent:", .{true});
    msg(void, win, "setTitleVisibility:", .{@as(isize, 1)});
    // An empty toolbar, so AppKit itself centers the traffic lights on the
    // header's line and gives the window the corners the cards nest in.
    const bar = msg(Id, msg(Id, objc.class("NSToolbar"), "alloc", .{}), "initWithIdentifier:", .{objc.str("ze")});
    msg(void, win, "setToolbar:", .{bar});
    msg(void, bar, "release", .{});
    msg(void, win, "setToolbarStyle:", .{@as(isize, 3)});
    msg(void, win, "setTitlebarSeparatorStyle:", .{@as(isize, 1)});
    msg(void, win, "setMinSize:", .{Point{ .x = text_room, .y = 240 }});
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
    return w;
}

/// Hands `w` its events and puts it where a new window goes, once it has
/// its cards.
fn finishWin(w: *Win) void {
    const win = w.window;
    const view = w.view;
    msg(void, win, "setDelegate:", .{view});
    msg(void, win, "makeFirstResponder:", .{view});
    if (wins.items.len == 1) {
        msg(void, win, "center", .{});
        _ = msg(bool, win, "setFrameAutosaveName:", .{objc.str("ze")});
    } else {
        // AppKit's cascade step from the last window's top left, kept on its
        // screen: a window that would run past the visible frame's right or
        // bottom edge starts again at that edge's other side.
        const prev = wins.items[wins.items.len - 2].window;
        const fr = msg(Rect, prev, "frame", .{});
        msg(void, win, "setFrame:display:", .{ fr, false });
        const step = msg(Point, win, "cascadeTopLeftFromPoint:", .{Point{ .x = fr.x, .y = fr.y + fr.h }});
        _ = msg(Point, win, "cascadeTopLeftFromPoint:", .{step});
        const screen = msg(Id, prev, "screen", .{});
        if (screen != null) {
            const vis = msg(Rect, screen, "visibleFrame", .{});
            var nf = msg(Rect, win, "frame", .{});
            nf.w = @min(nf.w, vis.w);
            nf.h = @min(nf.h, vis.h);
            if (nf.x + nf.w > vis.x + vis.w) nf.x = vis.x;
            if (nf.y < vis.y) nf.y = vis.y + vis.h - nf.h;
            msg(void, win, "setFrame:display:", .{ nf, false });
        }
    }
}

/// A card for window `w` with an empty untitled file and its own caret.
/// The caller puts it in the layout.
fn newPane(w: *Win) ?*Doc {
    const d = gpa.create(Doc) catch return null;
    d.* = .{ .file = blankPage() orelse return null, .win = w };
    if (conf.focus != .off) d.focus_a.snap(1);
    d.gut.snap(gutCols(d));
    docs.append(gpa, d) catch return null;
    d.caret = msg(Id, objc.class("CALayer"), "layer", .{});
    msg(void, d.caret, "setCornerRadius:", .{@as(f64, 1)});
    msg(void, d.caret, "setHidden:", .{true});
    msg(void, msg(Id, w.view, "layer", .{}), "addSublayer:", .{d.caret});
    return d;
}

/// Runs `panel` modally; `recheckAll` stays out until it answers.
fn runModal(panel: Id) isize {
    modal = true;
    defer modal = false;
    return msg(isize, panel, "runModal", .{});
}

/// An Objective-C block with no captures, laid out as clang lays out a
/// global one: never copied or freed.
const Block = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    desc: *const BlockDesc,
};
const BlockDesc = extern struct { reserved: c_ulong = 0, size: c_ulong };
const block_desc: BlockDesc = .{ .size = @sizeOf(Block) };
/// BLOCK_IS_GLOBAL.
const block_global = 1 << 28;
extern var _NSConcreteGlobalBlock: anyopaque;
/// The sheet's completion handler: ends the modal loop `runAlert` waits in.
var sheet_done: Block = undefined;

fn sheetEnded(_: *const Block, code: isize) callconv(.c) void {
    msg(void, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "stopModalWithCode:", .{code});
}

/// The window an alert drops down from as a sheet: the key window, or a Dev
/// build's front one, while it's on screen without a sheet already.
fn sheetHost() Id {
    const d = keyDoc() orelse return null;
    const win = d.win.window;
    if (!msg(bool, win, "isVisible", .{}) or msg(Id, win, "attachedSheet", .{}) != null) return null;
    return win;
}

/// Runs alert `a` as a sheet on the front window and waits for its answer,
/// or as a window of its own when no window can hold it.
fn runAlert(a: Id) isize {
    const host = sheetHost() orelse return runModal(a);
    modal = true;
    defer modal = false;
    sheet_done = .{ .isa = &_NSConcreteGlobalBlock, .flags = block_global, .invoke = @ptrCast(&sheetEnded), .desc = &block_desc };
    msg(void, a, "beginSheetModalForWindow:completionHandler:", .{ host, @as(*anyopaque, @ptrCast(&sheet_done)) });
    return msg(isize, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "runModalForWindow:", .{msg(Id, a, "window", .{})});
}

/// Asks with an alert whose `buttons` go in order (none gives the default OK)
/// and returns what it answered: 1000 for the first button, 1001 the next.
fn askAlert(title: []const u8, info: []const u8, buttons: []const []const u8) isize {
    return askAlertWith(title, info, buttons, null);
}

/// `askAlert` with `extra` (a view, such as a text field) under the words,
/// which takes the keys first.
fn askAlertWith(title: []const u8, info: []const u8, buttons: []const []const u8, extra: Id) isize {
    const a = objc.new("NSAlert");
    msg(void, a, "setMessageText:", .{objc.str(title)});
    msg(void, a, "setInformativeText:", .{objc.str(info)});
    for (buttons) |b| _ = msg(Id, a, "addButtonWithTitle:", .{objc.str(b)});
    if (extra != null) {
        msg(void, a, "setAccessoryView:", .{extra});
        msg(void, a, "layout", .{});
        msg(void, msg(Id, a, "window", .{}), "setInitialFirstResponder:", .{extra});
    }
    const r = runAlert(a);
    msg(void, a, "release", .{});
    return r;
}

fn alert(text: []const u8, detail: []const u8) void {
    _ = askAlert(text, detail, &.{});
}

/// Asks for a file or folder name in a text field that starts as `initial`.
/// Null on Cancel, or for an empty name or one with a slash. Valid until the
/// autorelease pool drains.
fn askName(title: []const u8, info: []const u8, initial: []const u8, ok: []const u8) ?[]const u8 {
    const box = msg(Id, msg(Id, objc.class("NSTextField"), "alloc", .{}), "initWithFrame:", .{Rect{ .w = 280, .h = 24 }});
    defer msg(void, box, "release", .{});
    msg(void, box, "setStringValue:", .{objc.str(initial)});
    if (askAlertWith(title, info, &.{ ok, "Cancel" }, box) != 1000) return null;
    const s = std.mem.trim(u8, objc.utf8(msg(Id, box, "stringValue", .{})), " \t");
    if (s.len == 0 or std.mem.indexOfScalar(u8, s, '/') != null or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return null;
    return s;
}

extern "c" fn strerror(n: c_int) [*:0]const u8;

/// What the system said about the last call that failed, like "Permission
/// denied". Read it right after the failure.
fn osError() []const u8 {
    const e = std.c._errno().*;
    return if (e == 0) "Unknown error" else std.mem.span(strerror(e));
}

fn askSave(d: *Doc, name: []const u8, n: usize) isize {
    front(d);
    var buf: [300]u8 = undefined;
    const title = if (n == 1)
        std.fmt.bufPrint(&buf, "Save changes to {s}?", .{name}) catch "Save changes?"
    else
        std.fmt.bufPrint(&buf, "Save changes to {d} files?", .{n}) catch "Save changes?";
    return askAlert(title, "Your changes are lost if you don't save them.", &.{ if (n == 1) "Save" else "Save All", "Don't Save", "Cancel" });
}

/// Asks to save a window's unsaved files, across its cards and tabs, with one
/// question. Closing the window asks about untitled files' text too, since
/// their drafts go with it; quitting keeps the drafts for next time and
/// doesn't. False when the user cancels.
fn settle(w: *Win, quit: bool) bool {
    var n: usize = 0;
    var one: ?TabRef = null;
    for (docs.items) |d| if (d.win == w and !d.closing) {
        for (0..tabCount(d)) |j| if (asks(quit, tabPage(d, j))) {
            n += 1;
            one = .{ .d = d, .j = j };
        };
    };
    if (n == 0) return true;
    // One file: show it so the question names it. More: ask from the focused card.
    const ask = if (n == 1) one.?.d else w.focus;
    if (n == 1) showTab(ask, one.?.j);
    return switch (askSave(ask, ask.file.name(), n)) {
        1000 => for (docs.items) |d| {
            if (d.win == w and !d.closing and !saveAll(d, quit)) break false;
        } else true,
        1001 => true,
        else => false,
    };
}

fn asks(quit: bool, p: *const Page) bool {
    return if (quit) p.edited() else p.loses();
}

/// Saves the file on show, then each page `settle` asked about in tab order.
fn saveAll(d: *Doc, quit: bool) bool {
    if (asks(quit, &d.file) and !save(d, false)) return false;
    // A Save As can close other tabs, so look again after each save.
    while (askingTab(d, quit)) |j| {
        showTab(d, j);
        if (d.at != j or !save(d, false)) return false;
    }
    return true;
}

fn askingTab(d: *Doc, quit: bool) ?usize {
    for (0..tabCount(d)) |j| if (asks(quit, tabPage(d, j))) return j;
    return null;
}

pub fn settleAll() bool {
    for (wins.items) |w| if (!settle(w, true)) return false;
    return true;
}

fn save(d: *Doc, as: bool) bool {
    // Save As writes before the doc takes the new path, so a failed write
    // leaves it as it was.
    var fresh: ?[:0]u8 = null;
    if (d.file.path == null or as) {
        const p = msg(Id, objc.class("NSSavePanel"), "savePanel", .{});
        msg(void, p, "setNameFieldStringValue:", .{objc.str(d.file.name())});
        if (root) |r| msg(void, p, "setDirectoryURL:", .{msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(r)})});
        if (runModal(p) != 1) return false;
        const path = objc.utf8(msg(Id, msg(Id, p, "URL", .{}), "path", .{}));
        const z = gpa.dupeSentinel(u8, path, 0) catch return false;
        // Resolve a file that exists before writing, so replacing a symlink
        // writes through to its target instead of over the link.
        if (!files.exists(z)) {
            fresh = z;
        } else {
            defer gpa.free(z);
            fresh = files.absolute(gpa, z) catch return false;
        }
    } else if (files.stamp(d.file.path.?)) |now| {
        // Another app wrote the file since Zag read or saved it. A deleted
        // file is just written again.
        if (!std.meta.eql(@as(?files.Stamp, now), d.file.stamp) and !askOverwrite(d)) return false;
    }
    const to = fresh orelse d.file.path.?;
    if (files.exists(to) and !files.writable(to) and !askReadOnly(to)) {
        if (fresh) |z| gpa.free(z);
        return false;
    }
    if (conf.trim_trailing_whitespace) d.file.ed.trimTrailingWhitespace(gpa) catch {};
    if (conf.ensure_final_newline) d.file.ed.ensureFinalNewline(gpa) catch {};
    // A failed write says what the system said, and offers to try again or
    // to save somewhere else.
    while (true) {
        if (files.write(to, d.file.ed.text())) |_| break else |_| {}
        var ib: [std.fs.max_path_bytes + 160]u8 = undefined;
        const why = std.fmt.bufPrint(&ib, "{s}.\n\n{s}", .{ osError(), to }) catch to;
        var tb: [300]u8 = undefined;
        const title = std.fmt.bufPrint(&tb, "Couldn't save {s}.", .{std.fs.path.basename(to)}) catch "Couldn't save this file.";
        switch (askAlert(title, why, &.{ "Try Again", "Save As…", "Cancel" })) {
            1000 => continue,
            1001 => {
                if (fresh) |z| gpa.free(z);
                return save(d, true);
            },
            else => {
                if (fresh) |z| gpa.free(z);
                return false;
            },
        }
    }
    if (fresh) |z| {
        // Resolve after writing so a new file in a linked folder has a real path too.
        const abs = files.absolute(gpa, z) catch {
            gpa.free(z);
            return false;
        };
        gpa.free(z);
        preview.rename(d.file.id, abs);
        if (d.file.path) |old| gpa.free(old);
        d.file.path = abs;
        dropCopies(d, abs);
        d.file.lang = langOf(&d.file, abs);
        clearSyntax(d);
        named(d);
    } else if (d.file.stamp == null) {
        // A file opened before it existed got a path that `realpath` couldn't
        // resolve; resolve it now so it matches the tree's path for the file.
        if (files.absolute(gpa, d.file.path.?)) |abs| {
            if (std.mem.eql(u8, abs, d.file.path.?)) {
                gpa.free(abs);
            } else {
                preview.rename(d.file.id, abs);
                gpa.free(d.file.path.?);
                d.file.path = abs;
                named(d);
            }
        } else |_| {}
    }
    d.file.ed.buf.markSaved();
    dropDraft(&d.file.draft);
    d.file.stamp = files.stamp(d.file.path.?);
    d.file.new_file = false;
    d.file.locked = !files.writable(d.file.path.?);
    toast(d.win, "saved");
    noteRecent(d.file.path.?);
    if (isConf(d.file.path)) {
        // Saving the settings file names its problems again, even ones shown before.
        report_key = 0;
        loadSettings();
    }
    // A new file shows in the tree when its folder's rows are listed; every
    // file's dot goes away.
    if (relOf(d.file.path.?)) |rel| if (!tree.has(rel) and listed(std.fs.path.dirname(rel))) {
        rebuildTree();
        refreshAll();
        return true;
    };
    refresh(d);
    for (wins.items) |w| redrawSide(w);
    return true;
}

/// Closes every other tab that holds `abs`, which Save As just wrote over
/// from `keep`, without asking: what it showed is gone from disk. A card's
/// last tab folds the card away, or closes the window when it's the only card.
fn dropCopies(keep: *Doc, abs: []const u8) void {
    while (copyOf(keep, abs)) |h| {
        const last = tabCount(h.d) == 1;
        var pg = takeTab(h.d, h.j) orelse return;
        pg.deinit();
        if (!last) continue;
        if (h.d.win.cards.pane != null) {
            // Close it on the next turn: `settle` may be walking the windows' cards.
            msg(void, h.d.win.window, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("performClose:"), @as(Id, null), @as(f64, 0) });
        } else {
            foldCard(h.d);
            if (h.d.win == keep.win) focus(keep);
        }
    }
}

/// The first live tab other than `keep`'s file on show that holds `abs`.
fn copyOf(keep: *Doc, abs: []const u8) ?TabRef {
    for (docs.items) |d| {
        if (d.closing) continue;
        for (0..tabCount(d)) |j| {
            const p = tabPage(d, j);
            if (p != &keep.file and p.path != null and std.mem.eql(u8, p.path.?, abs)) return .{ .d = d, .j = j };
        }
    }
    return null;
}

/// Whether the rows of folder `rel` (null for the root) are on the tree's list.
fn listed(rel: ?[]const u8) bool {
    const r = rel orelse return true;
    return tree.isOpen(r) and tree.has(r);
}

pub fn openPanel() void {
    const p = msg(Id, objc.class("NSOpenPanel"), "openPanel", .{});
    msg(void, p, "setCanChooseDirectories:", .{true});
    msg(void, p, "setAllowsMultipleSelection:", .{true});
    if (root) |r| msg(void, p, "setDirectoryURL:", .{msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(r)})});
    if (runModal(p) != 1) return;
    const urls = msg(Id, p, "URLs", .{});
    for (0..msg(usize, urls, "count", .{})) |i| {
        const path = objc.utf8(msg(Id, msg(Id, urls, "objectAtIndex:", .{i}), "path", .{}));
        openFile(path);
    }
}

/// The sidebar header's Open Folder…: a folder for the sidebar.
fn openFolderPanel() void {
    const p = msg(Id, objc.class("NSOpenPanel"), "openPanel", .{});
    msg(void, p, "setCanChooseDirectories:", .{true});
    msg(void, p, "setCanChooseFiles:", .{false});
    if (root) |r| msg(void, p, "setDirectoryURL:", .{msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(std.fs.path.dirname(r) orelse r)})});
    if (runModal(p) != 1) return;
    const urls = msg(Id, p, "URLs", .{});
    if (msg(usize, urls, "count", .{}) == 0) return;
    open(objc.utf8(msg(Id, msg(Id, urls, "objectAtIndex:", .{@as(usize, 0)}), "path", .{})), keyDoc());
}

/// File > Open Recent: the last files opened or saved, newest first.
fn noteRecent(p: []const u8) void {
    if (isConf(p)) return;
    noteIn("recent", p, 15);
}

/// The sidebar header's Recent Folders and the empty card's list: the last
/// folders the sidebar showed, newest first.
fn noteRecentFolder(p: []const u8) void {
    noteIn("recentFolders", p, 8);
}

/// Puts `p` first in the defaults' list `key`, keeping at most `max`.
fn noteIn(comptime key: []const u8, p: []const u8, max: usize) void {
    const s = objc.str(p);
    const out = msg(Id, objc.class("NSMutableArray"), "arrayWithObject:", .{s});
    const old = listIn(key);
    for (0..msg(usize, old, "count", .{})) |i| {
        if (msg(usize, out, "count", .{}) >= max) break;
        const o = msg(Id, old, "objectAtIndex:", .{i});
        if (!msg(bool, o, "isEqualToString:", .{s})) msg(void, out, "addObject:", .{o});
    }
    msg(void, defaults(), "setObject:forKey:", .{ out, objc.str(key) });
}

fn listIn(comptime key: []const u8) Id {
    const list = msg(Id, defaults(), "stringArrayForKey:", .{objc.str(key)});
    return if (list != null) list else msg(Id, objc.class("NSArray"), "array", .{});
}

pub fn recentFiles() Id {
    return listIn("recent");
}

fn recentFolders() Id {
    return listIn("recentFolders");
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
fn fields(s: []const u8) ?[3][]const u8 {
    var out: [3][]const u8 = undefined;
    var rest = s;
    for (0..2) |i| {
        const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
        out[i] = rest[0..tab];
        rest = rest[tab + 1 ..];
    }
    out[2] = rest;
    return out;
}

/// Where the caret and scroll were in recent files, newest first, as
/// "cur\tsy\tpath" lines, at most 100. Read from the defaults at setup and
/// written back a second after a change (and at quit), so switching tabs
/// doesn't rewrite the defaults each time.
var places: std.ArrayList([]u8) = .empty;
var places_due = false;

extern var _dispatch_main_q: anyopaque;
extern fn dispatch_time(when: u64, delta: i64) u64;
extern fn dispatch_after_f(when: u64, queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

fn loadPlaces() void {
    const list = msg(Id, defaults(), "stringArrayForKey:", .{objc.str("places")});
    if (list == null) return;
    for (0..msg(usize, list, "count", .{})) |i| {
        const s = objc.utf8(msg(Id, list, "objectAtIndex:", .{i}));
        if (fields(s) == null) continue;
        const own = gpa.dupe(u8, s) catch return;
        places.append(gpa, own) catch return gpa.free(own);
    }
}

/// Remembers the file's caret and scroll, newest first.
fn rememberPlace(pg: *const Page) void {
    const p = pg.path orelse return;
    var buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "{d}\t{d}\t", .{ pg.ed.cur, @as(i64, @intFromFloat(pg.sy)) }) catch return;
    const entry = std.mem.concat(gpa, u8, &.{ head, p }) catch return;
    var i: usize = 0;
    while (i < places.items.len) {
        if (std.mem.eql(u8, fields(places.items[i]).?[2], p)) gpa.free(places.orderedRemove(i)) else i += 1;
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
    for (places.items) |s| {
        const fs = fields(s).?;
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
    if (zoom_due) zoomWrite(@ptrFromInt(zoom_gen));
    for (docs.items) |d| rememberPlace(&d.file);
    if (places_due) writePlaces(null);
    const out = msg(Id, objc.class("NSMutableArray"), "array", .{});
    const order = msg(Id, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "orderedWindows", .{});
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    // Back to front, so the front window opens last and stays in front.
    // Windows AppKit leaves out of `orderedWindows` (hidden or minimized
    // ones, if it does) go first.
    for (wins.items) |wn| {
        if (msg(usize, order, "indexOfObject:", .{wn.window}) == std.math.maxInt(isize)) saveWin(wn, &line, out);
    }
    var i = msg(usize, order, "count", .{});
    while (i > 0) {
        i -= 1;
        const w = msg(Id, order, "objectAtIndex:", .{i});
        for (wins.items) |wn| if (wn.window == w) saveWin(wn, &line, out);
    }
    msg(void, defaults(), "setObject:forKey:", .{ out, objc.str("session") });
    if (root) |r| {
        msg(void, defaults(), "setObject:forKey:", .{ objc.str(r), objc.str("root") });
    } else msg(void, defaults(), "removeObjectForKey:", .{objc.str("root")});
}

/// One window's session line.
fn saveWin(wn: *Win, line: *std.ArrayList(u8), out: Id) void {
    line.clearRetainingCapacity();
    line.appendSlice(gpa, objc.utf8(msg(Id, wn.window, "stringWithSavedFrame", .{}))) catch return;
    const kept = saveLayout(wn, wn.cards, line) catch return;
    if (kept > 0) msg(void, out, "addObject:", .{objc.str(line.items)});
}

/// Writes `n`'s part of the session line. Returns how many files it kept.
fn saveLayout(w: *const Win, n: *const Node, out: *std.ArrayList(u8)) !usize {
    if (n.pane) |d| {
        var kept: usize = 0;
        var on: usize = 0;
        for (0..tabCount(d)) |j| {
            const p = tabPage(d, j);
            if (p.path != null or p.draft != null) {
                if (j == d.at) on = kept;
                kept += 1;
            }
        }
        try out.print(gpa, "\t#{d},{d},{d}", .{ kept, on, @intFromBool(w.focus == d) });
        for (0..tabCount(d)) |j| {
            const pg = tabPage(d, j);
            if (pg.path) |p| {
                try out.print(gpa, "\t{s}", .{p});
            } else if (pg.draft) |p| try out.print(gpa, "\t*{s}", .{p});
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

/// The last session's folder, owned by gpa, or null when it's gone or unset.
pub fn savedRoot() ?[:0]u8 {
    const saved = msg(Id, defaults(), "stringForKey:", .{objc.str("root")});
    if (saved == null) return null;
    const z = gpa.dupeSentinel(u8, objc.utf8(saved), 0) catch return null;
    if (files.isDir(z)) return z;
    gpa.free(z);
    return null;
}

/// Reopens last session's windows where they were, with their cards and
/// tabs, and its folder when Zag started without one. False when no window
/// opened.
pub fn restoreSession() bool {
    if (root == null) if (savedRoot()) |z| adoptRoot(z);
    // Drafts move from the old folder before any tab takes one's path.
    var db: [std.fs.max_path_bytes]u8 = undefined;
    _ = draftsDir(&db);
    const list = msg(Id, defaults(), "stringArrayForKey:", .{objc.str("session")});
    restoring = true;
    var opened: std.ArrayList(*Win) = .empty;
    defer opened.deinit(gpa);
    const n = if (list != null) msg(usize, list, "count", .{}) else 0;
    for (0..n) |i| {
        const entry = objc.utf8(msg(Id, list, "objectAtIndex:", .{i}));
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse continue;
        var it = std.mem.splitScalar(u8, entry[tab + 1 ..], '\t');
        if (restoreWindow(entry[0..tab], &it)) |w| opened.append(gpa, w) catch showWin(w.window);
    }
    restoring = false;
    if (tree_stale) rebuildTree();
    refreshAll();
    for (opened.items) |w| showWin(w.window);
    // Files that went away since last time are left out, and said so.
    if (gone_n > 0) {
        var buf: [120]u8 = undefined;
        toastFront(if (gone_n == 1)
            std.fmt.bufPrint(&buf, "{s} is gone, so it didn't reopen", .{gone_name[0..gone_len]}) catch "A file is gone, so it didn't reopen"
        else
            std.fmt.bufPrint(&buf, "{d} files are gone, so they didn't reopen", .{gone_n}) catch "Some files are gone, so they didn't reopen");
        gone_n = 0;
    }
    return docs.items.len > 0;
}

/// A window from one session line, or none when none of its files are left.
fn restoreWindow(frame: []const u8, it: *std.mem.SplitIterator(u8, .scalar)) ?*Win {
    const leaf = gpa.create(Node) catch return null;
    const w = newWin(leaf) orelse return null;
    var lit: ?*Doc = null;
    const n = restoreNode(w, it, &lit) orelse {
        // Nothing of the line is left: the window closes, holding a card for its layout.
        // Only the delegate is set, so closing tears it down without finishWin
        // centering it and writing that frame over the saved one.
        const d = newPane(w) orelse return null;
        leaf.* = .{ .pane = d };
        w.focus = d;
        msg(void, w.window, "setDelegate:", .{w.view});
        msg(void, w.window, "close", .{});
        return null;
    };
    gpa.destroy(leaf);
    w.cards = n;
    w.focus = lit orelse firstPane(n);
    finishWin(w);
    named(w.focus);
    msg(void, w.window, "setFrameFromString:", .{objc.str(frame)});
    return w;
}

/// The cards that `it` describes next, leaving out files that are gone and
/// cards left with none.
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
    if (tok.len == 0 or tok[0] != '#') return null;
    var head: [3]usize = undefined;
    var nums = std.mem.splitScalar(u8, tok[1..], ',');
    for (&head) |*v| v.* = std.fmt.parseInt(usize, nums.next() orelse "0", 10) catch 0;
    const d = newPane(w) orelse return null;
    // The window's focus is read while installing (the sidebar's scroll to
    // the file): the first card made holds it until `restoreWindow` picks
    // the lit one.
    if (for (docs.items) |o| {
        if (o.win == w and o != d) break false;
    } else true) w.focus = d;
    // The tabs wait as parked pages; only the lit one is installed, once.
    var on: usize = 0;
    for (0..head[0]) |i| {
        const p = it.next() orelse break;
        const draft = p.len > 0 and p[0] == '*';
        const saved = gpa.dupeSentinel(u8, if (draft) p[1..] else p, 0) catch continue;
        defer gpa.free(saved);
        // A draft from before the Drafts folder moved is read from its new place.
        var mb: [std.fs.max_path_bytes]u8 = undefined;
        const z = if (draft and !files.exists(saved)) movedDraft(saved, &mb) orelse saved else saved;
        if (!files.exists(z)) {
            if (!draft) {
                gone_n += 1;
                const nm = std.fs.path.basename(z);
                gone_len = @min(nm.len, gone_name.len);
                @memcpy(gone_name[0..gone_len], nm[0..gone_len]);
            }
            continue;
        }
        var pg = (if (draft) loadDraft(z) else loadPage(z)) orelse continue;
        // A parked page isn't rising in.
        pg.rise = false;
        d.pages.append(gpa, pg) catch {
            // A draft that can't open stays on disk for `adoptDrafts`.
            pg.deinitKeepDraft();
            continue;
        };
        if (i == head[1] or d.pages.items.len == 1) on = d.pages.items.len - 1;
        // The folders its file is in open in the sidebar.
        if (pg.path) |pp| if (relOf(pp)) |rel| revealFile(rel);
    }
    const tabs = d.pages.items.len;
    if (tabs == 0) {
        closePane(d);
        return null;
    }
    // Keep open tabs at the front of the 100 places so parked tabs keep theirs.
    for (d.pages.items) |*pg| rememberPlace(pg);
    // The old one-by-one restore rose only the last tab.
    d.pages.items[on].rise = on == tabs - 1;
    d.file.deinit();
    swapIn(d, on);
    if (head[2] == 1) lit.* = d;
    const n = gpa.create(Node) catch {
        closePane(d);
        return null;
    };
    n.* = .{ .pane = d };
    return n;
}

/// Files the session restore left out because they're gone: how many, and
/// the last one's name.
var gone_n: usize = 0;
var gone_name: [64]u8 = undefined;
var gone_len: usize = 0;

// ---- drafts ----

/// Untitled files keep their text in a draft file here as it changes, so
/// it's never lost: `~/Library/Application Support/zag/Drafts`. Drafts from
/// before Zag's rename, in `ze/Drafts`, move there the first time it's
/// asked for; when that move fails they're read where they are.
fn draftsDir(buf: []u8) ?[:0]const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    const z = std.fmt.bufPrintSentinel(buf, "{s}/Library/Application Support/zag/Drafts", .{home}, 0) catch return null;
    if (files.isDir(z)) return z;
    var ob: [std.fs.max_path_bytes]u8 = undefined;
    const old = std.fmt.bufPrintSentinel(&ob, "{s}/Library/Application Support/ze/Drafts", .{home}, 0) catch return z;
    if (!files.isDir(old)) return z;
    files.makeParent(z) catch {};
    if (std.c.rename(old, z) == 0) return z;
    return std.fmt.bufPrintSentinel(buf, "{s}", .{old}, 0) catch null;
}

/// Where a draft saved under the old `ze/Drafts` folder is now.
fn movedDraft(p: []const u8, buf: []u8) ?[:0]const u8 {
    const old = "/Application Support/ze/Drafts/";
    const at = std.mem.indexOf(u8, p, old) orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/Application Support/zag/Drafts/{s}", .{ p[0..at], p[at + old.len ..] }, 0) catch null;
}

fn saveDraftsNow(_: Id, _: Sel, _: Id) callconv(.c) void {
    saveDrafts();
}

/// Writes every untitled file that changed since its draft last did. One
/// that's empty again loses its draft.
fn saveDrafts() void {
    for (docs.items) |d| for (0..tabCount(d)) |j| keepDraft(tabPage(d, j));
}

fn keepDraft(p: *Page) void {
    if (p.path != null or p.ed.buf.changes == p.drafted) return;
    if (p.ed.text().len == 0) {
        dropDraft(&p.draft);
        p.drafted = p.ed.buf.changes;
        return;
    }
    if (p.draft == null) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = draftsDir(&buf) orelse return;
        const secs: u64 = @intFromFloat(@max(msg(f64, objc.class("NSDate"), "timeIntervalSinceReferenceDate", .{}), 0));
        p.draft = std.fmt.allocPrintSentinel(gpa, "{s}/{d}-{d}.txt", .{ dir, secs, newId() }, 0) catch return;
        files.makeParent(p.draft.?) catch return;
    }
    files.write(p.draft.?, p.ed.text()) catch return;
    p.drafted = p.ed.buf.changes;
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
    var ed = Editor.initOwned(gpa, bytes) catch return null;
    styleEditor(&ed);
    const own = gpa.dupeSentinel(u8, abs, 0) catch {
        ed.deinit(gpa);
        return null;
    };
    var pg: Page = .{ .ed = ed, .id = newId(), .draft = own, .drafted = ed.buf.changes, .rise = true };
    _ = pg.rename();
    return pg;
}

/// At launch: drafts that no tab holds, left by a crash or a start that
/// opened files instead of the last session, come back as tabs in the front
/// window.
pub fn adoptDrafts() void {
    _ = recoverDrafts();
}

/// Drafts no tab holds come back as tabs in the front window's card, oldest
/// first, after the tab on show, which stays on show: a file opened from
/// Finder keeps the keys. Says how many came back. Returns that count.
fn recoverDrafts() usize {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = draftsDir(&buf) orelse return 0;
    const dh = std.c.opendir(dir) orelse return 0;
    // Draft names start with the second they were made: "<seconds>-<id>.txt".
    const Found = struct { secs: u64, id: u64, name: []u8 };
    var found: std.ArrayList(Found) = .empty;
    defer {
        for (found.items) |x| gpa.free(x.name);
        found.deinit(gpa);
    }
    while (std.c.readdir(dh)) |e| {
        const name = std.mem.sliceTo(&e.name, 0);
        if (name.len == 0 or name[0] == '.' or !std.mem.endsWith(u8, name, ".txt")) continue;
        const stem = name[0 .. name.len - 4];
        const dash = std.mem.indexOfScalar(u8, stem, '-');
        const secs = std.fmt.parseInt(u64, stem[0 .. dash orelse stem.len], 10) catch std.math.maxInt(u64);
        const id = if (dash) |k| std.fmt.parseInt(u64, stem[k + 1 ..], 10) catch 0 else 0;
        const own = gpa.dupe(u8, name) catch continue;
        found.append(gpa, .{ .secs = secs, .id = id, .name = own }) catch gpa.free(own);
    }
    _ = std.c.closedir(dh);
    std.mem.sort(Found, found.items, {}, struct {
        fn lt(_: void, a: Found, b: Found) bool {
            return a.secs < b.secs or (a.secs == b.secs and a.id < b.id);
        }
    }.lt);
    var n: usize = 0;
    for (found.items) |x| {
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const abs = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ dir, x.name }, 0) catch continue;
        if (draftHeld(abs)) continue;
        var pg = loadDraft(abs) orelse continue;
        const d = keyDoc() orelse (if (wins.items.len > 0) wins.items[wins.items.len - 1].focus else newDoc()) orelse {
            pg.deinitKeepDraft();
            break;
        };
        if (replaceable(d)) {
            putTab(d, pg, 0);
        } else {
            pg.rise = false;
            d.pages.insert(gpa, @min(d.at + n, d.pages.items.len), pg) catch {
                pg.deinitKeepDraft();
                continue;
            };
            refreshWin(d.win);
        }
        n += 1;
    }
    if (n > 0) {
        var tb: [48]u8 = undefined;
        toastFront(if (n == 1) "Restored 1 draft" else std.fmt.bufPrint(&tb, "Restored {d} drafts", .{n}) catch "Restored drafts");
    }
    return n;
}

/// File > Recover Drafts: drafts no tab holds come back.
fn recoverDraftsNow() void {
    if (recoverDrafts() == 0) toastFront("No drafts to recover");
}

/// File > Browse Drafts…: the Drafts folder in Finder.
fn browseDrafts() void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = draftsDir(&buf) orelse return;
    if (!files.isDir(dir)) return toastFront("No drafts yet");
    msg(void, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(dir)})});
}

fn draftHeld(abs: []const u8) bool {
    for (docs.items) |d| for (0..tabCount(d)) |j| {
        if (tabPage(d, j).draft) |p| if (std.mem.eql(u8, p, abs)) return true;
    };
    return false;
}

// ---- changes from outside ----

/// When Zag comes forward: picks up settings and files that other apps changed.
pub fn recheckAll() void {
    if (modal) return;
    recheckSettings();
    for (docs.items) |d| checkOutside(d);
    // The rows and their cached lines stay unless a read folder moved on
    // disk or the open set changed (see `Tree.fresh`).
    if (!tree.fresh()) rebuildTree();
    refreshAll();
}

/// A clean doc reloads from disk; one with unsaved changes asks first. A
/// deleted or binary file leaves the text as unsaved changes. A failed read
/// leaves the old stamp, so the next check retries and Save asks first.
fn checkOutside(d: *Doc) void {
    for (d.pages.items) |*pg| checkDeleted(pg);
    const p = d.file.path orelse return;
    const now = files.stamp(p);
    // A file made read-only, or writable again, shows or drops its lock.
    const locked = now != null and !files.writable(p);
    if (locked != d.file.locked) {
        d.file.locked = locked;
        refresh(d);
    }
    if (std.meta.eql(now, d.file.stamp)) return;
    if (now == null) {
        d.file.stamp = now;
        d.file.ed.buf.markUnsaved();
        toast(d.win, "deleted on disk");
        return refresh(d);
    }
    const bytes = files.read(gpa, p) catch return;
    defer gpa.free(bytes);
    if (d.file.ed.buf.dirty() and !askReload(d, bytes)) {
        d.file.stamp = now;
        return;
    }
    if (looksBinary(bytes)) {
        d.file.stamp = now;
        d.file.ed.buf.markUnsaved();
        toast(d.win, "binary on disk");
        return refresh(d);
    }
    d.file.ed.reload(gpa, bytes) catch return;
    // A new first line (a `#!` added outside) can change the language.
    const lang = langOf(&d.file, p);
    if (lang != d.file.lang) {
        d.file.lang = lang;
        clearSyntax(d);
    }
    d.file.stamp = now;
    d.file.new_file = false;
    toast(d.win, "reloaded");
    refresh(d);
}

fn looksBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8000)], 0) != null;
}

/// A parked tab whose file was deleted keeps its text as unsaved changes, so
/// quitting asks about it. Only the shown tab reloads changed files.
fn checkDeleted(pg: *Page) void {
    const p = pg.path orelse return;
    if (pg.stamp == null or files.stamp(p) != null) return;
    pg.stamp = null;
    pg.ed.buf.markUnsaved();
}

fn changedTitle(d: *Doc, buf: *[300]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} changed in another app.", .{d.file.name()}) catch "This file changed in another app.";
}

/// Asks what to do about a file with unsaved changes that another app
/// changed, saying which lines differ. Show Changes opens the version on
/// disk beside it and keeps this one. True to reload.
fn askReload(d: *Doc, disk: []const u8) bool {
    // A Dev build never puts an alert in front of Harsha: it keeps its copy.
    if (background) return false;
    msg(void, d.win.window, "makeKeyAndOrderFront:", .{@as(Id, null)});
    var buf: [300]u8 = undefined;
    var ib: [300]u8 = undefined;
    const info = diffSummary(&ib, d.file.ed.text(), disk);
    switch (askAlert(changedTitle(d, &buf), info, &.{ "Keep Mine", "Reload", "Show Changes" })) {
        1001 => return true,
        1002 => showDiskCopy(d, disk),
        else => {},
    }
    return false;
}

/// Which lines differ between `mine` and `disk`, from the first line that
/// differs to the last, and what reloading costs.
fn diffSummary(buf: []u8, mine: []const u8, disk: []const u8) []const u8 {
    const lose = "Reloading it loses your unsaved changes here.";
    var a = std.mem.splitScalar(u8, mine, '\n');
    var b = std.mem.splitScalar(u8, disk, '\n');
    var head: usize = 0;
    while (true) {
        const x = a.next();
        const y = b.next();
        if (x == null or y == null or !std.mem.eql(u8, x.?, y.?)) break;
        head += 1;
    }
    const ml = std.mem.count(u8, mine, "\n") + 1;
    const dl = std.mem.count(u8, disk, "\n") + 1;
    var tail: usize = 0;
    var i = mine.len;
    var j = disk.len;
    // Matching lines back from the end, without running into the matching head.
    while (tail + head < @min(ml, dl)) {
        const xs = if (std.mem.lastIndexOfScalar(u8, mine[0..i], '\n')) |k| k + 1 else 0;
        const ys = if (std.mem.lastIndexOfScalar(u8, disk[0..j], '\n')) |k| k + 1 else 0;
        if (!std.mem.eql(u8, mine[xs..i], disk[ys..j]) or xs == 0 or ys == 0) break;
        i = xs - 1;
        j = ys - 1;
        tail += 1;
    }
    const here = ml - head - tail;
    const there = dl - head - tail;
    if (here == 0 and there == 0) return lose;
    const first = head + 1;
    const last = head + @max(here, there);
    if (first >= last) return std.fmt.bufPrint(buf, "Line {d} differs: {d} line{s} here, {d} on disk. {s}", .{ first, here, if (here == 1) "" else "s", there, lose }) catch lose;
    return std.fmt.bufPrint(buf, "Lines {d} to {d} differ: {d} line{s} here, {d} on disk. {s}", .{ first, last, here, if (here == 1) "" else "s", there, lose }) catch lose;
}

/// The version on disk of `d`'s file, as an untitled tab in a card split off
/// to its right (or a tab beside it when there's no room), to compare.
fn showDiskCopy(d: *Doc, disk: []const u8) void {
    var ed = Editor.init(gpa, disk) catch return;
    styleEditor(&ed);
    var pg: Page = .{ .ed = ed, .id = newId(), .lang = d.file.lang, .rise = true };
    const name = d.file.name();
    const nm = std.fmt.bufPrint(&pg.title, "{s} (on disk)", .{name}) catch blk: {
        const n = @min(name.len, pg.title.len);
        @memcpy(pg.title[0..n], name[0..n]);
        break :blk pg.title[0..n];
    };
    pg.title_len = nm.len;
    const to = (if (roomFor(d, false)) splitOff(d, false, false, false) else null) orelse d;
    putTab(to, pg, if (to == d) d.at + 1 else 0);
    focus(d);
}

/// Saving over a file another app changed since Zag read or saved it.
fn askOverwrite(d: *Doc) bool {
    if (background) return true;
    var buf: [300]u8 = undefined;
    return askAlert(changedTitle(d, &buf), "Saving replaces that version with yours.", &.{ "Save Anyway", "Cancel" }) == 1000;
}

/// Saving over a file set read-only, which the rename in `files.write`
/// would otherwise replace without a word.
fn askReadOnly(path: []const u8) bool {
    if (background) return true;
    var buf: [300]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "{s} is read-only.", .{std.fs.path.basename(path)}) catch "This file is read-only.";
    return askAlert(title, "Saving replaces it with your version, which stays read-only.", &.{ "Save Anyway", "Cancel" }) == 1000;
}

// ---- settings ----

fn desaturate(c: *Rgb) void {
    c.* = @splat(c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722);
}

/// Sets the colors that draw from the settings' themes: grey in zen (the
/// caret keeps half its color, so it still reads as the caret), warmer in
/// Late-Night with its warmth on, and with Increase Contrast on, muted
/// text lifted to the text color at 0.8.
fn buildThemes() void {
    themes = .{ conf.light, conf.dark };
    if (conf.zen) for (&themes) |*th| {
        const tint = th.caret;
        for (settings.all(th)) |*c| desaturate(c);
        th.caret = mixRgb(th.caret, tint, 0.5);
    };
    if (conf.late_night and conf.late_night_warmth) for (&themes) |*th| {
        for (settings.all(th)) |*c| c.* = .{ @min(1, c[0] * 1.04), c[1] * 0.94, c[2] * 0.78 };
    };
    if (contrast) for (&themes) |*th| {
        for (&th.muted, th.bg, th.fg) |*m, back, text| m.* = back + 0.8 * (text - back);
    };
}

/// The transition shared by the editor and preview when their theme changes.
pub fn themeFade() Id {
    const t = msg(Id, objc.class("CATransition"), "animation", .{});
    msg(void, t, "setType:", .{objc.str("fade")});
    msg(void, t, "setDuration:", .{@as(f64, 0.25)});
    msg(void, t, "setTimingFunction:", .{msg(Id, objc.class("CAMediaTimingFunction"), "functionWithName:", .{objc.str("easeInEaseOut")})});
    return t;
}

/// Crossfades the window to what draws next, for a theme or appearance
/// change: one fade over the view's layer and each caret layer.
fn fadeTheme(w: *Win) void {
    const t = themeFade();
    msg(void, msg(Id, w.view, "layer", .{}), "addAnimation:forKey:", .{ t, objc.str("theme") });
    for (docs.items) |d| if (d.win == w) msg(void, d.caret, "addAnimation:forKey:", .{ t, objc.str("theme") });
}

/// Once the settings file exists, uses the path open() gives it (/tmp is
/// /private/tmp, and a linked file resolves to its target so writes go
/// through the link instead of replacing it).
fn resolveConf() void {
    if (conf_path != null and files.exists(conf_path.?)) {
        if (files.absolute(gpa, conf_path.?)) |abs| {
            gpa.free(conf_path.?);
            conf_path = abs;
        } else |_| {}
    }
}

/// Reads the settings file and applies it to every window.
fn loadSettings() void {
    resolveConf();
    const p = conf_path orelse return;
    const old_conf = conf;
    conf_saved = settings.load(gpa, p);
    // A zoom still waiting to be written wins over the file's older size.
    if (zoom_due) conf_saved.size = zoom_size;
    conf_stamp = files.stamp(p);
    applySettings(old_conf);
    reportSettings();
}

/// What `report_key` was made from when the settings file's problems were
/// last named: 0 when it read cleanly.
var report_key: u64 = 0;

/// Names the settings file's first problem in a note on the front window,
/// once for each new set of problems.
fn reportSettings() void {
    const r = &conf_saved.report;
    const key: u64 = if (r.count == 0) 0 else (@as(u64, r.count) << 48) | (@as(u64, r.first_line) << 8) | r.msg_len;
    if (key == report_key) return;
    report_key = key;
    if (key == 0) return;
    var mb: [32]u8 = undefined;
    const more = if (r.count > 1) std.fmt.bufPrint(&mb, " (and {d} more)", .{r.count - 1}) catch "" else "";
    var buf: [200]u8 = undefined;
    toastFront(std.fmt.bufPrint(&buf, "config.toml line {d}: {s}{s}", .{ r.first_line, r.firstMessage(), more }) catch "config.toml has a line Zag can't read");
}

/// Applies `conf_saved` to every window; `old_conf` is what they showed.
fn applySettings(old_conf: settings.Settings) void {
    const old_lh = lh;
    const old_themes = themes;
    conf = conf_saved;
    if (conf.late_night) conf.lateNight();
    var fonts_changed = false;
    var text_moves = false;
    var side_moves = false;
    var zen_changed = false;
    var look_changed = false;
    var caret_changed = false;
    var indent_changed = false;
    var hidden_changed = false;
    for (std.enums.values(settings.Opt)) |o| if (!settings.same(&old_conf, &conf, o)) switch (o) {
        .font, .size, .@"line-height" => {
            fonts_changed = true;
            text_moves = true;
            side_moves = true;
        },
        .sidebar, .@"sidebar-width" => {
            text_moves = true;
            side_moves = true;
        },
        .wrap, .@"line-numbers", .typewriter, .@"zen-columns", .@"hanging-indent" => text_moves = true,
        .@"tab-width" => {
            text_moves = true;
            indent_changed = true;
        },
        .@"indent-with" => indent_changed = true,
        .zen => {
            text_moves = true;
            zen_changed = true;
        },
        .@"late-night", .appearance => look_changed = true,
        .@"caret-style", .@"caret-width", .@"caret-blink" => caret_changed = true,
        .@"show-hidden" => hidden_changed = true,
        // Colors, Focus, bracket pairs, the caret line's band, marks and
        // guides, the word count and what saving does leave every line
        // where it is: the redraw below picks them up.
        .pairs, .focus, .@"light-theme", .@"dark-theme", .@"trim-trailing-whitespace", .@"ensure-final-newline", .@"highlight-current-line", .@"show-invisibles", .@"indent-guides", .@"word-count", .@"focus-dim", .@"late-night-warmth" => {},
    };
    buildThemes();
    // A theme or appearance pick crossfades, and so does Late-Night; zen's own change doesn't.
    const crossfade = look_changed or (!zen_changed and !std.meta.eql(old_themes, themes));
    side_w = conf.sidebar_width;
    if (font == null or fonts_changed) setFont();
    preview.setTypography(conf.font(), conf.size, conf.spacing);
    if (hidden_changed) {
        tree.show_hidden = conf.show_hidden;
        tree_stale = true;
        if (root != null and !restoring) rebuildTree();
    }
    // The icons take the size and the caret and muted colors.
    for (old_themes, themes) |a, b| {
        if (old_conf.size != conf.size or !std.mem.eql(f64, &a.caret, &b.caret) or !std.mem.eql(f64, &a.muted, &b.muted)) {
            dropIcons();
            break;
        }
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
        if (side_moves) w.side_find = true;
        msg(void, w.window, "invalidateCursorRectsForView:", .{w.view});
    }
    for (docs.items) |d| {
        d.dark = null;
        if (indent_changed) for (0..tabCount(d)) |j| styleEditor(&tabPage(d, j).ed);
        // The status strip's word count may come or go.
        d.stat_at[0] = std.math.maxInt(u64);
        if (caret_changed) {
            d.caret_at = null;
            if (d.shown and d.caret_on) blink(d.caret);
        }
        if (text_moves) {
            for (0..tabCount(d)) |j| {
                const pg = tabPage(d, j);
                pg.sy = pg.sy / old_lh * lh;
                // Tab width and hanging indent change where rows wrap.
                pg.ed.buf.wraps_cols = 0;
            }
            d.ys.snap(d.file.sy);
            d.band_on = false;
            d.snap = true;
            reveal(d);
        }
        refresh(d);
    }
}

fn isConf(path: ?[]const u8) bool {
    const p = path orelse return false;
    const c = conf_path orelse return false;
    return std.mem.eql(u8, p, c);
}

/// Rewrites one line of the settings file and applies it. An open
/// config.toml with unsaved edits gets the same line in its text, as an
/// undoable edit, instead of a reload that would ask to drop those edits.
fn store(opt: settings.Opt, value: []const u8) void {
    const p = conf_path orelse return;
    const before = files.stamp(p);
    settings.store(gpa, p, &conf_saved, opt, value) catch return alert("Couldn't write the settings file.", p);
    loadSettings();
    for (docs.items) |d| if (isConf(d.file.path)) {
        if (d.file.ed.buf.dirty() and std.meta.eql(d.file.stamp, before)) {
            setConfLine(d, opt, value) catch {};
            d.file.stamp = files.stamp(p);
            refresh(d);
        } else checkOutside(d);
    };
}

/// Sets the `opt` line in the doc's own text, replacing only the bytes that
/// differ, with the caret and selection shifted past the change.
fn setConfLine(d: *Doc, opt: settings.Opt, value: []const u8) !void {
    const e = &d.file.ed;
    const old = e.text();
    const new = try settings.setLine(gpa, old, opt, value);
    defer gpa.free(new);
    var a: usize = 0;
    while (a < old.len and a < new.len and old[a] == new[a]) a += 1;
    var z: usize = 0;
    while (z < old.len - a and z < new.len - a and old[old.len - 1 - z] == new[new.len - 1 - z]) z += 1;
    const end = old.len - z;
    const grown = new.len - z;
    const cur = if (e.cur >= end) e.cur - end + grown else @min(e.cur, grown);
    const anchor = if (e.anchor >= end) e.anchor - end + grown else @min(e.anchor, grown);
    try e.buf.replace(gpa, a, end, new[a..grown], e.cur, false);
    e.select(anchor, cur);
}

// ---- the settings file, watched ----

extern var _dispatch_source_type_vnode: anyopaque;
extern fn dispatch_source_create(kind: *anyopaque, handle: usize, mask: usize, queue: *anyopaque) ?*anyopaque;
extern fn dispatch_source_set_event_handler_f(src: *anyopaque, f: *const fn (?*anyopaque) callconv(.c) void) void;
extern fn dispatch_source_set_cancel_handler_f(src: *anyopaque, f: *const fn (?*anyopaque) callconv(.c) void) void;
extern fn dispatch_set_context(obj: *anyopaque, ctx: ?*anyopaque) void;
extern fn dispatch_resume(obj: *anyopaque) void;
extern fn dispatch_source_cancel(src: *anyopaque) void;
extern fn dispatch_release(obj: *anyopaque) void;

/// DISPATCH_VNODE_DELETE | WRITE | EXTEND | RENAME | REVOKE.
const vnode_events: usize = 0x1 | 0x2 | 0x4 | 0x20 | 0x40;
/// The sources on the settings file and on its folder; null when not open.
var conf_watch: [2]?*anyopaque = .{ null, null };

fn closeWatchFd(ctx: ?*anyopaque) callconv(.c) void {
    _ = std.c.close(@intCast(@intFromPtr(ctx)));
}

/// A vnode source on `p` that runs `confChanged` on the main queue, or null.
fn watchPath(p: [*:0]const u8) ?*anyopaque {
    const fd = std.c.open(p, .{ .EVTONLY = true, .CLOEXEC = true });
    if (fd < 0) return null;
    const src = dispatch_source_create(&_dispatch_source_type_vnode, @intCast(fd), vnode_events, &_dispatch_main_q) orelse {
        _ = std.c.close(fd);
        return null;
    };
    dispatch_set_context(src, @ptrFromInt(@as(usize, @intCast(fd))));
    dispatch_source_set_event_handler_f(src, confChanged);
    dispatch_source_set_cancel_handler_f(src, closeWatchFd);
    dispatch_resume(src);
    return src;
}

/// Watches the settings file, for edits in place, and its folder, for saves
/// that replace the file. A replaced or deleted file ends its own watch, so
/// every event opens both again. Nothing runs while the file doesn't change.
fn watchConf() void {
    const p = conf_path orelse return;
    for (&conf_watch) |*w| if (w.*) |src| {
        dispatch_source_cancel(src);
        dispatch_release(src);
        w.* = null;
    };
    files.makeParent(p) catch return;
    var buf: [std.c.PATH_MAX]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&buf, "{s}", .{std.fs.path.dirname(p) orelse return}, 0) catch return;
    conf_watch = .{ watchPath(dir), watchPath(p) };
}

fn confChanged(_: ?*anyopaque) callconv(.c) void {
    watchConf();
    recheckSettings();
}

/// Applies the settings file if it changed since Zag last read or wrote it,
/// so Zag's own writes don't apply twice. A deleted file keeps the current
/// settings until it comes back.
fn recheckSettings() void {
    const p = conf_path orelse return;
    const now = files.stamp(p);
    if (now != null and !std.meta.eql(now, conf_stamp)) loadSettings();
}

pub fn openSettings() void {
    const p = conf_path orelse return;
    settings.ensure(gpa, p, &conf_saved) catch return alert("Couldn't write the settings file.", p);
    loadSettings();
    openFile(conf_path.?);
}

/// Zag > Reveal Config in Finder.
fn revealConfig() void {
    const p = conf_path orelse return;
    settings.ensure(gpa, p, &conf_saved) catch return alert("Couldn't write the settings file.", p);
    revealPath(p);
}

/// Zag > Reload Settings: reads config.toml again, naming its problems again.
fn reloadSettings() void {
    toastFront("Settings reloaded");
    report_key = 0;
    loadSettings();
}

/// Zag > Reset Settings to Defaults…: after asking, config.toml goes to the
/// Trash and a new one with every default takes its place.
fn resetSettings() void {
    const p = conf_path orelse return;
    if (askAlert("Reset all settings to their defaults?", "Zag moves your config.toml to the Trash and writes a new one with every setting at its default.", &.{ "Reset", "Cancel" }) != 1000) return;
    if (files.exists(p) and !trash(p)) return alert("Couldn't move the settings file to the Trash.", p);
    zoom_due = false;
    settings.prepare(gpa, p);
    report_key = 0;
    loadSettings();
    watchConf();
    for (docs.items) |d| if (isConf(d.file.path)) checkOutside(d);
    toastFront("Settings reset to their defaults");
}

/// Moves `p` to the Trash. False when it couldn't.
fn trash(p: []const u8) bool {
    const url = msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(p)});
    const fm = msg(Id, objc.class("NSFileManager"), "defaultManager", .{});
    return msg(bool, fm, "trashItemAtURL:resultingItemURL:error:", .{ url, @as(?*anyopaque, null), @as(?*anyopaque, null) });
}

/// Shows `p` selected in a Finder window.
fn revealPath(p: []const u8) void {
    const url = msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(p)});
    const urls = msg(Id, objc.class("NSArray"), "arrayWithObject:", .{url});
    msg(void, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "activateFileViewerSelectingURLs:", .{urls});
}

/// Writes the opposite of flag `opt` to the settings file.
pub fn flip(comptime opt: settings.Opt) void {
    const name = comptime blk: {
        var chars = @tagName(opt).*;
        std.mem.replaceScalar(u8, chars[0..], '-', '_');
        break :blk chars;
    };
    store(opt, if (@field(conf_saved, &name)) "false" else "true");
}

pub fn toggleTypewriter() void {
    if (!conf.late_night) flip(.typewriter);
}

pub fn pickFocus(i: usize) void {
    if (conf.late_night) return;
    if (i < std.enums.values(settings.Focus).len) store(.focus, @tagName(@as(settings.Focus, @enumFromInt(i))));
}

/// Leaving zen the usual way while Late-Night is on ends Late-Night.
pub fn toggleZen() void {
    if (conf.late_night) flip(.@"late-night") else flip(.zen);
}

/// Makes built-in theme `i` the one for its own mode, light or dark.
pub fn pickScheme(i: usize) void {
    if (i >= settings.schemes.len or conf.late_night) return;
    const sc = settings.schemes[i];
    store(if (sc.dark) .@"dark-theme" else .@"light-theme", sc.key);
}

/// View > Theme > Appearance: 0 Auto, 1 Light, 2 Dark.
pub fn pickLook(i: usize) void {
    if (i >= std.enums.values(settings.Look).len or conf.late_night) return;
    store(.appearance, @tagName(@as(settings.Look, @enumFromInt(i))));
}

// ---- prompt ----

/// Quick open and the palette keep this many best picks; their list shows
/// `list_rows` at a time and scrolls through the rest.
const max_picks = 32;
const list_rows = 10;

/// Find's match-case and whole-word rules, shared by every card and kept
/// from one find to the next.
var find_opts: editor.SearchOpts = .{};

/// One undo step of a prompt field: which field, its text and its selection.
const PromptStep = struct { which: u1, text: []u8, anc: usize, cur: usize };
const max_steps = 100;

/// Recent queries, oldest first: find's searches, replace's replacements
/// and go to line's lines.
const max_hist = 50;
var hists: [3]std.ArrayList([]u8) = @splat(.empty);

/// How long find's "wrapped" cue shows, fading in and out.
const wrap_time = 1.2;
/// Find's ticks along the card's edge stop at this many rows.
const max_ticks = 2000;

fn startPrompt(d: *Doc, m: Mode) void {
    // A prompt takes the keys back from the sidebar.
    if (d.win.side_key) {
        d.win.side_key = false;
        redrawSide(d.win);
    }
    d.mode = m;
    d.prompt.clearRetainingCapacity();
    d.pband_shown = false;
    d.pband_w = 0;
    d.pscroll = .{ 0, 0 };
    d.pcur = .{ 0, 0 };
    d.panc = .{ 0, 0 };
    d.hist_at = null;
    d.ptyping = false;
    d.pdrag = false;
    d.phover = null;
    dropSteps(&d.pundo);
    dropSteps(&d.predo);
    const was_palette = d.palette;
    switch (m) {
        .find, .replace => {
            d.which = 0;
            const e = &d.file.ed;
            const s = e.sel();
            d.origin_sel = .{ e.anchor, e.cur };
            d.origin_sy = d.file.sy;
            d.stepped = false;
            // The selection on one line, else the word at the caret, which
            // becomes the current match, else the last search.
            var seed: []const u8 = d.query.items;
            var from = s[0];
            if (s[0] != s[1]) {
                const picked = e.text()[s[0]..s[1]];
                if (std.mem.indexOfAny(u8, picked, "\r\n") == null) seed = picked;
            } else if (caretWord(e)) |w| {
                seed = e.text()[w[0]..w[1]];
                from = w[0];
                e.select(w[0], w[1]);
            }
            d.prompt.appendSlice(gpa, seed) catch {};
            // Both fields start selected, so typing replaces them.
            d.pcur = .{ d.prompt.items.len, d.with.items.len };
            d.origin = from;
            countFound(d);
        },
        .open => {
            d.palette = false;
            // Without a folder, quick open lists the folder of the file on screen.
            const r = root orelse blk: {
                const p = d.file.path orelse {
                    d.mode = .edit;
                    toast(d.win, "open a folder first (⌘O)");
                    return refresh(d);
                };
                setRoot(gpa.dupe(u8, std.fs.path.dirname(p) orelse "/") catch return);
                break :blk root.?;
            };
            if (quick != null and quick_root != null and std.mem.eql(u8, quick_root.?, r) and quick_hidden == conf.show_hidden) {
                pickFiles(d, true);
                bgRescanQuick(r, conf.show_hidden);
            } else {
                rescanQuick(r, if (was_palette) d else null);
            }
        },
        .command => {
            listCommands();
            d.palette = true;
            pickFiles(d, d.palette != was_palette);
        },
        else => {},
    }
    // Find's pills get their tooltips.
    msg(void, d.win.window, "invalidateCursorRectsForView:", .{d.win.view});
    refresh(d);
}

/// A byte that's part of a word, for find's prefill and a field's word moves.
fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// The word the caret is in or just after, for find's prefill.
fn caretWord(e: *const Editor) ?[2]usize {
    const t = e.text();
    for ([_]usize{ e.cur, e.cur -| 1 }) |p| {
        if (p >= t.len or !wordByte(t[p])) continue;
        const w = e.wordAt(p) orelse continue;
        if (w[0] < w[1]) return w;
    }
    return null;
}

/// The names quick open or the palette picks from, while it's open.
fn listing(d: *const Doc) ?[]const []const u8 {
    return switch (d.mode) {
        .open => if (quick) |*l| l.paths.items else null,
        .command => cmd_names.items,
        else => null,
    };
}

fn pickFiles(d: *Doc, fresh: bool) void {
    const names = listing(d) orelse return;
    // Rows that change under the typing crossfade from the last picks.
    d.prev_picks = d.picks;
    const live = d.pick_live and !fresh;
    d.prev_n = if (live) d.npicks else 0;
    d.prev_none = live and d.npicks == 0;
    d.pick_t0 = CACurrentMediaTime();
    const q = d.prompt.items;
    const has_q = std.mem.trim(u8, q, " ").len > 0;
    if (d.mode == .open) {
        var boosts: [32]finder.Boost = undefined;
        const b = quickBoosts(d, &boosts, q);
        if (has_q) {
            d.npicks = finder.bestCounted(names, q, b, &d.picks, &d.pmatches);
        } else {
            d.npicks = finder.bestWithBoost(names, q, &d.picks, b);
            d.pmatches = names.len;
        }
    } else {
        if (has_q) {
            d.npicks = finder.bestCounted(names, q, &.{}, &d.picks, &d.pmatches);
        } else {
            d.npicks = finder.best(names, q, &d.picks);
            d.pmatches = names.len;
        }
    }
    d.pick = 0;
    d.plist.snap(0);
}

/// Quick open's boosts: the recent files, newest first, and the cards'
/// open tabs, leaving out the file on show. An empty search lists them
/// first; typing still favors them a little.
fn quickBoosts(d: *const Doc, out: []finder.Boost, q: []const u8) []const finder.Boost {
    const empty = std.mem.trim(u8, q, " ").len == 0;
    const here = d.file.path orelse "";
    var n: usize = 0;
    const recent = recentFiles();
    for (0..msg(usize, recent, "count", .{})) |i| {
        if (n == out.len) return out[0..n];
        const p = objc.utf8(msg(Id, recent, "objectAtIndex:", .{i}));
        if (std.mem.eql(u8, p, here)) continue;
        const rel = relOf(p) orelse continue;
        out[n] = .{ .path = rel, .amount = if (empty) 4000 - @as(i32, @intCast(@min(i, 30))) * 100 else 256 };
        n += 1;
    }
    for (docs.items) |o| {
        if (o.closing) continue;
        for (0..tabCount(o)) |j| {
            if (n == out.len) return out[0..n];
            const p = tabPage(o, j).path orelse continue;
            if (std.mem.eql(u8, p, here)) continue;
            const rel = relOf(p) orelse continue;
            out[n] = .{ .path = rel, .amount = if (empty) 5000 else 384 };
            n += 1;
        }
    }
    return out[0..n];
}

// ---- command palette ----

/// A menu item the palette lists, with its shortcut, whether it's checked,
/// and whether Late-Night has set it, which dims it.
const Command = struct { item: Id, act: Sel, tag: isize, keys: []const u8, on: bool, grey: bool };
var cmd_arena: std.heap.ArenaAllocator = .init(gpa);
var cmd_names: std.ArrayList([]const u8) = .empty;
var cmds: std.ArrayList(Command) = .empty;

/// Lists every command in the menu bar, the View menu's first since the
/// palette is mostly for settings. Running one runs its menu item, so the
/// palette never needs its own copy of a command.
fn listCommands() void {
    // Each item is retained, so one that AppKit drops while the palette is
    // open stays safe to run.
    for (cmds.items) |c| msg(void, c.item, "release", .{});
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
    const palette_sel = objc.sel_registerName("commandPalette:");
    const scheme_sel = objc.sel_registerName("pickScheme:");
    // AppKit's own entries for each open window in the Window menu.
    const window_sel = objc.sel_registerName("makeKeyAndOrderFront:");
    // Help > Keyboard Shortcuts opens this palette.
    const shortcuts_sel = objc.sel_registerName("showShortcuts:");
    const services = msg(Id, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "servicesMenu", .{});
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
            // Open Recent fills itself only as it opens; Services is other apps'.
            if (msg(Id, sub, "delegate", .{}) == null and sub != services) addCommands(sub, title);
            continue;
        }
        const act = msg(Sel, it, "action", .{});
        if (act == null or objc.sel_getName(act)[0] == 0) {
            section = title;
            continue;
        }
        // The same command in two menus, or under a second key, is listed once.
        const tag = msg(isize, it, "tag", .{});
        if (act == palette_sel or act == window_sel or act == shortcuts_sel or listedAlready(act, tag)) continue;
        // Each built-in theme is a command of its own: "Theme: Paper (Light)".
        const name = (if (act == scheme_sel)
            std.fmt.allocPrint(a, "Theme: {s} ({s})", .{ title, if (settings.schemes[@intCast(tag)].dark) "Dark" else "Light" })
        else if (section.len > 0)
            std.fmt.allocPrint(a, "{s}: {s}", .{ section, title })
        else
            a.dupe(u8, title)) catch return;
        cmd_names.append(a, name) catch return;
        cmds.append(a, .{ .item = msg(Id, it, "retain", .{}), .act = act, .tag = tag, .keys = keysOf(a, it) catch "", .on = isChecked(it), .grey = greyed(it) }) catch {
            msg(void, it, "release", .{});
            return;
        };
    }
}

/// Whether the palette already lists a command that runs `act` with `tag`.
fn listedAlready(act: Sel, tag: isize) bool {
    for (cmds.items) |c| {
        if (c.act == act and c.tag == tag) return true;
    }
    return false;
}

/// A menu item's shortcut as the menu shows it, like ⇧⌘S.
fn keysOf(a: std.mem.Allocator, it: Id) ![]const u8 {
    const key = objc.utf8(msg(Id, it, "keyEquivalent", .{}));
    if (key.len == 0) return "";
    const mods = msg(usize, it, "keyEquivalentModifierMask", .{});
    var out: std.ArrayList(u8) = .empty;
    if (mods & objc.ctrl_key != 0) try out.appendSlice(a, "⌃");
    if (mods & objc.opt_key != 0) try out.appendSlice(a, "⌥");
    if (mods & objc.shift_key != 0) try out.appendSlice(a, "⇧");
    if (mods & objc.cmd_key != 0) try out.appendSlice(a, "⌘");
    if (keyGlyph(key)) |g| {
        try out.appendSlice(a, g);
    } else for (key) |ch| try out.append(a, std.ascii.toUpper(ch));
    return out.items;
}

/// How a menu shows a key that isn't a letter: Tab (and ⇧Tab's back tab),
/// Return and Enter, the deletes, Escape, Space, the arrows and the page keys.
fn keyGlyph(key: []const u8) ?[]const u8 {
    const glyphs = [_][2][]const u8{
        .{ "\t", "⇥" },
        .{ "\x19", "⇥" },
        .{ "\r", "↩" },
        .{ "\x03", "⌤" },
        .{ "\x08", "⌫" },
        .{ "\x7f", "⌫" },
        .{ "\u{F728}", "⌦" },
        .{ "\x1b", "⎋" },
        .{ " ", "␣" },
        .{ "\u{F700}", "↑" },
        .{ "\u{F701}", "↓" },
        .{ "\u{F702}", "←" },
        .{ "\u{F703}", "→" },
        .{ "\u{F729}", "↖" },
        .{ "\u{F72B}", "↘" },
        .{ "\u{F72C}", "⇞" },
        .{ "\u{F72D}", "⇟" },
    };
    for (glyphs) |g| if (std.mem.eql(u8, key, g[0])) return g[1];
    return null;
}

/// Runs a palette pick after the event that chose it, so a command that
/// closes the window doesn't pull the window out from under the prompt.
fn runCommand(_: Id, _: Sel, it: Id) callconv(.c) void {
    const menu = msg(Id, it, "menu", .{});
    if (menu == null) return;
    const i = msg(isize, menu, "indexOfItem:", .{it});
    if (i >= 0 and !greyed(it)) msg(void, menu, "performActionForItemAtIndex:", .{i});
}

fn countFound(d: *Doc) void {
    const t = d.file.ed.text();
    const q = d.prompt.items;
    d.found = editor.countMatchesWith(t, q, d.file.ed.sel()[0], find_opts);
    d.found[0] += 1;
}

/// "3 of 12" for a full count; past `count_cap`, "3 of 10000+", or
/// "10000+ matches" when the current match lies beyond the counted ones.
fn foundTally(buf: []u8, found: [2]usize) []const u8 {
    const cap = editor.count_cap;
    if (found[1] == 0) return "no matches";
    if (found[1] < cap) return std.fmt.bufPrint(buf, "{d} of {d}", .{ @min(found[0], found[1]), found[1] }) catch "";
    if (found[0] <= cap) return std.fmt.bufPrint(buf, "{d} of {d}+", .{ found[0], cap }) catch "";
    return std.fmt.bufPrint(buf, "{d}+ matches", .{cap}) catch "";
}

/// The prompt field that takes typing: the replacement, or the search.
fn field(d: *Doc) *std.ArrayList(u8) {
    return fieldAt(d, fieldIndex(d));
}

/// Which field takes typing: 1 for replace's replacement, else 0.
fn fieldIndex(d: *const Doc) u1 {
    return if (d.mode == .replace and d.which == 1) 1 else 0;
}

fn fieldAt(d: *Doc, i: u1) *std.ArrayList(u8) {
    return if (i == 1) &d.with else &d.prompt;
}

/// The typing field's selection, low end first.
fn fieldSel(d: *const Doc) [2]usize {
    const i = fieldIndex(d);
    return .{ @min(d.panc[i], d.pcur[i]), @max(d.panc[i], d.pcur[i]) };
}

/// Moves the typing field's caret to `pos`; `extend` keeps the anchor.
fn fieldTo(d: *Doc, pos: usize, extend: bool) void {
    const i = fieldIndex(d);
    d.pcur[i] = @min(pos, fieldAt(d, i).items.len);
    if (!extend) d.panc[i] = d.pcur[i];
    d.ptyping = false;
}

fn dropSteps(list: *std.ArrayList(PromptStep)) void {
    for (list.items) |s| gpa.free(s.text);
    list.clearRetainingCapacity();
}

/// The typing field as it is now, as an undo or redo step.
fn stepNow(d: *Doc) ?PromptStep {
    const i = fieldIndex(d);
    return .{ .which = i, .text = gpa.dupe(u8, fieldAt(d, i).items) catch return null, .anc = d.panc[i], .cur = d.pcur[i] };
}

fn pushStep(list: *std.ArrayList(PromptStep), s: PromptStep) void {
    if (list.items.len >= max_steps) gpa.free(list.orderedRemove(0).text);
    list.append(gpa, s) catch gpa.free(s.text);
}

/// Replaces the typing field's selection with `s` and runs the prompt's
/// search again. A letter typed right after another joins its undo step.
fn fieldPut(d: *Doc, s: []const u8, typing: bool) void {
    const i = fieldIndex(d);
    const into = fieldAt(d, i);
    const r = fieldSel(d);
    if (!(typing and d.ptyping and r[0] == r[1])) {
        if (stepNow(d)) |st| pushStep(&d.pundo, st);
        dropSteps(&d.predo);
    }
    into.replaceRange(gpa, r[0], r[1] - r[0], s) catch return;
    d.pcur[i] = r[0] + s.len;
    d.panc[i] = d.pcur[i];
    d.ptyping = typing;
    d.hist_at = null;
    promptChanged(d);
}

/// Sets the typing field to `s` with the caret at its end, as one undo step.
fn fieldSet(d: *Doc, s: []const u8) void {
    const i = fieldIndex(d);
    d.panc[i] = 0;
    d.pcur[i] = fieldAt(d, i).items.len;
    const keep = d.hist_at;
    fieldPut(d, s, false);
    d.hist_at = keep;
}

/// ⌘Z (and ⇧⌘Z, `redo`) while a prompt is open steps its fields' typing
/// back (and forth).
fn promptUndo(d: *Doc, redo: bool) void {
    const from = if (redo) &d.predo else &d.pundo;
    const to = if (redo) &d.pundo else &d.predo;
    const st = from.pop() orelse return;
    defer gpa.free(st.text);
    if (d.mode == .replace) d.which = st.which;
    if (stepNow(d)) |now_st| pushStep(to, now_st);
    const into = fieldAt(d, st.which);
    into.clearRetainingCapacity();
    into.appendSlice(gpa, st.text) catch {};
    d.panc[st.which] = @min(st.anc, into.items.len);
    d.pcur[st.which] = @min(st.cur, into.items.len);
    d.ptyping = false;
    d.hist_at = null;
    promptChanged(d);
}

/// Typing in the prompt (`typing`), or a paste. Go to line takes a line,
/// `line:column`, or `+N` and `-N` lines from the caret's.
fn promptType(d: *Doc, s: []const u8, typing: bool) void {
    if (d.mode != .line) return fieldPut(d, s, typing);
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (n < buf.len and (std.ascii.isDigit(c) or c == ':' or c == '+' or c == '-')) {
            buf[n] = c;
            n += 1;
        }
    }
    if (n > 0) fieldPut(d, buf[0..n], typing);
}

fn promptChanged(d: *Doc) void {
    switch (d.mode) {
        .find, .replace => if (fieldIndex(d) == 0) {
            d.stepped = false;
            const e = &d.file.ed;
            if (!e.findWith(d.prompt.items, d.origin, false, find_opts)) e.select(d.origin, d.origin);
            remember(d);
            countFound(d);
            center(d);
        },
        .open, .command => pickFiles(d, false),
        else => {},
    }
}

/// Keeps the search for ⌘G after the prompt closes.
fn remember(d: *Doc) void {
    d.query.clearRetainingCapacity();
    d.query.appendSlice(gpa, d.prompt.items) catch {};
}

/// The history the typing field steps through: find's searches (0),
/// replacements (1) or lines (2); none for quick open and the palette.
fn histOf(d: *const Doc) ?usize {
    return switch (d.mode) {
        .find => 0,
        .replace => @as(usize, fieldIndex(d)),
        .line => 2,
        else => null,
    };
}

/// Adds `s` to history `h` as its newest, dropping an older copy.
fn noteQuery(h: usize, s: []const u8) void {
    if (s.len == 0) return;
    const list = &hists[h];
    for (list.items, 0..) |x, i| {
        if (!std.mem.eql(u8, x, s)) continue;
        gpa.free(list.orderedRemove(i));
        break;
    }
    if (list.items.len >= max_hist) gpa.free(list.orderedRemove(0));
    const own = gpa.dupe(u8, s) catch return;
    list.append(gpa, own) catch gpa.free(own);
}

/// Keeps what the prompt's fields hold in their histories, as it runs or closes.
fn noteQueries(d: *Doc) void {
    d.hist_at = null;
    switch (d.mode) {
        .find => noteQuery(0, d.prompt.items),
        .replace => {
            noteQuery(0, d.prompt.items);
            noteQuery(1, d.with.items);
        },
        .line => noteQuery(2, d.prompt.items),
        else => {},
    }
}

/// ↑ (`older`) and ↓ in find, replace and go to line: the field steps
/// through its recent queries, and past the newest back to what was typed.
fn stepQuery(d: *Doc, older: bool) void {
    const h = &hists[histOf(d) orelse return];
    const n = h.items.len;
    if (n == 0) return;
    var at: usize = undefined;
    if (d.hist_at) |i| {
        if (older) {
            if (i == 0) return;
            at = i - 1;
        } else if (i + 1 < n) {
            at = i + 1;
        } else {
            d.hist_at = null;
            return fieldSet(d, d.hist_draft.items);
        }
    } else {
        if (!older) return;
        d.hist_draft.clearRetainingCapacity();
        d.hist_draft.appendSlice(gpa, field(d).items) catch {};
        at = n - 1;
        // The newest is skipped when the field already holds it.
        if (std.mem.eql(u8, h.items[at], field(d).items)) {
            if (at == 0) return;
            at -= 1;
        }
    }
    d.hist_at = at;
    fieldSet(d, h.items[at]);
}

/// Enter in the prompt.
fn accept(d: *Doc) void {
    const q = d.prompt.items;
    noteQueries(d);
    switch (d.mode) {
        .find => {
            remember(d);
            findAgain(d, shiftHeld());
        },
        .line => {
            if (std.mem.trim(u8, q, " ").len == 0) {
                d.mode = .edit;
                return;
            }
            // A line it can't read shakes the prompt, which stays open.
            const to = lineTarget(d, q) orelse {
                d.shake_t0 = CACurrentMediaTime();
                return;
            };
            d.mode = .edit;
            const e = &d.file.ed;
            e.moveTo(to, false);
            // The line it lands on flashes.
            const row = e.buf.lineOf(to);
            flashStart(d);
            flashAdd(d, e.buf.lineStart(row), e.buf.lineStop(row));
            center(d);
        },
        .open => openPick(d, .here),
        .command => {
            if (d.npicks == 0) return;
            const c = cmds.items[d.picks[d.pick]];
            // A command Late-Night set stays put and says why.
            if (c.grey) return toast(d.win, late_night_why);
            d.mode = .edit;
            objc.later(d.win.view, "runCommand:", c.item, 0);
        },
        .replace => {
            remember(d);
            d.stepped = true;
            const e = &d.file.ed;
            const s = e.sel();
            const with = d.with.items;
            const replaced = e.replaceOneWith(gpa, q, with, find_opts) catch false;
            // Each replacement flashes where it went in.
            if (replaced) {
                flashStart(d);
                flashAdd(d, s[0], s[0] + with.len);
            }
            _ = findStep(d, q, if (replaced) e.cur else s[0], false);
            countFound(d);
            center(d);
        },
        .edit => {},
    }
}

/// Where go to line's `q` points: `line`, `line:column`, `:column` on the
/// caret's line, or `+N` and `-N` lines from the caret's, each with an
/// optional `:column`. Lines and columns count from 1 and stop at the ends.
fn lineTarget(d: *Doc, q: []const u8) ?usize {
    const b = &d.file.ed.buf;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, q, " "), ':');
    const row_s = it.next() orelse return null;
    const col_s = it.next();
    if (it.next() != null) return null;
    const lines = b.lines();
    const here = b.lineOf(d.file.ed.cur);
    var row = here;
    if (row_s.len > 0 and (row_s[0] == '+' or row_s[0] == '-')) {
        const n = std.fmt.parseInt(usize, row_s[1..], 10) catch return null;
        row = if (row_s[0] == '+') @min(here +| n, lines - 1) else here -| n;
    } else if (row_s.len > 0 or col_s == null) {
        const n = std.fmt.parseInt(usize, row_s, 10) catch return null;
        row = @min(@max(n, 1), lines) - 1;
    }
    var col: usize = 0;
    if (col_s) |c| if (c.len > 0) {
        col = (std.fmt.parseInt(usize, c, 10) catch return null) -| 1;
    };
    const l = b.line(row);
    var i: usize = 0;
    while (col > 0 and i < l.len) : (col -= 1) i = editor.nextChar(l, i);
    return b.lineStart(row) + i;
}

/// ⌥Return in find and replace.
fn replaceAll(d: *Doc) void {
    noteQueries(d);
    remember(d);
    var spots: [max_flash][2]usize = undefined;
    const q = d.prompt.items;
    const n = d.file.ed.replaceAllWith(gpa, q, d.with.items, &spots, find_opts) catch 0;
    if (n > 0) {
        flashStart(d);
        for (spots[0..@min(n, spots.len)]) |sp| flashAdd(d, sp[0], sp[1]);
    }
    d.mode = .edit;
    var buf: [64]u8 = undefined;
    toast(d.win, if (n == 0) "no matches to replace" else std.fmt.bufPrint(&buf, "replaced {d} · ⌘Z to undo", .{n}) catch "");
    center(d);
}

/// Selects the match of `q` from `from` on (or the last before it, `back`),
/// noting a wrap past the file's end or start: the prompt shows "wrapped",
/// and with it closed a note says where to. False when there's none.
fn findStep(d: *Doc, q: []const u8, from: usize, back: bool) bool {
    const e = &d.file.ed;
    if (!e.findWith(q, from, back, find_opts)) return false;
    d.jumped = true;
    const p = e.sel()[0];
    if (if (back) p >= from else p < from) {
        d.wrap_t0 = CACurrentMediaTime();
        if (d.mode == .edit) toast(d.win, if (back) "wrapped to the end" else "wrapped to the top");
    }
    return true;
}

fn findAgain(d: *Doc, back: bool) void {
    const finding = d.mode == .find or d.mode == .replace;
    const q = if (finding) d.prompt.items else d.query.items;
    if (q.len == 0) return startPrompt(d, .find);
    const s = d.file.ed.sel();
    if (findStep(d, q, if (back) s[0] else s[0] + 1, back)) {
        d.stepped = true;
    } else if (finding) {
        d.shake_t0 = CACurrentMediaTime();
    } else toast(d.win, "no matches");
    if (finding) countFound(d);
    center(d);
}

fn shiftHeld() bool {
    const ev = msg(Id, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "currentEvent", .{});
    return msg(usize, ev, "modifierFlags", .{}) & objc.shift_key != 0;
}

/// Escape: the prompt closes. Find and replace put the selection and
/// scroll back as they were, unless Return or ⌘G stepped to a match.
fn cancelPrompt(d: *Doc) void {
    noteQueries(d);
    const finding = d.mode == .find or d.mode == .replace;
    d.mode = .edit;
    if (!finding or d.stepped) return;
    const n = d.file.ed.text().len;
    d.file.ed.select(@min(d.origin_sel[0], n), @min(d.origin_sel[1], n));
    d.file.sy = d.origin_sy;
    clampScroll(d);
}

const OpenHow = enum { here, tab, split };

/// Opens quick open's pick: Return the usual way, ⌘Return in a new tab
/// of this card, ⌥Return in a new card split off this one.
fn openPick(d: *Doc, how: OpenHow) void {
    if (d.mode != .open or d.npicks == 0) return;
    const paths = (quick orelse return).paths.items;
    if (d.picks[d.pick] >= paths.len) return;
    var buf: [std.c.PATH_MAX]u8 = undefined;
    const path = joinPath(&buf, root orelse return, paths[d.picks[d.pick]]) orelse return;
    d.mode = .edit;
    switch (how) {
        .here => open(path, d),
        .tab => placeFile(d.win, path, .{ .card = d, .zone = .tabs, .k = d.at + 1 }),
        .split => placeFile(d.win, path, .{ .card = d, .zone = if (roomFor(d, false)) .right else if (roomFor(d, true)) .bottom else .tabs, .k = d.at + 1 }),
    }
}

/// Flips find's match case (0) or whole word (1) for every find, and
/// searches each open find again from where it began.
fn toggleFind(d: *Doc, which: u1) void {
    if (which == 0) {
        find_opts.case_mode = if (find_opts.case_mode == .sensitive) .smart else .sensitive;
    } else find_opts.whole_word = !find_opts.whole_word;
    for (docs.items) |o| {
        if (o.mode != .find and o.mode != .replace) continue;
        const e = &o.file.ed;
        if (o.prompt.items.len > 0 and !e.findWith(o.prompt.items, o.origin, false, find_opts)) e.select(o.origin, o.origin);
        countFound(o);
        if (o == d) center(o);
        refresh(o);
    }
}

/// Moves the list's pick by `by` rows, stopping at its ends.
fn pickStep(d: *Doc, by: isize) void {
    if (d.npicks == 0) return;
    const to = @as(isize, @intCast(d.pick)) + by;
    d.pick = @intCast(std.math.clamp(to, 0, @as(isize, @intCast(d.npicks - 1))));
    showPick(d);
}

/// Glides the list so the pick is in view.
fn showPick(d: *Doc) void {
    const y = f(d.pick) * prow;
    var to = d.plist.to;
    if (y < to) to = y;
    if (y + prow > to + f(list_rows) * prow) to = y + prow - f(list_rows) * prow;
    d.plist.aim(to, CACurrentMediaTime());
}

/// Past the word after byte `from` of a prompt field, skipping what's before it.
fn wordEnd(t: []const u8, from: usize) usize {
    var i = from;
    while (i < t.len and !wordByte(t[i])) i += 1;
    while (i < t.len and wordByte(t[i])) i += 1;
    return i;
}

/// The word around byte `at` of a prompt field, or the character there
/// when it isn't in one, for a double-click.
fn fieldWord(t: []const u8, at: usize) [2]usize {
    var a = @min(at, t.len);
    if (!(a < t.len and wordByte(t[a])) and !(a > 0 and wordByte(t[a - 1]))) return .{ a, editor.nextCluster(t, a) };
    var z = a;
    while (a > 0 and wordByte(t[a - 1])) a -= 1;
    while (z < t.len and wordByte(t[z])) z += 1;
    return .{ a, z };
}

/// The byte of field `i` nearest `x` in the pane, as the field last drew.
fn fieldByte(d: *const Doc, i: u1, x: f64) usize {
    const t = if (i == 1) d.with.items else d.prompt.items;
    return editor.byteAtCol(t, @max(0, f(d.pscroll[i]) + (x - d.pfx[i]) / cw));
}

/// A click on the prompt line: on a find pill it flips it; in a field it
/// places the caret (⇧ extends), a double-click takes a word and a triple
/// the whole field. A drag from there selects (`promptDrag`).
fn promptDown(d: *Doc, p: Point, ev: Id) void {
    if (d.mode == .find or d.mode == .replace) for (d.tog_x, 0..) |t, k| {
        if (t[1] > 0 and p.x >= t[0] - 2 and p.x < t[0] + t[1] + 2) return toggleFind(d, @intCast(k));
    };
    if (d.mode == .replace) d.which = if (p.x >= d.pfx[1] - 3 * cw) 1 else 0;
    const i = fieldIndex(d);
    const t = fieldAt(d, i).items;
    const at = fieldByte(d, i, p.x);
    d.pdrag = true;
    d.pdrag_word = false;
    d.hist_at = null;
    switch (msg(isize, ev, "clickCount", .{})) {
        0, 1 => fieldTo(d, at, msg(usize, ev, "modifierFlags", .{}) & objc.shift_key != 0),
        2 => {
            const w = fieldWord(t, at);
            d.pdrag_word = true;
            d.pdrag_from = w;
            d.panc[i] = w[0];
            d.pcur[i] = w[1];
        },
        else => {
            d.panc[i] = 0;
            d.pcur[i] = t.len;
            d.pdrag = false;
        },
    }
    d.ptyping = false;
    refresh(d);
}

/// A drag from a click in a field moves its selection's far end, by words
/// after a double-click; past the field's ends it scrolls on.
fn promptDrag(d: *Doc, p: Point) void {
    if (d.mode == .edit) {
        d.pdrag = false;
        return;
    }
    const i = fieldIndex(d);
    const t = fieldAt(d, i).items;
    const at = fieldByte(d, i, p.x);
    if (d.pdrag_word) {
        const w = fieldWord(t, at);
        if (w[0] < d.pdrag_from[0]) {
            d.panc[i] = d.pdrag_from[1];
            d.pcur[i] = w[0];
        } else {
            d.panc[i] = d.pdrag_from[0];
            d.pcur[i] = @max(w[1], d.pdrag_from[1]);
        }
    } else d.pcur[i] = at;
    refresh(d);
}

fn oneOf(name: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |x| if (std.mem.eql(u8, name, x)) return true;
    return false;
}

/// Key commands while the prompt is open: the field's caret, selection and
/// deletes, ↑ and ↓ through the list's picks or the field's history, Tab
/// between replace's fields, Return, ⌥Return and Escape.
fn promptCommand(d: *Doc, full: []const u8) void {
    var name = full;
    var extend = false;
    if (std.mem.indexOf(u8, name, "AndModifySelection")) |at| {
        extend = true;
        name = name[0..at];
    }
    if (is(name, "insertNewline") or is(name, "insertLineBreak")) return accept(d);
    if (is(name, "insertNewlineIgnoringFieldEditor")) return switch (d.mode) {
        .replace => replaceAll(d),
        .open => openPick(d, .split),
        else => accept(d),
    };
    if (is(name, "cancelOperation")) return cancelPrompt(d);
    if (d.mode == .replace and (is(name, "insertTab") or is(name, "insertBacktab"))) {
        d.which ^= 1;
        d.ptyping = false;
        d.hist_at = null;
        return;
    }
    if (listing(d) != null) {
        const by: ?isize = if (is(name, "moveUp")) -1 else if (is(name, "moveDown")) 1 else if (is(name, "pageUp") or is(name, "scrollPageUp")) -list_rows else if (is(name, "pageDown") or is(name, "scrollPageDown")) list_rows else null;
        if (by) |n| return pickStep(d, n);
    } else if (is(name, "moveUp") or is(name, "moveDown")) return stepQuery(d, is(name, "moveUp"));
    const i = fieldIndex(d);
    const t = fieldAt(d, i).items;
    const cur = d.pcur[i];
    const r = fieldSel(d);
    // An arrow without ⇧ collapses a selection to its side.
    if (oneOf(name, &.{ "moveLeft", "moveBackward" })) return fieldTo(d, if (r[0] != r[1] and !extend) r[0] else editor.prevCluster(t, cur), extend);
    if (oneOf(name, &.{ "moveRight", "moveForward" })) return fieldTo(d, if (r[0] != r[1] and !extend) r[1] else editor.nextCluster(t, cur), extend);
    if (oneOf(name, &.{ "moveWordLeft", "moveWordBackward" })) return fieldTo(d, editor.wordLeft(t, cur), extend);
    if (oneOf(name, &.{ "moveWordRight", "moveWordForward" })) return fieldTo(d, wordEnd(t, cur), extend);
    if (oneOf(name, &.{ "moveToBeginningOfLine", "moveToLeftEndOfLine", "moveToBeginningOfParagraph", "moveParagraphBackward", "moveToBeginningOfDocument", "scrollToBeginningOfDocument" })) return fieldTo(d, 0, extend);
    if (oneOf(name, &.{ "moveToEndOfLine", "moveToRightEndOfLine", "moveToEndOfParagraph", "moveParagraphForward", "moveToEndOfDocument", "scrollToEndOfDocument" })) return fieldTo(d, t.len, extend);
    // A delete takes the selection when there is one, else what its key reaches.
    if (!std.mem.startsWith(u8, name, "delete")) return;
    var span = r;
    if (r[0] == r[1]) {
        if (oneOf(name, &.{ "deleteBackward", "deleteBackwardByDecomposingPreviousCharacter" })) {
            span[0] = editor.prevCluster(t, cur);
        } else if (is(name, "deleteWordBackward")) {
            span[0] = editor.wordLeft(t, cur);
        } else if (oneOf(name, &.{ "deleteToBeginningOfLine", "deleteToBeginningOfParagraph" })) {
            span[0] = 0;
        } else if (is(name, "deleteForward")) {
            span[1] = editor.nextCluster(t, cur);
        } else if (is(name, "deleteWordForward")) {
            span[1] = wordEnd(t, cur);
        } else if (oneOf(name, &.{ "deleteToEndOfLine", "deleteToEndOfParagraph" })) {
            span[1] = t.len;
        } else return;
    }
    if (span[0] == span[1]) return;
    d.panc[i] = span[0];
    d.pcur[i] = span[1];
    fieldPut(d, "", false);
}

fn is(name: []const u8, comptime want: []const u8) bool {
    return std.mem.eql(u8, name, want);
}

// ---- soft wrap ----

/// One screen row of a line: bytes `start..end`, with display columns
/// `col..ecol`. Without wrap every line is one row.
/// `tw` is the tab width the row was laid out with, and `ind` how many
/// columns a wrapped row's hanging indent moves it right.
const Seg = struct { k: usize = 0, start: usize = 0, col: usize = 0, end: usize = 0, ecol: usize = 0, tw: usize = editor.default_tab_width, ind: usize = 0 };

/// Rows wrap at the card's width once it's done springing, so a card that
/// grows or shrinks doesn't rewrap every frame.
fn wrapCols(d: *const Doc) usize {
    const room = @max(d.fin.x - 2 * gap - 2 * pad_x - gutter(d), 8 * cw);
    const cols: usize = @intFromFloat(room / cw);
    return if (conf.zen) @min(cols, conf.zen_columns) else cols;
}

/// Brings the row counts up to date after edits, a resize or a font change.
fn layout(d: *Doc) void {
    const b = &d.file.ed.buf;
    if (!wrapping()) {
        if (b.wraps.items.len > 0) b.wraps.clearAndFree(gpa);
        d.vfirst.clearAndFree(gpa);
        return;
    }
    const cols = if (d.closing and b.wraps_cols >= 8) b.wraps_cols else wrapCols(d);
    const stale = d.vfirst.items.len != b.lines() + 1;
    if (cols != b.wraps_cols or b.wraps.items.len != b.lines()) {
        b.wraps.resize(gpa, b.lines()) catch return;
        b.wraps_cols = cols;
        @memset(b.wraps.items, 0);
        b.wraps_from = 0;
    }
    if (b.wraps_from == std.math.maxInt(usize) and !stale) return;
    var from = @min(b.wraps_from, b.lines());
    b.wraps_from = std.math.maxInt(usize);
    for (b.wraps.items[from..], from..) |*w, i| {
        if (w.* == 0) w.* = @intCast(rowsOf(d, b.line(i), cols));
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
    return if (wrapping() and d.vfirst.items.len > 0) d.vfirst.items[d.vfirst.items.len - 1] else d.file.ed.buf.lines();
}

fn rowOfLine(d: *const Doc, i: usize) usize {
    return if (wrapping()) d.vfirst.items[i] else i;
}

fn lineOfRow(d: *const Doc, r: usize) usize {
    if (!wrapping()) return @min(r, d.file.ed.buf.lines() - 1);
    return buffer.lastAtMost(d.vfirst.items[0 .. d.vfirst.items.len - 1], r);
}

/// How many screen rows `l` takes at `cols` cells a row.
fn rowsOf(d: *const Doc, l: []const u8, cols: usize) usize {
    if (l.len <= cols and std.mem.indexOfScalar(u8, l, '\t') == null) return 1;
    var n: usize = 1;
    var s = segFrom(d, l, .{});
    while (s.end < l.len) : (n += 1) s = nextSeg(d, l, s);
    return n;
}

/// `editor.rowEnd` with tab stops every `tw` columns: where the row of
/// `line` from byte `start`, at column `col`, ends when `cols` cells fit.
fn wrapEnd(line: []const u8, start: usize, col: usize, cols: usize, tw: usize) editor.RowEnd {
    var i = start;
    var c = col;
    var brk: ?editor.RowEnd = null;
    while (i < line.len) {
        const x = editor.cellsTab(line, i, c, tw);
        if (c + x.w > col + cols and i > start) return brk orelse .{ .end = i, .col = c };
        c += x.w;
        i += x.len;
        if (line[i - 1] == ' ' or line[i - 1] == '\t') brk = .{ .end = i, .col = c };
    }
    return .{ .end = line.len, .col = c };
}

/// The leading indent of `l` in columns, or null when the line is blank.
fn indentCols(l: []const u8, tw: usize) ?usize {
    var col: usize = 0;
    for (l) |ch| switch (ch) {
        ' ' => col += 1,
        '\t' => col += tw - col % tw,
        '\r' => {},
        else => return col,
    };
    return null;
}

/// With Hanging Indent on, how far a wrapped row of `l` moves right: the
/// line's leading indent in columns, at most half a row.
fn hangOf(l: []const u8, cols: usize, tw: usize) usize {
    if (!conf.hanging_indent) return 0;
    return @min(indentCols(l, tw) orelse 0, cols / 2);
}

/// How far line `i`'s indent guides reach, in columns: its indent, or for
/// a blank line the smaller indent of the nearest lines with text around
/// it (looking 64 lines each way), so guides run through blank lines.
fn guideCols(d: *const Doc, i: usize, tw: usize) usize {
    const b = &d.file.ed.buf;
    if (indentCols(b.line(i), tw)) |c| return c;
    var up: usize = 0;
    var j = i;
    while (j > 0 and i - j < 64) {
        j -= 1;
        if (indentCols(b.line(j), tw)) |c| {
            up = c;
            break;
        }
    }
    var down: usize = 0;
    j = i + 1;
    while (j < b.lines() and j - i < 64) : (j += 1) if (indentCols(b.line(j), tw)) |c| {
        down = c;
        break;
    };
    return @min(up, down);
}

/// Fills in where a row that starts at `s.start` ends.
fn segFrom(d: *const Doc, l: []const u8, s: Seg) Seg {
    const tw = d.file.ed.tabWidth();
    if (!wrapping()) return .{ .end = l.len, .tw = tw };
    const cols = d.file.ed.buf.wraps_cols;
    const ind = if (s.k > 0) hangOf(l, cols, tw) else 0;
    const r = wrapEnd(l, s.start, s.col, cols - ind, tw);
    return .{ .k = s.k, .start = s.start, .col = s.col, .end = r.end, .ecol = r.col, .tw = tw, .ind = ind };
}

fn nextSeg(d: *const Doc, l: []const u8, s: Seg) Seg {
    return segFrom(d, l, .{ .k = s.k + 1, .start = s.end, .col = s.ecol });
}

fn wrapCache(dc: *const Doc, l: []const u8, first: *Seg) ?[]const Seg {
    if (!wrapping()) {
        first.* = segFrom(dc, l, .{});
        return null;
    }
    const d: *Doc = @constCast(dc);
    const ptr = @intFromPtr(l.ptr);
    const chg = d.file.ed.buf.changes;
    const cols = d.file.ed.buf.wraps_cols;
    const tw = d.file.ed.tabWidth();
    const hang = conf.hanging_indent;
    if (d.wrap_ptr == ptr and d.wrap_len == l.len and d.wrap_chg == chg and d.wrap_cols == cols and d.wrap_tw == tw and d.wrap_hang == hang and d.wrap_segs.items.len > 0) {
        return d.wrap_segs.items;
    }
    var s = segFrom(dc, l, .{});
    if (s.end >= l.len) {
        first.* = s;
        return null;
    }
    d.wrap_segs.clearRetainingCapacity();
    d.wrap_segs.append(gpa, s) catch {
        d.wrap_ptr = 0;
        first.* = s;
        return null;
    };
    while (s.end < l.len) {
        s = nextSeg(dc, l, s);
        d.wrap_segs.append(gpa, s) catch {
            d.wrap_ptr = 0;
            first.* = d.wrap_segs.items[0];
            return null;
        };
    }
    d.wrap_ptr = ptr;
    d.wrap_len = l.len;
    d.wrap_chg = chg;
    d.wrap_cols = cols;
    d.wrap_tw = tw;
    d.wrap_hang = hang;
    return d.wrap_segs.items;
}

/// The row of line `l` that holds byte `p`; a byte at a wrap starts the next row.
fn segOf(d: *const Doc, l: []const u8, p: usize) Seg {
    var first: Seg = undefined;
    if (wrapCache(d, l, &first)) |segs| {
        var lo: usize = 0;
        var hi: usize = segs.len - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (p < segs[mid].end) hi = mid else lo = mid + 1;
        }
        return segs[lo];
    }
    var s = first;
    while (p >= s.end and s.end < l.len) s = nextSeg(d, l, s);
    return s;
}

/// Row `k` of line `l`, or its last row.
fn segN(d: *const Doc, l: []const u8, k: usize) Seg {
    var first: Seg = undefined;
    if (wrapCache(d, l, &first)) |segs| return segs[@min(k, segs.len - 1)];
    var s = first;
    while (s.k < k and s.end < l.len) s = nextSeg(d, l, s);
    return s;
}

/// The last place the caret can sit in a row: before the wrap's last
/// character (a whole cluster), or the line end.
fn caretEnd(l: []const u8, s: Seg) usize {
    return if (s.end < l.len) editor.prevCluster(l, s.end) else l.len;
}

const RowCol = struct { row: usize, col: usize };

/// The caret's screen row, and its column within that row.
fn caretRow(d: *Doc) RowCol {
    layout(d);
    return rowColOf(d, d.file.ed.cur);
}

fn rowColOf(d: *const Doc, pos: usize) RowCol {
    const b = &d.file.ed.buf;
    const i = b.lineOf(pos);
    const l = b.line(i);
    const p = @min(pos - b.lineStart(i), l.len);
    const s = segOf(d, l, p);
    return .{ .row = rowOfLine(d, i) + s.k, .col = editor.colOfTab(l, s.start, s.col, p, s.tw) - s.col + s.ind };
}

/// Up and down by screen rows, keeping the column.
fn vmove(d: *Doc, delta: isize, extend: bool) void {
    const e = &d.file.ed;
    const here = caretRow(d);
    const want = e.want orelse here.col;
    const to = @as(isize, @intCast(here.row)) + delta;
    const r: usize = @intCast(std.math.clamp(to, 0, @as(isize, @intCast(totalRows(d) - 1))));
    const pos = if (r == here.row) (if (delta < 0) @as(usize, 0) else e.text().len) else byteAtRow(d, r, f(want));
    e.moveTo(pos, extend);
    e.want = want;
}

fn byteAtRow(d: *const Doc, row: usize, x: f64) usize {
    const b = &d.file.ed.buf;
    const i = lineOfRow(d, row);
    const l = b.line(i);
    const s = segN(d, l, row - rowOfLine(d, i));
    return b.lineStart(i) + std.math.clamp(editor.byteAtColTab(l, f(s.col) + @max(x - f(s.ind), 0), s.tw), s.start, caretEnd(l, s));
}

/// ⌘← and ⌘→ while wrapped: the ends of the screen row. False on a line's
/// first row going left, where the editor's smart home takes over.
fn rowEdge(d: *Doc, right: bool, extend: bool) bool {
    layout(d);
    const b = &d.file.ed.buf;
    const i = b.lineOf(d.file.ed.cur);
    const l = b.line(i);
    const s = segOf(d, l, d.file.ed.cur - b.lineStart(i));
    if (!right and s.k == 0) return false;
    d.file.ed.moveTo(b.lineStart(i) + if (right) caretEnd(l, s) else s.start, extend);
    return true;
}

// ---- scrolling ----

/// Lines of blank page that the scroll goes past the last row.
const past_end = 3;

/// The scroll's top and bottom. Typewriter mode lets the first and last
/// rows reach the middle, so the top can be negative.
fn scrollRange(d: *Doc) [2]f64 {
    // A scroll can come before the draw that lays out a tab just shown.
    layout(d);
    const lo = if (conf.typewriter) (lh - textH(d)) / 2 else 0;
    const hi = if (conf.typewriter) lo + f(totalRows(d) -| 1) * lh else f(totalRows(d) + past_end) * lh - textH(d);
    return .{ lo, @max(lo, hi) };
}

fn clampScroll(d: *Doc) void {
    const range = scrollRange(d);
    d.file.sy = std.math.clamp(d.file.sy, range[0], range[1]);
    d.file.sx = if (wrapping()) 0 else @max(d.file.sx, 0);
}

/// Centers the caret's row in typewriter mode; otherwise scrolls just
/// enough to show it with `scroll_off` rows of context above and below,
/// fewer when the card is too short for them.
const scroll_off = 2;
fn reveal(d: *Doc) void {
    const c = caretRow(d);
    const y = f(c.row) * lh;
    const th = textH(d);
    if (conf.typewriter) {
        d.file.sy = y - (th - lh) / 2;
    } else {
        const m = @min(scroll_off * lh, @max(0, @floor((th - lh) / 2 / lh)) * lh);
        if (y - m < d.file.sy) d.file.sy = y - m;
        if (y + lh + m > d.file.sy + th) d.file.sy = y + lh + m - th;
    }
    if (!wrapping()) {
        const x = f(c.col) * cw;
        const tw = rightEdge(d) - gap - 2 * pad_x - gutter(d);
        if (x < d.file.sx) d.file.sx = @max(0, x - 8 * cw);
        if (x > d.file.sx + tw - cw) d.file.sx = x - tw + 8 * cw;
    }
    clampScroll(d);
}

/// Puts the caret a third of the way down when it's off screen.
fn center(d: *Doc) void {
    const y = f(caretRow(d).row) * lh;
    if (y < d.file.sy or y + lh > d.file.sy + textH(d)) d.file.sy = y - textH(d) / 3;
    reveal(d);
}

const sentence_ends = [_][]const u8{ ".", "!", "?", "…" };
const sentence_closers = sentence_ends ++ [_][]const u8{ "\"", "'", ")", "]", "”", "’", "»" };

/// The byte length of the mark from `marks` that starts `s`, or 0.
fn markLen(s: []const u8, marks: []const []const u8) usize {
    for (marks) |m| if (std.mem.startsWith(u8, s, m)) return m.len;
    return 0;
}

fn trackFocus(d: *Doc) void {
    if (conf.focus != .off) {
        const b = &d.file.ed.buf;
        const text = d.file.ed.text();
        var lo = b.lineOf(d.file.ed.cur);
        var hi = lo;
        if (conf.focus != .line and std.mem.trim(u8, b.line(lo), " \t\r").len > 0) {
            while (lo > 0 and std.mem.trim(u8, b.line(lo - 1), " \t\r").len > 0) lo -= 1;
            while (hi + 1 < b.lines() and std.mem.trim(u8, b.line(hi + 1), " \t\r").len > 0) hi += 1;
        }
        var start = b.lineStart(lo);
        var end = b.lineStart(hi) + b.line(hi).len;
        if (conf.focus == .sentence) {
            // A sentence ends after a run of `.`, `!`, `?` or `…` and any
            // closing quotes, and only where whitespace or the span's end
            // follows, so the caret right after a period still lights the
            // sentence it finished.
            var i = start;
            while (i < end) {
                const n = markLen(text[i..end], &sentence_ends);
                if (n == 0) {
                    i += 1;
                    continue;
                }
                var j = i + n;
                while (j < end) {
                    const m = markLen(text[j..end], &sentence_closers);
                    if (m == 0) break;
                    j += m;
                }
                i = j;
                if (j < end and !std.ascii.isWhitespace(text[j])) continue;
                if (d.file.ed.cur <= j) {
                    end = j;
                    break;
                }
                start = j;
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
}

fn untitledChanged(d: *Doc) void {
    if (d.file.ed.buf.changes != d.file.draft_armed) {
        d.file.draft_armed = d.file.ed.buf.changes;
        objc.later(d.win.view, "saveDrafts:", null, 1);
    }
    // An untitled file is renamed after its first line once typing
    // pauses, or at once when the caret leaves that line, as Return
    // does, so its tab doesn't change width with each letter.
    if (d.file.stale()) {
        const row = nameRow(&d.file.ed);
        if (row != null and row.? != d.file.ed.buf.lineOf(d.file.ed.cur)) retitle(d) else objc.later(d.win.view, "retitle:", null, 0.6);
    }
}

/// Redraws `d`'s window, which shows the dot of unsaved changes in its
/// close button when any of its cards has some.
fn refresh(d: *Doc) void {
    // Typewriter mode recenters when the caret moves or the text changes,
    // but not after a wheel scroll alone.
    if (conf.typewriter and (d.center_at != d.file.ed.cur or d.center_changes != d.file.ed.buf.changes)) reveal(d);
    d.center_at = d.file.ed.cur;
    d.center_changes = d.file.ed.buf.changes;
    trackFocus(d);
    if (d.size.x >= 160 + 2 * gap and d.size.y >= 100 + 2 * gap and d.fin.x >= 160 + 2 * gap and d.fin.y >= 100 + 2 * gap and !d.closing and !cardsMoving(d.win.cards)) {
        msg(void, d.win.view, "setNeedsDisplayInRect:", .{cardDirtyRect(d)});
        for (docs.items) |o| if (o != d and o.win == d.win and (o.mode == .find or o.mode == .replace)) {
            msg(void, d.win.view, "setNeedsDisplayInRect:", .{cardDirtyRect(o)});
        };
    } else msg(void, d.win.view, "setNeedsDisplay:", .{true});
    const now_dirty = d.dirty();
    if (now_dirty != d.was_dirty) {
        d.was_dirty = now_dirty;
        redrawSide(d.win);
    }
    if (d.file.path == null) untitledChanged(d);
    preview.update(d, themeOf(d.win));
    var edited = false;
    for (docs.items) |o| if (o.win == d.win and o.dirty()) {
        edited = true;
    };
    if (edited != d.win.edited) {
        d.win.edited = edited;
        msg(void, d.win.window, "setDocumentEdited:", .{edited});
    }
    access.changed(d);
}

/// What VoiceOver's elements in `access.zig` read from the window, in the
/// view's coordinates. Nothing here runs unless VoiceOver asks.
pub const ax = struct {
    pub const Card = Doc;
    pub const Window = Win;

    pub const winOfView = winOf;

    pub fn alive(d: *const Doc) bool {
        return std.mem.indexOfScalar(*Doc, docs.items, @constCast(d)) != null and !d.closing;
    }

    pub fn winAlive(w: *const Win) bool {
        return std.mem.indexOfScalar(*Win, wins.items, @constCast(w)) != null;
    }

    /// Gives card `d` the typing.
    pub const focusCard = focus;

    /// The window's cards in layout order, leaving out ones folding away.
    pub fn cards(w: *const Win, out: []*Doc) usize {
        return listPanes(w.cards, out, 0);
    }

    pub fn name(d: *const Doc) []const u8 {
        return d.file.name();
    }

    /// Where the text shows in the card.
    pub fn textRect(d: *const Doc) Rect {
        return .{ .x = d.org.x + gap, .y = d.org.y + top_h, .w = rightEdge(d) - gap, .h = @max(bottom(d) - top_h, 0) };
    }

    /// The cell of the character at byte `pos`, one column wide.
    pub fn cell(d: *Doc, pos: usize) Rect {
        layout(d);
        const c = rowColOf(d, pos);
        return .{ .x = d.org.x + gap + padL(d) + f(c.col) * cw - d.vx, .y = d.org.y + top_h + f(c.row) * lh - d.vy, .w = cw, .h = lh };
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
        d.file.ed.select(anchor, cur);
        reveal(d);
        refresh(d);
    }

    /// The card shows its tabs, rather than its file's name alone.
    pub fn tabsShown(d: *const Doc) bool {
        return !conf.zen and d.tabbed.to == 1;
    }

    pub const tabs = tabCount;

    pub fn tabAtIndex(d: *Doc, j: usize) u32 {
        return tabPage(d, j).id;
    }

    pub const tabOf = tabIndex;

    pub fn tabTitle(d: *Doc, j: usize) []const u8 {
        return tabPage(d, j).name();
    }

    /// Where tab `id` last drew.
    pub fn tabRect(d: *const Doc, id: u32) Rect {
        const s = d.slots.items[slotOf(d, id) orelse return .{}];
        return .{ .x = d.org.x + s.x, .y = d.org.y + headY() - 12, .w = s.w, .h = 24 };
    }

    /// The tab under `p`, by id.
    pub fn tabUnder(d: *Doc, p: Point) ?u32 {
        const hit = tabAt(d, inPane(d, p)) orelse return null;
        return tabPage(d, hit.j).id;
    }

    /// Shows tab `id` in its card, as a click on it does.
    pub fn pressTab(d: *Doc, id: u32) bool {
        const j = tabIndex(d, id) orelse return false;
        focus(d);
        switchTab(d, j);
        return true;
    }

    pub const paneUnder = paneAt;

    pub const sidebar = sideShown;

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
        return if (overSide(w, p)) sideRow(w, p.y) else null;
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
        const i = tree.rowOf(want) orelse return false;
        if (tree.rows.items[i].dir) {
            startFold(i);
            return true;
        }
        const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root orelse return false, want }) catch return false;
        defer gpa.free(path);
        open(path, w.focus);
        return true;
    }
};

// ---- syntax colors ----

fn syncStates(d: *Doc, upto: usize) void {
    const s = syntax.syncStatesShift(gpa, d.file.lang, &d.file.ed.buf, &d.file.states, upto) catch {
        d.file.states.clearRetainingCapacity();
        d.lex[0].clear();
        return;
    };
    d.lex[0].shiftAndDrop(s);
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

    /// Forgets only changed lines, keeping the converged suffix's byte offsets.
    fn drop(x: *Kinds, from: usize, end: usize) void {
        var kept: usize = 0;
        for (x.lines.items) |e| {
            if (e.line >= from and e.line < end) continue;
            x.lines.items[kept] = e;
            kept += 1;
        }
        x.lines.shrinkRetainingCapacity(kept);
    }

    fn shiftAndDrop(x: *Kinds, s: syntax.Sync) void {
        if (s.delta) |delta| {
            var kept: usize = 0;
            for (x.lines.items) |e| {
                if (e.line < s.shift_at) {
                    if (e.line >= s.from and e.line < s.end) continue;
                    x.lines.items[kept] = e;
                    kept += 1;
                } else {
                    const nl = @as(isize, @intCast(e.line)) + delta;
                    if (nl < @as(isize, @intCast(s.shift_at))) continue;
                    const u: usize = @intCast(nl);
                    if (u >= s.from and u < s.end) continue;
                    x.lines.items[kept] = .{ .line = u, .at = e.at };
                    kept += 1;
                }
            }
            x.lines.shrinkRetainingCapacity(kept);
        } else if (s.from != s.end) {
            x.drop(s.from, s.end);
        }
    }
};

/// For a new language or file: every line lexes again.
fn clearSyntax(d: *Doc) void {
    d.file.states.clearRetainingCapacity();
    for (&d.lex) |*x| x.clear();
}

/// Line `i`'s kinds for this frame, added to `lex[0]`: copied from the last
/// frame when it drew the line, else lexed. `walk` steps through the last
/// frame's lines, as the frame asks for lines in order. Returns the kinds'
/// offset in `lex[0].kinds`, since a later line's append can move the buffer.
fn lineKinds(d: *Doc, i: usize, l: []const u8, walk: *usize) ?usize {
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
    } else _ = syntax.lexLine(d.file.lang, l, d.file.states.items[i], out);
    return at;
}

// ---- untitled names ----

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
    if (d.file.path != null or !d.file.rename()) return;
    if (slotOf(d, d.file.id)) |k| d.slots.items[k].drop();
    if (d.win.focus == d) msg(void, d.win.window, "setTitle:", .{objc.str(d.file.name())});
    msg(void, d.win.view, "setNeedsDisplay:", .{true});
}

/// The untitled cards in a window take their new names once typing has
/// paused.
fn retitleNow(self: Id, _: Sel, _: Id) callconv(.c) void {
    for (docs.items) |d| if (d.win.view == self) retitle(d);
}

// ---- icons ----

const Icon = enum { closed, opened, sidebar, plus, close, folder, parents, crumb, check, lock };
/// SF Symbols, which come with macOS, so they cost Zag no size.
const icon_names = [_][:0]const u8{ "chevron.right", "chevron.down", "sidebar.left", "plus", "xmark", "folder.fill", "chevron.down", "chevron.forward", "checkmark", "lock.fill" };
const CachedIcon = struct { img: Id = null, cg: Id = null, size: Point = .{}, dev_px: f64 = 0 };
/// Symbol images for the light and dark themes, tinted and made on first use.
var icons: [2][icon_names.len]CachedIcon = @splat(@splat(.{}));

/// After the colors or the font size change.
fn dropIcons() void {
    for (&icons) |*set| for (set) |*c| {
        if (c.cg) |cg| objc.CFRelease(cg);
        if (c.img != null) msg(void, c.img, "release", .{});
        c.* = .{};
    };
    for (kind_icons.items) |*e| {
        for (&e.cgs) |*slot| {
            if (slot.cg) |cg| objc.CFRelease(cg);
            slot.* = .{};
        }
    }
}

fn cacheCG(img: Id, rect: Rect) Id {
    const gc = msg(Id, objc.class("NSGraphicsContext"), "currentContext", .{});
    if (gc == null) return null;
    var prop = rect;
    const cg = msg(Id, img, "CGImageForProposedRect:context:hints:", .{ &prop, gc, @as(Id, null) });
    if (cg) |p| _ = objc.CFRetain(p);
    return cg;
}

fn drawCG(ctx: Id, cg: Id, r: Rect) void {
    objc.CGContextSaveGState(ctx);
    objc.CGContextTranslateCTM(ctx, r.x, r.y + r.h);
    objc.CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, .{ .x = 0, .y = 0, .w = r.w, .h = r.h }, cg);
    objc.CGContextRestoreGState(ctx);
}

/// A row's name at `room` wide: the whole line when it fits, else the cut one
/// (ending in `uiDots(fnt)`), made again only when the room changed.
fn sideFit(sl: *SideLine, fnt: Id, room: f64) Id {
    const l = sl.full orelse return null;
    if (sl.w < 0) sl.w = lineW(l);
    if (sl.w <= room) return l;
    if (sl.cut_room != room) {
        if (sl.cut) |c| objc.CFRelease(c);
        sl.cut_room = room;
        // Cut in the middle, so the end of the name and its extension stay.
        sl.cut = objc.CTLineCreateTruncatedLine(l, room, 2, uiDots(fnt));
    }
    return sl.cut orelse l;
}

fn freeSideLine(sl: *SideLine) void {
    if (sl.full) |p| objc.CFRelease(p);
    if (sl.cut) |p| objc.CFRelease(p);
    sl.* = .{};
}

/// The Mac's own icon for a file of `name`'s kind, the same one Finder
/// shows. Made on first use per extension and kept.
fn iconFor(name: []const u8) Id {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse 0;
    var low: [16]u8 = undefined;
    const ext = if (dot > 0 and name.len - dot - 1 <= low.len) name[dot + 1 ..] else "";
    const key = std.ascii.lowerString(low[0..ext.len], ext);
    for (kind_icons.items) |e| if (std.mem.eql(u8, e.key[0..e.len], key)) return e.img;
    const ut = objc.class("UTType");
    const ty = if (key.len > 0) msg(Id, ut, "typeWithFilenameExtension:", .{objc.str(key)}) else null;
    const ws = msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const img = msg(Id, msg(Id, ws, "iconForContentType:", .{ty orelse msg(Id, ut, "typeWithIdentifier:", .{objc.str("public.plain-text")})}), "retain", .{});
    var e: KindIcon = .{ .key = undefined, .len = @intCast(key.len), .img = img };
    @memcpy(e.key[0..key.len], key);
    kind_icons.append(gpa, e) catch {};
    return img;
}

const KindCg = struct { cg: Id = null, s: f64 = 0, px: f64 = 0 };
const KindIcon = struct { key: [16]u8, len: u8, img: Id, cgs: [3]KindCg = @splat(.{}) };
/// By lowercase extension, "" for none.
var kind_icons: std.ArrayList(KindIcon) = .empty;

fn icon(which: Icon, dark: bool, th: *const Theme) Id {
    const slot = &icons[@intFromBool(dark)][@intFromEnum(which)];
    if (slot.img != null) return slot.img;
    const scale: f64, const weight: f64 = switch (which) {
        .closed, .opened => .{ 0.6, 0.3 },
        .close => .{ 0.55, 0.3 },
        .crumb => .{ 0.64, 0.23 },
        .sidebar, .plus => .{ 1.0, 0 },
        .folder => .{ 15.0 / conf.size, 0 },
        .parents => .{ 9.0 / conf.size, 0.4 },
        .check => .{ 11.0 / conf.size, 0.3 },
        .lock => .{ 9.0 / conf.size, 0.2 },
    };
    const cfg = objc.class("NSImageSymbolConfiguration");
    const sized = msg(Id, cfg, "configurationWithPointSize:weight:", .{ conf.size * scale, weight });
    // Folders use shades of the caret; checks use it solid; the rest are muted.
    const tint = if (which == .folder)
        msg(Id, cfg, "configurationWithHierarchicalColor:", .{msg(Id, nscolor(th.caret), "colorWithAlphaComponent:", .{@as(f64, if (dark) 0.85 else 0.75)})})
    else
        msg(Id, cfg, "configurationWithPaletteColors:", .{msg(Id, objc.class("NSArray"), "arrayWithObject:", .{nscolor(if (which == .check) th.caret else th.muted)})});
    const img = msg(Id, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{ objc.str(icon_names[@intFromEnum(which)]), @as(Id, null) });
    if (img == null) return null;
    const made = msg(Id, img, "imageWithSymbolConfiguration:", .{msg(Id, sized, "configurationByApplyingConfiguration:", .{tint})});
    slot.img = msg(Id, made, "retain", .{});
    slot.size = if (slot.img != null) msg(Point, slot.img, "size", .{}) else .{};
    return slot.img;
}

fn tileSize() f64 {
    return @round(conf.size + 5);
}

/// A file's icon from `iconFor`, `s` square, with its top left at `x`, `y`.
fn tile(img: Id, x: f64, y: f64, s: f64) void {
    if (img == null) return;
    const gc = msg(Id, objc.class("NSGraphicsContext"), "currentContext", .{});
    const ctx = if (gc != null) msg(Id, gc, "CGContext", .{}) else null;
    if (ctx != null) {
        for (kind_icons.items) |*e| if (e.img == img) {
            var hit: Id = null;
            for (e.cgs) |slot| if (slot.cg != null and slot.px == dev_px and slot.s == s) {
                hit = slot.cg;
                break;
            };
            if (hit == null) {
                if (e.cgs[2].cg) |old| objc.CFRelease(old);
                e.cgs[2] = e.cgs[1];
                e.cgs[1] = e.cgs[0];
                e.cgs[0] = .{ .cg = cacheCG(img, .{ .w = s, .h = s }), .s = s, .px = dev_px };
                hit = e.cgs[0].cg;
            }
            if (hit) |cg| {
                drawCG(ctx, cg, .{ .x = x, .y = y, .w = s, .h = s });
                return;
            }
            break;
        };
    }
    msg(void, img, "drawInRect:fromRect:operation:fraction:respectFlipped:hints:", .{ Rect{ .x = x, .y = y, .w = s, .h = s }, Rect{}, @as(usize, 2), @as(f64, 1), true, @as(Id, null) });
}

/// A capsule behind a button under the mouse, centered on `cx`, `cy`: `a`
/// is how far the hover has faded in and `down` how much of a click's
/// stronger fill is left.
fn hoverPill(ctx: Id, th: *const Theme, a: f64, down: f64, cx: f64, cy: f64) void {
    const alpha = @max(0.08 * a, 0.14 * down);
    if (alpha > 0.001) pill(ctx, th.fg, alpha, cx - 14, cy - 14, 28, 28, 14);
}

// ---- the header's folder ----

/// At most this many chevrons in the header's folder.
const max_marks = 8;

const Head = struct {
    line: Id = null,
    room: f64 = -1,
    lw: f64 = 0,
    cut: bool = false,
    marks: [max_marks]f64 = undefined,
    n: usize = 0,
};

/// The header's folder for `d`'s file as a line in `path_font` that fits
/// `room`: relative to the open folder inside it, with the home folder as
/// ~ outside it, and a gap between folders whose middle it notes in
/// the returned marks for a chevron. Too long a path loses its first folders
/// to an ellipsis, keeping the ones nearest the file. No line for an
/// untitled file or one at the top of the open folder.
fn headLine(d: *const Doc, room: f64) Head {
    var head: Head = .{ .room = room };
    const p = d.file.path orelse return head;
    const dir = std.fs.path.dirname(p) orelse "/";
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    var rel = tilde(&pbuf, dir);
    if (root) |r| {
        if (std.mem.eql(u8, dir, r)) return head;
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
    if (n == 0) return head;
    std.mem.reverse([]const u8, parts[0..n]);
    const sep = "    ";
    const sep_w = textW(sep, path_font);
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
        if (line != null and lineW(line) > room) {
            objc.CFRelease(line.?);
            if (!last) continue;
            line = uiLine(text, path_font, room);
            head.cut = true;
        }
        if (line == null) return head;
        head.cut = head.cut or from > 0;
        // The last try is cut at its end to fit; a chevron the cut reached goes too.
        const lw = lineW(line);
        head.lw = lw;
        for (marks[0..m]) |at| {
            const x = textW(text[0..at], path_font);
            if (x + sep_w > lw) break;
            head.marks[head.n] = x + sep_w / 2;
            head.n += 1;
        }
        head.line = line;
        return head;
    }
}

/// Draws `img` centered in the square at `x`, `y` with side `s`.
fn drawIcon(img: Id, x: f64, y: f64, s: f64) void {
    drawIconIn(img, x, y, s, s, 1);
}

/// Draws `img` centered in the `w` by `h` box at `x`, `y`, at opacity `a`.
fn drawIconIn(img: Id, x: f64, y: f64, w: f64, h: f64, a: f64) void {
    if (img == null) return;
    const gc = msg(Id, objc.class("NSGraphicsContext"), "currentContext", .{});
    const ctx = if (gc != null) msg(Id, gc, "CGContext", .{}) else null;
    if (ctx != null) {
        for (&icons) |*set| for (set) |*c| if (c.img == img) {
            if (c.cg != null and c.dev_px != dev_px) {
                objc.CFRelease(c.cg.?);
                c.cg = null;
            }
            if (c.cg == null) {
                c.cg = cacheCG(img, .{ .w = c.size.x, .h = c.size.y });
                c.dev_px = dev_px;
            }
            if (c.cg) |cg| {
                const r: Rect = .{ .x = @round(x + (w - c.size.x) / 2), .y = @round(y + (h - c.size.y) / 2), .w = c.size.x, .h = c.size.y };
                objc.CGContextSaveGState(ctx);
                if (a < 1) objc.CGContextSetAlpha(ctx, a);
                objc.CGContextTranslateCTM(ctx, r.x, r.y + r.h);
                objc.CGContextScaleCTM(ctx, 1, -1);
                CGContextDrawImage(ctx, .{ .x = 0, .y = 0, .w = r.w, .h = r.h }, cg);
                objc.CGContextRestoreGState(ctx);
                return;
            }
            break;
        };
    }
    const size = msg(Point, img, "size", .{});
    const r: Rect = .{ .x = @round(x + (w - size.x) / 2), .y = @round(y + (h - size.y) / 2), .w = size.x, .h = size.y };
    msg(void, img, "drawInRect:fromRect:operation:fraction:respectFlipped:hints:", .{ r, Rect{}, @as(usize, 2), a, true, @as(Id, null) });
}

// ---- palette and quick open rows ----

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
var panel_base: f64 = 0;
var panel_small_base: f64 = 0;
/// How many rows the panel's height holds: the picks up to `list_rows`, or
/// the one "No matches".
fn panelRows(d: *const Doc) usize {
    return std.math.clamp(d.npicks, 1, list_rows);
}

/// The fixed-size row fonts, made once at launch.
fn panelFonts() void {
    panel_font = msg(Id, msg(Id, objc.class("NSFont"), "systemFontOfSize:", .{@as(f64, 13)}), "retain", .{});
    panel_small = msg(Id, msg(Id, objc.class("NSFont"), "systemFontOfSize:", .{@as(f64, 12)}), "retain", .{});
    panel_base = baseIn(panel_font, prow);
    panel_small_base = baseIn(panel_small, prow);
}

/// The baseline of text in `fnt`, centered in a row's height from its top.
fn baseIn(fnt: Id, h: f64) f64 {
    const asc = objc.CTFontGetAscent(fnt);
    return @round((h - asc - objc.CTFontGetDescent(fnt)) / 2 + asc);
}

fn midOff(fnt: Id) f64 {
    return (objc.CTFontGetAscent(fnt) - objc.CTFontGetDescent(fnt)) / 2;
}

/// Draws `s` in `fnt` with its left edge at `x`, cut to `room`, vertically
/// centered in a row whose top is `y`. Returns its width.
fn rowText(ctx: Id, s: []const u8, fnt: Id, c: Rgb, x: f64, y: f64, room: f64) f64 {
    if (room < 4 or s.len == 0) return 0;
    const line = rowLine(s, fnt, room, false);
    const base = if (fnt == panel_small) panel_small_base else panel_base;
    paintLine(ctx, line.line, c, 1, x, y + base);
    return line.w;
}

/// The lines the palette and quick open drew lately, so an open panel
/// doesn't lay its rows out again every frame. Keyed by text, font and room;
/// a full cache lets its oldest line go. Lines take the context's color, so
/// a theme change doesn't touch them.
const RowLine = struct { key: u64 = 0, line: Id = null, w: f64 = 0 };
var row_lines: [128]RowLine = @splat(.{});
var row_next: usize = 0;

/// `uiLine(s, fnt, room)` from `row_lines`, made on a miss, cut in its
/// middle with `mid`. The cache owns it.
fn rowLine(s: []const u8, fnt: Id, room: f64, mid: bool) *const RowLine {
    var h = std.hash.Fnv1a_64.init();
    h.update(std.mem.asBytes(&fnt));
    h.update(std.mem.asBytes(&room));
    h.update(&.{@as(u8, @intFromBool(mid))});
    h.update(s);
    const key = h.final() | 1;
    for (&row_lines) |*e| if (e.key == key) return e;
    const e = &row_lines[row_next];
    row_next = (row_next + 1) % row_lines.len;
    if (e.line) |l| objc.CFRelease(l);
    e.* = .{ .key = key, .line = uiLineCut(s, fnt, room, if (mid) 2 else 1) };
    e.w = lineW(e.line);
    return e;
}

/// The row shown when nothing matches: one dim "No matches" in the row font,
/// with its top at `top` (pushed down by `rise`), drawn at opacity `a`.
fn panelNone(ctx: Id, th: *const Theme, left: f64, top: f64, a: f64, rise: f64) void {
    if (a < 0.01) return;
    _ = rowText(ctx, "No matches", panel_font, mixRgb(th.panel, th.muted, a), left, top + rise, 1e5);
}

/// One row of the palette or quick open list, picked by `p`, whose content
/// runs from `left` to `right`, with its top at `y` (pushed down by `rise`),
/// drawn at opacity `a`.
fn panelRow(ctx: Id, d: *const Doc, th: *const Theme, dark: bool, p: usize, left: f64, right: f64, top: f64, a: f64, rise: f64) void {
    if (a < 0.01) return;
    const y = top + rise;
    const ink = mixRgb(th.panel, th.fg, a);
    const dim = mixRgb(th.panel, th.muted, a);
    if (d.palette) {
        if (p >= cmds.items.len) return;
        const c = cmds.items[p];
        // A command Late-Night set shows dimmed; picking it says why.
        const name_ink = if (c.grey) mixRgb(th.panel, th.muted, a * 0.6) else ink;
        const lead_ink = if (c.grey) mixRgb(th.panel, th.muted, a * 0.45) else dim;
        const x = left + check_col;
        if (c.on) drawIconIn(icon(.check, dark, th), left, y, check_col, prow, a);
        // Shortcuts: one glyph to a cell, flush right like a menu's.
        const cells = codepoints(c.keys);
        const keys_w = f(cells) * key_cell;
        var at = right - keys_w;
        var it = (std.unicode.Utf8View.init(c.keys) catch return).iterator();
        while (it.nextCodepointSlice()) |g| : (at += key_cell) {
            const line = rowLine(g, panel_small, 1e5, false);
            paintLine(ctx, line.line, lead_ink, 1, at + (key_cell - line.w) / 2, y + panel_small_base);
        }
        const room = right - keys_w - (if (cells > 0) @as(f64, 12) else 0) - x;
        const name = cmd_names.items[p];
        // The section leads in quietly, with no colon after it.
        if (std.mem.indexOf(u8, name, ": ")) |j| {
            const pw = rowText(ctx, name[0..j], panel_font, lead_ink, x, y, room);
            _ = rowText(ctx, name[j + 2 ..], panel_font, name_ink, x + pw + 6, y, room - pw - 6);
        } else _ = rowText(ctx, name, panel_font, name_ink, x, y, room);
        return;
    }
    const paths = (quick orelse return).paths.items;
    if (p >= paths.len) return;
    const path = paths[p];
    const slash = if (std.mem.lastIndexOfScalar(u8, path, '/')) |j| j + 1 else 0;
    // The file's Finder icon, its name, then its folder cut in the middle;
    // the letters the search matched draw in the accent.
    const s = 16.0;
    const img = iconFor(path[slash..]);
    if (img != null) msg(void, img, "drawInRect:fromRect:operation:fraction:respectFlipped:hints:", .{ Rect{ .x = left, .y = @round(y + (prow - s) / 2), .w = s, .h = s }, Rect{}, @as(usize, 2), a, true, @as(Id, null) });
    const x = left + s + 8;
    if (right - x < 4) return;
    const bits = matchBits(path, d.prompt.items);
    const hi = mixRgb(th.panel, th.caret, a);
    const nl = rowLine(path[slash..], panel_font, right - x, false);
    paintLine(ctx, nl.line, ink, 1, x, y + panel_base);
    markMatches(ctx, nl, path[slash..], &bits, slash, hi, x, y + panel_base);
    const dx = x + nl.w + 8;
    if (slash == 0 or right - dx < 8) return;
    const dl = rowLine(path[0..slash], panel_small, right - dx, true);
    paintLine(ctx, dl.line, dim, 1, dx, y + panel_small_base);
    markMatches(ctx, dl, path[0..slash], &bits, 0, hi, dx, y + panel_small_base);
}

const MatchBits = std.bit_set.Static(512);

/// The bytes of `path` that quick open's match of `q` lands on: each word
/// of `q` taken left to right, as `finder.score` matches it.
fn matchBits(path: []const u8, q: []const u8) MatchBits {
    var bits: MatchBits = .empty;
    var words = std.mem.tokenizeScalar(u8, q, ' ');
    while (words.next()) |w| {
        var qi: usize = 0;
        for (path, 0..) |ch, i| {
            if (qi == w.len or i >= MatchBits.bit_length) break;
            if (std.ascii.toLower(ch) != std.ascii.toLower(w[qi])) continue;
            bits.set(i);
            qi += 1;
        }
    }
    return bits;
}

/// Draws again, in `c`, the letters of row line `rl` (which shows `s`)
/// whose bytes, counted from `off`, are set in `bits`: the same glyphs,
/// clipped to their own cells.
fn markMatches(ctx: Id, rl: *const RowLine, s: []const u8, bits: *const MatchBits, off: usize, c: Rgb, x: f64, base: f64) void {
    if (rl.line == null) return;
    var rects: [64]Rect = undefined;
    var n: usize = 0;
    var u: isize = 0;
    var i: usize = 0;
    while (i < s.len and n < rects.len) {
        const len: usize = @min(std.unicode.utf8ByteSequenceLength(s[i]) catch 1, s.len - i);
        const units: isize = if (len == 4) 2 else 1;
        if (off + i < MatchBits.bit_length and bits.isSet(off + i)) {
            const x0 = CTLineGetOffsetForStringIndex(rl.line, u, null);
            const x1 = CTLineGetOffsetForStringIndex(rl.line, u + units, null);
            if (x1 > x0) {
                rects[n] = .{ .x = x + x0, .y = base - 18, .w = x1 - x0, .h = 24 };
                n += 1;
            }
        }
        u += units;
        i += len;
    }
    if (n == 0) return;
    objc.CGContextSaveGState(ctx);
    CGContextClipToRects(ctx, &rects, n);
    paintLine(ctx, rl.line, c, 1, x, base);
    objc.CGContextRestoreGState(ctx);
}

// ---- sidebar ----

/// How much of `rel`'s unsaved dot shows (0 to 1), from whichever card holds it.
fn rowDot(w: *const Win, rel: []const u8, now: f64) f64 {
    for (docs.items) |d| if (d.win == w) {
        for (0..tabCount(d)) |j| {
            const pg = tabPage(d, j);
            if (pg.path) |p| if (relOf(p)) |r| if (std.mem.eql(u8, r, rel)) return std.math.clamp(pg.dot.at(now), 0, 1);
        }
    };
    return 0;
}

/// Aims each file's dot at its unsaved state. True while any is fading.
fn sideDotsBusy(w: *const Win, now: f64) bool {
    var busy = false;
    for (docs.items) |d| if (d.win == w) {
        for (0..tabCount(d)) |j| {
            const pg = tabPage(d, j);
            pg.dot.aim(if (pg.edited()) 1 else 0, now);
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

/// The pinned folder under `y`, if any.
fn pinnedAt(w: *const Win, y: f64) ?usize {
    for (w.stuck[0..w.nstuck], w.stuck_y[0..w.nstuck]) |i, sy| if (y >= sy and y < sy + side_h) return i;
    return null;
}

/// The tree row under `y`: a pinned folder, or a row in the list.
fn sideRow(w: *const Win, y: f64) ?usize {
    return pinnedAt(w, y) orelse listRow(w, y);
}

fn listRow(w: *const Win, y: f64) ?usize {
    if (y < listTop() or y >= msg(Rect, w.view, "bounds", .{}).h - gap) return null;
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
/// opening or closing when another click comes moves to slot 1 and
/// finishes there, so a click never snaps the folder before it.
var folds: [2]Fold = .{ .{}, .{} };

/// A folding folder as drawn: its row, where its rows end, how far open it
/// is and how far the rows after it have slid up.
const FoldView = struct { at: usize, rest: usize, n: usize, p: f64, off: f64, closing: bool };

/// The folders that are folding on screen, by `rows`, into `out`.
fn foldViews(rows: []const tree_mod.Row, now: f64, out: *[2]FoldView) usize {
    var nv: usize = 0;
    for (&folds) |*o| {
        if (!o.t.moving(now) or o.at >= rows.len or !std.mem.eql(u8, rows[o.at].rel, o.rel[0..o.len])) continue;
        const p = std.math.clamp(o.t.at(now), 0, 1);
        out[nv] = .{ .at = o.at, .rest = o.at + o.n + 1, .n = o.n, .p = p, .off = (1 - p) * f(o.n) * side_h, .closing = o.closing };
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

fn turnOf(vs: []const FoldView, i: usize) ?f64 {
    var turn: ?f64 = null;
    for (vs) |v| if (v.at == i) {
        turn = v.p;
    };
    return turn;
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
    if (tree.rowOf(o.rel[0..o.len])) |i| {
        o.at = i;
        o.n = tree.end(i) - i - 1;
        return;
    }
    o.closing = false;
    o.t.snap(1);
}

/// Opens or closes the folder at row `i`. A folder that's still folding
/// turns around from where it got to; another one still folding keeps
/// going on its own record.
fn startFold(i: usize) void {
    defer for (wins.items) |w| redrawSide(w);
    const now = CACurrentMediaTime();
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = rel_buf[0..tree.rows.items[i].rel.len];
    @memcpy(rel, tree.rows.items[i].rel);
    for (&folds) |*o| if (o.t.moving(now) and std.mem.eql(u8, rel, o.rel[0..o.len])) {
        o.closing = !o.closing;
        return o.t.aim(if (o.closing) 0 else 1, now);
    };
    // A folding folder the new one reaches into, or a third folder
    // folding at once, finishes right away: a closing one shuts and an
    // opening one lands open.
    var at = i;
    while (true) {
        const e = tree.end(at);
        const crowded = folds[0].t.moving(now) and folds[1].t.moving(now);
        var hit: ?*Fold = null;
        for (&folds, 0..) |*o, s| if (o.t.moving(now) and ((o.at < e and at < o.at + o.n + 1) or (crowded and s == 1))) {
            hit = o;
        };
        const o = hit orelse break;
        if (o.closing) finishFold(o) else o.t.snap(1);
        at = tree.rowOf(rel) orelse return;
    }
    const shut = tree.isOpen(rel);
    if (folds[0].t.moving(now)) folds[1] = folds[0];
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
    fo.n = tree.end(at) - at - 1;
    for (wins.items) |w| hoverNow(w);
}

/// Shuts folder `o` for good: the tree drops its rows, and the other
/// folder still folding finds its row again.
fn finishFold(o: *Fold) void {
    o.closing = false;
    tree.toggle(gpa, o.rel[0..o.len]);
    rebuildTree();
    const now = CACurrentMediaTime();
    for (&folds) |*x| if (x != o) refindFold(x, now);
    for (wins.items) |w| hoverNow(w);
    for (wins.items) |w| redrawSide(w);
}

/// Shuts the closing folders whose rows have folded away.
fn finishFolds(now: f64) void {
    for (&folds) |*o| if (o.closing and !o.t.moving(now)) finishFold(o);
}

/// The fill the sidebar's selection and the palette's picked row share: a
/// soft rounded fill, fainter when the window isn't key, with a ring under
/// Increase Contrast. `fade` (0 to 1) scales both.
fn selFill(ctx: Id, th: *const Theme, dark: bool, key: bool, fade: f64, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const a: f64 = if (contrast) 0.16 else if (dark) (if (key) 0.12 else 0.07) else (if (key) 0.09 else 0.05);
    pill(ctx, th.fg, a * fade, x, y, w, h, radius);
    if (contrast) ring(ctx, th.fg, 0.4 * fade, x, y, w, h, radius);
}

fn rowIconX(depth: u16) f64 {
    return 26 + f(depth) * 16;
}

/// One row of the tree with its top at `y`: chevron, icon, name and dot.
/// `turn` is how far a folding folder's chevron has turned, 0 to 1. The file
/// on show in the focused card has its name in bold, which fades in as the
/// selection's highlight arrives and out as it leaves.
fn drawRow(w: *Win, ctx: Id, th: *const Theme, dark: bool, i: usize, y: f64, turn: ?f64, sh: f64, now: f64) void {
    const row = tree.rows.items[i];
    const s = side_icon;
    const x = rowIconX(row.depth) - 10;
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
    const sl = &side_lines.items[i];
    if (sl.full == null) sl.full = uiLine(row.rel[row.base..], side_font, 1e9);
    if (!row.dir and sl.icon == null) sl.icon = iconFor(row.rel[row.base..]);
    if (row.dir) drawIcon(icon(.folder, dark, th), x + 10, iy, s) else tile(sl.icon, x + 10, iy, s);
    const nx = x + 10 + s + 8;
    const room = side_w - nx - if (row.dir) @as(f64, 14) else 26;
    const plain = sideFit(sl, side_font, room);
    // How far the selection's highlight is on this row, for the bold name.
    const bp: f64 = if (row.dir or w.sel.row == null) 0 else (1 - std.math.clamp(@abs(w.sel.s.x - (f(i) * side_h - sh)) / side_h, 0, 1)) * std.math.clamp(w.sel.a.at(now), 0, 1);
    var nw = if (1 - bp > 0.001) drawLineA(ctx, plain, th.fg, 1 - bp, nx, y + side_base) else if (plain == sl.full) sl.w else lineW(plain);
    if (bp > 0.001) {
        const selected = w.sel.row == i;
        if (selected and (w.bold[0].line.full == null or w.bold[0].row != i or w.bold[0].gen != tree_gen)) {
            // The row it leaves keeps its bold name for the length of the hop.
            freeSideLine(&w.bold[1].line);
            w.bold[1] = w.bold[0];
            w.bold[0] = .{ .line = .{ .full = uiLine(row.rel[row.base..], name_font, 1e9) }, .row = i, .gen = tree_gen };
        }
        const kept: ?*SideLine = for (&w.bold) |*b| {
            if (b.line.full != null and b.row == i and b.gen == tree_gen) break &b.line;
        } else null;
        const line = if (kept) |k| sideFit(k, name_font, room) else uiLine(row.rel[row.base..], name_font, room);
        defer if (kept == null) if (line) |l| objc.CFRelease(l);
        const bw = drawLineA(ctx, line, th.fg, bp, nx, y + side_base);
        nw += (bw - nw) * bp;
    }
    if (lift > 0.01) objc.CGContextRestoreGState(ctx);
    const da = if (row.dir) 0 else rowDot(w, row.rel, now);
    var ex = nx + nw;
    if (da > 0.001) {
        if (side_dot == null) side_dot = uiLine(" •", font, side_w);
        ex += drawLineA(ctx, side_dot, th.caret, da, ex, y + side_base);
    }
    // A file open in a card that this user can't write has a lock after its name.
    if (!row.dir and rowLocked(w, row.rel)) drawIcon(icon(.lock, dark, th), ex + 4, y + (side_h - 10) / 2, 10);
}

/// Whether a card in `w` holds `rel` read-only.
fn rowLocked(w: *const Win, rel: []const u8) bool {
    for (docs.items) |d| if (d.win == w) {
        for (0..tabCount(d)) |j| {
            const pg = tabPage(d, j);
            if (pg.locked) if (pg.path) |p| if (relOf(p)) |r| if (std.mem.eql(u8, r, rel)) return true;
        }
    };
    return false;
}

/// Settles the sidebar's scroll position before its rows draw.
fn sideScroll(w: *Win, cur: ?[]const u8, view_h: f64, shut: f64, now: f64) f64 {
    const rows = tree.rows.items;
    // The list glides to a focused file that's out of view, once it's
    // been drawn; on the first draw it's just there.
    const was = if (w.side_t.moving(now)) w.side_t.at(now) else w.side_y;
    var glide = false;
    if (w.side_find) {
        w.side_find = false;
        if (cur) |c| if (tree.rowOf(c)) |i| {
            const y = f(i) * side_h;
            if (y < w.side_y or y + side_h > w.side_y + view_h) {
                w.side_y = y - view_h / 3;
                glide = w.side_drawn;
            }
        };
    }
    w.side_drawn = true;
    w.side_y = std.math.clamp(w.side_y, 0, @max(0, f(rows.len + 1) * side_h - shut - view_h));
    if (glide and was != w.side_y) {
        w.side_t.snap(was);
        w.side_t.aim(w.side_y, now);
    } else if (w.side_t.to != w.side_y) w.side_t.snap(w.side_y);
    return if (w.side_t.moving(now)) w.side_t.at(now) else w.side_y;
}

/// The folder's name pinned at the top, then a row per file and open
/// folder down to the cards' bottom edge, fading out there when more rows
/// sit below. The open folders holding the rows
/// at the top pin under the name, and the next folder pushes them up.
/// `fade` is the sidebar's alpha while it slides, applied here unless the
/// caller draws it `layered`, into a transparency layer with that alpha.
fn drawSide(w: *Win, ctx: Id, th: *const Theme, dark: bool, key: bool, bg: Rgb, fade: f64, layered: bool, now: f64) void {
    const rows = tree.rows.items;
    const lt = listTop();
    const full_h = msg(Rect, w.view, "bounds", .{}).h;
    // The list stops where the cards do, a gap above the window's bottom.
    const view_h = full_h - lt - gap;
    const cur = if (w.focus.file.path) |p| relOf(p) else null;
    // A closing folder's rows are still in the tree while it folds: leave
    // out the part already shut, so the clamp eases down with the fold
    // instead of dropping in one frame when the rows go.
    var vs: [2]FoldView = undefined;
    const vn = foldViews(rows, now, &vs);
    var moved: f64 = 0;
    var shut: f64 = 0;
    for (vs[0..vn]) |v| {
        moved += v.off;
        if (v.closing) shut += v.off;
    }
    const sy = sideScroll(w, cur, view_h, shut, now);
    if (side_lines.items.len < rows.len) side_lines.appendNTimes(gpa, .{}, rows.len - side_lines.items.len) catch return;

    objc.CGContextSaveGState(ctx);
    objc.CGContextClipToRect(ctx, .{ .y = top_h - 6, .w = side_w - 2, .h = full_h - top_h + 6 });
    if (side_head.full == null) side_head.full = uiLine(std.fs.path.basename(root.?), name_font, 1e9);
    // The folder's name is a button for its menu: a capsule under the mouse,
    // a stronger fill while pressed.
    const head_line = sideFit(&side_head, name_font, side_w - 46);
    const hw = lineW(head_line);
    w.head_w = hw + 17;
    const head_a = @max(0.08 * w.hot_t[2].at(now), 0.14 * (if (w.press == 4) w.press_t.at(now) else 0));
    if (head_a > 0.001) pill(ctx, th.fg, head_a * fade, 8, top_h + 3, w.head_w + 16, side_h - 6, (side_h - 6) / 2);
    _ = drawLineA(ctx, head_line, th.fg, 1, 16, top_h + side_base);
    drawIcon(icon(.parents, dark, th), 16 + hw + 5, top_h + (side_h - 12) / 2, 12);

    objc.CGContextClipToRect(ctx, .{ .y = lt, .w = side_w - 2, .h = view_h });

    // A folder Zag can't read, or one with nothing to list, says so in the
    // middle of the list.
    if (tree.unreadable or rows.len == 0) {
        const say = if (tree.unreadable) "Zag can't read this folder" else if (conf.show_hidden) "This folder is empty" else "No files to show here";
        const line = uiLine(say, side_font, side_w - 32);
        defer if (line) |l| objc.CFRelease(l);
        _ = drawLineA(ctx, line, th.muted, 1, @round((side_w - lineW(line)) / 2), @round(lt + view_h / 2 - side_h + side_base));
    }
    // A faint highlight follows the mouse down the list, sliding from row
    // to row on a spring that settles without a bounce. It fades in where
    // the mouse comes in and fades out where it leaves.
    const hov_a = w.hov.a.at(now);
    if (w.hov.row != null and w.hov.gen == tree_gen and w.hov.row.? < rows.len) {
        const i = w.hov.row.?;
        const ty = f(i) * side_h - shiftOf(vs[0..vn], i);
        w.hov.follow(ty, hov_a < 0.05, now);
    } else w.hov.a.aim(0, now);
    if (hov_a > 0.01) {
        pill(ctx, th.fg, (if (contrast) @as(f64, 0.08) else if (dark) @as(f64, 0.035) else 0.025) * (if (key) @as(f64, 1) else 0.7) * hov_a * fade, side_inset, lt + w.hov.s.step(now) - sy, side_w - 2 * side_inset - 2, side_h, side_radius);
    } else w.hov.park();

    // The selection hops from row to row with a little bounce, and rides
    // along when folders above it open or close.
    if (w.sel.gen != tree_gen or w.sel_id != w.focus.file.id) {
        w.sel.gen = tree_gen;
        w.sel_id = w.focus.file.id;
        w.sel.row = if (cur) |c| tree.rowOf(c) else null;
    }
    if (w.sel.row) |i| {
        const ty = f(i) * side_h - shiftOf(vs[0..vn], i);
        w.sel.follow(ty, w.sel.a.to == 0 or w.sel.last == null, now);
    } else w.sel.a.aim(0, now);
    w.sel.last = w.sel.row;
    const sel_a = w.sel.a.at(now) * if (w.sel.row) |sr| (if (insideOf(vs[0..vn], sr)) |v| v.p else 1.0) else 1.0;
    if (sel_a > 0.01) selFill(ctx, th, dark, key, sel_a * fade, side_inset, lt + w.sel.s.step(now) - sy, side_w - 2 * side_inset - 2, side_h, side_radius) else w.sel.park();

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
            drawRow(w, ctx, th, dark, i, y, null, sh, now);
            objc.CGContextRestoreGState(ctx);
            continue;
        }
        drawRow(w, ctx, th, dark, i, y, turnOf(vs[0..vn], i), sh, now);
    }
    // A list cut short says so on a row after its last.
    if (tree.truncated) {
        const y = lt + f(rows.len) * side_h - sy - moved;
        if (y < lt + view_h) {
            if (side_more == null) side_more = uiLine("Too many files to list them all", side_font, side_w - 32);
            _ = drawLineA(ctx, side_more, th.muted, 1, 26, y + side_base);
        }
    }

    // With the keys, the sidebar outlines the row they're on, and the
    // outline slides from row to row like the mouse's highlight.
    const kc_row = if (w.side_key and w.side_cur_gen == tree_gen) w.side_cur else null;
    if (kc_row) |i| if (i < rows.len) {
        w.kc.row = i;
        w.kc.follow(f(i) * side_h - shiftOf(vs[0..vn], i), w.kc.a.at(now) < 0.05, now);
    } else w.kc.a.aim(0, now) else w.kc.a.aim(0, now);
    const kc_a = w.kc.a.at(now);
    if (kc_a > 0.01) {
        const ky = lt + w.kc.s.step(now) - sy;
        pill(ctx, th.caret, 0.08 * kc_a * fade, side_inset, ky, side_w - 2 * side_inset - 2, side_h, side_radius);
        ring(ctx, th.caret, 0.55 * kc_a * fade, side_inset, ky, side_w - 2 * side_inset - 2, side_h, side_radius);
    } else w.kc.park();

    // Pinned folders, each held up by the end of its rows, the outer ones
    // drawn last so they stay on top. The one under the mouse lights like a
    // row, on its own highlight, so the rows' highlight stays under the pins.
    w.nstuck = stuckRows(sy, &w.stuck);
    if (w.hov_pin) |hp| w.pin_row = hp;
    w.pin_t.aim(if (w.hov_pin != null) 1 else 0, now);
    const pin_a = w.pin_t.at(now);
    var low = lt;
    var j = w.nstuck;
    while (j > 0) {
        j -= 1;
        const a = w.stuck[j];
        const e = tree.end(a);
        const y = @min(lt + f(j) * side_h, lt + f(e) * side_h - sy - side_h);
        w.stuck_y[j] = y;
        objc.CGContextClearRect(ctx, .{ .y = y, .w = side_w, .h = side_h });
        fillA(ctx, bg, chromeAlpha(th, dark, w.z.x), 0, y, side_w, side_h);
        if (a == w.pin_row and pin_a > 0.01) pill(ctx, th.fg, (if (contrast) @as(f64, 0.08) else if (dark) @as(f64, 0.035) else 0.025) * (if (key) @as(f64, 1) else 0.7) * pin_a * fade, side_inset, y, side_w - 2 * side_inset - 2, side_h, side_radius);
        drawRow(w, ctx, th, dark, a, y, turnOf(vs[0..vn], a), 0, now);
        low = @max(low, y + side_h);
    }
    // A hairline under whatever is pinned, once rows pass under it.
    const shade = std.math.clamp(sy / side_h, 0, 1);
    if (shade > 0) fillA(ctx, th.fg, (if (contrast) @as(f64, 0.2) else 0.08) * shade, 12, low - 1, side_w - 24, 1);
    // With more rows below the list's end, its last points fade away.
    const more = std.math.clamp((f(rows.len) * side_h - moved - sy - view_h) / side_fade, 0, 1);
    // Drawn at full strength: the band's height is what eases. In a layer
    // (the sidebar sliding) it only erases, and the layer's alpha does the rest.
    if (more * side_fade >= 1 and (fade >= 1 or layered)) fadeList(ctx, bg, chromeAlpha(th, dark, w.z.x), lt + view_h, more * side_fade, layered);
    objc.CGContextRestoreGState(ctx);
}

/// How tall the list's fade into the sidebar's background is at its bottom.
const side_fade = 16.0;
/// The two gradients that make it, built on first use and again when the
/// chrome color or its alpha changes: one erases the rows (clear to
/// opaque), the other puts the sidebar's background back as it was.
var fade_out: ?*anyopaque = null;
var fade_in: ?*anyopaque = null;
var fade_key: [4]f64 = undefined;

/// Fades the rows in the `h` points above `end` into the sidebar's
/// background `bg` (painted at alpha `a` over the material), fully.
/// The rows are erased with a gradient, then the background goes back with
/// the alpha that leaves the strip's empty parts as they were. In a
/// transparency layer (`erase_only`) the background under the layer stays,
/// so the erase is all it takes.
fn fadeList(ctx: Id, bg: Rgb, a: f64, end: f64, h: f64, erase_only: bool) void {
    const key = [4]f64{ bg[0], bg[1], bg[2], a };
    if (fade_out == null or !std.mem.eql(f64, &key, &fade_key)) {
        const space = objc.CGColorSpaceCreateDeviceRGB();
        defer if (space) |s| objc.CFRelease(s);
        if (fade_out) |g| objc.CFRelease(g);
        if (fade_in) |g| objc.CFRelease(g);
        const gone = [8]f64{ 0, 0, 0, 0, 0, 0, 0, 1 };
        fade_out = objc.CGGradientCreateWithColorComponents(space, &gone, null, 2);
        var comps: [20]f64 = undefined;
        var locs: [5]f64 = undefined;
        for (0..5) |i| {
            const t = f(i) / 4;
            locs[i] = t;
            comps[4 * i ..][0..3].* = bg;
            comps[4 * i + 3] = a * t / (1 - a + a * t);
        }
        fade_in = objc.CGGradientCreateWithColorComponents(space, &comps, &locs, 5);
        fade_key = key;
    }
    const y = end - h;
    const from = Point{ .y = y };
    const to = Point{ .y = end };
    objc.CGContextSaveGState(ctx);
    objc.CGContextClipToRect(ctx, .{ .y = y, .w = side_w - side_inset - 2, .h = h });
    objc.CGContextSetBlendMode(ctx, 23);
    objc.CGContextDrawLinearGradient(ctx, fade_out, from, to, 0);
    objc.CGContextSetBlendMode(ctx, 0);
    if (!erase_only) objc.CGContextDrawLinearGradient(ctx, fade_in, from, to, 0);
    objc.CGContextRestoreGState(ctx);
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
        // A folder click hands the sidebar the keys, on that folder.
        sideFocus(w, i);
        startFold(i);
        return;
    }
    // A file opens when the mouse comes up, unless it's dragged to a card;
    // the card it opens in takes the keys.
    if (w.side_key) {
        w.side_key = false;
        redrawSide(w);
    }
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ root.?, row.rel }, 0) catch return;
    const ix = rowIconX(row.depth);
    w.tdrag = .{ .from = null, .file = path, .cmd = flags & objc.cmd_key != 0, .down = p, .at = p, .grab = p.x - ix + tab_pad, .row = i };
}

/// Gives the sidebar the keys: the arrows, Return and typing work on its
/// rows until a click in a card or ⎋ hands them back. The outline starts
/// on `row`, or where it last was, or on the file on show.
fn sideFocus(w: *Win, row: ?usize) void {
    w.side_key = true;
    if (row) |r| {
        w.side_cur = r;
    } else if (w.side_cur == null or w.side_cur_gen != tree_gen) {
        w.side_cur = w.sel.row orelse if (tree.rows.items.len > 0) @as(?usize, 0) else null;
    }
    w.side_cur_gen = tree_gen;
    redrawSide(w);
}

/// View > Focus Sidebar (⇧⌘E): the sidebar takes the keys, shown first if
/// it was off.
fn focusSidebar(d: *Doc) void {
    if (root == null) return;
    if (!conf.sidebar) flip(.sidebar);
    sideFocus(d.win, null);
}

/// A key while the sidebar has the keys: ↑ and ↓ move, → opens a folder or
/// steps into it, ← closes it or steps out to its folder, Return opens a
/// file in the focused card (which takes the keys) or folds a folder, ⎋
/// hands the keys back, and letters pick the next row whose name starts
/// with them. False for keys it leaves alone (⌘ and ⌃ ones).
fn sideKey(w: *Win, ev: Id) bool {
    if (!w.side_key) return false;
    if (!sideShown(w)) {
        w.side_key = false;
        return false;
    }
    if (msg(usize, ev, "modifierFlags", .{}) & (objc.cmd_key | objc.ctrl_key) != 0) return false;
    const now = CACurrentMediaTime();
    finishFolds(now);
    const code = msg(u16, ev, "keyCode", .{});
    const rows = tree.rows.items;
    if (code == 53 or rows.len == 0) {
        w.side_key = code != 53;
        redrawSide(w);
        return true;
    }
    var i = @min(if (w.side_cur_gen == tree_gen) w.side_cur orelse 0 else 0, rows.len - 1);
    switch (code) {
        126 => i -|= 1,
        125 => i = @min(i + 1, rows.len - 1),
        124 => if (rows[i].dir) {
            if (!tree.isOpen(rows[i].rel)) startFold(i) else if (i + 1 < tree.rows.items.len and tree.rows.items[i + 1].depth > tree.rows.items[i].depth) {
                i += 1;
            }
        },
        123 => if (rows[i].dir and tree.isOpen(rows[i].rel)) startFold(i) else if (rows[i].depth > 0) {
            const want = rows[i].depth - 1;
            while (i > 0 and rows[i].depth != want) i -= 1;
        },
        36, 76 => if (rows[i].dir) startFold(i) else {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root.?, rows[i].rel }) catch return true;
            w.side_key = false;
            open(path, w.focus);
            redrawSide(w);
            return true;
        },
        else => {
            const s = objc.utf8(msg(Id, ev, "characters", .{}));
            if (s.len == 0 or s[0] < 0x20 or s[0] == 0x7f) return true;
            if (now - w.seek_t > 1.0) w.seek_len = 0;
            w.seek_t = now;
            const n = @min(s.len, w.seek.len - w.seek_len);
            @memcpy(w.seek[w.seek_len..][0..n], s[0..n]);
            w.seek_len += n;
            const q = w.seek[0..w.seek_len];
            // A first letter looks past the row it's on; more letters keep it if it still matches.
            const start = if (w.seek_len == n) i + 1 else i;
            for (0..rows.len) |k| {
                const r = (start + k) % rows.len;
                if (std.ascii.startsWithIgnoreCase(rows[r].rel[rows[r].base..], q)) {
                    i = r;
                    break;
                }
            }
        },
    }
    w.side_cur = @min(i, tree.rows.items.len -| 1);
    w.side_cur_gen = tree_gen;
    sideShowRow(w, w.side_cur.?);
    redrawSide(w);
    return true;
}

/// Glides the sidebar's list so row `i` is in view below the pinned folders.
fn sideShowRow(w: *Win, i: usize) void {
    const view_h = msg(Rect, w.view, "bounds", .{}).h - listTop() - gap;
    const y = f(i) * side_h;
    const pinned = f(w.nstuck) * side_h;
    var to = w.side_y;
    if (y < w.side_y + pinned) to = y - pinned else if (y + side_h > w.side_y + view_h) to = y + side_h - view_h;
    to = @max(0, to);
    if (to == w.side_y) return;
    w.side_t.snap(w.side_y);
    w.side_y = to;
    w.side_t.aim(to, CACurrentMediaTime());
}

// ---- text lines for the sidebar and status line ----

/// The sidebar's text as CoreText lines in the system font, made on first
/// draw: the folder's name, then one per tree row. Dropped when the tree or
/// the font changes; drawing one costs no layout.
var side_head: SideLine = .{};
/// A row's whole name and its width, made once, and the name cut to the room
/// it last had when it's wider than that: a width change remakes only a cut
/// line.
const SideLine = struct { full: Id = null, w: f64 = -1, cut: Id = null, cut_room: f64 = -1, icon: Id = null };
const Mark = struct {
    row: ?usize = null,
    gen: u32 = 0,
    last: ?usize = null,
    s: Spring,
    a: Tween = .{ .dur = fade_time },

    fn follow(m: *Mark, ty: f64, hidden: bool, now: f64) void {
        if (hidden) m.s.snap(ty) else if (m.last != m.row) m.s.aim(ty, now) else m.s.ride(ty);
        m.last = m.row;
        m.a.aim(1, now);
    }

    fn park(m: *Mark) void {
        if (!m.s.settled()) m.s.snap(m.s.to);
    }
};

const Bold = struct { line: SideLine = .{}, row: usize = 0, gen: u32 = 0 };

var side_lines: std.ArrayList(SideLine) = .empty;
/// The unsaved dot after a file's name, one line shared by every row.
var side_dot: Id = null;
/// The row after a list cut short, and the header's New badge.
var side_more: Id = null;
var new_badge: Id = null;

fn dropSideLines() void {
    if (side_dot) |l| objc.CFRelease(l);
    side_dot = null;
    for ([_]*Id{ &side_more, &new_badge }) |l| if (l.*) |x| {
        objc.CFRelease(x);
        l.* = null;
    };
    for (wins.items) |w| {
        for (&w.bold) |*b| freeSideLine(&b.line);
    }
    freeSideLine(&side_head);
    for (side_lines.items) |*l| freeSideLine(l);
    side_lines.clearRetainingCapacity();
}

/// Drops the header's folder, status and active tab's name.
fn dropHead(d: *Doc) void {
    if (d.head.line) |l| objc.CFRelease(l);
    d.head = .{};
    if (slotOf(d, d.file.id)) |k| d.slots.items[k].drop();
    if (d.stat) |l| objc.CFRelease(l);
    d.stat = null;
    d.stat_at[0] = std.math.maxInt(u64);
    if (d.stat_old) |l| objc.CFRelease(l);
    d.stat_old = null;
}

/// Code points in `s`: the bytes that don't continue a character.
fn codepoints(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| n += @intFromBool(c & 0xC0 != 0x80);
    return n;
}

/// `n` with a comma between its thousands.
fn grouped(out: *[32]u8, n: usize) []const u8 {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return "";
    var o: usize = 0;
    for (s, 0..) |c, i| {
        if (i > 0 and (s.len - i) % 3 == 0) {
            out[o] = ',';
            o += 1;
        }
        out[o] = c;
        o += 1;
    }
    return out[0..o];
}

fn put(buf: []u8, n: *usize, comptime fmt: []const u8, args: anytype) void {
    const out: []const u8 = std.fmt.bufPrint(buf[n.*..], fmt, args) catch "";
    n.* += out.len;
}

/// The status strip's line: the caret's line and column, the selection's
/// size, for text and Markdown the words, then the language, the indent and
/// the line endings. Made again only when one of those changed; the buffer
/// keeps the word count exact. A change in kind (another tab, a selection
/// coming or going, a new language, indent or line ending) keeps the old
/// line to crossfade from.
fn statusLine(d: *Doc, room: f64, now: f64) void {
    const e = &d.file.ed;
    const b = &e.buf;
    const t = e.text();
    const avail = @max(room, 0);
    const tabs = e.indent.len > 0 and e.indent[0] == '\t';
    const lang: []const u8 = if (d.file.lang_i) |i| syntax.languages[i].name else syntax.nameOf(d.file.lang);
    var lh_ = std.hash.Fnv1a_64.init();
    lh_.update(lang);
    lh_.update(e.indent);
    lh_.update(e.eol);
    lh_.update(&.{e.tab_width});
    const look = lh_.final();
    const at = [7]u64{ e.cur, e.anchor, b.changes, d.file.id, t.len, @intFromFloat(avail), look };
    if (d.stat != null and std.mem.eql(u64, &at, &d.stat_at)) return;
    d.stat_at = at;
    var buf: [240]u8 = undefined;
    var n: usize = 0;
    var g: [32]u8 = undefined;
    const li = b.lineOf(e.cur);
    put(&buf, &n, "Ln {d}, Col {d}", .{ li + 1, codepoints(t[b.lineStart(li)..e.cur]) + 1 });
    const ln_end = n;
    const s = e.sel();
    if (s[0] != s[1]) {
        const l1 = b.lineOf(s[1]);
        var lines = l1 - b.lineOf(s[0]) + 1;
        if (lines > 1 and s[1] == b.lineStart(l1)) lines -= 1;
        const chars = codepoints(t[s[0]..s[1]]);
        put(&buf, &n, "  ·  {s} character{s}, {d} line{s}", .{ grouped(&g, chars), if (chars == 1) "" else "s", lines, if (lines == 1) "" else "s" });
    }
    const words_on = switch (conf.word_count) {
        .always => true,
        .off => false,
        .auto => d.file.lang == &syntax.plain or d.file.lang.markdown,
    };
    if (words_on) {
        const words = b.wordCount();
        put(&buf, &n, "  ·  {s} word{s}", .{ grouped(&g, words), if (words == 1) "" else "s" });
    }
    const width: usize = if (tabs) e.tab_width else e.indent.len;
    put(&buf, &n, "  ·  {s}  ·  {s}: {d}  ·  {s}", .{ lang, if (tabs) "Tabs" else "Spaces", width, if (e.eol.len == 2) "CRLF" else "LF" });
    const kind = look ^ (@as(u64, d.file.id) << 2) ^ @as(u64, @intFromBool(s[0] != s[1])) ^ (@as(u64, @intFromBool(words_on)) << 1);
    if (d.stat) |l| {
        if (kind != d.stat_kind) {
            if (d.stat_old) |o| objc.CFRelease(o);
            d.stat_old = l;
            d.stat_old_w = d.stat_w;
            d.stat_t0 = now;
        } else objc.CFRelease(l);
    }
    d.stat_kind = kind;
    d.stat = uiLine(buf[0..n], path_font, avail);
    d.stat_w = lineW(d.stat);
    d.stat_ln_w = if (d.stat) |l| CTLineGetOffsetForStringIndex(l, @intCast(ln_end), null) else 0;
}

/// `s` as a line in `fnt` that takes the context's fill color, cut with an
/// ellipsis past `width`. Owned: CFRelease it.
fn uiLine(s: []const u8, fnt: Id, width: f64) Id {
    return uiLineCut(s, fnt, width, 1);
}

/// `uiLine` cut at its end (`at` 1) or in its middle (2).
fn uiLineCut(s: []const u8, fnt: Id, width: f64, at: u32) Id {
    const attrs = uiAttrs(fnt);
    const text = attributed(s, attrs);
    defer msg(void, text, "release", .{});
    const line = objc.CTLineCreateWithAttributedString(text);
    if (line == null or lineW(line) <= width) return line;
    const short = objc.CTLineCreateTruncatedLine(line, width, at, uiDots(fnt));
    if (short == null) return line;
    objc.CFRelease(line.?);
    return short;
}

/// One attributes dictionary and cut ellipsis per UI font in use, emptied
/// when the fonts are made again.
const UiAttrs = struct { font: Id, attrs: Id, dots: Id = null };
var ui_attrs: [10]UiAttrs = undefined;
var ui_attrs_n: usize = 0;

fn dropAttrs() void {
    for (ui_attrs[0..ui_attrs_n]) |a| {
        msg(void, a.attrs, "release", .{});
        if (a.dots) |d| objc.CFRelease(d);
    }
    ui_attrs_n = 0;
}

fn uiAttrs(fnt: Id) Id {
    return uiEntry(fnt).attrs;
}

fn uiEntry(fnt: Id) *UiAttrs {
    for (ui_attrs[0..ui_attrs_n]) |*a| if (a.font == fnt) return a;
    if (ui_attrs_n == ui_attrs.len) dropAttrs();
    const objs = [2]Id{ fnt, msg(Id, objc.class("NSNumber"), "numberWithBool:", .{true}) };
    const keys = [2]Id{ objc.str("NSFont"), objc.str("CTForegroundColorFromContext") };
    const made = msg(Id, msg(Id, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &objs, &keys, @as(usize, 2) }), "retain", .{});
    ui_attrs[ui_attrs_n] = .{ .font = fnt, .attrs = made };
    ui_attrs_n += 1;
    return &ui_attrs[ui_attrs_n - 1];
}

fn uiDots(fnt: Id) Id {
    const e = uiEntry(fnt);
    if (e.dots == null) {
        const text = attributed("…", e.attrs);
        defer msg(void, text, "release", .{});
        e.dots = objc.CTLineCreateWithAttributedString(text);
    }
    return e.dots;
}

fn attributed(s: []const u8, attrs: Id) Id {
    return msg(Id, msg(Id, objc.class("NSAttributedString"), "alloc", .{}), "initWithString:attributes:", .{ objc.str(s), attrs });
}

fn drawLineA(ctx: Id, line: Id, c: Rgb, a: f64, x: f64, y: f64) f64 {
    if (line == null) return 0;
    paintLine(ctx, line, c, a, x, y);
    return lineW(line);
}

fn lineW(line: Id) f64 {
    return if (line == null) 0 else objc.CTLineGetTypographicBounds(line, null, null, null);
}

fn textW(s: []const u8, fnt: Id) f64 {
    const line = uiLine(s, fnt, 1e9);
    defer if (line) |l| objc.CFRelease(l);
    return lineW(line);
}

/// Draws a line without measuring it when its width is known or unused.
fn paintLine(ctx: Id, line: Id, c: Rgb, a: f64, x: f64, y: f64) void {
    if (line == null) return;
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    objc.CGContextSetTextPosition(ctx, x, y);
    objc.CTLineDraw(line, ctx);
    // The grid's glyph runs read the text matrix's offset too, so put it back.
    objc.flipText(ctx);
}

// ---- drawing a window ----

/// Whether the window's look is dark, asked of AppKit again only after
/// `lookChanged` forgets the answer.
fn isDark(w: *Win) bool {
    if (w.dark) |dk| return dk;
    const name = objc.utf8(msg(Id, msg(Id, w.view, "effectiveAppearance", .{}), "name", .{}));
    const dk = std.mem.indexOf(u8, name, "Dark") != null;
    w.dark = dk;
    return dk;
}

fn themeOf(w: *Win) *const Theme {
    return &themes[@intFromBool(isDark(w))];
}

/// `kinds` is the row's line's offset in `lex[0].kinds`, not a slice, since
/// lexing a later row can move that buffer.
const VRow = struct { line: usize, seg: Seg, kinds: ?usize = null, reach: u8 = 0 };

fn cardRect(d: *const Doc) Rect {
    return .{ .x = gap, .y = gap, .w = d.size.x - 2 * gap, .h = d.size.y - 2 * gap };
}

fn cardShade(d: *const Doc, ctx: Id, dark: bool, now: f64) void {
    const zen_k = 1 - zen(d.win);
    const card = cardRect(d);
    if (zen_k > 0) cardShadow(ctx, dark, zen_k * (0.5 + 0.5 * d.win.key_a.at(now)), card.x, card.y, card.w, card.h);
}

fn cardDirtyRect(d: *const Doc) Rect {
    const card = cardRect(d);
    const xm = shadow_m + 6;
    const ym = shadow_m;
    return .{
        .x = d.org.x + card.x - xm,
        .y = d.org.y + card.y - ym,
        .w = @max(card.w + 2 * xm, 0),
        .h = @max(card.h + 2 * ym, 0),
    };
}

/// Draws a window: its chrome, each card in its pane, then the sidebar and
/// the buttons by the traffic lights.
fn draw(w: *Win, ctx: Id, dirty: Rect) void {
    const now = CACurrentMediaTime();
    const dark = isDark(w);
    const th = &themes[@intFromBool(dark)];
    const r = msg(Rect, w.view, "bounds", .{});
    const resizing = msg(bool, w.view, "inLiveResize", .{});
    dev_px = 1 / @max(1, msg(f64, w.window, "backingScaleFactor", .{}));
    const full = fitTitlebar(w, r);
    // A stretched sidebar edge springs back to its limit.
    if (side_stretch.x != 0 or side_stretch.v != 0) {
        _ = side_stretch.step(now);
        side_w = @round(side_rest + side_stretch.x);
    }
    // A closing folder shuts once its rows have folded away.
    finishFolds(now);
    // The sidebar slides in and out, on the first draw it's just there.
    const shown = sideShownAt(r.w);
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
    w.peek.aim(if (full or w.peek_in or now < w.peek_out) 1 else 0, now);
    const la = 1 - zen(w);
    const lit = @max(la, w.peek.at(now));
    if (lit != w.lights_a) {
        setLights(w, lit);
        w.lights_a = lit;
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
    objc.CGContextSaveGState(ctx);
    CGContextAddRect(ctx, dirty);
    for (docs.items) |d| if (d.win == w) {
        const grown = std.math.clamp(@min((d.size.x - 2 * gap) / 160, (d.size.y - 2 * gap) / 100), 0, 1);
        if (grown < 1) continue;
        const shaking = (now - d.card_shake_t0) / shake_time;
        if (shaking >= 0 and shaking < 1) continue;
        const body: Rect = .{ .x = d.org.x + gap, .y = d.org.y, .w = d.size.x - gap, .h = d.size.y };
        if (!hits(dirty, body)) continue;
        const card = cardRect(d);
        const inset = card_radius + 2;
        const iw = card.w - 2 * inset;
        const ih = card.h - 2 * inset;
        if (iw > 0 and ih > 0) {
            CGContextAddRect(ctx, .{ .x = d.org.x + card.x + inset, .y = d.org.y + card.y + inset, .w = iw, .h = ih });
        }
    };
    CGContextEOClip(ctx);
    objc.CGContextClearRect(ctx, dirty);
    fillA(ctx, chrome(th, dark, w.z.x), chromeAlpha(th, dark, w.z.x), dirty.x, dirty.y, dirty.w, dirty.h);
    objc.CGContextRestoreGState(ctx);
    // Text upright for every draw: a strip-only one skips the cards, whose drawPane also sets it.
    objc.flipText(ctx);
    const key = msg(bool, w.window, "isKeyWindow", .{});
    const many = w.cards.pane == null;
    for (&w.hot_t, [3]u8{ 1, 2, 4 }) |*t, bit| t.aim(if (w.hot == bit) 1 else 0, now);
    // A note waiting for a window shows in the first one that draws.
    if (pending_len > 0) {
        toast(w, pending_toast[0..pending_len]);
        pending_len = 0;
    }
    w.key_a.aim(if (key) 1 else 0, now);
    // The sidebar's own motion (its picked and hovered rows, the + button,
    // its scroll and folding folders) redraws only its strip; anything else
    // redraws the window.
    var busy = w.side_a.moving(now) or cardsMoving(w.cards) or
        (w.hot_t[0].moving(now) and !toggleInSide(shown, slid)) or
        w.pv_a.moving(now) or w.ghost_a.moving(now) or (w.menu_card != null and w.menu_a.moving(now)) or w.fly != null or
        !w.lift.settled() or w.key_a.moving(now) or !side_stretch.settled() or !w.z.settled();
    const dots_busy = sideDotsBusy(w, now) and shown;
    for (w.pv) |s| busy = busy or !s.settled();
    busy = busy or w.press_t.moving(now);
    const down = w.press_t.at(now);
    var gliding = false;
    var cards_busy = false;
    for (docs.items) |d| if (d.win == w) {
        // A card springing in or folding away fades with its size.
        const grown = std.math.clamp(@min((d.size.x - 2 * gap) / 160, (d.size.y - 2 * gap) / 100), 0, 1);
        if (grown <= 0.01) continue;
        // A strip redraw that doesn't reach this card leaves it be, and one
        // that reaches only its shadow draws just that.
        const body: Rect = .{ .x = d.org.x + gap, .y = d.org.y, .w = d.size.x - gap, .h = d.size.y };
        const shade: Rect = .{ .x = body.x - shadow_m, .y = body.y, .w = body.w - gap + 2 * shadow_m, .h = body.h };
        const shaking = (now - d.card_shake_t0) / shake_time;
        const is_shaking = shaking >= 0 and shaking < 1;
        if (hits(dirty, if (is_shaking) cardDirtyRect(d) else shade)) {
            objc.CGContextSaveGState(ctx);
            objc.CGContextTranslateCTM(ctx, d.org.x, d.org.y);
            if (is_shaking) objc.CGContextTranslateCTM(ctx, 6 * @sin(2 * std.math.pi * 3 * shaking) * (1 - shaking), 0);
            if (grown < 1) {
                objc.CGContextSetAlpha(ctx, grown);
                objc.CGContextBeginTransparencyLayer(ctx, null);
            }
            if (hits(dirty, body) or is_shaking) drawPane(d, ctx, th, dark, key, many, now, resizing) else cardShade(d, ctx, dark, now);
            if (grown < 1) objc.CGContextEndTransparencyLayer(ctx);
            objc.CGContextRestoreGState(ctx);
        }
        if (grown < 1) {
            busy = busy or d.busy or is_shaking;
        } else cards_busy = cards_busy or d.busy or is_shaking;
        gliding = gliding or d.cx.moving(now) or d.cy.moving(now);
    };
    // A gap that just snapped flashes a faint guide down its middle.
    if (w.guide) |n| {
        const t = (now - w.guide_t0) / guide_time;
        if (t >= 0 and t < 1 and n.pane == null) {
            const g = gapRect(n);
            const ga = @as(f64, if (contrast) 0.8 else 0.5) * (1 - t) * (1 - t);
            if (n.down) {
                pill(ctx, th.caret, ga, g.x + 16, g.y + g.h / 2 - 1, @max(g.w - 32, 0), 2, 1);
            } else pill(ctx, th.caret, ga, g.x + g.w / 2 - 1, g.y + 16, 2, @max(g.h - 32, 0), 1);
            busy = true;
        } else w.guide = null;
    }
    // The sidebar, and the buttons by the traffic lights, each with a soft
    // highlight under the mouse.
    const hy = headY();
    if (slid > 0.002 and root != null) {
        if (hits(dirty, .{ .w = side_w * slid, .h = r.h })) {
            objc.CGContextSaveGState(ctx);
            objc.CGContextClipToRect(ctx, .{ .w = side_w * slid, .h = r.h });
            objc.CGContextTranslateCTM(ctx, side_w * (slid - 1), 0);
            // Sliding, the strip draws into a layer that fades as a whole, so
            // the list's bottom fade stays as it is at rest.
            const sliding = slid < 1;
            if (sliding) {
                objc.CGContextSetAlpha(ctx, slid * slid);
                objc.CGContextBeginTransparencyLayer(ctx, null);
            }
            drawSide(w, ctx, th, dark, key, chrome(th, dark, w.z.x), 1, sliding, now);
            hoverPill(ctx, th, w.hot_t[1].at(now), if (w.press == 2) down else 0, side_w - gap - 20, hy);
            drawIcon(icon(.plus, dark, th), side_w - gap - 30, hy - 10, 20);
            if (sliding) objc.CGContextEndTransparencyLayer(ctx);
            objc.CGContextRestoreGState(ctx);
        }
    } else {
        w.hov.park();
        w.sel.park();
    }
    // In zen it fades out with the lights, on the same spring. With the
    // sidebar on but the window too narrow to show it, the button dims.
    w.tog_dim.aim(if (conf.sidebar and !shown) 0.4 else 1, now);
    if (root != null and la > 0.01) {
        const ta = la * w.tog_dim.at(now);
        if (ta < 1) objc.CGContextSetAlpha(ctx, ta);
        hoverPill(ctx, th, w.hot_t[0].at(now), if (w.press == 1) down else 0, toggle_x, hy);
        drawIcon(icon(.sidebar, dark, th), toggle_x - 10, hy - 10, 20);
        if (ta < 1) objc.CGContextSetAlpha(ctx, 1);
    }
    // Files from Finder over the window: the cards' room lights up.
    w.drop_t.aim(if (w.drop_on) 1 else 0, now);
    const drop_a = w.drop_t.at(now);
    if (drop_a > 0.01) {
        const dx = w.lx;
        pill(ctx, th.caret, 0.06 * drop_a, dx, gap, r.w - dx - gap, r.h - 2 * gap, card_radius);
        ring(ctx, th.caret, 0.6 * drop_a, dx, gap, r.w - dx - gap, r.h - 2 * gap, card_radius);
    }
    drawDrag(w, ctx, th, dark, now);
    const toasting = drawToast(w, ctx, th, r, now);
    busy = busy or w.drop_t.moving(now) or w.tog_dim.moving(now) or toasting;
    const side_busy = w.side_t.moving(now) or foldsBusy(now) or !w.sel.s.settled() or w.sel.a.moving(now) or w.hot_t[1].moving(now) or !w.hov.s.settled() or w.hov.a.moving(now)
        or dots_busy or (w.menu_card == null and w.menu_a.moving(now)) or (w.hot_t[0].moving(now) and toggleInSide(shown, slid)) or
        w.hot_t[2].moving(now) or w.pin_t.moving(now) or !w.kc.s.settled() or w.kc.a.moving(now);
    // Only the sidebar's strip moves when its rows' highlights are all that does.
    w.part = !busy and !cards_busy and side_busy and shown and slid >= 1;
    w.cards_only = cards_busy and !busy and !side_busy;
    w.busy = busy or cards_busy or side_busy or w.peek.moving(now);
    if (w.busy or gliding) msg(void, w.link, "setPaused:", .{false});
}

/// How long a note holds before it fades out.
const toast_hold = 2.0;
/// A note for a window that doesn't exist yet, shown by the first one drawn.
var pending_toast: [160]u8 = undefined;
var pending_len: usize = 0;

/// Shows `text` in a pill near the bottom of `w`'s cards: it fades and
/// rises in, holds, then fades out. A new note takes the old one's place.
fn toast(w: *Win, text: []const u8) void {
    var n = @min(text.len, w.toast_buf.len);
    while (n > 0 and n < text.len and text[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(w.toast_buf[0..n], text[0..n]);
    w.toast_len = n;
    if (w.toast_line) |l| objc.CFRelease(l);
    w.toast_line = null;
    const now = CACurrentMediaTime();
    w.toast_t0 = now;
    w.toast_t.aimOver(1, fade_time, now);
    objc.later(w.view, "holdRedraw:", w.link, toast_hold + 0.02);
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// `toast` on the key window, or the front one, or the first one to open.
fn toastFront(text: []const u8) void {
    const d = keyDoc() orelse if (wins.items.len > 0) wins.items[wins.items.len - 1].focus else null;
    if (d) |x| return toast(x.win, text);
    var n = @min(text.len, pending_toast.len);
    while (n > 0 and n < text.len and text[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(pending_toast[0..n], text[0..n]);
    pending_len = n;
}

/// Draws `w`'s note, if it has one. True while it's fading.
fn drawToast(w: *Win, ctx: Id, th: *const Theme, r: Rect, now: f64) bool {
    if (w.toast_len == 0) return false;
    if (now >= w.toast_t0 + toast_hold) w.toast_t.aimOver(0, 0.3, now);
    const a = std.math.clamp(w.toast_t.at(now), 0, 1);
    if (w.toast_t.to == 0 and !w.toast_t.moving(now)) {
        if (w.toast_line) |l| objc.CFRelease(l);
        w.toast_line = null;
        w.toast_len = 0;
        return false;
    }
    const room = @max(r.w - w.lx - 4 * gap - 28, 80);
    if (w.toast_line == null) w.toast_line = uiLine(w.toast_buf[0..w.toast_len], side_font, room);
    const lw = lineW(w.toast_line);
    const pw = lw + 28;
    const x = @round((w.lx + r.w - gap) / 2 - pw / 2);
    const y = @round(r.h - gap - strip_h - side_h - 14 + (1 - a) * 6);
    pill(ctx, th.fg, (if (contrast) @as(f64, 0.96) else 0.86) * a, x, y, pw, side_h, side_h / 2);
    _ = drawLineA(ctx, w.toast_line, th.bg, a, x + 14, y + side_base);
    return w.toast_t.moving(now);
}

const FindMarks = struct { cur: ?[2]usize, pop: f64, prev_a: f64, pills: []const u8, sensitive: bool, pills_a: f64 };

/// Settles the find indicator for this frame: the current match (popping on
/// arrival), the one fading out, and what the other pills match.
fn findMarks(d: *Doc, s: [2]usize, finding: bool, now: f64) FindMarks {
    var cur_m: ?[2]usize = null;
    if (finding) {
        const want = d.prompt.items;
        if (s[1] - s[0] == want.len and editor.matches(d.file.ed.text(), s[0], want, find_opts.sensitive(want), find_opts.whole_word)) cur_m = s;
    } else if (d.mode == .edit and s[0] != s[1]) {
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
        if (d.pundo.items.len == 0) d.stag_t0 = now;
    }
    // The other matches' pills stay while the find bar slides away, fading with it.
    const closing_find = d.mode == .edit and d.held_id == d.file.id and (d.held_mode == .find or d.held_mode == .replace) and d.pbar.at(now) > 0.002;
    const pills: []const u8 = if (finding) d.prompt.items else if (closing_find) d.held.items else "";
    return .{ .cur = cur_m, .pop = pop, .prev_a = prev_a, .pills = pills, .sensitive = find_opts.sensitive(pills), .pills_a = if (finding) 1 else d.pbar.at(now) };
}

/// Draws a card in its pane's coordinates: the text, the prompt line and
/// the header. `win_key` says whether its window is key, and `many`
/// whether the window has other cards, which lights the focused one's ring.
fn drawPane(d: *Doc, ctx: Id, th: *const Theme, dark: bool, win_key: bool, many: bool, now: f64, resizing: bool) void {
    if (d.dark != dark or !std.mem.eql(f64, &d.caret_ink, &th.caret)) {
        d.dark = dark;
        // `moveCaret` colors the layer from this.
        d.caret_ink = th.caret;
        d.caret_at = null;
        preview.update(d, th);
    }
    const card = cardRect(d);
    const zt = zen(d.win);
    const zen_k = 1 - zt;
    const focused = d.win.focus == d;
    // Only the key window's focused card has the keys; other cards' carets draw hollow.
    const key = win_key and focused and !d.closing;
    d.lit.aim(if (focused and many and win_key) 1 else 0, now);
    if (d.lit.dur != tab_time and !d.lit.moving(now)) {
        d.lit.snap(d.lit.to);
        d.lit.dur = tab_time;
    }
    d.inked.aim(if (key) 1 else 0, now);
    const ka = d.inked.at(now);
    aimBand(d, now);
    const b = &d.file.ed.buf;
    d.gut.aim(gutCols(d), now);
    d.gw = d.gut.at(now) * cw * zen_k;
    layout(d);
    if (conf.typewriter and d.center_h != textH(d)) reveal(d);
    d.center_h = textH(d);
    clampScroll(d);
    // Jumps glide the scroll. Stepping past the edge a few rows at a time and
    // live resizing snap it (the trackpad snaps in scrollWheel), and the caret
    // and band move with the page so they don't bounce back to the edge.
    if (d.file.sy != d.ys.to) {
        const dist = @abs(d.file.sy - d.ys.to);
        if (resizing or (!conf.typewriter and !d.ys.moving(now) and dist <= glide_rows * lh)) {
            const by = d.file.sy - d.ys.at(now);
            d.ys.snap(d.file.sy);
            d.band.shift(by);
            if (d.c_text) d.cy.shift(by);
        } else if (conf.typewriter and !d.ys.moving(now) and dist > glide_rows * lh) {
            // Typing after a scroll away eases back to the middle, longer
            // for a longer way.
            d.ys.aimOver(d.file.sy, std.math.clamp(scroll_time + 0.08 * @log2(dist / lh), scroll_time, 0.45), now);
        } else d.ys.aimOver(d.file.sy, scroll_time, now);
    }
    if (d.file.sx != d.xs.to) {
        if (resizing or (!d.xs.moving(now) and @abs(d.file.sx - d.xs.to) <= 16 * cw)) {
            const by = d.file.sx - d.xs.at(now);
            d.xs.snap(d.file.sx);
            if (d.c_text) d.cx.shift(by);
        } else d.xs.aim(d.file.sx, now);
    }
    d.vy = d.ys.at(now);
    d.vx = d.xs.at(now);
    // The Markdown preview follows the previewed file down the page.
    if (preview.shownFor(d.file.id)) {
        const range = scrollRange(d);
        const span = range[1] - range[0];
        const fr = if (span > 0) std.math.clamp((d.vy - range[0]) / span, 0, 1) else 0;
        if (fr != preview_frac) {
            preview_frac = fr;
            preview.syncScroll(fr);
        }
    }
    // The card that holds the text, header and prompt line, which draw
    // inside its rounded corners.
    cardShade(d, ctx, dark, now);
    pill(ctx, th.bg, 1, card.x, card.y, card.w, card.h, card_radius);
    const rect_only = d.pbar.at(now) == 0 and d.panel.at(now) <= 0.5 and (top_h - card.y) >= card_radius and stripH(d) >= card_radius;
    if (!rect_only) {
        objc.CGContextSaveGState(ctx);
        clipRound(ctx, card.x, card.y, card.w, card.h, card_radius);
    }
    objc.flipText(ctx);

    const total = totalRows(d);
    const last = @min(total, @as(usize, @intFromFloat(@max(@ceil((d.vy + textH(d)) / lh), 0))) + 1);
    const first: usize = @min(@as(usize, @intFromFloat(@max(@floor(d.vy / lh), 0))), last);
    const skip: usize = @intFromFloat(@max(@ceil(d.vx / cw), 0));
    const tx = gap + padL(d);
    // Sideways-scrolled text stops at the line numbers rather than running under them.
    const clip_l = card.x + (tx - 0.5 * cw - card.x) * std.math.clamp(d.gw / (3.5 * cw), 0, 1);
    const ox = tx + f(skip) * cw - d.vx;
    // Text stops a whole column inside the same margin on the right as on
    // the left, rather than running into the card's border.
    const cols: usize = @intFromFloat(@max(@floor((card.x + card.w - pad_x - ox) / cw), 0));
    const s = d.file.ed.sel();
    const here = caretRow(d);
    const finding = (d.mode == .find or d.mode == .replace) and d.prompt.items.len > 0;

    // The screen rows in view, and the line and part of it each one shows.
    var vis: [400]VRow = undefined;
    var vis_cut: [400]struct { byte: usize, col: usize } = undefined;
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
    const wide_snap: WideSnap = .{
        .touched = b.touched,
        .touched_end = b.touched_end,
        .shifted = b.lines_shifted,
        .shift_at = b.shift_at,
        .delta = b.line_delta,
    };
    syncStates(d, if (nvis > 0) vis[nvis - 1].line else 0);

    // A file freshly read from disk fades in, rising a few points into
    // place. A tab switch just fades from a little dim, with no rise.
    const base_a = d.load.at(now);
    objc.CGContextSaveGState(ctx);
    // Text stops above the status strip rather than running under it.
    const text_bottom = card.y + card.h - stripH(d) * (1 - d.pbar.at(now));
    objc.CGContextClipToRect(ctx, .{ .x = card.x, .y = top_h, .w = card.w, .h = @max(text_bottom - top_h, 0) });
    if (base_a < 1) {
        objc.CGContextSetAlpha(ctx, base_a);
        if (d.file.rise) objc.CGContextTranslateCTM(ctx, 0, (1 - base_a) * load_rise);
    }

    // The caret line's band slides after the caret. It fades away under a
    // selection, recedes with Focus's dimming, and in Zen spans only the
    // centered page.
    const band_on = d.mode == .edit;
    if (band_on and d.band_on) d.band.aimOver(f(here.row) * lh, if (conf.typewriter) scroll_time else caret_time, now) else d.band.snap(f(here.row) * lh);
    d.band_on = band_on;
    d.band_a.aim(if (band_on and s[0] == s[1]) 1 else 0, now);
    const band_alpha = d.band_a.at(now) * (1 - d.focus_a.at(now) * conf.focus_dim * 0.5);
    if (band_alpha > 0 and conf.highlight_current_line) {
        const right = card.x + card.w;
        const bx0 = gap + (@max(gap, tx - cw) - gap) * zt;
        const bx1 = right + (@min(right, tx + f(conf.zen_columns + 1) * cw) - right) * zt;
        fillA(ctx, th.line, band_alpha, bx0, top_h + d.band.at(now) - d.vy, bx1 - bx0, lh);
    }
    objc.CGContextSaveGState(ctx);
    objc.CGContextClipToRect(ctx, .{ .x = clip_l, .y = card.y, .w = ox + f(cols) * cw - clip_l, .h = card.h });

    // A new selection fades in.
    const has_sel = s[0] != s[1];
    const was_sel = d.had_sel;
    if (has_sel and !was_sel) d.sel_in.snap(0);
    d.had_sel = has_sel;
    if (has_sel) d.sel_in.aim(1, now);
    const sel_a = d.sel_in.at(now);
    if (d.file.ed.buf.changes != d.sel_chg) d.sel_out.snap(0);
    // A selection that collapses with the text untouched (a click, an arrow, Escape)
    // fades out where it was; an edit under it cuts, and a new selection replaces it.
    if (has_sel) {
        d.sel_out.snap(0);
        d.sel_last = s;
    } else if (was_sel and d.file.ed.buf.changes == d.sel_chg) {
        d.sel_out.snap(sel_a);
        d.sel_out.aim(0, now);
    }
    d.sel_chg = d.file.ed.buf.changes;
    const out_a = d.sel_out.at(now);

    const fm = findMarks(d, s, finding, now);
    flashWait(d, now);
    const flash_a = flashAlpha(d, now);
    // A selection in a card without the keys, or a window in the
    // background, draws dimmer.
    const sel_k = 0.45 + 0.55 * ka;
    // The bracket beside the caret and its partner, looked for again only
    // when the caret or the text moves; marked while the caret has the keys.
    const br_at: [2]u64 = .{ d.file.ed.cur, d.file.ed.buf.changes };
    if (!std.mem.eql(u64, &br_at, &d.br_at)) {
        d.br_at = br_at;
        d.br = d.file.ed.matchingBracket();
    }
    const br: ?[2]usize = if (d.mode == .edit and !has_sel and key) d.br else null;
    const tw = d.file.ed.tabWidth();

    // Backgrounds: indent guides, selection, flash, bracket marks, find matches.
    for (vis[0..nvis], first..) |v, row| {
        const y = top_h + f(row) * lh - d.vy;
        const ls = b.lineStart(v.line);
        const l = b.line(v.line);
        const sg = v.seg;
        if (conf.indent_guides) {
            // A wrapped row carries its line's guides only as far as its hanging indent.
            const upto = if (sg.k == 0) guideCols(d, v.line, tw) else sg.ind;
            var c: usize = 0;
            while (c < upto) : (c += tw) if (c >= skip) {
                fillA(ctx, th.muted, if (contrast) 0.4 else 0.22, snapPx(ox + (f(c) - f(skip)) * cw + 1), y, 2 * hair(), lh);
            };
        }
        if (has_sel) fillSpan(ctx, th.sel, sel_a * sel_k, s, ls, l, sg, ox, skip, y);
        if (out_a > 0) fillSpan(ctx, th.sel, out_a * sel_k, d.sel_last, ls, l, sg, ox, skip, y);
        if (flash_a > 0) for (d.flash[0..d.flash_n]) |fr| {
            if (fr[0] != fr[1]) {
                fillSpan(ctx, th.caret, flash_a, fr, ls, l, sg, ox, skip, y);
                continue;
            }
            // An empty span flashes as a bar where text went, on its row only.
            if (fr[0] < ls or fr[0] > ls + l.len) continue;
            const p = fr[0] - ls;
            if (p < sg.start or (p >= sg.end and sg.end < l.len)) continue;
            const x = ox + (f(editor.colOfTab(l, sg.start, sg.col, p, tw) - sg.col + sg.ind) - f(skip)) * cw;
            pill(ctx, th.caret, @min(1, flash_a * 2), x - 1.25, y + 2, 2.5, lh - 4, 1.25);
        };
        if (br) |pair| for (pair) |p| {
            const sp = rowSpan(l, ls, sg, .{ p, p + 1 }, ox, skip) orelse continue;
            if (sp.lo >= sp.hi) continue;
            pill(ctx, th.muted, if (contrast) 0.3 else 0.18, sp.x0 - 1, y + 2, sp.x1 - sp.x0 + 2, lh - 4, 3);
            fillA(ctx, th.caret, 0.7, sp.x0 + 1, snapPx(y + lh - 4), sp.x1 - sp.x0 - 2, 2 * hair());
        };
        if (fm.pills.len > 0) {
            // Opening find on prefilled text fades the matches in, the nearest first.
            const dist = if (row > here.row) row - here.row else here.row - row;
            const m_a = std.math.clamp((now - d.stag_t0 - @min(stag_row * f(dist), stag_cap)) / fade_time, 0, 1) * fm.pills_a;
            // Each pill's column carries on from the last one's, and the scan
            // stops past the right edge, so a long unwrapped line costs one pass.
            var at = sg.start;
            var col = sg.col;
            var j = sg.start -| (fm.pills.len - 1);
            const stop = @min(sg.end + fm.pills.len - 1, l.len);
            while (j < sg.end and j + fm.pills.len <= l.len) {
                const m_at = editor.nextMatch(l, fm.pills, j, stop, find_opts) orelse break;
                if (m_at >= sg.end) break;
                const lo = @max(m_at, sg.start);
                const hi = @min(m_at + fm.pills.len, sg.end);
                const c0 = editor.colOfTab(l, at, col, lo, tw);
                col = editor.colOfTab(l, lo, c0, hi, tw);
                at = hi;
                if (c0 - sg.col > skip + cols) break;
                if (col - sg.col + sg.ind + 1 >= skip and ls + m_at != s[0]) pill(ctx, th.match, match_alpha * m_a, ox + (f(c0 - sg.col + sg.ind) - f(skip)) * cw, y + 2, f(col - c0) * cw, lh - 4, 3);
                j = m_at + fm.pills.len;
            }
        }
    }

    // Text.
    var k: Ink = .{ .ctx = ctx };
    d.focus_a.aim(if (d.focus_on) 1 else 0, now);
    const focus_amt = d.focus_a.at(now);
    if (d.focus_on or focus_amt > 0) k.focus = .{ .new = d.focus_new, .old = d.focus_old, .t = std.math.clamp((now - d.focus_t0) / focus_time, 0, 1), .amt = focus_amt };
    k.selected = s;
    k.tw = tw;
    k.invis = conf.show_invisibles;
    k.invis_ink = mixRgb(th.bg, th.muted, if (contrast) 0.8 else 0.55);
    std.mem.swap(Kinds, &d.lex[0], &d.lex[1]);
    d.lex[0].clear();
    var walk: usize = 0;
    var lexed: usize = std.math.maxInt(usize);
    var kinds: ?usize = null;
    // Pass 0 stops a column short of the margin; it draws one cell more than
    // fits to learn which rows reach it (1) and which run past it (2). Pass 1
    // draws the last columns of rows that just fit at full strength, and the
    // passes after it the cut rows' last column in vertical strips of falling
    // alpha, so the text fades toward the page, band or selection under it
    // with no layer and one batch per strip however many rows are cut.
    const strip_a = [_]f64{ 0.8, 0.55, 0.3, 0.1 };
    var any_reach = fm.prev_a > 0 or fm.cur != null;
    var any_cut = false;
    for (0..2 + strip_a.len) |pass| {
        const x0 = ox + f(cols -| 1) * cw;
        objc.CGContextSaveGState(ctx);
        if (pass == 0) {
            if (cols > 0) objc.CGContextClipToRect(ctx, .{ .x = clip_l, .y = card.y, .w = x0 - clip_l, .h = card.h });
        } else {
            if (!any_reach or cols == 0 or (pass >= 2 and !any_cut)) {
                objc.CGContextRestoreGState(ctx);
                break;
            }
            if (pass == 1) {
                objc.CGContextClipToRect(ctx, .{ .x = x0, .y = card.y, .w = cw, .h = card.h });
            } else {
                const sw = cw / f(strip_a.len);
                objc.CGContextClipToRect(ctx, .{ .x = x0 + sw * f(pass - 2), .y = card.y, .w = sw, .h = card.h });
                objc.CGContextSetAlpha(ctx, base_a * strip_a[pass - 2]);
            }
        }
        lexed = std.math.maxInt(usize);
        for (vis[0..nvis], 0.., first..) |*v, vi, row| {
            if (pass == 1 and v.reach == 2) continue;
            if (pass >= 2 and v.reach != 2) continue;
            const l = b.line(v.line);
            const ls = b.lineStart(v.line);
            if (pass == 1 and v.reach == 0) {
                const fading_here = fm.prev_a > 0 and d.prev_m[0] <= ls + l.len and d.prev_m[1] > ls;
                const current_here = if (fm.cur) |m| m[0] <= ls + l.len and m[1] > ls else false;
                if (!fading_here and !current_here) continue;
            }
            if (pass == 0) {
                if (v.line != lexed) {
                    lexed = v.line;
                    kinds = if (d.file.lang != &syntax.plain and v.line < d.file.states.items.len) lineKinds(d, v.line, l, &walk) else null;
                }
                v.kinds = kinds;
            }
            const ks: ?[]const syntax.Kind = if (v.kinds) |at| d.lex[0].kinds.items[at..][0..l.len] else null;
            k.offset = ls;
            const row_y = top_h + f(row) * lh - d.vy;
            // Later passes redraw only the last columns, at the x pass 0 gives them.
            // A wrapped row's hanging indent moves it right.
            const ind = v.seg.ind;
            const back = @min(cols, 2);
            const cut_rel = (skip + cols - back) -| ind;
            const used = if (pass > 0)
                k.run(l, vis_cut[vi].byte, v.seg.end, vis_cut[vi].col, ks, th, th.fg, ox + f(cols - back) * cw, row_y + baseline, cut_rel - (vis_cut[vi].col - v.seg.col), back + 1)
            else blk: {
                var ct: Ink.Cut = .{ .target = cut_rel };
                const u = k.runCut(l, v.seg.start, v.seg.end, v.seg.col, ks, th, th.fg, ox + f(ind) * cw, row_y + baseline, skip, (cols + 1) -| ind, &ct) + ind;
                vis_cut[vi] = .{ .byte = ct.byte, .col = ct.col };
                break :blk u;
            };
            if (pass == 0) {
                v.reach = if (used > cols) 2 else if (used == cols) 1 else 0;
                any_reach = any_reach or used >= cols;
                any_cut = any_cut or used > cols;
            }
            if (fm.prev_a > 0) pillOver(&k, th, dark, l, k.offset, v.seg, d.prev_m, ox, skip, row_y, 1, fm.prev_a);
            if (fm.cur) |m| pillOver(&k, th, dark, l, k.offset, v.seg, m, ox, skip, row_y, fm.pop, 1);
        }
        k.flush();
        objc.CGContextRestoreGState(ctx);
    }
    objc.CGContextRestoreGState(ctx);
    // The gutter and prompt draw with this ink too, without marks.
    k.invis = .none;

    // Text scrolled sideways fades out into a faint rule where it meets
    // the line numbers (or the card's edge).
    if (d.vx > 0.5) {
        const sa = std.math.clamp(d.vx / cw, 0, 1);
        const h = edgeAt(d, now) - top_h;
        for (0..4) |i| fillA(ctx, th.bg, sa * (0.8 - 0.2 * f(i)), clip_l + f(i) * cw / 4, top_h, cw / 4, h);
        fillA(ctx, th.muted, sa * @as(f64, if (contrast) 0.5 else 0.3), snapPx(clip_l), top_h, hair(), h);
    }

    drawGutter(d, &k, th, vis[0..nvis], first, here.row, tx);
    objc.CGContextRestoreGState(ctx);
    if (rect_only) {
        objc.CGContextSaveGState(ctx);
        clipRound(ctx, card.x, card.y, card.w, card.h, card_radius);
    }

    drawBar(d, ctx, th, card, wide_snap, now);
    // Find's matches tick the card's right edge, fading with its band.
    drawTicks(d, ctx, th, card, fm.pills, fm.cur, fm.pills_a);

    if (d.mode == .edit) {
        const spot: [3]usize = .{ 0, here.row, here.col };
        // A shift-move that extends a selection snaps, like the selection's edge.
        if (has_sel and !std.mem.eql(usize, &spot, &d.spot)) d.snap = true;
        // A block or underline caret covers both cells of a wide character.
        const cl = b.line(b.lineOf(d.file.ed.cur));
        const cp = d.file.ed.cur - b.lineStart(b.lineOf(d.file.ed.cur));
        d.caret_cells = if (cp < cl.len and cl[cp] != '\t') editor.cellsTab(cl, cp, 0, tw).w else 1;
        // Every card shows its caret; only the one with the keys blinks solid.
        placeCaret(d, now, tx + f(here.col) * cw - 1, top_h + f(here.row) * lh + 2, true, spot, !d.closing, key);
        // A newly shown file's caret fades in with its text.
        if (d.caret_fade and key) {
            d.caret_fade = false;
            fadeIn(d.caret, d.load.dur);
        }
    }

    // The quick open list, rising out of the prompt line.
    drawPanel(d, ctx, th, dark, win_key, card, now);

    // The status strip along the card's bottom, in the header's small folder
    // ink, dimmer in a card that isn't key. It fades out under the prompt band
    // as it rises and back as it sinks, and away with Zen. A change in what
    // it says crossfades from the old line.
    const stat_a = zen_k * (1 - d.pbar.at(now));
    if (stat_a > 0.01) {
        statusLine(d, card.w - 2 * pad_x, now);
        const sy = @round(card.y + card.h - strip_h / 2 + path_off);
        const sr = card.x + card.w - pad_x;
        const sa = stat_a * (0.62 + 0.38 * ka);
        const xf = std.math.clamp((now - d.stat_t0) / fade_time, 0, 1);
        if (d.stat_old) |l| {
            if (xf < 1) {
                paintLine(ctx, l, th.muted, sa * (1 - xf), @round(sr - d.stat_old_w), sy);
            } else {
                objc.CFRelease(l);
                d.stat_old = null;
            }
        }
        d.stat_x = @round(sr - d.stat_w);
        paintLine(ctx, d.stat, th.muted, sa * xf, d.stat_x, sy);
    } else d.stat_x = -1;

    drawPrompt(d, ctx, th, &k, card, ka, key, finding, now);

    drawHint(d, ctx, th, &k, card, now);

    drawHeader(d, ctx, th, &k, dark, ka, card, zt, now);
    // Ends the card clip that drawPane set at its top (or around the header).
    objc.CGContextRestoreGState(ctx);
    drawRing(d, ctx, th, dark, card, zt, now);
    d.busy = scenery(d, now);
    // The scroll bar's hold has no frames to draw: a one-shot timer redraws
    // when it's over, and the fade out takes it from there.
    if (d.bar.to == 1 and !d.busy and d.bar_armed != d.bar_t0) {
        d.bar_armed = d.bar_t0;
        // `d.caret` stands in for the card: `later` needs a per-card object to cancel by.
        objc.later(d.win.view, "holdRedraw:", d.caret, @max(d.bar_t0 + bar_hold - now, 0) + 0.02);
    }
}

// Line numbers stay beside the text and dim with Focus. The caret's line
// keeps its brighter number while a prompt is open. Wrapped rows carry a
// faint ↳ instead of a number.
fn drawGutter(d: *Doc, k: *Ink, th: *const Theme, vis: []const VRow, first: usize, here_row: usize, tx: f64) void {
    const b = &d.file.ed.buf;
    const fo = k.focus;
    k.focus = null;
    const ga = std.math.clamp(d.gw / (3.5 * cw), 0, 1);
    if (ga > 0) {
        const at_line = lineOfRow(d, here_row);
        const plain = mixRgb(th.bg, th.muted, ga);
        // Focus mutes the caret line's number along with the band.
        const lift = if (fo) |fc| 1 - fc.amt * conf.focus_dim * 0.5 else 1;
        const here_ink = mixRgb(plain, mixRgb(th.bg, mixRgb(th.bg, th.fg, 0.85), ga), lift);
        const wrap_ink = mixRgb(th.bg, th.muted, ga * 0.5);
        // The numbers' right edge sits where the gutter is headed while it
        // grows, so they don't swim as it eases; shrinking, it rides along.
        const right = tx - d.gw + @max(d.gw, gutCols(d) * cw * (1 - zen(d.win))) - 1.5 * cw;
        for (vis, first..) |v, row| {
            const y = top_h + f(row) * lh - d.vy + baseline;
            if (v.seg.start != 0) {
                _ = k.text("↳", null, th, wrap_ink, right - cw, y, 0, 1);
                continue;
            }
            var nb: [20]u8 = undefined;
            var at = nb.len;
            var n = v.line + 1;
            while (true) {
                at -= 1;
                nb[at] = '0' + @as(u8, @intCast(n % 10));
                n /= 10;
                if (n == 0) break;
            }
            const num = nb[at..];
            var ink = if (v.line == at_line) here_ink else plain;
            if (fo) |fc| {
                const ls = b.lineStart(v.line);
                const le = ls + b.line(v.line).len;
                ink = mixRgb(th.bg, ink, fc.dim(fc.new[0] <= le and fc.new[1] > ls, fc.old[0] <= le and fc.old[1] > ls));
            }
            _ = k.text(num, null, th, ink, right - f(num.len) * cw, y, 0, num.len);
        }
        k.flush();
    }
}

// The bars' hold costs no frames; drawPane arms a one-shot timer for its end.
// They show while the page moves, while the pointer is near them, and while
// a knob is held, and remember where they drew for `barDown`.
const WideSnap = struct { touched: usize, touched_end: usize, shifted: bool, shift_at: usize, delta: ?isize };

fn lineWide(l: []const u8, tw: usize) usize {
    var tabs: usize = 0;
    while (tabs < l.len and l[tabs] == '\t') tabs += 1;
    return l.len + tabs * (tw - 1);
}

fn drawBar(d: *Doc, ctx: Id, th: *const Theme, card: Rect, snap: WideSnap, now: f64) void {
    const bar_room = textH(d);
    const range = scrollRange(d);
    const bar_span = range[1] - range[0];
    // How far the text scrolls sideways: the longest line in bytes (leading
    // tabs at full width), measured again after edits.
    const textw = card.x + card.w - pad_x - (gap + padL(d));
    if (wrapping()) {
        d.wide_chg = std.math.maxInt(u64);
        d.hmax = 0;
    } else {
        const b = &d.file.ed.buf;
        if (d.wide_chg != b.changes or d.wide_id != d.file.id) {
            const tw = d.file.ed.tabWidth();
            const prev_chg = d.wide_chg;
            const same_file = d.wide_id == d.file.id and prev_chg != std.math.maxInt(u64);
            d.wide_chg = b.changes;
            d.wide_id = d.file.id;
            var full = !same_file;
            if (!full and snap.touched < b.lines()) {
                const end = @min(snap.touched_end, b.lines());
                if (!snap.shifted) {
                    if (d.wide_line >= snap.touched and d.wide_line < end) {
                        const w = lineWide(b.line(d.wide_line), tw);
                        if (w >= d.wide) d.wide = w else full = true;
                    }
                    if (!full) {
                        for (snap.touched..end) |i| {
                            const w = lineWide(b.line(i), tw);
                            if (w > d.wide) {
                                d.wide = w;
                                d.wide_line = i;
                            }
                        }
                    }
                } else if (b.changes == prev_chg + 1 and snap.delta != null) {
                    const delta = snap.delta.?;
                    const shifted_old = @as(isize, @intCast(d.wide_line)) + delta;
                    if (d.wide_line < snap.shift_at) {
                        // widest line is untouched above the edit
                    } else if (shifted_old >= @as(isize, @intCast(end))) {
                        d.wide_line = @intCast(shifted_old);
                    } else if (d.wide_line == snap.shift_at and snap.shift_at < b.lines()) {
                        const w = lineWide(b.line(snap.shift_at), tw);
                        if (w >= d.wide) d.wide = w else full = true;
                    } else full = true;
                    if (!full) {
                        for (snap.shift_at..end) |i| {
                            const w = lineWide(b.line(i), tw);
                            if (w > d.wide) {
                                d.wide = w;
                                d.wide_line = i;
                            }
                        }
                    }
                } else full = true;
            } else if (!full and snap.touched >= b.lines()) {
                full = true;
            }
            if (full) {
                var wide: usize = 0;
                var wide_line: usize = 0;
                for (0..b.lines()) |i| {
                    const w = lineWide(b.line(i), tw);
                    if (w > wide) {
                        wide = w;
                        wide_line = i;
                    }
                }
                d.wide = wide;
                d.wide_line = wide_line;
            }
        }
        d.hmax = @max(@max(0, f(d.wide + 2) * cw - textw), d.file.sx);
    }
    if (bar_span <= 0 and d.hmax <= 0) {
        if (d.bar.to != 0) d.bar.snap(0);
        d.vtrack = .{};
        d.htrack = .{};
        return;
    }
    if (d.vy != d.bar_vy or d.vx != d.bar_vx) {
        d.bar_vy = d.vy;
        d.bar_vx = d.vx;
        d.bar_t0 = now;
        d.bar.aimOver(1, bar_in, now);
    }
    // Held by the pointer, they stay; letting go restarts the hold (`hoverAt`, `mouseUp`).
    const held = d.bar_hover or d.bar_drag != .none;
    if (held) d.bar.aimOver(1, bar_in, now);
    if (!held and now >= d.bar_t0 + bar_hold) {
        d.bar.aimOver(0, bar_time, now);
    }
    const alpha = d.bar.at(now);
    const v_on = bar_span > 0;
    if (v_on) {
        const track = bar_room - 4;
        const knob = @min(@max(@round(track * bar_room / (bar_span + bar_room)), 24), track);
        const at_y = @round((track - knob) * std.math.clamp((d.vy - range[0]) / bar_span, 0, 1));
        const x = card.x + card.w - bar_w - 3;
        d.vtrack = .{ .x = x, .y = top_h + 2, .w = bar_w, .h = track };
        d.vknob = .{ .x = x, .y = top_h + 2 + at_y, .w = bar_w, .h = knob };
        const press: f64 = if (d.bar_drag == .v) 1.4 else 1;
        if (alpha > 0.01) pill(ctx, th.fg, bar_alpha * alpha * press, x, d.vknob.y, bar_w, knob, bar_w * 0.5);
    } else d.vtrack = .{};
    if (d.hmax > 0) {
        const x0 = gap + padL(d);
        const x1 = card.x + card.w - pad_x - @as(f64, if (v_on) bar_w else 0);
        const track = @max(x1 - x0, 0);
        const knob = @min(@max(@round(track * textw / (textw + d.hmax)), 24), track);
        const at_x = @round((track - knob) * std.math.clamp(d.vx / d.hmax, 0, 1));
        const y = edgeAt(d, now) - bar_w - 3;
        d.htrack = .{ .x = x0, .y = y, .w = track, .h = bar_w };
        d.hknob = .{ .x = x0 + at_x, .y = y, .w = knob, .h = bar_w };
        const press: f64 = if (d.bar_drag == .h) 1.4 else 1;
        if (alpha > 0.01) pill(ctx, th.fg, bar_alpha * alpha * press, d.hknob.x, y, knob, bar_w, bar_w * 0.5);
    } else d.htrack = .{};
}

fn drawPanel(d: *Doc, ctx: Id, th: *const Theme, dark: bool, win_key: bool, card: Rect, now: f64) void {
    // The list rides the prompt band's top edge as it slides.
    const by = edgeAt(d, now);
    const want_ph: f64 = if (listing(d) != null) f(panelRows(d)) * prow + 2 * ppad else 0;
    d.panel.aim(want_ph, now);
    const ph = d.panel.at(now);
    const closing = listing(d) == null;
    // The rows and highlight stay as they were while the panel slides shut.
    if (closing and ph <= 0.5) {
        d.pick_live = false;
        d.pick_s.snap(d.pick_s.to);
        d.phover = null;
    }
    if (ph > 0.5 and (d.palette or quick != null)) {
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
        const top = by - ph + ppad;
        d.plist_top = top;
        // Past `list_rows` picks the list scrolls, gliding to keep the pick in view.
        const scroll = d.plist.at(now);
        // The picked row's highlight springs from row to row.
        if (!closing) {
            const pick_y = f(d.pick) * prow;
            if (d.pick_live) d.pick_s.aim(pick_y, now) else d.pick_s.snap(pick_y);
            if (!d.pick_live) d.rows_t0 = now;
            d.pick_live = true;
        }
        // The row under the mouse lights faintly, fading in and out.
        if (d.phover) |h| d.phov_row = h;
        d.phov_t.aim(if (d.phover != null and !closing) 1 else 0, now);
        const hov_a = d.phov_t.at(now);
        if (hov_a > 0.01 and d.phov_row < d.npicks and d.phov_row != d.pick) pill(ctx, th.fg, (if (contrast) @as(f64, 0.1) else 0.05) * hov_a, px + 6, top + f(d.phov_row) * prow - scroll, pw - 12, prow, 6);
        // The first rows fade in a step apart; rows that changed under the
        // typing crossfade from what was there, and rows that came or went
        // fade in or out in place. A fresh open starts its rows after the
        // picks were made, so it never crosses.
        const swap = std.math.clamp((now - d.pick_t0) / xfade_time, 0, 1);
        const crossing = swap < 1 and d.rows_t0 < d.pick_t0;
        if (d.npicks > 0 or (crossing and d.prev_n > 0)) {
            const keep: f64 = if (d.npicks > 0) 1 else 1 - swap;
            selFill(ctx, th, dark, win_key, keep, px + 6, top + d.pick_s.step(now) - scroll, pw - 12, prow, 6);
        } else d.pick_s.snap(d.pick_s.to);
        const shown = if (crossing) @max(d.npicks, d.prev_n) else d.npicks;
        // Only the rows the scroll shows draw, and one more while it glides.
        const first = @min(@as(usize, @intFromFloat(@max(@floor(scroll / prow), 0))), shown);
        const upto = @min(shown, first + list_rows + 1);
        for (first..upto) |i| {
            const y = top + f(i) * prow - scroll;
            const lag = row_lag * f(@min(i - first, 5));
            const t = std.math.clamp((now - d.rows_t0 - lag) / row_fade, 0, 1);
            const a = t * t * (3 - 2 * t);
            const rise = (1 - a) * 2;
            if (i >= d.npicks) {
                panelRow(ctx, d, th, dark, d.prev_picks[i], px + 14, px + pw - 14, y, a * (1 - swap), rise);
                continue;
            }
            const p = d.picks[i];
            if (crossing and i >= d.prev_n) {
                panelRow(ctx, d, th, dark, p, px + 14, px + pw - 14, y, a * swap, rise);
            } else if (crossing and d.prev_picks[i] != p) {
                panelRow(ctx, d, th, dark, d.prev_picks[i], px + 14, px + pw - 14, y, a * (1 - swap), rise);
                panelRow(ctx, d, th, dark, p, px + 14, px + pw - 14, y, a * swap, rise);
            } else panelRow(ctx, d, th, dark, p, px + 14, px + pw - 14, y, a, rise);
        }
        // No match leaves one dim row, so the panel keeps a row's height. It
        // fades in as the rows it replaces fade out, and out as rows return.
        if (d.npicks == 0 or (crossing and d.prev_none)) {
            const lone: f64 = if (d.npicks > 0) 1 - swap else if (crossing and !d.prev_none) swap else 1;
            const t = std.math.clamp((now - d.rows_t0) / row_fade, 0, 1);
            const a = t * t * (3 - 2 * t);
            panelNone(ctx, th, px + 14, top, a * lone, (1 - a) * 2);
        }
        objc.CGContextRestoreGState(ctx);
    }
}

/// Slides the prompt band for this frame: up from the card's bottom as the
/// prompt opens, its words rising in a beat behind it, and back down as it
/// closes, its words fading out. Runs before anything reads `edgeAt`.
fn aimBand(d: *Doc, now: f64) void {
    if (d.mode != .edit) {
        if (!d.prompt_on) {
            d.prompt_t.snap(0);
            d.pbar_t0 = now;
        }
        d.prompt_on = true;
        d.pbar.aimOver(1, panel_time, now);
        if (now >= d.pbar_t0 + words_lag) d.prompt_t.aimOver(1, panel_time, now);
    } else {
        if (d.prompt_on) d.prompt_t.aimOver(0, band_out, now);
        d.prompt_on = false;
        d.pbar.aimOver(0, band_out, now);
    }
}

fn drawPrompt(d: *Doc, ctx: Id, th: *const Theme, k: *Ink, card: Rect, ka: f64, key: bool, finding: bool, now: f64) void {
    const band_y = card.y + card.h - barH();
    const ty = band_y + 6 + baseline;
    const tx = gap + padL(d);
    // The prompt line: find, replace, go to line, quick open and the palette.
    // Its band slides with `aimBand`, drawing what it last showed until it's
    // gone. The text above already uses the final `bottom()`.
    var buf: [64]u8 = undefined;
    // A window that isn't key dims its header and prompt a step.
    const ink = mixRgb(th.muted, th.fg, ka);
    const prompting = d.mode != .edit;
    const nomatch = prompting and finding and d.found[1] == 0;
    if (nomatch and !d.nomatch) {
        d.shake_t0 = now;
        haptic(.level);
    }
    d.nomatch = nomatch;
    // "No matches" shakes the words and the tally sideways, settling over `shake_time`.
    const shake_p = (now - d.shake_t0) / shake_time;
    const shake = if (shake_p >= 0 and shake_p < 1) 6 * @sin(2 * std.math.pi * 3 * shake_p) * (1 - shake_p) else 0;
    if (prompting) {
        var g: [32]u8 = undefined;
        const lines = d.file.ed.buf.lines();
        const tally: []const u8 = switch (d.mode) {
            .find, .replace => if (finding) foundTally(&buf, d.found) else "",
            .line => std.fmt.bufPrint(&buf, "of {s} line{s}", .{ grouped(&g, lines), if (lines == 1) "" else "s" }) catch "",
            .open, .command => listTally(d, &buf),
            .edit => "",
        };
        d.held_n = @min(tally.len, d.held_tally.len);
        @memcpy(d.held_tally[0..d.held_n], tally[0..d.held_n]);
        d.held_mode = d.mode;
        d.held_id = d.file.id;
        d.held_which = fieldIndex(d);
        d.held.clearRetainingCapacity();
        d.held.appendSlice(gpa, d.prompt.items) catch {};
        d.held_with.clearRetainingCapacity();
        d.held_with.appendSlice(gpa, d.with.items) catch {};
    }
    const slide = d.pbar.at(now);
    if (!prompting and slide <= 0.002) {
        d.pband_shown = false;
        return;
    }
    const drop = (1 - slide) * barH();
    objc.CGContextSaveGState(ctx);
    defer objc.CGContextRestoreGState(ctx);
    objc.CGContextTranslateCTM(ctx, 0, drop);
    fill(ctx, th.bg, card.x, band_y, card.w, barH());
    fill(ctx, th.rule, card.x, band_y, card.w, hair());
    // The words rise into place as the prompt opens, and fade as it closes.
    const words = d.prompt_t.at(now);
    if (words < 1) {
        objc.CGContextSetAlpha(ctx, words);
        if (prompting) objc.CGContextTranslateCTM(ctx, 0, (1 - words) * 6);
    }
    const mode = d.held_mode;
    const which = d.held_which;
    const findish = mode == .find or mode == .replace;
    var right = card.x + card.w - pad_x;
    // Find's pills sit at the right end: match case, then whole word.
    if (findish) {
        var moved = false;
        var px = right;
        for ([_]u1{ 1, 0 }) |t| {
            const on = if (t == 0) find_opts.case_mode == .sensitive else find_opts.whole_word;
            d.tog_t[t].aim(if (on) 1 else 0, now);
            const lit = std.math.clamp(d.tog_t[t].at(now), 0, 1);
            const w = 2 * cw + 10;
            px -= w;
            const h = lh - 2;
            const y = band_y + (barH() - h) / 2;
            pill(ctx, th.caret, (if (contrast) @as(f64, 0.3) else 0.18) * lit, px, y, w, h, 5);
            ring(ctx, th.muted, (if (contrast) @as(f64, 0.7) else 0.4) * (1 - lit), px, y, w, h, 5);
            _ = k.text(if (t == 0) "Aa" else "\\b", null, th, mixRgb(th.muted, th.caret, lit), px + 5, ty, 0, 2);
            if (prompting and (d.tog_x[t][0] != px or d.tog_x[t][1] != w)) {
                d.tog_x[t] = .{ px, w };
                moved = true;
            }
            px -= 4;
        }
        right = px - 2 * cw;
        if (moved) msg(void, d.win.window, "invalidateCursorRectsForView:", .{d.win.view});
    } else if (prompting) d.tog_x = @splat(.{ 0, 0 });
    // The tally, tinted when nothing matches. For a moment after find wraps,
    // "wrapped" crossfades in over it.
    const tally = d.held_tally[0..d.held_n];
    const tally_cols = codepoints(tally);
    const wa = if (findish) wrapAlpha(d, now) else 0;
    const tally_ink = if (d.nomatch) mixRgb(th.muted, th.caret, 0.8) else th.muted;
    if (wa < 1) _ = k.text(tally, null, th, mixRgb(th.bg, tally_ink, 1 - wa), right - f(tally_cols) * cw + shake, ty, 0, 64);
    if (wa > 0) _ = k.text("wrapped", null, th, mixRgb(th.bg, th.caret, wa), right - 7 * cw, ty, 0, 8);
    const kept_cols = if (wa > 0) @max(tally_cols, 7) else tally_cols;
    if (kept_cols > 0) right -= f(kept_cols + 2) * cw;
    // Replace says what its keys do, while there's room for them.
    if (mode == .replace) {
        const hl = rowLine("⇥ switch    ↩ replace    ⌥↩ all", panel_small, 1e5, false);
        if (right - hl.w - tx > 48 * cw) {
            right -= hl.w;
            paintLine(ctx, hl.line, th.muted, if (contrast) 0.9 else 0.6, right, ty);
            right -= 2 * cw;
        }
    }
    const label = switch (mode) {
        .find, .replace => "find",
        .line => "line",
        .command => "run",
        else => "open",
    };
    // In replace only the label of the field taking typing is lit.
    _ = k.text(label, null, th, if (mode == .replace and which == 1) th.muted else th.caret, tx + shake, ty, 0, 8);
    const fx0 = tx + f(codepoints(label) + 1) * cw;
    const room: usize = @intFromFloat(@max(@floor((right - fx0) / cw), 1));
    var cols = [2]usize{ room, 0 };
    var fx = [2]f64{ fx0, 0 };
    if (mode == .replace) {
        // Each field gets what it needs while both fit, else they share the room.
        const avail = room -| 7;
        const need0 = editor.colOf(d.held.items, 0, 0, d.held.items.len) + 1;
        const need1 = editor.colOf(d.held_with.items, 0, 0, d.held_with.items.len) + 1;
        cols[0] = @min(if (need0 + need1 <= avail or need0 <= avail / 2) need0 else if (need1 <= avail / 2) avail - need1 else avail / 2, avail);
        cols[1] = avail - cols[0];
        fx[1] = fx0 + f(cols[0] + 7) * cw;
    }
    // A field scrolls sideways to keep its caret in view.
    if (prompting) {
        for ([_]u1{ 0, 1 }) |i| {
            if (i == 1 and mode != .replace) break;
            const t = fieldAt(d, i).items;
            const c = editor.colOf(t, 0, 0, d.pcur[i]);
            const n = @max(cols[i], 1);
            var s = d.pscroll[i];
            if (c < s) s = c;
            if (c + 1 > s + n) s = c + 1 - n;
            d.pscroll[i] = @min(s, (editor.colOf(t, 0, 0, t.len) + 1) -| n);
            d.pfx[i] = fx[i];
        }
    }
    // The field's selection, a prefill's included, fades out over
    // `fade_time` once typing or a click ends it, where it last was.
    var sel_on = false;
    if (prompting) {
        const i = fieldIndex(d);
        const r = fieldSel(d);
        const t = fieldAt(d, i).items;
        const s = d.pscroll[i];
        const c0 = @max(editor.colOf(t, 0, 0, r[0]), s);
        const c1 = @min(editor.colOf(t, 0, 0, r[1]), s + cols[i]);
        if (r[0] != r[1] and c1 > c0) {
            d.pband_x = fx[i] + f(c0 - s) * cw;
            d.pband_w = f(c1 - c0) * cw;
            sel_on = true;
        }
    }
    if (sel_on) {
        d.pband_shown = true;
    } else if (d.pband_shown) {
        d.pband_shown = false;
        d.pband_t0 = now;
    }
    const band_a = if (d.pband_shown) 1 else 1 - std.math.clamp((now - d.pband_t0) / fade_time, 0, 1);
    if (band_a > 0 and d.pband_w > 0) {
        k.flush();
        fillA(ctx, th.sel, band_a, d.pband_x + shake, band_y + 6, d.pband_w, lh);
    }
    _ = k.text(d.held.items, null, th, ink, fx[0] + shake, ty, d.pscroll[0], cols[0]);
    if (mode == .replace) {
        _ = k.text("with", null, th, if (which == 1) th.caret else th.muted, fx0 + f(cols[0] + 2) * cw + shake, ty, 0, 8);
        _ = k.text(d.held_with.items, null, th, ink, fx[1] + shake, ty, d.pscroll[1], cols[1]);
    }
    k.flush();
    if (prompting) {
        const i = fieldIndex(d);
        const t = fieldAt(d, i).items;
        const c = editor.colOf(t, 0, 0, d.pcur[i]);
        placeCaret(d, now, fx[i] + f(c -| d.pscroll[i]) * cw, band_y + 8 + drop, false, .{ 1 + @as(usize, @intFromEnum(d.mode)) * 2 + i, c, d.pscroll[i] }, key, key);
    }
}

/// Quick open's and the palette's tally: "3 of 120 matches" while typing
/// narrows the list, else "3 of 4,512 files" or commands.
fn listTally(d: *const Doc, buf: []u8) []const u8 {
    if (d.npicks == 0) return "no matches";
    const all = (listing(d) orelse return "").len;
    var g: [32]u8 = undefined;
    const what = if (d.pmatches < all) "matches" else if (d.mode == .command) "commands" else "files";
    return std.fmt.bufPrint(buf, "{d} of {s} {s}", .{ d.pick + 1, grouped(&g, d.pmatches), what }) catch "";
}

/// How much of find's "wrapped" cue shows: in over `fade_time`, out over
/// the last quarter second of `wrap_time`.
fn wrapAlpha(d: *const Doc, now: f64) f64 {
    const t = now - d.wrap_t0;
    if (t < 0 or t >= wrap_time) return 0;
    return @min(@min(t / fade_time, 1), @min((wrap_time - t) / 0.25, 1));
}

/// While find is open, a thin tick for each row with a match along the
/// card's right edge, where the scroll bar runs, and the current match's in
/// the accent. Found again when the search, its rules, the text or the
/// rows change; `a` fades them with the band.
fn drawTicks(d: *Doc, ctx: Id, th: *const Theme, card: Rect, q: []const u8, cur: ?[2]usize, a: f64) void {
    if (q.len == 0 or a < 0.01) return;
    const rows = totalRows(d);
    var h = std.hash.Fnv1a_64.init();
    h.update(q);
    h.update(&.{ @as(u8, @intFromEnum(find_opts.case_mode)), @as(u8, @intFromBool(find_opts.whole_word)) });
    h.update(std.mem.asBytes(&d.file.ed.buf.changes));
    h.update(std.mem.asBytes(&rows));
    h.update(std.mem.asBytes(&d.file.id));
    const key = h.final();
    if (key != d.ticks_key) {
        d.ticks_key = key;
        d.ticks.clearRetainingCapacity();
        const t = d.file.ed.text();
        var from: usize = 0;
        while (d.ticks.items.len < max_ticks) {
            const p = editor.nextMatch(t, q, from, t.len, find_opts) orelse break;
            const r: u32 = @intCast(rowColOf(d, p).row);
            const n = d.ticks.items.len;
            if (n == 0 or d.ticks.items[n - 1] != r) d.ticks.append(gpa, r) catch break;
            from = p + q.len;
        }
    }
    if (d.ticks.items.len == 0) return;
    const y0 = top_h + 2;
    const span = textH(d) - 4;
    const x = card.x + card.w - bar_w - 3;
    const all = f(@max(rows, 1));
    const ta: f64 = if (contrast) 1 else 0.8;
    for (d.ticks.items) |r| fillA(ctx, th.match, ta * a, x, snapPx(y0 + span * f(r) / all), bar_w, 2);
    if (cur) |c| fillA(ctx, th.caret, a, x - 1, snapPx(y0 + span * f(rowColOf(d, c[0]).row) / all) - 0.5, bar_w + 2, 3);
}

fn drawHint(d: *Doc, ctx: Id, th: *const Theme, k: *Ink, card: Rect, now: f64) void {
    const by = bottom(d);
    // An empty window says what to do: its hint fades in after a pause, so
    // a restored session never flashes it, and out on the first key.
    const blank = isBlank(d) and d.mode == .edit and !d.closing;
    if (blank) {
        if (d.blank_t0 < 0) {
            d.blank_t0 = now;
            msg(void, d.win.view, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("holdRedraw:"), @as(Id, null), @as(f64, hint_delay) });
        }
        if (now >= d.blank_t0 + hint_delay) {
            d.hint.aimOver(1, hint_in, now);
        }
    } else {
        d.blank_t0 = -1;
        d.hint.aimOver(0, fade_time, now);
    }
    const hint_a = d.hint.at(now);
    d.hint_n = 0;
    if (hint_a <= 0.01) return;
    // The commands, with their keys as the menu bar has them, in rows that
    // wrap to the card's width; under them a word about dropping files, then
    // recent files and folders. Each command and recent one is a button.
    const commands = [_]struct { keys: []const u8, name: []const u8, act: HintAct }{
        .{ .keys = comptime menuKeys("quickOpen:"), .name = "Quick Open", .act = .quick },
        .{ .keys = comptime menuKeys("openDocument:"), .name = "Open", .act = .open },
        .{ .keys = comptime menuKeys("commandPalette:"), .name = "Commands", .act = .command },
    };
    const drop_line = "or drop files and folders here";
    const cols: usize = @intFromFloat(@max(@floor((card.w - 2 * pad_x) / cw), 8));
    var widths: [commands.len]usize = undefined;
    var row_of: [commands.len]usize = undefined;
    var row_w: [commands.len]usize = @splat(0);
    var nrows: usize = 1;
    for (commands, &widths, &row_of) |c, *wd, *ro| {
        wd.* = codepoints(c.keys) + 1 + codepoints(c.name);
        const used = row_w[nrows - 1];
        if (used > 0 and used + 3 + wd.* > cols) nrows += 1;
        ro.* = nrows - 1;
        row_w[nrows - 1] += (if (row_w[nrows - 1] > 0) @as(usize, 3) else 0) + wd.*;
    }
    // Recent files and folders, the open folder left out.
    var recent: [8]struct { path: []const u8, act: HintAct } = undefined;
    var nrecent: usize = 0;
    const rf = recentFiles();
    for (0..@min(msg(usize, rf, "count", .{}), 5)) |i| {
        recent[nrecent] = .{ .path = objc.utf8(msg(Id, rf, "objectAtIndex:", .{i})), .act = .{ .recent = @intCast(i) } };
        nrecent += 1;
    }
    const rd = recentFolders();
    for (0..@min(msg(usize, rd, "count", .{}), 3)) |i| {
        const p = objc.utf8(msg(Id, rd, "objectAtIndex:", .{i}));
        if (root) |r| if (std.mem.eql(u8, p, r)) continue;
        recent[nrecent] = .{ .path = p, .act = .{ .folder = @intCast(i) } };
        nrecent += 1;
    }
    const lines = nrows + 1 + (if (nrecent > 0) nrecent + 1 else 0);
    const y0 = @round(@max((top_h + by - f(lines) * lh) / 2, top_h));
    // Where each button goes: commands centered row by row, recent ones in a
    // block centered as a whole.
    var at_col: [commands.len]usize = undefined;
    var fill_w: [commands.len]usize = @splat(0);
    for (widths, row_of, &at_col) |wd, ro, *ac| {
        ac.* = fill_w[ro] + (if (fill_w[ro] > 0) @as(usize, 3) else 0);
        fill_w[ro] = ac.* + wd;
    }
    var rec_w: usize = 0;
    var pbuf: [8][std.fs.max_path_bytes]u8 = undefined;
    var dirs: [8][]const u8 = undefined;
    for (recent[0..nrecent], 0..) |e, i| {
        const dir = std.fs.path.dirname(e.path) orelse "";
        dirs[i] = tilde(&pbuf[i], dir);
        rec_w = @max(rec_w, @min(codepoints(std.fs.path.basename(e.path)) + 2 + codepoints(dirs[i]), cols));
    }
    const rec_x = @round(card.x + (card.w - f(rec_w) * cw) / 2);
    for (commands, widths, row_of, at_col, 0..) |c, wd, ro, ac, i| {
        const x = @round(card.x + (card.w - f(row_w[ro]) * cw) / 2) + f(ac) * cw;
        d.hints[i] = .{ .rect = .{ .x = x - 8, .y = y0 + f(ro) * lh, .w = f(wd) * cw + 16, .h = lh }, .act = c.act };
    }
    d.hint_n = commands.len;
    const rec_y = y0 + f(nrows + 2) * lh;
    for (recent[0..nrecent], 0..) |e, i| {
        if (d.hint_n >= max_hints) break;
        d.hints[d.hint_n] = .{ .rect = .{ .x = rec_x - 8, .y = rec_y + f(i) * lh, .w = f(rec_w) * cw + 16, .h = lh }, .act = e.act };
        d.hint_n += 1;
    }
    if (d.hint_hot) |h| d.hint_lit = h;
    d.hint_hot_t.aim(if (d.hint_hot != null) 1 else 0, now);
    const hot_a = d.hint_hot_t.at(now);

    objc.CGContextSaveGState(ctx);
    objc.CGContextSetAlpha(ctx, hint_a);
    if (hot_a > 0.01 and d.hint_lit < d.hint_n) {
        const hr = d.hints[d.hint_lit].rect;
        pill(ctx, th.fg, (if (contrast) @as(f64, 0.14) else 0.07) * hot_a, hr.x, hr.y + 2, hr.w, hr.h - 4, (hr.h - 4) / 2);
    }
    const dim: f64 = if (contrast) 1 else hint_alpha;
    for (0..d.hint_n) |i| {
        const hr = d.hints[i].rect;
        const lit = if (i == d.hint_lit) hot_a else 0;
        const ink = mixRgb(mixRgb(th.bg, th.muted, dim), th.fg, lit);
        const base_y = hr.y + baseline;
        if (i < commands.len) {
            const c = commands[i];
            const kw = k.text(c.keys, null, th, ink, hr.x + 8, base_y, 0, cols);
            _ = k.text(c.name, null, th, ink, hr.x + 8 + f(kw + 1) * cw, base_y, 0, cols);
        } else {
            const e = recent[i - commands.len];
            const nm = std.fs.path.basename(e.path);
            const nw = k.text(nm, null, th, ink, hr.x + 8, base_y, 0, rec_w);
            if (nw + 2 < rec_w) _ = k.text(dirs[i - commands.len], null, th, mixRgb(th.bg, ink, 0.7), hr.x + 8 + f(nw + 2) * cw, base_y, 0, rec_w - nw - 2);
        }
    }
    const dn = comptime codepoints(drop_line);
    _ = k.text(drop_line, null, th, mixRgb(th.bg, th.muted, dim * 0.8), @round(card.x + (card.w - f(@min(dn, cols)) * cw) / 2), y0 + f(nrows) * lh + baseline, 0, cols);
    k.flush();
    objc.CGContextRestoreGState(ctx);
}

/// What a button on the empty card does: a command, or open a recent file
/// or folder by its place in its list.
const HintAct = union(enum) { quick, open, command, recent: u8, folder: u8 };
const Hint = struct { rect: Rect, act: HintAct };
const max_hints = 12;

/// The empty card's button under `p`, in its pane.
fn hintAt(d: *const Doc, p: Point) ?usize {
    for (d.hints[0..d.hint_n], 0..) |h, i| {
        if (p.x >= h.rect.x and p.x < h.rect.x + h.rect.w and p.y >= h.rect.y and p.y < h.rect.y + h.rect.h) return i;
    }
    return null;
}

/// Runs the empty card's button `i`.
fn runHint(d: *Doc, i: usize) void {
    switch (d.hints[i].act) {
        .quick => startPrompt(d, .open),
        .command => startPrompt(d, .command),
        .open => openPanel(),
        .recent => |j| {
            const list = recentFiles();
            if (j < msg(usize, list, "count", .{})) open(objc.utf8(msg(Id, list, "objectAtIndex:", .{@as(usize, j)})), d);
        },
        .folder => |j| {
            const list = recentFolders();
            if (j < msg(usize, list, "count", .{})) open(objc.utf8(msg(Id, list, "objectAtIndex:", .{@as(usize, j)})), d);
        },
    }
    if (ax.alive(d)) refresh(d);
}

/// The key and modifier symbols of the menu bar's command `sel`, like ⌘P.
fn menuKeys(comptime sel: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);
    return comptime keysIn(menu_bar, sel) orelse "";
}

fn keysIn(comptime entries: anytype, comptime sel: []const u8) ?[]const u8 {
    inline for (entries) |e| {
        const T = @TypeOf(e);
        if (@hasField(T, "items")) {
            if (comptime keysIn(e.items, sel)) |k| return k;
        } else if (@hasField(T, "sel") and @hasField(T, "key")) {
            if (comptime std.mem.eql(u8, e.sel, sel)) return comptime keyText(e.key, pluck(usize, e, "mods", 0));
        }
    }
    return null;
}

fn keyText(comptime key: []const u8, comptime mods: usize) []const u8 {
    comptime var out: []const u8 = "";
    if (mods & objc.ctrl_key != 0) out = out ++ "⌃";
    if (mods & objc.opt_key != 0) out = out ++ "⌥";
    if (mods & objc.shift_key != 0) out = out ++ "⇧";
    if (mods & objc.cmd_key != 0) out = out ++ "⌘";
    inline for (key) |ch| out = out ++ [1]u8{std.ascii.toUpper(ch)};
    return out;
}

/// The header, over text scrolled under it. Zen blends it into a plain margin.
fn drawHeader(d: *Doc, ctx: Id, th: *const Theme, k: *Ink, dark: bool, ka: f64, card: Rect, zt: f64, now: f64) void {
    fill(ctx, th.bg, card.x, card.y, card.w, top_h - gap);
    if (zt < 0.999) {
        if (zt > 0.001) {
            objc.CGContextSetAlpha(ctx, 1 - zt);
            objc.CGContextBeginTransparencyLayer(ctx, null);
        }
        fill(ctx, th.header, card.x, card.y, card.w, head_h);
        fill(ctx, th.rule, card.x, card.y + head_h, card.w, hair());
        fill(ctx, th.bg, card.x, card.y + head_h + hair(), card.w, top_h - gap - head_h - hair());
        const right = card.x + card.w - 10;
        objc.CGContextClipToRect(ctx, .{ .x = card.x, .y = card.y, .w = @max(right - card.x, 0), .h = head_h });
        drawTabs(d, ctx, th, k, dark, ka, tabsX(card.x + d.org.x, d.org.y < 1) - d.org.x, right, now);
        if (zt > 0.001) objc.CGContextEndTransparencyLayer(ctx);
    }
}

fn drawRing(d: *Doc, ctx: Id, th: *const Theme, dark: bool, card: Rect, zt: f64, now: f64) void {
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
        // A tab dropped into the card pulses its ring once, a little out from the card.
        const pt = (now - d.ring_t0) / ring_pulse;
        if (pt >= 0 and pt < 1) {
            const e = @sin(std.math.pi * pt);
            ring(ctx, th.caret, 0.7 * e * calm, card.x - 2 * e, card.y - 2 * e, card.w + 4 * e, card.h + 4 * e, card_radius + 2 * e);
        }
    }
}

// ---- header buttons and tabs ----

fn headY() f64 {
    return gap + head_h / 2;
}

/// Zen has no header row.
fn offHeadRow(p: Point, slack: f64) bool {
    return conf.zen or @abs(p.y - headY()) > slack;
}

fn toolRect(which: Icon) Rect {
    const x = switch (which) {
        .sidebar => toggle_x,
        .plus => side_w - gap - 20,
        else => unreachable,
    };
    return .{ .x = x - 14, .y = headY() - 14, .w = 28, .h = 28 };
}

/// The sidebar button by the traffic lights, or the + at the sidebar's
/// top right, under `p` in the view: anywhere on its capsule.
fn toolAt(w: *const Win, p: Point) ?Icon {
    if (conf.zen or root == null) return null;
    inline for (.{ Icon.sidebar, Icon.plus }) |t| {
        const r = toolRect(t);
        if (p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h and (t != .plus or sideShown(w))) return t;
    }
    return null;
}

/// Whether `p`, in the card's pane, is on the + after its tabs.
fn onTabPlus(d: *const Doc, p: Point) bool {
    return d.tabbed.to == 1 and !offHeadRow(p, 14) and @abs(p.x - d.plus_x) <= 14;
}

/// Whether `p`, in the card's pane, is on the chevron of the overflowing tabs' menu.
fn onTabChev(d: *const Doc, p: Point) bool {
    return d.tabbed.to == 1 and d.chev_x > 0 and !offHeadRow(p, 14) and @abs(p.x - d.chev_x) <= 13;
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
        const id = tabPage(d, j).id;
        if (slotOf(d, id) != null) continue;
        const pos = if (j == 0) 0 else slotOf(d, tabPage(d, j - 1).id).? + 1;
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

/// True while a tab pops, folds, fades, resizes, pulses or the highlight
/// springs, or the + after the tabs fades from a click.
fn tabsMoving(d: *const Doc, now: f64) bool {
    if (d.tabbed.moving(now) or d.tab_x.moving(now) or !d.hl[0].settled() or !d.hl[1].settled()) return true;
    if (!d.opening.settled() or d.plus_down.moving(now) or d.chev_a.moving(now) or d.chev_t.moving(now) or now < d.pulse_t0 + pulse_time) return true;
    for (d.slots.items) |s| if (s.gone or !s.grow.settled() or !s.shift.settled() or s.hov.moving(now) or s.xhov.moving(now) or !s.dot.settled() or !s.wid.settled() or !s.fit.settled()) return true;
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

/// Tab `s`'s cap when the others' is `cap`: the active tab keeps up to half
/// the row, except while a click on a × holds the widths.
fn tabCap(d: *const Doc, s: *const Slot, cap: f64, room: f64) f64 {
    if (s.gone or s.id != d.file.id or d.held_cap != null) return cap;
    return @max(cap, room / 2);
}

/// The header's left side, from `x0` to `x1`. With one tab it's the file's
/// name, unsaved dot and folder; with more, a row of tabs and a + after
/// them, which the one tab grows into. The active tab's highlight springs
/// from tab to tab, and the row scrolls to keep it in view.
fn drawTabs(d: *Doc, ctx: Id, th: *const Theme, k: *Ink, dark: bool, ka: f64, x0: f64, x1: f64, now: f64) void {
    const n = tabCount(d);
    const want: f64 = if (n > 1) 1 else 0;
    if (d.slots_seen) d.tabbed.aim(want, now) else d.tabbed.snap(want);
    syncSlots(d, now);
    const a = std.math.clamp(d.tabbed.at(now), 0, 1);
    const ts = tileSize();
    const hy = headY();
    const pad = tab_pad * a;
    for (d.slots.items) |*s| {
        if (s.name[0].full == null) {
            if (tabIndex(d, s.id)) |j| {
                const pg = tabPage(d, j);
                const nm = pg.name();
                s.name[0] = .{ .full = uiLine(nm, tab_bold, 1e5) };
                s.name[0].w = lineW(s.name[0].full);
                s.name[1] = .{ .full = uiLine(nm, side_font, 1e5) };
                s.icon = iconFor(if (pg.path != null) nm else "");
            }
        }
        const nw = @max(s.name[0].w, 0);
        if (s.sized) s.wid.aim(nw, now) else s.wid.snap(nw);
        s.sized = true;
        _ = s.wid.step(now);
        const pg: ?*Page = if (s.gone) null else if (tabIndex(d, s.id)) |j| tabPage(d, j) else null;
        if (pg) |p| s.draft = p.path == null;
        const dirty = if (pg) |p| p.edited() or p.drafting() else false;
        s.dot.aim(if (dirty) 1 else 0, now);
        _ = s.dot.step(now);
        _ = s.grow.step(now);
    }

    // The + and, while the tabs overflow, the chevron of their menu stay
    // pinned at the row's right end, and the tabs stop short of them.
    const chev = std.math.clamp(d.chev_a.at(now), 0, 1);
    const room = x1 - x0 - 28 * a - 26 * chev;
    // Squeeze the tabs to a common cap when they don't all fit, down to
    // enough for the tile and a few letters. The active tab keeps its own
    // width, up to half the row, before the others give up theirs.
    var cap: f64 = 1e9;
    if (n > 1) {
        var lo: f64 = 2 * pad + ts + tab_shut * a + 36;
        var hi: f64 = 1e4;
        for (0..24) |_| {
            const mid = (lo + hi) / 2;
            var sum: f64 = 0;
            for (d.slots.items) |*s| {
                const g = std.math.clamp(s.grow.x, 0, 1);
                sum += (@min(tabWidth(s, a), tabCap(d, s, mid, room)) + tab_space * a) * g;
            }
            if (sum <= room) lo = mid else hi = mid;
        }
        cap = lo;
    }
    // A click on a × holds the widths until the mouse leaves the row.
    if (d.held_cap) |hc| cap = hc;
    d.cap = cap;

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
        const g = @max(s.grow.x, 0);
        s.x = x;
        // A squeezed tab springs to its new width; one at its own width follows that at once.
        const full = tabWidth(s, a);
        const to = @min(full, tabCap(d, s, cap, room));
        if (!s.fitted or (to >= full and s.fit.x >= full - 0.5)) s.fit.snap(to) else s.fit.aim(to, now);
        s.fitted = true;
        s.w = s.fit.step(now) * g;
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
        if (!s.gone and s.id == d.file.id) act = .{ s.x, s.w };
    }
    const span = end + off - (x0 - pad);
    const most = @max(span - room, 0);
    d.tab_over = most;
    d.tabs_l = x0 - pad;
    d.tabs_r = x0 - pad + room;
    // Tabs that run past the row even squeezed bring in the chevron.
    d.chev_a.aim(if (a > 0.5 and span > x1 - x0 - 28 * a + 0.5) 1 else 0, now);
    // A wheel scroll holds while its tab stays on show, and a × click's held
    // widths hold the row still; otherwise it keeps the active tab in view.
    if (d.tab_user != null and d.tab_user_id != d.file.id) d.tab_user = null;
    if (d.tab_user) |u| {
        const c = std.math.clamp(u, 0, most);
        if (c != u) {
            d.tab_user = c;
            d.tab_x.aim(c, now);
        }
    } else if (d.held_cap != null) {
        d.tab_x.aim(std.math.clamp(d.tab_x.to, 0, most), now);
    } else d.tab_x.aim(std.math.clamp(act[0] + off - (x0 - pad) + act[1] / 2 - room / 2, 0, most), now);
    if (slotOf(d, d.file.id)) |i| act[0] += d.slots.items[i].shift.x;

    // The tab being dragged, or springing back into place, draws last on
    // its own backing, over the ones it slides past, and the highlight
    // stays under it. Off its row it's faint.
    const top_id = if (held_id != 0) held_id else if (slotOf(d, d.file.id)) |i| (if (d.slots.items[i].shift.settled()) 0 else d.file.id) else 0;

    // The active tab's highlight, with one tab sitting on it unseen.
    for (&d.hl, act) |*h, v| if (a < 0.01 or top_id == d.file.id) h.snap(v) else h.aim(v, now);
    const hx = d.hl[0].step(now);
    const hw = d.hl[1].step(now);
    // The row stops at its ends, short of the + and chevron: tabs scrolled
    // past them are cut there.
    objc.CGContextSaveGState(ctx);
    objc.CGContextClipToRect(ctx, .{ .x = x0 - pad, .y = 0, .w = @max(room, 0), .h = gap + head_h });
    if (a > 0.01) {
        tabFill(ctx, th, ka, a, hx, hy - 11, hw);
    }

    for (0..2) |pass| {
        for (d.slots.items) |*s| {
            if ((s.id == top_id) != (pass == 1)) continue;
            const back = if (d.win.fly) |fl| fl.card == d and fl.id == s.id else false;
            drawTab(d, s, ctx, th, dark, ka, a, tabCap(d, s, cap, room), x0, x0 - pad + room, now, back or (dragged != null and dragged.?.out and s.id == dragged.?.id), pass == 1);
        }
    }
    // The ends have tabs past them while the row is scrolled.
    tabFade(ctx, th, x0 - pad, 1, off / tab_fade * a);
    tabFade(ctx, th, x0 - pad + room, -1, (span - room - off) / tab_fade * a);
    objc.CGContextRestoreGState(ctx);

    // With one tab, the folder after the name; with more, the + after the
    // tabs. One goes before the other comes, so they never overlap.
    const folder_a = std.math.clamp(1 - 2 * a, 0, 1);
    const plus_a = std.math.clamp(2 * a - 1, 0, 1);
    // The + and chevron sit after the last tab, or at the row's end when
    // the tabs run past it. Badges go after them when there are tabs.
    const pe = @min(end, x0 - pad + room);
    var nx = pe + 8 + (28 + 26 * chev) * plus_a;
    // A file this user can't write has a lock after it, and one that isn't
    // on disk yet says New until it's saved.
    if (d.file.locked) {
        drawIcon(icon(.lock, dark, th), nx, hy - 6, 12);
        nx += 20;
    }
    if (d.file.new_file) {
        if (new_badge == null) new_badge = uiLine("New", path_font, 100);
        const bw = lineW(new_badge) + 12;
        const bh = 16.0;
        ring(ctx, th.muted, 0.6, nx, hy - bh / 2, bw, bh, bh / 2);
        paintLine(ctx, new_badge, th.muted, 1, nx + 6, @round(hy + path_off));
        nx += bw + 8;
    }
    if (folder_a > 0.01) {
        const head_room = @max(@floor(x1 - nx), 24);
        // Made again when `dropHead` clears it, when the room shrinks below
        // the line, or when the room changes for a line that was cut; one
        // that fit whole stays right in more room. A file at the top of the
        // open folder has none.
        if (d.head.room < 0 or (d.head.room != head_room and (d.head.cut or head_room < d.head.lw))) {
            if (d.head.line) |l| objc.CFRelease(l);
            d.head = headLine(d, head_room);
        }
        objc.CGContextSaveGState(ctx);
        objc.CGContextSetAlpha(ctx, folder_a);
        const fx = nx + 6 * (1 - folder_a);
        paintLine(ctx, d.head.line, th.muted, 1, fx, @round(hy + path_off));
        for (d.head.marks[0..d.head.n]) |m| drawIcon(icon(.crumb, dark, th), fx + m - 5, hy - 5, 10);
        if (d.head.lw > 0) nx += d.head.lw + 2 * cw;
        objc.CGContextRestoreGState(ctx);
    }
    d.plus_x = if (a > 0.5) pe + 14 else -100;
    d.chev_x = if (a > 0.5 and chev > 0.5) pe + 41 else -100;
    if (plus_a > 0.01) {
        objc.CGContextSaveGState(ctx);
        objc.CGContextSetAlpha(ctx, plus_a);
        d.plus_t.aim(if (d.plus_on) 1 else 0, now);
        const px = pe + 4 - 8 * (1 - plus_a);
        hoverPill(ctx, th, d.plus_t.at(now), d.plus_down.at(now), px + 10, hy);
        drawIcon(icon(.plus, dark, th), px, hy - 10, 20);
        if (chev > 0.01) {
            d.chev_t.aim(if (d.chev_on) 1 else 0, now);
            objc.CGContextSetAlpha(ctx, plus_a * chev);
            const vx = pe + 41 - 4 * (1 - chev);
            hoverPill(ctx, th, d.chev_t.at(now), 0, vx, hy);
            drawIcon(icon(.parents, dark, th), vx - 6, hy - 6, 12);
        }
        objc.CGContextRestoreGState(ctx);
        nx = @max(nx, pe + 36 + 26 * chev);
    }
    k.flush();
}

/// How far the tab row fades at an end that has tabs past it.
const tab_fade = 16.0;
/// The header's colour fading to clear, made on first use and again when
/// the header colour changes, and kept.
var tab_fade_grad: ?*anyopaque = null;
var tab_fade_rgb: Rgb = .{ -1, -1, -1 };

/// The header's own colour laid over the tab row's end at `edge`, `dir` 1
/// for the left end (solid at `edge`, clear `tab_fade` to its right) or -1
/// for the right, `t` of full strength.
fn tabFade(ctx: Id, th: *const Theme, edge: f64, dir: f64, t: f64) void {
    if (t < 0.01) return;
    if (tab_fade_grad == null or !std.mem.eql(f64, &tab_fade_rgb, &th.header)) {
        if (tab_fade_grad) |g| objc.CFRelease(g);
        const space = objc.CGColorSpaceCreateDeviceRGB();
        defer if (space) |s| objc.CFRelease(s);
        const c = th.header;
        const comps = [8]f64{ c[0], c[1], c[2], 1, c[0], c[1], c[2], 0 };
        tab_fade_grad = objc.CGGradientCreateWithColorComponents(space, &comps, null, 2);
        tab_fade_rgb = th.header;
    }
    const hy = headY();
    objc.CGContextSaveGState(ctx);
    objc.CGContextClipToRect(ctx, .{ .x = if (dir > 0) edge else edge - tab_fade, .y = hy - 12, .w = tab_fade, .h = 24 });
    if (t < 0.99) objc.CGContextSetAlpha(ctx, t);
    objc.CGContextDrawLinearGradient(ctx, tab_fade_grad, .{ .x = edge, .y = hy }, .{ .x = edge + dir * tab_fade, .y = hy }, 0);
    objc.CGContextRestoreGState(ctx);
}

/// The active tab's pill and ring at (`x`, `y`) and width `w`, as selFill's
/// stronger fill and ring under Increase Contrast. `ka` is the card's key
/// fade and `a` how far the header has turned into tabs.
fn tabFill(ctx: Id, th: *const Theme, ka: f64, a: f64, x: f64, y: f64, w: f64) void {
    pill(ctx, th.fg, (if (contrast) 0.16 else 0.05 + 0.03 * ka) * a, x, y, w, 22, 7);
    ring(ctx, th.fg, (if (contrast) 0.4 else 0.06 + 0.04 * ka) * a, x, y, w, 22, 7);
}

/// One tab of `d`'s header, where it lays out plus its slide; `a` is how
/// far the header has turned into tabs and `cap` the squeezed tabs' width.
/// Its name lights up, from regular at 0.62 to medium at full ink, as the
/// active tab's highlight lands on it, and its contents grow in with it.
fn drawTab(d: *Doc, s: *Slot, ctx: Id, th: *const Theme, dark: bool, ka: f64, a: f64, cap: f64, x0: f64, x1: f64, now: f64, faint: bool, lifted: bool) void {
    const hy = headY();
    const ts = tileSize();
    const pad = tab_pad * a;
    const sx = s.x + s.shift.x;
    if (s.w < 0.5 or sx > x1 or sx + s.w < x0 - pad) return;
    const on = !s.gone and s.id == d.file.id;
    const hovered = !s.gone and s.id == d.hover;
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
        tabFill(ctx, th, ka, a, sx, hy - 11, s.w);
    }
    if (hv > 0.01 and !on) pill(ctx, th.fg, @as(f64, if (contrast) 0.1 else 0.05) * hv, sx, hy - 11, s.w, 22, 7);
    if (d.win.menu_card == d and d.win.menu_tab == s.id) {
        const ma = d.win.menu_a.at(now);
        if (ma > 0.01) menuMark(ctx, th, ma, sx, hy - 11, s.w, 22, 7);
    }
    // ⌘T on a blank tab pulses it, to point at the blank tab already there.
    if (s.id == d.pulse_id) {
        const pt = (now - d.pulse_t0) / pulse_time;
        if (pt >= 0 and pt < 1) menuMark(ctx, th, @sin(std.math.pi * pt), sx, hy - 11, s.w, 22, 7);
    }
    // The icon, name, dot and × grow from 0.92 on the tab's spring.
    const sc = 0.92 + 0.08 * std.math.clamp(s.grow.x, 0, 1.2);
    if (@abs(sc - 1) > 0.001) {
        objc.CGContextTranslateCTM(ctx, sx + s.w / 2, hy);
        objc.CGContextScaleCTM(ctx, sc, sc);
        objc.CGContextTranslateCTM(ctx, -(sx + s.w / 2), -hy);
    }
    tile(s.icon, sx + pad, @round(hy - ts / 2), ts);
    const nx = sx + pad + ts + 7;
    // The name stops short of the close button.
    const shut_x = sx + s.w - pad - tab_shut * a;
    objc.CGContextSaveGState(ctx);
    const fit = shut_x - nx;
    objc.CGContextClipToRect(ctx, .{ .x = nx, .y = hy - 12, .w = @max(fit + 1, 0), .h = 24 });
    // How much the highlight covers this tab, so a tab that it only sits
    // next to stays unlit; a lone tab is the window's title.
    const cover = @min(d.hl[0].x + d.hl[1].x, sx + s.w) - @max(d.hl[0].x, sx);
    const lit = if (a < 0.5) 1 else std.math.clamp(cover / @max(s.w, d.hl[1].x, 1), 0, 1);
    // Only the name's drawing weight is cut; a closing tab keeps its raw line.
    const room_w = @floor(cap - 2 * pad - ts - 7 - tab_shut * a);
    const which: usize = if (lit >= 0.5) 0 else 1;
    const ink_a = 1 + (0.62 + 0.38 * @max(lit, hv) - 1) * ka;
    const ink = mixRgb(th.muted, th.fg, ka);
    const by = @round(hy + name_off);
    // The weight switches halfway while the ink brightens: the two weights
    // have different widths, so drawing both at once smears the name.
    objc.CGContextSetAlpha(ctx, alpha * ink_a);
    const name = if (s.gone) s.name[which].full else sideFit(&s.name[which], if (which == 0) tab_bold else side_font, room_w + 1);
    // A dim tab's regular name sits centered where its medium name would,
    // so the label holds its place as the weight changes.
    const dim_x = if (which == 1 and name != null) @max((@min(s.wid.x, fit) - lineW(name)) / 2, 0) else 0;
    paintLine(ctx, name, ink, 1, nx + dim_x, by);
    objc.CGContextRestoreGState(ctx);
    // The unsaved dot sits after the name with one tab and slides into
    // the close button's place with more; hovering trades it for the ×.
    const cx = shut_x + tab_shut * a / 2;
    const dv = std.math.clamp(s.dot.x, 0, 1.3);
    // On the active tab the × and the dot trade places as the dot comes and goes.
    const cross = a * @max(hv, if (on) 1 - @min(dv, 1) else 0);
    if (dv > 0.01 and cross < 0.5) {
        const dx = nx + s.wid.x + 9 + (cx - nx - s.wid.x - 9) * a;
        // An untitled file's draft dot is smaller and fainter: its text is safe in a draft.
        const r = @as(f64, if (s.draft) 2.5 else 3) * dv;
        const da = (1 - 2 * cross) * @min(dv, 1) * @as(f64, if (s.draft) 0.6 else 1);
        pill(ctx, if (s.draft) th.muted else th.caret, da, dx - r, hy - r, 2 * r, 2 * r, r);
    }
    if (cross > 0.01) {
        const xv = s.xhov.at(now) * a;
        if (xv > 0.01) pill(ctx, th.fg, @as(f64, if (contrast) 0.2 else 0.1) * xv, cx - 8, hy - 8, 16, 16, 5);
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

/// The tab under `p`, and whether it's over the tab's close button: the ×'s
/// 16-point square, as its hover shows. Only with two tabs or more; one is
/// the window's title. Tabs cut at the row's ends don't count there.
fn tabAt(d: *Doc, p: Point) ?TabHit {
    if (d.tabbed.to != 1 or offHeadRow(p, 12) or p.x < d.tabs_l or p.x >= d.tabs_r) return null;
    for (d.slots.items) |s| {
        if (s.gone or p.x < s.x or p.x >= s.x + s.w) continue;
        const j = tabIndex(d, s.id) orelse return null;
        const cx = s.x + s.w - tab_pad - tab_shut / 2;
        return .{ .j = j, .id = s.id, .close = @abs(p.x - cx) <= 8 and @abs(p.y - headY()) <= 8 };
    }
    return null;
}

/// With more than one card, a card's lone file name drags like a tab.
fn loneTab(d: *const Doc, p: Point) ?TabHit {
    return if (d.win.cards.pane != null) null else titleTab(d, p);
}

/// The card's lone file name under `p`, when it has one tab.
fn titleTab(d: *const Doc, p: Point) ?TabHit {
    if (d.tabbed.to != 0 or offHeadRow(p, 12)) return null;
    const s = d.slots.items[slotOf(d, d.file.id) orelse return null];
    if (p.x < s.x or p.x >= s.x + s.w) return null;
    return .{ .j = 0, .id = d.file.id, .close = false };
}

// ---- dragging tabs ----

fn tabsLeftOf(d: *const Doc, x: f64, skip: u32) usize {
    var k: usize = 0;
    for (d.slots.items) |o| if (!o.gone and o.id != skip and o.x + o.w / 2 < x) {
        k += 1;
    };
    return k;
}

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
        if (t.from) |d| {
            const s = d.slots.items[slotOf(d, t.id) orelse return endDrag(w)];
            if (s.name[0].full) |line| t.name = objc.CFRetain(line);
            t.icon = s.icon;
        } else if (t.file) |path| {
            t.name = uiLine(std.fs.path.basename(path), name_font, 1e5);
            t.icon = iconFor(std.fs.path.basename(path));
        }
        const nw = lineW(t.name);
        t.w = 2 * tab_pad + tileSize() + 7 + nw;
    }
    const prev = t.drop;
    const was: ?Zone = if (prev) |x| x.zone else null;
    t.drop = null;
    t.out = true;
    if (t.from) |d| {
        const lp = inPane(d, p);
        // It tears off 8 points past its card's tab row on every side, and
        // comes back into the row at the same line.
        const tear = 8.0;
        t.out = tabCount(d) == 1 or lp.x < -tear or lp.x >= d.size.x + tear or lp.y < -tear or lp.y >= top_h + tear;
        if (!t.out) if (tabIndex(d, t.id)) |j| {
            // It trades places with a tab once its middle passes that tab's.
            const s = d.slots.items[slotOf(d, t.id).?];
            const mid = lp.x - t.grab + s.w / 2;
            const k = tabsLeftOf(d, mid, t.id);
            if (k != j) haptic(.alignment);
            reorderTab(d, j, k);
        };
    }
    if (t.out) t.drop = dropAt(w, t, p, prev);
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

/// ⎋ during a drag: a tab goes back to its place in its row, a copy out
/// of its row or from the sidebar flies home, and letting go does nothing.
fn cancelDrag(w: *Win) void {
    var t = w.tdrag orelse return;
    w.tdrag = null;
    if (t.from) |d| if (!d.closing) {
        if (tabIndex(d, t.id)) |j| reorderTab(d, j, @min(t.start, tabCount(d) - 1));
        refresh(d);
    };
    t.drop = null;
    startFly(w, t);
    freeDrag(t);
    aimPreview(w, CACurrentMediaTime());
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

fn freeDrag(t: TabDrag) void {
    if (t.file) |p| gpa.free(p);
    if (t.name) |l| objc.CFRelease(l);
}

/// Where a tab or sidebar file dragged to `p` would land: among another
/// card's tabs, on another card's middle as a tab, or from anywhere else
/// over a card's text in a new card off its nearest edge that has room to
/// split, or on that card when none has. Null over the sidebar, the gaps,
/// its own card's tab row and middle, and its own card's text when it's
/// that card's only tab or the card can't split. The zone of `prev` holds
/// on `zone_slack` points past its edge.
fn dropAt(w: *Win, t: *const TabDrag, p: Point, prev: ?Drop) ?Drop {
    if (overSide(w, p)) return null;
    const c = paneAt(w, p) orelse return null;
    const own = if (t.from) |x| x == c else false;
    const lp = inPane(c, p);
    if (lp.y < top_h) {
        if (own) return null;
        return .{ .card = c, .zone = .tabs, .k = tabsLeftOf(c, lp.x, 0) };
    }
    const cw_ = @max(c.size.x - 2 * gap, 1);
    const ch = @max(c.size.y - 2 * gap, 1);
    const u = (lp.x - gap) / cw_;
    const v = (lp.y - gap) / ch;
    const held: ?Zone = if (prev) |x| (if (x.card == c) x.zone else null) else null;
    // The middle 40% of the card, each way, adds the tab to it.
    const mu = if (held != null and held.? == .whole) zone_slack / cw_ else 0;
    const mv = if (held != null and held.? == .whole) zone_slack / ch else 0;
    if (@abs(u - 0.5) <= 0.2 + mu and @abs(v - 0.5) <= 0.2 + mv) return if (own) null else .{ .card = c, .zone = .whole, .k = c.at + 1 };
    const edges = [4]Zone{ .left, .right, .top, .bottom };
    var near = [4]f64{ u, 1 - u, v, 1 - v };
    for (&near, edges, [4]f64{ cw_, cw_, ch, ch }) |*x, e, len| if (held != null and held.? == e) {
        x.* -= zone_slack / len;
    };
    var best: ?usize = null;
    if (!own or tabCount(c) > 1) for (near, 0..) |x, i| if (roomFor(c, i >= 2) and (best == null or x < near[best.?])) {
        best = i;
    };
    if (best) |i| return .{ .card = c, .zone = edges[i] };
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
            return .{ .x = c.org.x + x, .y = c.org.y + headY() - 11, .w = gw, .h = 22 };
        },
        .whole => .{ .x = r.x + 6, .y = r.y + 6, .w = r.w - 12, .h = r.h - 12 },
        .left => .{ .x = r.x, .y = r.y, .w = r.w / 2, .h = r.h },
        .right => .{ .x = r.x + r.w / 2, .y = r.y, .w = r.w / 2, .h = r.h },
        .top => .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h / 2 },
        .bottom => .{ .x = r.x, .y = r.y + r.h / 2, .w = r.w, .h = r.h / 2 },
    };
}

/// Where a card's tabs start in the view, past the traffic lights at the top.
fn tabsX(x: f64, top: bool) f64 {
    const lights_end: f64 = if (root != null) toggle_x + 22 else tabs_from;
    return if (top) @max(x + 14, lights_end) else x + 14;
}

/// Where the dragged copy's tab pill lands when `dr` splits off a new card:
/// the title spot of the half the card will take, in the view.
fn titleSpot(dr: Drop) Point {
    const r = dropRect(dr, 0);
    const x = tabsX(r.x, r.y < gap + 1);
    return .{ .x = x, .y = r.y + head_h / 2 - 11 };
}

fn dragHeld(w: *const Win) bool {
    return if (w.tdrag) |t| t.live and t.out else false;
}

/// Springs the drop preview to where the drag would land, opens a gap in
/// the tab row it's over (the tabs there slide aside), and fades the
/// dragged tab's copy in off its row. A preview that was out grows into
/// place from a little smaller.
fn aimPreview(w: *Win, now: f64) void {
    const t = if (w.tdrag) |*p| p else null;
    const dr: ?Drop = if (t) |x| x.drop else null;
    const gw = if (t) |x| x.w else 0;
    w.ghost_a.aim(if (dragHeld(w)) 1 else 0, now);
    if (dr) |x| {
        const r = dropRect(x, gw);
        const to = [4]f64{ r.x, r.y, r.w, r.h };
        if (w.pv_a.to == 0 and w.pv_a.at(now) < 0.05) {
            const from = [4]f64{ r.x + r.w * 0.06, r.y + r.h * 0.06, r.w * 0.88, r.h * 0.88 };
            for (&w.pv, from) |*s, v| s.snap(v);
        }
        for (&w.pv, to) |*s, v| s.aim(v, now);
        w.pv_a.aimOver(1, fade_time, now);
    } else {
        // A split drop's preview ring fades out into the new card's ring.
        w.pv_a.aimOver(0, if (w.pv_cross) 0.15 else fade_time, now);
        w.pv_cross = false;
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

fn landing(dr: Drop) ?*Doc {
    return if (splitZone(dr.zone)) splitOff(dr.card, dr.zone == .top or dr.zone == .bottom, dr.zone == .left or dr.zone == .top, true) else dr.card;
}

/// Moves card `from`'s tab `j` to where `dr` says, taking typing there.
/// A card left with no tabs folds away.
fn moveTab(from: *Doc, j: usize, dr: Drop) void {
    const last = tabCount(from) == 1;
    if (last and dr.card == from) return;
    const to = landing(dr) orelse return;
    const pg = takeTab(from, j) orelse return;
    putTab(to, pg, dr.k);
    if (last) foldCard(from);
    focus(to);
    to.ring_t0 = CACurrentMediaTime();
}

/// Shows file `path` in window `w` where `dr` says: as a new tab, or in a
/// new card split off an edge. A file a card there already holds moves
/// there instead, and one open in another window comes forward in it.
fn placeFile(w: *Win, path: [:0]const u8, dr: Drop) void {
    if (holder(path)) |h| {
        if (h.d.win != w) return open(path, null);
        if (h.d == dr.card and !splitZone(dr.zone)) {
            showTab(h.d, h.j);
            return focus(h.d);
        }
        return moveTab(h.d, h.j, dr);
    }
    var pg = loadPage(path) orelse return;
    const to = landing(dr) orelse return pg.deinit();
    putTab(to, pg, dr.k);
    noteRecent(path);
    focus(to);
    to.ring_t0 = CACurrentMediaTime();
}

/// The drop preview, the dragged tab's copy under the mouse, and a copy
/// finishing its trip after the mouse let go.
fn drawDrag(w: *Win, ctx: Id, th: *const Theme, dark: bool, now: f64) void {
    var r: [4]f64 = undefined;
    // Picked up, the copy lifts to 1.04; once it lets go it settles to 1.
    w.lift.aim(if (dragHeld(w)) 1.04 else 1, now);
    const lift = w.lift.step(now);
    for (&w.pv, &r) |*s, *v| v.* = s.step(now);
    const pa = w.pv_a.at(now);
    if (pa > 0.01) {
        const rad: f64 = if (r[3] < 30) 7 else card_radius;
        pill(ctx, th.caret, 0.12 * pa, r[0], r[1], r[2], r[3], rad);
        ring(ctx, th.caret, 0.6 * pa, r[0], r[1], r[2], r[3], rad);
    }
    if (w.fly) |*fl| {
        // Going back, it rides the tabs' spring; elsewhere it eases out.
        var p: f64 = undefined;
        var e: f64 = undefined;
        if (fl.spring) {
            e = fl.sp.step(now);
            if (fl.sp.settled()) return endFly(w);
            p = std.math.clamp(e, 0, 1);
        } else {
            p = flyDone(fl.*, now);
            if (p >= 1) return endFly(w);
            e = 1 - (1 - p) * (1 - p) * (1 - p);
        }
        // Back on its tab it just settles; into a gap or back to the
        // sidebar it fades as it arrives; on a card it fades where it is.
        const alpha = if (fl.fade) 1 - e else if (fl.card != null) 1 else std.math.clamp((1 - p) / 0.4, 0, 1);
        ghost(ctx, th, dark, fl.icon, fl.line, fl.w, fl.from.x + (fl.to.x - fl.from.x) * e, fl.from.y + (fl.to.y - fl.from.y) * e, alpha, lift);
    }
    const t = w.tdrag orelse return;
    if (!t.live) return;
    const ga = w.ghost_a.at(now);
    if (ga < 0.01) return;
    const at = ghostAt(t, t.at);
    ghost(ctx, th, dark, t.icon, t.name, t.w, at.x, at.y, ga, lift);
}

fn ghostAt(t: TabDrag, p: Point) Point {
    return .{ .x = p.x - std.math.clamp(t.grab, 10, t.w - 10), .y = p.y - 11 };
}

/// A tab's copy lifted off the page, `gw` wide with its top left at `x`, `y`,
/// grown by `lift` about its middle.
fn ghost(ctx: Id, th: *const Theme, dark: bool, img: Id, line: Id, gw: f64, x: f64, y: f64, alpha: f64, lift: f64) void {
    const ts = tileSize();
    objc.CGContextSaveGState(ctx);
    objc.CGContextSetAlpha(ctx, alpha);
    objc.CGContextTranslateCTM(ctx, x + gw / 2, y + 11);
    objc.CGContextScaleCTM(ctx, lift, lift);
    objc.CGContextTranslateCTM(ctx, -(x + gw / 2), -(y + 11));
    // A real shadow under it, so it reads as lifted off the page.
    objc.CGContextSaveGState(ctx);
    const shade = &ghost_shades[@intFromBool(dark)];
    if (shade.* == null) shade.* = objc.CGColorCreateGenericGray(0, if (dark) 0.55 else 0.22);
    objc.CGContextSetShadowWithColor(ctx, .{ .w = 0, .h = -4 }, 12, shade.*);
    pill(ctx, th.header, 1, x, y, gw, 22, 7);
    objc.CGContextRestoreGState(ctx);
    ring(ctx, th.fg, 0.3, x, y, gw, 22, 7);
    tile(img, x + tab_pad, @round(y + 11 - ts / 2), ts);
    paintLine(ctx, line, th.fg, 1, x + tab_pad + ts + 7, @round(y + 11 + name_off));
    objc.CGContextRestoreGState(ctx);
}

/// Sets the dragged copy off on its last trip as drag `t` ends: into the
/// gap among the tabs it's dropped on, back to its tab or sidebar row when
/// it lands nowhere, or fading where it's dropped on a card.
fn startFly(w: *Win, t: TabDrag) void {
    endFly(w);
    if (!t.live or !t.out) return;
    const line = t.name orelse return;
    const gw = t.w;
    const at = ghostAt(t, t.at);
    var fl: Fly = .{ .line = objc.CFRetain(line), .icon = t.icon, .w = gw, .from = at, .to = at, .t0 = CACurrentMediaTime(), .row = t.row };
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
            fl.to = .{ .x = d.org.x + s.x + s.shift.x, .y = d.org.y + headY() - 11 };
            fl.card = d;
            fl.id = t.id;
            fl.spring = true;
        } else fl.fade = true;
    } else {
        fl.to = ghostAt(t, t.down);
        fl.spring = true;
    }
    if (fl.spring) fl.sp.aim(1, fl.t0);
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
    if (fl.spring) return std.math.clamp(fl.sp.x, 0, 1);
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
/// corners nest inside it a gap in. Full screen keeps the last header height
/// and radius, and is what it returns; AppKit moves the lights up into the
/// hidden toolbar there, so the sidebar button and tabs take their room.
fn fitTitlebar(w: *Win, r: Rect) bool {
    if (msg(usize, w.window, "styleMask", .{}) & (1 << 14) != 0) {
        w.tb.ok = false;
        toggle_x = gap + 24;
        tabs_from = gap + 14;
        return true;
    }
    // The numbers change with the window's size, full screen or key state,
    // which clear `ok`, so they're measured again only then.
    if (!w.tb.ok or w.tb.w != r.w or w.tb.h != r.h) {
        const last = msg(Id, w.window, "standardWindowButton:", .{@as(usize, 2)});
        if (last == null) return false;
        const at = msg(Rect, last, "convertRect:toView:", .{ msg(Rect, last, "bounds", .{}), w.view });
        // AppKit's own radius for this window, private, so asked for with care;
        // macOS 26's radius for a window with a toolbar otherwise.
        const frame = msg(Id, w.view, "superview", .{});
        const ask = objc.sel_registerName("_getCachedWindowCornerRadius");
        const asked: f64 = if (frame != null and msg(bool, frame, "respondsToSelector:", .{ask})) msg(f64, frame, "_getCachedWindowCornerRadius", .{}) else 0;
        w.tb = .{
            .ok = true,
            .w = r.w,
            .h = r.h,
            .head = std.math.clamp(@round(2 * (at.y + at.h / 2 - gap)), 28, 44),
            .toggle = at.x + at.w + 27,
            .tabs = at.x + at.w + 22,
            .radius = std.math.clamp((if (asked >= 1) asked else 26) - gap, 6, 24),
        };
    }
    head_h = w.tb.head;
    top_h = gap + head_h + 6;
    toggle_x = w.tb.toggle;
    tabs_from = w.tb.tabs;
    card_radius = w.tb.radius;
    return false;
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

fn keyDown(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    const flags = msg(usize, ev, "modifierFlags", .{});
    const code = msg(u16, ev, "keyCode", .{});
    const mods = flags & (objc.cmd_key | objc.opt_key | objc.ctrl_key | objc.shift_key);
    // ⎋ mid-drag drops nothing: the tab or file goes home.
    if (code == 53 and d.win.tdrag != null) return cancelDrag(d.win);
    // While the sidebar has the keys, they move through its rows.
    if (sideKey(d.win, ev)) return;
    // ⌥Z for Soft Wrap: menus only see option keys after the text has typed them.
    if (flags & (objc.cmd_key | objc.opt_key | objc.ctrl_key) == objc.opt_key and code == 6) return flip(.wrap);
    // ⌃⌘Z reaches here while Late-Night greys the Zen item: it leaves Late-Night.
    if (flags & (objc.cmd_key | objc.opt_key | objc.ctrl_key) == objc.cmd_key | objc.ctrl_key and code == 6 and conf.late_night) return flip(.@"late-night");
    // ⌥↑ and ⌥↓ move lines, before the text system takes them as paragraph moves.
    if (d.mode == .edit and mods == objc.opt_key and (code == 126 or code == 125)) {
        lineEdit(d, if (code == 126) .up else .down);
        return refresh(d);
    }
    // ⌥⌘C and ⌥⌘W flip find's match case and whole word.
    if ((d.mode == .find or d.mode == .replace) and mods == objc.cmd_key | objc.opt_key and (code == 8 or code == 13)) return toggleFind(d, if (code == 8) 0 else 1);
    // ⌘Return opens quick open's pick in a new tab.
    if (d.mode == .open and mods == objc.cmd_key and (code == 36 or code == 76)) {
        openPick(d, .tab);
        return refresh(d);
    }
    // Command keys that the menu didn't take: only arrows and delete mean something.
    if (flags & objc.cmd_key != 0) {
        if (std.mem.indexOfScalar(u16, &.{ 51, 117, 115, 119, 123, 124, 125, 126 }, code) == null) return;
    }
    // Like NSTextView: the pointer hides while typing and returns when the
    // mouse moves. A key with no characters (a modifier alone) leaves it.
    const typed = objc.utf8(msg(Id, ev, "charactersIgnoringModifiers", .{})).len > 0;
    if (typed and (code < 123 or code > 126)) {
        msg(void, objc.class("NSCursor"), "setHiddenUntilMouseMoves:", .{true});
        // Typing fades Zen's peeking lights out at once.
        peekTo(d.win, false, false);
    }
    const arr = msg(Id, objc.class("NSArray"), "arrayWithObject:", .{ev});
    msg(void, self, "interpretKeyEvents:", .{arr});
}

fn insertText(self: Id, _: Sel, s: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    const ns = if (msg(bool, s, "isKindOfClass:", .{objc.class("NSAttributedString")})) msg(Id, s, "string", .{}) else s;
    const bytes = objc.utf8(ns);
    if (d.mode != .edit) {
        promptType(d, bytes, true);
    } else {
        const e = &d.file.ed;
        const len0 = e.text().len;
        const cur0 = e.cur;
        const lone = bytes.len == 1 and !e.hasSel();
        (if (conf.pairs) e.typePaired(gpa, bytes) else e.insert(gpa, bytes)) catch {};
        // A closer that typing added, or one it stepped over (with its
        // opener), flashes so the pair shows.
        if (conf.pairs and lone) {
            const t = e.text();
            if (t.len == len0 + 2 and e.cur < t.len) {
                flashStart(d);
                flashAdd(d, e.cur, e.cur + 1);
            } else if (t.len == len0 and e.cur == cur0 + 1) {
                flashStart(d);
                flashAdd(d, cur0, e.cur);
                if (editor.matchingBracketAt(t, cur0)) |m| flashAdd(d, m, m + 1);
            }
        }
        reveal(d);
    }
    refresh(d);
}

const moves = [_]struct { []const u8, editor.Motion }{
    .{ "moveLeft", .left },                     .{ "moveBackward", .left },            .{ "moveRight", .right },
    .{ "moveForward", .right },
    .{ "moveWordLeft", .word_left },            .{ "moveWordBackward", .word_left },   .{ "moveWordRight", .word_right },
    .{ "moveWordForward", .word_right },        .{ "moveToBeginningOfLine", .home },   .{ "moveToLeftEndOfLine", .home },
    .{ "moveToEndOfLine", .end },               .{ "moveToRightEndOfLine", .end },     .{ "moveToBeginningOfParagraph", .line_start },
    .{ "moveParagraphBackward", .line_start },  .{ "moveToEndOfParagraph", .line_end }, .{ "moveParagraphForward", .line_end },
    .{ "moveToBeginningOfDocument", .top },     .{ "moveToEndOfDocument", .bottom },
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
    const e = &d.file.ed;
    const by: ?isize = if (is(name, "moveUp")) -1 else if (is(name, "moveDown")) 1 else if (is(name, "pageUp")) -@as(isize, @intCast(pageLines(d))) else if (is(name, "pageDown")) @as(isize, @intCast(pageLines(d))) else null;
    if (by) |b| {
        vmove(d, b, extend);
        return true;
    }
    for (moves) |m| if (std.mem.eql(u8, m[0], name)) {
        if (wrapping()) switch (m[1]) {
            .home, .end => if (rowEdge(d, m[1] == .end, extend)) return true,
            else => {},
        };
        e.move(m[1], extend);
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
        d.file.sy += if (is(name, "scrollPageUp")) -textH(d) + lh else textH(d) - lh;
        clampScroll(d);
        return false;
    } else if (is(name, "scrollToBeginningOfDocument") or is(name, "scrollToEndOfDocument")) {
        d.file.sy = if (is(name, "scrollToBeginningOfDocument")) 0 else std.math.inf(f64);
        clampScroll(d);
        return false;
    } else if (is(name, "centerSelectionInVisibleArea")) {
        d.file.sy = std.math.inf(f64);
        center(d);
        return false;
    } else return false;
    return true;
}

fn posAt(d: *Doc, p: Point) usize {
    layout(d);
    const yy = p.y - top_h + d.vy;
    const row: usize = if (yy < 0) 0 else @min(@as(usize, @intFromFloat(yy / lh)), totalRows(d) - 1);
    // A click in the line numbers lands at the start of its row.
    const x = if (d.gw >= cw and p.x < gap + padL(d)) 0 else @max((p.x - gap - padL(d) + d.vx) / cw, 0);
    return byteAtRow(d, row, x);
}

fn local(self: Id, ev: Id) Point {
    return msg(Point, self, "convertPoint:fromView:", .{ msg(Point, ev, "locationInWindow", .{}), @as(Id, null) });
}

/// The word or line around `pos`, for double- and triple-click drags.
fn unitAt(d: *Doc, pos: usize) [2]usize {
    return if (d.drag == .word) d.file.ed.wordAt(pos) orelse .{ pos, pos } else d.file.ed.lineAt(pos);
}

/// The header and the band over the sidebar stand in for the hidden title
/// bar: they drag the window, and a double-click does what the Mac's
/// Desktop & Dock setting says, like any title bar.
fn titleStrip(w: *Win, ev: Id) void {
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
    w.sel_at = null;
    w.grab = null;
    endDrag(w);
    endFly(w);
    if (toolAt(w, p)) |t| {
        w.press = if (t == .sidebar) 1 else 2;
        w.press_t.snap(1);
        if (t == .sidebar) flip(.sidebar) else newTab(w.focus);
        return;
    }
    if (p.y >= top_h and @abs(p.x - side_w) <= edge_grab and sideShown(w)) {
        w.side_drag = true;
        w.side_lim = 0;
        if (side_stretch.x == 0) side_rest = side_w;
        side_stretch.snap(0);
        side_w = side_rest;
        return;
    }
    if (overSide(w, p)) {
        if (p.y < top_h) return titleStrip(w, ev);
        if (p.y < listTop()) {
            // The folder's name: its capsule fills while its menu is open.
            w.press = 4;
            w.press_t.snap(1);
            redrawSide(w);
            parentsMenu(w);
            letGo(w);
            return hoverNow(w);
        }
        return sideClick(w, p, msg(usize, ev, "modifierFlags", .{}));
    }
    if (gapAt(w.cards, p)) |n| {
        n.held = null;
        // A double-click on a gap evens its split.
        if (msg(isize, ev, "clickCount", .{}) == 2) {
            n.share.aim(0.5, CACurrentMediaTime());
            msg(void, w.view, "setNeedsDisplay:", .{true});
            return msg(void, w.window, "invalidateCursorRectsForView:", .{w.view});
        }
        w.grab = n;
        w.grab_hit = 0;
        w.grab_ease = 0;
        w.grab_off = (if (n.down) p.y - n.r.y else p.x - n.r.x) - 1.5 * gap - n.share.x * gapLimits(n).len;
        return;
    }
    const d = paneAt(w, p) orelse return titleStrip(w, ev);
    // A click in a card takes the keys back from the sidebar.
    if (w.side_key) {
        w.side_key = false;
        redrawSide(w);
    }
    focus(d);
    cardDown(d, inPane(d, p), ev);
}

/// A click in card `d`, at `p` in its pane: its tabs, + and chevron, the
/// quick open list, or the text.
fn cardDown(d: *Doc, p: Point, ev: Id) void {
    const by = bottom(d);
    if (p.y < top_h) {
        if (onTabPlus(d, p)) {
            d.plus_down.snap(1);
            return newTab(d);
        }
        if (onTabChev(d, p)) return tabsMenu(d);
        const clicks = msg(isize, ev, "clickCount", .{});
        const hit = tabAt(d, p) orelse loneTab(d, p) orelse {
            // A double-click on the tab row's empty room opens a new tab.
            if (clicks == 2 and d.tabbed.to == 1 and !offHeadRow(p, 12) and p.x >= d.tabs_l) return newTab(d);
            return titleStrip(d.win, ev);
        };
        if (hit.close) {
            d.held_cap = d.cap;
            return closeTab(d, hit.j);
        }
        // A double-click on an untitled tab names it.
        if (clicks == 2 and tabPage(d, hit.j).path == null) return nameDraft(d, hit.j);
        switchTab(d, hit.j);
        // Held, the tab can be dragged along its row or to another card.
        const s = d.slots.items[slotOf(d, hit.id) orelse return];
        const at: Point = .{ .x = p.x + d.org.x, .y = p.y + d.org.y };
        d.win.tdrag = .{ .from = d, .id = hit.id, .start = hit.j, .down = at, .at = at, .grab = p.x - (s.x + s.shift.x) };
        return;
    }
    // The empty card's buttons.
    if (d.hint_n > 0 and isBlank(d) and d.mode == .edit) if (hintAt(d, p)) |i| return runHint(d, i);
    if (listing(d) != null) {
        const top = d.plist_top;
        if (p.y >= top and p.y < top + f(panelRows(d)) * prow) {
            d.pick = @min(@as(usize, @intFromFloat(@max((p.y - top + d.plist.to) / prow, 0))), d.npicks -| 1);
            // ⌘-click opens the file in a new tab and ⌥-click in a split, like ⌘Return and ⌥Return.
            const flags = msg(usize, ev, "modifierFlags", .{});
            if (d.mode == .open and flags & objc.cmd_key != 0) {
                openPick(d, .tab);
            } else if (d.mode == .open and flags & objc.opt_key != 0) {
                openPick(d, .split);
            } else accept(d);
            return refresh(d);
        }
    }
    // A click on the prompt line places its caret or flips a find pill.
    if (d.mode != .edit and p.y >= by) return promptDown(d, p, ev);
    if (p.y >= by) {
        // The status strip's "Ln, Col" opens Go to Line.
        if (d.stat_x >= 0 and p.x >= d.stat_x - 4 and p.x < d.stat_x + d.stat_ln_w + 4) startPrompt(d, .line);
        return;
    }
    if (barDown(d, p)) return;
    d.win.side_down = false;
    d.mode = .edit;
    const e = &d.file.ed;
    const pos = posAt(d, p);
    const shift = msg(usize, ev, "modifierFlags", .{}) & objc.shift_key != 0;
    // A click in the line numbers takes the whole line, and dragging there takes more lines.
    const in_gutter = d.gw >= cw and p.x < gap + padL(d) - 0.5 * cw;
    d.drag = switch (msg(isize, ev, "clickCount", .{})) {
        2 => .word,
        3 => .line,
        1 => if (in_gutter) .line else .char,
        else => .char,
    };
    if (d.drag == .char) {
        e.moveTo(pos, shift);
    } else if (shift) {
        // Shift with a double or triple click (or a gutter click) extends
        // from the anchor by whole words or lines.
        const a = e.anchor;
        const u = unitAt(d, pos);
        d.drag_from = .{ a, a };
        if (u[0] < a) e.select(a, u[0]) else e.select(a, u[1]);
    } else {
        d.drag_from = unitAt(d, pos);
        e.select(d.drag_from[0], d.drag_from[1]);
    }
    refresh(d);
}

/// A click on a scroll bar while it shows: its knob follows the mouse from
/// where it was grabbed, and a click in its track glides the page there.
fn barDown(d: *Doc, p: Point) bool {
    if (d.bar.at(CACurrentMediaTime()) < 0.05 and !d.bar_hover) return false;
    const slop = 4.0;
    const v = d.vtrack;
    const h = d.htrack;
    if (v.h > 0 and p.x >= v.x - slop and p.x < v.x + v.w + slop and p.y >= v.y and p.y < v.y + v.h) {
        d.bar_drag = .v;
        const on = p.y >= d.vknob.y and p.y < d.vknob.y + d.vknob.h;
        d.bar_off = if (on) p.y - d.vknob.y else d.vknob.h / 2;
        barTo(d, p, !on);
        return true;
    }
    if (h.w > 0 and p.y >= h.y - slop and p.y < h.y + h.h + slop and p.x >= h.x and p.x < h.x + h.w) {
        d.bar_drag = .h;
        const on = p.x >= d.hknob.x and p.x < d.hknob.x + d.hknob.w;
        d.bar_off = if (on) p.x - d.hknob.x else d.hknob.w / 2;
        barTo(d, p, !on);
        return true;
    }
    return false;
}

/// Scrolls so the held knob sits under `p`, gliding there for a click in
/// the track and following at once for a drag.
fn barTo(d: *Doc, p: Point, glide: bool) void {
    const now = CACurrentMediaTime();
    if (d.bar_drag == .v) {
        const range = scrollRange(d);
        const room = d.vtrack.h - d.vknob.h;
        const fr = if (room > 0) std.math.clamp((p.y - d.bar_off - d.vtrack.y) / room, 0, 1) else 0;
        d.file.sy = range[0] + fr * (range[1] - range[0]);
        clampScroll(d);
        if (glide) d.ys.aimOver(d.file.sy, scroll_time, now) else d.ys.snap(d.file.sy);
    } else if (d.bar_drag == .h) {
        const room = d.htrack.w - d.hknob.w;
        const fr = if (room > 0) std.math.clamp((p.x - d.bar_off - d.htrack.x) / room, 0, 1) else 0;
        d.file.sx = fr * d.hmax;
        clampScroll(d);
        if (glide) d.xs.aimOver(d.file.sx, scroll_time, now) else d.xs.snap(d.file.sx);
    }
    d.bar_t0 = now;
    msg(void, d.win.view, "setNeedsDisplay:", .{true});
}

/// Double-click on an untitled tab: asks for a name the tab keeps, which
/// its text no longer changes, until it's saved.
fn nameDraft(d: *Doc, j: usize) void {
    const id = tabPage(d, j).id;
    const nm = askName("Name Draft", "The tab keeps this name until you save the draft.", tabPage(d, j).name(), "Rename") orelse return;
    if (!ax.alive(d)) return;
    const k = tabIndex(d, id) orelse return;
    const pg = tabPage(d, k);
    var n = @min(nm.len, pg.title.len);
    while (n < nm.len and n > 0 and nm[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(pg.title[0..n], nm[0..n]);
    pg.title_len = n;
    pg.hand = true;
    if (slotOf(d, id)) |i| d.slots.items[i].drop();
    if (k == d.at) named(d);
    refresh(d);
}

/// The overflowing tabs' chevron: a menu of every tab in the card, the one
/// on show checked.
fn tabsMenu(d: *Doc) void {
    const m = objc.new("NSMenu");
    defer msg(void, m, "release", .{});
    msg(void, m, "setAutoenablesItems:", .{false});
    for (0..tabCount(d)) |j| {
        const pg = tabPage(d, j);
        const it = menuItem(m, pg.name(), "pickTab:", "", 0);
        msg(void, it, "setTag:", .{@as(isize, @intCast(j))});
        if (j == d.at) msg(void, it, "setState:", .{@as(isize, 1)});
        if (pg.path) |path| msg(void, it, "setToolTip:", .{objc.str(path)});
    }
    pick_card = d;
    _ = msg(bool, m, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(Id, null), Point{ .x = d.org.x + d.chev_x - 12, .y = d.org.y + headY() + 14 }, d.win.view });
}

/// The card whose chevron menu is open.
var pick_card: ?*Doc = null;

fn pickTab(_: Id, _: Sel, item: Id) callconv(.c) void {
    const d = pick_card orelse return;
    pick_card = null;
    if (!ax.alive(d)) return;
    const j: usize = @intCast(msg(isize, item, "tag", .{}));
    if (j < tabCount(d)) switchTab(d, j);
    focus(d);
}

/// A middle-click on a tab closes it, holding the tabs' widths like a
/// click on its ×.
fn otherMouseDown(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    if (msg(isize, ev, "buttonNumber", .{}) != 2) return;
    const p = local(self, ev);
    if (overSide(w, p)) return;
    const d = paneAt(w, p) orelse return;
    const hit = tabAt(d, inPane(d, p)) orelse return;
    d.held_cap = d.cap;
    closeTab(d, hit.j);
    if (ax.alive(d)) refresh(d);
}

fn endSideDrag(w: *Win) void {
    w.side_drag = false;
    w.side_lim = 0;
    for (wins.items) |o| msg(void, o.window, "invalidateCursorRectsForView:", .{o.view});
}

/// Moves the sidebar's edge to `x` in every window, within its limits and
/// leaving room for the text. Past a limit it stretches against the
/// mouse, and dragged right in, the sidebar shuts.
fn resizeSide(w: *Win, x: f64) void {
    if (x < side_collapse) {
        const was = side_w;
        endSideDrag(w);
        side_stretch.snap(0);
        flip(.sidebar);
        // It slides away at the width it had.
        side_w = was;
        return;
    }
    const room = msg(Rect, w.view, "bounds", .{}).w - text_room;
    const lo = settings.sidebar_min;
    const hi = @max(lo, @min(settings.sidebar_max, room));
    const to = @round(std.math.clamp(x, lo, hi));
    const over: f64 = if (x < lo)
        -@min(grab_stretch, (lo - x) * grab_pull)
    else if (x > hi)
        @min(@max(0, @min(grab_stretch, room - hi)), (x - hi) * grab_pull)
    else
        0;
    const lim: i8 = if (x <= lo) -1 else if (x >= hi) 1 else 0;
    if (lim != w.side_lim) {
        w.side_lim = lim;
        if (lim != 0) haptic(.alignment);
    }
    // At a limit the edge can only go one way.
    msg(void, if (lim == 0) resizeCursor(false) else limitCursor(false, lim < 0), "set", .{});
    side_rest = to;
    side_stretch.snap(over);
    const now_w = @round(to + over);
    if (now_w == side_w) return;
    side_w = now_w;
    refreshAll();
}

/// Lights the button, tab or tab's close button under the mouse, in
/// whichever card it's over.
fn mouseMoved(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    const p = local(self, ev);
    // The corner is the header's strip up to where its tabs start, past the lights.
    // It's tracked in every mode so Zen turned on under the pointer keeps them lit;
    // only Zen holds them after the pointer leaves.
    const corner = p.x < tabs_from and p.y < top_h;
    if (w.peek_in != corner) peekTo(w, corner, true);
    hoverAt(w, p);
}

/// Lights what's under `p` in the window: its tool button, the folder's
/// name, tab or tab's close button, the empty card's buttons, and the
/// sidebar's row.
fn hoverAt(w: *Win, p: Point) void {
    const tool = toolAt(w, p);
    const on_head = tool == null and sideShown(w) and w.tdrag == null and p.x >= 8 and p.x < 24 + w.head_w and p.y >= top_h and p.y < listTop();
    const hot: u8 = if (tool) |t| (if (t == .sidebar) 1 else 2) else if (on_head) 4 else 0;
    if (hot != w.hot) {
        redrawHot(w, w.hot | hot);
        w.hot = hot;
    }
    const over = if (tool == null) paneAt(w, p) else null;
    for (docs.items) |d| if (d.win == w) {
        const lp = inPane(d, p);
        const hit = if (d == over and lp.y < top_h) tabAt(d, lp) else null;
        setHover(d, if (hit) |h| h.id else 0, if (hit) |h| h.close else false, d == over and onTabPlus(d, lp), d == over and onTabChev(d, lp));
        // Widths held by a click on a × let go once the mouse leaves the row.
        if (d.held_cap != null and (d != over or offHeadRow(lp, 14))) {
            d.held_cap = null;
            msg(void, w.view, "setNeedsDisplay:", .{true});
        }
        const hint = if (d == over and d.hint_n > 0 and w.tdrag == null) hintAt(d, lp) else null;
        if (hint != d.hint_hot) {
            d.hint_hot = hint;
            msg(void, w.view, "setNeedsDisplay:", .{true});
        }
        // The quick open or palette row under the mouse.
        var row: ?usize = null;
        if (d == over and w.tdrag == null and listing(d) != null and lp.y >= d.plist_top and lp.y < d.plist_top + f(panelRows(d)) * prow) {
            const r: usize = @intFromFloat(@max((lp.y - d.plist_top + d.plist.to) / prow, 0));
            if (r < d.npicks) row = r;
        }
        if (row != d.phover) {
            d.phover = row;
            msg(void, w.view, "setNeedsDisplay:", .{true});
        }
        // The scroll bars show while the pointer nears the card's right
        // edge, or its bottom edge for the sideways bar, and fade a hold
        // after it leaves.
        const card = cardRect(d);
        const near = d == over and w.tdrag == null and lp.y >= top_h and lp.y < bottom(d) and
            (lp.x >= card.x + card.w - 18 or (d.htrack.w > 0 and lp.y >= bottom(d) - 18));
        if (near != d.bar_hover) {
            d.bar_hover = near;
            d.bar_t0 = CACurrentMediaTime();
            msg(void, w.view, "setNeedsDisplay:", .{true});
        }
    };
    sideHover(w, p);
}

/// Runs the hover hit test again from where the mouse sits now, for when
/// rows or tabs have moved under a still mouse. Does nothing while the
/// mouse is outside the window's view.
fn hoverNow(w: *Win) void {
    if (w.tdrag != null or !msg(bool, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "isActive", .{})) return;
    const num = msg(isize, w.window, "windowNumber", .{});
    if (msg(isize, objc.class("NSWindow"), "windowNumberAtPoint:belowWindowWithWindowNumber:", .{ msg(Point, objc.class("NSEvent"), "mouseLocation", .{}), @as(isize, 0) }) != num) return;
    const at = msg(Point, w.window, "mouseLocationOutsideOfEventStream", .{});
    const p = msg(Point, w.view, "convertPoint:fromView:", .{ at, @as(Id, null) });
    const b = msg(Rect, w.view, "bounds", .{});
    if (p.x < 0 or p.y < 0 or p.x >= b.w or p.y >= b.h) return;
    hoverAt(w, p);
}

/// Points the sidebar's hover highlight at the row under `p`: a row of the
/// list or a pinned folder, not the header or the sidebar's edge, and none
/// while something's dragged. The row's full path is its tooltip.
fn sideHover(w: *Win, p: Point) void {
    var row: ?usize = null;
    var pin: ?usize = null;
    if (sideShown(w) and p.x < side_w - edge_grab and p.y >= listTop() and w.tdrag == null) {
        pin = pinnedAt(w, p.y);
        if (pin == null) row = listRow(w, p.y);
    }
    if (pin != w.hov_pin) {
        w.hov_pin = pin;
        redrawSide(w);
    }
    if (row == w.hov.row and w.hov.gen == tree_gen) return;
    w.hov.row = row;
    w.hov.gen = tree_gen;
    redrawSide(w);
    msg(void, w.window, "invalidateCursorRectsForView:", .{w.view});
}

/// Points the card's hover at tab `id` (0 for none), its × (`shut`), the +
/// or the chevron. A new tab, ×, or + under the mouse gets its tooltip.
fn setHover(d: *Doc, id: u32, shut: bool, plus: bool, chev: bool) void {
    if (id == d.hover and shut == d.hover_x and plus == d.plus_on and chev == d.chev_on) return;
    const tips = id != d.hover or shut != d.hover_x or plus != d.plus_on;
    d.hover = id;
    d.hover_x = shut;
    d.plus_on = plus;
    d.chev_on = chev;
    msg(void, d.win.view, "setNeedsDisplay:", .{true});
    if (tips) msg(void, d.win.window, "invalidateCursorRectsForView:", .{d.win.view});
}

/// The mouse left the view: everything it lit goes out.
fn mouseExited(self: Id, _: Sel, _: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    peekTo(w, false, true);
    hoverAt(w, .{ .x = -1, .y = -1 });
}

/// Zen's lights peek back while the mouse is in the window's top-left
/// corner, and fade out a hold after it leaves. Typing (no hold) needs no
/// timer: its own redraw starts the fade.
fn peekTo(w: *Win, in: bool, hold: bool) void {
    const t: f64 = if (hold and conf.zen) 0.6 else 0;
    w.peek_in = in;
    w.peek_out = CACurrentMediaTime() + t;
    if (t > 0) objc.later(w.view, "holdRedraw:", w.window, t);
}

/// View > Peek Window Controls: Zen's hidden traffic lights and title show
/// for a moment, then fade, with no trip to the corner.
const peek_hold = 2.0;
fn peekLights(d: *Doc) void {
    const w = d.win;
    w.peek_in = false;
    w.peek_out = CACurrentMediaTime() + peek_hold;
    objc.later(w.view, "holdRedraw:", w.window, peek_hold);
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// View > Language: shows the card's file in the picked language (an
/// index into `syntax.languages`, in the item's tag) until its tab closes.
fn pickLanguage(self: Id, _: Sel, item: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    const i: usize = @intCast(@max(msg(isize, item, "tag", .{}), 0));
    if (i >= syntax.languages.len) return;
    d.file.lang_i = @intCast(i);
    d.file.lang = syntax.languages[i].lang;
    clearSyntax(d);
    refresh(d);
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
    w.sel_at = null;
    w.focus.pdrag = false;
    if (w.focus.bar_drag != .none) {
        w.focus.bar_drag = .none;
        w.focus.bar_t0 = CACurrentMediaTime();
        return msg(void, w.view, "setNeedsDisplay:", .{true});
    }
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
    endSideDrag(w);
    if (side_rest != conf.sidebar_width) {
        var buf: [24]u8 = undefined;
        store(.@"sidebar-width", settings.decimal(&buf, side_rest));
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
    if (w.tdrag) |t| {
        // A sidebar file dragged out of the window goes on as a drag of the
        // file itself, for Finder and other apps.
        const p = local(self, ev);
        const b = msg(Rect, self, "bounds", .{});
        if (t.file != null and t.live and (p.x < 0 or p.y < 0 or p.x >= b.w or p.y >= b.h)) return dragOut(w, ev);
        return dragTab(w, p);
    }
    if (w.grab) |n| return dragGap(w, n, local(self, ev));
    if (w.focus.bar_drag != .none) return barTo(w.focus, inPane(w.focus, local(self, ev)), false);
    if (w.focus.pdrag) return promptDrag(w.focus, inPane(w.focus, local(self, ev)));
    if (w.side_down) return;
    dragText(w, local(self, ev));
}

/// Hands the sidebar file being dragged to a system drag of its file: Finder
/// takes it as a copy. The copy inside the window lets go.
fn dragOut(w: *Win, ev: Id) void {
    const t = w.tdrag.?;
    w.tdrag = null;
    defer freeDrag(t);
    const path = t.file.?;
    const url = msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.str(path)});
    const item = msg(Id, msg(Id, objc.class("NSDraggingItem"), "alloc", .{}), "initWithPasteboardWriter:", .{url});
    defer msg(void, item, "release", .{});
    const p = local(w.view, ev);
    const s = tileSize();
    msg(void, item, "setDraggingFrame:contents:", .{ Rect{ .x = p.x - s / 2, .y = p.y - s / 2, .w = s, .h = s }, iconFor(std.fs.path.basename(path)) });
    _ = msg(Id, w.view, "beginDraggingSessionWithItems:event:source:", .{ msg(Id, objc.class("NSArray"), "arrayWithObject:", .{item}), ev, w.view });
    aimPreview(w, CACurrentMediaTime());
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// What a file dragged out of the sidebar may do where it lands: be copied,
/// so a drop in Finder never moves it out of the folder.
fn dragOutMask(_: Id, _: Sel, _: Id, _: isize) callconv(.c) usize {
    return 1;
}

/// How often a selection drag held outside the text scrolls.
const drag_step = 1.0 / 60.0;

/// How far a selection drag held `dist` points past the text's edge
/// scrolls each step, in `unit`s: slowly near the edge, faster farther out.
fn dragSpeed(dist: f64, unit: f64) f64 {
    return unit * std.math.clamp(dist / 24, 0.2, 4);
}

/// Extends the focused card's selection to `at` in the view, scrolling
/// when it's above, below or (unwrapped) beside the text, the faster the
/// farther out, and comes back after `drag_step` to scroll again while the
/// mouse holds still out there.
fn dragText(w: *Win, at: Point) void {
    const d = w.focus;
    d.snap = true;
    const p = inPane(d, at);
    const sy = d.file.sy;
    const sx = d.file.sx;
    if (p.y < top_h) d.file.sy -= dragSpeed(top_h - p.y, lh);
    if (p.y > bottom(d)) d.file.sy += dragSpeed(p.y - bottom(d), lh);
    if (!wrapping()) {
        const left = gap + padL(d);
        const right = rightEdge(d) - pad_x;
        if (p.x < left and d.file.sx > 0) d.file.sx -= dragSpeed(left - p.x, cw);
        if (p.x > right and d.file.sx < d.hmax) d.file.sx = @min(d.hmax, d.file.sx + dragSpeed(p.x - right, cw));
    }
    clampScroll(d);
    d.ys.snap(d.file.sy);
    d.xs.snap(d.file.sx);
    const pos = posAt(d, p);
    if (d.drag == .char) {
        d.file.ed.moveTo(pos, true);
    } else {
        const u = unitAt(d, pos);
        if (u[0] < d.drag_from[0]) d.file.ed.select(d.drag_from[1], u[0]) else d.file.ed.select(d.drag_from[0], @max(u[1], d.drag_from[1]));
    }
    refresh(d);
    w.sel_at = at;
    if (d.file.sy != sy or d.file.sx != sx) objc.later(w.view, "dragScroll:", w.window, drag_step);
}

/// The selection drag's timer: scrolls on while the button is still down.
fn dragScroll(self: Id, _: Sel, _: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    const at = w.sel_at orelse return;
    if (msg(usize, objc.class("NSEvent"), "pressedMouseButtons", .{}) & 1 == 0) {
        w.sel_at = null;
        return;
    }
    dragText(w, at);
}

/// Scrolls the sidebar or the card under the mouse, focused or not.
fn scrollWheel(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const w = winOf(self) orelse return;
    const at = local(self, ev);
    if (overSide(w, at)) {
        const dy = msg(f64, ev, "scrollingDeltaY", .{});
        w.side_y -= if (msg(bool, ev, "hasPreciseScrollingDeltas", .{})) dy else dy * lh;
        sideHover(w, at);
        return redrawSide(w);
    }
    const d = paneAt(w, at) orelse return;
    var dx = msg(f64, ev, "scrollingDeltaX", .{});
    var dy = msg(f64, ev, "scrollingDeltaY", .{});
    const precise = msg(bool, ev, "hasPreciseScrollingDeltas", .{});
    if (!precise) {
        dx *= lh;
        dy *= lh;
    }
    const lp = inPane(d, at);
    // Over quick open's or the palette's list, the wheel scrolls its rows.
    if (listing(d) != null and d.npicks > list_rows and lp.y >= d.plist_top - ppad and lp.y < bottom(d)) {
        const most = f(d.npicks - list_rows) * prow;
        const to = std.math.clamp(d.plist.to - dy, 0, most);
        if (precise) d.plist.snap(to) else d.plist.aim(to, CACurrentMediaTime());
        hoverAt(w, at);
        return msg(void, w.view, "setNeedsDisplay:", .{true});
    }
    // Over a tab row that runs past its end, a sideways scroll, or a mouse
    // wheel's, scrolls the tabs.
    if (lp.y < top_h and d.tabbed.to == 1 and d.tab_over > 0 and !offHeadRow(lp, 14) and (@abs(dx) > @abs(dy) or !precise)) {
        const by = if (@abs(dx) > @abs(dy)) dx else dy;
        const to = std.math.clamp((d.tab_user orelse d.tab_x.to) - by, 0, d.tab_over);
        d.tab_user = to;
        d.tab_user_id = d.file.id;
        if (precise) d.tab_x.snap(to) else d.tab_x.aim(to, CACurrentMediaTime());
        hoverAt(w, at);
        return msg(void, w.view, "setNeedsDisplay:", .{true});
    }
    d.file.sx -= dx;
    d.file.sy -= dy;
    clampScroll(d);
    // A trackpad follows the fingers; a mouse wheel's clicks glide.
    if (precise) {
        d.ys.snap(d.file.sy);
        d.xs.snap(d.file.sx);
    } else {
        const now = CACurrentMediaTime();
        d.ys.aimOver(d.file.sy, scroll_time, now);
        d.xs.aimOver(d.file.sx, scroll_time, now);
    }
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
        msg(void, self, "addCursorRect:cursor:", .{ Rect{ .x = side_w - edge_grab, .y = top_h, .w = 2 * edge_grab, .h = r.h - top_h }, resizeCursor(false) });
    }
    // The two buttons by the traffic lights get their menu items' names;
    // `toolTip` answers nil where zen hides them. The folder's name and the
    // row under the mouse get their full paths, and so do the tab under the
    // mouse; its × and the tabs' + get their commands.
    msg(void, self, "removeAllToolTips", .{});
    if (root != null) {
        _ = msg(isize, self, "addToolTipRect:owner:userData:", .{ toolRect(.sidebar), self, @as(?*anyopaque, null) });
        _ = msg(isize, self, "addToolTipRect:owner:userData:", .{ toolRect(.plus), self, @as(?*anyopaque, null) });
    }
    if (sideShown(w)) {
        _ = msg(isize, self, "addToolTipRect:owner:userData:", .{ Rect{ .x = 8, .y = top_h, .w = side_w - 16, .h = side_h }, self, @as(?*anyopaque, null) });
        if (w.hov.row) |i| if (w.hov.gen == tree_gen) {
            const y = listTop() + f(i) * side_h - w.side_y;
            if (y >= listTop()) _ = msg(isize, self, "addToolTipRect:owner:userData:", .{ Rect{ .y = y, .w = side_w - edge_grab, .h = side_h }, self, @as(?*anyopaque, null) });
        };
    }
    if (!conf.zen) for (docs.items) |d| if (d.win == w and !d.closing and d.tabbed.to == 1) {
        const hy = d.org.y + headY();
        if (d.hover != 0) if (slotOf(d, d.hover)) |i| {
            const s = d.slots.items[i];
            const sx = d.org.x + s.x;
            const cx = sx + s.w - tab_pad - tab_shut / 2;
            _ = msg(isize, self, "addToolTipRect:owner:userData:", .{ Rect{ .x = sx, .y = hy - 11, .w = @max(cx - 8 - sx, 0), .h = 22 }, self, @as(?*anyopaque, null) });
            _ = msg(isize, self, "addToolTipRect:owner:userData:", .{ Rect{ .x = cx - 8, .y = hy - 8, .w = 16, .h = 16 }, self, @as(?*anyopaque, null) });
        };
        if (d.plus_x > 0) _ = msg(isize, self, "addToolTipRect:owner:userData:", .{ Rect{ .x = d.org.x + d.plus_x - 14, .y = hy - 14, .w = 28, .h = 28 }, self, @as(?*anyopaque, null) });
    };
    // Find's pills say what they do and their keys.
    for (docs.items) |d| {
        if (d.win != w or (d.mode != .find and d.mode != .replace)) continue;
        for (d.tog_x) |t| {
            if (t[1] > 0) _ = msg(isize, self, "addToolTipRect:owner:userData:", .{ Rect{ .x = d.org.x + t[0], .y = d.org.y + d.size.y - gap - barH(), .w = t[1], .h = barH() }, self, @as(?*anyopaque, null) });
        }
    }
}

/// The tooltip under `p`: a button's menu item title and keys (or why the
/// sidebar doesn't show), a tab's full path, or the full path of the
/// folder or the row.
fn toolTip(self: Id, _: Sel, _: Id, _: isize, p: Point, _: ?*anyopaque) callconv(.c) Id {
    const w = winOf(self) orelse return null;
    if (toolAt(w, p)) |t| {
        if (t != .sidebar) return objc.str("New Tab " ++ comptime menuKeys("newTab:"));
        return objc.str(if (conf.sidebar and !sideShown(w)) "Widen the window to show the sidebar" else sidebar_title);
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (!overSide(w, p)) if (paneAt(w, p)) |d| {
        const lp = inPane(d, p);
        if ((d.mode == .find or d.mode == .replace) and lp.y >= bottom(d)) {
            for (d.tog_x, 0..) |t, k| {
                if (t[1] > 0 and lp.x >= t[0] and lp.x < t[0] + t[1]) return objc.str(if (k == 0) "Match Case ⌥⌘C" else "Whole Word ⌥⌘W");
            }
        }
        if (lp.y >= top_h) return null;
        if (onTabPlus(d, lp)) return objc.str("New Tab " ++ comptime menuKeys("newTab:"));
        const hit = tabAt(d, lp) orelse return null;
        if (hit.close) return objc.str("Close Tab " ++ comptime menuKeys("closeTab:"));
        const pg = tabPage(d, hit.j);
        return objc.str(if (pg.path) |path| tilde(&buf, path) else pg.name());
    };
    if (!sideShown(w) or p.x >= side_w) return null;
    const r = root orelse return null;
    if (p.y < listTop()) return if (p.y >= top_h) objc.str(tilde(&buf, r)) else null;
    const i = pinnedAt(w, p.y) orelse listRow(w, p.y) orelse return null;
    var full: [std.fs.max_path_bytes]u8 = undefined;
    return objc.str(tilde(&buf, std.fmt.bufPrint(&full, "{s}/{s}", .{ r, tree.rows.items[i].rel }) catch return null));
}

/// Window key and full-screen changes invalidate the titlebar layout.
fn keyChanged(self: Id, _: Sel) callconv(.c) void {
    if (winOf(self)) |w| w.tb.ok = false;
    msg(void, self, "setNeedsDisplay:", .{true});
}

/// The system's light or dark look changed: crossfade to the new colors.
/// A window that isn't on screen yet has nothing to fade from.
fn lookChanged(self: Id, _: Sel) callconv(.c) void {
    if (winOf(self)) |w| {
        w.dark = null;
        if (msg(bool, w.window, "isVisible", .{})) fadeTheme(w);
    }
    msg(void, self, "setNeedsDisplay:", .{true});
}

fn readContrast() void {
    contrast = msg(bool, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "accessibilityDisplayShouldIncreaseContrast", .{});
}

/// The Mac's Increase Contrast setting changed: read it again and redraw.
pub fn contrastChanged(_: Id, _: Sel, _: Id) callconv(.c) void {
    readContrast();
    buildThemes();
    dropIcons();
    for (wins.items) |w| msg(void, w.view, "setNeedsDisplay:", .{true});
    for (docs.items) |d| preview.update(d, themeOf(d.win));
}

extern const NSPasteboardTypeFileURL: Id;
extern const NSPasteboardURLReadingFileURLsOnlyKey: Id;

/// Files dragged over the window from Finder copy-drop, which opens them;
/// the window lights up while they're over it.
fn draggingEntered(self: Id, _: Sel, _: Id) callconv(.c) usize {
    if (winOf(self)) |w| setDropOn(w, true);
    return 1;
}

fn draggingExited(self: Id, _: Sel, _: Id) callconv(.c) void {
    if (winOf(self)) |w| setDropOn(w, false);
}

fn setDropOn(w: *Win, on: bool) void {
    if (w.drop_on == on) return;
    w.drop_on = on;
    msg(void, w.view, "setNeedsDisplay:", .{true});
}

/// Opens the dropped files as tabs in this window's focused card, one after
/// another; a folder becomes the sidebar's folder.
fn performDrag(self: Id, _: Sel, sender: Id) callconv(.c) bool {
    const w = winOf(self) orelse return false;
    setDropOn(w, false);
    const pb = msg(Id, sender, "draggingPasteboard", .{});
    const classes = msg(Id, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    const opts = msg(Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ msg(Id, objc.class("NSNumber"), "numberWithBool:", .{true}), NSPasteboardURLReadingFileURLsOnlyKey });
    const urls = msg(Id, pb, "readObjectsForClasses:options:", .{ classes, opts });
    const n = if (urls != null) msg(usize, urls, "count", .{}) else 0;
    for (0..n) |i| {
        if (!ax.winAlive(w)) break;
        open(objc.utf8(msg(Id, msg(Id, urls, "objectAtIndex:", .{i}), "path", .{})), w.focus);
    }
    return n > 0;
}

// ---- context menus ----

/// Built on the first right-click and kept. Their items have no target, so
/// they reach the key window's view through the responder chain.
var text_menu: Id = null;
var side_menu: Id = null;
/// The side menu's items that need a file (`side_items`) or any row
/// (`row_items`), and its Show Hidden Files item, whose check changes.
var side_items: [3]Id = @splat(null);
var row_items: [5]Id = @splat(null);
var hidden_item: Id = null;
var tab_menu: Id = null;
var tab_items: [9]Id = @splat(null);
/// The menu of a card's header away from its tabs.
var card_menu: Id = null;
/// The file of the sidebar row or tab the menu was opened on and its window.
var menu_path: [std.fs.max_path_bytes:0]u8 = undefined;
var menu_len: usize = 0;
var menu_win: ?*Win = null;
/// The menu's path is a folder (or the open folder itself, for a click on
/// no row).
var menu_dir = false;

pub fn menuItem(menu: Id, title: []const u8, sel: [:0]const u8, key: []const u8, mods: usize) Id {
    const it = msg(Id, msg(Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{ objc.str(title), objc.sel_registerName(sel), objc.str(key) });
    if (key.len > 0) msg(void, it, "setKeyEquivalentModifierMask:", .{mods});
    msg(void, menu, "addItem:", .{it});
    msg(void, it, "release", .{});
    return it;
}

pub fn clipboardItems(m: Id) void {
    fillMenu(m, clipboard, null);
}

pub fn separator(m: Id) void {
    msg(void, m, "addItem:", .{msg(Id, objc.class("NSMenuItem"), "separatorItem", .{})});
}

/// An SF Symbol as a menu item's image.
fn symbol(name: [:0]const u8) Id {
    return msg(Id, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{ objc.str(name), @as(Id, null) });
}

/// `menuItem` with an SF Symbol before its title.
fn symbolItem(menu: Id, title: []const u8, sel: [:0]const u8, sym: [:0]const u8) Id {
    const it = menuItem(menu, title, sel, "", 0);
    msg(void, it, "setImage:", .{symbol(sym)});
    return it;
}

/// A click on the folder's name: a menu of the folder and the folders above
/// it, each with its icon (picking one shows it in Finder), then Reveal in
/// Finder, Open Folder…, Recent Folders and Show Hidden Files.
fn parentsMenu(w: *Win) void {
    const m = objc.new("NSMenu");
    defer msg(void, m, "release", .{});
    msg(void, m, "setAutoenablesItems:", .{false});
    const ws = msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const fm = msg(Id, objc.class("NSFileManager"), "defaultManager", .{});
    var path: []const u8 = root.?;
    var n: isize = 0;
    while (true) : (n += 1) {
        const at = objc.str(path);
        const it = menuItem(m, objc.utf8(msg(Id, fm, "displayNameAtPath:", .{at})), "sideParent:", "", 0);
        msg(void, it, "setTag:", .{n});
        const img = msg(Id, msg(Id, ws, "iconForFile:", .{at}), "copy", .{});
        msg(void, img, "setSize:", .{Point{ .x = 16, .y = 16 }});
        msg(void, it, "setImage:", .{img});
        msg(void, img, "release", .{});
        if (path.len <= 1) break;
        path = std.fs.path.dirname(path) orelse break;
    }
    separator(m);
    _ = symbolItem(m, "Reveal in Finder", "revealRoot:", "folder");
    _ = symbolItem(m, "Open Folder…", "openFolder:", "folder.badge.plus");
    const sub = msg(Id, msg(Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.str("Recent Folders")});
    defer msg(void, sub, "release", .{});
    msg(void, sub, "setAutoenablesItems:", .{false});
    const list = recentFolders();
    var shown: usize = 0;
    for (0..msg(usize, list, "count", .{})) |i| {
        const p = msg(Id, list, "objectAtIndex:", .{i});
        if (msg(bool, p, "isEqualToString:", .{objc.str(root.?)})) continue;
        const it = menuItem(sub, objc.utf8(msg(Id, fm, "displayNameAtPath:", .{p})), "openRecentFolder:", "", 0);
        msg(void, it, "setRepresentedObject:", .{p});
        msg(void, it, "setToolTip:", .{p});
        const img = msg(Id, msg(Id, ws, "iconForFile:", .{p}), "copy", .{});
        msg(void, img, "setSize:", .{Point{ .x = 16, .y = 16 }});
        msg(void, it, "setImage:", .{img});
        msg(void, img, "release", .{});
        shown += 1;
    }
    const recent = symbolItem(m, "Recent Folders", "", "clock");
    msg(void, recent, "setSubmenu:", .{sub});
    msg(void, recent, "setEnabled:", .{shown > 0});
    separator(m);
    const hid = symbolItem(m, "Show Hidden Files", "toggleHidden:", "eye");
    msg(void, hid, "setState:", .{@as(isize, @intFromBool(conf.show_hidden))});
    _ = msg(bool, m, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(Id, null), Point{ .x = 16, .y = listTop() }, w.view });
}

/// The folder name menu's Reveal in Finder.
fn revealRoot(_: Id, _: Sel, _: Id) callconv(.c) void {
    if (root) |r| revealPath(r);
}

/// The folder name menu's Open Folder….
fn openFolder(_: Id, _: Sel, _: Id) callconv(.c) void {
    openFolderPanel();
}

/// A folder from the folder name menu's Recent Folders.
fn openRecentFolder(_: Id, _: Sel, item: Id) callconv(.c) void {
    const p = objc.utf8(msg(Id, item, "representedObject", .{}));
    var z: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&z, "{s}", .{p}, 0) catch return;
    if (!files.isDir(dir)) return toastFront("That folder is gone");
    open(dir, keyDoc());
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
    redrawMenuMark(w);
    return m;
}

fn menuDidClose(_: Id, _: Sel, m: Id) callconv(.c) void {
    msg(void, m, "setDelegate:", .{@as(Id, null)});
    const w = menu_win orelse return;
    w.menu_a.aim(0, CACurrentMediaTime());
    redrawMenuMark(w);
}

fn redrawMenuMark(w: *Win) void {
    if (w.menu_card == null) redrawSide(w) else msg(void, w.view, "setNeedsDisplay:", .{true});
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
    if (!overSide(w, p)) {
        const d = paneAt(w, p) orelse return null;
        const lp = inPane(d, p);
        if (lp.y < top_h) return tabMenu(self, w, d, lp) orelse cardMenu(d);
        if (lp.y >= bottom(d)) return null;
        focus(d);
        // A right-click outside the selection moves the caret there first,
        // so the menu acts where it opened.
        if (d.mode == .edit) {
            const pos = posAt(d, lp);
            const s = d.file.ed.sel();
            if (s[0] == s[1] or pos < s[0] or pos > s[1]) {
                d.file.ed.moveTo(pos, false);
                refresh(d);
            }
        }
        if (text_menu == null) {
            const m = objc.new("NSMenu");
            _ = menuItem(m, "Undo", "undo:", "z", objc.cmd_key);
            _ = menuItem(m, "Redo", "redo:", "z", objc.cmd_key | objc.shift_key);
            separator(m);
            clipboardItems(m);
            separator(m);
            _ = menuItem(m, "Find Selection", "findText:", "f", objc.cmd_key);
            _ = menuItem(m, "Toggle Comment", "toggleComment:", "/", objc.cmd_key);
            _ = menuItem(m, "Format JSON", "formatJson:", "j", objc.cmd_key | objc.opt_key);
            separator(m);
            _ = menuItem(m, "Split Right", "splitRight:", "d", objc.cmd_key);
            _ = menuItem(m, "Split Down", "splitDown:", "d", objc.cmd_key | objc.shift_key);
            text_menu = m;
        }
        return text_menu;
    }
    if (p.y < top_h) return null;
    if (p.y < listTop()) return null;
    // Over no row, the menu is about the open folder itself.
    const at = sideRow(w, p.y);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (at) |i| std.fmt.bufPrint(&buf, "{s}/{s}", .{ root.?, tree.rows.items[i].rel }) catch return null else root.?;
    if (!setMenuPath(path)) return null;
    menu_dir = if (at) |i| tree.rows.items[i].dir else true;
    if (side_menu == null) {
        const m = objc.new("NSMenu");
        msg(void, m, "setAutoenablesItems:", .{false});
        side_items = .{
            menuItem(m, "Open in New Tab", "openInNewTab:", "", 0),
            menuItem(m, "Open in New Split", "openInNewSplit:", "", 0),
            menuItem(m, "Open in New Window", "openInNewWindow:", "", 0),
        };
        separator(m);
        _ = symbolItem(m, "New File…", "sideNewFile:", "doc.badge.plus");
        _ = symbolItem(m, "New Folder…", "sideNewFolder:", "folder.badge.plus");
        separator(m);
        row_items[0] = symbolItem(m, "Rename…", "sideRename:", "pencil");
        row_items[1] = symbolItem(m, "Duplicate", "sideDuplicate:", "plus.square.on.square");
        row_items[2] = symbolItem(m, "Move to Trash", "sideTrash:", "trash");
        separator(m);
        _ = symbolItem(m, "Reveal in Finder", "revealInFinder:", "folder");
        _ = symbolItem(m, "Copy Path", "copyPath:", "doc.on.doc");
        row_items[3] = symbolItem(m, "Copy Relative Path", "copyRelativePath:", "doc.on.clipboard");
        separator(m);
        row_items[4] = symbolItem(m, "Collapse All", "collapseAll:", "rectangle.compress.vertical");
        hidden_item = symbolItem(m, "Show Hidden Files", "toggleHidden:", "eye");
        side_menu = m;
    }
    for (side_items) |it| msg(void, it, "setEnabled:", .{at != null and !menu_dir});
    for (row_items[0..4]) |it| msg(void, it, "setEnabled:", .{at != null});
    msg(void, row_items[4], "setEnabled:", .{tree.open.items.len > 0});
    msg(void, hidden_item, "setState:", .{@as(isize, @intFromBool(conf.show_hidden))});
    const same = w.menu_card == null and at != null and w.menu_row == at and w.menu_gen == tree_gen;
    w.menu_card = null;
    w.menu_row = at;
    w.menu_gen = tree_gen;
    return markMenu(self, w, side_menu, same);
}

/// The menu for card `d`'s tab (or lone file name) under `lp`, in its pane,
/// showing the keys of the commands the menu bar has too.
fn tabMenu(self: Id, w: *Win, d: *Doc, lp: Point) Id {
    const hit = tabAt(d, lp) orelse titleTab(d, lp) orelse return null;
    const n = tabCount(d);
    const path = tabPage(d, hit.j).path;
    const has_path = if (path) |x| setMenuPath(x) else false;
    if (tab_menu == null) {
        const m = objc.new("NSMenu");
        msg(void, m, "setAutoenablesItems:", .{false});
        _ = menuItem(m, "Close Tab", "tabClose:", "w", objc.cmd_key);
        tab_items[0] = menuItem(m, "Close Other Tabs", "tabCloseOthers:", "", 0);
        tab_items[1] = menuItem(m, "Close Tabs to the Left", "tabCloseLeft:", "", 0);
        tab_items[2] = menuItem(m, "Close Tabs to the Right", "tabCloseRight:", "", 0);
        separator(m);
        tab_items[3] = menuItem(m, "Duplicate Tab", "tabDuplicate:", "", 0);
        tab_items[4] = menuItem(m, "Move to New Window", "tabNewWindow:", "", 0);
        separator(m);
        tab_items[5] = menuItem(m, "Split Right", "tabSplitRight:", "d", objc.cmd_key);
        tab_items[6] = menuItem(m, "Split Down", "tabSplitDown:", "d", objc.cmd_key | objc.shift_key);
        separator(m);
        tab_items[7] = menuItem(m, "Reveal in Finder", "revealInFinder:", "", 0);
        tab_items[8] = menuItem(m, "Copy Path", "copyPath:", "", 0);
        tab_menu = m;
    }
    const on = [9]bool{ n > 1, hit.j > 0, hit.j + 1 < n, true, n > 1 or d.win.cards.pane == null, n > 1 and roomFor(d, false), n > 1 and roomFor(d, true), has_path, has_path };
    for (tab_items, on) |it, x| msg(void, it, "setEnabled:", .{x});
    const same = w.menu_card == d and w.menu_tab == hit.id;
    w.menu_row = null;
    w.menu_card = d;
    w.menu_tab = hit.id;
    return markMenu(self, w, tab_menu, same);
}

/// The menu of card `d`'s header away from its tabs: its own commands,
/// which reach it as the focused card.
fn cardMenu(d: *Doc) Id {
    focus(d);
    if (card_menu == null) {
        const m = objc.new("NSMenu");
        _ = menuItem(m, "New Tab", "newTab:", "t", objc.cmd_key);
        separator(m);
        _ = menuItem(m, "Split Right", "splitRight:", "d", objc.cmd_key);
        _ = menuItem(m, "Split Down", "splitDown:", "d", objc.cmd_key | objc.shift_key);
        separator(m);
        _ = menuItem(m, "Close Card", "closeCard:", "", 0);
        card_menu = m;
    }
    return card_menu;
}

/// The card and tab index the tab menu was opened on, while both are there.
fn menuTab() ?TabRef {
    const w = menu_win orelse return null;
    const d = w.menu_card orelse return null;
    if (!ax.alive(d)) return null;
    return .{ .d = d, .j = tabIndex(d, w.menu_tab) orelse return null };
}

fn tabAction(comptime run: anytype, comptime args: anytype) *const anyopaque {
    return @ptrCast(&struct {
        fn imp(_: Id, _: Sel, _: Id) callconv(.c) void {
            const t = menuTab() orelse return;
            _ = @call(.auto, run, .{ t.d, t.j } ++ args);
        }
    }.imp);
}

fn splitTab(d: *Doc, j: usize, zone: Zone) void {
    moveTab(d, j, .{ .card = d, .zone = zone });
}

/// Closes card `d`'s tabs right of tab `at` and, with `left`, the ones left
/// of it, then shows it. Each one with something to lose asks first, and
/// Cancel stops there.
fn closeAround(d: *Doc, at: usize, right: bool, left: bool) void {
    const id = tabPage(d, at).id;
    while (right) {
        const j = tabIndex(d, id) orelse return;
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

/// A tab's Duplicate Tab: an untitled copy of its text right after it.
fn duplicateTab(d: *Doc, j: usize) void {
    const src = tabPage(d, j);
    var ed = Editor.init(gpa, src.ed.text()) catch return;
    styleEditor(&ed);
    var pg: Page = .{ .ed = ed, .id = newId(), .lang = src.lang, .lang_i = src.lang_i };
    _ = pg.rename();
    putTab(d, pg, j + 1);
}

fn openFromMenu(zone: Zone) void {
    const w = menu_win orelse return;
    const c = w.focus;
    placeFile(w, menuFile(), .{ .card = c, .zone = zone, .k = c.at + 1 });
}

fn openInNewTab(_: Id, _: Sel, _: Id) callconv(.c) void {
    openFromMenu(.tabs);
}

/// Splits the focused card right, or down when it's too narrow, or opens a
/// tab when it's too small for either.
fn openInNewSplit(_: Id, _: Sel, _: Id) callconv(.c) void {
    const w = menu_win orelse return;
    const c = w.focus;
    const zone: Zone = if (roomFor(c, false)) .right else if (roomFor(c, true)) .bottom else .tabs;
    openFromMenu(zone);
}

fn openInNewWindow(_: Id, _: Sel, _: Id) callconv(.c) void {
    open(menuFile(), null);
}

fn revealInFinder(_: Id, _: Sel, _: Id) callconv(.c) void {
    revealPath(menuFile());
}

fn copyPath(_: Id, _: Sel, _: Id) callconv(.c) void {
    putClipboard(menuFile());
}

/// The path from the open folder, or the whole path outside it.
fn copyRelativePath(_: Id, _: Sel, _: Id) callconv(.c) void {
    putClipboard(relOf(menuFile()) orelse menuFile());
}

/// The folder the side menu's New File… and New Folder… make things in:
/// the row's folder, or the folder the row's file is in.
fn menuFolder() []const u8 {
    const p = menuFile();
    return if (menu_dir) p else std.fs.path.dirname(p) orelse p;
}

/// After a file or folder appears, moves or goes: the sidebar lists the
/// folder again, with `shown` (a path inside the open folder) in view.
fn sideChanged(shown: ?[]const u8) void {
    if (shown) |s| if (relOf(s)) |rel| revealFile(rel);
    tree_stale = true;
    rebuildTree();
    for (wins.items) |w| w.side_find = true;
    refreshAll();
}

/// `dir`/`name` into `buf`, null-terminated.
fn joinPath(buf: []u8, dir: []const u8, name: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch null;
}

/// Says a file operation failed, with the system's reason.
fn failed(what: []const u8, path: []const u8) void {
    var ib: [std.fs.max_path_bytes + 160]u8 = undefined;
    alert(what, std.fmt.bufPrint(&ib, "{s}.\n\n{s}", .{ osError(), path }) catch path);
}

/// The side menu's New File…: asks for a name, makes the file empty, and
/// opens it in the focused card.
fn sideNewFile(_: Id, _: Sel, _: Id) callconv(.c) void {
    const w = menu_win orelse return;
    var db: [std.fs.max_path_bytes]u8 = undefined;
    const dir = db[0..menuFolder().len];
    @memcpy(dir, menuFolder());
    var ib: [300]u8 = undefined;
    const name = askName("New File", std.fmt.bufPrint(&ib, "A new, empty file in {s}.", .{std.fs.path.basename(dir)}) catch "", "untitled.txt", "Create") orelse return;
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const p = joinPath(&pb, dir, name) orelse return;
    if (files.exists(p)) return alert("A file with that name is already there.", p);
    files.write(p, "") catch return failed("Couldn't make the file.", p);
    sideChanged(p);
    if (ax.winAlive(w)) open(p, w.focus);
}

/// The side menu's New Folder….
fn sideNewFolder(_: Id, _: Sel, _: Id) callconv(.c) void {
    var db: [std.fs.max_path_bytes]u8 = undefined;
    const dir = db[0..menuFolder().len];
    @memcpy(dir, menuFolder());
    var ib: [300]u8 = undefined;
    const name = askName("New Folder", std.fmt.bufPrint(&ib, "A new folder in {s}.", .{std.fs.path.basename(dir)}) catch "", "untitled folder", "Create") orelse return;
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const p = joinPath(&pb, dir, name) orelse return;
    if (files.exists(p)) return alert("Something with that name is already there.", p);
    if (std.c.mkdir(p, 0o755) != 0) return failed("Couldn't make the folder.", p);
    sideChanged(p);
}

/// The side menu's Rename…: open tabs of the file, or of files in the
/// folder, follow it to its new name.
fn sideRename(_: Id, _: Sel, _: Id) callconv(.c) void {
    var ob: [std.fs.max_path_bytes]u8 = undefined;
    const old = std.fmt.bufPrintSentinel(&ob, "{s}", .{menuFile()}, 0) catch return;
    const base = std.fs.path.basename(old);
    const name = askName("Rename", "", base, "Rename") orelse return;
    if (std.mem.eql(u8, name, base)) return;
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const p = joinPath(&pb, std.fs.path.dirname(old) orelse "/", name) orelse return;
    if (files.exists(p)) return alert("Something with that name is already there.", p);
    if (std.c.rename(old, p) != 0) return failed("Couldn't rename it.", old);
    movedPath(old, p);
    sideChanged(p);
}

/// Open tabs whose file is `old`, or inside the folder `old`, take the
/// same place under `new`.
fn movedPath(old: []const u8, new: []const u8) void {
    for (docs.items) |d| for (0..tabCount(d)) |j| {
        const pg = tabPage(d, j);
        const p = pg.path orelse continue;
        if (!std.mem.startsWith(u8, p, old) or (p.len > old.len and p[old.len] != '/')) continue;
        const np = std.mem.concatWithSentinel(gpa, u8, &.{ new, p[old.len..] }, 0) catch continue;
        preview.rename(pg.id, np);
        gpa.free(p);
        pg.path = np;
        const lang = langOf(pg, np);
        if (lang != pg.lang) {
            pg.lang = lang;
            pg.states.clearRetainingCapacity();
        }
        pg.stamp = files.stamp(np);
        if (j == d.at) {
            clearSyntax(d);
            named(d);
        }
    };
}

/// The side menu's Duplicate: a copy beside it named "name copy.ext", or
/// "name copy 2.ext" and on when that's taken.
fn sideDuplicate(_: Id, _: Sel, _: Id) callconv(.c) void {
    const src = menuFile();
    const dir = std.fs.path.dirname(src) orelse return;
    const base = std.fs.path.basename(src);
    const dot = if (menu_dir) null else std.mem.lastIndexOfScalar(u8, base, '.');
    const stem = if (dot) |k| (if (k > 0) base[0..k] else base) else base;
    const ext = if (dot) |k| (if (k > 0) base[k..] else "") else "";
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    var n: usize = 1;
    const p = while (n < 100) : (n += 1) {
        var nb: [std.fs.max_path_bytes]u8 = undefined;
        const name = (if (n == 1) std.fmt.bufPrint(&nb, "{s} copy{s}", .{ stem, ext }) else std.fmt.bufPrint(&nb, "{s} copy {d}{s}", .{ stem, n, ext })) catch return;
        const q = joinPath(&pb, dir, name) orelse return;
        if (!files.exists(q)) break q;
    } else return;
    const fm = msg(Id, objc.class("NSFileManager"), "defaultManager", .{});
    if (!msg(bool, fm, "copyItemAtPath:toPath:error:", .{ objc.str(src), objc.str(p), @as(?*anyopaque, null) })) return failed("Couldn't duplicate it.", src);
    sideChanged(p);
}

/// The side menu's Move to Trash. Open tabs of what went keep their text
/// as unsaved changes.
fn sideTrash(_: Id, _: Sel, _: Id) callconv(.c) void {
    const p = menuFile();
    if (!trash(p)) return failed("Couldn't move it to the Trash.", p);
    for (docs.items) |d| checkOutside(d);
    sideChanged(null);
}

/// The side menu's Collapse All: every open folder shuts, and the list
/// crossfades to its top.
fn collapseAll(_: Id, _: Sel, _: Id) callconv(.c) void {
    tree.closeAll(gpa);
    for (wins.items) |w| {
        w.side_y = 0;
        w.side_t.snap(0);
        if (sideShown(w)) msg(void, msg(Id, w.view, "layer", .{}), "addAnimation:forKey:", .{ themeFade(), objc.str("root") });
    }
    tree_stale = true;
    rebuildTree();
    refreshAll();
}

fn windowShouldClose(self: Id, _: Sel, _: Id) callconv(.c) bool {
    return settle(winOf(self) orelse return true, false);
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
    for (&w.bold) |*b| freeSideLine(&b.line);
    if (w.toast_line) |l| objc.CFRelease(l);
    if (std.mem.indexOfScalar(*Win, wins.items, w)) |j| _ = wins.orderedRemove(j);
    gpa.destroy(w);
}

// ---- menu actions ----

fn action(comptime run: anytype, comptime args: anytype) *const anyopaque {
    return @ptrCast(&struct {
        fn imp(self: Id, _: Sel, _: Id) callconv(.c) void {
            const d = docOf(self) orelse return;
            _ = @call(.auto, run, .{d} ++ args);
            // Closing the last tab closes the window, and the card with it.
            if (std.mem.indexOfScalar(*Doc, docs.items, d) != null) refresh(d);
        }
    }.imp);
}

/// A menu action thunk: calls `run` with `args` and drops its result.
pub fn appAction(comptime run: anytype, comptime args: anytype) *const anyopaque {
    return @ptrCast(&struct {
        fn thunk(_: Id, _: Sel, _: Id) callconv(.c) void {
            _ = @call(.auto, run, args);
        }
    }.thunk);
}

/// A menu action thunk for items that carry their index in `tag`.
fn appPick(comptime run: fn (usize) void) *const anyopaque {
    return @ptrCast(&struct {
        fn thunk(_: Id, _: Sel, sender: Id) callconv(.c) void {
            run(@intCast(msg(isize, sender, "tag", .{})));
        }
    }.thunk);
}

fn pasteboard() Id {
    return msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
}

extern const NSPasteboardTypeString: Id;

fn copy(d: *Doc) void {
    if (d.mode != .edit) {
        const r = fieldSel(d);
        if (r[0] != r[1]) putClipboard(field(d).items[r[0]..r[1]]);
        return;
    }
    const s = d.file.ed.sel();
    if (s[0] == s[1]) return;
    putClipboard(d.file.ed.text()[s[0]..s[1]]);
}

fn putClipboard(text: []const u8) void {
    const string = if (std.unicode.utf8ValidateSlice(text)) objc.str(text) else access.nsText(text);
    const pb = pasteboard();
    _ = msg(isize, pb, "clearContents", .{});
    _ = msg(bool, pb, "setString:forType:", .{ string, NSPasteboardTypeString });
}

fn cut(d: *Doc) void {
    if (d.mode != .edit) {
        const r = fieldSel(d);
        if (r[0] == r[1]) return;
        putClipboard(field(d).items[r[0]..r[1]]);
        return fieldPut(d, "", false);
    }
    if (!d.file.ed.hasSel()) return;
    copy(d);
    d.file.ed.deleteSelection(gpa) catch {};
    // A bar flashes where the cut text was.
    flashStart(d);
    flashAdd(d, d.file.ed.cur, d.file.ed.cur);
    reveal(d);
}

/// The prompt is one line. In find and replace a paste over several lines
/// becomes one, each line break and the indent around it a single space;
/// Quick Open and the palette take only its first line, and go to line
/// keeps its digits, `:`, `+` and `-`.
fn promptPaste(d: *Doc, s: []const u8) void {
    const t = std.mem.trim(u8, s, "\r\n");
    if (t.len == 0) return;
    const nl = std.mem.indexOfAny(u8, t, "\r\n") orelse return promptType(d, t, false);
    switch (d.mode) {
        .open, .command => fieldPut(d, std.mem.trimEnd(u8, t[0..nl], " \t"), false),
        .line => promptType(d, t[0..nl], false),
        else => {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            var lines = std.mem.tokenizeAny(u8, t, "\r\n");
            while (lines.next()) |l| {
                const part = std.mem.trim(u8, l, " \t");
                if (part.len == 0) continue;
                if (out.items.len > 0) out.append(gpa, ' ') catch return;
                out.appendSlice(gpa, part) catch return;
            }
            fieldPut(d, out.items, false);
        },
    }
}

fn paste(d: *Doc) void {
    const s = objc.utf8(msg(Id, pasteboard(), "stringForType:", .{NSPasteboardTypeString}));
    // An image or file on the clipboard has no text: the selection stays.
    if (s.len == 0) return;
    if (d.mode != .edit) return promptPaste(d, s);
    const at = d.file.ed.sel()[0];
    d.file.ed.paste(gpa, s) catch {};
    // Every paste flashes what it put in, a short one too.
    flashStart(d);
    flashAdd(d, at, d.file.ed.cur);
    reveal(d);
}

fn selectAll(d: *Doc) void {
    if (d.mode == .edit) return d.file.ed.selectAll();
    const i = fieldIndex(d);
    d.panc[i] = 0;
    d.pcur[i] = field(d).items.len;
    d.ptyping = false;
}

fn stepHistory(d: *Doc, forward: bool) void {
    // In a prompt, ⌘Z and ⇧⌘Z step back and forth through its typing; with
    // none to step, the prompt closes and the text's own undo runs.
    if (d.mode != .edit and (if (forward) d.predo.items.len else d.pundo.items.len) > 0) return promptUndo(d, forward);
    d.mode = .edit;
    flashStart(d);
    if ((if (forward) d.file.ed.redo(gpa) else d.file.ed.undo(gpa)) catch null) |span| flashAdd(d, span[0], span[1]);
    reveal(d);
}

fn closeActive(d: *Doc) void {
    closeTab(d, d.at);
}

pub fn previewText(id: u32) ?[]const u8 {
    for (docs.items) |d| {
        if (d.closing) continue;
        for (0..tabCount(d)) |j| {
            const p = tabPage(d, j);
            if (p.id == id) return p.ed.text();
        }
    }
    return null;
}

/// The tab the Markdown preview shows, and how far down it was last scrolled.
var preview_frac: f64 = -1;

fn markdownPreview(d: *Doc) void {
    preview.setTypography(conf.font(), conf.size, conf.spacing);
    preview_frac = -1;
    preview.toggle(d, themeOf(d.win));
}

fn comment(d: *Doc) void {
    if (d.mode != .edit) return;
    d.file.ed.toggleComment(gpa, d.file.lang.line_comment) catch {};
}

/// Edit > Format JSON: lays out the selection or the file and flashes what
/// it laid out. JSON it can't read moves the caret to where it goes wrong,
/// shakes the card and says what's wrong there.
fn formatJson(d: *Doc) void {
    if (d.mode != .edit) return;
    const e = &d.file.ed;
    const t = e.text();
    const r = if (e.hasSel()) e.sel() else [2]usize{ 0, t.len };
    const ws = " \t\r\n";
    const a = r[1] - std.mem.trimStart(u8, t[r[0]..r[1]], ws).len;
    const z = r[0] + std.mem.trimEnd(u8, t[r[0]..r[1]], ws).len;
    if (a >= z) return toast(d.win, if (e.hasSel()) "the selection has no JSON in it" else "no JSON to format");
    const len0 = t.len;
    if (e.formatJson(gpa) catch return) {
        flashStart(d);
        flashAdd(d, a, z + e.text().len - len0);
        return reveal(d);
    }
    // Nothing changed, so the text and its offsets still hold.
    const bad = jsonFault(t[a..z]);
    const at = a + bad.at;
    e.select(at, at);
    center(d);
    d.card_shake_t0 = CACurrentMediaTime();
    const b = &e.buf;
    const row = b.lineOf(at);
    const col = codepoints(t[b.lineStart(row)..at]) + 1;
    var buf: [96]u8 = undefined;
    const c: u8 = if (at < z) t[at] else 0;
    toast(d.win, if (bad.end)
        std.fmt.bufPrint(&buf, "JSON ends too soon at line {d}, column {d}", .{ row + 1, col }) catch "not valid JSON"
    else if (c > 0x20 and c < 0x7f)
        std.fmt.bufPrint(&buf, "unexpected \"{c}\" in JSON at line {d}, column {d}", .{ c, row + 1, col }) catch "not valid JSON"
    else
        std.fmt.bufPrint(&buf, "JSON goes wrong at line {d}, column {d}", .{ row + 1, col }) catch "not valid JSON");
}

/// Where JSON text `s` first goes wrong, and whether it just ends too soon.
fn jsonFault(s: []const u8) struct { at: usize, end: bool } {
    var sc = std.json.Scanner.initCompleteInput(gpa, s);
    defer sc.deinit();
    while (true) {
        const tok = sc.next() catch |err| return .{ .at = @min(sc.cursor, s.len), .end = err == error.UnexpectedEndOfInput };
        if (tok == .end_of_document) return .{ .at = s.len, .end = true };
    }
}

const LineEdit = enum { duplicate, up, down, join, delete };

/// Edit's line commands, on the caret's line or every line the selection touches.
fn lineEdit(d: *Doc, op: LineEdit) void {
    if (d.mode != .edit) return;
    const e = &d.file.ed;
    (switch (op) {
        .duplicate => e.duplicateLine(gpa),
        .up => e.moveLinesUp(gpa),
        .down => e.moveLinesDown(gpa),
        .join => e.joinLines(gpa),
        .delete => e.deleteLine(gpa),
    }) catch {};
    reveal(d);
}

/// A zoom's size, applied at once and written to the settings file once
/// zooming pauses, so a run of ⌘= writes the file once.
var zoom_due = false;
var zoom_size: f64 = settings.default_size;
/// Counts zooms, so only the last one's timer writes.
var zoom_gen: usize = 0;

/// View > Bigger, Smaller and Actual Size. The new size shows in a note;
/// at 8 or 40 points the trackpad taps.
fn zoom(by: f64) void {
    const was = conf_saved.size;
    const size = if (by == 0) settings.default_size else std.math.clamp(was + by, settings.size_min, settings.size_max);
    const limit = by != 0 and (size == settings.size_min or size == settings.size_max);
    if (limit) haptic(.level);
    if (size != was) {
        const old = conf;
        conf_saved.size = size;
        zoom_size = size;
        zoom_due = true;
        zoom_gen +%= 1;
        dispatch_after_f(dispatch_time(0, 400 * std.time.ns_per_ms), &_dispatch_main_q, @ptrFromInt(zoom_gen), zoomWrite);
        applySettings(old);
    }
    var nb: [24]u8 = undefined;
    var tb: [64]u8 = undefined;
    const edge: []const u8 = if (!limit) "" else if (size == settings.size_max) ", the largest" else ", the smallest";
    toastFront(std.fmt.bufPrint(&tb, "{s} pt{s}", .{ settings.decimal(&nb, size), edge }) catch "");
}

/// Writes the last zoom's size, unless a later zoom (`ctx` is its count) is waiting.
fn zoomWrite(ctx: ?*anyopaque) callconv(.c) void {
    if (@intFromPtr(ctx) != zoom_gen or !zoom_due) return;
    zoom_due = false;
    var buf: [24]u8 = undefined;
    store(.size, settings.decimal(&buf, zoom_size));
}

/// The Font panel's choice, saved to the settings file.
fn changeFont(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const picked = msg(Id, sender, "convertFont:", .{font});
    if (picked == null) return;
    const name = objc.utf8(msg(Id, picked, "fontName", .{}));
    // The system font's private name can't be asked for by name.
    store(.font, if (name.len == 0 or name[0] == '.') "system" else name);
    var buf: [24]u8 = undefined;
    store(.size, settings.decimal(&buf, @round(msg(f64, picked, "pointSize", .{}))));
}

/// File > Save All: every file with unsaved changes, in every window. A
/// Cancel in a Save As stops there.
fn saveEverything(_: *Doc) void {
    var i: usize = 0;
    while (i < docs.items.len) : (i += 1) {
        const x = docs.items[i];
        if (!x.closing and !saveAll(x, true)) return;
    }
}

/// File > Reveal in Finder: the file on show, selected in Finder.
fn revealCurrent(d: *Doc) void {
    if (d.file.path) |p| revealPath(p) else toast(d.win, "not saved yet");
}

/// Window > Merge All Windows: every other window's tabs move into this
/// card, and those windows close.
fn mergeWindows(d: *Doc) void {
    var others: [64]*Win = undefined;
    var n: usize = 0;
    for (wins.items) |w| if (w != d.win and n < others.len) {
        others[n] = w;
        n += 1;
    };
    for (others[0..n]) |w| {
        for (docs.items) |x| if (x.win == w and !x.closing) {
            while (!(tabCount(x) == 1 and isBlank(x))) {
                var pg = takeTab(x, 0) orelse break;
                if (pg.path == null and pg.ed.text().len == 0) {
                    pg.deinit();
                    continue;
                }
                putTab(d, pg, tabCount(d));
            }
        };
        // Only blank cards are left, so closing asks nothing.
        msg(void, w.window, "close", .{});
    }
    focus(d);
    showWin(d.win.window);
}

/// Window > Move Tab to New Window: the tab on show leaves for a window of
/// its own. A window's only tab stays where it is.
fn tabToNewWindow(d: *Doc) void {
    tabOut(d, d.at);
}

/// Moves card `d`'s tab `j` to a window of its own.
fn tabOut(d: *Doc, j: usize) void {
    const last = tabCount(d) == 1;
    if (last and d.win.cards.pane != null) return;
    const pg = takeTab(d, j) orelse return;
    const nd = newDoc() orelse {
        var p = pg;
        return p.deinitKeepDraft();
    };
    putTab(nd, pg, 0);
    if (last) foldCard(d);
}

/// Help menu links.
const guide_url = "https://github.com/hkay-dev/zag/blob/main/docs/guide/index.md";
const issues_url = "https://github.com/hkay-dev/zag/issues/new";

fn openUrl(url: []const u8) void {
    const u = msg(Id, objc.class("NSURL"), "URLWithString:", .{objc.str(url)});
    if (u != null) _ = msg(bool, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{u});
}

/// A 14-point picture of built-in theme `sc` for the Theme menu: its
/// background in a rounded square edged in its rule color, with bars in
/// its keyword, text and string colors.
fn swatch(sc: settings.Scheme) Id {
    const space = objc.CGColorSpaceCreateDeviceRGB();
    defer if (space) |s| objc.CFRelease(s);
    const ctx = objc.CGBitmapContextCreate(null, 28, 28, 8, 0, space, 1);
    if (ctx == null) return null;
    defer objc.CFRelease(ctx.?);
    const c = sc.colors;
    pill(ctx, rgbOf(c.rule), 1, 0, 0, 28, 28, 7);
    pill(ctx, rgbOf(c.bg), 1, 1, 1, 26, 26, 6);
    // The bitmap's origin is its bottom left: the first bar is the top one.
    pill(ctx, rgbOf(c.kinds[1]), 1, 6, 17, 12, 3, 1.5);
    pill(ctx, rgbOf(c.fg), 1, 6, 12, 16, 3, 1.5);
    pill(ctx, rgbOf(c.kinds[2]), 1, 6, 7, 9, 3, 1.5);
    const img = objc.CGBitmapContextCreateImage(ctx) orelse return null;
    defer objc.CFRelease(img);
    const ns = msg(Id, msg(Id, objc.class("NSImage"), "alloc", .{}), "initWithCGImage:size:", .{ img, objc.Size{ .w = 14, .h = 14 } });
    return msg(Id, ns, "autorelease", .{});
}

fn rgbOf(b: [3]u8) Rgb {
    return .{ f(b[0]) / 255, f(b[1]) / 255, f(b[2]) / 255 };
}

// ---- the menu bar ----
//
// One list builds the menus, binds each command's handler and says which
// commands grey out or show a checkmark, so a selector is written once.
// An entry is a separator (`.sep`), a greyed heading (`.heading`), a menu or
// inline group (`.items`, a menu when it has a `.menu` title), a command
// (`.title` and `.sel`), a run of picks that carry their index in `tag`
// (`.titles`, or `.schemes` for the built-in themes).

/// Who handles a command: the app delegate (needs no window), the key
/// window's view, or AppKit itself (`.fonts` is the font manager).
const Target = enum { app, view, system, fonts };

/// The setting a command's checkmark shows. Picks compare their tag.
const Check = enum { wrap, pairs, sidebar, line_numbers, typewriter, zen, late_night, focus, scheme, look, show_hidden, language };

/// `e`'s field `name` as a `T`, or `default` when the entry has none.
fn pluck(comptime T: type, comptime e: anytype, comptime name: []const u8, comptime default: T) T {
    return if (@hasField(@TypeOf(e), name)) @as(T, @field(e, name)) else default;
}

/// The View menu item that shows or hides the sidebar; its sidebar button's tooltip says the same.
const sidebar_title = "Sidebar";

const clipboard = .{
    .{ .title = "Cut", .sel = "cut:", .key = "x", .mods = objc.cmd_key, .to = .view, .run = cut },
    .{ .title = "Copy", .sel = "copy:", .key = "c", .mods = objc.cmd_key, .to = .view, .run = copy },
    .{ .title = "Paste", .sel = "paste:", .key = "v", .mods = objc.cmd_key, .to = .view, .run = paste },
    .{ .title = "Select All", .sel = "selectAll:", .key = "a", .mods = objc.cmd_key, .to = .view, .run = selectAll },
};

const menu_bar = .{
    .{ .menu = "Zag", .items = .{
        .{ .title = "About Zag", .sel = "orderFrontStandardAboutPanel:" },
        .{ .sep = true },
        .{ .title = "Settings…", .sel = "openSettings:", .key = ",", .mods = objc.cmd_key, .to = .app, .run = openSettings },
        .{ .title = "Reveal Config in Finder", .sel = "revealConfig:", .to = .app, .run = revealConfig },
        .{ .title = "Reload Settings", .sel = "reloadSettings:", .to = .app, .run = reloadSettings },
        .{ .title = "Reset Settings to Defaults…", .sel = "resetSettings:", .to = .app, .run = resetSettings },
        .{ .sep = true },
        .{ .services = true },
        .{ .sep = true },
        .{ .title = "Hide Zag", .sel = "hide:", .key = "h", .mods = objc.cmd_key },
        .{ .title = "Hide Others", .sel = "hideOtherApplications:", .key = "h", .mods = objc.cmd_key | objc.opt_key },
        .{ .title = "Show All", .sel = "unhideAllApplications:" },
        .{ .sep = true },
        .{ .title = "Quit Zag", .sel = "terminate:", .key = "q", .mods = objc.cmd_key },
    } },
    .{ .menu = "File", .items = .{
        .{ .title = "New", .sel = "newDocument:", .key = "n", .mods = objc.cmd_key, .to = .app, .run = newDoc },
        .{ .title = "New Tab", .sel = "newTab:", .key = "t", .mods = objc.cmd_key, .to = .view, .run = newTab },
        .{ .title = "Open…", .sel = "openDocument:", .key = "o", .mods = objc.cmd_key, .to = .app, .run = openPanel },
        // The delegate fills it each time it opens.
        .{ .menu = "Open Recent", .delegate = true, .items = .{} },
        .{ .title = "Quick Open…", .sel = "quickOpen:", .key = "p", .mods = objc.cmd_key, .to = .view, .run = startPrompt, .args = .{Mode.open} },
        .{ .sep = true },
        .{ .title = "Close Tab", .sel = "closeTab:", .key = "w", .mods = objc.cmd_key, .to = .view, .run = closeActive },
        .{ .title = "Reopen Closed Tab", .sel = "reopenTab:", .to = .view, .run = reopenTab },
        .{ .title = "Close Window", .sel = "performClose:", .key = "w", .mods = objc.cmd_key | objc.shift_key },
        .{ .title = "Save", .sel = "saveDocument:", .key = "s", .mods = objc.cmd_key, .to = .view, .run = save, .args = .{false} },
        .{ .title = "Save As…", .sel = "saveDocumentAs:", .key = "s", .mods = objc.cmd_key | objc.shift_key, .to = .view, .run = save, .args = .{true} },
        .{ .title = "Save All", .sel = "saveAll:", .key = "s", .mods = objc.cmd_key | objc.opt_key, .to = .view, .run = saveEverything },
        .{ .sep = true },
        .{ .title = "Reveal in Finder", .sel = "revealCurrent:", .to = .view, .run = revealCurrent },
        .{ .title = "Recover Drafts", .sel = "recoverDrafts:", .to = .app, .run = recoverDraftsNow },
        .{ .title = "Browse Drafts…", .sel = "browseDrafts:", .to = .app, .run = browseDrafts },
    } },
    .{ .menu = "Edit", .items = .{
        .{ .title = "Undo", .sel = "undo:", .key = "z", .mods = objc.cmd_key, .to = .view, .run = stepHistory, .args = .{false} },
        .{ .title = "Redo", .sel = "redo:", .key = "z", .mods = objc.cmd_key | objc.shift_key, .to = .view, .run = stepHistory, .args = .{true} },
        .{ .sep = true },
        .{ .items = clipboard },
        .{ .sep = true },
        .{ .title = "Find…", .sel = "findText:", .key = "f", .mods = objc.cmd_key, .to = .view, .run = startPrompt, .args = .{Mode.find} },
        .{ .title = "Find and Replace…", .sel = "findAndReplace:", .key = "f", .mods = objc.cmd_key | objc.opt_key, .to = .view, .run = startPrompt, .args = .{Mode.replace} },
        .{ .title = "Find Next", .sel = "findNext:", .key = "g", .mods = objc.cmd_key, .to = .view, .run = findAgain, .args = .{false} },
        .{ .title = "Find Previous", .sel = "findPrevious:", .key = "g", .mods = objc.cmd_key | objc.shift_key, .to = .view, .run = findAgain, .args = .{true} },
        .{ .title = "Go to Line…", .sel = "gotoLine:", .key = "l", .mods = objc.cmd_key, .to = .view, .run = startPrompt, .args = .{Mode.line} },
        .{ .title = "Toggle Comment", .sel = "toggleComment:", .key = "/", .mods = objc.cmd_key, .to = .view, .run = comment },
        .{ .title = "Format JSON", .sel = "formatJson:", .key = "j", .mods = objc.cmd_key | objc.opt_key, .to = .view, .run = formatJson },
        .{ .sep = true },
        .{ .title = "Duplicate Line", .sel = "duplicateLine:", .key = "d", .mods = objc.ctrl_key | objc.shift_key, .to = .view, .run = lineEdit, .args = .{LineEdit.duplicate} },
        .{ .title = "Move Line Up", .sel = "moveLineUp:", .key = "\u{F700}", .mods = objc.opt_key, .to = .view, .run = lineEdit, .args = .{LineEdit.up} },
        .{ .title = "Move Line Down", .sel = "moveLineDown:", .key = "\u{F701}", .mods = objc.opt_key, .to = .view, .run = lineEdit, .args = .{LineEdit.down} },
        .{ .title = "Join Lines", .sel = "joinLines:", .key = "j", .mods = objc.ctrl_key, .to = .view, .run = lineEdit, .args = .{LineEdit.join} },
        .{ .title = "Delete Line", .sel = "deleteLine:", .key = "k", .mods = objc.cmd_key | objc.shift_key, .to = .view, .run = lineEdit, .args = .{LineEdit.delete} },
    } },
    .{ .menu = "View", .items = .{
        .{ .title = "Command Palette…", .sel = "commandPalette:", .key = "k", .mods = objc.cmd_key, .to = .view, .run = startPrompt, .args = .{Mode.command} },
        .{ .title = "Markdown Preview", .sel = "markdownPreview:", .key = "m", .mods = objc.cmd_key | objc.shift_key, .to = .view, .run = markdownPreview },
        .{ .sep = true },
        .{ .title = "Font…", .sel = "orderFrontFontPanel:", .key = "t", .mods = objc.cmd_key | objc.shift_key, .to = .fonts },
        .{ .title = "Bigger", .sel = "zoomIn:", .key = "=", .mods = objc.cmd_key, .to = .app, .run = zoom, .args = .{1} },
        // ⌘+ arrives as ⇧⌘=, which the item above doesn't match.
        .{ .title = "Bigger", .sel = "zoomIn:", .key = "+", .mods = objc.cmd_key, .hidden = true },
        .{ .title = "Smaller", .sel = "zoomOut:", .key = "-", .mods = objc.cmd_key, .to = .app, .run = zoom, .args = .{-1} },
        .{ .title = "Actual Size", .sel = "zoomReset:", .key = "0", .mods = objc.cmd_key, .to = .app, .run = zoom, .args = .{0} },
        .{ .sep = true },
        .{ .title = "Soft Wrap", .sel = "toggleWrap:", .key = "z", .mods = objc.opt_key, .to = .app, .run = flip, .args = .{.wrap}, .check = .wrap },
        .{ .title = "Line Numbers", .sel = "toggleLineNumbers:", .key = "l", .mods = objc.cmd_key | objc.shift_key, .to = .app, .run = flip, .args = .{.@"line-numbers"}, .check = .line_numbers },
        .{ .title = "Auto-Close Brackets", .sel = "togglePairs:", .to = .app, .run = flip, .args = .{.pairs}, .check = .pairs },
        .{ .title = sidebar_title, .sel = "toggleSidebar:", .key = "\\", .mods = objc.cmd_key, .to = .app, .run = flip, .args = .{.sidebar}, .check = .sidebar },
        .{ .title = "Focus Sidebar", .sel = "focusSidebar:", .key = "e", .mods = objc.cmd_key | objc.shift_key, .to = .view, .run = focusSidebar },
        .{ .title = "Show Hidden Files", .sel = "toggleHidden:", .to = .app, .run = flip, .args = .{.@"show-hidden"}, .check = .show_hidden },
        .{ .title = "Zen Mode", .sel = "toggleZen:", .key = "z", .mods = objc.ctrl_key | objc.cmd_key, .to = .app, .run = toggleZen, .check = .zen, .grey = true },
        .{ .title = "Peek Window Controls", .sel = "peekLights:", .key = "p", .mods = objc.ctrl_key | objc.cmd_key, .to = .view, .run = peekLights },
        // Late-Night's own checkmark reads its flag; the items it sets show the effective values.
        .{ .title = "Late-Night Focus", .sel = "toggleLateNight:", .key = "n", .mods = objc.ctrl_key | objc.cmd_key, .to = .app, .run = flip, .args = .{.@"late-night"}, .check = .late_night },
        .{ .title = "Show Next Tab", .sel = "nextTab:", .key = "\t", .mods = objc.ctrl_key, .to = .view, .run = stepTab, .args = .{1} },
        // ⇧Tab arrives as back tab, so that's the key to match.
        .{ .title = "Show Previous Tab", .sel = "previousTab:", .key = "\x19", .mods = objc.ctrl_key | objc.shift_key, .to = .view, .run = stepTab, .args = .{-1} },
        // ⇧⌘] and ⇧⌘[ arrive as ⌘} and ⌘{, so those are the keys to match.
        .{ .title = "Show Next Tab", .sel = "nextTab:", .key = "}", .mods = objc.cmd_key, .hidden = true },
        .{ .title = "Show Previous Tab", .sel = "previousTab:", .key = "{", .mods = objc.cmd_key, .hidden = true },
        .{ .menu = "Go to Tab", .items = .{
            .{ .title = "Tab 1", .sel = "showTab1:", .key = "1", .mods = objc.cmd_key, .to = .view, .run = jumpTab, .args = .{0} },
            .{ .title = "Tab 2", .sel = "showTab2:", .key = "2", .mods = objc.cmd_key, .to = .view, .run = jumpTab, .args = .{1} },
            .{ .title = "Tab 3", .sel = "showTab3:", .key = "3", .mods = objc.cmd_key, .to = .view, .run = jumpTab, .args = .{2} },
            .{ .title = "Tab 4", .sel = "showTab4:", .key = "4", .mods = objc.cmd_key, .to = .view, .run = jumpTab, .args = .{3} },
            .{ .title = "Tab 5", .sel = "showTab5:", .key = "5", .mods = objc.cmd_key, .to = .view, .run = jumpTab, .args = .{4} },
            .{ .title = "Tab 6", .sel = "showTab6:", .key = "6", .mods = objc.cmd_key, .to = .view, .run = jumpTab, .args = .{5} },
            .{ .title = "Tab 7", .sel = "showTab7:", .key = "7", .mods = objc.cmd_key, .to = .view, .run = jumpTab, .args = .{6} },
            .{ .title = "Tab 8", .sel = "showTab8:", .key = "8", .mods = objc.cmd_key, .to = .view, .run = jumpTab, .args = .{7} },
            .{ .title = "Last Tab", .sel = "showLastTab:", .key = "9", .mods = objc.cmd_key, .to = .view, .run = jumpTab, .args = .{8} },
        } },
        .{ .title = "Typewriter Scrolling", .sel = "toggleTypewriter:", .to = .app, .run = toggleTypewriter, .check = .typewriter, .grey = true },
        .{ .menu = "Focus", .items = .{
            .{ .titles = .{ "Off", "Line", "Sentence", "Paragraph" }, .sel = "pickFocus:", .to = .app, .run = pickFocus, .check = .focus, .grey = true },
        } },
        // The view handles picks itself (`pickLanguage`): each item's tag indexes `syntax.languages`.
        .{ .menu = "Language", .items = .{
            .{ .langs = true, .sel = "pickLanguage:", .check = .language },
        } },
        .{ .sep = true },
        .{ .title = "Split Right", .sel = "splitRight:", .key = "d", .mods = objc.cmd_key, .to = .view, .run = split, .args = .{false} },
        .{ .title = "Split Down", .sel = "splitDown:", .key = "d", .mods = objc.cmd_key | objc.shift_key, .to = .view, .run = split, .args = .{true} },
        .{ .title = "Next Card", .sel = "nextCard:", .key = "]", .mods = objc.cmd_key, .to = .view, .run = stepCard, .args = .{1} },
        .{ .title = "Previous Card", .sel = "previousCard:", .key = "[", .mods = objc.cmd_key, .to = .view, .run = stepCard, .args = .{-1} },
        .{ .title = "Card Left", .sel = "focusCardLeft:", .key = "\u{F702}", .mods = objc.cmd_key | objc.opt_key, .to = .view, .run = focusToward, .args = .{Zone.left} },
        .{ .title = "Card Right", .sel = "focusCardRight:", .key = "\u{F703}", .mods = objc.cmd_key | objc.opt_key, .to = .view, .run = focusToward, .args = .{Zone.right} },
        .{ .title = "Card Above", .sel = "focusCardAbove:", .key = "\u{F700}", .mods = objc.cmd_key | objc.opt_key, .to = .view, .run = focusToward, .args = .{Zone.top} },
        .{ .title = "Card Below", .sel = "focusCardBelow:", .key = "\u{F701}", .mods = objc.cmd_key | objc.opt_key, .to = .view, .run = focusToward, .args = .{Zone.bottom} },
        .{ .title = "Maximize or Restore Card", .sel = "maximizeCard:", .key = "\r", .mods = objc.cmd_key | objc.shift_key, .to = .view, .run = maximizeCard },
        .{ .title = "Move Tab to Next Card", .sel = "tabToNextCard:", .key = "]", .mods = objc.cmd_key | objc.opt_key, .to = .view, .run = tabToCard, .args = .{1} },
        .{ .title = "Move Tab to Previous Card", .sel = "tabToPreviousCard:", .key = "[", .mods = objc.cmd_key | objc.opt_key, .to = .view, .run = tabToCard, .args = .{-1} },
        .{ .title = "Close Card", .sel = "closeCard:", .to = .view, .run = closeCard },
        .{ .menu = "Theme", .items = .{
            .{ .heading = "Appearance" },
            .{ .titles = .{ "Auto", "Light", "Dark" }, .indent = 1, .sel = "pickAppearance:", .to = .app, .run = pickLook, .check = .look, .grey = true },
            .{ .schemes = true, .indent = 1, .sel = "pickScheme:", .to = .app, .run = pickScheme, .check = .scheme, .grey = true },
        } },
        .{ .sep = true },
        .{ .title = "Enter Full Screen", .sel = "toggleFullScreen:", .key = "f", .mods = objc.cmd_key | objc.ctrl_key },
    } },
    .{ .menu = "Window", .items = .{
        .{ .title = "Minimize", .sel = "performMiniaturize:", .key = "m", .mods = objc.cmd_key },
        .{ .title = "Zoom", .sel = "performZoom:" },
        .{ .sep = true },
        .{ .title = "Move Tab to New Window", .sel = "tabToNewWindow:", .to = .view, .run = tabToNewWindow },
        .{ .title = "Merge All Windows", .sel = "mergeWindows:", .to = .view, .run = mergeWindows },
    } },
    .{ .menu = "Help", .items = .{
        .{ .title = "Zag User Guide", .sel = "openGuide:", .to = .app, .run = openUrl, .args = .{guide_url} },
        .{ .title = "Keyboard Shortcuts", .sel = "showShortcuts:", .to = .view, .run = startPrompt, .args = .{Mode.command} },
        .{ .sep = true },
        .{ .title = "Report an Issue", .sel = "reportIssue:", .to = .app, .run = openUrl, .args = .{issues_url} },
    } },
};

fn submenu(bar: Id, title: []const u8) Id {
    const m = msg(Id, msg(Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.str(title)});
    const it = menuItem(bar, title, "", "", 0);
    msg(void, it, "setSubmenu:", .{m});
    msg(void, m, "release", .{});
    return m;
}

/// Adds the items of `entries` to `menu`; `delegate` goes to menus that ask for one.
fn fillMenu(menu: Id, comptime entries: anytype, delegate: Id) void {
    inline for (entries) |e| {
        const T = @TypeOf(e);
        if (@hasField(T, "services")) {
            // AppKit fills the Services menu with other apps' services.
            const m = submenu(menu, "Services");
            msg(void, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "setServicesMenu:", .{m});
        } else if (@hasField(T, "sep")) {
            separator(menu);
        } else if (@hasField(T, "heading")) {
            msg(void, menuItem(menu, e.heading, "", "", 0), "setEnabled:", .{false});
        } else if (@hasField(T, "items")) {
            if (@hasField(T, "menu")) {
                const m = submenu(menu, e.menu);
                if (pluck(bool, e, "delegate", false)) msg(void, m, "setDelegate:", .{delegate});
                fillMenu(m, e.items, delegate);
            } else fillMenu(menu, e.items, delegate);
        } else if (@hasField(T, "schemes")) {
            for (settings.schemes, 0..) |sc, i| {
                if (i == 0 or sc.dark != settings.schemes[i - 1].dark) {
                    separator(menu);
                    msg(void, menuItem(menu, if (sc.dark) "Dark Mode" else "Light Mode", "", "", 0), "setEnabled:", .{false});
                }
                // Each theme shows a swatch lazily when its menu opens.
                _ = pick(menu, sc.title, e.sel, i, pluck(isize, e, "indent", 0));
            }
        } else if (@hasField(T, "titles")) {
            inline for (e.titles, 0..) |title, i| _ = pick(menu, title, e.sel, i, pluck(isize, e, "indent", 0));
        } else if (@hasField(T, "langs")) {
            for (syntax.languages, 0..) |l, i| _ = pick(menu, l.name, e.sel, i, 0);
        } else {
            const it = menuItem(menu, e.title, e.sel, pluck([]const u8, e, "key", ""), pluck(usize, e, "mods", 0));
            if (pluck(Target, e, "to", .system) == .fonts) {
                msg(void, it, "setTarget:", .{msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{})});
            }
            if (pluck(bool, e, "hidden", false)) {
                msg(void, it, "setHidden:", .{true});
                msg(void, it, "setAllowsKeyEquivalentWhenHidden:", .{true});
            }
        }
    }
}

/// A pick item: its index rides in `tag`.
fn pick(menu: Id, title: []const u8, sel: [:0]const u8, i: usize, indent: isize) Id {
    const it = menuItem(menu, title, sel, "", 0);
    msg(void, it, "setTag:", .{@as(isize, @intCast(i))});
    if (indent != 0) msg(void, it, "setIndentationLevel:", .{indent});
    return it;
}

/// Builds the menu bar and installs it. `delegate` fills Open Recent.
pub fn buildMenu(delegate: Id) void {
    const nsapp = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const bar = objc.new("NSMenu");
    inline for (menu_bar) |e| {
        const m = submenu(bar, e.menu);
        fillMenu(m, e.items, delegate);
        if (comptime std.mem.eql(u8, e.menu, "Window")) msg(void, nsapp, "setWindowsMenu:", .{m});
        if (comptime std.mem.eql(u8, e.menu, "Help")) msg(void, nsapp, "setHelpMenu:", .{m});
    }
    msg(void, nsapp, "setMainMenu:", .{bar});
    msg(void, bar, "release", .{});
}

/// Binds the handlers of the commands `to` handles onto class `c`.
fn bind(comptime entries: anytype, comptime to: Target, c: objc.ClassBuilder) void {
    inline for (entries) |e| {
        const T = @TypeOf(e);
        if (@hasField(T, "items")) {
            bind(e.items, to, c);
        } else if (comptime @hasField(T, "run") and pluck(Target, e, "to", .system) == to) {
            const args = comptime if (@hasField(T, "args")) e.args else .{};
            const picks = @hasField(T, "titles") or @hasField(T, "schemes");
            switch (to) {
                .view => c.method(e.sel, action(e.run, args), "v@:@"),
                .app => c.method(e.sel, if (picks) appPick(e.run) else appAction(e.run, args), "v@:@"),
                .system, .fonts => unreachable,
            }
        }
    }
}

/// Binds the app delegate's menu commands, the ones that work with no window.
pub fn bindApp(d: objc.ClassBuilder) void {
    bind(menu_bar, .app, d);
}

const Rule = struct { check: ?Check, grey: bool };

/// The checkmark and greying rule of the command with selector `name`.
fn ruleFor(comptime entries: anytype, name: []const u8) ?Rule {
    inline for (entries) |e| {
        const T = @TypeOf(e);
        if (@hasField(T, "items")) {
            if (ruleFor(e.items, name)) |r| return r;
        } else if (@hasField(T, "sel")) {
            if (std.mem.eql(u8, e.sel, name)) return .{ .check = pluck(?Check, e, "check", null), .grey = pluck(bool, e, "grey", false) };
        }
    }
    return null;
}

fn ruleOf(it: Id) ?Rule {
    return ruleFor(menu_bar, std.mem.span(objc.sel_getName(msg(Sel, it, "action", .{}))));
}

/// Whether setting `c` is on; a pick is on when its `tag` is the chosen one.
fn checked(c: Check, tag: usize) bool {
    return switch (c) {
        .wrap => conf.wrap,
        .pairs => conf.pairs,
        .sidebar => conf.sidebar,
        .line_numbers => conf.line_numbers,
        .typewriter => conf.typewriter,
        .zen => conf.zen,
        .late_night => conf.late_night,
        .focus => tag == @intFromEnum(conf.focus),
        .scheme => tag == conf.light_scheme or tag == conf.dark_scheme,
        .look => tag == @intFromEnum(conf.look),
        .show_hidden => conf.show_hidden,
        .language => langPicked(tag),
    };
}

/// Whether the key card's file shows in language `tag` of `syntax.languages`:
/// the one picked by hand, or the family's first name for a detected one.
fn langPicked(tag: usize) bool {
    const d = keyDoc() orelse return false;
    if (tag >= syntax.languages.len) return false;
    if (d.file.lang_i) |i| return tag == i;
    const l = syntax.languages[tag];
    return l.lang == d.file.lang and std.mem.eql(u8, l.name, syntax.nameOf(d.file.lang));
}

/// Whether a menu item shows a checkmark now, whether or not its menu was opened.
fn isChecked(it: Id) bool {
    const c = (ruleOf(it) orelse return false).check orelse return false;
    return checked(c, @intCast(msg(isize, it, "tag", .{})));
}

/// Whether Late-Night has set the command that `it` runs, so the menu greys it
/// and the palette leaves it out.
fn greyed(it: Id) bool {
    const r = ruleOf(it) orelse return false;
    return r.grey and conf.late_night;
}

/// What the menu's validation says: sets the checkmark and greys what
/// Late-Night has set, with a tooltip that says why and how to get it back.
pub fn validate(_: Id, _: Sel, it: Id) callconv(.c) bool {
    const r = ruleOf(it) orelse return true;
    if (r.check) |c| {
        const tag: usize = @intCast(msg(isize, it, "tag", .{}));
        msg(void, it, "setState:", .{@as(isize, @intFromBool(checked(c, tag)))});
        if (c == .scheme and tag < settings.schemes.len and msg(Id, it, "image", .{}) == null) {
            msg(void, it, "setImage:", .{swatch(settings.schemes[tag])});
        }
    }
    const off = r.grey and conf.late_night;
    if (r.grey) msg(void, it, "setToolTip:", .{if (off) objc.str(late_night_why) else @as(Id, null)});
    return !off;
}

/// The tooltip on the items Late-Night Focus greys.
const late_night_why = "Late-Night Focus sets this. Turn off Late-Night Focus (" ++ menuKeys("toggleLateNight:") ++ ") to change it.";

/// Registers the view class and loads the font. Call once at launch.
pub fn setup() void {
    readContrast();
    loadPlaces();
    conf_path = settings.path(gpa) catch null;
    resolveConf();
    if (conf_path) |p| settings.prepare(gpa, p);
    loadSettings();
    panelFonts();
    watchConf();
    const c = objc.ClassBuilder.begin("NSView", "ZeView");
    c.ivar("win");
    c.method("drawRect:", @ptrCast(&drawRect), "v@:{CGRect=dddd}");
    c.method("isFlipped", @ptrCast(&objc.yes), "c@:");
    c.method("isOpaque", @ptrCast(&objc.no), "c@:");
    // A see-through view lets AppKit move the window from anywhere under the
    // toolbar, tabs included; `titleStrip` moves it from the empty parts.
    c.method("mouseDownCanMoveWindow", @ptrCast(&objc.no), "c@:");
    c.method("acceptsFirstResponder", @ptrCast(&objc.yes), "c@:");
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
    c.method("view:stringForToolTip:point:userData:", @ptrCast(&toolTip), "@@:@q{CGPoint=dd}^v");
    c.method("viewDidChangeEffectiveAppearance", @ptrCast(&lookChanged), "v@:");
    c.method("windowDidBecomeKey:", @ptrCast(&keyChanged), "v@:@");
    c.method("windowDidResignKey:", @ptrCast(&keyChanged), "v@:@");
    c.method("windowDidExitFullScreen:", @ptrCast(&keyChanged), "v@:@");
    c.method("draggingEntered:", @ptrCast(&draggingEntered), "Q@:@");
    c.method("draggingExited:", @ptrCast(&draggingExited), "v@:@");
    c.method("draggingEnded:", @ptrCast(&draggingExited), "v@:@");
    c.method("performDragOperation:", @ptrCast(&performDrag), "c@:@");
    // A sidebar file dragged out to Finder.
    c.method("draggingSession:sourceOperationMaskForDraggingContext:", @ptrCast(&dragOutMask), "Q@:@q");
    _ = class_addProtocol(c.cls, objc_getProtocol("NSDraggingSource"));
    c.method("windowShouldClose:", @ptrCast(&windowShouldClose), "c@:@");
    c.method("windowWillClose:", @ptrCast(&windowWillClose), "v@:@");
    c.method("window:willUseFullScreenPresentationOptions:", @ptrCast(&fullScreenOptions), "Q@:@Q");
    c.method("retitle:", @ptrCast(&retitleNow), "v@:@");
    c.method("tick:", @ptrCast(&tick), "v@:@");
    c.method("holdRedraw:", @ptrCast(&holdRedraw), "v@:@");
    c.method("dragScroll:", @ptrCast(&dragScroll), "v@:@");
    c.method("saveDrafts:", @ptrCast(&saveDraftsNow), "v@:@");
    c.method("changeFont:", @ptrCast(&changeFont), "v@:@");
    c.method("menuForEvent:", @ptrCast(&menuForEvent), "@@:@");
    c.method("openInNewWindow:", @ptrCast(&openInNewWindow), "v@:@");
    c.method("openInNewTab:", @ptrCast(&openInNewTab), "v@:@");
    c.method("openInNewSplit:", @ptrCast(&openInNewSplit), "v@:@");
    c.method("tabClose:", tabAction(closeTab, .{}), "v@:@");
    c.method("tabCloseOthers:", tabAction(closeAround, .{ true, true }), "v@:@");
    c.method("tabCloseLeft:", tabAction(closeAround, .{ false, true }), "v@:@");
    c.method("tabCloseRight:", tabAction(closeAround, .{ true, false }), "v@:@");
    c.method("tabDuplicate:", tabAction(duplicateTab, .{}), "v@:@");
    c.method("tabNewWindow:", tabAction(tabOut, .{}), "v@:@");
    c.method("tabSplitRight:", tabAction(splitTab, .{Zone.right}), "v@:@");
    c.method("tabSplitDown:", tabAction(splitTab, .{Zone.bottom}), "v@:@");
    c.method("otherMouseDown:", @ptrCast(&otherMouseDown), "v@:@");
    c.method("endDissolve:", @ptrCast(&endDissolve), "v@:@");
    c.method("pickTab:", @ptrCast(&pickTab), "v@:@");
    c.method("pickLanguage:", @ptrCast(&pickLanguage), "v@:@");
    // The View menu's Language picks check the key card's language.
    c.method("validateMenuItem:", @ptrCast(&validate), "c@:@");
    c.method("menuDidClose:", @ptrCast(&menuDidClose), "v@:@");
    c.method("revealInFinder:", @ptrCast(&revealInFinder), "v@:@");
    c.method("sideParent:", @ptrCast(&sideParent), "v@:@");
    c.method("copyPath:", @ptrCast(&copyPath), "v@:@");
    c.method("copyRelativePath:", @ptrCast(&copyRelativePath), "v@:@");
    c.method("revealRoot:", @ptrCast(&revealRoot), "v@:@");
    c.method("openFolder:", @ptrCast(&openFolder), "v@:@");
    c.method("openRecentFolder:", @ptrCast(&openRecentFolder), "v@:@");
    c.method("sideNewFile:", @ptrCast(&sideNewFile), "v@:@");
    c.method("sideNewFolder:", @ptrCast(&sideNewFolder), "v@:@");
    c.method("sideRename:", @ptrCast(&sideRename), "v@:@");
    c.method("sideDuplicate:", @ptrCast(&sideDuplicate), "v@:@");
    c.method("sideTrash:", @ptrCast(&sideTrash), "v@:@");
    c.method("collapseAll:", @ptrCast(&collapseAll), "v@:@");
    c.method("runCommand:", @ptrCast(&runCommand), "v@:@");
    access.addViewMethods(c);
    bind(menu_bar, .view, c);
    view_class = c.finish();
    win_ivar = objc.ivarOffset(view_class, "win");
}

extern fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
extern fn class_addProtocol(cls: Id, protocol: ?*anyopaque) bool;
extern fn CTLineGetOffsetForStringIndex(line: Id, index: isize, secondary: ?*f64) f64;
extern fn CGContextClipToRects(ctx: Id, rects: [*]const Rect, count: usize) void;
extern "c" fn CGContextEOClip(ctx: Id) void;
extern "c" fn CGContextAddRect(ctx: Id, rect: Rect) void;
extern "c" fn CGContextDrawImage(ctx: Id, rect: Rect, image: Id) void;
