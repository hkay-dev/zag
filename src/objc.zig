//! The Objective-C runtime, plus the CoreGraphics and CoreText calls ze
//! draws with. Apple Silicon only: one objc_msgSend serves every return type.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .aarch64) @compileError("ze runs on Apple Silicon only");
}

pub const Id = ?*anyopaque;
pub const Sel = ?*anyopaque;

pub const Point = extern struct { x: f64 = 0, y: f64 = 0 };
pub const Rect = extern struct { x: f64 = 0, y: f64 = 0, w: f64 = 0, h: f64 = 0 };
const Range = extern struct { loc: isize, len: isize };
const Transform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };

pub extern fn objc_getClass(name: [*:0]const u8) Id;
pub extern fn sel_registerName(name: [*:0]const u8) Sel;
pub extern fn sel_getName(sel: Sel) [*:0]const u8;
extern fn objc_allocateClassPair(super: Id, name: [*:0]const u8, extra: usize) Id;
extern fn objc_registerClassPair(cls: Id) void;
extern fn class_addMethod(cls: Id, sel: Sel, imp: *const anyopaque, types: [*:0]const u8) bool;
extern fn class_addIvar(cls: Id, name: [*:0]const u8, size: usize, log2_align: u8, types: [*:0]const u8) bool;
extern fn class_getInstanceVariable(cls: Id, name: [*:0]const u8) ?*anyopaque;
extern fn ivar_getOffset(ivar: ?*anyopaque) isize;
extern fn objc_msgSend() callconv(.c) void;
pub extern fn objc_autoreleasePoolPush() ?*anyopaque;
pub extern fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

pub fn class(name: [*:0]const u8) Id {
    return objc_getClass(name);
}

/// Sends `sel` to `target`. Literal numbers in `args` need a type.
pub fn msg(comptime R: type, target: Id, comptime sel: [:0]const u8, args: anytype) R {
    const fields = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const params = comptime blk: {
        var p: [fields.len + 2]type = undefined;
        p[0] = Id;
        p[1] = Sel;
        for (fields, 2..) |f, i| p[i] = f;
        break :blk p;
    };
    const F = @Fn(&params, &@splat(.{}), R, .{ .@"callconv" = .c });
    const f: *const F = @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ target, sel_registerName(sel) } ++ args);
}

/// `[[cls alloc] init]`.
pub fn new(cls: [*:0]const u8) Id {
    return msg(Id, msg(Id, class(cls), "alloc", .{}), "init", .{});
}

/// A subclass under construction.
pub const ClassBuilder = struct {
    cls: Id,

    pub fn begin(super: [*:0]const u8, name: [*:0]const u8) ClassBuilder {
        return .{ .cls = objc_allocateClassPair(class(super), name, 0) };
    }

    /// `types` is the Objective-C type encoding, such as "v@:@".
    pub fn method(b: ClassBuilder, sel: [*:0]const u8, imp: *const anyopaque, types: [*:0]const u8) void {
        _ = class_addMethod(b.cls, sel_registerName(sel), imp, types);
    }

    /// A pointer-sized instance variable.
    pub fn ivar(b: ClassBuilder, name: [*:0]const u8) void {
        _ = class_addIvar(b.cls, name, 8, 3, "^v");
    }

    pub fn finish(b: ClassBuilder) Id {
        objc_registerClassPair(b.cls);
        return b.cls;
    }
};

pub fn ivarOffset(cls: Id, name: [*:0]const u8) usize {
    return @intCast(ivar_getOffset(class_getInstanceVariable(cls, name)));
}

/// An autoreleased NSString with a copy of `s`. Invalid UTF-8 gives "".
pub fn str(s: []const u8) Id {
    const ns = msg(Id, msg(Id, class("NSString"), "alloc", .{}), "initWithBytes:length:encoding:", .{ s.ptr, s.len, @as(usize, 4) });
    if (ns == null) return msg(Id, class("NSString"), "string", .{});
    return msg(Id, ns, "autorelease", .{});
}

/// The UTF-8 bytes of an NSString, valid until the autorelease pool drains.
pub fn utf8(ns: Id) []const u8 {
    if (ns == null) return "";
    const p = msg(?[*:0]const u8, ns, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

pub extern fn CFRelease(cf: *anyopaque) void;
pub extern fn CFRetain(cf: *anyopaque) *anyopaque;
pub extern fn CGContextSetRGBFillColor(ctx: Id, r: f64, g: f64, b: f64, a: f64) void;
pub extern fn CGContextFillRect(ctx: Id, rect: Rect) void;
pub extern fn CGPathCreateWithRoundedRect(rect: Rect, corner_w: f64, corner_h: f64, transform: ?*const anyopaque) ?*anyopaque;
pub extern fn CGContextAddPath(ctx: Id, path: ?*anyopaque) void;
pub extern fn CGContextFillPath(ctx: Id) void;
pub extern fn CGContextEOFillPath(ctx: Id) void;
pub extern fn CGContextSaveGState(ctx: Id) void;
pub extern fn CGContextRestoreGState(ctx: Id) void;
pub extern fn CGContextClipToRect(ctx: Id, rect: Rect) void;
pub extern fn CGContextTranslateCTM(ctx: Id, tx: f64, ty: f64) void;
pub extern fn CGContextScaleCTM(ctx: Id, sx: f64, sy: f64) void;
pub extern fn CGContextRotateCTM(ctx: Id, angle: f64) void;
pub extern fn CGContextSetAlpha(ctx: Id, alpha: f64) void;
pub extern fn CGContextBeginTransparencyLayer(ctx: Id, info: ?*anyopaque) void;
pub extern fn CGContextEndTransparencyLayer(ctx: Id) void;
pub extern fn CGContextClip(ctx: Id) void;
extern fn CGContextSetTextMatrix(ctx: Id, t: Transform) void;
pub extern fn CTFontGetGlyphsForCharacters(font: Id, chars: [*]const u16, glyphs: [*]u16, count: isize) bool;
pub extern fn CTFontDrawGlyphs(font: Id, glyphs: [*]const u16, positions: [*]const Point, count: usize, ctx: Id) void;
pub extern fn CTFontGetAdvancesForGlyphs(font: Id, orientation: u32, glyphs: [*]const u16, advances: ?*anyopaque, count: isize) f64;
pub extern fn CTFontGetAscent(font: Id) f64;
pub extern fn CTFontGetDescent(font: Id) f64;
extern fn CTFontCreateForString(font: Id, s: Id, range: Range) Id;
pub extern fn CTLineCreateWithAttributedString(s: Id) Id;
pub extern fn CTLineCreateTruncatedLine(line: Id, width: f64, kind: u32, token: Id) Id;
pub extern fn CTLineDraw(line: Id, ctx: Id) void;
pub extern fn CTLineGetTypographicBounds(line: Id, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;
pub extern fn CGContextSetTextPosition(ctx: Id, x: f64, y: f64) void;

/// Flips glyphs upright in a flipped view.
pub fn flipText(ctx: Id) void {
    CGContextSetTextMatrix(ctx, .{ .a = 1, .b = 0, .c = 0, .d = -1, .tx = 0, .ty = 0 });
}

/// The font the system picks for `units` when `font` lacks the glyph. Retained.
pub fn fallbackFont(font: Id, units: []const u16) Id {
    const s = msg(Id, class("NSString"), "stringWithCharacters:length:", .{ units.ptr, units.len });
    return CTFontCreateForString(font, s, .{ .loc = 0, .len = @intCast(units.len) });
}
