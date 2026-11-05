//! One window per file: an NSView subclass that draws the text with
//! CoreText glyph runs on a monospace grid, and turns key and mouse events
//! into editor commands. The bottom line is the status bar and the prompt
//! for find, go to line and quick open.
const std = @import("std");
const objc = @import("objc.zig");
const editor = @import("editor.zig");
const syntax = @import("syntax.zig");
const finder = @import("finder.zig");
const files = @import("files.zig");
const settings = @import("settings.zig");
const Editor = editor.Editor;
const Id = objc.Id;
const Sel = objc.Sel;
const Rect = objc.Rect;
const Point = objc.Point;
const msg = objc.msg;

pub const gpa = std.heap.c_allocator;
/// The folder quick open lists. Owned by gpa.
pub var root: ?[]const u8 = null;

const shift_key: usize = 1 << 17;
const cmd_key: usize = 1 << 20;
const ctrl_key: usize = 1 << 18;
const opt_key: usize = 1 << 19;

// ---- look ----

const Rgb = settings.Rgb;
const Theme = settings.Theme;

const pad_x = 28.0;
const top_h = 40.0;

/// Font, size, colors and toggles, from the settings file.
var conf: settings.Settings = .{};
var conf_path: ?[:0]u8 = null;
var conf_stamp: ?files.Stamp = null;
/// View menu items that show a checkmark, set by the menu builder.
pub var wrap_item: Id = null;
pub var pairs_item: Id = null;

var font: Id = null;
var bold: Id = null;
var cw: f64 = 8;
var lh: f64 = 22;
var baseline: f64 = 15;
var ascii: [2][95]u16 = undefined;
const Fallback = struct { font: Id, glyph: u16 };
var fallbacks: std.AutoHashMapUnmanaged(u21, Fallback) = .empty;

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
                const paint = if (kinds != null) th.kinds[@intFromEnum(kind)] else color;
                k.put(glyph(cp, kind == .keyword), paint, x + f(rel - skip) * cw, y);
            }
            col += c.w;
            i += c.len;
        }
        return (col - col0) -| skip;
    }
};

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

fn nscolor(c: Rgb) Id {
    return msg(Id, objc.class("NSColor"), "colorWithDeviceRed:green:blue:alpha:", .{ c[0], c[1], c[2], @as(f64, 1) });
}

// ---- motion ----

extern fn CACurrentMediaTime() f64;
extern const NSRunLoopCommonModes: Id;

/// A value that eases from where it is to a new target over `dur` seconds.
/// A display link redraws while any of them move.
const Tween = struct {
    from: f64 = 0,
    to: f64 = 0,
    t0: f64 = 0,
    dur: f64,

    fn at(w: Tween, now: f64) f64 {
        const q = 1 - std.math.clamp((now - w.t0) / w.dur, 0, 1);
        return w.to + (w.from - w.to) * q * q * q;
    }

    fn aim(w: *Tween, to: f64, now: f64) void {
        if (to == w.to) return;
        w.from = w.at(now);
        w.to = to;
        w.t0 = now;
    }

    fn snap(w: *Tween, to: f64) void {
        w.from = to;
        w.to = to;
    }

    fn moving(w: Tween, now: f64) bool {
        return w.from != w.to and now < w.t0 + w.dur;
    }
};

const scroll_time = 0.16;
const caret_time = 0.09;
const fade_time = 0.12;
const panel_time = 0.14;

/// Aims the caret. A new spot glides there; the same spot, a caret that was
/// hidden, or a mouse drag snaps. In the text the caret lives in page
/// coordinates, so it rides along with a gliding scroll.
fn placeCaret(d: *Doc, now: f64, x: f64, y: f64, in_text: bool, spot: [3]usize, show: bool) void {
    const moved = !std.mem.eql(usize, &spot, &d.spot);
    if (in_text != d.c_text) {
        const sign: f64 = if (in_text) 1 else -1;
        d.cx.snap(d.cx.at(now) + sign * d.vx);
        d.cy.snap(d.cy.at(now) + sign * d.vy);
        d.c_text = in_text;
    }
    if (moved and d.shown and show and !d.snap) {
        d.cx.aim(x, now);
        d.cy.aim(y, now);
    } else {
        d.cx.snap(x);
        d.cy.snap(y);
    }
    if (show and (moved or !d.shown)) blink(d.caret);
    d.spot = spot;
    d.shown = show;
    d.snap = false;
    moveCaret(d, now);
}

/// Puts the caret layer where its glide is at `now`, hidden outside the text.
fn moveCaret(d: *Doc, now: f64) void {
    var x = d.cx.at(now);
    var y = d.cy.at(now);
    if (d.c_text) {
        x -= d.vx;
        y -= d.vy;
    }
    const by = bounds(d).h - barH();
    const visible = d.shown and (!d.c_text or (x >= pad_x - 2 and y >= top_h - 8 and y + lh - 4 <= by));
    const t = objc.class("CATransaction");
    msg(void, t, "begin", .{});
    msg(void, t, "setDisableActions:", .{true});
    msg(void, d.caret, "setFrame:", .{Rect{ .x = x, .y = y, .w = 2, .h = lh - 4 }});
    msg(void, d.caret, "setHidden:", .{!visible});
    msg(void, t, "commit", .{});
}

/// Holds the caret solid for half a second, then fades it out and in.
fn blink(caret: Id) void {
    const num = objc.class("NSNumber");
    const a = msg(Id, objc.class("CABasicAnimation"), "animationWithKeyPath:", .{objc.str("opacity")});
    msg(void, a, "setFromValue:", .{msg(Id, num, "numberWithDouble:", .{@as(f64, 1)})});
    msg(void, a, "setToValue:", .{msg(Id, num, "numberWithDouble:", .{@as(f64, 0)})});
    msg(void, a, "setDuration:", .{@as(f64, 0.5)});
    msg(void, a, "setAutoreverses:", .{true});
    msg(void, a, "setRepeatCount:", .{std.math.inf(f32)});
    msg(void, a, "setBeginTime:", .{CACurrentMediaTime() + 0.5});
    msg(void, a, "setTimingFunction:", .{msg(Id, objc.class("CAMediaTimingFunction"), "functionWithName:", .{objc.str("easeInEaseOut")})});
    msg(void, caret, "addAnimation:forKey:", .{ a, objc.str("blink") });
}

/// True while scrolling, the line band, a selection fade or the quick open
/// list still has frames to draw.
fn scenery(d: *const Doc, now: f64) bool {
    return d.ys.moving(now) or d.xs.moving(now) or d.band.moving(now) or d.panel.moving(now) or (d.had_sel and now < d.sel_t0 + fade_time);
}

/// Display link callback: redraws while the scenery moves, otherwise just
/// moves the caret, and pauses once everything has settled.
fn tick(self: Id, _: Sel, _: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    if (d.busy) return msg(void, self, "setNeedsDisplay:", .{true});
    const now = CACurrentMediaTime();
    moveCaret(d, now);
    if (!d.cx.moving(now) and !d.cy.moving(now)) msg(void, d.link, "setPaused:", .{true});
}

// ---- documents ----

const Mode = enum { edit, find, line, open, replace };
const Drag = enum { char, word, line };

const Doc = struct {
    ed: Editor,
    /// Absolute path, or null while untitled.
    path: ?[:0]u8 = null,
    lang: *const syntax.Lang = &syntax.plain,
    window: Id = null,
    view: Id = null,
    /// Where scrolling is headed; vx and vy are where it shows right now.
    sx: f64 = 0,
    sy: f64 = 0,
    vx: f64 = 0,
    vy: f64 = 0,
    xs: Tween = .{ .dur = scroll_time },
    ys: Tween = .{ .dur = scroll_time },
    /// The caret line's band, in page coordinates.
    band: Tween = .{ .dur = caret_time },
    band_on: bool = false,
    had_sel: bool = false,
    sel_t0: f64 = 0,
    /// Height of the quick open list.
    panel: Tween = .{ .dur = panel_time },
    cx: Tween = .{ .dur = caret_time },
    cy: Tween = .{ .dur = caret_time },
    /// The caret tween is in page coordinates (else window coordinates).
    c_text: bool = true,
    /// The last draw had scenery still moving.
    busy: bool = false,
    link: Id = null,
    /// Soft wrap: the first screen row of each line, plus the total at the
    /// end, for rows `cols` cells wide.
    vfirst: std.ArrayList(u32) = .empty,
    cols: usize = 0,
    /// The file's change time and size when ze last read or wrote it.
    stamp: ?files.Stamp = null,
    mode: Mode = .edit,
    prompt: std.ArrayList(u8) = .empty,
    /// Find and replace: the replacement, and which field takes typing.
    with: std.ArrayList(u8) = .empty,
    which: u1 = 0,
    /// The prompt still shows its starting text; typing replaces it.
    fresh: bool = false,
    /// The last find, for find next and previous.
    query: std.ArrayList(u8) = .empty,
    /// Where the caret was when find opened.
    origin: usize = 0,
    found: [2]usize = .{ 0, 0 },
    list: ?finder.Files = null,
    picks: [10]usize = undefined,
    npicks: usize = 0,
    pick: usize = 0,
    /// A word for the status bar, cleared by the next key or click.
    note: []const u8 = "",
    drag: Drag = .char,
    drag_from: [2]usize = .{ 0, 0 },
    /// Syntax state at the start of each line, known for this many lines.
    states: std.ArrayList(syntax.State) = .empty,
    kinds: std.ArrayList(syntax.Kind) = .empty,
    dark: ?bool = null,
    /// The caret is a Core Animation layer, so its glide and blink run in
    /// the window server instead of redrawing the text.
    caret: Id = null,
    /// What the caret last stood for: mode, then row and column or prompt width.
    spot: [3]usize = .{ std.math.maxInt(usize), 0, 0 },
    shown: bool = false,
    /// Place the caret without gliding (mouse drags).
    snap: bool = false,

    fn name(d: *const Doc) []const u8 {
        return if (d.path) |p| std.fs.path.basename(p) else "untitled";
    }

    fn deinit(d: *Doc) void {
        d.ed.deinit(gpa);
        if (d.path) |p| gpa.free(p);
        if (d.list) |*l| l.deinit();
        d.prompt.deinit(gpa);
        d.with.deinit(gpa);
        d.query.deinit(gpa);
        d.states.deinit(gpa);
        d.kinds.deinit(gpa);
        d.vfirst.deinit(gpa);
    }
};

var docs: std.ArrayList(*Doc) = .empty;
var view_class: Id = null;
var doc_ivar: usize = 0;

fn docOf(self: Id) ?*Doc {
    const slot: *?*Doc = @ptrFromInt(@intFromPtr(self.?) + doc_ivar);
    return slot.*;
}

fn setDoc(self: Id, d: ?*Doc) void {
    const slot: *?*Doc = @ptrFromInt(@intFromPtr(self.?) + doc_ivar);
    slot.* = d;
}

fn bounds(d: *const Doc) Rect {
    return msg(Rect, d.view, "bounds", .{});
}

fn textH(d: *const Doc) f64 {
    return @max(bounds(d).h - top_h - barH(), lh);
}

fn pageLines(d: *const Doc) usize {
    return @max(@as(usize, @intFromFloat(textH(d) / lh)), 2) - 1;
}

/// Opens `path` (a file or a folder). Reuses `into` when it has no unsaved
/// changes, and brings a window forward when it already shows the file.
pub fn open(path: []const u8, into: ?*Doc) void {
    const abs = files.absolute(gpa, path) catch return;
    if (files.isDir(abs)) {
        if (root) |r| gpa.free(r);
        root = abs;
        const d = into orelse keyDoc() orelse newDoc() orelse return;
        startPrompt(d, .open);
        return;
    }
    defer gpa.free(abs);
    for (docs.items) |d| if (d.path != null and std.mem.eql(u8, d.path.?, abs)) {
        msg(void, d.window, "makeKeyAndOrderFront:", .{@as(Id, null)});
        return;
    };
    const bytes = files.read(gpa, abs) catch |err| switch (err) {
        error.FileNotFound => gpa.alloc(u8, 0) catch return,
        else => return alert("Couldn't open this file.", abs),
    };
    defer gpa.free(bytes);
    if (std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8000)], 0) != null) return alert("This looks like a binary file.", abs);
    const d = if (into) |t| (if (t.ed.buf.dirty()) newDoc() else t) else newDoc();
    const doc = d orelse return;
    const ed = Editor.init(gpa, bytes) catch return;
    rememberPlace(doc);
    doc.ed.deinit(gpa);
    doc.ed = ed;
    if (doc.path) |p| gpa.free(p);
    doc.path = gpa.dupeSentinel(u8, abs, 0) catch null;
    doc.lang = syntax.forPath(abs);
    doc.states.clearRetainingCapacity();
    doc.stamp = files.stamp(abs);
    doc.sx = 0;
    doc.sy = 0;
    doc.mode = .edit;
    if (placeOf(abs)) |pl| {
        var c = @min(pl.cur, bytes.len);
        while (c > 0 and c < bytes.len and bytes[c] & 0xC0 == 0x80) c -= 1;
        doc.ed.select(c, c);
        doc.sy = pl.sy;
    }
    doc.ys.snap(doc.sy);
    doc.xs.snap(0);
    doc.snap = true;
    noteRecent(abs);
    named(doc);
    msg(void, doc.window, "makeKeyAndOrderFront:", .{@as(Id, null)});
}

fn named(d: *Doc) void {
    msg(void, d.window, "setTitle:", .{objc.str(d.name())});
    if (d.path) |p| msg(void, d.window, "setRepresentedFilename:", .{objc.str(p)});
    refresh(d);
}

pub fn keyDoc() ?*Doc {
    const w = msg(Id, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "keyWindow", .{});
    for (docs.items) |d| if (d.window == w) return d;
    return null;
}

/// A doc nothing has been typed into, for a file to open into.
pub fn blankDoc() ?*Doc {
    const d = keyDoc() orelse return null;
    return if (d.path == null and d.ed.text().len == 0) d else null;
}

pub fn count() usize {
    return docs.items.len;
}

pub fn newDoc() ?*Doc {
    const d = gpa.create(Doc) catch return null;
    d.* = .{ .ed = Editor.init(gpa, "") catch return null };
    docs.append(gpa, d) catch return null;

    const frame: Rect = .{ .w = 880, .h = 720 };
    const style: usize = 1 | 2 | 4 | 8 | (1 << 15);
    const win = msg(Id, msg(Id, objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ frame, style, @as(usize, 2), false });
    const view = msg(Id, msg(Id, view_class, "alloc", .{}), "initWithFrame:", .{frame});
    setDoc(view, d);
    d.window = win;
    d.view = view;
    msg(void, view, "setWantsLayer:", .{true});
    d.caret = msg(Id, objc.class("CALayer"), "layer", .{});
    msg(void, d.caret, "setCornerRadius:", .{@as(f64, 1)});
    msg(void, d.caret, "setHidden:", .{true});
    msg(void, msg(Id, view, "layer", .{}), "addSublayer:", .{d.caret});
    d.link = msg(Id, view, "displayLinkWithTarget:selector:", .{ view, objc.sel_registerName("tick:") });
    msg(void, d.link, "addToRunLoop:forMode:", .{ msg(Id, objc.class("NSRunLoop"), "mainRunLoop", .{}), NSRunLoopCommonModes });
    msg(void, d.link, "setPaused:", .{true});
    msg(void, win, "setTitlebarAppearsTransparent:", .{true});
    msg(void, win, "setTitleVisibility:", .{@as(isize, 1)});
    msg(void, win, "setMinSize:", .{Point{ .x = 360, .y = 240 }});
    msg(void, win, "setContentView:", .{view});
    msg(void, view, "release", .{});
    msg(void, win, "setDelegate:", .{view});
    msg(void, win, "makeFirstResponder:", .{view});
    if (docs.items.len == 1) {
        msg(void, win, "center", .{});
        _ = msg(bool, win, "setFrameAutosaveName:", .{objc.str("ze")});
    } else {
        const fr = msg(Rect, docs.items[docs.items.len - 2].window, "frame", .{});
        msg(void, win, "setFrame:display:", .{ fr, false });
        msg(void, win, "setFrameTopLeftPoint:", .{Point{ .x = fr.x + 24, .y = fr.y + fr.h - 24 }});
    }
    named(d);
    msg(void, win, "makeKeyAndOrderFront:", .{@as(Id, null)});
    return d;
}

fn alert(text: []const u8, detail: []const u8) void {
    const a = objc.new("NSAlert");
    msg(void, a, "setMessageText:", .{objc.str(text)});
    msg(void, a, "setInformativeText:", .{objc.str(detail)});
    _ = msg(isize, a, "runModal", .{});
    msg(void, a, "release", .{});
}

/// Asks to save unsaved changes. False when the user cancels.
fn settle(d: *Doc) bool {
    if (!d.ed.buf.dirty()) return true;
    msg(void, d.window, "makeKeyAndOrderFront:", .{@as(Id, null)});
    const a = objc.new("NSAlert");
    var buf: [300]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Save changes to {s}?", .{d.name()}) catch "Save changes?";
    msg(void, a, "setMessageText:", .{objc.str(title)});
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

/// For quitting: every window with unsaved changes asks first.
pub fn settleAll() bool {
    for (docs.items) |d| if (!settle(d)) return false;
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
        if (d.path) |old| gpa.free(old);
        d.path = z;
        d.lang = syntax.forPath(z);
        d.states.clearRetainingCapacity();
        named(d);
    }
    files.write(d.path.?, d.ed.text()) catch {
        alert("Couldn't save this file.", d.path.?);
        return false;
    };
    d.ed.buf.markSaved();
    d.stamp = files.stamp(d.path.?);
    d.note = "saved";
    noteRecent(d.path.?);
    if (conf_path != null and std.mem.eql(u8, d.path.?, conf_path.?)) loadSettings();
    refresh(d);
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

/// Remembers where the caret and scroll were in `d`'s file, newest first.
fn rememberPlace(d: *const Doc) void {
    const p = d.path orelse return;
    const ud = defaults();
    const old = msg(Id, ud, "stringArrayForKey:", .{objc.str("places")});
    const out = msg(Id, objc.class("NSMutableArray"), "array", .{});
    var buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "{d}\t{d}\t", .{ d.ed.cur, @as(i64, @intFromFloat(d.sy)) }) catch return;
    const entry = std.mem.concat(gpa, u8, &.{ head, p }) catch return;
    defer gpa.free(entry);
    msg(void, out, "addObject:", .{objc.str(entry)});
    const n = if (old != null) msg(usize, old, "count", .{}) else 0;
    for (0..n) |i| {
        if (msg(usize, out, "count", .{}) >= 100) break;
        const s = msg(Id, old, "objectAtIndex:", .{i});
        const fs = fields(objc.utf8(s), 2) orelse continue;
        if (!std.mem.eql(u8, fs[2], p)) msg(void, out, "addObject:", .{s});
    }
    msg(void, ud, "setObject:forKey:", .{ out, objc.str("places") });
}

fn placeOf(p: []const u8) ?Place {
    const list = msg(Id, defaults(), "stringArrayForKey:", .{objc.str("places")});
    if (list == null) return null;
    for (0..msg(usize, list, "count", .{})) |i| {
        const fs = fields(objc.utf8(msg(Id, list, "objectAtIndex:", .{i})), 2) orelse continue;
        if (!std.mem.eql(u8, fs[2], p)) continue;
        return .{
            .cur = std.fmt.parseInt(usize, fs[0], 10) catch 0,
            .sy = @floatFromInt(std.fmt.parseInt(i64, fs[1], 10) catch 0),
        };
    }
    return null;
}

/// On quit: every window's file and frame, back to front, for next launch.
pub fn saveSession() void {
    for (docs.items) |d| rememberPlace(d);
    const out = msg(Id, objc.class("NSMutableArray"), "array", .{});
    const wins = msg(Id, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "orderedWindows", .{});
    var i = msg(usize, wins, "count", .{});
    while (i > 0) {
        i -= 1;
        const w = msg(Id, wins, "objectAtIndex:", .{i});
        for (docs.items) |d| if (d.window == w and d.path != null) {
            const frame = objc.utf8(msg(Id, w, "stringWithSavedFrame", .{}));
            const entry = std.mem.concat(gpa, u8, &.{ frame, "\t", d.path.? }) catch continue;
            defer gpa.free(entry);
            msg(void, out, "addObject:", .{objc.str(entry)});
        };
    }
    msg(void, defaults(), "setObject:forKey:", .{ out, objc.str("session") });
}

/// Reopens last session's windows where they were. False when none opened.
pub fn restoreSession() bool {
    const list = msg(Id, defaults(), "stringArrayForKey:", .{objc.str("session")});
    if (list == null) return false;
    for (0..msg(usize, list, "count", .{})) |i| {
        const fs = fields(objc.utf8(msg(Id, list, "objectAtIndex:", .{i})), 1) orelse continue;
        const p = gpa.dupeSentinel(u8, fs[1], 0) catch continue;
        defer gpa.free(p);
        if (!files.exists(p)) continue;
        open(p, blankDoc());
        for (docs.items) |d| if (d.path != null and std.mem.eql(u8, d.path.?, p)) {
            msg(void, d.window, "setFrameFromString:", .{objc.str(fs[0])});
        };
    }
    return docs.items.len > 0;
}

// ---- changes from outside ----

fn sameStamp(a: ?files.Stamp, b: ?files.Stamp) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

/// When ze comes forward: picks up settings and files that other apps changed.
pub fn recheckAll() void {
    if (conf_path) |p| if (!sameStamp(files.stamp(p), conf_stamp)) loadSettings();
    for (docs.items) |d| checkOutside(d);
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
    conf = settings.load(gpa, p);
    conf_stamp = files.stamp(p);
    setFont();
    if (wrap_item != null) msg(void, wrap_item, "setState:", .{@as(isize, @intFromBool(conf.wrap))});
    if (pairs_item != null) msg(void, pairs_item, "setState:", .{@as(isize, @intFromBool(conf.pairs))});
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

// ---- prompt ----

fn startPrompt(d: *Doc, m: Mode) void {
    d.mode = m;
    d.prompt.clearRetainingCapacity();
    d.fresh = false;
    d.note = "";
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
                root = gpa.dupe(u8, std.fs.path.dirname(p) orelse "/") catch return;
                break :blk root.?;
            };
            d.list = finder.scan(gpa, r) catch null;
            pickFiles(d);
        },
        else => {},
    }
    refresh(d);
}

fn pickFiles(d: *Doc) void {
    const l = d.list orelse return;
    d.npicks = finder.best(l.paths.items, d.prompt.items, &d.picks);
    d.pick = 0;
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
        .open => pickFiles(d),
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
            d.mode = .edit;
            if (d.npicks == 0) return;
            const rel = d.list.?.paths.items[d.picks[d.pick]];
            var buf: [std.c.PATH_MAX]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root.?, rel }) catch return;
            open(path, d);
        },
        .replace => {
            remember(d);
            d.fresh = false;
            const s = d.ed.sel();
            const replaced = d.ed.replaceOne(gpa, q, d.with.items) catch false;
            _ = d.ed.find(q, if (replaced) d.ed.cur else s[0], false);
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
    const n = d.ed.replaceAll(gpa, d.prompt.items, d.with.items) catch 0;
    d.mode = .edit;
    d.note = std.fmt.bufPrint(&note_buf, "replaced {d}", .{n}) catch "";
    center(d);
}

fn findAgain(d: *Doc, back: bool) void {
    const finding = d.mode == .find or d.mode == .replace;
    const q = if (finding) d.prompt.items else d.query.items;
    if (q.len == 0) return startPrompt(d, .find);
    const s = d.ed.sel();
    if (!d.ed.find(q, if (back) s[0] else s[0] + 1, back)) d.note = "no matches";
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
    } else if (d.mode == .open and (is(name, "moveUp") or is(name, "moveDown"))) {
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

fn wrapCols(d: *const Doc) usize {
    return @max(@as(usize, @intFromFloat((bounds(d).w - 2 * pad_x) / cw)), 8);
}

/// Brings the row counts up to date after edits, a resize or a font change.
fn layout(d: *Doc) void {
    const b = &d.ed.buf;
    if (!conf.wrap) {
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
    return if (conf.wrap) d.vfirst.items[d.vfirst.items.len - 1] else d.ed.buf.lines();
}

fn rowOfLine(d: *const Doc, i: usize) usize {
    return if (conf.wrap) d.vfirst.items[i] else i;
}

fn lineOfRow(d: *const Doc, r: usize) usize {
    if (!conf.wrap) return @min(r, d.ed.buf.lines() - 1);
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
    if (!conf.wrap) return .{ .end = l.len };
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

fn clampScroll(d: *Doc) void {
    d.sy = std.math.clamp(d.sy, 0, @max(0, f(totalRows(d)) * lh - textH(d) / 2));
    d.sx = if (conf.wrap) 0 else @max(d.sx, 0);
}

/// Scrolls just enough to show the caret.
fn reveal(d: *Doc) void {
    const c = caretRow(d);
    const y = f(c.row) * lh;
    const th = textH(d);
    if (y < d.sy) d.sy = y;
    if (y + lh > d.sy + th) d.sy = y + lh - th;
    if (!conf.wrap) {
        const x = f(c.col) * cw;
        const tw = bounds(d).w - 2 * pad_x;
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

fn refresh(d: *Doc) void {
    msg(void, d.view, "setNeedsDisplay:", .{true});
    msg(void, d.window, "setDocumentEdited:", .{d.ed.buf.dirty()});
}

// ---- drawing ----

fn syncStates(d: *Doc, upto: usize) void {
    const b = &d.ed.buf;
    if (b.touched < d.states.items.len) d.states.shrinkRetainingCapacity(b.touched + 1);
    b.touched = std.math.maxInt(usize);
    if (d.lang == &syntax.plain) return;
    if (d.states.items.len == 0) d.states.append(gpa, .normal) catch return;
    while (d.states.items.len <= upto and d.states.items.len < b.lines()) {
        const i = d.states.items.len - 1;
        d.states.append(gpa, syntax.lexLine(d.lang, b.line(i), d.states.items[i], null)) catch return;
    }
}

fn isDark(view: Id) bool {
    const name = objc.utf8(msg(Id, msg(Id, view, "effectiveAppearance", .{}), "name", .{}));
    return std.mem.indexOf(u8, name, "Dark") != null;
}

const VRow = struct { line: usize, seg: Seg };

fn draw(d: *Doc, ctx: Id) void {
    const now = CACurrentMediaTime();
    const dark = isDark(d.view);
    const th = if (dark) &conf.dark else &conf.light;
    if (d.dark != dark) {
        d.dark = dark;
        msg(void, d.window, "setBackgroundColor:", .{nscolor(th.bg)});
        msg(void, d.caret, "setBackgroundColor:", .{msg(Id, nscolor(th.caret), "CGColor", .{})});
    }
    const r = bounds(d);
    const b = &d.ed.buf;
    layout(d);
    clampScroll(d);
    // Keys and jumps glide the scroll; the trackpad and live resizing snap it.
    if (msg(bool, d.view, "inLiveResize", .{})) {
        d.ys.snap(d.sy);
        d.xs.snap(d.sx);
    }
    d.ys.aim(d.sy, now);
    d.xs.aim(d.sx, now);
    d.vy = d.ys.at(now);
    d.vx = d.xs.at(now);
    fill(ctx, th.bg, 0, 0, r.w, r.h);
    objc.flipText(ctx);

    const total = totalRows(d);
    const last = @min(total, @as(usize, @intFromFloat(@max(@ceil((d.vy + textH(d)) / lh), 0))) + 1);
    const first: usize = @min(@as(usize, @intFromFloat(@max(@floor(d.vy / lh), 0))), last);
    const skip: usize = @intFromFloat(@max(@ceil(d.vx / cw), 0));
    const ox = pad_x + f(skip) * cw - d.vx;
    const cols: usize = @intFromFloat(@ceil((r.w - ox) / cw));
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

    // The caret line's band slides after the caret.
    const band_on = d.mode == .edit and s[0] == s[1];
    if (band_on and d.band_on) d.band.aim(f(here.row) * lh, now) else d.band.snap(f(here.row) * lh);
    d.band_on = band_on;
    if (band_on) fill(ctx, th.line, 0, top_h + d.band.at(now) - d.vy, r.w, lh);

    // A new selection fades in.
    const has_sel = s[0] != s[1];
    if (has_sel and !d.had_sel) d.sel_t0 = now;
    d.had_sel = has_sel;
    const fade = std.math.clamp((now - d.sel_t0) / fade_time, 0, 1);
    const sel_a = 1 - (1 - fade) * (1 - fade) * (1 - fade);

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
        if (has_sel and s[0] <= ls + l.len and s[1] > ls) {
            const lo = std.math.clamp(@max(s[0], ls) - ls, sg.start, sg.end);
            const hi = std.math.clamp(@min(s[1], ls + l.len) - ls, sg.start, sg.end);
            const tail: f64 = if (s[1] > ls + l.len and sg.end == l.len) 0.6 * cw else 0;
            const x0 = xat(l, sg, lo, ox, skip);
            const w = xat(l, sg, hi, ox, skip) - x0 + tail;
            if (w > 0) fillA(ctx, th.sel, sel_a, x0, y, w, lh);
        }
        if (finding) {
            const q = d.prompt.items;
            var j = sg.start -| (q.len - 1);
            while (j < sg.end and j + q.len <= l.len) : (j += 1) if (editor.matchAt(l, j, q)) {
                const lo = @max(j, sg.start);
                const hi = @min(j + q.len, sg.end);
                if (lo < hi and ls + j != s[0]) {
                    const x0 = xat(l, sg, lo, ox, skip);
                    fill(ctx, th.match, x0, y + 2, xat(l, sg, hi, ox, skip) - x0, lh - 4);
                }
                j += q.len - 1;
            };
        }
    }

    // Text.
    var k: Ink = .{ .ctx = ctx };
    var lexed: usize = std.math.maxInt(usize);
    var kinds: ?[]const syntax.Kind = null;
    for (vis[0..nvis], first..) |v, row| {
        const l = b.line(v.line);
        if (v.line != lexed) {
            lexed = v.line;
            kinds = null;
            if (d.lang != &syntax.plain and v.line < d.states.items.len) {
                if (d.kinds.items.len < l.len) d.kinds.resize(gpa, l.len) catch {};
                if (d.kinds.items.len >= l.len) {
                    _ = syntax.lexLine(d.lang, l, d.states.items[v.line], d.kinds.items[0..l.len]);
                    kinds = d.kinds.items[0..l.len];
                }
            }
        }
        _ = k.run(l, v.seg.start, v.seg.end, v.seg.col, kinds, th, th.fg, ox, top_h + f(row) * lh - d.vy + baseline, skip, cols);
    }
    k.flush();

    // The caret only shows in the key window.
    const by = r.h - barH();
    const key = msg(bool, d.window, "isKeyWindow", .{});
    if (d.mode == .edit) {
        placeCaret(d, now, pad_x + f(here.col) * cw - 1, top_h + f(here.row) * lh + 2, true, .{ 0, here.row, here.col }, key);
    }

    // The band under the title bar, the quick open list, and the status bar.
    fill(ctx, th.bg, 0, 0, r.w, top_h - 8);
    const ty = by + 6 + baseline;
    const want_ph: f64 = if (d.mode == .open and d.list != null) f(d.npicks) * lh + 12 else 0;
    d.panel.aim(want_ph, now);
    const ph = d.panel.at(now);
    if (ph > 0.5 and d.list != null) {
        // The list rises out of the bottom line, rows riding its top edge.
        objc.CGContextSaveGState(ctx);
        objc.CGContextClipToRect(ctx, .{ .x = 0, .y = by - ph, .w = r.w, .h = ph });
        fill(ctx, th.panel, 0, by - ph, r.w, ph);
        fill(ctx, th.rule, 0, by - ph, r.w, 1);
        for (d.picks[0..d.npicks], 0..) |p, i| {
            const y = by - ph + 6 + f(i) * lh;
            if (i == d.pick) fill(ctx, th.sel, 0, y, r.w, lh);
            const path = d.list.?.paths.items[p];
            const slash = if (std.mem.lastIndexOfScalar(u8, path, '/')) |j| j + 1 else 0;
            const n = k.text(path[slash..], null, th, th.fg, pad_x, y + baseline, 0, 200);
            _ = k.text(path[0..slash], null, th, th.muted, pad_x + f(n + 2) * cw, y + baseline, 0, 200);
        }
        k.flush();
        objc.CGContextRestoreGState(ctx);
    }
    fill(ctx, th.bg, 0, by, r.w, barH());
    fill(ctx, th.rule, 0, by, r.w, 1);
    var buf: [64]u8 = undefined;
    var right: []const u8 = "";
    var x: f64 = pad_x;
    if (d.mode == .edit) {
        x += f(k.text(d.name(), null, th, th.fg, x, ty, 0, 200)) * cw;
        if (b.dirty()) x += f(k.text(" •", null, th, th.caret, x, ty, 0, 4)) * cw;
        if (d.note.len > 0) _ = k.text(d.note, null, th, th.muted, x + 2 * cw, ty, 0, 200);
        const li = b.lineOf(d.ed.cur);
        const col = editor.colOf(b.line(li), d.ed.cur - b.lineStart(li));
        right = std.fmt.bufPrint(&buf, "{d}:{d}", .{ li + 1, col + 1 }) catch "";
    } else {
        const label = switch (d.mode) {
            .find, .replace => "find",
            .line => "line",
            else => "open",
        };
        x += f(k.text(label, null, th, th.caret, x, ty, 0, 8) + 1) * cw;
        if (d.fresh) {
            k.flush();
            fill(ctx, th.sel, x, by + 6, f(editor.colOf(d.prompt.items, d.prompt.items.len)) * cw, lh);
        }
        x += f(k.text(d.prompt.items, null, th, th.fg, x, ty, 0, 400)) * cw;
        var cx = x;
        if (d.mode == .replace) {
            x += 2 * cw;
            x += f(k.text("with", null, th, th.caret, x, ty, 0, 8) + 1) * cw;
            x += f(k.text(d.with.items, null, th, th.fg, x, ty, 0, 400)) * cw;
            if (d.which == 1) cx = x;
        }
        k.flush();
        const width = if (d.which == 1 and d.mode == .replace) d.with.items.len else d.prompt.items.len;
        placeCaret(d, now, cx, by + 8, false, .{ 1 + @intFromEnum(d.mode) * 2 + d.which, width, 0 }, key);
        if (finding) right = if (d.found[1] == 0) "no matches" else std.fmt.bufPrint(&buf, "{d} of {d}", .{ @min(d.found[0], d.found[1]), d.found[1] }) catch "";
        if (d.mode == .open and d.list != null) right = std.fmt.bufPrint(&buf, "{d} files", .{d.list.?.paths.items.len}) catch "";
    }
    _ = k.text(right, null, th, th.muted, r.w - pad_x - f(right.len) * cw, ty, 0, 64);
    k.flush();

    d.busy = scenery(d, now);
    if (d.busy or d.cx.moving(now) or d.cy.moving(now)) msg(void, d.link, "setPaused:", .{false});
}

// ---- NSView methods ----

fn drawRect(self: Id, _: Sel, _: Rect) callconv(.c) void {
    const d = docOf(self) orelse return;
    const gc = msg(Id, objc.class("NSGraphicsContext"), "currentContext", .{});
    draw(d, msg(Id, gc, "CGContext", .{}));
}

fn yes(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

fn keyDown(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    d.note = "";
    const flags = msg(usize, ev, "modifierFlags", .{});
    const code = msg(u16, ev, "keyCode", .{});
    // ⌥Z for Soft Wrap: menus only see option keys after the text has typed them.
    if (flags & (cmd_key | opt_key | ctrl_key) == opt_key and code == 6) return toggleWrap();
    // Command keys that the menu didn't take: only arrows and delete mean something.
    if (flags & cmd_key != 0) {
        if (std.mem.indexOfScalar(u16, &.{ 51, 117, 115, 119, 123, 124, 125, 126 }, code) == null) return;
    }
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
        if (conf.wrap) switch (m[1]) {
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
    const x = @max((p.x - pad_x + d.vx) / cw, 0);
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

fn mouseDown(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    const p = local(self, ev);
    const by = bounds(d).h - barH();
    d.note = "";
    if (d.mode == .open and d.list != null) {
        const top = by - f(d.npicks) * lh - 6;
        if (p.y >= top and p.y < by) {
            d.pick = @min(@as(usize, @intFromFloat((p.y - top) / lh)), d.npicks -| 1);
            accept(d);
            return refresh(d);
        }
    }
    if (p.y >= by) return;
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

fn mouseDragged(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    d.snap = true;
    const p = local(self, ev);
    if (p.y < top_h) d.sy -= lh;
    if (p.y > bounds(d).h - barH()) d.sy += lh;
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

fn scrollWheel(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    var dx = msg(f64, ev, "scrollingDeltaX", .{});
    var dy = msg(f64, ev, "scrollingDeltaY", .{});
    if (!msg(bool, ev, "hasPreciseScrollingDeltas", .{})) {
        dx *= lh;
        dy *= lh;
    }
    d.sx -= dx;
    d.sy -= dy;
    clampScroll(d);
    d.ys.snap(d.sy);
    d.xs.snap(d.sx);
    refresh(d);
}

fn resetCursorRects(self: Id, _: Sel) callconv(.c) void {
    msg(void, self, "addCursorRect:cursor:", .{ msg(Rect, self, "bounds", .{}), msg(Id, objc.class("NSCursor"), "IBeamCursor", .{}) });
}

/// Also the window delegate's key and resign key calls, so the caret shows
/// only in the key window.
fn appearanceChanged(self: Id, _: Sel) callconv(.c) void {
    msg(void, self, "setNeedsDisplay:", .{true});
}

fn windowShouldClose(self: Id, _: Sel, _: Id) callconv(.c) bool {
    const d = docOf(self) orelse return true;
    return settle(d);
}

fn windowWillClose(self: Id, _: Sel, _: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
    rememberPlace(d);
    msg(void, d.link, "invalidate", .{});
    setDoc(self, null);
    msg(void, d.window, "setDelegate:", .{@as(Id, null)});
    for (docs.items, 0..) |x, i| if (x == d) {
        _ = docs.orderedRemove(i);
        break;
    };
    d.deinit();
    gpa.destroy(d);
}

// ---- menu actions ----

fn action(comptime run: fn (*Doc) void) *const anyopaque {
    return @ptrCast(&struct {
        fn imp(self: Id, _: Sel, _: Id) callconv(.c) void {
            const d = docOf(self) orelse return;
            d.note = "";
            run(d);
            refresh(d);
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
    d.ed.insert(gpa, s) catch {};
    reveal(d);
}

fn selectAll(d: *Doc) void {
    if (d.mode == .edit) d.ed.selectAll();
}

fn undo(d: *Doc) void {
    d.mode = .edit;
    d.ed.undo(gpa) catch {};
    reveal(d);
}

fn redo(d: *Doc) void {
    d.mode = .edit;
    d.ed.redo(gpa) catch {};
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
    loadSettings();
    const c = objc.ClassBuilder.begin("NSView", "ZeView");
    c.ivar("doc");
    c.method("drawRect:", @ptrCast(&drawRect), "v@:{CGRect=dddd}");
    c.method("isFlipped", @ptrCast(&yes), "c@:");
    c.method("isOpaque", @ptrCast(&yes), "c@:");
    c.method("acceptsFirstResponder", @ptrCast(&yes), "c@:");
    c.method("keyDown:", @ptrCast(&keyDown), "v@:@");
    c.method("insertText:", @ptrCast(&insertText), "v@:@");
    c.method("doCommandBySelector:", @ptrCast(&doCommand), "v@::");
    c.method("mouseDown:", @ptrCast(&mouseDown), "v@:@");
    c.method("mouseDragged:", @ptrCast(&mouseDragged), "v@:@");
    c.method("scrollWheel:", @ptrCast(&scrollWheel), "v@:@");
    c.method("resetCursorRects", @ptrCast(&resetCursorRects), "v@:");
    c.method("viewDidChangeEffectiveAppearance", @ptrCast(&appearanceChanged), "v@:");
    c.method("windowDidBecomeKey:", @ptrCast(&appearanceChanged), "v@:@");
    c.method("windowDidResignKey:", @ptrCast(&appearanceChanged), "v@:@");
    c.method("windowShouldClose:", @ptrCast(&windowShouldClose), "c@:@");
    c.method("windowWillClose:", @ptrCast(&windowWillClose), "v@:@");
    c.method("tick:", @ptrCast(&tick), "v@:@");
    c.method("changeFont:", @ptrCast(&changeFont), "v@:@");
    const actions = .{
        .{ "copy:", copy },             .{ "cut:", cut },               .{ "paste:", paste },
        .{ "selectAll:", selectAll },   .{ "undo:", undo },             .{ "redo:", redo },
        .{ "saveDocument:", saveDoc },      .{ "saveDocumentAs:", saveAs }, .{ "findText:", find },
        .{ "findNext:", findNext },         .{ "findPrevious:", findPrev }, .{ "gotoLine:", gotoLine },
        .{ "quickOpen:", quickOpen },       .{ "toggleComment:", comment }, .{ "zoomIn:", zoomIn },
        .{ "zoomOut:", zoomOut },           .{ "zoomReset:", zoomReset },   .{ "findAndReplace:", findReplace },
    };
    inline for (actions) |a| c.method(a[0], action(a[1]), "v@:@");
    view_class = c.finish();
    doc_ivar = objc.ivarOffset(view_class, "doc");
}
