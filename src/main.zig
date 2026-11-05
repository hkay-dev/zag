//! ze: a tiny native text editor. `ze [file or folder]...`
const std = @import("std");
const objc = @import("objc.zig");
const view = @import("view.zig");
const files = @import("files.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const msg = objc.msg;

const cmd: usize = 1 << 20;
const shift: usize = 1 << 17;
const ctrl: usize = 1 << 18;
const opt: usize = 1 << 19;

/// In release builds the default panic handler and debug Io pull in a DWARF
/// reader and all of std.Io.Threaded, about half the binary. ze does its own
/// file I/O on libc. Debug builds keep both for stack traces.
const release = @import("builtin").mode != .debug;
pub const panic = if (release) std.debug.no_panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = if (release) null else std.Io.Threaded.global_single_threaded;

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
    if (view.count() == 0) _ = view.newDoc();
    // Launched from a terminal there is no bundle and nothing brings the
    // window forward; from the bundle, Launch Services does it (or `open -g` doesn't).
    const bundle = msg(Id, objc.class("NSBundle"), "mainBundle", .{});
    if (msg(Id, bundle, "bundleIdentifier", .{}) == null) msg(void, app(), "activate", .{});
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

fn newDocument(_: Id, _: Sel, _: Id) callconv(.c) void {
    _ = view.newDoc();
}

fn openDocument(_: Id, _: Sel, _: Id) callconv(.c) void {
    view.openPanel();
}

fn item(menu: Id, title: []const u8, action: [:0]const u8, key: []const u8, mods: usize) void {
    const it = msg(Id, msg(Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
        objc.str(title), objc.sel_registerName(action), objc.str(key),
    });
    if (key.len > 0) msg(void, it, "setKeyEquivalentModifierMask:", .{mods});
    msg(void, menu, "addItem:", .{it});
    msg(void, it, "release", .{});
}

fn separator(menu: Id) void {
    msg(void, menu, "addItem:", .{msg(Id, objc.class("NSMenuItem"), "separatorItem", .{})});
}

fn submenu(bar: Id, title: []const u8) Id {
    const m = msg(Id, msg(Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.str(title)});
    const it = objc.new("NSMenuItem");
    msg(void, it, "setSubmenu:", .{m});
    msg(void, bar, "addItem:", .{it});
    msg(void, it, "release", .{});
    msg(void, m, "release", .{});
    return m;
}

fn buildMenu() void {
    const bar = objc.new("NSMenu");
    const a = submenu(bar, "ze");
    item(a, "About ze", "orderFrontStandardAboutPanel:", "", 0);
    separator(a);
    item(a, "Hide ze", "hide:", "h", cmd);
    item(a, "Hide Others", "hideOtherApplications:", "h", cmd | opt);
    item(a, "Show All", "unhideAllApplications:", "", 0);
    separator(a);
    item(a, "Quit ze", "terminate:", "q", cmd);

    const file = submenu(bar, "File");
    item(file, "New", "newDocument:", "n", cmd);
    item(file, "Open…", "openDocument:", "o", cmd);
    item(file, "Quick Open…", "quickOpen:", "p", cmd);
    separator(file);
    item(file, "Close", "performClose:", "w", cmd);
    item(file, "Save", "saveDocument:", "s", cmd);
    item(file, "Save As…", "saveDocumentAs:", "s", cmd | shift);

    const edit = submenu(bar, "Edit");
    item(edit, "Undo", "undo:", "z", cmd);
    item(edit, "Redo", "redo:", "z", cmd | shift);
    separator(edit);
    item(edit, "Cut", "cut:", "x", cmd);
    item(edit, "Copy", "copy:", "c", cmd);
    item(edit, "Paste", "paste:", "v", cmd);
    item(edit, "Select All", "selectAll:", "a", cmd);
    separator(edit);
    item(edit, "Find…", "findText:", "f", cmd);
    item(edit, "Find Next", "findNext:", "g", cmd);
    item(edit, "Find Previous", "findPrevious:", "g", cmd | shift);
    item(edit, "Go to Line…", "gotoLine:", "l", cmd);
    item(edit, "Toggle Comment", "toggleComment:", "/", cmd);

    const v = submenu(bar, "View");
    item(v, "Bigger", "zoomIn:", "=", cmd);
    item(v, "Smaller", "zoomOut:", "-", cmd);
    item(v, "Actual Size", "zoomReset:", "0", cmd);
    separator(v);
    item(v, "Enter Full Screen", "toggleFullScreen:", "f", cmd | ctrl);

    const w = submenu(bar, "Window");
    item(w, "Minimize", "performMiniaturize:", "m", cmd);
    item(w, "Zoom", "performZoom:", "", 0);
    msg(void, app(), "setWindowsMenu:", .{w});
    msg(void, app(), "setMainMenu:", .{bar});
    msg(void, bar, "release", .{});
}

pub fn main(init: std.process.Init.Minimal) void {
    args = init.args.toSlice(view.gpa) catch &.{};
    const pool = objc.objc_autoreleasePoolPush();
    const nsapp = app();
    _ = msg(bool, nsapp, "setActivationPolicy:", .{@as(isize, 0)});

    // From a terminal, quick open lists the folder ze started in. Finder
    // starts apps in /, so there it waits for a folder to be opened.
    if (files.cwd(view.gpa)) |dir| {
        if (dir.len > 1) view.root = dir else view.gpa.free(dir);
    }

    const d = objc.ClassBuilder.begin("NSObject", "ZeApp");
    d.method("applicationDidFinishLaunching:", @ptrCast(&didFinishLaunching), "v@:@");
    d.method("application:openFiles:", @ptrCast(&openFiles), "v@:@@");
    d.method("applicationShouldTerminateAfterLastWindowClosed:", @ptrCast(&yes), "c@:@");
    d.method("applicationShouldTerminate:", @ptrCast(&shouldTerminate), "Q@:@");
    d.method("applicationShouldHandleReopen:hasVisibleWindows:", @ptrCast(&reopen), "c@:@c");
    d.method("newDocument:", @ptrCast(&newDocument), "v@:@");
    d.method("openDocument:", @ptrCast(&openDocument), "v@:@");
    const cls = d.finish();
    msg(void, nsapp, "setDelegate:", .{msg(Id, msg(Id, cls, "alloc", .{}), "init", .{})});

    buildMenu();
    view.setup();
    objc.objc_autoreleasePoolPop(pool);
    msg(void, nsapp, "run", .{});
}
