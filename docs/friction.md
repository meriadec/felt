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
- 2026-11-22: a frame-pixel test failed because chrome covered the point on a small screen. The dock is at the bottom center and the top bar at the top center: probe frame pixels at the left or right edge, or press Space to hide both (editor unit tests start with them hidden).
- 2026-11-22: XShmCreateImage keeps a pointer to the XShmSegmentInfo; a stack copy gave BadShmSeg. Fix: heap-allocate it (comment in x11.zig).
- 2026-11-22: the Zig test runner names the wrong test in "while executing test". Doc: docs/testing.md says to read the `error:` line.
- 2026-11-22: bench numbers moved +-30% between runs (powersave governor). Fix: `--bench` repeats startup and prints min/median.
- 2026-11-22: X11 check was a manual xdotool session. Fix: `zig build smoke-x11`.
- 2026-11-22: CLI errors did not name the bad option or path. Fix: cli.Diag and per-path messages.
- 2026-11-22: `git stash` without `-u` while splitting commits hid staged work. Rule: stage the commit's paths and `git commit` them; check other commits in a `git worktree`.
- 2026-11-22: `perf record` is not allowed (perf_event_paranoid), no sudo. Profile with micro-benchmarks or timers instead; open.
- 2026-11-22: `-Dupdate-goldens=true` rewrote every golden after an encoder change (same pixels). Fix: rewrite only on a pixel change.
- 2026-11-23: checking the chrome at 1080p and 4K took ad hoc `--headless --size` commands. Fix: `zig build shot -Dsize=WxH`.
- 2026-11-23: a zoom crop written to a reused /tmp path showed an old unrelated image in the agent's image reader. Fix: docs/testing.md writes zooms under test-out/ with a new name and `+repage`.
- 2026-11-23: golden scripts could only replay on the 1200x750 fixture; the canvas-growth case needed a small wide image. Fix: script command `image PATH` and tests/fixtures/strip.png.
- 2026-11-23: `zig build shot -Dsize=3840x2160` replays the same screen coordinates, so shapes land far from the image at 4K. Doc: docs/testing.md says -Dsize is for chrome checks.
- 2026-11-23: the X11 smoke test failed once: Esc came 0.5 s after Ctrl+S, before the save. Fix: the script waits for the saved file.
- 2026-11-23: a compile error in `zig build check` prints a multi-KB zig command line around the error. Workaround: `zig build check 2>&1 | grep -v '^/home'`; open.
- 2026-11-23: adding the move tool widened the dock and broke the dock clicks in ui.txt and help.txt (raw coordinates). Fix: script command `ui tool NAME | color N | size | help | undo | redo`.
- 2026-11-23: `zig build check ...; git commit` committed on a red check (a golden had changed). Rule: chain `check && git commit`; every commit re-checked in a worktree at the end.
- 2026-11-23: no profiler (`perf` not allowed): finding the move drag hot spot took temporary timers in compositor.zig. Second time for the stairs move: fix: `compositor.Prof`, the bench prints a scene / frame / chrome split of each move drag.
- 2026-11-22: `a` again now switches the arrow style (`c` again now too: no script pressed it twice); 7 golden scripts and the bench pressed `a` with the arrow tool already active and silently drew stairs. Fix: scripts lost the extra `key a`; the bench asserts its tool and style before each arrow case. Open: no `check` step runs the bench, so a behaviour change breaks it unseen.
- 2026-11-22: the callout style switch shows over the callout slot; callout.txt clicked its label there and silently toggled the style (then typed tool keys). Same class: stairs.txt had pressed on the top bar since its first commit, so one arrow never showed. Fix: a script press on the dock, its switch or the top bar fails the replay (`ui ...` clicks chrome).
- 2026-11-23: proving that the existing stairs goldens stayed pixel-identical took a manual `compare -metric AE` loop over the shots (the golden tolerance hides small changes). Fix: `zig build test -Dexact-goldens=true`.
- 2026-11-23: the bench's stairs move pressed the middle of the middle segment, which became the bend handle: the bench stopped with an error and printed none of its results (buffered). Fix: the bench flushes on error; it presses the first segment. Second hit of "no `check` step runs the bench": still open.
- 2026-11-23: topbar.txt hovered redo with a raw `move 470 40`; a wider top bar would move it off redo with no error. Fix: script command `move ui NAME` hovers a chrome item where it is.
- 2026-11-23: a re-rendered `zig build shot` PNG read at the same path showed the old picture (second hit of the reader cache). Fix: `zig build shot -Dtag=NAME` writes new paths.
