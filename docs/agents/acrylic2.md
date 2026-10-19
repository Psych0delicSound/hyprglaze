# acrylic2 — a 1:1 port of the flow-ref3 Shadertoy

`acrylic2` is a component effect (`effects/acrylic2/`) that reproduces the
Shadertoy **flow-ref3** ("kind of viscous, like honey", xenn) —
<https://www.shadertoy.com/view/7sGGRD> — pass for pass, with no visual or
physical redesign. Two host integrations are additive: windows are solid rigid
bodies in the flow, and the colour input is taken from the live theme instead of
a shipped texture. Read `docs/agents/layout.md` for where files live and
`docs/effect-porting.md` / `docs/agents/new-effect.md` for the component recipe.

## The reference

flow-ref3 is a five-pass mashup. Its JSON channel graph is the whole design:

| pass | body | inputs (in order) |
|---|---|---|
| Image | displacement + dispersion (fork of cornusammonis' *Displacement with Dispersion*) | `ch0`=Buffer D, `ch1`=colour, `ch2`=Buffer C |
| Buffer A | *A fracturing dynamical system* (MsyXRW) | `ch0`=Buffer D, `ch1`=noise A, `ch3`=keyboard |
| Buffer B | *A fluid-like dynamical system* (XddSRX) | `ch0`=Buffer A |
| Buffer C | flockaroo's *single pass CFD* | `ch0`=Buffer C (self), `ch1`=noise C, `ch2`=colour, `ch3`=Buffer B |
| Buffer D | *Barbarella's Lava Lamp* (sstGWl) feedback | `ch0`=Buffer B, `ch1`=colour, `ch2`=Buffer C, `ch3`=Buffer B |

Shadertoy renders buffers in order A→B→C→D (Image last) and a buffer reading a
buffer that has *not yet* run this frame sees the previous frame. So the actual
per-frame dependency is:

```
A  <- D(prev),  noiseA, keyboard
B  <- A
C  <- C(prev),  noiseC, colour, B
D  <- B,        colour, C,      B
Img<- D,        colour, C
```

The "collision" is the whole chain: the fracturing field (A) and the fluid field
(B) feed each other through D, flockaroo's scale-mixing (C) advects them, and
the lava lamp (D) wraps the result back into A next frame.

## The port

`effects/acrylic2/effect.zig` keeps the four ping-pong pairs (`a`/`b`/`c`/`d`)
and runs the passes in the order above, reproducing Shadertoy's
previous-frame semantics exactly (A reads D's texture from last frame, C reads
its own texture from last frame, etc.). `uRes0`/`uRes1` carry
`iChannelResolution` for Buffer C's `randS`.

The GLSL is not re-authored:

- `effects/acrylic2/acrylic2.frag` — the Image pass; the host loads and
  compiles it as the display shader.
- `effects/acrylic2/shaders.zig` — Buffers A–D, generated from the original
  `.frag` files. The Common tab is prepended to each.

The regeneration script is `scripts/gen-acrylic2-shaders.py` (it reads the
reference `.frag` files and rewrites `shaders.zig` + `acrylic2.frag`). It makes
exactly three kinds of edit, all documented in its header:

- Shadertoy plumbing: `iChannelN` → `uChN`, `iChannelResolution[0|1]` →
  `uRes0|uRes1`, and a `main()` wrapper that calls the untouched `mainImage()`.
- Window rigid bodies: an obstacle snippet appended to Buffers A, B and C and
  applied to the field in the `main()` wrapper (see *Windows* below).
- A theme colour source in the Image pass, replacing the reference's colour
  texture `iChannel1` (see *Colours* below). The displacement and dispersion
  maths is untouched.

### Inputs

The reference's external textures are not shipped. The port synthesises them
deterministically at first upload:

- `noise_a` — smooth multi-octave value noise (coherent blobs; Buffer A seeds
  from it).
- `noise_c` — white noise (Buffer C steps a random rotation each frame).
- keyboard — a 1×1 zero, so Buffer A's `reset()` never fires, the same as an
  untouched wallpaper.

This changes no movement logic: both noise inputs are 256×256 and drive exactly
the same code paths as the reference images.

### Colours

The reference's colour JPEG (`iChannel1`) is replaced by `hgTheme(uv)`: a fixed
smooth field sampled through the live theme palette (`iPalette`, `iPaletteSize`,
`iPaletteBg`, `iPaletteFg`, supplied by the host for the display shader). The
Image pass's chromatic dispersion then separates the palette into fringes, so
the honey is tinted by the user's theme instead of the shipped JPEG. The colour
texture's only other use in the reference (Buffers C/D) is discarded by the
original code, so those passes bind a 1×1 placeholder.

### Windows

flow-ref3 has no window interaction. This port adds one, additively: every
window is a **rigid body** in the flow.

`hgObstacle()` (generated into the GLSL) is applied to Buffer A's `.xy` and
`.zw`, Buffer B's velocity `.xy`, and Buffer C's `.xy` (0.5-centred velocity).
For each window it builds a rounded-box SDF, but only inside a thin band at the
surface and in the interior — never globally:

- **no penetration** — the inward normal component of the field is removed, so
  the flow bends around the window instead of crossing it;
- **moving wall** — the condition is relative to the window's own velocity, so
  a window moving into the flow pushes it aside;
- **no solid interior** — the field is not frozen or overwritten inside the
  rect. Doing that made the displacement collapse to zero in the window and
  drew a bright ring around it (and, with the outward normal reaching across
  the screen, pulled distant flows toward the window like a magnet). The body
  acts only at its surface, so the visible flow stays continuous.
- **optional no-slip** — `win_slip > 0` adds a viscous drag at the surface;
  the default is free slip, push-only.

Window rects and per-window velocities are tracked in `update()` from
`hg_frame.windows` (velocities from the centre delta; the host only supplies the
focused window's velocity). Rect coordinates are GL-space surface pixels, so
they are scaled by `scale` into buffer pixels before upload.

## Config

`[acrylic2]` in the TOML (see the README):

- `scale` — buffer resolution as a fraction of the output. Default `0.5`: half
  resolution makes every texel cover two output pixels, so the structures read
  about twice as large, and the four buffers are four times cheaper. `1.0` is
  the reference's canvas-resolution behaviour.
- `win_band` — boundary-layer thickness in surface px (default `10`).
- `win_corner` — rounded-corner radius of the obstacle in surface px
  (default `14`).
- `win_speed` — the window speed in px/s that maps to a field value of `1`
  (default `700`); body velocity is clamped to a unit vector in field space.
- `win_slip` — `0..1`, optional no-slip drag at the window surface (default
  `0.0`, free slip: windows push and deflect the flow but never pull it).

## Verify

```sh
zig build && zig build test
scripts/rebuild.sh
~/.local/bin/hyprglaze --list-effects        # acrylic2 listed
~/.local/bin/hyprglaze --effect acrylic2 --fps   # cold-load, watch /tmp/hyprglaze.log
```

The five passes are GPU shaders compiled at load, so `zig build` cannot catch a
shader error — always cold-load and read the log. A uniform typo renders flat and
still "succeeds".

At 1920×1200 with `scale = 0.5` the four buffers plus the Image pass run at
~60 FPS on the reference machine.

