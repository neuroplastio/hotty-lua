#!/bin/sh
# The click example in hottyterm, a native host, on the private headless
# display that hotty-blitz's scripts/headless.sh starts. Not part of the gate:
#
#   make e2e        # screenshots and a log in $OUT
#
# It shows the card, clicks its button (through a virtual pointer, with a
# virtual keyboard present: without one the window gets no pointer), presses
# Ctrl-L, scrolls, and splits, taking a screenshot after each.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
HOTTYTERM=${HOTTYTERM:-$HOME/.local/opt/hottyterm/bin/hottyterm}
HOTTY_BLITZ_DIR=${HOTTY_BLITZ_DIR:-$root/../../hotty-blitz/main}
OUT=${OUT:-${TMPDIR:-/tmp}/hotty-lua-e2e}
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/hotty/sway"
WTYPE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/hotty/wtype/root"

if [ ! -s "$CACHE/display" ] || ! pgrep -x sway >/dev/null; then
	echo "no headless display: $HOTTY_BLITZ_DIR/scripts/headless.sh start" >&2
	exit 1
fi
# One user of the display at a time. -o: what runs under the lock does not
# hold it, or a sway started there would keep it.
if [ -z "${HOTTY_E2E_LOCKED:-}" ]; then
	HOTTY_E2E_LOCKED=1 exec flock -o "$CACHE/lock" "$0" "$@"
fi
mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT/e2e.log"

export WAYLAND_DISPLAY="$(cat "$CACHE/display")"
unset DISPLAY HYPRLAND_INSTANCE_SIGNATURE
export HOTTY_LUA_ROOT="$root" E2E_LOG="$OUT/e2e.log"
"$HOTTYTERM" --gtk-single-instance=false --window-decoration=false \
	-e nvim --clean -u "$here/init.lua" >"$OUT/hottyterm.log" 2>&1 &
pid=$!

# Waits for the Neovim to log a step, then for the frame it draws.
step() {
	n=0
	until grep -q "STEP $1" "$OUT/e2e.log" 2>/dev/null; do
		n=$((n + 1))
		[ $n -lt 200 ] || { echo "FAIL: no step $1" >&2; kill $pid; exit 1; }
		sleep 0.1
	done
	sleep 0.6
}

step placed
grim "$OUT/1-placed.png"
# The button: three cells in, on the card's first row, screen row 3.
cell=$(sed -n 's/.* CELL \([0-9.]*\) \([0-9.]*\)$/\1 \2/p' "$OUT/e2e.log")
x=$(echo "$cell" | awk '{ print int(3 * $1) }')
y=$(echo "$cell" | awk '{ print int(3.5 * $2) }')
# A virtual keyboard while the pointer clicks: without one, the window gets
# no pointer. Its one key, after the clicks, is Escape, which changes nothing.
if [ -x "$WTYPE_ROOT/usr/bin/wtype" ]; then
	LD_LIBRARY_PATH="$WTYPE_ROOT/usr/lib" "$WTYPE_ROOT/usr/bin/wtype" -s 4000 -k Escape &
fi
sleep 0.5
# A click on the cells first (line 10: the window takes the pointer), then
# the button.
echo "clicking at $x,$y"
python3 "$HOTTY_BLITZ_DIR/scripts/vpointer.py" 1200 750 \
	move "$x" "$(echo "$cell" | awk '{ print int(11.5 * $2) }')" sleep 0.3 click sleep 0.4 \
	move "$x" "$y" sleep 0.3 click
step clicked
grim "$OUT/2-clicked.png"
step Ctrl-L
grim "$OUT/3-ctrl-l.png"
step scrolled
grim "$OUT/4-scrolled.png"
step "split, then"
grim "$OUT/5-split.png"
step quit
kill $pid 2>/dev/null || true
wait $pid 2>/dev/null || true

cat "$OUT/e2e.log"
fail=0
grep -q 'MODE native' "$OUT/e2e.log" || { echo "FAIL: not detected native" >&2; fail=1; }
grep -q 'e = "click"' "$OUT/e2e.log" || { echo "FAIL: no click event" >&2; fail=1; }
echo "screenshots in $OUT"
exit $fail
