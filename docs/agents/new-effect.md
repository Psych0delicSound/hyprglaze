# Adding a new effect (including new inputs)

Read this when adding an effect that is **not** a port of an existing built-in,
and especially when it needs host data that `hg_frame` does not carry yet.
For porting an existing built-in, use `docs/effect-porting.md` instead.

The hard part is almost never the shader. It is deciding where the data comes
from, getting it into the per-frame snapshot, and extending the ABI without
breaking loaded components.

## 1. Choose the shape

| Shape | When | Where |
|---|---|---|
| **Component** (default) | any stateful effect, and anything needing new input | `effects/<name>/effect.zig` + `<name>.frag` |
| **Shader-only** | purely procedural, no CPU state and no extra input | `shaders/<name>.frag` (shared stateless context) |
| **Union variant** | only to keep a `HG_NO_PLUGINS=1` fallback for an existing built-in | `src/effects/<name>*.zig` + a variant in `src/effects.zig` |

New effects should be components. They need **no registration**: the loader
scans `effects/*/effect.zig`, and `--list-effects` picks them up. A component
beats a union variant of the same name.

A component-only effect still works with `HG_NO_PLUGINS=1`, but it falls back
to the shared stateless context: its shader renders, its CPU simulation does
not. If that degradation is unacceptable, add a union variant as well.

## 2. Know the data path

Every input follows the same spine:

```
source               host module                     per-frame snapshot     ABI              effect
Hyprland IPC   ┐
external client├──▶ src/core/* (poll/event/cache) ──▶ FrameState      ──▶  hg_frame   ──▶  update()
config/TOML    │                                    (src/core/frame.zig)  (hg_plugin.h)      │
audio capture  │                                                         (plugin.zig)        ▼
clock/geometry ┘                                                         + uniform push   upload()
                                                                                             │
                                                                      host draws the quad ◀──┘
```

Two hard rules at every step:

- **Snapshot, never retain.** `FrameState` slices and every `hg_frame` pointer
  are valid only during `update`. Copy what you keep.
- **Coordinates are GL space.** The host converts compositor layout space
  (y-down, per-output offsets, logical scale) into surface pixels with y-up via
  `src/core/geometry.zig` (`toGl`, `toGlPoint`). Any new geometry input must go
  through the same conversion — do not feed raw IPC rects to an effect.

## 3. Build the effect first

If the data the effect needs already exists in `hg_frame`, skip to §4.

Skeleton: `effects/<name>/effect.zig`, exporting one `hg_module`:

```zig
const hg = @import("hg.zig");
const c = hg.c;

const State = struct { /* your state */ };

fn create(host: [*c]const c.hg_host, w: f32, h: f32) callconv(.c) ?*anyopaque { … }
fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void { … }
fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void { … }
fn destroy(handle: ?*anyopaque) callconv(.c) void { … }

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "<name>",
    .shader = "<name>.frag",
    .config_section = null,   // or a shared section name
    .wants_audio = 0,         // 1 ⇒ host fills hg_frame.wave
    .create = create,
    .update = update,
    .upload = upload,
    .destroy = destroy,
};
export fn hg_module_entry() callconv(.c) *const c.hg_module { return &module; }
```

Lifecycle rules (see `docs/agents/conventions.md`):

- `create` allocates state and reads config through `hg.Host`; **it must not
  touch GL**.
- `update` runs the simulation and copies anything kept past the call.
- `upload` sets effect-local uniforms and creates GL objects lazily. It runs
  **before** the host's draw, so leave blend off.
- `destroy` frees state and GL objects; the creating context is current.

Uniforms:

- **Effect-local** data → `hg.Uniforms(.{ .foo = "iFoo" })` and set it in
  `upload(program)`. Unknown/undeclared uniforms are silently skipped
  (location −1), so a typo is invisible — verify with pixels.
- **Host-wide** data → the standard uniforms (`iResolution`, `iTime`,
  `iMouse`, `iWindow`, `iWindows`, `iPalette*`, …) already pushed by the host.
  Do not duplicate them.
- Standard uniforms are pushed by the host **after** `upload`; an effect must
  not try to override one.

Scale and DPI: `iResolution`, window rects and cursor are already surface
pixels with the output scale applied. Use pixels consistently; for soft
effects derive sizes from `iResolution.y` (the built-ins do).

Config: read keys from the effect's own TOML section with `hg.Host`
(`getFloat`/`getInt`/`getBool`/`getString`) and sensible defaults. Clamp
user values. Use `.config_section = "<other>"` only when the effect
intentionally shares another section. Audio is host-captured; set
`wants_audio = 1` and use `hg.audio` — never open your own capture.

## 4. Extend the input (the main work)

### 4a. Acquire it in the host

Put the source in a small `src/core/` module with unit tests for pure logic.
Choose the cheapest reliable acquisition:

- **Event-driven** (already-parsed IPC, a socket) → cache the last value; the
  frame loop reads the cache.
- **Polled** → poll off the hot path or at a bounded rate, never block the
  render loop.
- **External client / auxiliary data** → the same rule: the host owns the
  connection, validates and bounds it, and republishes a snapshot.

Keep the pipeline snapshot-based: producers write a value, the frame loop
copies it. If a helper thread is unavoidable (audio does this), guard the
snapshot and read it once per frame.

Units and space must be decided here and documented: pixels vs logical,
surface-relative vs monitor-relative, y-up vs y-down.

### 4b. Put it in `FrameState`

`src/core/frame.zig`. Add fields with defaults so existing construction sites
keep compiling. Prefer fixed-size arrays plus a count over slices for anything
the ABI will carry; slices are acceptable if the ABI copies them immediately.

Document, next to the field: **units, coordinate space, and lifetime**.
Fill it in the frame loop in `src/main.zig` where the `FrameState` is built
(the `r.fx().update(.{ … })` literal).

### 4c. Extend the ABI

This is the step that can break every loaded component, so do it deliberately.

1. **`sdk/include/hg_plugin.h`** — add fields to the end of the relevant struct
   (`hg_frame`, or a new C struct it points to). Never reorder or retype an
   existing field, and never grow a struct used inside an array (`hg_rect`)
   without treating it as a new ABI. Use a fixed capacity plus a length
   (`const T* x; uint64_t x_len`) and comment the cap, units, space, and
   "valid only during `update`".
2. **Bump `HG_ABI_VERSION`** for any layout change. The host refuses a `.so`
   built against a different version. This is the safety net, not optional.
3. **`src/core/plugin.zig`** — in `Instance.update`, pack `FrameState` into
   the C struct. Back the pointers with storage that outlives the synchronous
   `update` call (stack locals are fine); cap array counts at the ABI/shader
   maximum; zero-fill anything absent. Do not allocate per frame.
4. **`sdk/hg.zig`** — add a thin wrapper only if it makes the effect code
   materially simpler; the struct is already reachable through `hg_frame`.
5. **Cache/ABI consequences.** The component cache key includes the ABI header
   and every staged SDK file, so changed binaries recompile automatically and
   `scripts/rebuild.sh` prunes superseded `.so`s. The version bump protects
   against a host/component mismatch; do not rely on the hash alone.

If the new input should reach **every** shader, it is a standard uniform, not
an ABI change: add a location to `ShaderProgram`, a field to
`FrameUniforms`, push it in `ShaderProgram.draw`, and fill it where the
renderer builds `FrameUniforms`. Keep it out of the ABI if the effect can
receive it another way.

### 4d. Offer it to the effect

For a component, read the new `hg_frame` field in `update`, copy it, and push
whatever the shader needs through effect-local uniforms in `upload`. If the
field is an array, mirror the host cap in the shader's array size — a mismatch
is either a silent truncation or a GL upload overrun.

## 5. Verify (do not skip the cold load)

```sh
zig build
zig build test
scripts/rebuild.sh          # installs ~/.local/bin + restarts + prunes cache
~/.local/bin/hyprglaze --list-effects
~/.local/bin/hyprglaze --effect <name>   # watch the daemon log
```

- **`zig build` does not compile component sources.** They compile on load, so
  a typo surfaces only in the daemon log, never in the build exit code. Always
  load the effect once.
- Cold load must log `compiling` → `compiled` → `loaded` → `entering render
  loop`; a warm load must reuse the `.so` without recompiling.
- Grab two frames and confirm the effect is actually drawn and animating. A
  uniform typo renders flat and still "succeeds".
- Exercise the input: move a window, move the cursor, supply the external data,
  and confirm the effect reacts. If you added a shader standard uniform, check
  it changes with the data.
- `HG_NO_PLUGINS=1 --effect <name>` must still start and draw (stateless
  fallback, unless you also added a union variant).
- Behavior tied to the compositor belongs in the nested harness
  (`docs/agents/harness.md`); pure logic belongs in `zig build test`.

## 6. Documentation (same commit)

Before committing, refresh:

- this file, if the recipe or the data path changed;
- `docs/agents/layout.md` if you added a source module or SDK helper;
- `docs/agents/config.md` if you added a config key or changed resolution;
- `docs/agents/conventions.md` if you introduced a new invariant;
- `docs/effect-porting.md` if the effect is (or becomes) a port;
- the README's shader-uniform / config tables for anything user-visible;
- the docs index in `AGENTS.md` for any new doc.

## 7. Checklist

- [ ] Shape chosen (component; shader-only; union only for fallback).
- [ ] New data acquired in a tested `src/core/` module, bounded and cached.
- [ ] Converted to GL space (`geometry.toGl`/`toGlPoint`), units documented.
- [ ] Added to `FrameState` with defaults and a lifetime comment.
- [ ] Added to `hg_frame` at the **end**, fixed cap + length, `HG_ABI_VERSION`
      bumped.
- [ ] Packed in `plugin.zig` from storage that outlives the synchronous call.
- [ ] Effect reads/copies it; shader array caps match the host.
- [ ] `create` has no GL; `upload` creates GL lazily and leaves blend off.
- [ ] Config keys defaulted and clamped; audio (if any) host-captured.
- [ ] `zig build` + `zig build test` clean; cold load compiles and draws;
      input actually changes the output; warm cache; `HG_NO_PLUGINS=1`.
- [ ] Docs refreshed in the same commit.
