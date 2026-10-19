# AGENTS.md — guide for AI agents working on hyprglaze

hyprglaze is a Wayland wallpaper daemon for Hyprland: it renders GLSL effects
on the background layer, and pushes live desktop state (window geometry,
focus, cursor, audio) into the shaders' uniforms. Zig 0.16, Wayland C API via
Zig, GL ES 3.0 shaders.

## Using these docs

This file is the universal entry point. Topic detail lives in `docs/agents/`;
read **only** the doc(s) your task touches, to keep context small.

| Doc | Read when |
|---|---|
| `docs/agents/build.md` | building, running, applying changes, debugging logs |
| `docs/agents/layout.md` | finding code; effect/component/SDK architecture |
| `docs/agents/conventions.md` | GL state, frame data, clocks, config reload, tests |
| `docs/agents/config.md` | config dir and shader/effect resolution (do not break) |
| `docs/agents/harness.md` | running the nested Hyprland harness / probes |
| `docs/agents/history.md` | before touching anything removed or forbidden |
| `docs/agents/new-effect.md` | adding a new effect, especially one needing a new host input/context |
| `docs/agents/acrylic.md` | acrylic: the slow 1:1 flow-ref3 port (five passes), theme ramps, window rigid bodies |
| `docs/effect-porting.md` | porting a built-in effect to a C-ABI component |

## Keeping these docs current (before every commit)

A commit must leave the docs true. In the **same commit** as any change that
alters the build/run loop, the source layout, an ABI/SDK, config or shader
resolution, the harness, or a convention, update this file and the relevant
`docs/agents/*.md`. When in doubt, grep the docs for what you touched and
refresh it. Do this **every time, before committing**.

## The one loop to always run

After any daemon/SDK/effect edit, `scripts/rebuild.sh` is the only correct way
to make it live: it builds, installs to `~/.local/bin`, prunes the stale
component cache, and restarts the daemon. A bare `zig build` leaves the
terminal `hyprglaze` stale; never stop at that. Details and debugging are in
`docs/agents/build.md`.

## Universal rules

- **Do not commit without the user's explicit approval.** Make edits and run
  the loop, but leave the working tree uncommitted until the user asks you to
  commit. When you do commit, follow the doc rule above.
- Changes are only live via `scripts/rebuild.sh`; errors surface in the captured
  daemon log (`/tmp/hyprglaze.log`), not in exit codes.
- Do not break the config/shader layout in `docs/agents/config.md`.
- Never reintroduce the removed `ai_buddy`/network/credential code paths
  (`docs/agents/history.md`).
- Porting a built-in to a component is **additive**: keep the union variant as
  the `HG_NO_PLUGINS=1` fallback (see `docs/effect-porting.md`).
