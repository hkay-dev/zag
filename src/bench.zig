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
extern fn clock_gettime_nsec_np(clock: c_int) u64;

const Sample = struct { metric: []const u8, x: f64 };
var samples: std.ArrayList(Sample) = .empty;
var out: []const u8 = "";
var v: Id = null;
var win: Id = null;

const Phase = enum {
    start, launch_done, frame, move, key, erase, enter_start, enter, join,
    scroll, tab, anim, hold, palette, activate, guards, quick, quick_parts, done,
};
var phase: Phase = .start;
var index: usize = 0;
var settling: usize = 0;
var cpu0: f64 = 0;
var main0: f64 = 0;
var quick_root: []const u8 = "";
var saved_root: ?[]const u8 = null;
const frame_delay = 1.0 / 120.0;

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
    objc.later(objc.new("ZeBench"), "begin:", null, 0);
}

/// Right after launch: open the files, size the window and draw it once,
/// which ends the launch number, then let things settle before the script.
fn begin(self: Id, _: Sel, _: Id) callconv(.c) void {
    if (std.c.getenv("ZE_BENCH_ROOT")) |r| if (view.gpa.dupe(u8, std.mem.span(r))) |dir| view.setRoot(dir) else |_| {};
    if (std.c.getenv("ZE_BENCH_FILES")) |fs| {
        var it = std.mem.splitScalar(u8, std.mem.span(fs), ':');
        while (it.next()) |p| {
            var path: [std.fs.max_path_bytes]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&path, "{s}", .{p}, 0) catch fail("benchmark input path too long");
            var st: std.c.Stat = undefined;
            if (std.c.stat(z, &st) != 0 or st.mode & std.c.S.IFMT != std.c.S.IFREG) fail("missing or nonregular benchmark input");
            if (!view.open(p, view.keyDoc())) fail("cannot open benchmark input");
            const d = view.keyDoc() orelse fail("no benchmark document");
            if (d.file.new_file) fail("benchmark input disappeared while opening");
        }
    } else if (std.c.getenv("ZE_BENCH_LAUNCH_ONLY") == null) fail("missing benchmark inputs");
    findView();
    if (std.c.getenv("ZE_BENCH_LAUNCH_ONLY") == null) msg(void, win, "setFrame:display:", .{ objc.Rect{ .x = 40, .y = 40, .w = 1200, .h = 760 }, true });
    msg(void, v, "displayIfNeeded", .{});
    put("launch_ms", (wallNow() - procStart()) * 1000);
    memory("launch_mb", "launch_peak_mb");
    visible();
    objc.later(self, "run:", null, 1.5);
}

/// 1 when any of the window shows on screen, 0 when other windows cover it
/// all (macOS then paces its frames differently): a condition to note with
/// the numbers.
fn visible() void {
    put("visible", if (msg(usize, win, "occlusionState", .{}) & 2 != 0) 1 else 0);
}

fn advance(next: Phase, frames: usize) void {
    phase = next;
    index = 0;
    settling = frames;
}

/// One action or settling frame per callback. Returning lets AppKit and
/// Quick Open's main-queue completion run between measurements.
fn run(self: Id, _: Sel, _: Id) callconv(.c) void {
    if (settling > 0) {
        settling -= 1;
        settle();
        objc.later(self, "run:", null, frame_delay);
        return;
    }
    const i = index;
    index += 1;
    var delay: f64 = frame_delay;
    switch (phase) {
        .start => {
            if (std.c.getenv("ZE_BENCH_LAUNCH_ONLY") != null) {
                advance(.launch_done, 150);
            } else {
                cpu0 = cpuNow();
                main0 = threadCpu();
                view.stepTab(view.keyDoc().?, 1);
                advance(.frame, 30);
            }
        },
        .launch_done => {
            memory("footprint_mb", "peak_mb");
            complete();
        },
        .frame => {
            step("frame_ms", true, nothing, .{});
            if (index == 120) advance(.move, 0);
        },
        .move => {
            if (i == 0) memory("mem_frame_mb", "peak_frame_mb");
            command("moveDown:");
            if (index == 600) advance(.key, 30);
        },
        .key => {
            step("key_ms", false, insert, .{if (i % 7 == 6) " " else "x"});
            if (index == 200) advance(.erase, 0);
        },
        .erase => {
            command("deleteBackward:");
            if (index == 200) advance(.enter_start, 30);
        },
        .enter_start => {
            memory("mem_key_mb", "peak_key_mb");
            // Column zero avoids auto-indent, so backspace joins each line.
            command("moveToBeginningOfParagraph:");
            advance(.enter, 30);
        },
        .enter => {
            step("enter_ms", false, command, .{"insertNewline:"});
            if (index == 50) advance(.join, 0);
        },
        .join => {
            step("join_ms", false, command, .{"deleteBackward:"});
            if (index == 50) advance(.scroll, 30);
        },
        .scroll => {
            step("scroll_ms", false, scroll, .{@as(i32, if (i < 200) -40 else 40)});
            if (index == 400) advance(.tab, 30);
        },
        .tab => {
            if (i == 0) memory("mem_scroll_mb", "peak_scroll_mb");
            step("tab_ms", false, view.stepTab, .{ view.keyDoc().?, @as(isize, 1) });
            settling = 30;
            if (index == 60) advance(.anim, 30);
        },
        .anim => {
            if (i == 0) memory("mem_tab_mb", "peak_tab_mb");
            if (i % 13 == 0) {
                view.stepTab(view.keyDoc().?, 1);
            } else step("anim_frame_ms", false, send, .{"tick:"});
            if (index == 20 * 13) advance(.hold, 30);
        },
        .hold => {
            memory("mem_anim_mb", "peak_anim_mb");
            // A timer leaves the main queue available during footprint/vmmap.
            if (std.c.getenv("ZE_BENCH_HOLD")) |h| {
                const seconds_to_hold = std.fmt.parseFloat(f64, std.mem.span(h)) catch 0;
                if (!std.math.isFinite(seconds_to_hold)) fail("invalid bench hold");
                delay = @max(frame_delay, seconds_to_hold);
            }
            advance(.palette, 0);
        },
        .palette => {
            const letters = [_][]const u8{ "s", "p", "l", "i", "t" };
            switch (i % 7) {
                0 => step("palette_ms", false, send, .{"commandPalette:"}),
                6 => {
                    step("palette_ms", false, command, .{"cancelOperation:"});
                    settling = 30;
                },
                else => step("palette_ms", false, insert, .{letters[i % 7 - 1]}),
            }
            if (index == 20 * 7) advance(.activate, 30);
        },
        .activate => {
            step("activate_ms", false, view.recheckAll, .{});
            settling = 30;
            if (index == 40) advance(.guards, 30);
        },
        .guards => {
            put("proc_cpu_ms", (cpuNow() - cpu0) * 1000);
            put("main_cpu_ms", (threadCpu() - main0) * 1000);
            memory("footprint_mb", "peak_mb");
            visible();
            if (std.c.getenv("ZE_BENCH_QUICKOPEN_ROOT")) |r| {
                quick_root = std.mem.span(r);
                // setRoot frees the old root, so retain an owned copy.
                saved_root = if (view.root) |root| view.gpa.dupe(u8, root) catch fail("no memory") else null;
                view.setRoot(view.gpa.dupe(u8, quick_root) catch fail("no memory"));
                advance(.quick, 30);
            } else advance(.done, 0);
        },
        .quick => {
            const letters = [_][]const u8{ "m", "a", "i" };
            switch (i % 5) {
                0 => step("quickopen_ms", false, send, .{"quickOpen:"}),
                4 => {
                    step("quickopen_ms", false, command, .{"cancelOperation:"});
                    settling = 30;
                },
                else => step("quickopen_ms", false, insert, .{letters[i % 5 - 1]}),
            }
            if (index == 20 * 5) advance(.quick_parts, 60);
        },
        .quick_parts => {
            quickOpenParts(quick_root);
            settling = 30;
            if (index == 20) advance(.done, 0);
        },
        .done => {
            if (saved_root) |root| view.setRoot(root);
            complete();
        },
    }
    objc.later(self, "run:", null, delay);
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
    const pool = objc.objc_autoreleasePoolPush();
    const t0 = threadCpu();
    @call(.auto, f, args);
    if (full) msg(void, v, "setNeedsDisplay:", .{true});
    finishFrame(pool, metric, t0);
}

fn finishFrame(pool: ?*anyopaque, comptime metric: ?[]const u8, t0: f64) void {
    msg(void, v, "displayIfNeeded", .{});
    if (metric) |m| put(m, (threadCpu() - t0) * 1000);
    msg(void, objc.class("CATransaction"), "flush", .{});
    objc.objc_autoreleasePoolPop(pool);
}

/// This thread's CPU seconds so far.
fn threadCpu() f64 {
    return @as(f64, @floatFromInt(clock_gettime_nsec_np(16))) / 1e9;
}

fn nothing() void {}

fn send(sel: [*:0]const u8) void {
    msg(void, v, sel, .{@as(Id, null)});
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

/// One untimed spring/fade frame; the caller schedules the next turn.
fn settle() void {
    const pool = objc.objc_autoreleasePoolPush();
    send("tick:");
    finishFrame(pool, null, 0);
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
    samples.append(view.gpa, .{ .metric = metric, .x = x }) catch fail("no memory for sample");
}

/// Appends each sample to `<out>/<metric>.txt`.
fn flush() void {
    for (samples.items) |s| {
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&path, "{s}/{s}.txt", .{ out, s.metric }, 0) catch fail("metric path too long");
        const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) fail("cannot open metric");
        var line: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&line, "{d:.4}\n", .{s.x}) catch fail("cannot format metric");
        if (std.c.write(fd, t.ptr, t.len) != @as(isize, @intCast(t.len))) fail("incomplete metric write");
        if (std.c.close(fd) != 0) fail("cannot close metric");
    }
}

fn complete() noreturn {
    flush();
    // `open -W` does not report the app's exit status. Publish success only
    // after every sample reached its file, so bench.sh rejects failed runs.
    if (std.c.getenv("ZE_BENCH_DONE")) |path| {
        const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) fail("cannot record benchmark completion");
        if (std.c.close(fd) != 0) {
            _ = std.c.unlink(path);
            fail("cannot close benchmark completion");
        }
    }
    std.c.exit(0);
}

fn fail(why: []const u8) noreturn {
    _ = std.c.write(2, why.ptr, why.len);
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

/// Isolated Quick Open parts, after the interaction rounds and guards.
/// The scheduler gives each round its own turn after settling frames.
fn quickOpenParts(big: []const u8) void {
    const t0 = threadCpu();
    var f = finder.scan(view.gpa, big, false) catch fail("cannot scan benchmark folder");
    put("quickopen_walk_ms", (threadCpu() - t0) * 1000);
    put("quickopen_files", @floatFromInt(f.paths.items.len));
    var picks: [10]usize = undefined;
    const t2 = threadCpu();
    _ = finder.best(f.paths.items, "", &.{}, &picks, null);
    put("quickopen_score0_ms", (threadCpu() - t2) * 1000);
    for (1..4) |n| {
        const t1 = threadCpu();
        _ = finder.best(f.paths.items, "mai"[0..n], &.{}, &picks, null);
        put("quickopen_score_ms", (threadCpu() - t1) * 1000);
    }
    const t3 = threadCpu();
    f.deinit();
    put("quickopen_free_ms", (threadCpu() - t3) * 1000);
}
