# annotate

Fast full-screen screenshot annotation for X11. Opens an image, you draw
arrows, text, boxes, numbered bubbles, callouts, highlights and pixelation
with one-letter tools, then save (Ctrl+S) or copy (Ctrl+C). Built to replace
`ksnip -e` in an i3 setup.

## Install

Needs Zig 0.15.2 (pinned in `mise.toml`), X11 headers (`libx11-dev`,
`libxext-dev`) and, for Ctrl+C, `xclip`.

```sh
mise exec -- zig build -Doptimize=ReleaseFast --prefix ~/.local install
# -> ~/.local/bin/annotate
```

## Use

```sh
annotate shot.png            # Ctrl+S overwrites shot.png
annotate -e shot.png         # same (ksnip-compatible flag)
annotate -o out.png shot.png # Ctrl+S writes out.png
```

The image fits the screen (never upscaled). Press `?` or F1 to show or hide
the key bar. Esc quits; with unsaved changes, press Esc twice. Ctrl+C counts as
saved, because xclip keeps the image in the clipboard after annotate exits.

Full key map: [docs/keymap.md](docs/keymap.md).

## i3

Replace the ksnip lines with:

```
bindsym $mod+e exec "annotate -e $(/bin/ls -1td /home/mpillet/* | head -n 1)"
for_window [class="annotate"] floating enable, fullscreen enable
```

The first line opens the newest file in your home directory (`ls -1td` with a
glob gives full paths, so the working directory of i3 does not matter).
annotate asks for full screen itself; the `for_window` line keeps i3 from
tiling it for a moment. To shoot and annotate in one key:

```
bindsym Print exec "maim -s /tmp/shot.png && annotate -o $HOME/shot-$(date +%s).png /tmp/shot.png"
```

## Develop

See [AGENTS.md](AGENTS.md).
