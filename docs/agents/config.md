# Config + shader layout (do not break)

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
- A component (`effects/<name>/effect.zig`) **wins** over a union variant of the
  same name. It is compiled on first load (cache key: ABI version, zig version,
  compile flags, effect source, SDK bytes) and driven through the C ABI. The
  host's global Io is the single-threaded, `.failing`-allocator one, so the
  compiler subprocess gets its own c_allocator/environment-backed Io.
- A component may share another effect's config section via
  `hg_module.config_section` (starfield and milkdrop read the shared
  `[visualizer]` knobs); NULL/empty means the module's `id`.
- **Current live config:** `~/.config/hypr/hyprglaze/hyprglaze.toml` sets
  `effect = "weft"` with theme `Black Blue OLED`; no explicit `shader =`
  override.
- **`black-blue.frag` design constraints** chosen by the user: OLED black
  covers ~90-95% of the screen; paint islands are *evenly* distributed
  (low-frequency subtraction equalizes coverage), dark-blue 50% / light-blue
  40% / white 10% ramp; mouse reacts only through the blob-field gate lift — no
  ring/line highlighting; window-motion interaction intentionally removed
  pending a rework with real window geometry (the `iWindowVel`/`iWindowAcc`
  uniforms are reserved for that).
- **Autostart:** Hyprland autostart (`~/.config/hypr/config/autostart.lua`,
  Lua-based config, Hyprland ≥0.55 with `hyprland.lua`) launches `hyprglaze`
  instead of `hyprpaper`; do not re-add `exec_cmd("hyprpaper")`.
