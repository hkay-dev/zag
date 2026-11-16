//! Motion curves, CoreGraphics shapes and shadows, cached icons, and UI
//! CoreText lines shared across windows, without touching editor state.
const std = @import("std");
const objc = @import("objc.zig");
const settings = @import("settings.zig");
const Id = objc.Id;
const Point = objc.Point;
const Rect = objc.Rect;
const msg = objc.msg;
const Rgb = settings.Rgb;
const Theme = settings.Theme;

const gpa = std.heap.c_allocator;

pub extern fn CACurrentMediaTime() f64;

// ---- motion ----

/// Cubic ease-out glide from `from` at speed `v0` to `to` over `dur` seconds.
pub const Tween = struct {
    from: f64 = 0,
    to: f64 = 0,
    t0: f64 = 0,
    v0: f64 = 0,
    dur: f64,

    pub fn at(w: Tween, now: f64) f64 {
        const s = std.math.clamp((now - w.t0) / w.dur, 0, 1);
        const s2 = s * s;
        const s3 = s2 * s;
        return (2 * s3 - 3 * s2 + 1) * w.from + (s3 - 2 * s2 + s) * w.dur * w.v0 + (3 * s2 - 2 * s3) * w.to;
    }

    pub fn speed(w: Tween, now: f64) f64 {
        if (!w.moving(now)) return 0;
        const s = std.math.clamp((now - w.t0) / w.dur, 0, 1);
        const s2 = s * s;
        return (6 * s - 6 * s2) * (w.to - w.from) / w.dur + (3 * s2 - 4 * s + 1) * w.v0;
    }

    pub fn aim(w: *Tween, to: f64, now: f64) void {
        w.aimOver(to, w.dur, now);
    }

    pub fn aimOver(w: *Tween, to: f64, dur: f64, now: f64) void {
        if (to == w.to) return;
        const v = w.speed(now);
        w.from = w.at(now);
        w.dur = dur;
        w.to = to;
        w.t0 = now;
        const ease = 3 * (to - w.from) / w.dur;
        // Slower keeps its speed; faster is capped so it doesn't overshoot.
        w.v0 = if (v == 0 or ((v > 0) == (ease > 0) and @abs(v) > @abs(ease))) ease else v;
    }

    pub fn snap(w: *Tween, to: f64) void {
        w.from = to;
        w.to = to;
        w.v0 = 0;
    }

    /// Shifts the glide when the page under it jumps.
    pub fn shift(w: *Tween, by: f64) void {
        w.from += by;
        w.to += by;
    }

    pub fn moving(w: Tween, now: f64) bool {
        return w.from != w.to and now < w.t0 + w.dur;
    }
};

/// Damped spring toward `to`.
pub const Spring = struct {
    x: f64 = 0,
    v: f64 = 0,
    to: f64 = 0,
    t: f64 = 0,
    k: f64,
    c: f64,
    /// Close enough to call it settled.
    eps: f64 = 0.002,

    pub fn aim(s: *Spring, to: f64, now: f64) void {
        if (s.settled()) s.t = now;
        s.to = to;
    }

    pub fn snap(s: *Spring, to: f64) void {
        s.x = to;
        s.to = to;
        s.v = 0;
    }

    pub fn ride(s: *Spring, to: f64) void {
        s.x += to - s.to;
        s.to = to;
    }

    /// Moves it on to `now` and returns where it is.
    pub fn step(s: *Spring, now: f64) f64 {
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

    pub fn settled(s: Spring) bool {
        return @abs(s.x - s.to) < s.eps and @abs(s.v) < s.eps * 10;
    }
};

// ---- shapes and shadows ----

/// The window's points per device pixel, set at the start of each draw.
pub var dev_px: f64 = 0.5;

/// One device pixel in points: separators and outlines are this thick.
pub fn hair() f64 {
    return dev_px;
}

/// `v` rounded to the nearest device pixel.
pub fn snapPx(v: f64) f64 {
    return @round(v / dev_px) * dev_px;
}

pub fn fill(ctx: Id, c: Rgb, x: f64, y: f64, w: f64, h: f64) void {
    fillA(ctx, c, 1, x, y, w, h);
}

pub fn fillA(ctx: Id, c: Rgb, a: f64, x: f64, y: f64, w: f64, h: f64) void {
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    objc.CGContextFillRect(ctx, .{ .x = x, .y = y, .w = w, .h = h });
}

/// Rounded-rect path with per-corner radii (TL, TR, BR, BL).
pub fn cornerPath(ctx: Id, x: f64, y: f64, w: f64, h: f64, radii: [4]f64) void {
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
pub fn roundPath(ctx: Id, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    cornerPath(ctx, x, y, w, h, @splat(radius));
}

/// Filled rounded rectangle.
pub fn pill(ctx: Id, c: Rgb, a: f64, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    roundPath(ctx, x, y, w, h, radius);
    objc.CGContextFillPath(ctx);
}

/// Hairline outline of `pill` (one device pixel thick).
pub fn ring(ctx: Id, c: Rgb, a: f64, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const t = hair();
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    roundPath(ctx, x, y, w, h, radius);
    roundPath(ctx, x + t, y + t, w - 2 * t, h - 2 * t, radius - t);
    objc.CGContextEOFillPath(ctx);
}

/// Limits drawing to a rounded rectangle until the state is restored.
pub fn clipRound(ctx: Id, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    roundPath(ctx, x, y, w, h, radius);
    objc.CGContextClip(ctx);
}

pub fn scaleAt(ctx: Id, cx: f64, cy: f64, s: f64) void {
    objc.CGContextTranslateCTM(ctx, cx, cy);
    objc.CGContextScaleCTM(ctx, s, s);
    objc.CGContextTranslateCTM(ctx, -cx, -cy);
}

pub fn nscolor(c: Rgb) Id {
    return msg(Id, objc.class("NSColor"), "colorWithDeviceRed:green:blue:alpha:", .{ c[0], c[1], c[2], @as(f64, 1) });
}

/// Nine-slice cached card shadow for light and dark themes.
pub const shadow_m = 12.0;
const shadow_core = 40.0;
var shadow_cells: [2][9]?*anyopaque = @splat(@splat(null));
var shadow_for: f64 = 0;

pub fn dropShadow() void {
    for (&shadow_cells) |*set| for (set) |*cell| {
        if (cell.*) |i| objc.CFRelease(i);
        cell.* = null;
    };
    shadow_for = 0;
}

fn shadowCells(dark: bool, radius: f64) *const [9]?*anyopaque {
    if (shadow_for != radius) {
        dropShadow();
        shadow_for = radius;
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
    const path = objc.CGPathCreateWithRoundedRect(.{ .x = m, .y = m, .w = core, .h = core }, 2 * radius, 2 * radius, null);
    defer if (path) |p| objc.CFRelease(p);
    // Clear the inner card shape so only the outer blur remains.
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
    const edge = m + 2 * radius;
    const cuts = [4]f64{ 0, edge, side - edge, side };
    for (0..3) |r| for (0..3) |c| {
        cells[r * 3 + c] = objc.CGImageCreateWithImageInRect(img, .{ .x = cuts[c], .y = cuts[r], .w = cuts[c + 1] - cuts[c], .h = cuts[r + 1] - cuts[r] });
    };
    return cells;
}

/// Stretches the cached nine-slice card shadow around `(x, y, w, h)`.
pub fn shadow(ctx: Id, dark: bool, alpha: f64, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const edge = shadow_m + radius;
    if (w < 2 * radius or h < 2 * radius) return;
    const cells = shadowCells(dark, radius);
    const xs = [4]f64{ x - shadow_m, x - shadow_m + edge, x + w + shadow_m - edge, x + w + shadow_m };
    const ys = [4]f64{ y - shadow_m, y - shadow_m + edge, y + h + shadow_m - edge, y + h + shadow_m };
    objc.CGContextSaveGState(ctx);
    objc.CGContextSetAlpha(ctx, alpha);
    // The view is flipped and images draw upside down in a flipped context,
    // so flip the slices back, once.
    objc.CGContextScaleCTM(ctx, 1, -1);
    for (0..3) |r| for (0..3) |c| if (r != 1 or c != 1) {
        objc.CGContextDrawImage(ctx, .{ .x = xs[c], .y = -ys[r + 1], .w = xs[c + 1] - xs[c], .h = ys[r + 1] - ys[r] }, cells[r * 3 + c]);
    };
    objc.CGContextRestoreGState(ctx);
}

pub fn fade(dur: f64, timing: []const u8) Id {
    const t = msg(Id, objc.class("CATransition"), "animation", .{});
    msg(void, t, "setType:", .{objc.str("fade")});
    msg(void, t, "setDuration:", .{dur});
    msg(void, t, "setTimingFunction:", .{msg(Id, objc.class("CAMediaTimingFunction"), "functionWithName:", .{objc.str(timing)})});
    return t;
}

var fade_anim: Id = null;
var fade_anim_key: Id = null;

pub fn fadeIn(layer: Id, dur: f64) void {
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

// ---- icons ----

pub const Icon = enum { closed, opened, sidebar, plus, close, folder, parents, crumb, check, lock };
const icon_names = [_][:0]const u8{ "chevron.right", "chevron.down", "sidebar.left", "plus", "xmark", "folder.fill", "chevron.down", "chevron.forward", "checkmark", "lock.fill" };
pub const CachedIcon = struct { img: Id = null, cg: ?*anyopaque = null, size: Point = .{}, px: f64 = 0 };
var icons: [2][icon_names.len]CachedIcon = @splat(@splat(.{}));
const KindCg = struct { cg: ?*anyopaque = null, s: f64 = 0, px: f64 = 0 };
pub const KindIcon = struct { key: [16]u8, len: u8, img: Id, cgs: [3]KindCg = @splat(.{}) };
var kind_icons: std.ArrayList(KindIcon) = .empty;

pub fn dropIcons() void {
    for (&icons) |*set| for (set) |*c| {
        if (c.cg) |cg| objc.CFRelease(cg);
        if (c.img != null) msg(void, c.img, "release", .{});
        c.* = .{};
    };
    for (kind_icons.items) |*e| for (&e.cgs) |*slot| {
        if (slot.cg) |cg| objc.CFRelease(cg);
        slot.* = .{};
    };
}

fn cacheCG(ctx: Id, img: Id, rect: Rect) ?*anyopaque {
    const gc = msg(Id, objc.class("NSGraphicsContext"), "graphicsContextWithCGContext:flipped:", .{ ctx, true });
    if (gc == null) return null;
    var prop = rect;
    const cg = msg(Id, img, "CGImageForProposedRect:context:hints:", .{ &prop, gc, @as(Id, null) });
    return if (cg) |p| objc.CFRetain(p) else null;
}

pub fn drawCG(ctx: Id, cg: ?*anyopaque, x: f64, y: f64, w: f64, h: f64, a: f64) void {
    const img = cg orelse return;
    objc.CGContextSaveGState(ctx);
    if (a < 1) objc.CGContextSetAlpha(ctx, a);
    objc.CGContextTranslateCTM(ctx, x, y + h);
    objc.CGContextScaleCTM(ctx, 1, -1);
    objc.CGContextDrawImage(ctx, .{ .x = 0, .y = 0, .w = w, .h = h }, img);
    objc.CGContextRestoreGState(ctx);
}

/// Finder UTType icon for `name`'s extension, cached on first use.
pub fn iconFor(name: []const u8) Id {
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

pub fn icon(which: Icon, dark: bool, th: *const Theme, size: f64) Id {
    const slot = &icons[@intFromBool(dark)][@intFromEnum(which)];
    if (slot.img != null) return slot.img;
    const scale: f64, const weight: f64 = switch (which) {
        .closed, .opened => .{ 0.6, 0.3 },
        .close => .{ 0.55, 0.3 },
        .crumb => .{ 0.64, 0.23 },
        .sidebar, .plus => .{ 1.0, 0 },
        .folder => .{ 15.0 / size, 0 },
        .parents => .{ 9.0 / size, 0.4 },
        .check => .{ 11.0 / size, 0.3 },
        .lock => .{ 9.0 / size, 0.2 },
    };
    const cfg = objc.class("NSImageSymbolConfiguration");
    const sized = msg(Id, cfg, "configurationWithPointSize:weight:", .{ size * scale, weight });
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

pub fn tile(ctx: Id, img: Id, x: f64, y: f64, s: f64) void {
    tileA(ctx, img, x, y, s, 1);
}

pub fn tileA(ctx: Id, img: Id, x: f64, y: f64, s: f64, a: f64) void {
    if (img == null or ctx == null) return;
    for (kind_icons.items) |*e| if (e.img == img) {
        for (e.cgs) |slot| if (slot.cg != null and slot.px == dev_px and slot.s == s) {
            return drawCG(ctx, slot.cg, x, y, s, s, a);
        };
        if (e.cgs[2].cg) |old| objc.CFRelease(old);
        e.cgs[2] = e.cgs[1];
        e.cgs[1] = e.cgs[0];
        e.cgs[0] = .{ .cg = cacheCG(ctx, img, .{ .w = s, .h = s }), .s = s, .px = dev_px };
        return drawCG(ctx, e.cgs[0].cg, x, y, s, s, a);
    };
}

pub fn drawIcon(ctx: Id, img: Id, x: f64, y: f64, s: f64) void {
    drawIconIn(ctx, img, x, y, s, s, 1);
}

pub fn drawIconIn(ctx: Id, img: Id, x: f64, y: f64, w: f64, h: f64, a: f64) void {
    if (img == null or ctx == null) return;
    for (&icons) |*set| for (set) |*c| if (c.img == img) {
        if (c.cg != null and c.px != dev_px) {
            objc.CFRelease(c.cg.?);
            c.cg = null;
        }
        if (c.cg == null) {
            c.cg = cacheCG(ctx, img, .{ .w = c.size.x, .h = c.size.y });
            c.px = dev_px;
        }
        drawCG(ctx, c.cg, @round(x + (w - c.size.x) / 2), @round(y + (h - c.size.y) / 2), c.size.x, c.size.y, a);
        return;
    };
}

// ---- CoreText UI lines ----

pub fn sysFont(size: f64, weight: ?f64) Id {
    const ns = objc.class("NSFont");
    const made = if (weight) |w| msg(Id, ns, "systemFontOfSize:weight:", .{ size, w }) else msg(Id, ns, "systemFontOfSize:", .{size});
    return msg(Id, made, "retain", .{});
}

pub fn baseIn(fnt: Id, h: f64) f64 {
    const asc = objc.CTFontGetAscent(fnt);
    return @round((h - asc - objc.CTFontGetDescent(fnt)) / 2 + asc);
}

pub fn midOff(fnt: Id) f64 {
    return (objc.CTFontGetAscent(fnt) - objc.CTFontGetDescent(fnt)) / 2;
}

/// Ring cache of CoreText lines for palette and quick-open rows.
pub const RowLine = struct { key: u64 = 0, line: Id = null, w: f64 = 0 };
var row_lines: [128]RowLine = @splat(.{});
var row_next: usize = 0;

pub fn rowLine(s: []const u8, fnt: Id, room: f64, mid: bool) *const RowLine {
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

pub fn dropRowLines() void {
    for (&row_lines) |*e| {
        if (e.line) |l| objc.CFRelease(l);
        e.* = .{};
    }
    row_next = 0;
}

pub fn uiLine(s: []const u8, fnt: Id, width: f64) Id {
    return uiLineCut(s, fnt, width, 1);
}

pub fn uiLineCut(s: []const u8, fnt: Id, width: f64, at: u32) Id {
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

/// Cached attributes dictionary and truncation token per UI font.
pub const UiAttrs = struct { font: Id, attrs: Id, dots: Id = null };
var ui_attrs: [10]UiAttrs = undefined;
var ui_attrs_n: usize = 0;

pub fn dropAttrs() void {
    for (ui_attrs[0..ui_attrs_n]) |a| {
        msg(void, a.attrs, "release", .{});
        if (a.dots) |d| objc.CFRelease(d);
    }
    ui_attrs_n = 0;
}

pub fn uiAttrs(fnt: Id) Id {
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

pub fn uiDots(fnt: Id) Id {
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

pub fn drawLineA(ctx: Id, line: Id, c: Rgb, a: f64, x: f64, y: f64) f64 {
    if (line == null) return 0;
    paintLine(ctx, line, c, a, x, y);
    return lineW(line);
}

pub fn lineW(line: Id) f64 {
    return if (line == null) 0 else objc.CTLineGetTypographicBounds(line, null, null, null);
}

pub fn textW(s: []const u8, fnt: Id) f64 {
    const line = uiLine(s, fnt, 1e9);
    defer if (line) |l| objc.CFRelease(l);
    return lineW(line);
}

/// Draws a line without measuring it when its width is known or unused.
pub fn paintLine(ctx: Id, line: Id, c: Rgb, a: f64, x: f64, y: f64) void {
    if (line == null) return;
    objc.CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], a);
    objc.CGContextSetTextPosition(ctx, x, y);
    objc.CTLineDraw(line, ctx);
    // The grid's glyph runs read the text matrix's offset too, so put it back.
    objc.flipText(ctx);
}
