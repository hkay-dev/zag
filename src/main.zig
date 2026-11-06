//! Zag: a tiny native text editor. `zag [file or folder]...`
const std = @import("std");
const objc = @import("objc.zig");
const view = @import("view.zig");
const files = @import("files.zig");
const settings = @import("settings.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const msg = objc.msg;

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

extern const NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification: Id;

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
fn act(comptime f: anytype, comptime a: anytype) *const anyopaque {
    return @ptrCast(&struct {
        fn thunk(_: Id, _: Sel, _: Id) callconv(.c) void {
            _ = @call(.auto, f, a);
        }
    }.thunk);
}

/// A menu action thunk for items that carry their index in `tag`.
fn tagged(comptime f: fn (usize) void) *const anyopaque {
    return @ptrCast(&struct {
        fn thunk(_: Id, _: Sel, sender: Id) callconv(.c) void {
            f(@intCast(msg(isize, sender, "tag", .{})));
        }
    }.thunk);
}

/// Fills File > Open Recent each time it opens.
fn fillRecent(_: Id, _: Sel, menu: Id) callconv(.c) void {
    msg(void, menu, "removeAllItems", .{});
    const paths = view.recentFiles();
    const n = msg(usize, paths, "count", .{});
    for (0..n) |i| {
        const p = msg(Id, paths, "objectAtIndex:", .{i});
        const it = view.menuItem(menu, objc.utf8(msg(Id, p, "lastPathComponent", .{})), "openRecent:", "", 0);
        msg(void, it, "setRepresentedObject:", .{p});
        msg(void, it, "setToolTip:", .{p});
    }
    if (n > 0) view.separator(menu);
    _ = view.menuItem(menu, "Clear Menu", if (n > 0) "clearRecent:" else "noRecent:", "", 0);
}

fn openRecent(_: Id, _: Sel, sender: Id) callconv(.c) void {
    view.open(objc.utf8(msg(Id, sender, "representedObject", .{})), view.blankDoc());
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
    _ = view.menuItem(a, "About Zag", "orderFrontStandardAboutPanel:", "", 0);
    view.separator(a);
    _ = view.menuItem(a, "Settings…", "openSettings:", ",", objc.cmd_key);
    view.separator(a);
    _ = view.menuItem(a, "Hide Zag", "hide:", "h", objc.cmd_key);
    _ = view.menuItem(a, "Hide Others", "hideOtherApplications:", "h", objc.cmd_key | objc.opt_key);
    _ = view.menuItem(a, "Show All", "unhideAllApplications:", "", 0);
    view.separator(a);
    _ = view.menuItem(a, "Quit Zag", "terminate:", "q", objc.cmd_key);

    const file = submenu(bar, "File");
    _ = view.menuItem(file, "New", "newDocument:", "n", objc.cmd_key);
    _ = view.menuItem(file, "New Tab", "newTab:", "t", objc.cmd_key);
    _ = view.menuItem(file, "Open…", "openDocument:", "o", objc.cmd_key);
    const recent = submenu(file, "Open Recent");
    msg(void, recent, "setDelegate:", .{delegate});
    _ = view.menuItem(file, "Quick Open…", "quickOpen:", "p", objc.cmd_key);
    view.separator(file);
    _ = view.menuItem(file, "Close Tab", "closeTab:", "w", objc.cmd_key);
    _ = view.menuItem(file, "Close Window", "performClose:", "w", objc.cmd_key | objc.shift_key);
    _ = view.menuItem(file, "Save", "saveDocument:", "s", objc.cmd_key);
    _ = view.menuItem(file, "Save As…", "saveDocumentAs:", "s", objc.cmd_key | objc.shift_key);

    const edit = submenu(bar, "Edit");
    _ = view.menuItem(edit, "Undo", "undo:", "z", objc.cmd_key);
    _ = view.menuItem(edit, "Redo", "redo:", "z", objc.cmd_key | objc.shift_key);
    view.separator(edit);
    _ = view.menuItem(edit, "Cut", "cut:", "x", objc.cmd_key);
    _ = view.menuItem(edit, "Copy", "copy:", "c", objc.cmd_key);
    _ = view.menuItem(edit, "Paste", "paste:", "v", objc.cmd_key);
    _ = view.menuItem(edit, "Select All", "selectAll:", "a", objc.cmd_key);
    view.separator(edit);
    _ = view.menuItem(edit, "Find…", "findText:", "f", objc.cmd_key);
    _ = view.menuItem(edit, "Find and Replace…", "findAndReplace:", "f", objc.cmd_key | objc.opt_key);
    _ = view.menuItem(edit, "Find Next", "findNext:", "g", objc.cmd_key);
    _ = view.menuItem(edit, "Find Previous", "findPrevious:", "g", objc.cmd_key | objc.shift_key);
    _ = view.menuItem(edit, "Go to Line…", "gotoLine:", "l", objc.cmd_key);
    _ = view.menuItem(edit, "Toggle Comment", "toggleComment:", "/", objc.cmd_key);

    const v = submenu(bar, "View");
    _ = view.menuItem(v, "Command Palette…", "commandPalette:", "k", objc.cmd_key);
    _ = view.menuItem(v, "Markdown Preview", "markdownPreview:", "m", objc.cmd_key | objc.shift_key);
    view.separator(v);
    const fonts = view.menuItem(v, "Font…", "orderFrontFontPanel:", "t", objc.cmd_key | objc.shift_key);
    msg(void, fonts, "setTarget:", .{msg(Id, objc.class("NSFontManager"), "sharedFontManager", .{})});
    _ = view.menuItem(v, "Bigger", "zoomIn:", "=", objc.cmd_key);
    _ = view.menuItem(v, "Smaller", "zoomOut:", "-", objc.cmd_key);
    _ = view.menuItem(v, "Actual Size", "zoomReset:", "0", objc.cmd_key);
    view.separator(v);
    view.wrap_item = view.menuItem(v, "Soft Wrap", "toggleWrap:", "z", objc.opt_key);
    view.lines_item = view.menuItem(v, "Line Numbers", "toggleLineNumbers:", "l", objc.cmd_key | objc.shift_key);
    view.pairs_item = view.menuItem(v, "Auto-Close Brackets", "togglePairs:", "", 0);
    view.sidebar_item = view.menuItem(v, "Sidebar", "toggleSidebar:", "\\", objc.cmd_key);
    view.zen_item = view.menuItem(v, "Zen Mode", "toggleZen:", "z", objc.ctrl_key | objc.cmd_key);
    view.late_item = view.menuItem(v, "Late-Night Focus", "toggleLateNight:", "n", objc.ctrl_key | objc.cmd_key);
    _ = view.menuItem(v, "Show Next Tab", "nextTab:", "\t", objc.ctrl_key);
    // ⇧Tab arrives as back tab, so that's the key to match.
    _ = view.menuItem(v, "Show Previous Tab", "previousTab:", "\x19", objc.ctrl_key | objc.shift_key);
    view.typewriter_item = view.menuItem(v, "Typewriter Scrolling", "toggleTypewriter:", "", 0);
    const focus = submenu(v, "Focus");
    for ([_][]const u8{ "Off", "Line", "Sentence", "Paragraph" }, 0..) |title, i| {
        const it = view.menuItem(focus, title, "pickFocus:", "", 0);
        msg(void, it, "setTag:", .{@as(isize, @intCast(i))});
        view.focus_items[i] = it;
    }
    view.separator(v);
    _ = view.menuItem(v, "Split Right", "splitRight:", "d", objc.cmd_key);
    _ = view.menuItem(v, "Split Down", "splitDown:", "d", objc.cmd_key | objc.shift_key);
    _ = view.menuItem(v, "Next Card", "nextCard:", "]", objc.cmd_key);
    _ = view.menuItem(v, "Previous Card", "previousCard:", "[", objc.cmd_key);
    const themes = submenu(v, "Theme");
    msg(void, view.menuItem(themes, "Appearance", "", "", 0), "setEnabled:", .{false});
    for ([_][]const u8{ "Auto", "Light", "Dark" }, 0..) |title, i| {
        const it = view.menuItem(themes, title, "pickAppearance:", "", 0);
        msg(void, it, "setTag:", .{@as(isize, @intCast(i))});
        msg(void, it, "setIndentationLevel:", .{@as(isize, 1)});
        view.look_items[i] = it;
    }
    for (settings.schemes, 0..) |sc, i| {
        if (i == 0 or sc.dark != settings.schemes[i - 1].dark) {
            view.separator(themes);
            msg(void, view.menuItem(themes, if (sc.dark) "Dark Mode" else "Light Mode", "", "", 0), "setEnabled:", .{false});
        }
        const it = view.menuItem(themes, sc.title, "pickScheme:", "", 0);
        msg(void, it, "setTag:", .{@as(isize, @intCast(i))});
        msg(void, it, "setIndentationLevel:", .{@as(isize, 1)});
        view.scheme_items[i] = it;
    }
    view.separator(v);
    _ = view.menuItem(v, "Enter Full Screen", "toggleFullScreen:", "f", objc.cmd_key | objc.ctrl_key);

    const w = submenu(bar, "Window");
    _ = view.menuItem(w, "Minimize", "performMiniaturize:", "m", objc.cmd_key);
    _ = view.menuItem(w, "Zoom", "performZoom:", "", 0);
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
    if (id != null) view.background = std.mem.endsWith(u8, objc.utf8(id), ".dev");
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
    d.method("applicationShouldTerminateAfterLastWindowClosed:", @ptrCast(&objc.yes), "c@:@");
    d.method("applicationShouldTerminate:", @ptrCast(&shouldTerminate), "Q@:@");
    d.method("applicationShouldHandleReopen:hasVisibleWindows:", @ptrCast(&reopen), "c@:@c");
    d.method("newDocument:", act(view.newDoc, .{}), "v@:@");
    d.method("openDocument:", act(view.openPanel, .{}), "v@:@");
    d.method("applicationDidBecomeActive:", @ptrCast(&becameActive), "v@:@");
    d.method("applicationWillTerminate:", act(view.saveSession, .{}), "v@:@");
    d.method("openSettings:", act(view.openSettings, .{}), "v@:@");
    d.method("toggleWrap:", act(view.toggleWrap, .{}), "v@:@");
    d.method("toggleLineNumbers:", act(view.toggleLineNumbers, .{}), "v@:@");
    d.method("togglePairs:", act(view.togglePairs, .{}), "v@:@");
    d.method("toggleSidebar:", act(view.toggleSidebar, .{}), "v@:@");
    d.method("toggleTypewriter:", act(view.toggleTypewriter, .{}), "v@:@");
    d.method("toggleLateNight:", act(view.toggleLateNight, .{}), "v@:@");
    d.method("validateMenuItem:", @ptrCast(&view.allowed), "c@:@");
    d.method("toggleZen:", act(view.toggleZen, .{}), "v@:@");
    d.method("nextTab:", act(view.stepTab, .{1}), "v@:@");
    d.method("previousTab:", act(view.stepTab, .{-1}), "v@:@");
    d.method("pickScheme:", tagged(view.pickScheme), "v@:@");
    d.method("pickAppearance:", tagged(view.pickLook), "v@:@");
    d.method("pickFocus:", tagged(view.pickFocus), "v@:@");
    d.method("menuNeedsUpdate:", @ptrCast(&fillRecent), "v@:@");
    d.method("openRecent:", @ptrCast(&openRecent), "v@:@");
    d.method("clearRecent:", act(view.clearRecent, .{}), "v@:@");
    d.method("contrastChanged:", @ptrCast(&view.contrastChanged), "v@:@");
    const cls = d.finish();
    const delegate = msg(Id, msg(Id, cls, "alloc", .{}), "init", .{});
    msg(void, nsapp, "setDelegate:", .{delegate});
    const notes = msg(Id, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "notificationCenter", .{});
    msg(void, notes, "addObserver:selector:name:object:", .{ delegate, objc.sel_registerName("contrastChanged:"), NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification, @as(Id, null) });

    buildMenu(delegate);
    view.setup();
    bench.start();
    objc.objc_autoreleasePoolPop(pool);
    msg(void, nsapp, "run", .{});
}
