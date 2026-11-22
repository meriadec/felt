//! Build graph. Run `zig build --help` for the steps and options.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addExe(b, target, optimize);
    b.installArtifact(exe);

    // run: zig build run -- <args>
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run annotate (pass args after --)").dependOn(&run.step);

    // test: unit tests of the core and of the app.
    const test_step = b.step("test", "Run unit tests and golden replays");
    for ([_]*std.Build.Module{ coreModule(b, target, optimize), exe.root_module }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        const t_run = b.addRunArtifact(t);
        t_run.setCwd(b.path("."));
        t_run.has_side_effects = true; // tests read tests/ from disk
        test_step.dependOn(&t_run.step);
    }

    // fmt / fmt-check
    const fmt_paths = &.{ "build.zig", "src" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    b.step("fmt-check", "Fail if a Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);
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
    return b.addExecutable(.{ .name = "annotate", .root_module = mod });
}
