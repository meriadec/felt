# Friction log

Open hiccups only: a confusing error, a slow or missing command, a repeated
manual step, a missing doc.

1. Fix it in the repo (tool, flag, build step, script, test, doc), in its own
   small commit.
2. If you cannot fix it now, add one line below: date, what happened.
3. The fix commit deletes the line. The commit message keeps the story.
4. A rule that no code can enforce goes to the doc it belongs to
   (docs/testing.md, AGENTS.md), not here.
5. A hiccup that happens twice needs tooling or a test, not a longer doc.

## Open

- 2026-11-25: `zig build test -Dexact-goldens=true` fails on `zoom_out` (1 pixel: the incremental frame differs from a full repaint); it did before the montage work too (68609f4). Zero tolerance finds it; find the 1-pixel rounding in the zoom damage.
