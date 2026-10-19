#!/bin/sh
# Apply the host-side window rule the nested harness needs — RUNTIME ONLY.
#
#   scripts/harness-host-rule.sh
#
# The harness boots a nested Hyprland as a client of the *host* session, and
# its nested outputs are host windows of class "aquamarine". If the host tiling
# WM resizes them, MON_B comes back too small and the run dies with "MON_B came
# back ...x..., too small for the probe geometry". Floats + no_anim on that
# class fixes it. See docs/agents/harness.md.
#
# This is deliberately runtime-only and separate from the harness: applying it
# mutates the host session, which the harness itself promises never to do.
# Nothing is written to the user's config, so a host restart forgets it —
# re-run this once per host session before the first harness run.
#
# Hyprland's Lua config parser rejects `hyprctl keyword` ("use eval"); a legacy
# (hyprlang) setup takes the windowrulev2 keyword. Both are attempted.
set -eu

lua_rule='hl.window_rule({ name = "nested-aq", match = { class = "^aquamarine$" }, float = true, no_anim = true })'

if hyprctl eval "$lua_rule" >/dev/null 2>&1; then
    echo "harness host rule applied (runtime, Lua parser): nested-aq float+no_anim"
    exit 0
fi

if hyprctl keyword windowrulev2 "float,class:^(aquamarine)$" >/dev/null 2>&1; then
    hyprctl keyword windowrulev2 "noanim,class:^(aquamarine)$" >/dev/null 2>&1 || true
    echo "harness host rule applied (runtime, legacy parser): nested-aq float+no_anim"
    exit 0
fi

echo "could not apply the harness host rule." >&2
echo "Add this to your host config, then re-run:" >&2
echo "  hl.window_rule({ name = \"nested-aq\", match = { class = \"^aquamarine\$\" }, float = true, no_anim = true })" >&2
exit 1
