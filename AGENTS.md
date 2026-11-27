# Felt

Full-screen screenshot annotation tool for X11 (replaces ksnip in i3). Zig 0.17.1.
A pure core (document, tools, editor state machine, software renderer) with
two thin backends: X11 window and headless script replay.

## Dev loop

Run zig as `mise exec -- zig build <step>` (fresh clone: `mise trust` first).
`zig build --help` lists all steps.

```sh
zig build check                       # fmt-check + unit tests + golden replays: before every commit (`mise run check`: short compile errors)
zig build shot -Dscript=arrow         # render tests/scripts/arrow.txt to test-out/shots/*.png, then read the PNGs
zig build test -Dupdate-goldens=true  # accept new rendering (look at the shots first)
zig build local                       # reinstall ~/.local/bin/felt from this tree
zig build bench                       # ReleaseFast timings; compare with docs/perf.md
DISPLAY=:0 zig build smoke-x11        # real window, driven by xdotool
```

## Rules

- The user tests the installed `felt`. After every change to the code, run
  `zig build local` (the post-commit hook in .githooks does it for commits;
  a fresh clone: `git config core.hooksPath .githooks`). Tell the user when
  the binary is stale.
- Self-improvement: every hiccup (confusing error, slow or missing command,
  repeated manual step, missing doc) is a harness bug. Fix it in the repo
  (tool, flag, build step, script, doc) in its own small commit. If you
  cannot fix it now, add one line to docs/friction.md (open items only; the
  fix commit deletes the line).
- Commits: conventional (`feat:`, `fix:`, `perf:`, `refactor:`, `test:`,
  `docs:`, `build:`, `chore:`), one concern each, green (`zig build check`). Chain `check && git commit`: never commit on a red check.
- One concept per file, with a `//!` doc comment that states its role.
- Do not edit docs/keymap.md: `zig build docs` writes it from src/core/keymap.zig.

## Read before you act

- docs/architecture.md: before you change src/core or a backend, or add a tool.
- docs/testing.md: before you add or change a script, a golden or a test.
- docs/perf.md: before you change the renderer, the compositor, image IO or the X11 loop.
- docs/friction.md: open hiccups; read it before you finish a task.
