const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } },
    } });
    // `zig build --release` makes it small: the point of Zag is a tiny binary.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .small });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
        .unwind_tables = if (optimize == .debug) .sync else .none,
    });
    // `-Dbench=true` compiles in the self-driving bench (src/bench.zig, run
    // by scripts/bench.sh). Shipped builds leave it out.
    const opts = b.addOptions();
    opts.addOption(bool, "bench", b.option(bool, "bench", "Compile in the bench mode") orelse false);
    mod.addOptions("build_options", opts);
    if (!target.query.isNative()) {
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        }
    }
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("QuartzCore", .{});

    const exe = b.addExecutable(.{ .name = "zag", .root_module = mod });
    // No spare room after the load commands: Zag never gets its install names
    // rewritten, and the padding alone can push __TEXT onto another 16 KB page.
    exe.headerpad_size = 0;
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .link_libc = true,
    }) });
    b.step("test", "Run the editing tests").dependOn(&b.addRunArtifact(tests).step);
}
