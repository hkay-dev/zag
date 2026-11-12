//! VoiceOver: each card's text as a text area, a card's tabs as radio
//! buttons in a tab group, and the sidebar's rows as an outline. The window
//! draws itself in one view, so these elements stand in for what it draws.
//! They're made only when VoiceOver asks for them, kept so it can follow one
//! from question to question, and let go when what they stand for goes.
//! Ranges count UTF-16 units, as NSString does; the text is UTF-8 bytes.
const std = @import("std");
const objc = @import("objc.zig");
const editor = @import("editor.zig");
const buffer = @import("buffer.zig");
const view = @import("view.zig");
const ax = view.ax;
const Doc = ax.Card;
const Win = ax.Window;
const Id = objc.Id;
const Sel = objc.Sel;
const Rect = objc.Rect;
const Point = objc.Point;
const msg = objc.msg;
const gpa = view.gpa;

extern fn NSAccessibilityPostNotification(element: Id, name: Id) void;

const Range = extern struct { loc: usize = 0, len: usize = 0 };

const Kind = enum(u8) { text, tabs, tab, outline, row };

/// What an element stands for: its kind, the card or window it's in, and
/// for a tab its id, for a row a hash of its path.
const Key = struct { kind: Kind, owner: usize, key: u64 };
const Held = struct { obj: Id, stamp: u32 };
const Entry = struct { key: Key, h: Held };

fn before(a: Key, b: Key) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    if (a.owner != b.owner) return a.owner < b.owner;
    return a.key < b.key;
}

/// Where `k` is, or would go.
fn lowerBound(k: Key) usize {
    var lo: usize = 0;
    var hi = held.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (before(held.items[mid].key, k)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn find(k: Key) ?*Held {
    const i = lowerBound(k);
    if (i < held.items.len and !before(k, held.items[i].key)) return &held.items[i].h;
    return null;
}

/// Every element made so far, retained.
/// Sorted by key, so a lookup is a binary search.
var held: std.ArrayList(Entry) = .empty;
/// Bumped each time a list of children is built, to tell which ones it kept.
var stamp: u32 = 0;
var classes: [5]Id = @splat(null);

/// Each element's instance variables. `owner` is 0 once it's let go.
/// A row keeps where it last was in the tree; a text area keeps the tab,
/// change count and selection it last told VoiceOver about.
const Field = enum { owner, key, idx, gen, id, changes, cur, anchor };
const field_names = @typeInfo(Field).@"enum".field_names;
var offs: [field_names.len]usize = undefined;

fn slot(obj: Id, comptime fl: Field) *usize {
    return @ptrFromInt(@intFromPtr(obj.?) + offs[@intFromEnum(fl)]);
}

const ns_range = "{_NSRange=QQ}";
const ns_rect = "{CGRect={CGPoint=dd}{CGSize=dd}}";

/// Adds VoiceOver's questions to the window's view and makes the element
/// classes. Call once, while the view's class is being built.
pub fn addViewMethods(c: objc.ClassBuilder) void {
    c.method("accessibilityChildren", @ptrCast(&viewChildren), "@@:");
    c.method("accessibilityFocusedUIElement", @ptrCast(&viewFocused), "@@:");
    c.method("accessibilityHitTest:", @ptrCast(&viewHit), "@@:{CGPoint=dd}");

    const t = begin("ZeAxText");
    t.method("accessibilityFrame", @ptrCast(&textFrame), ns_rect ++ "@:");
    t.method("accessibilityLabel", @ptrCast(&textLabel), "@@:");
    t.method("accessibilityValue", @ptrCast(&textValue), "@@:");
    t.method("accessibilityNumberOfCharacters", @ptrCast(&textCount), "q@:");
    t.method("accessibilitySelectedText", @ptrCast(&selText), "@@:");
    t.method("accessibilitySelectedTextRange", @ptrCast(&selRange), ns_range ++ "@:");
    t.method("accessibilitySelectedTextRanges", @ptrCast(&selRanges), "@@:");
    t.method("setAccessibilitySelectedTextRange:", @ptrCast(&setSelRange), "v@:" ++ ns_range);
    t.method("accessibilityInsertionPointLineNumber", @ptrCast(&caretLine), "q@:");
    t.method("accessibilityVisibleCharacterRange", @ptrCast(&visibleRange), ns_range ++ "@:");
    t.method("accessibilityLineForIndex:", @ptrCast(&lineForIndex), "q@:q");
    t.method("accessibilityRangeForLine:", @ptrCast(&rangeForLine), ns_range ++ "@:q");
    t.method("accessibilityStringForRange:", @ptrCast(&stringForRange), "@@:" ++ ns_range);
    t.method("accessibilityAttributedStringForRange:", @ptrCast(&attributedForRange), "@@:" ++ ns_range);
    t.method("accessibilityFrameForRange:", @ptrCast(&frameForRange), ns_rect ++ "@:" ++ ns_range);
    t.method("accessibilityRangeForPosition:", @ptrCast(&rangeForPosition), ns_range ++ "@:{CGPoint=dd}");
    t.method("accessibilityRangeForIndex:", @ptrCast(&rangeForIndex), ns_range ++ "@:q");
    t.method("accessibilityStyleRangeForIndex:", @ptrCast(&styleRange), ns_range ++ "@:q");
    t.method("isAccessibilityFocused", @ptrCast(&textFocused), "c@:");
    t.method("setAccessibilityFocused:", @ptrCast(&setTextFocused), "v@:c");
    classes[@intFromEnum(Kind.text)] = t.finish();

    const g = begin("ZeAxTabs");
    g.method("accessibilityFrame", @ptrCast(&tabsFrame), ns_rect ++ "@:");
    g.method("accessibilityChildren", @ptrCast(&tabsChildren), "@@:");
    g.method("accessibilityTabs", @ptrCast(&tabsChildren), "@@:");
    classes[@intFromEnum(Kind.tabs)] = g.finish();

    const b = begin("ZeAxTab");
    b.method("accessibilityFrame", @ptrCast(&tabFrame), ns_rect ++ "@:");
    b.method("accessibilityTitle", @ptrCast(&tabTitle), "@@:");
    b.method("accessibilityValue", @ptrCast(&tabValue), "@@:");
    b.method("isAccessibilitySelected", @ptrCast(&tabSelected), "c@:");
    b.method("accessibilityPerformPress", @ptrCast(&tabPress), "c@:");
    classes[@intFromEnum(Kind.tab)] = b.finish();

    const o = begin("ZeAxOutline");
    o.method("accessibilityFrame", @ptrCast(&outlineFrame), ns_rect ++ "@:");
    o.method("accessibilityLabel", @ptrCast(&outlineLabel), "@@:");
    o.method("accessibilityChildren", @ptrCast(&outlineChildren), "@@:");
    o.method("accessibilityRows", @ptrCast(&outlineChildren), "@@:");
    o.method("accessibilitySelectedRows", @ptrCast(&outlineSelected), "@@:");
    classes[@intFromEnum(Kind.outline)] = o.finish();

    const r = begin("ZeAxRow");
    r.method("accessibilityFrame", @ptrCast(&rowFrame), ns_rect ++ "@:");
    r.method("accessibilityLabel", @ptrCast(&rowLabel), "@@:");
    r.method("accessibilityIndex", @ptrCast(&rowIndex), "q@:");
    r.method("accessibilityDisclosureLevel", @ptrCast(&rowLevel), "q@:");
    r.method("isAccessibilityDisclosed", @ptrCast(&rowOpen), "c@:");
    r.method("isAccessibilitySelected", @ptrCast(&rowSelected), "c@:");
    r.method("accessibilityPerformPress", @ptrCast(&rowPress), "c@:");
    classes[@intFromEnum(Kind.row)] = r.finish();

    inline for (field_names, 0..) |fl, i| offs[i] = objc.ivarOffset(classes[0], fl);
}

/// An NSAccessibilityElement subclass with every field, so they sit at
/// the same offsets in each class.
fn begin(name: [*:0]const u8) objc.ClassBuilder {
    const b = objc.ClassBuilder.begin("NSAccessibilityElement", name);
    inline for (field_names) |fl| b.ivar(fl);
    b.method("isAccessibilityElement", @ptrCast(&objc.yes), "c@:");
    return b;
}

// ---- telling VoiceOver ----

fn post(obj: Id, comptime name: []const u8) void {
    NSAccessibilityPostNotification(obj, objc.str(name));
}

/// After an edit or a caret move in `d`: tells VoiceOver, when it has
/// asked about `d`'s text before.
pub fn changed(d: *Doc) void {
    if (held.items.len == 0) return;
    const obj = (find(.{ .kind = .text, .owner = @intFromPtr(d), .key = 0 }) orelse return).obj;
    if (slot(obj, .id).* != d.file.id or slot(obj, .changes).* != d.file.ed.buf.changes) {
        slot(obj, .id).* = d.file.id;
        slot(obj, .changes).* = d.file.ed.buf.changes;
        post(obj, "AXValueChanged");
    }
    if (slot(obj, .cur).* != d.file.ed.cur or slot(obj, .anchor).* != d.file.ed.anchor) {
        slot(obj, .cur).* = d.file.ed.cur;
        slot(obj, .anchor).* = d.file.ed.anchor;
        post(obj, "AXSelectedTextChanged");
    }
}

/// Card `d` took the typing.
pub fn focused(d: *Doc) void {
    if (held.items.len == 0) return;
    post(textOf(d), "AXFocusedUIElementChanged");
}

/// Card `d` is going: its elements go dead.
pub fn drop(d: *Doc) void {
    sweep(struct {
        owner: usize,
        fn gone(s: @This(), k: Key, _: Held) bool {
            return k.owner == s.owner and (k.kind == .text or k.kind == .tabs or k.kind == .tab);
        }
    }{ .owner = @intFromPtr(d) });
}

/// Window `w` is closing: its sidebar's elements go dead.
pub fn dropWin(w: *Win) void {
    sweep(struct {
        owner: usize,
        fn gone(s: @This(), k: Key, _: Held) bool {
            return k.owner == s.owner and (k.kind == .outline or k.kind == .row);
        }
    }{ .owner = @intFromPtr(w) });
}

/// Lets go of every element `ctx.gone` picks.
fn sweep(ctx: anytype) void {
    if (held.items.len == 0) return;
    var dead: std.ArrayList(Id) = .empty;
    defer dead.deinit(gpa);
    var keep: usize = 0;
    for (held.items) |e| {
        if (ctx.gone(e.key, e.h)) {
            if (dead.append(gpa, e.h.obj)) |_| continue else |_| {}
        }
        held.items[keep] = e;
        keep += 1;
    }
    held.items.len = keep;
    for (dead.items) |obj| {
        slot(obj, .owner).* = 0;
        post(obj, "AXUIElementDestroyed");
        msg(void, obj, "release", .{});
    }
}

// ---- making elements ----

fn element(kind: Kind, owner: usize, key: u64, parent: Id) Id {
    const k: Key = .{ .kind = kind, .owner = owner, .key = key };
    if (find(k)) |h| {
        h.stamp = stamp;
        return h.obj;
    }
    const obj = msg(Id, msg(Id, classes[@intFromEnum(kind)], "alloc", .{}), "init", .{});
    if (obj == null) return null;
    held.insert(gpa, lowerBound(k), .{ .key = k, .h = .{ .obj = obj, .stamp = stamp } }) catch {
        msg(void, obj, "release", .{});
        return null;
    };
    slot(obj, .owner).* = owner;
    slot(obj, .key).* = key;
    const role: []const u8 = switch (kind) {
        .text => "AXTextArea",
        .tabs => "AXTabGroup",
        .tab => "AXRadioButton",
        .outline => "AXOutline",
        .row => "AXRow",
    };
    msg(void, obj, "setAccessibilityRole:", .{objc.str(role)});
    if (kind == .row) msg(void, obj, "setAccessibilitySubrole:", .{objc.str("AXOutlineRow")});
    msg(void, obj, "setAccessibilityParent:", .{parent});
    return obj;
}

fn textOf(d: *Doc) Id {
    const obj = element(.text, @intFromPtr(d), 0, d.win.view);
    if (obj != null and slot(obj, .id).* == 0) {
        slot(obj, .id).* = d.file.id;
        slot(obj, .changes).* = d.file.ed.buf.changes;
        slot(obj, .cur).* = d.file.ed.cur;
        slot(obj, .anchor).* = d.file.ed.anchor;
    }
    return obj;
}

fn tabsOf(d: *Doc) Id {
    return element(.tabs, @intFromPtr(d), 0, d.win.view);
}

fn tabOf(d: *Doc, id: u32) Id {
    return element(.tab, @intFromPtr(d), id, tabsOf(d));
}

fn outlineOf(w: *Win) Id {
    return element(.outline, @intFromPtr(w), 0, w.view);
}

fn rowOf(w: *Win, i: usize) Id {
    const obj = element(.row, @intFromPtr(w), hashRel(ax.rows()[i].rel), outlineOf(w));
    if (obj != null) {
        slot(obj, .idx).* = i;
        slot(obj, .gen).* = ax.treeGen();
    }
    return obj;
}

fn hashRel(rel: []const u8) u64 {
    return std.hash.Wyhash.hash(0, rel);
}

/// The live card an element stands for.
fn docOf(self: Id) ?*Doc {
    const p = slot(self, .owner).*;
    if (p == 0) return null;
    const d: *Doc = @ptrFromInt(p);
    return if (ax.alive(d)) d else null;
}

fn winOf(self: Id) ?*Win {
    const p = slot(self, .owner).*;
    if (p == 0) return null;
    const w: *Win = @ptrFromInt(p);
    return if (ax.winAlive(w)) w else null;
}

fn array() Id {
    return msg(Id, objc.class("NSMutableArray"), "array", .{});
}

fn add(list: Id, obj: Id) void {
    if (obj != null) msg(void, list, "addObject:", .{obj});
}

/// `r` in the view, in screen coordinates.
fn screen(nsview: Id, r: Rect) Rect {
    const win = msg(Id, nsview, "window", .{});
    if (win == null) return .{};
    return msg(Rect, win, "convertRectToScreen:", .{msg(Rect, nsview, "convertRect:toView:", .{ r, @as(Id, null) })});
}

/// Screen point `p` in the view.
fn fromScreen(nsview: Id, p: Point) Point {
    const win = msg(Id, nsview, "window", .{});
    if (win == null) return .{};
    const r = msg(Rect, win, "convertRectFromScreen:", .{Rect{ .x = p.x, .y = p.y }});
    return msg(Point, nsview, "convertPoint:fromView:", .{ Point{ .x = r.x, .y = r.y }, @as(Id, null) });
}

// ---- the window ----

/// The sidebar's outline, then each card's tabs and text, in layout order.
fn viewChildren(self: Id, _: Sel) callconv(.c) Id {
    const list = array();
    const w = ax.winOfView(self) orelse return list;
    stamp +%= 1;
    if (ax.sidebar(w)) add(list, outlineOf(w));
    var cards: [64]*Doc = undefined;
    for (cards[0..ax.cards(w, &cards)]) |d| {
        if (ax.tabsShown(d)) add(list, tabsOf(d));
        add(list, textOf(d));
    }
    sweep(struct {
        w: *Win,
        now: u32,
        fn gone(s: @This(), k: Key, h: Held) bool {
            if (h.stamp == s.now) return false;
            return switch (k.kind) {
                .outline => k.owner == @intFromPtr(s.w),
                .text, .tabs => blk: {
                    const d: *Doc = @ptrFromInt(k.owner);
                    break :blk ax.alive(d) and d.win == s.w;
                },
                .tab, .row => false,
            };
        }
    }{ .w = w, .now = stamp });
    return list;
}

fn viewFocused(self: Id, _: Sel) callconv(.c) Id {
    const w = ax.winOfView(self) orelse return self;
    return textOf(w.focus);
}

fn viewHit(self: Id, _: Sel, p: Point) callconv(.c) Id {
    const w = ax.winOfView(self) orelse return self;
    const at = fromScreen(self, p);
    if (ax.rowUnder(w, at)) |i| return rowOf(w, i);
    if (ax.sidebar(w) and at.x < ax.sideRect(w).w) return outlineOf(w);
    const d = ax.paneUnder(w, at) orelse return textOf(w.focus);
    if (ax.tabsShown(d)) if (ax.tabUnder(d, at)) |id| return tabOf(d, id);
    return textOf(d);
}

// ---- text ----

fn unitsOf(cp: u21) usize {
    return if (cp >= 0x10000) 2 else 1;
}

/// The byte `n` UTF-16 units on from byte `from`, at a character's start.
fn advance(t: []const u8, from: usize, n: usize) usize {
    var left = n;
    var i = from;
    while (i < t.len and left > 0) {
        const c = editor.decode(t, i);
        const k = unitsOf(c.cp);
        if (k > left) break;
        left -= k;
        i += c.len;
    }
    return i;
}

/// UTF-16 units before byte `pos`, a character's start: the line's offset
/// from the buffer's table, plus a walk within the line.
fn unitsTo(b: *buffer.Buffer, pos: usize) usize {
    const t = b.text.items;
    const u = b.unitStarts(gpa) catch return buffer.utf16Units(t, 0, pos);
    const k = b.lineOf(pos);
    return u[k] + buffer.utf16Units(t, b.lineStart(k), pos);
}

/// The byte `n` UTF-16 units into the text, at a character's start.
fn byteAt(b: *buffer.Buffer, n: usize) usize {
    const t = b.text.items;
    const u = b.unitStarts(gpa) catch return advance(t, 0, n);
    const k = buffer.lastAtMost(u, n);
    return advance(t, b.lineStart(k), n - u[k]);
}

fn toRange(b: *buffer.Buffer, a: usize, z: usize) Range {
    const loc = unitsTo(b, a);
    return .{ .loc = loc, .len = unitsTo(b, z) - loc };
}

fn toBytes(b: *buffer.Buffer, r: Range) [2]usize {
    const a = byteAt(b, r.loc);
    return .{ a, byteAt(b, unitsTo(b, a) +| r.len) };
}

/// An NSString of `s`, with each bad byte as U+FFFD so the units line up
/// with `buffer.utf16Units`.
pub fn nsText(s: []const u8) Id {
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(gpa);
    out.ensureTotalCapacity(gpa, s.len) catch return objc.str("");
    var i: usize = 0;
    while (i < s.len) {
        const c = editor.decode(s, i);
        if (c.cp >= 0x10000) {
            const v = c.cp - 0x10000;
            out.appendAssumeCapacity(@intCast(0xD800 + (v >> 10)));
            out.appendAssumeCapacity(@intCast(0xDC00 + (v & 0x3FF)));
        } else out.appendAssumeCapacity(@intCast(c.cp));
        i += c.len;
    }
    return msg(Id, objc.class("NSString"), "stringWithCharacters:length:", .{ out.items.ptr, out.items.len });
}

fn textFrame(self: Id, _: Sel) callconv(.c) Rect {
    const d = docOf(self) orelse return .{};
    return screen(d.win.view, ax.textRect(d));
}

fn textLabel(self: Id, _: Sel) callconv(.c) Id {
    const d = docOf(self) orelse return objc.str("");
    return objc.str(ax.name(d));
}

fn textValue(self: Id, _: Sel) callconv(.c) Id {
    const d = docOf(self) orelse return objc.str("");
    return nsText(d.file.ed.text());
}

fn textCount(self: Id, _: Sel) callconv(.c) isize {
    const d = docOf(self) orelse return 0;
    const b = &d.file.ed.buf;
    return @intCast(unitsTo(b, b.text.items.len));
}

fn selText(self: Id, _: Sel) callconv(.c) Id {
    const d = docOf(self) orelse return objc.str("");
    const s = d.file.ed.sel();
    return nsText(d.file.ed.text()[s[0]..s[1]]);
}

fn selRange(self: Id, _: Sel) callconv(.c) Range {
    const d = docOf(self) orelse return .{};
    const s = d.file.ed.sel();
    return toRange(&d.file.ed.buf, s[0], s[1]);
}

fn selRanges(self: Id, _: Sel) callconv(.c) Id {
    const v = msg(Id, objc.class("NSValue"), "valueWithRange:", .{selRange(self, null)});
    return msg(Id, objc.class("NSArray"), "arrayWithObject:", .{v});
}

/// VoiceOver moves the caret or selects.
fn setSelRange(self: Id, _: Sel, r: Range) callconv(.c) void {
    const d = docOf(self) orelse return;
    const b = toBytes(&d.file.ed.buf, r);
    ax.select(d, b[0], b[1]);
}

fn caretLine(self: Id, _: Sel) callconv(.c) isize {
    const d = docOf(self) orelse return 0;
    return @intCast(d.file.ed.buf.lineOf(d.file.ed.cur));
}

fn visibleRange(self: Id, _: Sel) callconv(.c) Range {
    const d = docOf(self) orelse return .{};
    const v = ax.visible(d);
    return toRange(&d.file.ed.buf, v[0], @max(v[0], v[1]));
}

fn lineForIndex(self: Id, _: Sel, i: isize) callconv(.c) isize {
    const d = docOf(self) orelse return 0;
    if (i < 0) return 0;
    return @intCast(d.file.ed.buf.lineOf(byteAt(&d.file.ed.buf, @intCast(i))));
}

/// Line `n` with its line break, as NSTextView gives it.
fn rangeForLine(self: Id, _: Sel, n: isize) callconv(.c) Range {
    const d = docOf(self) orelse return .{};
    const b = &d.file.ed.buf;
    if (n < 0 or @as(usize, @intCast(n)) >= b.lines()) return .{ .loc = unitsTo(b, b.text.items.len) };
    const k: usize = @intCast(n);
    return toRange(b, b.lineStart(k), b.lineStop(k));
}

fn stringForRange(self: Id, _: Sel, r: Range) callconv(.c) Id {
    const d = docOf(self) orelse return objc.str("");
    const t = d.file.ed.text();
    const b = toBytes(&d.file.ed.buf, r);
    return nsText(t[b[0]..b[1]]);
}

fn attributedForRange(self: Id, _: Sel, r: Range) callconv(.c) Id {
    const s = msg(Id, objc.class("NSAttributedString"), "alloc", .{});
    return msg(Id, msg(Id, s, "initWithString:", .{stringForRange(self, null, r)}), "autorelease", .{});
}

/// Where a range draws: its stretch of one row, or every row it touches.
fn frameForRange(self: Id, _: Sel, r: Range) callconv(.c) Rect {
    const d = docOf(self) orelse return .{};
    const t = d.file.ed.text();
    const b = toBytes(&d.file.ed.buf, r);
    const a = ax.cell(d, b[0]);
    if (b[1] == b[0]) return screen(d.win.view, a);
    const z = ax.cell(d, editor.prevChar(t, b[1]));
    if (z.y == a.y) return screen(d.win.view, .{ .x = a.x, .y = a.y, .w = @max(z.x + z.w - a.x, a.w), .h = a.h });
    const tr = ax.textRect(d);
    return screen(d.win.view, .{ .x = tr.x, .y = a.y, .w = tr.w, .h = z.y + z.h - a.y });
}

/// The character under screen point `p`.
fn rangeForPosition(self: Id, _: Sel, p: Point) callconv(.c) Range {
    const d = docOf(self) orelse return .{};
    const t = d.file.ed.text();
    const pos = ax.posAtPoint(d, fromScreen(d.win.view, p));
    return toRange(&d.file.ed.buf, pos, editor.nextChar(t, pos));
}

/// The whole character that unit `i` falls in.
fn rangeForIndex(self: Id, _: Sel, i: isize) callconv(.c) Range {
    const d = docOf(self) orelse return .{};
    const t = d.file.ed.text();
    const pos = byteAt(&d.file.ed.buf, @intCast(@max(i, 0)));
    return toRange(&d.file.ed.buf, pos, editor.nextChar(t, pos));
}

/// The text has one style for VoiceOver: all of it.
fn styleRange(self: Id, _: Sel, _: isize) callconv(.c) Range {
    const d = docOf(self) orelse return .{};
    const b = &d.file.ed.buf;
    return .{ .len = unitsTo(b, b.text.items.len) };
}

fn textFocused(self: Id, _: Sel) callconv(.c) bool {
    const d = docOf(self) orelse return false;
    return d.win.focus == d;
}

fn setTextFocused(self: Id, _: Sel, on: bool) callconv(.c) void {
    const d = docOf(self) orelse return;
    if (on) ax.focusCard(d);
}

// ---- tabs ----

fn tabsFrame(self: Id, _: Sel) callconv(.c) Rect {
    const d = docOf(self) orelse return .{};
    const n = ax.tabs(d);
    if (n == 0) return .{};
    const first = ax.tabRect(d, ax.tabAtIndex(d, 0));
    const last = ax.tabRect(d, ax.tabAtIndex(d, n - 1));
    return screen(d.win.view, .{ .x = first.x, .y = first.y, .w = @max(last.x + last.w - first.x, 0), .h = first.h });
}

fn tabsChildren(self: Id, _: Sel) callconv(.c) Id {
    const list = array();
    const d = docOf(self) orelse return list;
    if (!ax.tabsShown(d)) return list;
    stamp +%= 1;
    for (0..ax.tabs(d)) |j| add(list, tabOf(d, ax.tabAtIndex(d, j)));
    sweep(struct {
        owner: usize,
        now: u32,
        fn gone(s: @This(), k: Key, h: Held) bool {
            return k.kind == .tab and k.owner == s.owner and h.stamp != s.now;
        }
    }{ .owner = @intFromPtr(d), .now = stamp });
    return list;
}

/// The tab's index now, or null once it's closed.
fn tabIndex(self: Id) ?view.TabRef {
    const d = docOf(self) orelse return null;
    return .{ .d = d, .j = ax.tabOf(d, @intCast(slot(self, .key).*)) orelse return null };
}

fn tabFrame(self: Id, _: Sel) callconv(.c) Rect {
    const t = tabIndex(self) orelse return .{};
    return screen(t.d.win.view, ax.tabRect(t.d, @intCast(slot(self, .key).*)));
}

fn tabTitle(self: Id, _: Sel) callconv(.c) Id {
    const t = tabIndex(self) orelse return objc.str("");
    return objc.str(ax.tabTitle(t.d, t.j));
}

fn tabValue(self: Id, _: Sel) callconv(.c) Id {
    return msg(Id, objc.class("NSNumber"), "numberWithInt:", .{@as(c_int, @intFromBool(tabSelected(self, null)))});
}

fn tabSelected(self: Id, _: Sel) callconv(.c) bool {
    const t = tabIndex(self) orelse return false;
    return t.j == t.d.at;
}

fn tabPress(self: Id, _: Sel) callconv(.c) bool {
    const d = docOf(self) orelse return false;
    return ax.pressTab(d, @intCast(slot(self, .key).*));
}

// ---- sidebar ----

fn outlineFrame(self: Id, _: Sel) callconv(.c) Rect {
    const w = winOf(self) orelse return .{};
    return screen(w.view, ax.sideRect(w));
}

fn outlineLabel(_: Id, _: Sel) callconv(.c) Id {
    return objc.str(std.fs.path.basename(view.root orelse ""));
}

fn outlineChildren(self: Id, _: Sel) callconv(.c) Id {
    const list = array();
    const w = winOf(self) orelse return list;
    if (!ax.sidebar(w)) return list;
    stamp +%= 1;
    for (0..ax.rows().len) |i| add(list, rowOf(w, i));
    sweep(struct {
        owner: usize,
        now: u32,
        fn gone(s: @This(), k: Key, h: Held) bool {
            return k.kind == .row and k.owner == s.owner and h.stamp != s.now;
        }
    }{ .owner = @intFromPtr(w), .now = stamp });
    return list;
}

/// The row of the focused card's file.
fn outlineSelected(self: Id, _: Sel) callconv(.c) Id {
    const list = array();
    const w = winOf(self) orelse return list;
    if (w.sel.row) |i| if (i < ax.rows().len) add(list, rowOf(w, i));
    return list;
}

/// The row's place in the tree now, or null once it's gone.
fn rowAt(self: Id) ?struct { w: *Win, i: usize } {
    const w = winOf(self) orelse return null;
    const rows = ax.rows();
    const i = slot(self, .idx).*;
    if (slot(self, .gen).* == ax.treeGen() and i < rows.len) return .{ .w = w, .i = i };
    const key = slot(self, .key).*;
    for (rows, 0..) |row, k| if (hashRel(row.rel) == key) {
        slot(self, .idx).* = k;
        slot(self, .gen).* = ax.treeGen();
        return .{ .w = w, .i = k };
    };
    return null;
}

fn rowFrame(self: Id, _: Sel) callconv(.c) Rect {
    const r = rowAt(self) orelse return .{};
    return screen(r.w.view, ax.rowRect(r.w, r.i));
}

fn rowLabel(self: Id, _: Sel) callconv(.c) Id {
    const r = rowAt(self) orelse return objc.str("");
    const row = ax.rows()[r.i];
    return objc.str(row.rel[row.base..]);
}

fn rowIndex(self: Id, _: Sel) callconv(.c) isize {
    const r = rowAt(self) orelse return 0;
    return @intCast(r.i);
}

fn rowLevel(self: Id, _: Sel) callconv(.c) isize {
    const r = rowAt(self) orelse return 0;
    return ax.rows()[r.i].depth;
}

fn rowOpen(self: Id, _: Sel) callconv(.c) bool {
    const r = rowAt(self) orelse return false;
    return ax.rowOpen(r.i);
}

fn rowSelected(self: Id, _: Sel) callconv(.c) bool {
    const r = rowAt(self) orelse return false;
    return if (r.w.sel.row) |s| s == r.i else false;
}

fn rowPress(self: Id, _: Sel) callconv(.c) bool {
    const r = rowAt(self) orelse return false;
    return ax.pressRow(r.w, ax.rows()[r.i].rel);
}
