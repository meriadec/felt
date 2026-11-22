//! Build graph. Run `zig build --help` for the steps and options.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const update_goldens = b.option(bool, "update-goldens", "With `test`: rewrite tests/golden/*.png from the current output") orelse false;
    const script = b.option([]const u8, "script", "With `shot`: script name in tests/scripts (default: all)");

    const exe = addExe(b, target, optimize);
    b.installArtifact(exe);

    // run: zig build run -- <args>
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run annotate (pass args after --)").dependOn(&run.step);

    // test: unit tests of the core and of the app, plus golden replays.
    const test_step = b.step("test", "Run unit tests and golden replays (-Dupdate-goldens=true to accept new output)");
    for ([_]*std.Build.Module{ coreModule(b, target, optimize), exe.root_module }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        const t_run = b.addRunArtifact(t);
        t_run.setCwd(b.path("."));
        t_run.has_side_effects = true; // tests read tests/ and docs/ from disk
        if (update_goldens) t_run.setEnvironmentVariable("ANNOTATE_UPDATE_GOLDENS", "1");
        test_step.dependOn(&t_run.step);
    }

    // shot: render scripts headless to test-out/shots/ for a quick look.
    const shot_step = b.step("shot", "Render tests/scripts/*.txt (or -Dscript=<name>) to test-out/shots/<name>.{frame,export}.png");
    var names: std.ArrayList([]const u8) = .empty;
    if (script) |s| {
        names.append(b.allocator, std.fs.path.stem(s)) catch @panic("OOM");
    } else {
        var dir = b.build_root.handle.openDir("tests/scripts", .{ .iterate = true }) catch @panic("cannot open tests/scripts");
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (std.mem.endsWith(u8, e.name, ".txt")) names.append(b.allocator, b.dupe(e.name[0 .. e.name.len - 4])) catch @panic("OOM");
        }
    }
    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "test-out/shots" });
    mkdir.setCwd(b.path("."));
    for (names.items) |name| {
        const r = b.addRunArtifact(exe);
        r.setCwd(b.path("."));
        r.addArgs(&.{
            "--headless",
            "--script",
            b.fmt("tests/scripts/{s}.txt", .{name}),
            "--frame-out",
            b.fmt("test-out/shots/{s}.frame.png", .{name}),
            "--export-out",
            b.fmt("test-out/shots/{s}.export.png", .{name}),
            "tests/fixtures/screenshot.png",
        });
        r.step.dependOn(&mkdir.step);
        shot_step.dependOn(&r.step);
    }

    // bench: always ReleaseFast, whatever -Doptimize says.
    const bench_exe = addExe(b, target, .ReleaseFast);
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.setCwd(b.path("."));
    bench_run.addArg("--bench");
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Measure startup and frame times, ReleaseFast (args after --: [--size WxH] [image])").dependOn(&bench_run.step);

    // docs: regenerate docs/keymap.md from src/core/keymap.zig.
    const km = b.addRunArtifact(exe);
    km.addArg("--keymap-md");
    const docs = b.addUpdateSourceFiles();
    docs.addCopyFileToSource(km.captureStdOut(), "docs/keymap.md");
    b.step("docs", "Regenerate docs/keymap.md from the key map source").dependOn(&docs.step);

    // fmt / fmt-check
    const fmt_paths = &.{ "build.zig", "src" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });
    b.step("fmt-check", "Fail if a Zig source is not formatted").dependOn(&fmt_check.step);

    // check: everything a commit needs.
    const check = b.step("check", "fmt-check + test: run before every commit");
    check.dependOn(&fmt_check.step);
    check.dependOn(test_step);
}

/// The pure core: document, tools, editor, software renderer. No backend imports
/// are possible: a module cannot import files outside its root directory.
fn coreModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.addIncludePath(b.path("vendor/stb"));
    // stb is always optimized: a Debug PNG decode is 10x slower and slows every test.
    core.addCSourceFile(.{ .file = b.path("vendor/stb/stb_impl.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
    core.addAnonymousImport("font_ttf", .{ .root_source_file = b.path("vendor/fonts/DejaVuSans-Bold.ttf") });
    return core;
}

fn addExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("core", coreModule(b, target, optimize));
    mod.linkSystemLibrary("X11", .{});
    mod.linkSystemLibrary("Xext", .{});
    return b.addExecutable(.{ .name = "annotate", .root_module = mod });
}
