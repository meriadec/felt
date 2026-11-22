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
included) and `<name>.export.png` (what Ctrl+S writes). Read the PNG. The
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

Note: when a test fails, the Zig test runner may name another test in the
"while executing test" line. The `error:` line above it names the real one.

## Script format

One command per line, screen coordinates, `#` starts a comment.

| Command | Effect |
|---|---|
| `image PATH` | Replay on this image (repo-relative), e.g. `tests/fixtures/strip.png` (480x57); wins over the CLI image |
| `size W H` | Screen size (CLI `--size` wins; default 1280x720) |
| `key CHORD...` | Key presses: `a`, `5`, `]`, `?`, `ctrl+z`, `ctrl+shift+z`, `enter`, `shift+enter`, `esc`, `backspace`, `f1`, `space` |
| `type TEXT` | Types the rest of the line literally; `\n` is Shift+Enter |
| `click X Y [button]` | Press and release (`left`, `middle`, `right`; middle drag pans) |
| `down X Y [button]`, `up X Y [button]` | Press, release |
| `move X Y` | Pointer motion |
| `drag X0 Y0 X1 Y1 [steps]` | Press, `steps` moves (default 8), release |
| `wheel up\|down [n] [at X Y] [ctrl]` | Wheel steps at a point (size; with `ctrl`: zoom about the point) |
| `ui tool NAME`, `ui color N`, `ui size`, `ui help`, `ui undo`, `ui redo`, `ui arrow-style [straight\|stairs]` | Click a dock or top bar item at its place for the screen size (scripts survive layout changes). `arrow-style` (alias `pointer-style`) with no name clicks the style not in use; the switch shows only with the arrow or the callout tool, over that tool's slot |
| `resize W H` | Window resize |

The replay renders after each event that asks for a redraw, like the X11
loop. A script that ends mid-drag or mid-typing shows the preview in the frame.

## Add a golden script

1. Write `tests/scripts/<name>.txt` with `size 900 500` (keeps PNGs small).
2. `zig build shot -Dscript=<name>` and look at the frame.
3. `zig build test -Dupdate-goldens=true`, then `zig build check`.
4. Commit the script and both goldens together.

## X11

`DISPLAY=:0 zig build smoke-x11` opens the real window, draws with xdotool,
saves, quits, and checks the saved PNG. It writes `test-out/x11-smoke/window.png`.
It grabs the pointer for about 3 s. No Xvfb is needed for anything else.
