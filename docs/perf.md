# Performance

## Measure

```sh
zig build bench                                  # synthetic 2560x1440 image, 1920x1080 screen
zig build bench -- --size 3840x2160 shot.png     # your own image and screen size
DISPLAY=:0 zig-out/bin/felt --smoke shot.png # real window: prints timings, exits after the first frame
```

Move drags also print a split: scene repaint, frame composition (chrome
part of it) and the rect counts (`compositor.Prof`), so a slow case shows
its hot part without temporary timers. `--bench` always builds ReleaseFast. It repeats startup 7 times and prints min
and median: this desktop (Ryzen AI 9 HX 370, `powersave` governor, hybrid
cores) varies by +-30% from run to run, so compare mins. `--smoke` needs
`-Doptimize=ReleaseFast` for real numbers. `--timing` prints the same line on a
normal run.

## Budgets

| What | Budget |
|---|---|
| First frame on screen, 4K screenshot on a 4K screen (`--smoke`) | < 60 ms |
| Startup in `--bench` (decode + first frame), 1080p | < 25 ms |
| Frame while dragging or typing, 4K, p95 | < 4 ms (a 240 Hz frame) |
| Export render + PNG encode, 4K | < 60 ms |

## Capture mode (2026-11)

`zig build bench` prints the picker cases (`benchCapture`): a frozen screen
of the screen size, dimmed once per repaint rect, the selection copied back
bright. Min of 2 runs, ReleaseFast:

| Metric | 1080p | 4K |
|---|---|---|
| first picker frame | 1.1 ms | 3.7 ms |
| drag frame (100 motion events, 20% to 80%) | avg 0.20 ms, p95 0.71 | avg 1.09 ms, p95 2.99 |
| crop of a 60% rectangle | 1.1 ms | 2.6 ms |

A frame repaints the old and the new highlight (and the pills): 13% of the
screen on average in that drag. Real display (4K, `felt --capture --timing`,
shared memory): root grab 13-16 ms; window up and first picker frame on
screen 48 ms after the process starts. The dim is one multiply per channel
per pixel, in a loop the compiler vectorizes. Not done: repainting only the
bands that a drag adds (a 4K drag frame is already under the 4 ms budget).

## Canvas background switch (2026-11)

Min of 3 to 6 runs each, before (commit "docs: the arrow tool help says a
stairs path routes around the others") and after the light / dark canvas
background, its config file, and per-panel chrome damage:

| Metric | 1080p | 4K |
|---|---|---|
| frame, canvas bg switch (`b`, grown canvas, zoomed out) | avg 0.16 ms, p95 0.19 | avg 0.84 ms, p95 1.27 |
| config read (startup, window mode only) | 0.003 ms | 0.003 ms |
| config write (atomic, on a switch) | 0.012 ms | 0.014 ms |
| startup total | 13.0 -> 12.5 ms (noise) | 12.3 -> 12.3 ms |
| frame, drag crop | avg 0.32 -> 0.11 ms | avg 0.74 -> 0.21 ms |

A switch repaints the scene only in the bands of canvas around the image
(the annotations there with it, a pixelate across the edge grown to hold
all of it) and the toast: 14% of a 1080p screen. Before per-panel chrome
damage it took 1.6 ms at 4K: the new toast repainted the dock and the top
bar too. The crop drag gains the same way (its "Crop to W x H" toast
changes each frame). `--smoke` on the 4K display: config read 0.03-0.06 ms
on the main thread while the image decodes; first frame on screen 29-34 ms
(before: 34-41 ms, noise). All other cases within noise (+-5%; undo
rebuild at 1080p 2.3-3.6 ms before, 2.9-3.2 after: one sample per run).

## Canvas padding (2026-11)

Padding 0 changes no path of the renderer: `ctx.pad` is added to the kept
rectangle in `extent` (an expand by 0), and the compositor compares one more
integer per frame. Bench at 1080p, 3 runs: all existing cases within noise
(drag arrow avg 0.24-0.27 ms, canvas bg switch 0.16-0.19 ms). New case
`frame: padding step` (`.` four times, `,` four times, x3): avg 5.5 to 8 ms,
p95 8 to 10 ms. A step changes every clip, the canvas and the fit, so the
scene repaints in full (like a crop refit, 2.8 ms, plus the larger canvas);
it runs once per gesture step, never per drag frame of a shape.

## Auto-routing (2026-11)

Min of 3 runs each, before (commit "test: a callout grows the canvas to
its pointer head") and after the auto-routing of stairs paths. The cases
that existed did not move beyond noise (1080p: drag stairs arrow avg
0.33 -> 0.34 ms, p95 0.64 -> 0.66; 4K: avg 1.08 -> 1.12, p95 2.33 ->
2.43; all others within +-5%). The stairs move case now grabs the first
segment (the middle holds the bend handle), so its numbers changed with
the repaint pattern (4K p95 2.10 -> 1.58 ms).

The routing cases (`benchRouting` in src/bench.zig): 31 annotations plus
a fan of 8 stairs arrows across the row of 30 numbers, then a stairs
arrow dragged through them and committed, then one fan arrow moved:

| Metric | 1080p | 4K |
|---|---|---|
| commit of a fan arrow (settle + render) | avg 0.93 ms, p95 1.83 | avg 2.39 ms, p95 4.75 |
| frame, drag stairs arrow, routed in the preview | avg 0.46 ms, p95 0.64 | avg 1.42 ms, p95 2.25 |
| its commit | 1.30 ms | 2.89 ms (settle 0.6 ms) |
| frame, move a stairs arrow, routed | avg 0.85 ms, p95 1.07 | avg 2.07 ms, p95 2.64 |
| route per motion event (`route.best`, 40 annotations) | 0.034 ms | 0.035 ms |
| move commit, 2 neighbours re-routed | 3.7 ms | 6.7 ms (settle 0.7 ms) |

The router is cheap: every candidate path lies in the box of its two
ends, so it collects only the segments and label boxes that touch that
box (a bounds test per segment), then tests 1 + 49 x 2 candidates of 3
segments each, with a bounds rejection per pair. A commit's time is
mostly the scene repaint of the re-routed paths (old and new cover, each
rect repainting every annotation under it), like a move.

## Numbers (2026-11, after the stairs arrows and the callout arrow pointers)

`zig build bench` (synthetic 2560x1440 PNG, screen 1920x1080), min of 3 runs;
"was" is the run before the stairs arrows (commit "feat!: remove the
highlight tool"):

| Metric | Value |
|---|---|
| decode PNG (min) | 7.0 ms (stb: 9.0 ms) |
| first frame render (min) | 5.7 ms (was 5.6) |
| startup total (min) | 12.9 ms (was 13.0) |
| frame, drag arrow | avg 0.24 ms, p95 0.45 ms |
| frame, drag stairs arrow | avg 0.32 ms, p95 0.63 ms (new) |
| frame, drag stairs callout (pointer preview) | avg 0.20 ms, p95 0.34 ms, damage 3.7% (new) |
| frame, drag pixelate | avg 0.32 ms, p95 0.67 ms |
| frame, type a character | avg 0.13 ms |
| frame, move drag (long arrow, 31 annotations) | avg 0.47 ms, p95 0.49 ms, damage 5.2% (was 0.54 / 0.59: merge rule below) |
| frame, move drag (long stairs arrow, 32 annotations) | avg 0.59 ms, p95 0.78 ms, damage 2.2% (new; 1.28 / 1.85 before the stairs perf commits) |
| frame, move drag (stairs callout box, 32 annotations) | avg 0.68 ms, p95 0.89 ms, damage 2.5%, 5 repaint rects (new) |
| undo, scene rebuild with 31 annotations | 2.2 ms |
| export render / PNG encode | 3.6 ms / 10.8 ms |
| frame, drag crop (outside dimmed) | avg 0.32 ms, p95 0.35 ms |
| crop release (refit + scene rebuild) | 2.8 ms |
| zoom out (`-`), scene rebuild at 2/3 | 6.4 ms (4.9 before the canvas shadow: it is a per-pixel band around the canvas) |
| frame, drag that grows the canvas | avg 0.15 ms, p95 0.28 ms |
| frame, pan (middle drag, 31 annotations) | avg 0.60 ms, p95 0.82 ms (was 0.56: the arrow style switch is drawn in each full frame) |
| Ctrl+wheel zoom (downscale + rebuild) | avg 2.6 ms, p95 3.3 ms |

`zig build bench -- --size 3840x2160` (same image, 4K screen, UI scale 2),
min of 3 runs: drag arrow avg 0.76 ms p95 1.65 ms, drag stairs arrow avg
1.07 ms p95 2.29 ms, drag pixelate avg 0.90 ms p95 2.06 ms, type a
character avg 0.42 ms, move drag avg 1.30 ms p95 1.35 ms (was 1.46 /
1.55), move drag of a stairs arrow avg 1.58 ms p95 2.11 ms (damage 1.9%;
3.56 / 5.0 before the stairs perf commits: over the 4 ms budget), drag
stairs callout avg 0.61 ms p95 1.07 ms, move of a stairs callout box avg
1.75 ms p95 2.30 ms (damage 2.1%), undo 7.5
ms, export 5.4 / 13.3 ms, drag crop avg 0.76 ms, crop release 7.2 ms, drag
that grows the canvas avg 0.43 ms p95 0.85 ms, pan avg 3.8 ms p95 4.7 ms
(was 3.7), zoom 7.6-9.4 ms.

The stairs move drag at 4K went 3.56 -> 2.96 ms (axis-aligned segment
distance, no division) -> 3.1 ms (4 repaint boxes, not 8; 1080p 1.07 ->
0.88) -> 1.58 ms (merge rule: a box moved by a pixel in x and y was
painted twice, as two overlapping rects).

The move drag went 8.2 -> 5.0 ms (sdf union) -> 4.4 ms (no outline while
moving) -> 1.6 ms (slab repaint) at 4K.

`zig build bench -- --size 3840x2160 root4k.png` (real 4K screenshot, 1.6 MB PNG;
measured at commit "perf: split image downscaling across threads"):

| Metric | Value |
|---|---|
| decode PNG (min) | 22 ms (stb: 39.6 ms) |
| first frame render (min) | 5.8 ms |
| frame, drag arrow | avg 1.3 ms, p95 3.0 ms |
| frame, type a character | avg 0.08 ms |
| export render / PNG encode | 6.0 ms / 33.8 ms, 1.6 MB (stb: 183 ms, 2.1 MB) |

`--smoke` on the 4K display (i3), same screenshot: window mapped 2-3 ms, image
decoded 25-29 ms (on a thread, in parallel with the window), first frame on
screen 41-42 ms (render 5.5-7 ms, present 6.5-10 ms). Whole process
(`/usr/bin/time`): 0.05-0.06 s.

## What makes it fast

- Decode on a thread while the X connection, window and shared-memory frame
  come up; the main thread faults the frame pages in meanwhile.
- Own PNG decoder for 8-bit RGB/RGBA (src/core/png.zig): libdeflate inflate,
  vectorized row filters, Paeth rows undone 4 at a time with a 1-pixel skew
  so 4 dependency chains run in parallel. stb_image handles all other files.
- Big buffers (canvases, PNG scratch, stb buffers) are mmapped with
  transparent huge pages: 16 page faults per 4K frame instead of 8100.
- Compositor layers: the image is drawn straight into the scene; the frame is
  the X11 shared-memory image; only damaged rectangles are repainted and put.
- Crop keeps the decoded image: the `scaled` layer downscales only the kept
  rectangle, once per zoom level or crop; at 1:1 the image is copied as is,
  above 1:1 sampled (nearest) only where visible. The export copies it.
- The canvas grows by bands: a drag past the image damages only the
  bands it adds or removes; a commit fills them in the scene and appends.
  A canvas background switch repaints only the bands around the image.
- Chrome panels repaint one by one (`State.panelSig`): a changing toast
  does not repaint the dock.
- A move repaints the scene only under the old and the new place, and
  for thin shapes (arrow, callout pointer, rect outline) only slabs along
  them (`draw.cover`, on a fixed grid); a stairs arrow or stairs callout
  pointer only the boxes of its three axis-aligned segments and its head
  (a callout: plus its box). Two repaint rects merge
  when their union is no bigger than both apart (`Fix` in compositor.zig):
  a slab at the old and the new place, a box moved by a pixel. A
  repaint rect that touches a pixelate grows to hold all of it.
- `sdf.Union` skips its second shape where the distance to that shape's
  bounds is already larger: along an arrow shaft, the head is not computed.
- Damage keeps up to 12 rects; when full, a new rect folds into the one
  that grows the least (not all into one).
- A pan scrolls the scene (whole-pixel offsets) and paints only the
  uncovered strips. A scene with a pixelate repaints in full (pixelate reads
  the pixels under it). A crop drag repaints only the
  bands between the old and the new rectangle (Damage does not merge rects
  whose union is much bigger than both).
- Rasterizer: signed distance shapes in 8x8 tiles; tiles outside are skipped,
  tiles inside are filled without per-pixel math.
- Downscale: separable area filter, both passes split across threads.
- X11 loop: drains all queued events (motion bursts) before one render.

## Tried and rejected

- wuffs PNG decoder: same speed as stb in fresh processes here, 3.7 MB of C.
- Zig std inflate (0.15): 2.5x slower than libdeflate.
- stb_image_write at lower zlib levels: at most 30% faster; libdeflate level 1
  is 5x faster with smaller files.

## Open leads

- A pan presents the whole frame (6-10 ms at 4K) and copies it twice. An
  X server side scroll (`XCopyArea`) plus strips would make it cheap.
- Zoom at 4K rebuilds `scaled` (11-13 ms); levels could be cached.
- Present is 6-10 ms for a full 4K frame (X server copy); the first frame,
  zoom and pan pay it.
- Undo of an add or a crop rebuilds the whole scene (2.2 ms at 1080p, 8.4 ms
  at 4K with 31 annotations; the undo of a move repaints in place). A
  per-step scene cache would make it ~1 ms.
- A move under or of a big pixelate repaints the whole pixelate each frame.
- A commit that re-routes long stairs paths repaints their old and new
  covers over every annotation under them (6.7 ms at 4K with 2 re-routes
  among 40 annotations); a per-annotation layer cache would cut it.
- `route.best` collects obstacles per call (text measure for label
  boxes); a drag could cache them for its duration if scenes get dense.
- No profiler here (`perf` is not allowed). The bench prints a scene /
  frame / chrome split of the move drags (`compositor.Prof`); finer splits
  (per annotation kind) still need temporary timers.
- PNG row conversion (RGBA -> pixels, 3-4 ms at 4K) could run on threads.
