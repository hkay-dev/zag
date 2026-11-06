//! Foundation parses Markdown; AppKit lays out the read-only preview.
const std = @import("std");
const objc = @import("objc.zig");
const settings = @import("settings.zig");
const syntax = @import("syntax.zig");
const Id = objc.Id;
const msg = objc.msg;
const Range = extern struct { loc: usize, len: usize };
var window: Id = null;
var text: Id = null;
var target: Id = null;
var owner: Id = null;
var path: Id = null;
var theme: settings.Theme = undefined;
var fade = false;
/// The doc and edit count last scheduled or rendered.
var seen_id: u32 = std.math.maxInt(u32);
var seen_changes: u64 = 0;
var text_of: *const fn (u32) ?[]const u8 = undefined;
/// The text last rendered, kept so a theme change still repaints after its tab closes.
var source: Id = null;
/// Fonts and paragraph styles don't depend on the theme, so each is made once and kept.
/// `fonts[block][traits]`: body, three heading sizes, mono; each with italic and bold added.
var fonts: [5][4]Id = @splat(@splat(null));
/// Indexed by `list | quote << 1 | heading_gap << 2`.
var styles: [8]Id = @splat(null);

fn color(rgb: settings.Rgb) Id {
    return msg(Id, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ rgb[0], rgb[1], rgb[2], @as(f64, 1) });
}
fn attr(s: Id, key: Id, value: Id, r: Range) void {
    msg(void, s, "addAttribute:value:range:", .{ key, value, r });
}
fn closed(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    msg(void, objc.class("NSObject"), "cancelPreviousPerformRequestsWithTarget:", .{target});
    msg(void, path, "release", .{});
    path = null;
    owner = null;
    window = null;
    msg(void, source, "release", .{});
    source = null;
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
/// `themes` are the ones the editor draws with (light, dark): zen's grey and Increase Contrast included.
pub fn update(d: anytype, themes: *const [2]settings.Theme, dark: bool) void {
    if (owner != d.win.window) return;
    // A caret move or scroll changes nothing: `changes` counts every edit, undo and redo.
    const unchanged = seen_id == d.file.id and seen_changes == d.file.ed.buf.changes;
    const th = &themes[@intFromBool(dark)];
    const same_theme = std.meta.eql(theme, th.*);
    if (unchanged and same_theme) return;
    const active = unchanged or std.mem.eql(u8, objc.utf8(path), d.file.path orelse "");
    var edited = !same_theme;
    if (active and !unchanged) {
        seen_id = d.file.id;
        seen_changes = d.file.ed.buf.changes;
        edited = true;
    }
    if (!edited) return;
    fade = fade or !same_theme;
    theme = th.*;
    msg(void, objc.class("NSObject"), "cancelPreviousPerformRequestsWithTarget:", .{target});
    msg(void, target, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("render:"), @as(Id, null), @as(f64, 0.15) });
}
pub fn toggle(d: anytype, getter: *const fn (u32) ?[]const u8, th: *const settings.Theme) void {
    if (window != null) { msg(void, window, "close", .{}); return; }
    if (target == null) {
        const c = objc.ClassBuilder.begin("NSObject", "ZePreview");
        c.method("render:", @ptrCast(&render), "v@:@");
        c.method("windowWillClose:", @ptrCast(&closed), "v@:@");
        c.method("windowDidResize:", @ptrCast(&resized), "v@:@");
        c.method("markdownPreview:", @ptrCast(&closeAction), "v@:@");
        target = msg(Id, msg(Id, c.finish(), "alloc", .{}), "init", .{});
    }
    owner = d.win.window;
    path = msg(Id, objc.str(d.file.path orelse ""), "mutableCopy", .{});
    seen_id = d.file.id;
    seen_changes = d.file.ed.buf.changes;
    theme = th.*;
    text_of = getter;
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
    // A saved frame wins; only a first opening is placed beside the editor's window.
    const name_key = objc.str("ZePreview");
    if (!msg(bool, window, "setFrameUsingName:", .{name_key})) {
        const fr = msg(objc.Rect, d.win.window, "frame", .{});
        msg(void, window, "setFrameTopLeftPoint:", .{objc.Point{ .x = fr.x + fr.w - 80, .y = fr.y + fr.h }});
    }
    _ = msg(bool, window, "setFrameAutosaveName:", .{name_key});
    resized(null, null, null);
    render(null, null, null);
    msg(void, window, "orderFront:", .{@as(Id, null)});
}
/// The font for block kind `base` (0 body, 1 to 3 headings, 4 mono) with the italic (1) and bold (2) traits.
fn font(base: usize, traits: usize) Id {
    const slot = &fonts[base][traits];
    if (slot.* == null) {
        const class = objc.class("NSFont");
        const f = switch (base) {
            0 => msg(Id, class, "systemFontOfSize:", .{@as(f64, 15)}),
            1...3 => msg(Id, class, "systemFontOfSize:weight:", .{ @as(f64, if (base == 1) 26 else if (base == 2) 20 else 17), @as(f64, 0.3) }),
            else => msg(Id, class, "monospacedSystemFontOfSize:weight:", .{ @as(f64, 14), @as(f64, 0) }),
        };
        slot.* = msg(Id, if (traits == 0) f else msg(Id, msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{}), "convertFont:toHaveTrait:", .{ f, traits }), "retain", .{});
    }
    return slot.*;
}
/// The paragraph style for `flags` (list 1, quote 2, space before a heading 4). Never changed after it's made.
fn style(flags: usize) Id {
    const slot = &styles[flags];
    if (slot.* == null) {
        const p = objc.new("NSMutableParagraphStyle");
        msg(void, p, "setLineHeightMultiple:", .{@as(f64, 1.35)});
        msg(void, p, "setParagraphSpacing:", .{@as(f64, if (flags & 1 != 0) 4 else 10)});
        if (flags & 4 != 0) msg(void, p, "setParagraphSpacingBefore:", .{@as(f64, 18)});
        if (flags & 3 != 0) msg(void, p, "setHeadIndent:", .{@as(f64, 24)});
        if (flags & 2 != 0) msg(void, p, "setFirstLineHeadIndent:", .{@as(f64, 24)});
        slot.* = p;
    }
    return slot.*;
}
fn render(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    if (text_of(seen_id)) |bytes| {
        msg(void, source, "release", .{});
        source = msg(Id, objc.str(bytes), "retain", .{});
    }
    if (source == null) return;
    const options = objc.new("NSAttributedStringMarkdownParsingOptions");
    defer msg(void, options, "release", .{});
    msg(void, options, "setInterpretedSyntax:", .{@as(isize, 0)});
    const parsed = msg(Id, msg(Id, objc.class("NSAttributedString"), "alloc", .{}), "initWithMarkdown:options:baseURL:error:", .{ msg(Id, source, "dataUsingEncoding:", .{@as(usize, 4)}), options, @as(Id, null), @as(?*Id, null) });
    defer msg(void, parsed, "release", .{});
    const out = objc.new("NSMutableAttributedString");
    defer msg(void, out, "release", .{});
    const key_intent, const key_inline, const key_link = .{ objc.str("NSPresentationIntent"), objc.str("NSInlinePresentationIntent"), objc.str("NSLink") };
    const key_font, const key_color, const key_style, const key_back, const key_line = .{ objc.str("NSFont"), objc.str("NSColor"), objc.str("NSParagraphStyle"), objc.str("NSBackgroundColor"), objc.str("NSUnderline") };
    const fg, const link, const muted, const panel = .{ color(theme.fg), color(theme.kinds[@intFromEnum(syntax.Kind.function)]), color(theme.muted), color(theme.panel) };
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
        var base: usize = 0;
        var ink = fg;
        const all: Range = .{ .loc = 0, .len = r.len };
        var flags: usize = 0;
        var prefix: Id = null;
        var c = intent;
        while (c != null) : (c = msg(Id, c, "parentIntent", .{})) {
            switch (msg(isize, c, "intentKind", .{})) {
                1 => {
                    const level = msg(usize, c, "headerLevel", .{});
                    base = if (level == 1) 1 else if (level == 2) 2 else 3;
                    if (i > 0) flags |= 4;
                },
                4 => {
                    flags |= 1;
                    const ordered = msg(isize, msg(Id, c, "parentIntent", .{}), "intentKind", .{}) == 2;
                    // stringWithFormat: is variadic, which msg can't pass on arm64.
                    var num: [24]u8 = undefined;
                    if (fresh and prefix == null) prefix = if (ordered) objc.str(std.fmt.bufPrint(&num, "{d}. ", .{msg(isize, c, "ordinal", .{})}) catch "") else objc.str("• ");
                },
                5 => { base = 4; attr(part, key_back, panel, all); },
                6 => { ink = muted; flags |= 2; },
                7 => if (fresh) { prefix = objc.str("────────────────────────"); },
                else => {},
            }
        }
        const inline_intent = msg(usize, msg(Id, attrs, "objectForKey:", .{key_inline}), "unsignedIntegerValue", .{});
        if (inline_intent & 4 != 0) base = 4;
        const linked = msg(Id, attrs, "objectForKey:", .{key_link}) != null;
        if (linked) ink = link;
        attr(part, key_font, font(base, inline_intent & 3), all);
        attr(part, key_color, ink, all);
        if (linked) attr(part, key_line, msg(Id, objc.class("NSNumber"), "numberWithInteger:", .{@as(isize, 1)}), all);
        attr(part, key_style, style(flags), all);
        msg(void, part, "removeAttribute:range:", .{ key_intent, all });
        if (prefix != null) msg(void, part, "replaceCharactersInRange:withString:", .{ Range{ .loc = 0, .len = 0 }, prefix });
        msg(void, out, "appendAttributedString:", .{part});
        previous = identity;
        i += r.len;
    }
    const clip = msg(Id, msg(Id, text, "enclosingScrollView", .{}), "contentView", .{});
    const position = msg(objc.Rect, clip, "bounds", .{});
    const store = msg(Id, text, "textStorage", .{});
    const origin = msg(objc.Point, text, "textContainerOrigin", .{});
    const old_len = msg(usize, store, "length", .{});
    const old = msg(Id, msg(Id, store, "string", .{}), "copy", .{});
    defer msg(void, old, "release", .{});
    // The paragraph at the top of the view: its first character, and how far the view's top is below it.
    // TextKit 2 is asked directly; touching the view's layoutManager would switch it to TextKit 1,
    // which draws differently.
    const tlm = msg(Id, text, "textLayoutManager", .{});
    const tcs = msg(Id, text, "textContentStorage", .{});
    var anchor: usize = 0;
    var above: f64 = 0;
    var found = false;
    if (old_len > 0 and tlm != null) {
        const frag = msg(Id, tlm, "textLayoutFragmentForPosition:", .{objc.Point{ .x = 0, .y = position.y - origin.y }});
        if (frag != null) {
            anchor = msg(usize, tcs, "offsetFromLocation:toLocation:", .{ msg(Id, msg(Id, tcs, "documentRange", .{}), "location", .{}), msg(Id, msg(Id, frag, "rangeInElement", .{}), "location", .{}) });
            above = position.y - origin.y - msg(objc.Rect, frag, "layoutFragmentFrame", .{}).y;
            found = true;
        }
    }
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
    msg(void, text, "setLinkTextAttributes:", .{msg(Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ link, key_color })});
    msg(void, store, "setAttributedString:", .{out});
    const new_len = msg(usize, store, "length", .{});
    if (!found or new_len == 0) {
        msg(void, text, "scrollPoint:", .{objc.Point{ .x = position.x, .y = position.y }});
        return;
    }
    // The paragraph that was at the top of the view stays there: an edit above it shifts its index by
    // the change in length, one at or below it leaves the index alone.
    const kept = msg(usize, msg(Id, old, "commonPrefixWithString:options:", .{ msg(Id, store, "string", .{}), @as(usize, 0) }), "length", .{});
    const shifted: isize = @as(isize, @intCast(anchor)) + @as(isize, @intCast(new_len)) - @as(isize, @intCast(old_len));
    const at = if (anchor < kept) anchor else @min(@max(@as(usize, @intCast(@max(shifted, 0))), kept), new_len - 1);
    // Heights below the view are only estimated until laid out, so lay out all of it first.
    msg(void, tlm, "ensureLayoutForRange:", .{msg(Id, tcs, "documentRange", .{})});
    const place = msg(Id, tcs, "locationFromLocation:withOffset:", .{ msg(Id, msg(Id, tcs, "documentRange", .{}), "location", .{}), @as(isize, @intCast(at)) });
    const top = msg(objc.Rect, msg(Id, tlm, "textLayoutFragmentForLocation:", .{place}), "layoutFragmentFrame", .{}).y;
    msg(void, text, "scrollPoint:", .{objc.Point{ .x = position.x, .y = top + origin.y + above }});
}
