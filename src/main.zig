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
pub const std_options: std.Options = .{ .signal_stack_size = if (release) null else 1 << 18 };
/// The self-driving bench, only in `-Dbench=true` builds.
const bench = if (@import("build_options").bench) @import("bench.zig") else struct {
    fn start() void {}
};

var args: []const [:0]const u8 = &.{};
/// Finder request lists queued before launch, with one reply per list.
var pending: Id = null;
var launched = false;
/// The Dock tile's menu, built on first use.
var dock_menu: Id = null;

extern const NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification: Id;

fn app() Id {
    return msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
}

fn didFinishLaunching(_: Id, _: Sel, _: Id) callconv(.c) void {
    // The last session comes back first, so files opened from Finder or the
    // terminal join it and the session saved on quit still holds it. It also
    // brings back the saved folder when the terminal gave none. With neither,
    // Zag opens without a folder: reading home would set off the Desktop and
    // Documents prompts.
    _ = view.restoreSession();
    // `-Key value` pairs are AppKit defaults (like -AppleInterfaceStyle Dark), not files.
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len == 0) continue;
        if (a[0] == '-') {
            i += 1;
        } else {
            _ = view.openFile(a);
        }
    }
    launched = true;
    if (pending != null) {
        const requests = pending;
        pending = null;
        for (0..msg(usize, requests, "count", .{})) |j| {
            openList(app(), msg(Id, requests, "objectAtIndex:", .{j}));
        }
        msg(void, requests, "release", .{});
    }
    if (view.count() == 0) _ = view.newDoc();
    view.adoptDrafts();
    // Launched from a terminal there is no bundle and nothing brings the
    // window forward; from the bundle, Launch Services does it (or `open -g` doesn't).
    const bundle = msg(Id, objc.class("NSBundle"), "mainBundle", .{});
    if (!view.background and msg(Id, bundle, "bundleIdentifier", .{}) == null) msg(void, app(), "activate", .{});
}

fn openList(application: Id, list: Id) void {
    var ok = true;
    for (0..msg(usize, list, "count", .{})) |i| {
        if (!view.openFile(objc.utf8(msg(Id, list, "objectAtIndex:", .{i})))) ok = false;
    }
    msg(void, application, "replyToOpenOrPrint:", .{@as(usize, if (ok) 0 else 2)});
}

fn openFiles(_: Id, _: Sel, application: Id, list: Id) callconv(.c) void {
    if (launched) return openList(application, list);
    // At launch Finder's files arrive before the session is restored; they wait for it.
    if (pending == null) pending = objc.new("NSMutableArray");
    const request = msg(Id, list, "copy", .{});
    defer msg(void, request, "release", .{});
    if (pending == null or request == null) {
        msg(void, application, "replyToOpenOrPrint:", .{@as(usize, 2)});
        return;
    }
    msg(void, pending, "addObject:", .{request});
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

/// Fills File > Open Recent each time it opens. Each file shows its icon,
/// and files sharing a name show their folder's name too.
fn fillRecent(_: Id, _: Sel, menu: Id) callconv(.c) void {
    msg(void, menu, "removeAllItems", .{});
    const paths = view.recentFiles();
    const n = msg(usize, paths, "count", .{});
    const ws = msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    for (0..n) |i| {
        const p = msg(Id, paths, "objectAtIndex:", .{i});
        const name = msg(Id, p, "lastPathComponent", .{});
        var shared = false;
        for (0..n) |j| {
            if (j != i and msg(bool, name, "isEqualToString:", .{msg(Id, msg(Id, paths, "objectAtIndex:", .{j}), "lastPathComponent", .{})})) {
                shared = true;
                break;
            }
        }
        var buf: [1024]u8 = undefined;
        const base = objc.utf8(name);
        const title = if (shared)
            std.fmt.bufPrint(&buf, "{s} ({s})", .{ base, objc.utf8(msg(Id, msg(Id, p, "stringByDeletingLastPathComponent", .{}), "lastPathComponent", .{})) }) catch base
        else
            base;
        const it = view.menuItem(menu, title, open_recent, "", 0);
        msg(void, it, "setRepresentedObject:", .{p});
        msg(void, it, "setToolTip:", .{p});
        view.setFileIcon(ws, it, p);
    }
    if (n > 0) view.separator(menu);
    _ = view.menuItem(menu, "Clear Menu", if (n > 0) clear_recent else "noRecent:", "", 0);
}

/// The Dock tile's menu: a new window, the open panel and settings.
fn dockMenu(self: Id, _: Sel, _: Id) callconv(.c) Id {
    if (dock_menu != null) return dock_menu;
    dock_menu = objc.new("NSMenu");
    msg(void, dock_menu, "setAutoenablesItems:", .{false});
    inline for (.{ .{ "New Window", "newDocument:" }, .{ "Open…", "openDocument:" }, .{ "Settings…", "openSettings:" } }) |e| {
        msg(void, view.menuItem(dock_menu, e[0], e[1], "", 0), "setTarget:", .{self});
    }
    return dock_menu;
}

fn openRecent(_: Id, _: Sel, sender: Id) callconv(.c) void {
    _ = view.openFile(objc.utf8(msg(Id, sender, "representedObject", .{})));
}

pub fn main(init: std.process.Init.Minimal) void {
    args = init.args.toSlice(view.gpa) catch &.{};
    const pool = objc.objc_autoreleasePoolPush();
    const nsapp = app();
    // Dev and Perf builds run in the background: no Dock tile or menu bar,
    // and neither comes forward.
    const id = msg(Id, msg(Id, objc.class("NSBundle"), "mainBundle", .{}), "bundleIdentifier", .{});
    if (id != null) {
        const bundle_id = objc.utf8(id);
        view.background = std.mem.endsWith(u8, bundle_id, ".dev") or std.mem.endsWith(u8, bundle_id, ".perf");
    }
    _ = msg(bool, nsapp, "setActivationPolicy:", .{@as(isize, if (view.background) 1 else 0)});
    // No window tabs, so ⌃Tab reaches Zag's own tabs.
    msg(void, objc.class("NSWindow"), "setAllowsAutomaticWindowTabbing:", .{false});

    // From a terminal, quick open and the sidebar use the folder Zag started
    // in. Finder starts apps in /, so there the session's folder is used.
    if (files.cwd(view.gpa)) |dir| {
        if (dir.len > 1) view.adoptRoot(dir) else view.gpa.free(dir);
    }

    const d = objc.ClassBuilder.begin("NSObject", "ZeApp");
    d.method("applicationDidFinishLaunching:", @ptrCast(&didFinishLaunching), "v@:@");
    d.method("application:openFiles:", @ptrCast(&openFiles), "v@:@@");
    d.method("applicationShouldTerminateAfterLastWindowClosed:", @ptrCast(&objc.no), "c@:@");
    d.method("applicationShouldTerminate:", @ptrCast(&shouldTerminate), "Q@:@");
    d.method("applicationShouldHandleReopen:hasVisibleWindows:", @ptrCast(&reopen), "c@:@c");
    d.method("applicationDockMenu:", @ptrCast(&dockMenu), "@@:@");
    d.method(open_recent, @ptrCast(&openRecent), "v@:@");
    d.method(clear_recent, view.appAction(view.clearRecent, .{}), "v@:@");
    view.bindApp(d);
    d.method("applicationDidBecomeActive:", @ptrCast(&becameActive), "v@:@");
    d.method("validateMenuItem:", @ptrCast(&view.validate), "c@:@");
    d.method("menuNeedsUpdate:", @ptrCast(&fillRecent), "v@:@");
    d.method("contrastChanged:", @ptrCast(&view.contrastChanged), "v@:@");
    _ = d.finish();
    const delegate = objc.new("ZeApp");
    msg(void, nsapp, "setDelegate:", .{delegate});
    const notes = msg(Id, msg(Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "notificationCenter", .{});
    msg(void, notes, "addObserver:selector:name:object:", .{ delegate, objc.sel_registerName("contrastChanged:"), NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification, @as(Id, null) });

    view.buildMenu(delegate);
    view.setup();
    bench.start();
    objc.objc_autoreleasePoolPop(pool);
    msg(void, nsapp, "run", .{});
}
