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

## Numbers (2026-11, commit "perf: split image downscaling across threads")

`zig build bench` (synthetic 2560x1440 PNG, screen 1920x1080):

| Metric | Value |
|---|---|
| decode PNG (min) | 9.5 ms (stb: 11.8 ms) |
| first frame render (min) | 5.7 ms |
| startup total (min) | 15.3 ms |
| frame, drag arrow | avg 0.54 ms, p95 1.07 ms (damage 11% of screen) |
| frame, drag pixelate | avg 0.33 ms, p95 0.70 ms |
| frame, type a character | avg 0.06 ms |
| undo, scene rebuild with 31 annotations | 9.2 ms |
| export render / PNG encode | 4.1 ms / 11.3 ms (stb: 60 ms) |

`zig build bench -- --size 3840x2160 root4k.png` (real 4K screenshot, 1.6 MB PNG):

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

- Present is 6-10 ms for a full 4K frame (X server copy); only the first frame
  pays it.
- Undo rebuilds the whole scene (9-12 ms with 31 annotations). A per-step
  scene cache would make it ~1 ms.
- PNG row conversion (RGBA -> pixels, 3-4 ms at 4K) could run on threads.
