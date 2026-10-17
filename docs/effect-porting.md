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
| particles | ⬜ | particle solver + palette |
| laser | ⬜ | ray tracer + palette + clock + spectral |
| starfield | ⬜ | FBO + geometry painter + spectral + palette; shared `[visualizer]` section |
| glitch | ⬜ | own program + FBO + spectral + RNG |
| milkdrop | ⬜ | FBO feedback + geometry + presets + spectral + palette; shared `[visualizer]` section |
| liquid2 / `custom` | n/a | already the stateless fallback context; not ported |

Audio flavour of the pending set (what the component must feed its analyzer):
* **raw waveform** (`hg_frame.wave` → `hg.audio.Splitter`): voltaic, moire.
* **spectral** (`hg.audio.Analyzer` FFT bands + kicks): windowglow, fur, fluid,
  whorl, amorphous, flux, cellbloom, ivy, laser, starfield, glitch, milkdrop.
* **none**: tide, concentric, particles.

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

1. **Shared config section.** `paramSection()` makes `starfield` and `milkdrop`
   read the shared `[visualizer]` section, not their own. The component host
   currently keys params (and the host-side `music`/`sink` audio lookup) on the
   effect name, so a naive port would read `[starfield]`/`[milkdrop]` and lose
   its audio settings.
   *Fix:* add `const char* config_section` to `hg_module` (NULL ⇒ use `id`) and
   have `Instance.maybeCreate` use it for both the params ctx and the audio
   flags. Bump `HG_ABI_VERSION`.

2. **Own offscreen / feedback pass.** `glitch`, `milkdrop`, `starfield`
   (and now swarm) render an extra pass into an FBO and hand the texture to the
   main shader. `hg_gl.Program` covers the *program*; the FBO + colour texture +
   resize + ping-pong lifecycle is still per-effect.
   *Fix (optional):* add `hg_gl.Target` (create/resize/bind texture + FBO,
   `deinit`) to `sdk/hg_gl.zig`. swarm currently does this by hand and can be
   migrated onto it later.

3. **Shared CPU→GL painter.** `src/effects/geometry.zig` (346 lines: faded
   lines, dots, filled polygons, frames, built into a CPU `Batch` and drawn by a
   `Painter` with additive/alpha blending) is shared by `milkdrop` and
   `starfield`.
   *Fix:* move it to `sdk/hg_geometry.zig` (add to `sdk_modules`) so both
   components import one copy, or duplicate it per component if the SDK should
   stay shader-only.

4. **Self-contained solvers/tables to copy locally.**
   * `particles/system.zig` (556 lines) — the full ball/pop/collider solver;
     `particles` only.
   * `laser/trace.zig` (169 lines) — ray-vs-AABB reflection; `laser` only.
   * `milkdrop/presets.zig` (507 lines) — embedded per-frame preset equations;
     `milkdrop` only.
   * `clock.zig` (23 lines) — `phase`/`cycles`; copy locally (swarm did) or
     promote to the SDK.

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

* `hg_module.config_section` (item 1). Everything else is SDK-local (items 2–4)
  or already covered.

## Suggested order

1. Cheap wins, no new capabilities — validates the recipe across flavours:
   `tide`, `concentric`, `fire`, `windowglow`, `fur`, `fluid`, `whorl`.
2. Audio + clock: `amorphous`, `flux`, `cellbloom`, `voltaic`, `moire`, `ivy`.
3. Add `hg_gl.Target` (item 2), then `glitch`.
4. Add `config_section` (item 1) + move `geometry.zig` to the SDK (item 3),
   then `starfield`, `laser`, `particles`, `milkdrop`.
5. **Phase 4** once every current built-in has a component: delete the union
   variants, `shaderOf`, `defaultShaderFor`, and the `custom` fallback plumbing
   (or keep a slim stateless path only for user `<subdir>/<frag>.frag` shaders).

## Verification checklist (per port)

* `zig build` + `zig build test` clean.
* `--list-effects` shows the name as a component (listed first).
* Cold load compiles and logs `compiled` → `loaded`; warm load reuses the cache.
* Runs in the render loop at the expected FPS with audio active.
* `HG_NO_PLUGINS=1` still renders via the union fallback.
