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
var fade = false;

fn color(rgb: settings.Rgb) Id {
    return msg(Id, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ rgb[0], rgb[1], rgb[2], @as(f64, 1) });
}
fn attr(s: Id, key: Id, value: Id, r: Range) void {
    msg(void, s, "addAttribute:value:range:", .{ key, value, r });
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
    fade = false;
}
pub fn close(w: Id) void {
    if (owner == w) msg(void, window, "close", .{});
}
fn closeAction(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    close(owner);
}
pub fn rename(w: Id, old: []const u8, new: []const u8) void {
    if (owner == w and std.mem.eql(u8, objc.utf8(path), old)) {
        msg(void, path, "setString:", .{objc.str(new)});
        retitle();
    }
}
/// Titles the window "<file> Preview" and gives it the file's proxy icon.
fn retitle() void {
    const name = objc.utf8(path);
    var buf: [512]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "{s} Preview", .{if (name.len == 0) "Untitled" else std.fs.path.basename(name)}) catch "Preview";
    msg(void, window, "setTitle:", .{objc.str(title)});
    const url = if (name.len == 0) null else msg(Id, objc.class("NSURL"), "fileURLWithPath:", .{path});
    msg(void, window, "setRepresentedURL:", .{url});
}
/// The widest the text column gets, in points.
const column = 680.0;
/// Keeps the text in a centered column at most `column` wide by widening
/// the side insets as the window grows.
fn resized(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    if (text == null) return;
    const w = msg(objc.Rect, text, "frame", .{}).w;
    msg(void, text, "setTextContainerInset:", .{objc.Point{ .x = @max(28, @floor((w - column) / 2)), .y = 24 }});
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
    fade = fade or !std.meta.eql(theme, th.*);
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
        c.method("windowDidResize:", @ptrCast(&resized), "v@:@");
        c.method("markdownPreview:", @ptrCast(&closeAction), "v@:@");
        target = msg(Id, msg(Id, c.finish(), "alloc", .{}), "init", .{});
    }
    owner = w;
    path = msg(Id, objc.str(name), "mutableCopy", .{});
    theme = th.*;
    source = msg(Id, objc.str(bytes), "retain", .{});
    const frame: objc.Rect = .{ .w = 620, .h = 700 };
    window = msg(Id, msg(Id, objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ frame, @as(usize, 1 | 2 | 4 | 8), @as(usize, 2), false });
    retitle();
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
    resized(null, null, null);
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
    const key_intent, const key_inline, const key_link = .{ objc.str("NSPresentationIntent"), objc.str("NSInlinePresentationIntent"), objc.str("NSLink") };
    const key_font, const key_color, const key_style, const key_back = .{ objc.str("NSFont"), objc.str("NSColor"), objc.str("NSParagraphStyle"), objc.str("NSBackgroundColor") };
    const fg, const link, const muted, const panel = .{ color(theme.fg), color(theme.kinds[5]), color(theme.muted), color(theme.panel) };
    var i: usize = 0;
    var previous: usize = 0;
    while (i < msg(usize, parsed, "length", .{})) {
        var r: Range = undefined;
        const attrs = msg(Id, parsed, "attributesAtIndex:effectiveRange:", .{ i, &r });
        const part = msg(Id, msg(Id, parsed, "attributedSubstringFromRange:", .{r}), "mutableCopy", .{});
        defer msg(void, part, "release", .{});
        const intent = msg(Id, attrs, "objectForKey:", .{key_intent});
        const identity = msg(usize, intent, "identity", .{});
        const fresh = identity != previous;
        if (fresh and i > 0) msg(void, msg(Id, out, "mutableString", .{}), "appendString:", .{objc.str("\n")});
        var font = msg(Id, fonts, "systemFontOfSize:", .{@as(f64, 15)});
        var ink = fg;
        const all: Range = .{ .loc = 0, .len = r.len };
        const paragraph = objc.new("NSMutableParagraphStyle");
        defer msg(void, paragraph, "release", .{});
        msg(void, paragraph, "setLineHeightMultiple:", .{@as(f64, 1.35)});
        msg(void, paragraph, "setParagraphSpacing:", .{@as(f64, 10)});
        var prefix: Id = null;
        var c = intent;
        while (c != null) : (c = msg(Id, c, "parentIntent", .{})) {
            switch (msg(isize, c, "intentKind", .{})) {
                1 => {
                    const level = msg(usize, c, "headerLevel", .{});
                    font = msg(Id, fonts, "systemFontOfSize:weight:", .{ @as(f64, if (level == 1) 26 else if (level == 2) 20 else 17), @as(f64, 0.3) });
                    if (i > 0) msg(void, paragraph, "setParagraphSpacingBefore:", .{@as(f64, 18)});
                },
                4 => {
                    msg(void, paragraph, "setParagraphSpacing:", .{@as(f64, 4)});
                    msg(void, paragraph, "setHeadIndent:", .{@as(f64, 24)});
                    const ordered = msg(isize, msg(Id, c, "parentIntent", .{}), "intentKind", .{}) == 2;
                    // stringWithFormat: is variadic, which msg can't pass on arm64.
                    var num: [24]u8 = undefined;
                    if (fresh and prefix == null) prefix = if (ordered) objc.str(std.fmt.bufPrint(&num, "{d}. ", .{msg(isize, c, "ordinal", .{})}) catch "") else objc.str("• ");
                },
                5 => { font = msg(Id, fonts, "monospacedSystemFontOfSize:weight:", .{ @as(f64, 14), @as(f64, 0) }); attr(part, key_back, panel, all); },
                6 => { ink = muted; msg(void, paragraph, "setHeadIndent:", .{@as(f64, 24)}); msg(void, paragraph, "setFirstLineHeadIndent:", .{@as(f64, 24)}); },
                7 => if (fresh) { prefix = objc.str("────────────────────────"); },
                else => {},
            }
        }
        const inline_intent = msg(usize, msg(Id, attrs, "objectForKey:", .{key_inline}), "unsignedIntegerValue", .{});
        if (inline_intent & 4 != 0) font = msg(Id, fonts, "monospacedSystemFontOfSize:weight:", .{ @as(f64, 14), @as(f64, 0) });
        if (inline_intent & 3 != 0) font = msg(Id, msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{}), "convertFont:toHaveTrait:", .{ font, inline_intent & 3 });
        if (msg(Id, attrs, "objectForKey:", .{key_link}) != null) ink = link;
        attr(part, key_font, font, all);
        attr(part, key_color, ink, all);
        attr(part, key_style, paragraph, all);
        msg(void, part, "removeAttribute:range:", .{ key_intent, all });
        if (prefix != null) msg(void, part, "replaceCharactersInRange:withString:", .{ Range{ .loc = 0, .len = 0 }, prefix });
        msg(void, out, "appendAttributedString:", .{part});
        previous = identity;
        i += r.len;
    }
    const clip = msg(Id, msg(Id, text, "enclosingScrollView", .{}), "contentView", .{});
    const position = msg(objc.Rect, clip, "bounds", .{});
    if (fade) {
        // The same crossfade as view.zig's fadeTheme, on the scroll view's layer.
        const t = msg(Id, objc.class("CATransition"), "animation", .{});
        msg(void, t, "setType:", .{objc.str("fade")});
        msg(void, t, "setDuration:", .{@as(f64, 0.25)});
        msg(void, t, "setTimingFunction:", .{msg(Id, objc.class("CAMediaTimingFunction"), "functionWithName:", .{objc.str("easeInEaseOut")})});
        msg(void, msg(Id, msg(Id, window, "contentView", .{}), "layer", .{}), "addAnimation:forKey:", .{ t, objc.str("theme") });
        fade = false;
    }
    msg(void, text, "setBackgroundColor:", .{color(theme.bg)});
    msg(void, window, "setBackgroundColor:", .{color(theme.bg)});
    msg(void, text, "setLinkTextAttributes:", .{msg(Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ color(theme.kinds[5]), objc.str("NSColor") })});
    msg(void, msg(Id, text, "textStorage", .{}), "setAttributedString:", .{out});
    msg(void, text, "scrollPoint:", .{objc.Point{ .x = position.x, .y = position.y }});
}
