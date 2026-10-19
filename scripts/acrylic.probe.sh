# Visual probe for the acrylic effect: a theme-black particle liquid fills the
# surface, a minority of the particles are palette-coloured, and moving a
# window stirs the pool like a leaf dragged across water.
#
#   scripts/hypr-harness.sh scripts/acrylic.probe.sh
#
# HG_THEME overrides the theme; HG_SHOW=1 to watch it. Produces
# $OUT/shots/acrylic-*.png.

FX=${HG_EFFECT:-acrylic}
# Screenshots only; hidden (15fps) is enough unless watching.
[ -n "${HG_SHOW:-}" ] && show_harness
place acr-a 11 250 300 300 500
place acr-b 11 950 550 400 400
start_effect "$MON_B" fx "$FX"
move_cursor $((BX + 700)) $((BY + 150)) || true

# Colored fraction, near-black fraction and mean level, ignoring the top
# banner and the (flat, unsaturated) probe windows.
stats() { python3 - "$OUT/shots/$1.png" <<'PY'
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int); a[:48] = 0
mx = a.max(2); sat = mx - a.min(2)
colored = int(((mx > 70) & (sat > 35)).sum())
dark = float((mx < 90).mean())
mean = float(a.mean())
print(f"{colored} {dark:.3f} {mean:.2f}")
PY
}

# Mean absolute pixel difference (max channel) between two frames, skipping the
# banner. Windows sit at identical rects in both frames for the motion test.
diff() { python3 - "$OUT/shots/$1.png" "$OUT/shots/$2.png" <<'PY'
import sys, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
b = np.asarray(Image.open(sys.argv[2]).convert("RGB")).astype(int)
d = np.abs(a - b).max(2); d[:48] = 0
print(f"{d.mean():.3f} {int((d > 16).sum())}")
PY
}

# Component compilation stalls the first frames (a cold cache can take ~10s);
# give the pool time to settle before judging the render.
sleep 10
grab acrylic-rest "$MON_B"
REST=$(stats acrylic-rest); echo "  rest: $REST"
COLORED=$(echo "$REST" | cut -d' ' -f1)
DARK=$(echo "$REST" | cut -d' ' -f2)
expect "[ $COLORED -gt 400 ]" "palette-coloured liquid is drawn"
expect "[ $COLORED -lt 600000 ]" "black is the bulk of the liquid (colored < ~30% of the surface)"
expect "awk 'BEGIN{exit !($DARK > 0.6)}'" "the surface is predominantly black (>60% near-black)"

# Quiet baseline: ambient liquid motion over the same interval.
sleep 0.8
grab acrylic-quiet "$MON_B"
BASE=$(diff acrylic-rest acrylic-quiet); echo "  quiet diff: $BASE"

# Stir the pool: yank the focused window across the output and back, so both
# frames have identical window rects and any remaining difference is liquid.
E "hl.animation({ leaf = 'windows', enabled = true, speed = 5, bezier = 'linear' })" >/dev/null
E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 120)), y = $((BY + 680)), relative = false }))" >/dev/null
sleep 0.45
E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 950)), y = $((BY + 550)), relative = false }))" >/dev/null
sleep 1.2
grab acrylic-after "$MON_B"
AFTER=$(stats acrylic-after); echo "  after: $AFTER"
STIR=$(diff acrylic-rest acrylic-after); echo "  stirred diff: $STIR"

BASE_N=$(echo "$BASE" | cut -d' ' -f2)
STIR_N=$(echo "$STIR" | cut -d' ' -f2)
expect "[ $STIR_N -gt 500 ]" "the moved window left a visible wake"
expect "[ $STIR_N -gt $(( BASE_N * 3 / 2 )) ]" "the wake is larger than the ambient drift"

echo "  cpu=$(ps -o %cpu= -p $EFFECT_PID)%"
expect "kill -0 $EFFECT_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-fx.log" "no errors in the daemon log"
