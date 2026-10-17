# AGENTS.md — guide for AI agents working on hyprglaze

hyprglaze is a Wayland wallpaper daemon for Hyprland: it renders GLSL effects
on the background layer, and pushes live desktop state (window geometry,
focus, cursor, audio) into the shaders' uniforms. Zig 0.16, Wayland C API via
Zig, GL ES 3.0 shaders.

## Build & run

```sh
zig build                              # debug
zig build -Doptimize=ReleaseSafe       # release (what the installed daemon runs)
zig build -Doptimize=ReleaseSafe --prefix ~/.local   # installs to ~/.local/bin
zig build test                         # unit tests, no compositor needed
zig build ipc-test                     # standalone watcher diagnostic (needs Hyprland)
```

Dependencies (Arch): `zig wayland mesa libglvnd libpulse stb lua`.

To reload after a build: `pkill hyprglaze; setsid ~/.local/bin/hyprglaze &>/tmp/hg.log < /dev/null &`
Run it detached with output captured — shader compile errors land in that log.

## Layout

- `src/main.zig` — daemon entry: config load, Hyprland IPC, per-frame loop
  (window animation replay, effect update, render, swap, rebuild paths).
- `src/core/`
  - `shader.zig` — program compile + the standard uniform push
    (`FrameUniforms` → `draw`). Custom uniforms `iWindowVel`/`iWindowAcc`
    live here; a shader that doesn't declare them costs nothing (loc -1).
  - `transition.zig` — focus debouncing, smoothed current window/cursor, and
    the focused window's velocity/acceleration estimate (smoothed, reset on
    focus commit).
  - `wayland.zig`/`egl.zig` — layer-shell surface, EGL context, rebuild on
    output loss. `watcher.zig`/`watcher.lua` — the Lua chunk installed inside
    Hyprland's config VM; pushes `custom>>hg:*` socket2 events.
  - `window_anim.zig` — replays Hyprland's own `windowsMove` curve so window
    rects track animations (Hyprland only reports the goal rect).
  - `config.zig` — TOML parse; `strip.zig` — derived window state.
- `src/effects.zig` — the `Effect` union; every built-in effect registers here.
  `initContext`/`paramSection`/`cliName`/`shaderOf` derive everything (CLI
  name, config section, default shader path) from the union via comptime
  reflection — new built-ins need no registration beyond adding the variant.
  A component effect (`effects/<name>/`) is preferred over a union variant of
  the same name.
- `src/effects/<name>/` — built-in effect contexts: `context.zig` (state +
  init/update/upload/deinit), split into helper files when large.
- `src/core/plugin.zig` — the component-effect host: discovery, compile-on-load
  (cache under `~/.cache/hyprglaze/`), `dlopen`, ABI check, and the `Instance`
  wrapper that bridges `FrameState` to the C ABI.
- `src/core/frame.zig` — `FrameState`/`WindowInfo`, split out of `effects.zig`
  so the plugin host can name them without an import cycle.
- `sdk/include/hg_plugin.h` + `sdk/hg.zig` — the effect ABI and Zig helpers.
  `sdk/hg_audio.zig` — pure audio analysis over `hg_frame.wave`: the FFT band
  splitter (`magnitudes`/`Bands`), the kick detector (`Onset`), the waveform-fed
  `Analyzer`, and the older time-domain `Splitter`. It is the single source of
  truth for the numbers: `src/effects/spectral.zig` and `src/effects/bands.zig`
  are now thin host shims re-exporting it (spectral adds the capture-owning
  `Analyzer`), and components use it as `hg.audio` (`hg.zig` re-exports the
  file). `plugin.zig` stages every entry in `sdk_modules` next to the component
  source and folds them into the cache key, so a component may `@import`
  `hg.zig`/`hg_audio.zig`; add new SDK `.zig` files to that list.
- `effects/<name>/` — a component effect: `effect.zig` (exports
  `hg_module_entry`) plus its shader (`<name>.frag`). Installed to
  `/usr/share/hyprglaze/effects/`. A component takes audio from the host —
  it never opens its own capture; set `wants_audio = 1` and read
  `hg_frame.wave` through `hg.audio.Analyzer`. `weft` (no audio need beyond the
  raw waveform) and `crystal` (FFT bands + kicks) are the two worked examples.
- `shaders/<name>.frag` — one frag per built-in, GLSL ES 3.0, Shadertoy-style
  uniforms. See the README's Shader Uniforms table for the exact list. At
  runtime these are resolved from the installed tree
  `/usr/share/hyprglaze/shaders/` (see below), not from the repo CWD.
- `protocols/*.xml` — wayland-scanned at build time.
- `scripts/hypr-harness.sh` + `scripts/*.test.sh`/`*.probe.sh` — nested
  Hyprland integration harness (`zig build` first). Coordinates/behavior
  assertions; screenshots are readouts because the probe frag draws rings.
- `tools/` — harness support files.
- `src/data/themes.json` — 365 Gogh schemes, palette pushed as uniforms.

## Conventions

- GL state rules: effect `init()` must not touch GL (no current context
  guaranteed); create GL objects on first `upload`, delete in `deinit`.
  `deinit` must release everything, including background threads.
- `FrameState` slices are valid only during `update`; copy what an effect
  keeps. Also note the union update/setup contract in `effects.zig`.
- Clocks: accumulate in `f64`; `f32` seconds stall after ~a day. Errors
  surface as logs — check the daemon's captured output, not exit codes.
- Config is hot-reloaded via inotify (watcher reinstalls itself after each
  reload, which recreates Hyprland's Lua VM).
- Tests use `std.testing`; parser/transform coverage is high — add tests for
  pure logic, probes for compositor behavior.

## Config + shader layout (do not break)

- The config directory is `~/.config/hypr/hyprglaze/`, holding
  `hyprglaze.toml` only. Shaders, effects and the SDK live under the packaged
  `/usr/share/hyprglaze/` (`iohelp.system_data_dir`). The old flat
  `~/.config/hypr/hyprglaze.toml` is no longer read (new-dir-only); the
  helpers live in `config.zig` (`configDir`/`defaultConfigPath`/
  `resolveShaderPath`). `resolveShaderPath` resolves `~`, absolute paths, and
  everything else relative to `/usr/share/hyprglaze/shaders`.
- `/usr/share/hyprglaze/` holds `shaders/`, `effects/`, and `sdk/`; in a dev
  tree each is a symlink to the repo. All effect shaders are read from
  `shaders/` *on demand*: `--list-effects` and startup recursively walk it
  (`effects.zig` `listEffects`/`scanFrags`), so any `.frag` at any depth is
  selectable as `effect = "<subdir>/<frag-stem>"` (or the bare stem at top
  level).
- Effects whose name matches an `Effect` union variant build that Zig context;
  any other name runs on the shared stateless context (like liquid2).
  `liquid2` maps to `customs/liquid2.frag`; custom shaders read the theme
  palette via the standard `iPalette`/`iPaletteBg`/`iPaletteFg` uniforms, with
  fixed-color fallbacks built in for `theme` being unset.
- A component (`effects/<name>/effect.zig`) wins over a union variant of the
  same name. It is compiled on first load (cache key: ABI version, zig version,
  compile flags, effect source, SDK bytes) and driven through the C ABI. The
  host's global Io is the single-threaded, `.failing`-allocator one, so the
  compiler subprocess gets its own c_allocator/environment-backed Io.
- `~/.config/hypr/hyprglaze/hyprglaze.toml` currently sets `effect = "weft"`
  with theme `Black Blue OLED`; no explicit `shader =` override.
- `black-blue.frag` design constraints chosen by the user: OLED black covers
  ~90-95% of the screen; paint islands are *evenly* distributed (low-frequency
  subtraction equalizes coverage), dark-blue 50% / light-blue 40% / white 10%
  ramp; mouse reacts only through the blob-field gate lift — no ring/line
  highlighting; window-motion interaction intentionally removed pending a
  rework with real window geometry (the `iWindowVel`/`iWindowAcc` uniforms are
  reserved for that).
- Hyprland autostart (`~/.config/hypr/config/autostart.lua`, Lua-based config,
  Hyprland ≥0.55 with `hyprland.lua`) launches `hyprglaze` instead of
  `hyprpaper`; do not re-add `exec_cmd("hyprpaper")`.

## History note

The upstream `ai_buddy` effect (Claude Haiku on AWS Bedrock, shelling out to
the `aws` CLI) was deliberately removed at the user's request — do not
reintroduce it or any network/credential-dependent code path. Remaining
subprocess use: `popen("pactl get-default-sink …")` for audio sink detection
only.
