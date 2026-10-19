# What does a window's Lua `at`/`size` report while Hyprland animates it:
# the animated (rendered) value, or the goal? Samples every timer tick
# across an animated move and resize, and `hyprctl clients` alongside.
#
# Finding on 0.56.x: both report the GOAL — `at` jumps to the destination
# on the first tick while the window animates there — and the Lua object
# exposes no animated key (`__index` is a C function; see the key probes).
# That is why src/core/window_anim.zig replays the curve itself.
#
#   scripts/hypr-harness.sh scripts/geom-anim.probe.sh

E "hl.animation({ leaf = 'windows', enabled = true, speed = 10, bezier = 'linear' })" >/dev/null
spawn_probe anim-x
wait_for "hcj clients | jq -e '.[]|select(.class==\"anim-x\")' >/dev/null" 15
wait_for "[ \"\$(hcj activewindow | jq -r .class)\" = anim-x ]" 10
E "hl.dispatch(hl.dsp.window.float({ action = 'on' }))" >/dev/null; sleep 1.5
E "hl.dispatch(hl.dsp.window.resize({ x = 400, y = 300, relative = false }))" >/dev/null; sleep 1.5
E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 100)), y = $((BY + 100)), relative = false }))" >/dev/null; sleep 1.5

LOG="$OUT/anim-samples.txt"
E "
local f = io.open('$LOG', 'w')
local function win()
  for _, w in ipairs(hl.get_windows({ mapped = true })) do
    if w.class == 'anim-x' then return w end
  end
end
local w = win()
local mt = getmetatable(w)
f:write('meta=', tostring(mt), '\n')
for k, v in pairs(mt) do f:write('mt ', tostring(k), '=', tostring(v), '\n') end
if type(mt.__index) == 'table' then
  for k, v in pairs(mt.__index) do f:write('idx ', tostring(k), '=', tostring(v), '\n') end
end
local ok, err = pcall(function()
  for k, v in pairs(w) do f:write('pair ', tostring(k), '=', tostring(v), '\n') end
end)
f:write('pairs ok=', tostring(ok), ' ', tostring(err), '\n')
for _, k in ipairs({ 'at', 'size', 'real_position', 'real_size', 'position', 'goal',
                     'render_at', 'animated_at', 'real_at', 'x', 'y', 'w', 'h', 'box' }) do
  local ok2, v = pcall(function() return w[k] end)
  local s = tostring(v)
  if ok2 and type(v) == 'table' or type(v) == 'userdata' then
    local ok3, xy = pcall(function() return v.x .. ',' .. v.y end)
    if ok3 then s = s .. ' (' .. xy .. ')' end
  end
  f:write('key ', k, ' ok=', tostring(ok2), ' v=', s, '\n')
end
f:flush()
local n = 0
local t0 = os.clock()
__probe_t = hl.timer(function()
  n = n + 1
  local w2 = win()
  if w2 then
    f:write(string.format('tick %d at=%.1f,%.1f size=%.1f,%.1f\n', n, w2.at.x, w2.at.y, w2.size.x, w2.size.y))
  end
  if n == 8 then hl.dispatch(hl.dsp.window.move({ x = $((BX + 700)), y = $((BY + 500)), relative = false })) end
  if n == 90 then hl.dispatch(hl.dsp.window.resize({ x = 800, y = 600, relative = false })) end
  if n >= 170 then f:close(); __probe_t:set_enabled(false) end
end, { timeout = 16, type = 'repeat' })
" 
for i in $(seq 1 12); do
  sleep 0.08; hcj clients | jq -r '.[]|select(.class=="anim-x")|"hyprctl at=\(.at) size=\(.size)"' >> "$OUT/hyprctl-samples.txt"
done
sleep 3
grep -v '^tick' "$LOG"; grep '^tick' "$LOG" | sed -n '6,14p'
cat "$OUT/hyprctl-samples.txt"
