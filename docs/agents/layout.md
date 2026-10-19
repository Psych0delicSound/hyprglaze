# Source layout

Read the parts your task touches; the effect/component/SDK architecture is
below.

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
  file).
  `sdk/hg_gl.zig` — GL helpers for heavy effects that render their own offscreen
  pass: `Program` (fullscreen-triangle VAO + the standard
  `iResolution`/`iWindows`/`iPalette*` uniforms) and `Target` (colour texture +
  framebuffer, created/freed as one; two of them is a feedback ping-pong). Both
  are built lazily in `upload`.
  `sdk/hg_geometry.zig` — the shared CPU→GL painter (`Batch`/`Painter`,
  `Points`/`PointPainter`); `src/effects/geometry.zig` is a re-export shim so
  built-ins and components share one copy.
  `sdk/hg_clock.zig` — the shared f64 effect clock (`phase`/`cycles`);
  `src/effects/clock.zig` is a re-export shim, so built-ins and components turn
  a long clock into exact f32 oscillator arguments through one copy.
  `plugin.zig` stages every `.zig` file in a component directory (multi-file
  components are supported — see swarm) plus every entry in `sdk_modules` (add
  new SDK `.zig` files there) and folds them into the cache key, so a component
  may `@import("hg.zig")`/`hg_audio.zig`/`hg_gl.zig`/`hg_geometry.zig`/`hg_clock.zig`.
- `effects/<name>/` — a component effect: `effect.zig` (exports
  `hg_module_entry`) plus its shader (`<name>.frag`). Installed to
  `/usr/share/hyprglaze/effects/`. A component takes audio from the host —
  it never opens its own capture; set `wants_audio = 1` and read
  `hg_frame.wave` through `hg.audio.Analyzer`. `weft`, `crystal`, `swarm`
  (multi-file), `glitch`, `starfield`, `milkdrop`, `laser`, `particles`,
  `acrylic` (GPU flow field + flow-shaped bands) and `acrylic2` (a 1:1 port
  of the `flow-ref3` Shadertoy: five chained buffers, window rigid bodies,
  theme-coloured) are the worked examples;
  see `docs/effect-porting.md` for the per-effect port recipe.
- `shaders/<name>.frag` — one frag per built-in, GLSL ES 3.0, Shadertoy-style
  uniforms. See the README's Shader Uniforms table for the exact list. At
  runtime these are resolved from the installed tree
  `/usr/share/hyprglaze/shaders/` (see `docs/agents/config.md`), not from the
  repo CWD.
- `protocols/*.xml` — wayland-scanned at build time.
- `scripts/hypr-harness.sh` + `scripts/*.test.sh`/`*.probe.sh` — nested
  Hyprland integration harness (`zig build` first). Coordinates/behavior
  assertions; screenshots are readouts. See `docs/agents/harness.md`.
- `tools/` — harness support files.
- `src/data/themes.json` — 365 Gogh schemes, palette pushed as uniforms.
