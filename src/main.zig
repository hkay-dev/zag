//! Zag: a tiny native text editor. `zag [file or folder]...`
const std = @import("std");
const objc = @import("objc.zig");
const view = @import("view.zig");
const files = @import("files.zig");
const settings = @import("settings.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const msg = objc.msg;

const cmd: usize = 1 << 20;
const shift: usize = 1 << 17;
const ctrl: usize = 1 << 18;
const opt: usize = 1 << 19;

/// In release builds the default panic handler and debug Io pull in a DWARF
/// reader and all of std.Io.Threaded, about half the binary. Zag does its own
/// file I/O on libc. Debug builds keep both for stack traces.
const release = @import("builtin").mode != .debug;
pub const panic = if (release) std.debug.no_panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = if (release) null else std.Io.Threaded.global_single_threaded;
/// The self-driving bench, only in `-Dbench=true` builds.
const bench = if (@import("build_options").bench) @import("bench.zig") else struct {
    fn start() void {}
};

var args: []const [:0]const u8 = &.{};

fn app() Id {
    return msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
}

fn didFinishLaunching(_: Id, _: Sel, _: Id) callconv(.c) void {
    // `-Key value` pairs are AppKit defaults (like -AppleInterfaceStyle Dark), not files.
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len == 0) continue;
        if (a[0] == '-') {
            i += 1;
        } else view.open(a, view.blankDoc());
    }
    if (view.count() == 0 and !view.restoreSession()) _ = view.newDoc();
    view.adoptDrafts();
    // With no folder from the terminal or the last session, use the home folder.
    if (view.root == null) if (std.c.getenv("HOME")) |h| {
        if (view.gpa.dupe(u8, std.mem.span(h))) |dir| view.setRoot(dir) else |_| {}
    };
    // Launched from a terminal there is no bundle and nothing brings the
    // window forward; from the bundle, Launch Services does it (or `open -g` doesn't).
    const bundle = msg(Id, objc.class("NSBundle"), "mainBundle", .{});
    if (!view.background and msg(Id, bundle, "bundleIdentifier", .{}) == null) msg(void, app(), "activate", .{});
}

fn openFiles(_: Id, _: Sel, _: Id, list: Id) callconv(.c) void {
    for (0..msg(usize, list, "count", .{})) |i| view.open(objc.utf8(msg(Id, list, "objectAtIndex:", .{i})), view.blankDoc());
}

fn yes(_: Id, _: Sel, _: Id) callconv(.c) bool {
    return true;
}

fn shouldTerminate(_: Id, _: Sel, _: Id) callconv(.c) usize {
    return @intFromBool(view.settleAll());
}

fn reopen(_: Id, _: Sel, _: Id, visible: bool) callconv(.c) bool {
    if (!visible and view.count() == 0) _ = view.newDoc();
    return true;
}

fn becameActive(_: Id, _: Sel, _: Id) callconv(.c) void {
    // A Dev build hands the keys straight back.
    if (view.background) return msg(void, app(), "deactivate", .{});
    view.recheckAll();
}

/// A menu action thunk: calls `f` with `a` and drops its result.
fn act(comptime f: anytype, comptime a: anytype) *const fn (Id, Sel, Id) callconv(.c) void {
    return &struct {
        fn thunk(_: Id, _: Sel, _: Id) callconv(.c) void {
            _ = @call(.auto, f, a);
        }
    }.thunk;
}

/// A menu action thunk for items that carry their index in `tag`.
fn tagged(comptime f: fn (usize) void) *const fn (Id, Sel, Id) callconv(.c) void {
    return &struct {
        fn thunk(_: Id, _: Sel, sender: Id) callconv(.c) void {
            f(@intCast(msg(isize, sender, "tag", .{})));
        }
    }.thunk;
}

/// Late-Night greys the Zen, Typewriter, Focus and Theme items.
fn validate(_: Id, _: Sel, it: Id) callconv(.c) bool {
    return view.allowed(it);
}

/// Fills File > Open Recent each time it opens.
fn fillRecent(_: Id, _: Sel, menu: Id) callconv(.c) void {
    msg(void, menu, "removeAllItems", .{});
    const paths = view.recentFiles();
    const n = msg(usize, paths, "count", .{});
    for (0..n) |i| {
        const p = msg(Id, paths, "objectAtIndex:", .{i});
        const it = item(menu, objc.utf8(msg(Id, p, "lastPathComponent", .{})), "openRecent:", "", 0);
        msg(void, it, "setRepresentedObject:", .{p});
        msg(void, it, "setToolTip:", .{p});
    }
    if (n > 0) separator(menu);
    _ = item(menu, "Clear Menu", if (n > 0) "clearRecent:" else "noRecent:", "", 0);
}

fn openRecent(_: Id, _: Sel, sender: Id) callconv(.c) void {
    view.open(objc.utf8(msg(Id, sender, "representedObject", .{})), view.blankDoc());
}

fn item(menu: Id, title: []const u8, action: [:0]const u8, key: []const u8, mods: usize) Id {
    const it = msg(Id, msg(Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
        objc.str(title), objc.sel_registerName(action), objc.str(key),
    });
    if (key.len > 0) msg(void, it, "setKeyEquivalentModifierMask:", .{mods});
    msg(void, menu, "addItem:", .{it});
    msg(void, it, "release", .{});
    return it;
}

fn separator(menu: Id) void {
    msg(void, menu, "addItem:", .{msg(Id, objc.class("NSMenuItem"), "separatorItem", .{})});
}

fn submenu(bar: Id, title: []const u8) Id {
    const m = msg(Id, msg(Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.str(title)});
    const it = objc.new("NSMenuItem");
    msg(void, it, "setTitle:", .{objc.str(title)});
    msg(void, it, "setSubmenu:", .{m});
    msg(void, bar, "addItem:", .{it});
    msg(void, it, "release", .{});
    msg(void, m, "release", .{});
    return m;
}

fn buildMenu(delegate: Id) void {
    const bar = objc.new("NSMenu");
    const a = submenu(bar, "Zag");
    _ = item(a, "About Zag", "orderFrontStandardAboutPanel:", "", 0);
    separator(a);
    _ = item(a, "Settings…", "openSettings:", ",", cmd);
    separator(a);
    _ = item(a, "Hide Zag", "hide:", "h", cmd);
    _ = item(a, "Hide Others", "hideOtherApplications:", "h", cmd | opt);
    _ = item(a, "Show All", "unhideAllApplications:", "", 0);
    separator(a);
    _ = item(a, "Quit Zag", "terminate:", "q", cmd);

    const file = submenu(bar, "File");
    _ = item(file, "New", "newDocument:", "n", cmd);
    _ = item(file, "New Tab", "newTab:", "t", cmd);
    _ = item(file, "Open…", "openDocument:", "o", cmd);
    const recent = submenu(file, "Open Recent");
    msg(void, recent, "setDelegate:", .{delegate});
    _ = item(file, "Quick Open…", "quickOpen:", "p", cmd);
    separator(file);
    _ = item(file, "Close Tab", "closeTab:", "w", cmd);
    _ = item(file, "Close Window", "performClose:", "w", cmd | shift);
    _ = item(file, "Save", "saveDocument:", "s", cmd);
    _ = item(file, "Save As…", "saveDocumentAs:", "s", cmd | shift);

    const edit = submenu(bar, "Edit");
    _ = item(edit, "Undo", "undo:", "z", cmd);
    _ = item(edit, "Redo", "redo:", "z", cmd | shift);
    separator(edit);
    _ = item(edit, "Cut", "cut:", "x", cmd);
    _ = item(edit, "Copy", "copy:", "c", cmd);
    _ = item(edit, "Paste", "paste:", "v", cmd);
    _ = item(edit, "Select All", "selectAll:", "a", cmd);
    separator(edit);
    _ = item(edit, "Find…", "findText:", "f", cmd);
    _ = item(edit, "Find and Replace…", "findAndReplace:", "f", cmd | opt);
    _ = item(edit, "Find Next", "findNext:", "g", cmd);
    _ = item(edit, "Find Previous", "findPrevious:", "g", cmd | shift);
    _ = item(edit, "Go to Line…", "gotoLine:", "l", cmd);
    _ = item(edit, "Toggle Comment", "toggleComment:", "/", cmd);

    const v = submenu(bar, "View");
    _ = item(v, "Command Palette…", "commandPalette:", "k", cmd);
    _ = item(v, "Markdown Preview", "markdownPreview:", "m", cmd | shift);
    separator(v);
    const fonts = item(v, "Font…", "orderFrontFontPanel:", "t", cmd | shift);
    msg(void, fonts, "setTarget:", .{msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{})});
    _ = item(v, "Bigger", "zoomIn:", "=", cmd);
    _ = item(v, "Smaller", "zoomOut:", "-", cmd);
    _ = item(v, "Actual Size", "zoomReset:", "0", cmd);
    separator(v);
    view.wrap_item = item(v, "Soft Wrap", "toggleWrap:", "z", opt);
    view.lines_item = item(v, "Line Numbers", "toggleLineNumbers:", "l", cmd | shift);
    view.pairs_item = item(v, "Auto-Close Brackets", "togglePairs:", "", 0);
    view.sidebar_item = item(v, "Sidebar", "toggleSidebar:", "\\", cmd);
    view.zen_item = item(v, "Zen Mode", "toggleZen:", "z", ctrl | cmd);
    view.late_item = item(v, "Late-Night Focus", "toggleLateNight:", "n", ctrl | cmd);
    _ = item(v, "Show Next Tab", "nextTab:", "\t", ctrl);
    // ⇧Tab arrives as back tab, so that's the key to match.
    _ = item(v, "Show Previous Tab", "previousTab:", "\x19", ctrl | shift);
    view.typewriter_item = item(v, "Typewriter Scrolling", "toggleTypewriter:", "", 0);
    const focus = submenu(v, "Focus");
    for ([_][]const u8{ "Off", "Line", "Sentence", "Paragraph" }, 0..) |title, i| {
        const it = item(focus, title, "pickFocus:", "", 0);
        msg(void, it, "setTag:", .{@as(isize, @intCast(i))});
        view.focus_items[i] = it;
    }
    separator(v);
    _ = item(v, "Split Right", "splitRight:", "d", cmd);
    _ = item(v, "Split Down", "splitDown:", "d", cmd | shift);
    _ = item(v, "Next Card", "nextCard:", "]", cmd);
    _ = item(v, "Previous Card", "previousCard:", "[", cmd);
    const themes = submenu(v, "Theme");
    msg(void, item(themes, "Appearance", "", "", 0), "setEnabled:", .{false});
    for ([_][]const u8{ "Auto", "Light", "Dark" }, 0..) |title, i| {
        const it = item(themes, title, "pickAppearance:", "", 0);
        msg(void, it, "setTag:", .{@as(isize, @intCast(i))});
        msg(void, it, "setIndentationLevel:", .{@as(isize, 1)});
        view.look_items[i] = it;
    }
    for (settings.schemes, 0..) |sc, i| {
        if (i == 0 or sc.dark != settings.schemes[i - 1].dark) {
            separator(themes);
            msg(void, item(themes, if (sc.dark) "Dark Mode" else "Light Mode", "", "", 0), "setEnabled:", .{false});
        }
        const it = item(themes, sc.title, "pickScheme:", "", 0);
        msg(void, it, "setTag:", .{@as(isize, @intCast(i))});
        msg(void, it, "setIndentationLevel:", .{@as(isize, 1)});
        view.scheme_items[i] = it;
    }
    separator(v);
    _ = item(v, "Enter Full Screen", "toggleFullScreen:", "f", cmd | ctrl);

    const w = submenu(bar, "Window");
    _ = item(w, "Minimize", "performMiniaturize:", "m", cmd);
    _ = item(w, "Zoom", "performZoom:", "", 0);
    msg(void, app(), "setWindowsMenu:", .{w});

    const help = submenu(bar, "Help");
    msg(void, app(), "setHelpMenu:", .{help});
    msg(void, app(), "setMainMenu:", .{bar});
    msg(void, bar, "release", .{});
}

pub fn main(init: std.process.Init.Minimal) void {
    args = init.args.toSlice(view.gpa) catch &.{};
    const pool = objc.objc_autoreleasePoolPush();
    const nsapp = app();
    // A Dev build (bundle id ending in `.dev`) runs in the background: no
    // Dock tile or menu bar, and it never comes forward.
    const id = msg(Id, msg(Id, objc.class("NSBundle"), "mainBundle", .{}), "bundleIdentifier", .{});
    if (id != null) view.background = std.mem.endsWith(u8, std.mem.span(msg([*:0]const u8, id, "UTF8String", .{})), ".dev");
    _ = msg(bool, nsapp, "setActivationPolicy:", .{@as(isize, if (view.background) 1 else 0)});
    // No window tabs, so ⌃Tab reaches Zag's own tabs.
    msg(void, objc.class("NSWindow"), "setAllowsAutomaticWindowTabbing:", .{false});

    // From a terminal, quick open and the sidebar use the folder Zag started
    // in. Finder starts apps in /, so there the last folder or home is used.
    if (files.cwd(view.gpa)) |dir| {
        if (dir.len > 1) view.adoptRoot(dir) else view.gpa.free(dir);
    }

    const d = objc.ClassBuilder.begin("NSObject", "ZeApp");
    d.method("applicationDidFinishLaunching:", @ptrCast(&didFinishLaunching), "v@:@");
    d.method("application:openFiles:", @ptrCast(&openFiles), "v@:@@");
    d.method("applicationShouldTerminateAfterLastWindowClosed:", @ptrCast(&yes), "c@:@");
    d.method("applicationShouldTerminate:", @ptrCast(&shouldTerminate), "Q@:@");
    d.method("applicationShouldHandleReopen:hasVisibleWindows:", @ptrCast(&reopen), "c@:@c");
    d.method("newDocument:", @ptrCast(act(view.newDoc, .{})), "v@:@");
    d.method("openDocument:", @ptrCast(act(view.openPanel, .{})), "v@:@");
    d.method("applicationDidBecomeActive:", @ptrCast(&becameActive), "v@:@");
    d.method("applicationWillTerminate:", @ptrCast(act(view.saveSession, .{})), "v@:@");
    d.method("openSettings:", @ptrCast(act(view.openSettings, .{})), "v@:@");
    d.method("toggleWrap:", @ptrCast(act(view.toggleWrap, .{})), "v@:@");
    d.method("toggleLineNumbers:", @ptrCast(act(view.toggleLineNumbers, .{})), "v@:@");
    d.method("togglePairs:", @ptrCast(act(view.togglePairs, .{})), "v@:@");
    d.method("toggleSidebar:", @ptrCast(act(view.toggleSidebar, .{})), "v@:@");
    d.method("toggleTypewriter:", @ptrCast(act(view.toggleTypewriter, .{})), "v@:@");
    d.method("toggleLateNight:", @ptrCast(act(view.toggleLateNight, .{})), "v@:@");
    d.method("validateMenuItem:", @ptrCast(&validate), "c@:@");
    d.method("toggleZen:", @ptrCast(act(view.toggleZen, .{})), "v@:@");
    d.method("nextTab:", @ptrCast(act(view.stepTab, .{1})), "v@:@");
    d.method("previousTab:", @ptrCast(act(view.stepTab, .{-1})), "v@:@");
    d.method("pickScheme:", @ptrCast(tagged(view.pickScheme)), "v@:@");
    d.method("pickAppearance:", @ptrCast(tagged(view.pickLook)), "v@:@");
    d.method("pickFocus:", @ptrCast(tagged(view.pickFocus)), "v@:@");
    d.method("menuNeedsUpdate:", @ptrCast(&fillRecent), "v@:@");
    d.method("openRecent:", @ptrCast(&openRecent), "v@:@");
    d.method("clearRecent:", @ptrCast(act(view.clearRecent, .{})), "v@:@");
    const cls = d.finish();
    const delegate = msg(Id, msg(Id, cls, "alloc", .{}), "init", .{});
    msg(void, nsapp, "setDelegate:", .{delegate});

    buildMenu(delegate);
    view.setup();
    bench.start();
    objc.objc_autoreleasePoolPop(pool);
    msg(void, nsapp, "run", .{});
}
