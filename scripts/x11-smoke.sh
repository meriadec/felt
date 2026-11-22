#!/usr/bin/env bash
# X11 smoke test on a real display (needs DISPLAY, xdotool, ImageMagick `import`).
# Opens annotate on a copy of the fixture, draws an arrow, two numbers and a
# text with xdotool, captures the window, saves with Ctrl+S, quits with Esc,
# then checks the saved PNG. Run through `zig build smoke-x11`.
# Takes about 3 s and grabs the pointer and the screen meanwhile.
set -euo pipefail
bin=${1:-zig-out/bin/annotate}
out=test-out/x11-smoke
mkdir -p "$out"
rm -f "$out"/*.png "$out"/log.txt

for tool in xdotool import identify; do
  command -v "$tool" >/dev/null || { echo "x11-smoke: $tool not found" >&2; exit 2; }
done
[ -n "${DISPLAY:-}" ] || { echo "x11-smoke: DISPLAY is not set (try DISPLAY=:0)" >&2; exit 2; }

cp tests/fixtures/screenshot.png "$out/input.png"
"$bin" --timing -o "$out/saved.png" "$out/input.png" 2>"$out/log.txt" &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT

wid=
for _ in $(seq 50); do
  wid=$(xdotool search --class '^annotate$' 2>/dev/null | head -1) && [ -n "$wid" ] && break
  sleep 0.1
done
[ -n "$wid" ] || { echo "x11-smoke: no annotate window after 5 s" >&2; cat "$out/log.txt" >&2; exit 1; }
sleep 0.3
eval "$(xdotool getwindowgeometry --shell "$wid")"
cx=$((X + WIDTH / 2)); cy=$((Y + HEIGHT / 2))

xdotool mousemove --sync $((cx - 250)) $((cy + 150)) mousedown 1
for i in 1 2 3 4 5; do xdotool mousemove $((cx - 250 + i * 40)) $((cy + 150 - i * 30)); sleep 0.02; done
xdotool mouseup 1
xdotool key n mousemove $((cx + 100)) $((cy - 100)) click 1 mousemove $((cx + 200)) $((cy - 100)) click 1
xdotool key t mousemove $((cx - 250)) $((cy + 200)) click 1
xdotool type --delay 5 "x11 smoke"
xdotool key Return
sleep 0.3
import -window "$wid" "$out/window.png"
xdotool key ctrl+s
sleep 0.5
xdotool key Escape
for _ in $(seq 30); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
if kill -0 $pid 2>/dev/null; then echo "x11-smoke: annotate did not quit on Esc after save" >&2; exit 1; fi
trap - EXIT

[ -f "$out/saved.png" ] || { echo "x11-smoke: Ctrl+S wrote nothing" >&2; exit 1; }
want=$(identify -format '%wx%h' "$out/input.png")
got=$(identify -format '%wx%h' "$out/saved.png")
[ "$want" = "$got" ] || { echo "x11-smoke: saved $got, expected $want" >&2; exit 1; }
cat "$out/log.txt"
echo "x11-smoke: OK. Look at $out/window.png (screen) and $out/saved.png (export)."
