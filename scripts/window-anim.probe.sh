# Does the wallpaper's idea of a window track the window through
# Hyprland's move animation? The probe shader rings the focused window in
# red 12px outside its edge; burst grabs during an animated move measure
# the ring against the window actually on screen, frame by frame.
#
#   scripts/hypr-harness.sh scripts/window-anim.probe.sh
#
# Runs once on a 1s linear bezier and once on the live session's spring
# (mirrored into hyprglaze via [transition] window_spring).
#
# Timing needs full frame rate, so it calls show_harness first: hidden,
# the host throttles the nested output to 15fps and the ~66ms frames read
# as a tracking lag that is not the daemon's.

# "x0 y0 x1 y1" of the probe window (spawn_probe forces its flat #242424
# background) and of the red ring, from one grab.
measure() { python3 - "$OUT/shots/$1.png" <<'PY'
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
a[:48] = 0   # Hyprland's red "started without start-hyprland" banner
def bbox(m):
    ys, xs = np.nonzero(m)
    return (xs.min(), ys.min(), xs.max(), ys.max()) if len(xs) else None
win = bbox((np.abs(a - [36, 36, 36]).max(axis=2) <= 6))
ring = bbox((a[..., 0] > 200) & (a[..., 1] < 60) & (a[..., 2] < 60))
if not win or not ring: print("none"); sys.exit()
# Ring's outer edge sits PAD+TH = 14px outside the window.
err = max(abs(ring[0] + 14 - win[0]), abs(ring[1] + 14 - win[1]),
          abs(ring[2] - 14 - win[2]), abs(ring[3] - 14 - win[3]))
# Signed lag along x: negative = the ring trails the window.
print(win[0], win[1], err, ring[0] + 14 - win[0])
PY
}

# "mid" while the probe window is between 400x300 and 900x700.
garea() { python3 - "$OUT/shots/$1.png" <<'PY'
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int); a[:48] = 0
ys, xs = np.nonzero(np.abs(a - [36, 36, 36]).max(axis=2) <= 6)
w = xs.max() - xs.min() + 1 if len(xs) else 0
print("mid" if 420 < w < 880 else "end")
PY
}

run_case() {   # TAG [resize]
    local tag=$1 mode=${2:-move} worst=0 n=0 moving=0 line
    spawn_probe "anim-$tag"
    wait_for "[ \"\$(hcj activewindow | jq -r .class)\" = anim-$tag ]" 10
    E "hl.dispatch(hl.dsp.window.move({ workspace = 11 }))" >/dev/null; sleep 0.5
    E "hl.dispatch(hl.dsp.window.float({ action = 'on' }))" >/dev/null; sleep 1.5
    E "hl.dispatch(hl.dsp.window.resize({ x = 400, y = 300, relative = false }))" >/dev/null; sleep 1.5
    # Resizes grow about the centre, so that case starts mid-output.
    if [ "$mode" = resize ]; then
        E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 500)), y = $((BY + 400)), relative = false }))" >/dev/null; sleep 2
    else
        E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 100)), y = $((BY + 100)), relative = false }))" >/dev/null; sleep 2
    fi
    HG_CFG="$OUT/cfg-$tag.toml" start_daemon "$MON_B" "$tag"
    sleep 1
    if [ "$mode" = resize ]; then
        E "hl.dispatch(hl.dsp.window.resize({ x = 900, y = 700, relative = false }))" >/dev/null
    else
        E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 900)), y = $((BY + 700)), relative = false }))" >/dev/null
    fi
    for i in $(seq -w 1 14); do
        grab "wa-$tag-$i" "$MON_B" >/dev/null 2>&1
        line=$(measure "wa-$tag-$i"); echo "    $tag grab $i: x y err = $line"
        [ "$line" = none ] && continue
        set -- $line; n=$((n + 1)); [ "$3" -gt "$worst" ] && worst=$3
        [ "$1" -gt 110 ] && [ "$1" -lt 890 ] && moving=$((moving + 1))
        [ "$mode" = resize ] && [ "$(garea "wa-$tag-$i")" = mid ] && moving=$((moving + 1))
    done
    echo "  $tag: $n grabs, $moving mid-flight, worst ring error ${worst}px"
    expect "[ $moving -ge 3 ]" "$tag: caught the window mid-animation"
    # The floor: a goal change lands anywhere in the watcher's 16ms tick,
    # compensated by its 8ms mean, so +-8ms of motion remains — at most
    # ~14px where this spring launches fastest, 1-5px mid-flight.
    expect "[ $worst -le 16 ]" "$tag: ring stays on the window through the animation"
    kill "$(eval echo \$DAEMON_${tag}_PID)" 2>/dev/null; sleep 0.5
    kill "${CLIENT_PIDS[-1]}"; sleep 0.5
}

base() { sed '/^\[geometry\]/,/^smoothing/d' "$OUT/cfg/hypr/hyprglaze.toml"; printf '\n[geometry]\nsmoothing = 0.0\n'; }

show_harness

# 1s linear bezier.
E "hl.animation({ leaf = 'windows', enabled = true, speed = 10, bezier = 'linear' })" >/dev/null
base > "$OUT/cfg-bez.toml"
run_case bez

# The live session's spring.
E "hl.curve('springy', { type = 'spring', mass = 1, stiffness = 71.2633, dampening = 15.8273644 })" >/dev/null
E "hl.animation({ leaf = 'windows', enabled = true, speed = 4.79, spring = 'springy' })" >/dev/null
{ base | sed 's/^\[transition\]$/[transition]\nwindow_spring = "1,71.2633,15.8273644"/'; } > "$OUT/cfg-spr.toml"
run_case spr
cp "$OUT/cfg-spr.toml" "$OUT/cfg-rsz.toml"

# The same spring on an animated resize: all four edges must track.
run_case rsz resize
