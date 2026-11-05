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

// ---- look ----

const Rgb = [3]f64;

fn rgb(comptime hex: u24) Rgb {
    return .{ @as(f64, @floatFromInt(hex >> 16)) / 255, @as(f64, @floatFromInt((hex >> 8) & 0xff)) / 255, @as(f64, @floatFromInt(hex & 0xff)) / 255 };
}

const Theme = struct {
    bg: Rgb,
    fg: Rgb,
    muted: Rgb,
    /// Indexed by syntax.Kind.
    kinds: [5]Rgb,
    sel: Rgb,
    line: Rgb,
    caret: Rgb,
    match: Rgb,
    panel: Rgb,
    rule: Rgb,
};

/// Warm paper in light mode, ink in dark mode.
const paper: Theme = .{
    .bg = rgb(0xF5F2EA),
    .fg = rgb(0x2E2C28),
    .muted = rgb(0x9A958A),
    .kinds = .{ rgb(0x2E2C28), rgb(0x9C3D26), rgb(0x4F7A3A), rgb(0xA39E92), rgb(0xA8642A) },
    .sel = rgb(0xE3D9BF),
    .line = rgb(0xEFEADF),
    .caret = rgb(0xE8590C),
    .match = rgb(0xF2D98A),
    .panel = rgb(0xECE7DB),
    .rule = rgb(0xDDD6C7),
};

const ink: Theme = .{
    .bg = rgb(0x17171B),
    .fg = rgb(0xD9D4C7),
    .muted = rgb(0x6E6A61),
    .kinds = .{ rgb(0xD9D4C7), rgb(0xF08A6C), rgb(0xA7C080), rgb(0x6A665E), rgb(0xE8B86B) },
    .sel = rgb(0x34343E),
    .line = rgb(0x1E1E24),
    .caret = rgb(0xFF8A3D),
    .match = rgb(0x5A4A24),
    .panel = rgb(0x202027),
    .rule = rgb(0x2A2A31),
};

const pad_x = 28.0;
const top_h = 40.0;
const default_size = 14.0;

var font: Id = null;
var bold: Id = null;
var font_size: f64 = default_size;
var cw: f64 = 8;
var lh: f64 = 22;
var baseline: f64 = 15;
var ascii: [2][95]u16 = undefined;
const Fallback = struct { font: Id, glyph: u16 };
var fallbacks: std.AutoHashMapUnmanaged(u21, Fallback) = .empty;

fn barH() f64 {
    return lh + 12;
}

fn setFont(size: f64) void {
    font_size = std.math.clamp(size, 8, 40);
    if (font != null) _ = msg(void, font, "release", .{});
    if (bold != null) _ = msg(void, bold, "release", .{});
    const NSFont = objc.class("NSFont");
    font = msg(Id, msg(Id, NSFont, "monospacedSystemFontOfSize:weight:", .{ font_size, @as(f64, 0) }), "retain", .{});
    bold = msg(Id, msg(Id, NSFont, "monospacedSystemFontOfSize:weight:", .{ font_size, @as(f64, 0.3) }), "retain", .{});
    var chars: [95]u16 = undefined;
    for (&chars, 0..) |*ch, i| ch.* = @intCast(0x20 + i);
    _ = objc.CTFontGetGlyphsForCharacters(font, &chars, &ascii[0], 95);
    _ = objc.CTFontGetGlyphsForCharacters(bold, &chars, &ascii[1], 95);
    const zero = [1]u16{ascii[0]['0' - 0x20]};
    cw = objc.CTFontGetAdvancesForGlyphs(font, 0, &zero, null, 1);
    const asc = objc.CTFontGetAscent(font);
    const desc = objc.CTFontGetDescent(font);
    lh = @round(font_size * 1.6);
    baseline = @round((lh - asc - desc) / 2 + asc);
    var it = fallbacks.valueIterator();
    while (it.next()) |fb| if (fb.font != font) objc.CFRelease(fb.font.?);
    fallbacks.clearRetainingCapacity();
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
        var col: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const c = editor.cells(s, i, col);
            if (col >= skip + max) break;
            if (col >= skip and s[i] >= 0x20 and s[i] != 0x7f) {
                const cp: u21 = if (s[i] < 0x80) s[i] else editor.decode(s, i).cp;
                const kind: syntax.Kind = if (kinds) |ks| ks[i] else .text;
                const paint = if (kinds != null) th.kinds[@intFromEnum(kind)] else color;
                k.put(glyph(cp, kind == .keyword), paint, x + f(col - skip) * cw, y);
            }
            col += c.w;
            i += c.len;
        }
        return col -| skip;
    }
};

fn f(n: usize) f64 {
    return @floatFromInt(n);
}

fn fill(ctx: Id, c: Rgb, x: f64, y: f64, w: f64, h: f64) void {
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], 1);
    objc.CGContextFillRect(ctx, .{ .x = x, .y = y, .w = w, .h = h });
}

// ---- documents ----

const Mode = enum { edit, find, line, open };
const Drag = enum { char, word, line };

const Doc = struct {
    ed: Editor,
    /// Absolute path, or null while untitled.
    path: ?[:0]u8 = null,
    lang: *const syntax.Lang = &syntax.plain,
    window: Id = null,
    view: Id = null,
    sx: f64 = 0,
    sy: f64 = 0,
    mode: Mode = .edit,
    prompt: std.ArrayList(u8) = .empty,
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

    fn name(d: *const Doc) []const u8 {
        return if (d.path) |p| std.fs.path.basename(p) else "untitled";
    }

    fn deinit(d: *Doc) void {
        d.ed.deinit(gpa);
        if (d.path) |p| gpa.free(p);
        if (d.list) |*l| l.deinit();
        d.prompt.deinit(gpa);
        d.query.deinit(gpa);
        d.states.deinit(gpa);
        d.kinds.deinit(gpa);
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
    doc.ed.deinit(gpa);
    doc.ed = ed;
    if (doc.path) |p| gpa.free(p);
    doc.path = gpa.dupeSentinel(u8, abs, 0) catch null;
    doc.lang = syntax.forPath(abs);
    doc.states.clearRetainingCapacity();
    doc.sx = 0;
    doc.sy = 0;
    doc.mode = .edit;
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
    d.note = "saved";
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

// ---- prompt ----

fn startPrompt(d: *Doc, m: Mode) void {
    d.mode = m;
    d.prompt.clearRetainingCapacity();
    d.fresh = false;
    d.note = "";
    switch (m) {
        .find => {
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

fn promptType(d: *Doc, s: []const u8) void {
    if (d.fresh) d.prompt.clearRetainingCapacity();
    d.fresh = false;
    if (d.mode == .line) {
        for (s) |c| if (std.ascii.isDigit(c)) d.prompt.append(gpa, c) catch {};
    } else d.prompt.appendSlice(gpa, s) catch {};
    promptChanged(d);
}

fn promptChanged(d: *Doc) void {
    switch (d.mode) {
        .find => {
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
        .edit => {},
    }
}

fn findAgain(d: *Doc, back: bool) void {
    const q = if (d.mode == .find) d.prompt.items else d.query.items;
    if (q.len == 0) return startPrompt(d, .find);
    const s = d.ed.sel();
    if (!d.ed.find(q, if (back) s[0] else s[0] + 1, back)) d.note = "no matches";
    if (d.mode == .find) countFound(d);
    center(d);
}

fn shiftHeld() bool {
    const ev = msg(Id, msg(Id, objc.class("NSApplication"), "sharedApplication", .{}), "currentEvent", .{});
    return msg(usize, ev, "modifierFlags", .{}) & shift_key != 0;
}

/// Key commands while the prompt is open.
fn promptCommand(d: *Doc, name: []const u8) void {
    if (is(name, "insertNewline")) return accept(d);
    if (is(name, "cancelOperation")) {
        d.mode = .edit;
        return;
    }
    if (is(name, "deleteBackward")) {
        d.fresh = false;
        d.prompt.items.len = editor.prevChar(d.prompt.items, d.prompt.items.len);
    } else if (is(name, "deleteWordBackward") or is(name, "deleteToBeginningOfLine")) {
        d.prompt.clearRetainingCapacity();
    } else if (d.mode == .open and (is(name, "moveUp") or is(name, "moveDown"))) {
        if (is(name, "moveUp")) d.pick -|= 1 else d.pick = @min(d.pick + 1, d.npicks -| 1);
        return;
    } else return;
    promptChanged(d);
}

fn is(name: []const u8, comptime want: []const u8) bool {
    return std.mem.eql(u8, name, want);
}

// ---- scrolling ----

fn clampScroll(d: *Doc) void {
    const lines = f(d.ed.buf.lines());
    d.sy = std.math.clamp(d.sy, 0, @max(0, lines * lh - textH(d) / 2));
    d.sx = @max(d.sx, 0);
}

/// Scrolls just enough to show the caret.
fn reveal(d: *Doc) void {
    const b = &d.ed.buf;
    const row = b.lineOf(d.ed.cur);
    const y = f(row) * lh;
    const th = textH(d);
    if (y < d.sy) d.sy = y;
    if (y + lh > d.sy + th) d.sy = y + lh - th;
    const x = f(editor.colOf(b.line(row), d.ed.cur - b.lineStart(row))) * cw;
    const tw = bounds(d).w - 2 * pad_x;
    if (x < d.sx) d.sx = @max(0, x - 8 * cw);
    if (x > d.sx + tw - cw) d.sx = x - tw + 8 * cw;
    clampScroll(d);
}

/// Puts the caret a third of the way down when it's off screen.
fn center(d: *Doc) void {
    const y = f(d.ed.buf.lineOf(d.ed.cur)) * lh;
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

fn draw(d: *Doc, ctx: Id) void {
    const dark = isDark(d.view);
    const th = if (dark) &ink else &paper;
    if (d.dark != dark) {
        d.dark = dark;
        const c = msg(Id, objc.class("NSColor"), "colorWithDeviceRed:green:blue:alpha:", .{ th.bg[0], th.bg[1], th.bg[2], @as(f64, 1) });
        msg(void, d.window, "setBackgroundColor:", .{c});
    }
    const r = bounds(d);
    const b = &d.ed.buf;
    const t = d.ed.text();
    fill(ctx, th.bg, 0, 0, r.w, r.h);
    objc.flipText(ctx);

    clampScroll(d);
    const last = @min(b.lines(), @as(usize, @intFromFloat(@ceil((d.sy + textH(d)) / lh))) + 1);
    const first: usize = @min(@as(usize, @intFromFloat(@floor(d.sy / lh))), last);
    const skip: usize = @intFromFloat(@ceil(d.sx / cw));
    const ox = pad_x + f(skip) * cw - d.sx;
    const cols: usize = @intFromFloat(@ceil((r.w - ox) / cw));
    const s = d.ed.sel();
    const cur_row = b.lineOf(d.ed.cur);
    const finding = d.mode == .find and d.prompt.items.len > 0;
    syncStates(d, last);

    // Backgrounds: caret line, selection, find matches.
    for (first..last) |row| {
        const y = top_h + f(row) * lh - d.sy;
        const ls = b.lineStart(row);
        const l = b.line(row);
        if (row == cur_row and s[0] == s[1] and d.mode == .edit) fill(ctx, th.line, 0, y, r.w, lh);
        const next = if (row + 1 < b.lines()) b.lineStart(row + 1) else t.len + 1;
        if (s[0] < next and s[1] > ls) {
            const a = editor.colOf(l, @max(s[0], ls) - ls);
            const z = editor.colOf(l, @min(s[1], ls + l.len) - ls);
            const tail: f64 = if (s[1] > ls + l.len) 0.6 else 0;
            fill(ctx, th.sel, ox + (f(a) - f(skip)) * cw, y, (f(z) - f(a) + tail) * cw, lh);
        }
        if (finding) {
            const q = d.prompt.items;
            var i: usize = 0;
            while (i + q.len <= l.len) : (i += 1) if (editor.matchAt(l, i, q)) {
                const a = editor.colOf(l, i);
                const z = editor.colOf(l, i + q.len);
                if (ls + i != s[0]) fill(ctx, th.match, ox + (f(a) - f(skip)) * cw, y + 2, f(z - a) * cw, lh - 4);
                i += q.len - 1;
            };
        }
    }

    // Text.
    var k: Ink = .{ .ctx = ctx };
    for (first..last) |row| {
        const l = b.line(row);
        var kinds: ?[]const syntax.Kind = null;
        if (d.lang != &syntax.plain and row < d.states.items.len) {
            if (d.kinds.items.len < l.len) d.kinds.resize(gpa, l.len) catch {};
            if (d.kinds.items.len >= l.len) {
                _ = syntax.lexLine(d.lang, l, d.states.items[row], d.kinds.items[0..l.len]);
                kinds = d.kinds.items[0..l.len];
            }
        }
        _ = k.text(l, kinds, th, th.fg, ox, top_h + f(row) * lh - d.sy + baseline, skip, cols);
    }
    k.flush();

    if (d.mode == .edit) {
        const x = pad_x + f(editor.colOf(b.line(cur_row), d.ed.cur - b.lineStart(cur_row))) * cw - d.sx;
        if (x >= pad_x - 1) fill(ctx, th.caret, x - 1, top_h + f(cur_row) * lh - d.sy + 2, 2, lh - 4);
    }

    // The band under the title bar, the quick open list, and the status bar.
    fill(ctx, th.bg, 0, 0, r.w, top_h - 8);
    const by = r.h - barH();
    const ty = by + 6 + baseline;
    if (d.mode == .open and d.list != null) {
        const ph = f(d.npicks) * lh + 12;
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
        const col = editor.colOf(b.line(cur_row), d.ed.cur - b.lineStart(cur_row));
        right = std.fmt.bufPrint(&buf, "{d}:{d}", .{ cur_row + 1, col + 1 }) catch "";
    } else {
        const label = switch (d.mode) {
            .find => "find",
            .line => "line",
            else => "open",
        };
        x += f(k.text(label, null, th, th.caret, x, ty, 0, 8) + 1) * cw;
        if (d.fresh) {
            k.flush();
            fill(ctx, th.sel, x, by + 6, f(editor.colOf(d.prompt.items, d.prompt.items.len)) * cw, lh);
        }
        const n = k.text(d.prompt.items, null, th, th.fg, x, ty, 0, 400);
        x += f(n) * cw;
        k.flush();
        fill(ctx, th.caret, x, by + 8, 2, lh - 4);
        if (d.mode == .find and d.prompt.items.len > 0) right = if (d.found[1] == 0) "no matches" else std.fmt.bufPrint(&buf, "{d} of {d}", .{ @min(d.found[0], d.found[1]), d.found[1] }) catch "";
        if (d.mode == .open and d.list != null) right = std.fmt.bufPrint(&buf, "{d} files", .{d.list.?.paths.items.len}) catch "";
    }
    _ = k.text(right, null, th, th.muted, r.w - pad_x - f(right.len) * cw, ty, 0, 64);
    k.flush();
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
    // Command keys that the menu didn't take: only arrows and delete mean something.
    if (msg(usize, ev, "modifierFlags", .{}) & cmd_key != 0) {
        const code = msg(u16, ev, "keyCode", .{});
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
        d.ed.insert(gpa, bytes) catch {};
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
        e.move(m[1], extend, pageLines(d));
        return true;
    };
    if (is(name, "deleteBackward") or is(name, "deleteBackwardByDecomposingPreviousCharacter")) {
        try e.deleteBack(gpa, .char);
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
    const b = &d.ed.buf;
    const yy = p.y - top_h + d.sy;
    const row: usize = if (yy < 0) 0 else @min(@as(usize, @intFromFloat(yy / lh)), b.lines() - 1);
    return b.lineStart(row) + editor.byteAtCol(b.line(row), @max((p.x - pad_x + d.sx) / cw, 0));
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
    const p = local(self, ev);
    if (p.y < top_h) d.sy -= lh;
    if (p.y > bounds(d).h - barH()) d.sy += lh;
    clampScroll(d);
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
    refresh(d);
}

fn resetCursorRects(self: Id, _: Sel) callconv(.c) void {
    msg(void, self, "addCursorRect:cursor:", .{ msg(Rect, self, "bounds", .{}), msg(Id, objc.class("NSCursor"), "IBeamCursor", .{}) });
}

fn appearanceChanged(self: Id, _: Sel) callconv(.c) void {
    msg(void, self, "setNeedsDisplay:", .{true});
}

fn windowShouldClose(self: Id, _: Sel, _: Id) callconv(.c) bool {
    const d = docOf(self) orelse return true;
    return settle(d);
}

fn windowWillClose(self: Id, _: Sel, _: Id) callconv(.c) void {
    const d = docOf(self) orelse return;
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
    setFont(if (by == 0) default_size else font_size + by);
    for (docs.items) |d| {
        clampScroll(d);
        refresh(d);
    }
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

/// Registers the view class and loads the font. Call once at launch.
pub fn setup() void {
    setFont(default_size);
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
    c.method("windowShouldClose:", @ptrCast(&windowShouldClose), "c@:@");
    c.method("windowWillClose:", @ptrCast(&windowWillClose), "v@:@");
    const actions = .{
        .{ "copy:", copy },             .{ "cut:", cut },               .{ "paste:", paste },
        .{ "selectAll:", selectAll },   .{ "undo:", undo },             .{ "redo:", redo },
        .{ "saveDocument:", saveDoc },  .{ "saveDocumentAs:", saveAs }, .{ "findText:", find },
        .{ "findNext:", findNext },     .{ "findPrevious:", findPrev }, .{ "gotoLine:", gotoLine },
        .{ "quickOpen:", quickOpen },   .{ "toggleComment:", comment }, .{ "zoomIn:", zoomIn },
        .{ "zoomOut:", zoomOut },       .{ "zoomReset:", zoomReset },
    };
    inline for (actions) |a| c.method(a[0], action(a[1]), "v@:@");
    view_class = c.finish();
    doc_ivar = objc.ivarOffset(view_class, "doc");
}
