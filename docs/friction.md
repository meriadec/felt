# Friction log

Every hiccup is a harness bug: a confusing error, a slow or missing command, a
repeated manual step, a missing doc. When you hit one:

1. Fix it in the repo if you can (tool, flag, build step, script, doc), in its
   own small commit.
2. Add one line below: date, what happened, what fixed it (or "open").
3. If a lesson shows up twice, turn it into tooling or a test, not a longer doc.

Keep each entry to one line. Delete entries whose fix makes them obvious.

## Log

- 2026-11-22: global `~/.gitignore_global` ignores `mise.toml`, so a clean clone had no pinned zig. Fix: `!mise.toml` in .gitignore.
- 2026-11-22: stb_image in Debug made every test decode slow. Fix: build.zig compiles vendored C with `-O2` in all modes.
- 2026-11-22: zig test runs are cached, so golden tests did not re-run after PNG edits. Fix: `has_side_effects = true` on test runs.
- 2026-11-22: status pill showed a tofu glyph: a slice pointed at a stack temporary. No test caught it; only reading the shot did. Fix: `ui.txt` golden covers the pill. Rule: after any chrome change, run `zig build shot` and read the PNG.
- 2026-11-22: a frame-pixel test failed because the hint bar covered the point on a 200x150 screen. Fix: tests that probe frame pixels press `?` first.
- 2026-11-22: XShmCreateImage keeps a pointer to the XShmSegmentInfo; a stack copy gave BadShmSeg. Fix: heap-allocate it (comment in x11.zig).
- 2026-11-22: the Zig test runner names the wrong test in "while executing test". Doc: docs/testing.md says to read the `error:` line.
- 2026-11-22: bench numbers moved +-30% between runs (powersave governor). Fix: `--bench` repeats startup and prints min/median.
- 2026-11-22: X11 check was a manual xdotool session. Fix: `zig build smoke-x11`.
- 2026-11-22: CLI errors did not name the bad option or path. Fix: cli.Diag and per-path messages.
- 2026-11-22: `git stash` without `-u` while splitting commits hid staged work. Rule: stage the commit's paths and `git commit` them; check other commits in a `git worktree`.
- 2026-11-22: `perf record` is not allowed (perf_event_paranoid), no sudo. Profile with micro-benchmarks or timers instead; open.
