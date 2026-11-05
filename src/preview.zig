//! Foundation parses Markdown; AppKit lays out the read-only preview.
const std = @import("std");
const objc = @import("objc.zig");
const settings = @import("settings.zig");
const Id = objc.Id;
const msg = objc.msg;
const Range = extern struct { loc: usize, len: usize };
var window: Id = null;
var text: Id = null;
var target: Id = null;
var owner: Id = null;
var source: Id = null;
var path: Id = null;
var theme: settings.Theme = undefined;

fn color(rgb: settings.Rgb) Id {
    return msg(Id, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ rgb[0], rgb[1], rgb[2], @as(f64, 1) });
}
fn attr(s: Id, key: []const u8, value: Id, r: Range) void {
    msg(void, s, "addAttribute:value:range:", .{ objc.str(key), value, r });
}
fn closed(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    msg(void, objc.class("NSObject"), "cancelPreviousPerformRequestsWithTarget:", .{target});
    msg(void, source, "release", .{});
    msg(void, path, "release", .{});
    source = null;
    path = null;
    owner = null;
    window = null;
    text = null;
}
pub fn close(w: Id) void {
    if (owner == w) msg(void, window, "close", .{});
}
fn closeAction(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    close(owner);
}
pub fn rename(w: Id, old: []const u8, new: []const u8) void {
    if (owner == w and std.mem.eql(u8, objc.utf8(path), old)) msg(void, path, "setString:", .{objc.str(new)});
}
pub fn update(d: anytype, conf: *const settings.Settings) void {
    if (owner != d.window) return;
    const active = std.mem.eql(u8, objc.utf8(path), d.path orelse "");
    const appearance = objc.utf8(msg(Id, msg(Id, d.view, "effectiveAppearance", .{}), "name", .{}));
    const th = if (std.mem.indexOf(u8, appearance, "Dark") != null) &conf.dark else &conf.light;
    const bytes = d.ed.text();
    if (std.meta.eql(theme, th.*) and (!active or d.ed.buf.touched == std.math.maxInt(usize) or std.mem.eql(u8, objc.utf8(source), bytes))) return;
    if (active) {
        msg(void, source, "release", .{});
        source = msg(Id, objc.str(bytes), "retain", .{});
    }
    theme = th.*;
    msg(void, objc.class("NSObject"), "cancelPreviousPerformRequestsWithTarget:", .{target});
    msg(void, target, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("render:"), @as(Id, null), @as(f64, 0.15) });
}
pub fn toggle(w: Id, name: []const u8, bytes: []const u8, th: *const settings.Theme) void {
    if (window != null) { msg(void, window, "close", .{}); return; }
    if (target == null) {
        const c = objc.ClassBuilder.begin("NSObject", "ZePreview");
        c.method("render:", @ptrCast(&render), "v@:@");
        c.method("windowWillClose:", @ptrCast(&closed), "v@:@");
        c.method("markdownPreview:", @ptrCast(&closeAction), "v@:@");
        target = msg(Id, msg(Id, c.finish(), "alloc", .{}), "init", .{});
    }
    owner = w;
    path = msg(Id, objc.str(name), "mutableCopy", .{});
    theme = th.*;
    source = msg(Id, objc.str(bytes), "retain", .{});
    const frame: objc.Rect = .{ .w = 620, .h = 700 };
    window = msg(Id, msg(Id, objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ frame, @as(usize, 1 | 2 | 4 | 8), @as(usize, 2), false });
    msg(void, window, "setTitle:", .{objc.str("Markdown Preview")});
    msg(void, window, "setTitlebarAppearsTransparent:", .{true});
    msg(void, window, "setDelegate:", .{target});
    const scroll = msg(Id, msg(Id, objc.class("NSScrollView"), "alloc", .{}), "initWithFrame:", .{frame});
    text = msg(Id, msg(Id, objc.class("NSTextView"), "alloc", .{}), "initWithFrame:", .{frame});
    msg(void, text, "setEditable:", .{false});
    msg(void, text, "setTextContainerInset:", .{objc.Point{ .x = 28, .y = 24 }});
    msg(void, text, "setAutoresizingMask:", .{@as(usize, 2)});
    msg(void, msg(Id, text, "textContainer", .{}), "setWidthTracksTextView:", .{true});
    msg(void, scroll, "setHasVerticalScroller:", .{true});
    msg(void, scroll, "setDocumentView:", .{text});
    msg(void, window, "setContentView:", .{scroll});
    msg(void, scroll, "release", .{});
    msg(void, text, "release", .{});
    const fr = msg(objc.Rect, w, "frame", .{});
    msg(void, window, "setFrameTopLeftPoint:", .{objc.Point{ .x = fr.x + fr.w - 80, .y = fr.y + fr.h }});
    render(null, null, null);
    msg(void, window, "orderFront:", .{@as(Id, null)});
}
fn render(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    const options = objc.new("NSAttributedStringMarkdownParsingOptions");
    defer msg(void, options, "release", .{});
    msg(void, options, "setInterpretedSyntax:", .{@as(isize, 0)});
    const parsed = msg(Id, msg(Id, objc.class("NSAttributedString"), "alloc", .{}), "initWithMarkdown:options:baseURL:error:", .{ msg(Id, source, "dataUsingEncoding:", .{@as(usize, 4)}), options, @as(Id, null), @as(?*Id, null) });
    defer msg(void, parsed, "release", .{});
    const out = objc.new("NSMutableAttributedString");
    defer msg(void, out, "release", .{});
    const fonts = objc.class("NSFont");
    var i: usize = 0;
    var previous: usize = 0;
    while (i < msg(usize, parsed, "length", .{})) {
        var r: Range = undefined;
        const attrs = msg(Id, parsed, "attributesAtIndex:effectiveRange:", .{ i, &r });
        const part = msg(Id, msg(Id, parsed, "attributedSubstringFromRange:", .{r}), "mutableCopy", .{});
        defer msg(void, part, "release", .{});
        const intent = msg(Id, attrs, "objectForKey:", .{objc.str("NSPresentationIntent")});
        const identity = msg(usize, intent, "identity", .{});
        const fresh = identity != previous;
        if (fresh and i > 0) msg(void, msg(Id, out, "mutableString", .{}), "appendString:", .{objc.str("\n\n")});
        var font = msg(Id, fonts, "systemFontOfSize:", .{@as(f64, 16)});
        var ink = color(theme.fg);
        const all: Range = .{ .loc = 0, .len = r.len };
        const paragraph = objc.new("NSMutableParagraphStyle");
        defer msg(void, paragraph, "release", .{});
        var prefix: Id = null;
        var c = intent;
        while (c != null) : (c = msg(Id, c, "parentIntent", .{})) {
            switch (msg(isize, c, "intentKind", .{})) {
                1 => font = msg(Id, fonts, "boldSystemFontOfSize:", .{@as(f64, if (msg(usize, c, "headerLevel", .{}) == 1) 30 else if (msg(usize, c, "headerLevel", .{}) == 2) 24 else 20)}),
                4 => {
                    msg(void, paragraph, "setHeadIndent:", .{@as(f64, 24)});
                    const ordered = msg(isize, msg(Id, c, "parentIntent", .{}), "intentKind", .{}) == 2;
                    // stringWithFormat: is variadic, which msg can't pass on arm64.
                    var num: [24]u8 = undefined;
                    if (fresh and prefix == null) prefix = if (ordered) objc.str(std.fmt.bufPrint(&num, "{d}. ", .{msg(isize, c, "ordinal", .{})}) catch "") else objc.str("• ");
                },
                5 => { font = msg(Id, fonts, "monospacedSystemFontOfSize:weight:", .{ @as(f64, 14), @as(f64, 0) }); attr(part, "NSBackgroundColor", color(theme.panel), all); },
                6 => { ink = color(theme.muted); msg(void, paragraph, "setHeadIndent:", .{@as(f64, 24)}); msg(void, paragraph, "setFirstLineHeadIndent:", .{@as(f64, 24)}); },
                7 => if (fresh) { prefix = objc.str("────────────────────────"); },
                else => {},
            }
        }
        const inline_intent = msg(usize, msg(Id, attrs, "objectForKey:", .{objc.str("NSInlinePresentationIntent")}), "unsignedIntegerValue", .{});
        if (inline_intent & 4 != 0) font = msg(Id, fonts, "monospacedSystemFontOfSize:weight:", .{ @as(f64, 14), @as(f64, 0) });
        font = msg(Id, msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{}), "convertFont:toHaveTrait:", .{ font, inline_intent & 3 });
        if (msg(Id, attrs, "objectForKey:", .{objc.str("NSLink")}) != null) ink = color(theme.kinds[5]);
        attr(part, "NSFont", font, all);
        attr(part, "NSColor", ink, all);
        attr(part, "NSParagraphStyle", paragraph, all);
        msg(void, part, "removeAttribute:range:", .{ objc.str("NSPresentationIntent"), all });
        if (prefix != null) msg(void, part, "replaceCharactersInRange:withString:", .{ Range{ .loc = 0, .len = 0 }, prefix });
        msg(void, out, "appendAttributedString:", .{part});
        previous = identity;
        i += r.len;
    }
    const clip = msg(Id, msg(Id, text, "enclosingScrollView", .{}), "contentView", .{});
    const position = msg(objc.Rect, clip, "bounds", .{});
    msg(void, text, "setBackgroundColor:", .{color(theme.bg)});
    msg(void, window, "setBackgroundColor:", .{color(theme.header)});
    msg(void, text, "setLinkTextAttributes:", .{msg(Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ color(theme.kinds[5]), objc.str("NSColor") })});
    msg(void, msg(Id, text, "textStorage", .{}), "setAttributedString:", .{out});
    msg(void, text, "scrollPoint:", .{objc.Point{ .x = position.x, .y = position.y }});
}
