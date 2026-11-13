//! Foundation parses Markdown; AppKit lays out the read-only preview.
const std = @import("std");
const objc = @import("objc.zig");
const settings = @import("settings.zig");
const syntax = @import("syntax.zig");
const view = @import("view.zig");
const Id = objc.Id;
const msg = objc.msg;
const Range = extern struct { loc: usize, len: usize };
var window: Id = null;
var text: Id = null;
var target: Id = null;
/// The NSTextView subclass that paints code panels, quote bars and rules behind the text.
var text_class: Id = null;
/// The window that last showed the previewed tab; its theme paints the preview.
var owner: Id = null;
/// The previewed tab's path, for the title.
var path: Id = null;
var theme: settings.Theme = undefined;
var fade = false;
/// The previewed tab's id and the edit count last scheduled or rendered.
var seen_id: u32 = std.math.maxInt(u32);
var seen_changes: u64 = 0;
/// The text last rendered, kept so a theme change still repaints after its tab closes.
var source: Id = null;
/// The editor's font (a PostScript name, "" for the system's monospaced font), size and line
/// height. The preview's type scales with the size, and code uses the font.
var face_buf: [128]u8 = undefined;
var face_len: usize = 0;
var ed_size: f64 = settings.default_size;
var ed_spacing: f64 = default_spacing;
const default_spacing = @as(settings.Settings, .{}).spacing;
/// Fonts and paragraph styles don't depend on the theme, so each is made once and kept until
/// the editor's typography changes.
/// `fonts[block][traits]`: body, three heading sizes, mono; each with italic and bold added.
var fonts: [5][4]Id = @splat(@splat(null));
/// Indexed by a key of the `*_f` flags below with the list depth (0 to 3) above them.
var styles: [512]Id = @splat(null);
const list_f = 1;
const quote_f = 2;
const gap_f = 4;
const code_f = 8;
const first_f = 16;
const last_f = 32;
const rule_f = 64;
const depth_shift = 7;

/// A stretch of the rendered text that gets a shape painted behind it.
const Deco = struct {
    start: u32,
    end: u32,
    kind: enum(u8) { code, quote, rule },
    /// The block's identity, so a block's later runs join its first.
    id: usize,
    /// The paragraph style key of the block's runs.
    key: u16,
};
var decos: [512]Deco = undefined;
var deco_max_end: [decos.len]u32 = undefined;
var deco_n: usize = 0;
/// Where each heading starts in the rendered text, for `#heading` links.
var heads: [256]u32 = undefined;
var head_n: usize = 0;
/// A kind per byte of one code line.
var kinds_buf: [4096]syntax.Kind = undefined;

fn color(rgb: settings.Rgb) Id {
    return msg(Id, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ rgb[0], rgb[1], rgb[2], @as(f64, 1) });
}
fn attr(s: Id, key: Id, value: Id, r: Range) void {
    msg(void, s, "addAttribute:value:range:", .{ key, value, r });
}
/// How much bigger than at the default size the editor's text is.
fn scale() f64 {
    return ed_size / settings.default_size;
}
fn closed(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    msg(void, objc.class("NSObject"), "cancelPreviousPerformRequestsWithTarget:", .{target});
    msg(void, path, "release", .{});
    path = null;
    owner = null;
    window = null;
    seen_id = 0;
    msg(void, source, "release", .{});
    source = null;
    text = null;
    fade = false;
    deco_n = 0;
    head_n = 0;
}
pub fn shownFor(id: u32) bool {
    return window != null and seen_id == id;
}
pub fn close(w: Id) void {
    if (owner == w) msg(void, window, "close", .{});
}
fn closeAction(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    close(owner);
}
/// File > Close Tab (⌘W) with the preview key: its delegate answers `closeTab:`, so the shortcut closes the window.
fn closeTab(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    msg(void, window, "performClose:", .{@as(Id, null)});
}
/// Edit > Find (⌘F), Find Next (⌘G) and Find Previous (⇧⌘G) with the preview key: the window's
/// delegate answers them and hands them to the text view's find bar.
fn finder(tag: isize) void {
    if (text == null) return;
    const item = objc.new("NSMenuItem");
    defer msg(void, item, "release", .{});
    msg(void, item, "setTag:", .{tag});
    msg(void, text, "performFindPanelAction:", .{item});
}
fn findText(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    finder(1);
}
fn findNext(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    finder(2);
}
fn findPrevious(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    finder(3);
}
/// Tab `id` was saved under a new path.
pub fn rename(id: u32, new: []const u8) void {
    if (window != null and id == seen_id) {
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
/// The widest the text column gets, in points at the default size.
const column = 680.0;
/// Keeps the text in a centered column at most `column` wide by widening
/// the side insets as the window grows.
fn resized(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    if (text == null) return;
    const w = msg(objc.Rect, text, "frame", .{}).w;
    msg(void, text, "setTextContainerInset:", .{objc.Point{ .x = @max(28, @floor((w - column * scale()) / 2)), .y = 24 }});
}
/// `th` is the theme the editor draws with: zen's grey and Increase Contrast included.
pub fn update(d: anytype, th: *const settings.Theme) void {
    if (window == null) return;
    // Only the previewed tab's edits render; any card in its window passes on a theme change.
    const mine = d.file.id == seen_id;
    if (mine) owner = d.win.window else if (owner != d.win.window) return;
    // A caret move or scroll changes nothing: `changes` counts every edit, undo and redo.
    const changed = mine and seen_changes != d.file.ed.buf.changes;
    const same_theme = std.meta.eql(theme, th.*);
    if (!changed and same_theme) return;
    if (changed) seen_changes = d.file.ed.buf.changes;
    fade = fade or !same_theme;
    theme = th.*;
    // `later` cancels the render already waiting, so a burst of typing renders once.
    objc.later(target, "render:", null, 0.15);
}
/// The editor's font (a PostScript name, "" for the system's monospaced font), size and line
/// height changed: the preview's headings, body and code scale with them.
pub fn setTypography(name: []const u8, size: f64, spacing: f64) void {
    const n = @min(name.len, face_buf.len);
    if (size == ed_size and spacing == ed_spacing and std.mem.eql(u8, face_buf[0..face_len], name[0..n])) return;
    @memcpy(face_buf[0..n], name[0..n]);
    face_len = n;
    ed_size = size;
    ed_spacing = spacing;
    for (&fonts) |*row| {
        for (row) |*f| {
            if (f.* != null) msg(void, f.*, "release", .{});
            f.* = null;
        }
    }
    for (&styles) |*s| {
        if (s.* != null) msg(void, s.*, "release", .{});
        s.* = null;
    }
    if (window == null) return;
    resized(null, null, null);
    objc.later(target, "render:", null, 0.15);
}
/// Scrolls the preview to `fraction` of the way down (0 the top, 1 the bottom), so it follows the editor.
pub fn syncScroll(fraction: f64) void {
    if (text == null) return;
    const scroll = msg(Id, text, "enclosingScrollView", .{});
    const clip = msg(Id, scroll, "contentView", .{});
    const b = msg(objc.Rect, clip, "bounds", .{});
    const room = @max(0, msg(objc.Rect, text, "frame", .{}).h - b.h);
    msg(void, clip, "setBoundsOrigin:", .{objc.Point{ .x = b.x, .y = std.math.clamp(fraction, 0, 1) * room }});
    msg(void, scroll, "reflectScrolledClipView:", .{clip});
}
pub fn toggle(d: anytype, th: *const settings.Theme) void {
    if (window != null) { msg(void, window, "close", .{}); return; }
    if (target == null) {
        const c = objc.ClassBuilder.begin("NSObject", "ZePreview");
        c.method("render:", @ptrCast(&render), "v@:@");
        c.method("windowWillClose:", @ptrCast(&closed), "v@:@");
        c.method("windowDidResize:", @ptrCast(&resized), "v@:@");
        c.method("markdownPreview:", @ptrCast(&closeAction), "v@:@");
        c.method("closeTab:", @ptrCast(&closeTab), "v@:@");
        c.method("findText:", @ptrCast(&findText), "v@:@");
        c.method("findNext:", @ptrCast(&findNext), "v@:@");
        c.method("findPrevious:", @ptrCast(&findPrevious), "v@:@");
        c.method("textView:clickedOnLink:atIndex:", @ptrCast(&clicked), "B@:@@Q");
        target = msg(Id, msg(Id, c.finish(), "alloc", .{}), "init", .{});
        const t = objc.ClassBuilder.begin("NSTextView", "ZagPreviewText");
        t.method("drawViewBackgroundInRect:", @ptrCast(&backdrop), "v@:{CGRect=dddd}");
        text_class = t.finish();
    }
    owner = d.win.window;
    path = msg(Id, objc.str(d.file.path orelse ""), "mutableCopy", .{});
    seen_id = d.file.id;
    seen_changes = d.file.ed.buf.changes;
    theme = th.*;
    const frame: objc.Rect = .{ .w = 620, .h = 700 };
    window = msg(Id, msg(Id, objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ frame, @as(usize, 1 | 2 | 4 | 8), @as(usize, 2), false });
    retitle();
    msg(void, window, "setTitlebarAppearsTransparent:", .{true});
    msg(void, window, "setDelegate:", .{target});
    const scroll = msg(Id, msg(Id, objc.class("NSScrollView"), "alloc", .{}), "initWithFrame:", .{frame});
    text = msg(Id, msg(Id, text_class, "alloc", .{}), "initWithFrame:", .{frame});
    msg(void, text, "setEditable:", .{false});
    msg(void, text, "setUsesFindBar:", .{true});
    msg(void, text, "setIncrementalSearchingEnabled:", .{true});
    msg(void, text, "setDelegate:", .{target});
    msg(void, text, "setTextContainerInset:", .{objc.Point{ .x = 28, .y = 24 }});
    msg(void, text, "setAutoresizingMask:", .{@as(usize, 2)});
    msg(void, msg(Id, text, "textContainer", .{}), "setWidthTracksTextView:", .{true});
    msg(void, scroll, "setHasVerticalScroller:", .{true});
    msg(void, scroll, "setDocumentView:", .{text});
    msg(void, window, "setContentView:", .{scroll});
    msg(void, scroll, "release", .{});
    msg(void, text, "release", .{});
    // A saved frame wins; only a first opening is placed beside the editor's window.
    const name_key = objc.str("ZagPreview");
    if (!msg(bool, window, "setFrameUsingName:", .{name_key})) {
        const fr = msg(objc.Rect, d.win.window, "frame", .{});
        msg(void, window, "setFrameTopLeftPoint:", .{objc.Point{ .x = fr.x + fr.w - 80, .y = fr.y + fr.h }});
    }
    _ = msg(bool, window, "setFrameAutosaveName:", .{name_key});
    resized(null, null, null);
    render(null, null, null);
    msg(void, window, "orderFront:", .{@as(Id, null)});
}
/// The editor's font at `size`, or the system's monospaced one.
fn mono(size: f64) Id {
    if (face_len > 0) {
        const f = msg(Id, objc.class("NSFont"), "fontWithName:size:", .{ objc.str(face_buf[0..face_len]), size });
        if (f != null) return f;
    }
    return msg(Id, objc.class("NSFont"), "monospacedSystemFontOfSize:weight:", .{ size, @as(f64, 0) });
}
/// The font for block kind `base` (0 body, 1 to 3 headings, 4 mono) with the italic (1) and bold (2) traits.
fn font(base: usize, traits: usize) Id {
    const slot = &fonts[base][traits];
    if (slot.* == null) {
        const class = objc.class("NSFont");
        const k = scale();
        const f = switch (base) {
            0 => msg(Id, class, "systemFontOfSize:", .{15 * k}),
            1...3 => msg(Id, class, "systemFontOfSize:weight:", .{ k * @as(f64, if (base == 1) 26 else if (base == 2) 20 else 17), @as(f64, 0.3) }),
            else => mono(ed_size),
        };
        slot.* = msg(Id, if (traits == 0) f else msg(Id, msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{}), "convertFont:toHaveTrait:", .{ f, traits }), "retain", .{});
    }
    return slot.*;
}
/// Prose line height: 1.35 at the editor's default line height, following it up and down.
fn lineHeight() f64 {
    return std.math.clamp(1.35 * ed_spacing / default_spacing, 1.1, 2.2);
}
/// The first-line and wrapped-line indents, unscaled, for style key `key`, before a code
/// block's own padding.
fn indents(key: usize) [2]f64 {
    const depth: f64 = @floatFromInt(key >> depth_shift);
    var first: f64 = 0;
    var head: f64 = 0;
    if (key & quote_f != 0) {
        first += 24;
        head += 24;
    }
    if (key & list_f != 0) {
        first += 24 * depth;
        head += 24 * (depth + 1);
    }
    // A code block in a list item lines up with the item's text, not its bullet.
    if (key & code_f != 0) first = head;
    return .{ first, head };
}
/// The paragraph style for `key`: the `*_f` flags and the list depth. Never changed after it's made.
fn style(key: usize) Id {
    const slot = &styles[key];
    if (slot.* == null) {
        const k = scale();
        const code = key & code_f != 0;
        const p = objc.new("NSMutableParagraphStyle");
        msg(void, p, "setLineHeightMultiple:", .{if (code) @max(1.1, lineHeight() * 0.9) else lineHeight()});
        const after: f64 = if (code) (if (key & last_f != 0) 14 else 0) else if (key & rule_f != 0) 8 else if (key & list_f != 0) 4 else 10;
        msg(void, p, "setParagraphSpacing:", .{after * k});
        const before: f64 = if (key & gap_f != 0) 18 else if (key & first_f != 0) 14 else if (key & rule_f != 0) 8 else 0;
        if (before > 0) msg(void, p, "setParagraphSpacingBefore:", .{before * k});
        const in = indents(key);
        const pad: f64 = if (code) 14 else 0;
        msg(void, p, "setFirstLineHeadIndent:", .{(in[0] + pad) * k});
        msg(void, p, "setHeadIndent:", .{(in[1] + pad) * k});
        if (code) msg(void, p, "setTailIndent:", .{-pad * k});
        slot.* = p;
    }
    return slot.*;
}
/// Widens column `col` of the table to fit the cell that runs from `start` to the end of `out`.
fn measure(out: Id, start: usize, col: usize, widths: []f64) void {
    if (col >= widths.len) return;
    const len = msg(usize, out, "length", .{});
    const sub = msg(Id, out, "attributedSubstringFromRange:", .{Range{ .loc = start, .len = len - start }});
    widths[col] = @max(widths[col], msg(objc.Size, sub, "size", .{}).w);
}
/// Lines up the table that runs from `start` to the end of `out`: a left tab stop after each column's widest cell.
fn tabulate(out: Id, start: usize, widths: []const f64, key_style: Id) void {
    const p = objc.new("NSMutableParagraphStyle");
    defer msg(void, p, "release", .{});
    msg(void, p, "setLineHeightMultiple:", .{lineHeight()});
    msg(void, p, "setParagraphSpacing:", .{6 * scale()});
    const stops = objc.new("NSMutableArray");
    defer msg(void, stops, "release", .{});
    const none = msg(Id, objc.class("NSDictionary"), "dictionary", .{});
    var x: f64 = 0;
    for (widths) |w| {
        x += w + 24 * scale();
        const tab = msg(Id, msg(Id, objc.class("NSTextTab"), "alloc", .{}), "initWithTextAlignment:location:options:", .{ @as(isize, 0), x, none });
        msg(void, stops, "addObject:", .{tab});
        msg(void, tab, "release", .{});
    }
    msg(void, p, "setTabStops:", .{stops});
    attr(out, key_style, p, .{ .loc = start, .len = msg(usize, out, "length", .{}) - start });
}
/// Notes that `start..end` of the rendered text belongs to block `id` of `kind`, joining the
/// stretch already noted for that block.
fn note(kind: @FieldType(Deco, "kind"), id: usize, key: usize, start: usize, end: usize) void {
    var j = deco_n;
    while (j > 0) {
        j -= 1;
        if (decos[j].kind != kind) continue;
        if (id != 0 and decos[j].id == id) {
            decos[j].end = @intCast(end);
            return;
        }
        break;
    }
    if (deco_n == decos.len or end <= start) return;
    decos[deco_n] = .{ .start = @intCast(start), .end = @intCast(end), .kind = kind, .id = id, .key = @intCast(key) };
    deco_n += 1;
}
/// A path syntax.forPath reads a fenced block's language from: "x.<ext>" for hint `hint`.
fn langPath(hint: []const u8, buf: []u8) []const u8 {
    const aliases = [_][2][]const u8{
        .{ "python", "py" },     .{ "javascript", "js" }, .{ "typescript", "ts" }, .{ "rust", "rs" },
        .{ "shell", "sh" },      .{ "console", "sh" },    .{ "ruby", "rb" },       .{ "golang", "go" },
        .{ "c++", "cpp" },       .{ "objc", "m" },        .{ "kotlin", "kt" },     .{ "csharp", "cs" },
        .{ "objective-c", "m" }, .{ "jsonc", "json" },
    };
    var low: [24]u8 = undefined;
    if (hint.len > low.len) return "";
    for (hint, 0..) |ch, j| low[j] = std.ascii.toLower(ch);
    var ext: []const u8 = low[0..hint.len];
    for (aliases) |a| {
        if (std.mem.eql(u8, a[0], ext)) ext = a[1];
    }
    return std.fmt.bufPrint(buf, "x.{s}", .{ext}) catch "";
}
/// Colors a fenced code block's text by syntax.zig's lexer for the block's language `hint`.
fn paint(part: Id, hint: Id, key_color: Id) void {
    var buf: [32]u8 = undefined;
    const lang = syntax.forPath(langPath(objc.utf8(hint), &buf));
    const bytes = objc.utf8(msg(Id, part, "string", .{}));
    var kind_colors: [7]Id = undefined;
    for (0..7) |ki| kind_colors[ki] = color(theme.kinds[ki]);
    var state: syntax.State = .normal;
    // `u` counts UTF-16 units, the attributed string's indexes.
    var u: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) u += 1;
        first = false;
        const kinds: ?[]syntax.Kind = if (line.len <= kinds_buf.len) kinds_buf[0..line.len] else null;
        state = syntax.lexLine(lang, line, state, kinds);
        var run_start = u;
        var run_kind: syntax.Kind = .text;
        for (line, 0..) |b, j| {
            const kd = if (kinds) |ks| ks[j] else .text;
            if (b & 0xC0 != 0x80 and kd != run_kind) {
                if (run_kind != .text and u > run_start) attr(part, key_color, kind_colors[@intFromEnum(run_kind)], .{ .loc = run_start, .len = u - run_start });
                run_start = u;
                run_kind = kd;
            }
            // A lead byte of four starts a surrogate pair; continuation bytes add nothing.
            u += @as(usize, if (b & 0xC0 == 0x80) 0 else if (b >= 0xF0) 2 else 1);
        }
        if (run_kind != .text and u > run_start) attr(part, key_color, kind_colors[@intFromEnum(run_kind)], .{ .loc = run_start, .len = u - run_start });
    }
}
fn render(_: Id, _: objc.Sel, _: Id) callconv(.c) void {
    if (view.previewText(seen_id)) |bytes| {
        msg(void, source, "release", .{});
        source = null;
        if (std.unicode.utf8ValidateSlice(bytes)) {
            source = msg(Id, msg(Id, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len }), "retain", .{});
        } else {
            var clean: std.ArrayList(u8) = .empty;
            defer clean.deinit(view.gpa);
            clean.ensureTotalCapacity(view.gpa, bytes.len) catch {};
            var j: usize = 0;
            while (j < bytes.len) {
                const n = std.unicode.utf8ByteSequenceLength(bytes[j]) catch 0;
                if (n > 0 and j + n <= bytes.len) {
                    if (std.unicode.utf8Decode(bytes[j .. j + n])) |_| {
                        clean.appendSlice(view.gpa, bytes[j .. j + n]) catch return;
                        j += n;
                        continue;
                    } else |_| {}
                }
                clean.appendSlice(view.gpa, "\u{FFFD}") catch return;
                j += 1;
            }
            source = msg(Id, msg(Id, objc.class("NSData"), "dataWithBytes:length:", .{ clean.items.ptr, clean.items.len }), "retain", .{});
        }
    }
    if (source == null) return;
    const options = objc.new("NSAttributedStringMarkdownParsingOptions");
    defer msg(void, options, "release", .{});
    msg(void, options, "setInterpretedSyntax:", .{@as(isize, 0)});
    // Relative links resolve against the file's folder.
    const folder: Id = if (msg(usize, path, "length", .{}) == 0) null else msg(Id, objc.class("NSURL"), "fileURLWithPath:isDirectory:", .{ msg(Id, path, "stringByDeletingLastPathComponent", .{}), true });
    const parsed = msg(Id, msg(Id, objc.class("NSAttributedString"), "alloc", .{}), "initWithMarkdown:options:baseURL:error:", .{ source, options, folder, @as(?*Id, null) });
    defer msg(void, parsed, "release", .{});
    const out = objc.new("NSMutableAttributedString");
    defer msg(void, out, "release", .{});
    const key_intent, const key_inline, const key_link = .{ objc.str("NSPresentationIntent"), objc.str("NSInlinePresentationIntent"), objc.str("NSLink") };
    const key_font, const key_color, const key_style, const key_back, const key_line = .{ objc.str("NSFont"), objc.str("NSColor"), objc.str("NSParagraphStyle"), objc.str("NSBackgroundColor"), objc.str("NSUnderline") };
    const fg, const link, const muted, const panel = .{ color(theme.fg), color(theme.kinds[@intFromEnum(syntax.Kind.function)]), color(theme.muted), color(theme.panel) };
    const text_out = msg(Id, out, "mutableString", .{});
    deco_n = 0;
    head_n = 0;
    var i: usize = 0;
    var previous: usize = 0;
    // The table being rendered and its current cell: identities, where each starts in `out`,
    // the cell's column and the widest cell seen in each column.
    var table: usize = 0;
    var table_start: usize = 0;
    var cell: usize = 0;
    var cell_start: usize = 0;
    var col: usize = 0;
    var widths: [16]f64 = @splat(0);
    // A ticked task's paragraph, whose text is muted.
    var done: usize = 0;
    // A code block's last newline is held back, and given back if the block goes on.
    var held = false;
    while (i < msg(usize, parsed, "length", .{})) {
        var r: Range = undefined;
        const attrs = msg(Id, parsed, "attributesAtIndex:effectiveRange:", .{ i, &r });
        const part = msg(Id, msg(Id, parsed, "attributedSubstringFromRange:", .{r}), "mutableCopy", .{});
        defer msg(void, part, "release", .{});
        const intent = msg(Id, attrs, "objectForKey:", .{key_intent});
        const identity = msg(usize, intent, "identity", .{});
        // A table cell's text joins its row's line, after a tab per column.
        const in_cell = msg(isize, intent, "intentKind", .{}) == 11;
        const row: Id = if (in_cell) msg(Id, intent, "parentIntent", .{}) else null;
        const block = if (in_cell) msg(usize, row, "identity", .{}) else identity;
        const this_cell = if (in_cell) identity else 0;
        const this_table = if (in_cell) msg(usize, msg(Id, row, "parentIntent", .{}), "identity", .{}) else 0;
        if (cell != 0 and this_cell != cell) measure(out, cell_start, col, &widths);
        if (table != 0 and this_table != table) tabulate(out, table_start, &widths, key_style);
        const fresh = block != previous;
        if ((fresh and i > 0) or held) msg(void, text_out, "appendString:", .{objc.str("\n")});
        held = false;
        if (in_cell and this_table != table) {
            table_start = msg(usize, out, "length", .{});
            widths = @splat(0);
        }
        if (in_cell and this_cell != cell) {
            const at: usize = @intCast(@max(msg(isize, intent, "column", .{}), 0));
            const tabs = if (fresh) at else @max(at -| col, 1);
            for (0..tabs) |_| msg(void, text_out, "appendString:", .{objc.str("\t")});
            cell_start = msg(usize, out, "length", .{});
            col = at;
        }
        table = this_table;
        cell = this_cell;
        var base: usize = 0;
        var ink = fg;
        var flags: usize = 0;
        var header: usize = 0;
        var heading = false;
        var prefix: Id = null;
        // The innermost list item, how many lists deep it is, the outermost quote and the code block.
        var item: Id = null;
        var items: usize = 0;
        var quote_id: usize = 0;
        var code_id: usize = 0;
        var hint: Id = null;
        var rule = false;
        var c = intent;
        while (c != null) : (c = msg(Id, c, "parentIntent", .{})) {
            switch (msg(isize, c, "intentKind", .{})) {
                1 => {
                    const level = msg(usize, c, "headerLevel", .{});
                    base = if (level == 1) 1 else if (level == 2) 2 else 3;
                    heading = true;
                    if (i > 0) flags |= gap_f;
                },
                4 => {
                    flags |= list_f;
                    if (item == null) item = c;
                    items += 1;
                },
                5 => {
                    base = 4;
                    flags |= code_f;
                    code_id = msg(usize, c, "identity", .{});
                    hint = msg(Id, c, "languageHint", .{});
                },
                6 => {
                    ink = muted;
                    flags |= quote_f;
                    quote_id = msg(usize, c, "identity", .{});
                },
                7 => rule = true,
                9 => header = 2,
                else => {},
            }
        }
        const depth: usize = @min(items -| 1, 3);
        flags |= depth << depth_shift;
        if (fresh and item != null) {
            const ordered = msg(isize, msg(Id, item, "parentIntent", .{}), "intentKind", .{}) == 2;
            // stringWithFormat: is variadic, which msg can't pass on arm64.
            var num: [24]u8 = undefined;
            const bullets = [_][]const u8{ "• ", "◦ ", "▪ " };
            prefix = objc.str(if (ordered) std.fmt.bufPrint(&num, "{d}. ", .{msg(isize, item, "ordinal", .{})}) catch "" else bullets[depth % bullets.len]);
            // A task's "[ ]" or "[x]" becomes a box, ticked or not.
            const lead = objc.utf8(msg(Id, part, "string", .{}));
            if (lead.len >= 4 and lead[0] == '[' and lead[2] == ']' and lead[3] == ' ' and (lead[1] == ' ' or lead[1] == 'x' or lead[1] == 'X')) {
                const ticked = lead[1] != ' ';
                msg(void, part, "deleteCharactersInRange:", .{Range{ .loc = 0, .len = 4 }});
                prefix = objc.str(if (ticked) "☑ " else "☐ ");
                if (ticked) done = block;
            }
        }
        if (rule) {
            flags |= rule_f;
            // A no-break space gives the rule's line a height to paint the rule across.
            if (fresh) prefix = objc.str("\u{00A0}");
        }
        if (code_id != 0) {
            const len = msg(usize, part, "length", .{});
            if (len > 0 and msg(u16, msg(Id, part, "string", .{}), "characterAtIndex:", .{len - 1}) == '\n') {
                msg(void, part, "deleteCharactersInRange:", .{Range{ .loc = len - 1, .len = 1 }});
                held = true;
            }
        }
        if (block == done and done != 0) ink = muted;
        const plain = ink;
        const all: Range = .{ .loc = 0, .len = msg(usize, part, "length", .{}) };
        const inline_intent = msg(usize, msg(Id, attrs, "objectForKey:", .{key_inline}), "unsignedIntegerValue", .{});
        // Code, fenced or inline, sits on the panel color.
        if (inline_intent & 4 != 0) base = 4;
        if (base == 4) attr(part, key_back, panel, all);
        const linked = msg(Id, attrs, "objectForKey:", .{key_link}) != null;
        if (linked) ink = link;
        attr(part, key_font, font(base, inline_intent & 3 | header), all);
        attr(part, key_color, ink, all);
        if (code_id != 0) paint(part, hint, key_color);
        if (linked) attr(part, key_line, msg(Id, objc.class("NSNumber"), "numberWithInteger:", .{@as(isize, 1)}), all);
        attr(part, key_style, style(flags), all);
        msg(void, part, "removeAttribute:range:", .{ key_intent, all });
        const start = msg(usize, out, "length", .{});
        // A bullet, number, box or rule gets body text's own look, never its item's bold, code or link.
        if (prefix != null) {
            const lead = msg(Id, msg(Id, objc.class("NSMutableAttributedString"), "alloc", .{}), "initWithString:", .{prefix});
            defer msg(void, lead, "release", .{});
            const whole: Range = .{ .loc = 0, .len = msg(usize, lead, "length", .{}) };
            attr(lead, key_font, font(0, 0), whole);
            attr(lead, key_color, plain, whole);
            attr(lead, key_style, style(flags), whole);
            msg(void, out, "appendAttributedString:", .{lead});
        }
        msg(void, out, "appendAttributedString:", .{part});
        const end = msg(usize, out, "length", .{});
        if (code_id != 0) note(.code, code_id, flags, start, end);
        if (quote_id != 0) note(.quote, quote_id, flags, start, end);
        if (rule) note(.rule, 0, flags, start, end);
        if (heading and fresh and head_n < heads.len) {
            heads[head_n] = @intCast(start);
            head_n += 1;
        }
        previous = block;
        i += r.len;
    }
    if (cell != 0) measure(out, cell_start, col, &widths);
    if (table != 0) tabulate(out, table_start, &widths, key_style);
    // A code block's first and last lines get the room its panel is painted in.
    for (decos[0..deco_n]) |dc| {
        if (dc.kind != .code) continue;
        const top = msg(Range, text_out, "paragraphRangeForRange:", .{Range{ .loc = dc.start, .len = 0 }});
        const bottom = msg(Range, text_out, "paragraphRangeForRange:", .{Range{ .loc = dc.end - 1, .len = 0 }});
        if (top.loc == bottom.loc) {
            attr(out, key_style, style(dc.key | first_f | last_f), top);
        } else {
            attr(out, key_style, style(dc.key | first_f), top);
            attr(out, key_style, style(dc.key | last_f), bottom);
        }
    }
    if (deco_n > 1) {
        for (1..deco_n) |di| {
            const cur = decos[di];
            var dj = di;
            while (dj > 0 and decos[dj - 1].start > cur.start) : (dj -= 1) decos[dj] = decos[dj - 1];
            decos[dj] = cur;
        }
    }
    var max_end: u32 = 0;
    for (0..deco_n) |di| {
        max_end = @max(max_end, decos[di].end);
        deco_max_end[di] = max_end;
    }
    const clip = msg(Id, msg(Id, text, "enclosingScrollView", .{}), "contentView", .{});
    const position = msg(objc.Rect, clip, "bounds", .{});
    const store = msg(Id, text, "textStorage", .{});
    const origin = msg(objc.Point, text, "textContainerOrigin", .{});
    const old_len = msg(usize, store, "length", .{});
    const old = msg(Id, msg(Id, store, "string", .{}), "copy", .{});
    defer msg(void, old, "release", .{});
    const selected = msg(Range, text, "selectedRange", .{});
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
    const layer = msg(Id, msg(Id, window, "contentView", .{}), "layer", .{});
    if (fade) {
        msg(void, layer, "addAnimation:forKey:", .{ view.themeFade(), objc.str("theme") });
        fade = false;
    } else if (old_len > 0 and !msg(bool, old, "isEqualToString:", .{text_out})) {
        // New text crossfades in rather than jumping.
        const t = msg(Id, objc.class("CATransition"), "animation", .{});
        msg(void, t, "setType:", .{objc.str("fade")});
        msg(void, t, "setDuration:", .{@as(f64, 0.12)});
        msg(void, t, "setTimingFunction:", .{msg(Id, objc.class("CAMediaTimingFunction"), "functionWithName:", .{objc.str("easeOut")})});
        msg(void, layer, "addAnimation:forKey:", .{ t, objc.str("render") });
    }
    msg(void, text, "setBackgroundColor:", .{color(theme.bg)});
    msg(void, window, "setBackgroundColor:", .{color(theme.bg)});
    msg(void, text, "setLinkTextAttributes:", .{msg(Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ link, key_color })});
    msg(void, store, "setAttributedString:", .{out});
    msg(void, text, "setNeedsDisplay:", .{true});
    const new_len = msg(usize, store, "length", .{});
    // An edit above an index shifts it by the change in length; one at or below it leaves it alone.
    const kept = msg(usize, msg(Id, old, "commonPrefixWithString:options:", .{ msg(Id, store, "string", .{}), @as(usize, 0) }), "length", .{});
    const delta: isize = @as(isize, @intCast(new_len)) - @as(isize, @intCast(old_len));
    const shift = struct {
        fn at(x: usize, k: usize, d: isize, n: usize) usize {
            if (x < k) return x;
            return @min(@max(@as(usize, @intCast(@max(@as(isize, @intCast(x)) + d, 0))), k), n);
        }
    }.at;
    if (old_len > 0) {
        const from = shift(selected.loc, kept, delta, new_len);
        const to = shift(selected.loc + selected.len, kept, delta, new_len);
        msg(void, text, "setSelectedRange:", .{Range{ .loc = from, .len = to -| from }});
    }
    if (!found or new_len == 0) {
        msg(void, text, "scrollPoint:", .{objc.Point{ .x = position.x, .y = position.y }});
        return;
    }
    // The paragraph that was at the top of the view stays there.
    const at = @min(shift(anchor, kept, delta, new_len), new_len - 1);
    // Heights below the view are only estimated until laid out, so lay out all of it first.
    msg(void, tlm, "ensureLayoutForRange:", .{msg(Id, tcs, "documentRange", .{})});
    const top = fragmentFrame(tlm, tcs, at).y;
    msg(void, text, "scrollPoint:", .{objc.Point{ .x = position.x, .y = top + origin.y + above }});
}
/// The layout fragment holding character `offset`, or null.
fn fragmentAt(tlm: Id, tcs: Id, offset: usize) Id {
    const place = msg(Id, tcs, "locationFromLocation:withOffset:", .{ msg(Id, msg(Id, tcs, "documentRange", .{}), "location", .{}), @as(isize, @intCast(offset)) });
    if (place == null) return null;
    return msg(Id, tlm, "textLayoutFragmentForLocation:", .{place});
}
fn fragmentFrame(tlm: Id, tcs: Id, offset: usize) objc.Rect {
    return msg(objc.Rect, fragmentAt(tlm, tcs, offset), "layoutFragmentFrame", .{});
}
/// The top of the first line (or with `bottom`, the bottom of the last line) of the paragraph
/// holding character `offset`, in text container coordinates.
fn lineEdge(tlm: Id, tcs: Id, offset: usize, bottom: bool) ?f64 {
    const frag = fragmentAt(tlm, tcs, offset);
    if (frag == null) return null;
    const fr = msg(objc.Rect, frag, "layoutFragmentFrame", .{});
    const lines = msg(Id, frag, "textLineFragments", .{});
    const line = if (bottom) msg(Id, lines, "lastObject", .{}) else msg(Id, lines, "firstObject", .{});
    if (line == null) return if (bottom) fr.y + fr.h else fr.y;
    const b = msg(objc.Rect, line, "typographicBounds", .{});
    return fr.y + b.y + (if (bottom) b.h else 0);
}
fn fill(ctx: Id, rgb: settings.Rgb, r: objc.Rect, radius: f64) void {
    objc.CGContextSetRGBFillColor(ctx, rgb[0], rgb[1], rgb[2], 1);
    if (radius <= 0 or r.w < 2 * radius or r.h < 2 * radius) return objc.CGContextFillRect(ctx, r);
    const shape = objc.CGPathCreateWithRoundedRect(r, radius, radius, null);
    objc.CGContextAddPath(ctx, shape);
    objc.CGContextFillPath(ctx);
    objc.CFRelease(shape.?);
}
/// Paints the background, then a bordered panel behind each code block, a bar beside each
/// quote and a line through each rule.
fn backdrop(self: Id, _: objc.Sel, dirty: objc.Rect) callconv(.c) void {
    const ctx = msg(Id, msg(Id, objc.class("NSGraphicsContext"), "currentContext", .{}), "CGContext", .{});
    fill(ctx, theme.bg, dirty, 0);
    if (self != text) return;
    const tlm = msg(Id, self, "textLayoutManager", .{});
    const tcs = msg(Id, self, "textContentStorage", .{});
    if (tlm == null or tcs == null) return;
    const len = msg(usize, msg(Id, self, "textStorage", .{}), "length", .{});
    const origin = msg(objc.Point, self, "textContainerOrigin", .{});
    const container = msg(Id, self, "textContainer", .{});
    const pad = msg(f64, container, "lineFragmentPadding", .{});
    const width = msg(objc.Size, container, "size", .{}).w;
    const k = scale();
    const left = origin.x + pad;
    const right = origin.x + width - pad;
    if (deco_n == 0 or len == 0) return;
    var lo: usize = 0;
    var hi: usize = deco_n;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const hit = deco_max_end[mid] > 0 and
            (lineEdge(tlm, tcs, @min(deco_max_end[mid], len) - 1, true) orelse 0) + origin.y + 12 * k >= dirty.y;
        if (hit) hi = mid else lo = mid + 1;
    }
    for (decos[lo..deco_n]) |dc| {
        if (dc.end == 0 or dc.end > len) continue;
        const top = origin.y + (lineEdge(tlm, tcs, dc.start, false) orelse continue);
        if (top - 12 * k > dirty.y + dirty.h) break;
        const bottom = origin.y + (lineEdge(tlm, tcs, dc.end - 1, true) orelse continue);
        if (bottom + 12 * k < dirty.y) continue;
        switch (dc.kind) {
            .code => {
                const x = left + indents(dc.key)[1] * k;
                const box: objc.Rect = .{ .x = x, .y = top - 8 * k, .w = @max(0, right - x), .h = bottom - top + 16 * k };
                fill(ctx, theme.rule, box, 6 * k);
                fill(ctx, theme.panel, .{ .x = box.x + 1, .y = box.y + 1, .w = @max(0, box.w - 2), .h = @max(0, box.h - 2) }, 6 * k - 1);
            },
            .quote => {
                const x = left + 6 * k;
                fill(ctx, theme.muted, .{ .x = x, .y = top, .w = 3 * k, .h = bottom - top }, 1.5 * k);
            },
            .rule => fill(ctx, theme.rule, .{ .x = left, .y = @round((top + bottom) / 2), .w = @max(0, right - left), .h = 1 }, 0),
        }
    }
}
/// Lowercases `s` the way GitHub makes a heading's anchor: letters, digits, `-` and `_` stay,
/// spaces become `-`, the rest goes.
fn slug(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (n == buf.len) break;
        const keep: ?u8 = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else if (ch == '-' or ch == '_' or ch >= 0x80) ch else if (ch == ' ') '-' else null;
        if (keep) |b| {
            buf[n] = b;
            n += 1;
        }
    }
    return buf[0..n];
}
/// Glides the preview to the heading whose anchor is `fragment`; false when none matches.
fn jump(fragment: Id) bool {
    if (text == null) return false;
    var want_buf: [256]u8 = undefined;
    const want = slug(objc.utf8(msg(Id, fragment, "stringByRemovingPercentEncoding", .{}) orelse fragment), &want_buf);
    const s = msg(Id, msg(Id, text, "textStorage", .{}), "string", .{});
    const len = msg(usize, s, "length", .{});
    for (heads[0..head_n]) |h| {
        if (h >= len) continue;
        const r = msg(Range, s, "paragraphRangeForRange:", .{Range{ .loc = h, .len = 0 }});
        var buf: [256]u8 = undefined;
        if (!std.mem.eql(u8, slug(objc.utf8(msg(Id, s, "substringWithRange:", .{r})), &buf), want)) continue;
        const tlm = msg(Id, text, "textLayoutManager", .{});
        const tcs = msg(Id, text, "textContentStorage", .{});
        if (tlm == null) return false;
        msg(void, tlm, "ensureLayoutForRange:", .{msg(Id, tcs, "documentRange", .{})});
        const scroll = msg(Id, text, "enclosingScrollView", .{});
        const clip = msg(Id, scroll, "contentView", .{});
        const b = msg(objc.Rect, clip, "bounds", .{});
        const room = @max(0, msg(objc.Rect, text, "frame", .{}).h - b.h);
        const y = fragmentFrame(tlm, tcs, h).y + msg(objc.Point, text, "textContainerOrigin", .{}).y - 12 * scale();
        const ac = objc.class("NSAnimationContext");
        msg(void, ac, "beginGrouping", .{});
        const now = msg(Id, ac, "currentContext", .{});
        msg(void, now, "setDuration:", .{@as(f64, 0.16)});
        msg(void, now, "setTimingFunction:", .{msg(Id, objc.class("CAMediaTimingFunction"), "functionWithName:", .{objc.str("easeOut")})});
        msg(void, msg(Id, clip, "animator", .{}), "setBoundsOrigin:", .{objc.Point{ .x = b.x, .y = std.math.clamp(y, 0, room) }});
        msg(void, ac, "endGrouping", .{});
        return true;
    }
    return false;
}
/// A click on a link: `#heading` glides to that heading, a file opens in Zag, and anything
/// else (a web page, mail) opens in its own app.
fn clicked(_: Id, _: objc.Sel, _: Id, link: Id, _: usize) callconv(.c) bool {
    const url = if (msg(bool, link, "isKindOfClass:", .{objc.class("NSString")})) msg(Id, objc.class("NSURL"), "URLWithString:", .{link}) else link;
    if (url == null) return false;
    const fragment = msg(Id, url, "fragment", .{});
    const file = msg(bool, url, "isFileURL", .{});
    const scheme = msg(Id, url, "scheme", .{});
    const to: Id = if (file) msg(Id, msg(Id, msg(Id, url, "absoluteURL", .{}), "URLByStandardizingPath", .{}), "path", .{}) else null;
    if (fragment != null and msg(usize, fragment, "length", .{}) > 0) {
        // A link to this file, or the bare anchor resolved against its folder.
        const here = path != null and msg(usize, path, "length", .{}) > 0;
        const own = scheme == null or (to != null and here and (msg(bool, to, "isEqualToString:", .{path}) or
            msg(bool, to, "isEqualToString:", .{msg(Id, path, "stringByDeletingLastPathComponent", .{})})));
        if (own) {
            if (!jump(fragment)) NSBeep();
            return true;
        }
    }
    if (to != null) {
        if (msg(bool, msg(Id, objc.class("NSFileManager"), "defaultManager", .{}), "fileExistsAtPath:", .{to})) view.openFile(objc.utf8(to)) else NSBeep();
        return true;
    }
    if (scheme == null) return false;
    _ = msg(bool, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{url});
    return true;
}
extern fn NSBeep() void;
