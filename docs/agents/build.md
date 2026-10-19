# Build, run, apply

Read this before building or running anything.

## Commands

```sh
zig build                              # debug
zig build -Doptimize=ReleaseSafe       # release (what the installed daemon runs)
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # installs to ~/.local/bin
zig build test                         # unit tests, no compositor needed
zig build ipc-test                     # standalone watcher diagnostic (needs Hyprland)
```

Dependencies (Arch): `zig wayland mesa libglvnd libpulse stb lua`.

## Applying a change (do this after every daemon/SDK/effect edit)

The `hyprglaze` the user runs from a terminal is `~/.local/bin/hyprglaze`, so a
change is only live once it is built, installed there, **and** the daemon is
restarted:

```sh
scripts/rebuild.sh
```

That script is the single source of truth for the loop. It:

1. `zig build -Doptimize=ReleaseSafe --prefix ~/.local` — so the PATH binary is
   the new build. A bare `zig build` leaves the terminal `hyprglaze` stale;
   never stop at that.
2. restarts the daemon detached, output captured at `/tmp/hyprglaze.log`
   (`HYPRGLAZE_LOG` to override).
3. prunes `~/.cache/hyprglaze` of the component `.so`s (and their `build/`
   dirs) that the new run did **not** load — the content-hash entries left over
   from earlier builds.

Always run it after an edit rather than restarting by hand, so the installed
binary, the running daemon, and the compile cache stay consistent. Logs are the
only error surface (shader-compile and plugin-compile failures land in
`/tmp/hyprglaze.log`); with `-fstrip` a plugin crash has no symbols — rebuild
without it to debug. Do not invoke `/usr/bin/hyprglaze` directly (an older
packaged binary); PATH already prefers `~/.local/bin`.

## Debugging a component

A component is compiled on first load (a `zig` subprocess), so the first frames
after a cold load are stalled while it builds and screenshots taken then show
the compositor background. Run again to reuse the cache before judging timing.
Component compile/discovery code is `src/core/plugin.zig`.
