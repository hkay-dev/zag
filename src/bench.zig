//! Bench mode, built only with `zig build -Dbench=true` (scripts/bench.sh).
//! With ZE_BENCH=<dir> set, Zag opens ZE_BENCH_FILES (colon-separated) in one
//! window with ZE_BENCH_ROOT in the sidebar, drives itself through a fixed
//! script, times each step's work plus the synchronous draw that follows it,
//! appends one number per step to `<dir>/<metric>.txt` and quits. It never
//! takes focus: the window stays behind every other one and nothing goes
//! through the HID.
const std = @import("std");
const finder = @import("finder.zig");
const objc = @import("objc.zig");
const view = @import("view.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const msg = objc.msg;

extern fn CGEventCreateScrollWheelEvent2(source: ?*anyopaque, units: u32, count: u32, w1: i32, w2: i32, w3: i32) ?*anyopaque;
extern fn CGEventSetLocation(ev: ?*anyopaque, at: objc.Point) void;
extern fn usleep(us: c_uint) c_int;
extern fn clock_gettime_nsec_np(clock: c_int) u64;

const Sample = struct { metric: []const u8, x: f64 };
var samples: std.ArrayList(Sample) = .empty;
var out: []const u8 = "";
var v: Id = null;
var win: Id = null;

/// Called from main before the run loop starts. Does nothing without ZE_BENCH.
pub fn start() void {
    const dir = std.c.getenv("ZE_BENCH") orelse return;
    out = std.mem.span(dir);
    view.background = true;
    samples.ensureTotalCapacity(view.gpa, 4096) catch fail("no memory");
    const c = objc.ClassBuilder.begin("NSObject", "ZeBench");
    c.method("begin:", @ptrCast(&begin), "v@:@");
    c.method("run:", @ptrCast(&run), "v@:@");
    _ = c.finish();
    const b = objc.new("ZeBench");
    msg(void, b, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("begin:"), @as(Id, null), @as(f64, 0) });
}

/// Right after launch: open the files, size the window and draw it once,
/// which ends the launch number, then let things settle before the script.
fn begin(self: Id, _: Sel, _: Id) callconv(.c) void {
    if (std.c.getenv("ZE_BENCH_ROOT")) |r| if (view.gpa.dupe(u8, std.mem.span(r))) |dir| view.setRoot(dir) else |_| {};
    if (std.c.getenv("ZE_BENCH_FILES")) |fs| {
        var it = std.mem.tokenizeScalar(u8, std.mem.span(fs), ':');
        while (it.next()) |p| view.open(p, view.keyDoc());
    }
    findView();
    if (std.c.getenv("ZE_BENCH_LAUNCH_ONLY") == null) msg(void, win, "setFrame:display:", .{ objc.Rect{ .x = 40, .y = 40, .w = 1200, .h = 760 }, true });
    msg(void, v, "displayIfNeeded", .{});
    put("launch_ms", (wallNow() - procStart()) * 1000);
    memory("launch_mb", "launch_peak_mb");
    visible();
    msg(void, self, "performSelector:withObject:afterDelay:", .{ objc.sel_registerName("run:"), @as(Id, null), @as(f64, 1.5) });
}

/// 1 when any of the window shows on screen, 0 when other windows cover it
/// all (macOS then paces its frames differently): a condition to note with
/// the numbers.
fn visible() void {
    put("visible", if (msg(usize, win, "occlusionState", .{}) & 2 != 0) 1 else 0);
}

fn run(_: Id, _: Sel, _: Id) callconv(.c) void {
    // A copy of a real session: just launch and let it settle, never edit.
    if (std.c.getenv("ZE_BENCH_LAUNCH_ONLY") != null) {
        for (0..5) |_| settle();
        memory("footprint_mb", "peak_mb");
        flush();
        std.c.exit(0);
    }
    const cpu0 = cpuNow();
    const main0 = threadCpu();
    // The first tab holds the big file.
    view.stepTab(1);
    settle();

    // A full redraw of an idle window.
    for (0..120) |_| step("frame_ms", true, nothing, .{});
    memory("mem_frame_mb", "peak_frame_mb");

    // Typing in the middle of the big file.
    for (0..600) |_| command("moveDown:");
    settle();
    for (0..200) |i| step("key_ms", false, insert, .{if (i % 7 == 6) " " else "x"});
    for (0..200) |_| command("deleteBackward:");
    settle();
    memory("mem_key_mb", "peak_key_mb");

    // Column zero avoids auto-indent, so each backspace joins one inserted line.
    command("moveToBeginningOfParagraph:");
    settle();
    for (0..50) |_| step("enter_ms", false, command, .{"insertNewline:"});
    for (0..50) |_| step("join_ms", false, command, .{"deleteBackward:"});
    settle();

    // Scrolling down and back up with the trackpad.
    for (0..400) |i| step("scroll_ms", false, scroll, .{@as(i32, if (i < 200) -40 else 40)});
    settle();
    memory("mem_scroll_mb", "peak_scroll_mb");

    // Switching tabs: the switch and its first frame, then later frames of
    // the switch's fade at 120 Hz.
    for (0..60) |_| {
        step("tab_ms", false, view.stepTab, .{@as(isize, 1)});
        settle();
    }
    memory("mem_tab_mb", "peak_tab_mb");
    for (0..20) |_| {
        view.stepTab(1);
        for (0..12) |_| step("anim_frame_ms", false, tick, .{});
    }
    settle();
    memory("mem_anim_mb", "peak_anim_mb");
    // ZE_BENCH_HOLD=<seconds> waits here, for footprint or vmmap to look.
    if (std.c.getenv("ZE_BENCH_HOLD")) |h| sleep(std.fmt.parseFloat(f64, std.mem.span(h)) catch 0);

    // The command palette: open it, filter it a letter at a time, close it.
    for (0..20) |_| {
        step("palette_ms", false, palette, .{});
        for ([_][]const u8{ "s", "p", "l", "i", "t" }) |ch| step("palette_ms", false, insert, .{ch});
        step("palette_ms", false, command, .{"cancelOperation:"});
        settle();
    }

    // Zag coming forward: the recheck of settings, files and folders, and the frame after.
    for (0..40) |_| {
        step("activate_ms", false, view.recheckAll, .{});
        settle();
    }

    put("proc_cpu_ms", (cpuNow() - cpu0) * 1000);
    put("main_cpu_ms", (threadCpu() - main0) * 1000);
    memory("footprint_mb", "peak_mb");
    visible();
    if (std.c.getenv("ZE_BENCH_QUICKOPEN_ROOT")) |r| quickOpenSteps(std.mem.span(r));
    flush();
    std.c.exit(0);
}

/// The process's physical footprint now and its peak so far, in MB, from
/// TASK_VM_INFO (phys_footprint and ledger_phys_footprint_peak).
fn memory(comptime now: []const u8, comptime peak: []const u8) void {
    var info: std.c.task_vm_info_data_t = std.mem.zeroes(std.c.task_vm_info_data_t);
    var n = std.c.TASK.VM.INFO_COUNT;
    if (std.c.task_info(std.c.mach_task_self(), std.c.TASK.VM.INFO, @ptrCast(&info), &n) != 0) return;
    put(now, @as(f64, @floatFromInt(info.phys_footprint)) / (1 << 20));
    put(peak, @as(f64, @floatFromInt(info.ledger_phys_footprint_peak)) / (1 << 20));
}

/// Times `f(args)` plus the draw it causes (the whole view when `full`),
/// as main-thread CPU time, so neither load on the Mac nor the window
/// server's pace counts. Each step is one run loop turn: its own
/// autorelease pool and a Core Animation commit, outside the timing. Steps
/// come no faster than a 120 Hz display asks for frames: faster, and a
/// window that shows on screen piles up new backing stores for frames the
/// screen hasn't shown yet, which real use never does.
fn step(comptime metric: []const u8, comptime full: bool, comptime f: anytype, args: anytype) void {
    sleep(1.0 / 120.0);
    const pool = objc.objc_autoreleasePoolPush();
    const t0 = threadCpu();
    @call(.auto, f, args);
    if (full) msg(void, v, "setNeedsDisplay:", .{true});
    msg(void, v, "displayIfNeeded", .{});
    put(metric, (threadCpu() - t0) * 1000);
    msg(void, objc.class("CATransaction"), "flush", .{});
    objc.objc_autoreleasePoolPop(pool);
}

/// This thread's CPU seconds so far.
fn threadCpu() f64 {
    return @as(f64, @floatFromInt(clock_gettime_nsec_np(16))) / 1e9;
}

fn nothing() void {}

/// What the display link does each frame.
fn tick() void {
    msg(void, v, "tick:", .{@as(Id, null)});
}

fn palette() void {
    msg(void, v, "commandPalette:", .{@as(Id, null)});
}

fn insert(s: []const u8) void {
    msg(void, v, "insertText:", .{objc.str(s)});
}

fn command(name: [*:0]const u8) void {
    msg(void, v, "doCommandBySelector:", .{objc.sel_registerName(name)});
}

/// A precise (trackpad) scroll of `dy` points over the middle of the card.
fn scroll(dy: i32) void {
    const ev = CGEventCreateScrollWheelEvent2(null, 0, 1, dy, 0, 0) orelse fail("no scroll event");
    defer objc.CFRelease(ev);
    const f = msg(objc.Rect, win, "frame", .{});
    const screens = msg(Id, objc.class("NSScreen"), "screens", .{});
    const top = msg(objc.Rect, msg(Id, screens, "objectAtIndex:", .{@as(usize, 0)}), "frame", .{}).h;
    CGEventSetLocation(ev, .{ .x = f.x + 700, .y = top - (f.y + f.h) + 300 });
    msg(void, v, "scrollWheel:", .{msg(Id, objc.class("NSEvent"), "eventWithCGEvent:", .{ev})});
}

/// Lets springs and fades finish, drawing about as often as the display would.
fn settle() void {
    for (0..30) |_| {
        sleep(0.008);
        const pool = objc.objc_autoreleasePoolPush();
        tick();
        msg(void, v, "displayIfNeeded", .{});
        msg(void, objc.class("CATransaction"), "flush", .{});
        objc.objc_autoreleasePoolPop(pool);
    }
}

fn findView() void {
    const app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const ws = msg(Id, app, "windows", .{});
    for (0..msg(usize, ws, "count", .{})) |i| {
        const w = msg(Id, ws, "objectAtIndex:", .{i});
        const subs = msg(Id, msg(Id, w, "contentView", .{}), "subviews", .{});
        const last = msg(Id, subs, "lastObject", .{});
        if (last != null and msg(bool, last, "isKindOfClass:", .{objc.class("ZeView")})) {
            win = w;
            v = last;
            return;
        }
    }
    fail("no ze view");
}

fn sleep(s: f64) void {
    _ = usleep(@intFromFloat(s * 1e6));
}

fn seconds(tv: std.c.timeval) f64 {
    return @as(f64, @floatFromInt(tv.sec)) + @as(f64, @floatFromInt(tv.usec)) / 1e6;
}

fn wallNow() f64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return seconds(tv);
}

/// When this process started: p_starttime opens kinfo_proc.
fn procStart() f64 {
    var buf: [1024]u8 align(8) = undefined;
    var len: usize = buf.len;
    const mib = [_]c_int{ 1, 14, 1, std.c.getpid() };
    if (std.c.sysctl(&mib, 4, &buf, &len, null, 0) != 0) return wallNow();
    return seconds(@as(*const std.c.timeval, @ptrCast(&buf)).*);
}

/// User plus system CPU seconds of every thread of this process so far.
fn cpuNow() f64 {
    var ru: std.c.rusage = undefined;
    _ = std.c.getrusage(std.c.rusage.SELF, &ru);
    return seconds(ru.utime) + seconds(ru.stime);
}

fn put(metric: []const u8, x: f64) void {
    samples.append(view.gpa, .{ .metric = metric, .x = x }) catch {};
}

/// Appends each sample to `<out>/<metric>.txt`.
fn flush() void {
    for (samples.items) |s| {
        var path: [1024]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&path, "{s}/{s}.txt", .{ out, s.metric }, 0) catch continue;
        const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) continue;
        defer _ = std.c.close(fd);
        var line: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&line, "{d:.4}\n", .{s.x}) catch continue;
        _ = std.c.write(fd, t.ptr, t.len);
    }
}

fn fail(why: []const u8) noreturn {
    _ = std.c.write(2, why.ptr, why.len);
    std.c.exit(1);
}

/// Quick open on a home-sized folder (ZE_BENCH_QUICKOPEN_ROOT, made by
/// bench.sh): open it, type three letters, close it. Runs after the
/// guards above are recorded, so main_cpu_ms and the memory numbers don't
/// include it. The root points at the big folder only for this step.
/// Beside the steps' numbers, the parts of an open step are timed alone on
/// the same folder, so what's left is drawing: quickopen_walk_ms
/// (`finder.scan`), quickopen_score0_ms (`finder.best` with the empty query
/// the open step starts with), quickopen_free_ms (dropping the last list)
/// and quickopen_score_ms (each typed letter's `finder.best`).
fn quickOpenSteps(big: []const u8) void {
    // setRoot frees the old root, so keep a copy to put back.
    const keep = if (view.root) |r| view.gpa.dupe(u8, r) catch return else null;
    view.setRoot(view.gpa.dupe(u8, big) catch return);
    defer if (keep) |k| view.setRoot(k);
    settle();
    const letters = [_][]const u8{ "m", "a", "i" };
    for (0..20) |_| {
        step("quickopen_ms", false, quickOpen, .{});
        for (letters) |ch| step("quickopen_ms", false, insert, .{ch});
        step("quickopen_ms", false, command, .{"cancelOperation:"});
        settle();
    }
    for (0..20) |_| {
        // Wake up as the open step does, after the settling frames.
        settle();
        const t0 = threadCpu();
        var f = finder.scan(view.gpa, big) catch return;
        put("quickopen_walk_ms", (threadCpu() - t0) * 1000);
        put("quickopen_files", @floatFromInt(f.paths.items.len));
        var picks: [10]usize = undefined;
        const t2 = threadCpu();
        _ = finder.best(f.paths.items, "", &picks);
        put("quickopen_score0_ms", (threadCpu() - t2) * 1000);
        for (1..letters.len + 1) |n| {
            const q = "mai"[0..n];
            const t1 = threadCpu();
            _ = finder.best(f.paths.items, q, &picks);
            put("quickopen_score_ms", (threadCpu() - t1) * 1000);
        }
        const t3 = threadCpu();
        f.deinit();
        put("quickopen_free_ms", (threadCpu() - t3) * 1000);
    }
}

fn quickOpen() void {
    msg(void, v, "quickOpen:", .{@as(Id, null)});
}
