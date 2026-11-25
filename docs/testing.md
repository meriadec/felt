# Testing

`zig build test` runs, in this order of speed:

1. Core unit tests (`test` blocks in `src/core/*.zig`).
2. App tests: CLI, script parser, export mapping, keymap doc freshness.
3. Golden replays (`src/golden.zig`): every `tests/scripts/*.txt` is replayed on
   `tests/fixtures/screenshot.png` (1200x750), or on the script's `image`.
   For each script it compares the final UI frame and the export with
   `tests/golden/<name>.frame.png` and `<name>.export.png`, and checks that
   the damage-tracked frame equals a full repaint.

Tests run with the repo root as working directory and always re-run (they read
files from disk).

## See the UI

```sh
zig build shot -Dscript=callout   # or no -Dscript for all scripts
```

writes `test-out/shots/<name>.frame.png` (what the screen shows, chrome
included) and `<name>.export.png` (what Ctrl+S writes). Read the PNG. To
look again after a change, add `-Dtag=v2` (files get a `.v2` suffix): an
image reader may cache a path and show the old picture. The
chrome scales with the screen height, so check it at real sizes too:

```sh
zig build shot -Dscript=help -Dsize=3840x2160   # test-out/shots/help.3840x2160.frame.png
```

`-Dsize` replays the same screen coordinates, so shapes land elsewhere on a
bigger screen: use it to check the chrome, not the shapes.

To check anti-aliasing, zoom a crop. Write it under test-out/ with a new name
each time (an image viewer may cache a reused path), and `+repage`:

```sh
convert test-out/shots/arrow.export.png -crop 140x120+740+380 +repage -filter point -resize 400% test-out/zoom-arrow-1.png
```

Ad hoc, without a script file:

```sh
zig build run -- --headless --size 1920x1080 --script my.txt --frame-out /tmp/f.png --export-out /tmp/e.png image.png
```

## Golden failures

A mismatch prints the pixel count and writes
`test-out/golden/<name>.<frame|export>.{actual,expected,diff}.png` (diff: magenta
pixels differ). A damage bug writes `<name>.damage.{incremental,full}.png`.
If the new rendering is intended, look at the shots, then:

```sh
zig build test -Dupdate-goldens=true
```

Tolerance: a channel may differ by 8; at most 0.05% of the pixels may differ.
To prove that a change keeps every golden pixel (a refactor, a new
parameter whose default must look the same), run with no tolerance:

```sh
zig build test -Dexact-goldens=true
```

Note: when a test fails, the Zig test runner may name another test in the
"while executing test" line. The `error:` line above it names the real one.

## Script format

One command per line, screen coordinates, `#` starts a comment.

| Command | Effect |
|---|---|
| `image PATH` | Replay on this image (repo-relative), e.g. `tests/fixtures/strip.png` (480x57); wins over the CLI image |
| `size W H` | Screen size (CLI `--size` wins; default 1280x720) |
| `key CHORD...` | Key presses: `a`, `5`, `]`, `?`, `ctrl+z`, `ctrl+shift+z`, `enter`, `shift+enter`, `esc`, `backspace`, `f1`, `space` |
| `keyup CHORD...` | Key released: `key space` holds the hand until `keyup space` |
| `type TEXT` | Types the rest of the line literally; `\n` is Shift+Enter |
| `click X Y [button]` | Press and release (`left`, `middle`, `right`; middle drag pans) |
| `dblclick X Y` | Two clicks; the second one is a double click (the move tool edits a text or callout) |
| `down X Y [button]`, `up X Y [button]` | Press, release |
| `move X Y` | Pointer motion |
| `move ui NAME...` | Pointer onto a chrome item, no click (hover); NAME as for `ui` |
| `drag X0 Y0 X1 Y1 [steps]` | Press, `steps` moves (default 8), release |
| `wheel up\|down [n] [at X Y] [ctrl]` | Wheel steps at a point (size; with `ctrl`: zoom about the point) |
| `ui tool NAME` (NAME as in the key map; `move` also names "move/select"), `ui color N`, `ui size`, `ui help`, `ui undo`, `ui redo`, `ui canvas-bg [light\|dark]`, `ui padding PX`, `ui arrow-style [straight\|stairs]`, `ui text-style [plain\|boxed]` | Click a dock or top bar item at its place for the screen size (scripts survive layout changes). `padding PX` clicks the slider notch of the step nearest to PX (a no-op if that step is set). `canvas-bg` with no name clicks the top bar switch (a toggle); with a name it clicks only if the canvas is not that one yet. `arrow-style` (alias `pointer-style`) with no name clicks the style not in use; with a name it clicks only if the style is not that one yet; the switch shows only with the arrow or the callout tool, over that tool's slot. `text-style` works like `arrow-style` for the text tool's switch |
| `resize W H` | Window resize |
| `capture` | Replay on the capture picker (src/core/picker.zig), not the editor: the image is the frozen screen and the screen has its size (`size` is ignored). The frame is the last picker frame; the export is the crop if the script confirmed a selection (a drag released, or a click on a window). `ui` is an error. The delay never waits: the crop is of the frozen picture |
| `window X Y W H` | A top-level window for the picker, topmost first (the first one that holds the pointer wins) |
| `place PATH X Y` | Place another image (repo-relative PNG) with its top-left corner at the scene point (X, Y) in image px; the first image is at (0, 0). One undo step |
| `addimage PATH SIDE` | Place another image on a magnet side (`left`, `top`, `right`, `bottom`) of the image placed last: 64 px away, centered on the shared edge (src/core/magnet.zig). One undo step. See tests/scripts/montage.txt (small tiles: tests/fixtures/tile_{a,b,c}.png) |
| `dropzone W H X Y` | Montage drop overlay for a dragged image of W x H px with the pointer at the screen point (X, Y): the free magnet slots around the placed images are dashed, the nearest to the pointer is highlighted (src/core/dropzone.zig). `dropzone off` clears it. Slots lie outside the images: with a canvas that fills the screen they are off-screen, so use small images (tests/scripts/montage_dropzone*.txt) |
| `drag X0 Y0 X1 Y1` on an image | With the move tool and 2+ images, a drag that starts on an image (no annotation under it) drags the image to the nearest free slot (tests/scripts/montage_drag.txt); a script that ends mid-drag shows the ghost and the slots (montage_drag_mid.txt). The press must be inside an image on the first view: the view zooms out at the first move, after the drop the view is refitted at once to the whole scene (like `0`), after the cancel (Esc) it is the original view (montage_drag_cancel.txt) |
| `touch PATH SECONDS` | Set the modification time of a file or folder (repo-relative) to SECONDS since the epoch. The file browser sorts by it, and git does not keep times: a script sets them (tests/scripts/browser_open.txt). Touch the files in a folder before the folder itself |
| `browser home DIR` | The folder the file browser starts in (repo-relative; replaces `$HOME`), before the first open. Dates show in UTC |
| `ui browser` / `move ui browser` | Click or hover the folder button (top left): opens or closes the browser panel (same as `key o`) |
| `browser cd NAME` | Move onto the row named NAME (`..` for the parent row) and click it: enters a folder. The row is scrolled into view first; an unknown name fails the replay |
| `browser up` | Click the up button of the header |
| `browser scroll N` | N wheel steps over the list (positive: down, negative: up) |
| `browser drag NAME X Y [hold]` | Press on the row NAME, move to (X, Y) in 8 steps, release. With `hold` the button stays down (the frame shows the ghost and the slots; `key esc` cancels, `up X Y` releases). The headless browser has no thread: thumbnails are ready right after each event. Fixture folder: tests/fixtures/browser/ (images and folders, a hidden file and a text file that must not show) |
| `delay SECONDS` | The picker's initial delay (`--delay`); `key tab` toggles it |

The replay renders after each event that asks for a redraw, like the X11
loop. A raw left press (`click`, `down`, `drag`) on the dock, its style
switch or the top bar fails the replay: click chrome with `ui`, so a
layout change never turns a drawing press into a button click. A script that ends mid-drag or mid-typing shows the preview in the frame.

File browser scripts (tests/scripts/browser_*.txt): `browser_open` (the list: mixed by date, thumbnails, no hidden or text file), `browser_nav` and `browser_trips` (enter a folder, up, scroll), `browser_drag_mid` (ghost + slots), `browser_drop` and `browser_drop_undo` (one undo step), `browser_drag_cancel` (Esc, release over the panel). Unit tests: `dirlist.zig` (filter, sort, dates, paths; a real temp folder), `thumbs.zig` (fit, LRU cache), `loader.zig` (sync and threaded, wake pipe, dropped jobs), `browsergeo.zig` (geometry, hit test, scroll clamp), `browser.zig` (listing, enter, up, errors, worker thread), `editor.zig` (keys, wheel, the drag state machine, cancel) and `browser_draw.zig` (ellipsis).

## Add a golden script

1. Write `tests/scripts/<name>.txt` with `size 900 500` (keeps PNGs small).
2. `zig build shot -Dscript=<name>` and look at the frame.
3. `zig build test -Dupdate-goldens=true`, then `zig build check`.
4. Commit the script and both goldens together.

## Habits

- Probe frame pixels at the left or right edge: the dock and the top bar sit
  at the bottom and top center and cover small screens.
- After any chrome change, run `zig build shot` and read the PNG: no test
  catches a wrong glyph.
- Write zoom crops under `test-out/` with a new name and `+repage`: an image
  reader caches a reused path.

## X11

`DISPLAY=:0 zig build smoke-x11` opens the real window, draws with xdotool,
saves, quits, and checks the saved PNG. It writes `test-out/x11-smoke/window.png`.
It grabs the pointer for about 3 s. No Xvfb is needed for anything else.
