#!/bin/sh
# scripts/rebuild.sh — rebuild, install the terminal `hyprglaze`, restart the
# daemon, and prune the component compile cache of everything the new build
# superseded.
#
# This is the canonical "I changed the daemon/SDK" loop:
#   1. `zig build -Doptimize=ReleaseSafe --prefix ~/.local` so the `hyprglaze`
#      on PATH (~/.local/bin) is the new binary.
#   2. restart the daemon detached, logging to HYPRGLAZE_LOG.
#   3. delete cached component `.so`s (and their build dirs) that this run did
#      not load — old content-hash entries left behind by earlier builds.
#
# Usage:  scripts/rebuild.sh
# Env:    PREFIX         install prefix              (default: ~/.local)
#         HYPRGLAZE_LOG  daemon log path             (default: /tmp/hyprglaze.log)
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix=${PREFIX:-$HOME/.local}
log=${HYPRGLAZE_LOG:-/tmp/hyprglaze.log}
cache=${XDG_CACHE_HOME:-$HOME/.cache}/hyprglaze
bin=$prefix/bin/hyprglaze

cd "$repo"

echo "==> building + installing to $prefix"
zig build -Doptimize=ReleaseSafe --prefix "$prefix"

case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "warning: $prefix/bin is not in PATH — add it so \`hyprglaze\` resolves" >&2 ;;
esac

# Transient partial outputs from an interrupted compile never get loaded.
rm -f "$cache"/*.tmp.so

echo "==> restarting the daemon ($bin)"
pkill -x hyprglaze 2>/dev/null || true
sleep 0.5
# Truncate the log at launch so the load check below reads this run only.
: >"$log"
setsid "$bin" >>"$log" 2>&1 </dev/null &

# Wait for the configured effect to load (a first-time compile of a heavy
# component can take a few seconds) or for a built-in to reach the loop.
i=0
while [ "$i" -lt 120 ]; do
    if grep -q "loaded plugin" "$log" 2>/dev/null; then break; fi
    if grep -q "entering render loop" "$log" 2>/dev/null; then break; fi
    if grep -qiE "error|panic" "$log" 2>/dev/null; then break; fi
    sleep 0.5
    i=$((i + 1))
done

# Keep only the component .so files this run loaded (and their build dirs).
# Anything else is a superseded hash. With no plugin loaded (built-in effect,
# or plugins disabled) there is nothing to prune against, so leave it alone.
keep=$(mktemp)
sed -n 's/.*loaded plugin \([^ ]*\.so\).*/\1/p' "$log" | sed 's#.*/##' | sort -u >"$keep"

if [ -s "$keep" ]; then
    pruned=0
    for f in "$cache"/*.so; do
        [ -e "$f" ] || continue
        if ! grep -qxF "$(basename "$f")" "$keep"; then
            rm -f "$f"
            pruned=$((pruned + 1))
        fi
    done
    for d in "$cache"/build/*/; do
        [ -e "$d" ] || continue
        if ! grep -qxF "$(basename "$d").so" "$keep"; then
            rm -rf "$d"
            pruned=$((pruned + 1))
        fi
    done
    echo "==> pruned $pruned stale cache entr(y|ies)"
else
    echo "==> no plugin loaded; cache left untouched"
fi
rm -f "$keep"

if pgrep -x hyprglaze >/dev/null 2>&1; then
    echo "==> running (pid $(pgrep -x hyprglaze | tr '\n' ' ')); log: $log"
else
    echo "==> daemon is NOT running — see $log" >&2
    exit 1
fi
