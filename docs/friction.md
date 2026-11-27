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

- A 16-bit PNG (ImageMagick `gradient:` default) opens as a blank scene with no toast, in the montage CLI path (seen with `felt A.png B.png C.png`; 8-bit PNG24 works). Find out why and show an error or convert.
- `zig build bench` aborts at HEAD with `BenchNoStairsStyle` (then `BenchNoStairsCallout`) in the drag-stairs cases (bench.zig ~317, ~411), also with an empty config. The callout setup there no longer leaves the stairs style on; fix the setup and let the bench run to the end. (2026-11, found during the Zig 0.17 port)
