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

2026-11-25: `DISPLAY=:0 zig build smoke-x11` fails also on a74a9c0 (before the browser): the saved PNG corner is #2E3440, expected #4C566A (canvas dark after b). Not looked into.
- A 16-bit PNG (ImageMagick `gradient:` default) opens as a blank scene with no toast, in the montage CLI path (seen with `felt A.png B.png C.png`; 8-bit PNG24 works). Find out why and show an error or convert.
- `zig build bench -- --size 3840x2160` fails with `BenchMoveMissedTheFanArrow` (2026-11, seen while timing the picker ruler).
