# Nested Hyprland harness

Drives hyprglaze inside a nested, two-output Hyprland so multi-monitor and
compositor behavior can be tested on a one-display machine. Hyprland (not sway)
because hyprglaze installs `src/core/watcher.lua` into Hyprland's Lua VM.

```sh
zig build                              # the harness runs ./zig-out/bin/hyprglaze
scripts/harness-host-rule.sh           # once per host session — see below
scripts/hypr-harness.sh scripts/window-anim.probe.sh [/tmp/out-dir]
```

The harness never drives the host session (no input injection; every mutating
`hyprctl` carries `-i "$NESTED_SIG"`). Full hard-won constraints are in the
header comment of `scripts/hypr-harness.sh`.

## Prerequisite: the host `nested-aq` window rule

The nested outputs are backed by **host** windows of class `aquamarine`. If the
host tiling WM resizes them, `MON_B` comes back too small and the run dies with
`MON_B came back WxH, too small for the probe geometry`. Float + `no_anim` on
that class fixes it. Apply it at runtime — **once per host session**, never
persisted to the user's config:

```sh
scripts/harness-host-rule.sh
```

The script uses `hyprctl eval` for the Lua parser, falling back to
`hyprctl keyword windowrulev2` for a legacy parser. It is deliberately
runtime-only: a host restart forgets it. The harness does **not** apply it
itself, because that would mean driving the host session.

## Probe client

`place`/`spawn_probe` launch a bare Wayland client as the "window under test".
`kitty` is preferred (the repo tests against it), `foot` is a fallback; set
`HG_CLIENT` to force one. The client is forced to a flat `#242424` background
with no decorations or padding, because `window-anim.probe.sh` locates the
window by that exact colour and the geometry probes assume the coloured rect is
the window rect.

## Sourced probe contract

A probe body is `.`-sourced by the harness and gets: `$OUT`, `$NESTED_SIG`,
`$NESTED_WL`, `$MON_A`/`$MON_B` (do not hardcode names), `$AW..$BY`, and the
helpers `hc`/`hcj` (nested hyprctl), `E` (nested eval), `start_daemon`,
`start_effect`, `place`, `spawn_probe`, `grab`/`shot`, `show_harness`, `scan`,
`ring_of`, `move_cursor`, `expect`, `wait_for`. `wait_for` timing out ends the
run on purpose.

Common shape (see `scripts/window-anim.probe.sh`, `*.test.sh`):

```sh
FX=${HG_EFFECT:?set HG_EFFECT}
start_effect "$MON_B" fx "$FX"
move_cursor $(( BX + BW / 2 )) $(( BY + BH / 2 ))
for i in $(seq 1 4); do grab "$FX-$i" "$MON_B"; sleep 1; done
expect "grep -q 'entering render loop' $OUT/hyprglaze-fx.log" "render loop"
```

A component's first run compiles it (a `zig` subprocess), stalling the first
frames — run twice, or wait, before judging screenshots.
