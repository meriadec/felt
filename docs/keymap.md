# Key map

Generated from `src/core/keymap.zig` by `zig build docs`. Do not edit by hand.

## Tools

| Key | Tool | Mouse |
|---|---|---|
| `a` | arrow | Drag from the tail to the head. |
| `t` | text | Click, type. Enter or Esc finishes, Shift+Enter adds a line, Backspace erases. |
| `r` | rect | Drag from corner to corner. |
| `n` | number | Click to drop the next number (1, 2, 3...). Undo takes the number back. |
| `c` | callout | Drag from the point of interest to where the box goes, release, type, Enter. A plain click makes a label without a pointer. |
| `h` | highlight | Drag over text to mark it like a highlighter pen. |
| `p` | pixelate | Drag over a secret to pixelate it. |

## Keys

| Key | Action |
|---|---|
| `1` | color red |
| `2` | color orange |
| `3` | color yellow |
| `4` | color green |
| `5` | color blue |
| `6` | color purple |
| `7` | color white |
| `8` | color black |
| `Tab` | next tool |
| `Shift+Tab` | previous tool |
| `[` | size |
| `]` | bigger |
| `Ctrl+z` | undo |
| `Ctrl+Shift+z` | redo |
| `Ctrl+y` | redo |
| `Ctrl+s` | save |
| `Ctrl+c` | copy |
| `Esc` | quit |
| `?` | help |
| `F1` | help |

## Mouse and context

| Input | Effect |
|---|---|
| Mouse wheel | Bigger / smaller stroke and text |
| Right click | Cancel the shape or text in progress |
| Esc while drawing | Cancel the shape in progress |
| Esc with unsaved changes | Shows a warning; a second Esc quits. Ctrl+C counts as saved: the clipboard keeps the image. |
| Ctrl+Z while typing | Drop the text in progress |
| Tab while typing | Finish the text, then go to the next tool |
