//! Zag: a tiny native text editor. `zag [file or folder]...`
const std = @import("std");
const objc = @import("objc.zig");
const view = @import("view.zig");
const files = @import("files.zig");
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
        } else view.openFile(a);
    }
    if (view.count() == 0 and !view.restoreSession()) _ = view.newDoc();
    view.adoptDrafts();
    // A file opened from Finder skips the session, but not its folder; with
    // neither a folder from the terminal nor a saved one, use the home folder.
    if (view.root == null) {
        if (view.savedRoot()) |dir| view.setRoot(dir) else if (std.c.getenv("HOME")) |h| {
            if (view.gpa.dupe(u8, std.mem.span(h))) |dir| view.setRoot(dir) else |_| {}
        }
    }
    // Launched from a terminal there is no bundle and nothing brings the
    // window forward; from the bundle, Launch Services does it (or `open -g` doesn't).
    const bundle = msg(Id, objc.class("NSBundle"), "mainBundle", .{});
    if (!view.background and msg(Id, bundle, "bundleIdentifier", .{}) == null) msg(void, app(), "activate", .{});
}

fn openFiles(_: Id, _: Sel, _: Id, list: Id) callconv(.c) void {
    for (0..msg(usize, list, "count", .{})) |i| view.openFile(objc.utf8(msg(Id, list, "objectAtIndex:", .{i})));
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

/// The Open Recent items change with the list, so they're built and bound here.
const open_recent = "openRecent:";
const clear_recent = "clearRecent:";

/// Fills File > Open Recent each time it opens.
fn fillRecent(_: Id, _: Sel, menu: Id) callconv(.c) void {
    msg(void, menu, "removeAllItems", .{});
    const paths = view.recentFiles();
    const n = msg(usize, paths, "count", .{});
    for (0..n) |i| {
        const p = msg(Id, paths, "objectAtIndex:", .{i});
        const it = view.menuItem(menu, objc.utf8(msg(Id, p, "lastPathComponent", .{})), open_recent, "", 0);
        msg(void, it, "setRepresentedObject:", .{p});
        msg(void, it, "setToolTip:", .{p});
    }
    if (n > 0) view.separator(menu);
    _ = view.menuItem(menu, "Clear Menu", if (n > 0) clear_recent else "noRecent:", "", 0);
}

fn openRecent(_: Id, _: Sel, sender: Id) callconv(.c) void {
    view.openFile(objc.utf8(msg(Id, sender, "representedObject", .{})));
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
    d.method(open_recent, @ptrCast(&openRecent), "v@:@");
    d.method(clear_recent, view.appAction(view.clearRecent, .{}), "v@:@");
    view.bindApp(d);
    d.method("applicationDidBecomeActive:", @ptrCast(&becameActive), "v@:@");
    d.method("applicationWillTerminate:", view.appAction(view.saveSession, .{}), "v@:@");
    d.method("validateMenuItem:", @ptrCast(&view.validate), "c@:@");
    d.method("menuNeedsUpdate:", @ptrCast(&fillRecent), "v@:@");
    d.method("contrastChanged:", @ptrCast(&view.contrastChanged), "v@:@");
    const cls = d.finish();
    const delegate = msg(Id, msg(Id, cls, "alloc", .{}), "init", .{});
    msg(void, nsapp, "setDelegate:", .{delegate});
    const notes = msg(Id, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "notificationCenter", .{});
    msg(void, notes, "addObserver:selector:name:object:", .{ delegate, objc.sel_registerName("contrastChanged:"), NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification, @as(Id, null) });

    view.buildMenu(delegate);
    view.setup();
    bench.start();
    objc.objc_autoreleasePoolPop(pool);
    msg(void, nsapp, "run", .{});
}
