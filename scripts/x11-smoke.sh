#!/usr/bin/env bash
# X11 smoke test on a real display (needs DISPLAY, xdotool, ImageMagick `import`).
# Opens felt on a copy of the fixture, draws a stairs arrow (`a`: the
# style stays the startup stairs), two numbers and a text with xdotool,
# zooms out (Ctrl+wheel), pans (middle drag), drops a number past the image
# edge, switches the canvas to dark (`b`), captures the
# window, saves with Ctrl+S, quits with Esc, then checks the saved PNG (the
# canvas grew to the right, dark grey) and the config file (canvas_bg=dark,
# under a test XDG_CONFIG_HOME: the user's config is never touched). Run
# through `zig build smoke-x11`.
# Takes about 3 s and grabs the pointer and the screen meanwhile.
set -euo pipefail
bin=${1:-zig-out/bin/felt}
out=test-out/x11-smoke
mkdir -p "$out"
rm -f "$out"/*.png "$out"/log.txt
rm -rf "$out/xdg"

for tool in xdotool import identify; do
  command -v "$tool" >/dev/null || { echo "x11-smoke: $tool not found" >&2; exit 2; }
done
[ -n "${DISPLAY:-}" ] || { echo "x11-smoke: DISPLAY is not set (try DISPLAY=:0)" >&2; exit 2; }

cp tests/fixtures/screenshot.png "$out/input.png"
XDG_CONFIG_HOME="$PWD/$out/xdg" "$bin" --timing -o "$out/saved.png" "$out/input.png" 2>"$out/log.txt" &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT

wid=
for _ in $(seq 50); do
  wid=$(xdotool search --class '^felt$' 2>/dev/null | head -1) && [ -n "$wid" ] && break
  sleep 0.1
done
[ -n "$wid" ] || { echo "x11-smoke: no felt window after 5 s" >&2; cat "$out/log.txt" >&2; exit 1; }
sleep 0.3
eval "$(xdotool getwindowgeometry --shell "$wid")"
cx=$((X + WIDTH / 2)); cy=$((Y + HEIGHT / 2))

xdotool windowfocus --sync "$wid" # a key before the focus is lost
xdotool key a # the arrow tool (the callout tool is active at startup)
xdotool mousemove --sync $((cx - 250)) $((cy + 150)) mousedown 1
for i in 1 2 3 4 5; do xdotool mousemove $((cx - 250 + i * 40)) $((cy + 150 - i * 30)); sleep 0.02; done
xdotool mouseup 1
xdotool key n mousemove $((cx + 100)) $((cy - 100)) click 1 mousemove $((cx + 200)) $((cy - 100)) click 1
xdotool key t mousemove $((cx - 250)) $((cy + 200)) click 1
xdotool type --delay 5 "x11 smoke"
xdotool key Return
xdotool mousemove --sync $cx $cy keydown ctrl click 5 keyup ctrl
xdotool mousedown 2 mousemove $((cx + 50)) $((cy + 25)) mousemove $((cx + 100)) $((cy + 50)) mouseup 2
xdotool key n mousemove $((cx + 700)) $cy click 1
xdotool key b
sleep 0.3
import -window "$wid" "$out/window.png"
xdotool key ctrl+s
for _ in $(seq 50); do [ -s "$out/saved.png" ] && break; sleep 0.1; done
sleep 0.2
xdotool key Escape
for _ in $(seq 30); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
if kill -0 $pid 2>/dev/null; then echo "x11-smoke: felt did not quit on Esc after save" >&2; exit 1; fi
trap - EXIT

[ -f "$out/saved.png" ] || { echo "x11-smoke: Ctrl+S wrote nothing" >&2; exit 1; }
want=$(identify -format '%w %h' "$out/input.png")
got=$(identify -format '%w %h' "$out/saved.png")
read -r ww wh <<<"$want"
read -r gw gh <<<"$got"
[ "$gw" -gt "$ww" ] && [ "$gh" -eq "$wh" ] || { echo "x11-smoke: saved ${gw}x${gh}, expected wider than ${ww}x${wh} (number past the right edge)" >&2; exit 1; }
px=$(convert "$out/saved.png" -crop "1x1+$((gw - 2))+2" -format '%[hex:p{0,0}]' info:)
[ "${px:0:6}" = "2E3440" ] || { echo "x11-smoke: canvas past the image is #$px, expected #2E3440 (dark, after b)" >&2; exit 1; }
# The stairs arrow, image (350, 525) to (550, 375): its last segment runs
# along y = 375 to the head (a straight arrow is far below there).
px=$(convert "$out/saved.png" -crop "1x1+500+375" -format '%[hex:p{0,0}]' info:)
[ "${px:0:6}" = "E04B5A" ] || { echo "x11-smoke: image (500, 375) is #$px, expected #E04B5A (the red stairs arrow: \`a\`, startup style stairs)" >&2; exit 1; }
grep -qx 'canvas_bg=dark' "$out/xdg/felt/config" || { echo "x11-smoke: $out/xdg/felt/config does not say canvas_bg=dark" >&2; exit 1; }
cat "$out/log.txt"
echo "x11-smoke: OK. Look at $out/window.png (screen) and $out/saved.png (export)."
