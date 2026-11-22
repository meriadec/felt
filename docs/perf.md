# Performance

## Measure

```sh
zig build bench                                  # synthetic 2560x1440 image, 1920x1080 screen
zig build bench -- --size 3840x2160 shot.png     # your own image and screen size
DISPLAY=:0 zig-out/bin/annotate --smoke shot.png # real window: prints timings, exits after the first frame
```

`--bench` always builds ReleaseFast. It repeats startup 7 times and prints min
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

## Numbers (2026-11, after the growing canvas, zoom and pan)

`zig build bench` (synthetic 2560x1440 PNG, screen 1920x1080), min of 3 runs:

| Metric | Value |
|---|---|
| decode PNG (min) | 7.0 ms (stb: 8.7 ms) |
| first frame render (min) | 5.7 ms (was 5.3: the downscaled image is kept in `scaled`, then copied) |
| startup total (min) | 12.7 ms |
| frame, drag arrow | avg 0.50 ms, p95 1.0 ms (damage 11% of screen) |
| frame, drag pixelate | avg 0.32 ms, p95 0.67 ms |
| frame, type a character | avg 0.14 ms |
| frame, drag crop (outside dimmed) | avg 0.58 ms, p95 0.60 ms |
| crop release (refit + scene rebuild) | 4.1 ms |
| undo, scene rebuild with 31 annotations | 3.1 ms (was 8.7-10.7: `scaled` is kept, no new downscale) |
| export render / PNG encode | 4.8 ms / 10.5 ms (stb: 58-80 ms) |
| zoom out (`-`), scene rebuild at 2/3 | 5.2 ms |
| frame, drag that grows the canvas | avg 0.32 ms, p95 0.64 ms (damage 5.4% of screen) |
| frame, pan (middle drag, 31 annotations) | avg 0.83 ms, p95 1.0 ms (was 3.4 ms before the scene scroll) |
| Ctrl+wheel zoom (downscale + rebuild) | avg 4.1 ms, p95 5.0 ms |

`zig build bench -- --size 3840x2160` (same image, 4K screen, UI scale 2):
drag arrow avg 1.6 ms p95 3.4 ms, drag pixelate avg 0.86 ms p95 2.0 ms (the
drag starts outside the image, so it grows the canvas live), type a character
avg 0.44 ms, drag crop avg 1.7 ms p95 1.8 ms, crop release 10 ms, undo 10.4 ms,
export 7.2 / 12.6 ms, drag that grows the canvas avg 0.90 ms p95 1.9 ms, pan
avg 4.5 ms p95 4.6 ms (two full-frame copies: scene scroll + frame), zoom
11.3-13.3 ms.

Before these changes (commit "docs: perf numbers after the crop tool"), the
same runs gave: first frame 5.3 ms, startup 12.3 ms, drag arrow avg 0.49 ms,
undo 10.6 ms, export 4.2 / 10.8 ms; at 4K drag arrow avg 1.5 ms p95 3.3 ms,
drag pixelate avg 0.55 ms, undo 13.2 ms, export 6.4 ms.

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
- The canvas grows by bands: a drag past the image damages only the white
  bands it adds or removes; a commit fills them in the scene and appends.
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
- Undo rebuilds the whole scene (3 ms at 1080p, 10 ms at 4K with 31 annotations). A per-step
  scene cache would make it ~1 ms.
- PNG row conversion (RGBA -> pixels, 3-4 ms at 4K) could run on threads.
