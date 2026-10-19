# Effect porting plan — built-ins → C-ABI components

The host can run any built-in either as a **union variant** (`src/effects/<name>.zig`
or `src/effects/<name>/context.zig`, compiled into the daemon) or as a
**component** (`effects/<name>/`, compiled on load through the `hg_module`
ABI). This file tracks the migration. A component *wins* over a union variant
of the same name, so porting is always additive: the union variant stays as a
`HG_NO_PLUGINS=1` / build-time fallback until Phase 4 removes it.

## Status

| Effect | State | Notes |
|---|---|---|
| weft | ✅ component | raw waveform |
| crystal | ✅ component | FFT bands + kicks |
| visualizer | ✅ component | waveform → `iParticles` |
| swarm | ✅ component | boids + offscreen compute pass; multi-file |
| tide | ⬜ | no audio; simple |
| concentric | ⬜ | no audio; simple |
| fire | ⬜ | time-domain bands |
| windowglow | ⬜ | spectral |
| fur | ⬜ | spectral |
| fluid | ⬜ | spectral |
| whorl | ⬜ | spectral (origin of `spectral.zig`) |
| amorphous | ⬜ | spectral + palette + RNG |
| flux | ⬜ | spectral + bands |
| cellbloom | ⬜ | spectral + bands + clock |
| ivy | ⬜ | spectral + bands + clock; largest (1445 lines) |
| voltaic | ⬜ | raw waveform + bands + clock |
| moire | ⬜ | raw waveform + bands |
| particles | ✅ component | ball/contact solver (`system.zig`) copied locally + palette; no audio |
| laser | ✅ component | ray solver (`trace.zig`) + f64 `clock.zig` copied locally + spectral (bands + kicks) + palette via the host's standard uniforms |
| starfield | ✅ component | FBO (`hg_gl.Target`) + `hg_geometry` painter + spectral + palette; `.config_section = "visualizer"` |
| glitch | ✅ component | own program + FBO (via `hg_gl.Target`) + spectral + RNG |
| milkdrop | ✅ component | ping-pong `hg_gl.Target` feedback + warp `hg_gl.Program` + `hg_geometry` + copied `presets.zig` + spectral + palette; `.config_section = "visualizer"` |
| liquid2 / `custom` | n/a | already the stateless fallback context; not ported |

Audio flavour of the pending set (what the component must feed its analyzer):
* **raw waveform** (`hg_frame.wave` → `hg.audio.Splitter`): voltaic, moire.
* **spectral** (`hg.audio.Analyzer` FFT bands + kicks): windowglow, fur, fluid,
  whorl, amorphous, flux, cellbloom, ivy.
* **none**: tide, concentric.

## The standard port recipe

1. `mkdir effects/<name>`; `git mv shaders/<name>.frag effects/<name>/<name>.frag`.
2. Copy the context to `effects/<name>/effect.zig` and convert it:
   * `create(host, w, h)` reads params via `hg.Host` (section = effect name, see
     the caveat below). No GL here.
   * `update(self, frame)` maps `hg_frame` fields onto the old `FrameState`
     fields (they are 1:1). **Copy** anything kept past the call — frame
     pointers die at return.
   * `upload(self, program)` sets the effect's uniforms via `hg.Uniforms`; the
     host pushes the standard uniforms on `program` itself.
   * `destroy(self)` releases everything (`hg.allocator.destroy`, GL names).
   * set `wants_audio` if the effect reads the waveform.
3. Split helper files into `effects/<name>/` and fix `@import` paths (the
   compiler stages and hashes **every** `.zig` in the directory).
4. `zig build && zig build test`; `zig build -Doptimize=ReleaseSafe --prefix ~/.local`;
   run `~/.local/bin/hyprglaze --effect <name> --fps` and watch `/tmp/hg.log`.
5. Check the fallback: `HG_NO_PLUGINS=1 ~/.local/bin/hyprglaze --effect <name>`
   (uses the union variant + the component's absolute frag path).

## Unique context features (what the ABI/SDK does not yet express)

These are the real porting prerequisites — everything else is mechanical.
Items 1–3 are **done**; 4–7 are per-port notes, not ABI work.

1. **Shared config section.** ✅ `hg_module.config_section` (`const char*`,
   NULL/empty ⇒ `id`) landed alongside `HG_ABI_VERSION 2`. `Instance.maybeCreate`
   reads params and the host-side `music`/`sink` audio flags from that section,
   so `starfield`/`milkdrop` set `.config_section = "visualizer"`.

2. **Own offscreen / feedback pass.** ✅ `hg_gl.Target` (RGBA8/RGBA16F colour
   texture + FBO, resize, `begin`/`end`, optional mipmaps, `deinit`) landed in
   `sdk/hg_gl.zig`; `glitch` uses it for its ping-pong feedback targets and
   `milkdrop` for its feedback ping-pong (two targets). swarm
   still does this by hand and can migrate later.

3. **Shared CPU→GL painter.** ✅ moved to `sdk/hg_geometry.zig` (in
   `sdk_modules`); `src/effects/geometry.zig` is now a re-export shim so the
   built-ins and the `milkdrop`/`starfield` components share one copy.

4. **Self-contained solvers/tables to copy locally.**
   * `particles/system.zig` (556 lines) — the full ball/pop/collider solver;
     copied into `effects/particles/`.
   * `laser/trace.zig` (169 lines) — ray-vs-AABB reflection; copied into
     `effects/laser/`.
   * `milkdrop/presets.zig` (507 lines) — embedded per-frame preset equations;
     `milkdrop` only (copied into the component).
   * `clock.zig` (23 lines) — `phase`/`cycles`; ✅ promoted to the SDK as
     `sdk/hg_clock.zig` (staged by the loader; `src/effects/clock.zig` is a
     re-export shim). No longer copied per component.

5. **RNG seeded from the wall clock.** `amorphous`, `glitch`, `milkdrop`,
   `starfield` seed `std.Random.DefaultPrng` from `iohelp.nowNs()`. Plugins can
   call `std.c.clock_gettime` (or seed from `hg_frame.time`); no SDK change
   needed, just replace the import.

6. **Theme palette as colours.** `milkdrop` walks chromatic slots (`hue`),
   `laser`/`starfield`/`amorphous`/`particles` read specific slots/BG/FG. This
   is already exposed as `hg_frame.palette` / `palette_len` / `palette_bg` /
   `palette_fg`; nothing to build.

7. **Conventions to preserve (not features).** A component's `upload` runs
   before the host's main draw, so it must leave GL state the host expects
   (notably blend off). GL objects are created lazily in `upload` and freed in
   `destroy`; `create` must not touch GL. `destroy` runs with the creating
   context still current.

## Remaining ABI gaps

None. `config_section` (item 1) landed with `HG_ABI_VERSION 2`; `hg_gl.Target`
(item 2) and `hg_geometry.zig` (item 3) are SDK-local and in place. The rest of
the pending ports are mechanical transliteration plus their local solvers.

## Suggested order

1. Cheap wins, no new capabilities — validates the recipe across flavours:
   `tide`, `concentric`, `fire`, `windowglow`, `fur`, `fluid`, `whorl`.
2. Audio + clock: `amorphous`, `flux`, `cellbloom`, `voltaic`, `moire`, `ivy`.
3. ✅ `hg_gl.Target` (item 2) + `glitch`.
4. ✅ `config_section` (item 1) + `hg_geometry.zig` (item 3) + `hg_clock.zig`
   moved to the SDK, and `starfield`, `milkdrop`, `laser` then `particles`
   ported on top. Every SDK-dependent built-in now has a component; what
   remains is the mechanical set (steps 1–2).
5. **Phase 4** once every current built-in has a component: delete the union
   variants, `shaderOf`, `defaultShaderFor`, and the `custom` fallback plumbing
   (or keep a slim stateless path only for user `<subdir>/<frag>.frag` shaders).

## Verification checklist (per port)

* `zig build` + `zig build test` clean.
* `--list-effects` shows the name as a component (listed first).
* Cold load compiles and logs `compiled` → `loaded`; warm load reuses the cache.
* Runs in the render loop at the expected FPS with audio active.
* `HG_NO_PLUGINS=1` still renders via the union fallback.
