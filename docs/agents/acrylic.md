# acrylic — a 1:1 port of the flow-ref3 Shadertoy

`acrylic` is a component effect (`effects/acrylic/`) that reproduces the
Shadertoy **flow-ref3** ("kind of viscous, like honey", xenn) —
<https://www.shadertoy.com/view/7sGGRD> — pass for pass. Three things are tuned
for a desktop wallpaper: windows are solid rigid bodies in the flow, the colour
input is a static field of small paint islands quantised onto a black-dominant
OLED palette, and the dynamics run slower and more viscous than the reference.
Read `docs/agents/layout.md` for where files live and `docs/effect-porting.md` /
`docs/agents/new-effect.md` for the component recipe.

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

`effects/acrylic/effect.zig` keeps the four ping-pong pairs (`a`/`b`/`c`/`d`)
and runs the passes in the order above, reproducing Shadertoy's
previous-frame semantics exactly (A reads D's texture from last frame, C reads
its own texture from last frame, etc.). `uRes0`/`uRes1` carry
`iChannelResolution` for Buffer C's `randS`. One extra program (`pass_paint`)
renders the static colour source once at buffer resolution into a `paint`
target; the Image pass reads it as `uCh1`.

The GLSL is not re-authored:

- `effects/acrylic/acrylic.frag` — the Image pass; the host loads and
  compiles it as the display shader.
- `effects/acrylic/shaders.zig` — Buffers A–D and the paint program, generated
  from the original `.frag` files. The Common tab is prepended to each.

The regeneration script is `scripts/gen-acrylic-shaders.py` (it reads the
reference `.frag` files and rewrites `shaders.zig` + `acrylic.frag`). It makes
these edits, all documented in its header:

- Shadertoy plumbing: `iChannelN` → `uChN`, `iChannelResolution[0|1]` →
  `uRes0|uRes1`, and a `main()` wrapper that calls the untouched `mainImage()`.
- Window rigid bodies: an obstacle snippet appended to Buffers A, B and C and
  applied to the field in the `main()` wrapper (see *Windows* below).
- A small-island paint source rendered into `uCh1`, replacing the reference's
  colour texture `iChannel1` (see *Colours* below). The displacement maths is
  untouched; the dispersion distance is shortened (see *Tuning*).
- Slow/viscous constants in Buffers A/B/C (see *Tuning* below); the equations
  are untouched.

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

The reference's colour JPEG (`iChannel1`) is replaced by `hgTheme(uv)`, which
samples a static paint texture (`uCh1`) rendered once by `pass_paint`. That
source is a field of **small islands**, not one continuous vein network:
`hgPaint` stacks three jittered hash-grid layers, each cell holding a randomly
sized, rotated, slightly elongated ellipse, with ~22% of cells left empty. On
its own the source is mostly zero with scattered blobs, so the idle flow cannot
settle into a single screen-spanning stream. The Image pass's dispersion then
averages the source along the displacement, bending each island into a short
stream that collides and slides around its neighbours. The surviving intensity
`p` is mapped onto four theme slots:

| band | source | target area |
|---|---|---|
| black | `iPaletteBg` | ~82% |
| deep blue | `iPalette[10]` (`#1240b0` on Black Blue OLED) | ~9% |
| light blue | `iPalette[2]` (`#2e8fff`) | ~12% |
| white | `iPalette[15]` | thin outlines (~2%) |

`hgPalette(p, outline)` uses `smoothstep` thresholds at roughly the 80th and 88th
percentiles of the dispersed intensity (`0.20`, `0.42`), so the screen reads as
a broad OLED-black body with blue streams. The thresholds are tuned for the
palette above; they are the knobs to move if a theme's luminance changes the
balance.

The white spots are **outlines, not fills**. `hgOutline(p)` takes the gradient
of the dispersed intensity (`dFdx`/`dFdy`) and turns the `p = 0.66` contour into
a signed distance in pixels, so the white band around it has the same width on
every spot, whatever the spot's size, and the core of the spot keeps the
light-blue band. Only the neighbourhood of the contour can turn white, so the
flat black field never picks up an outline. The white half-width is 3 px
(`halfWidth` in the generator) and the whole feature is one line of the
generator — the blue bands are untouched.

The paint program is rendered with `iResolution` set to the buffer size and
sampled with repeat/linear filtering, so edge-crossing dispersion taps stay
continuous. Rendering it once (instead of evaluating the island hashes at every
one of the 64 dispersion taps) keeps the Image pass at the same cost as the old
procedural source.

Two finishing touches are borrowed from `weft`: an additive field grain over the
whole screen (10 Hz reseed, amplitude `0.035`, so the black body has a little
stock), and a weak dark-light halo around windows — flows lift near a window
(`mix(0.78, 1.14, halo)`) and the far field rests darker. Both are much weaker
than weft's full fringe halo. The reference's
contrast/ACES/lava-glow finish is dropped: it flooded the screen with colour and
fought the theme. The colour texture's only other use in the reference (Buffers
C/D) is discarded by the original code, so those passes bind a 1×1 placeholder.

The palette uniforms (`iPalette`, `iPaletteSize`, `iPaletteBg`, `iPaletteFg`)
are supplied by the host for the display shader.

### Windows

flow-ref3 has no window interaction. This port adds one, additively: every
window is a **rigid body** in the flow.

`hgObstacle()` (generated into the GLSL) is applied to Buffer A's `.xy` and
`.zw`, Buffer B's velocity `.xy`, and Buffer C's `.xy`. For each window it
builds a rounded-box SDF and only acts within a thin band at the surface and in
the interior — never globally (the far-field gate is what stops the normal
reaching across the screen and pulling flows in like a magnet):

- **no penetration** — the base is the magnet-fix projection: the inward normal
  component of the field is removed, so flow bends around the window instead of
  crossing it. The test is relative to the window's own velocity, so a window
  moving into the flow pushes it aside;
- **interior clearing** (`win_push`) — inside the rect the whole field is
  damped from the edge inward (default fully), so there is **no flow under a
  window** and no window-shaped imprint leaks out as a trail when it moves.
  Nothing is frozen into a solid; the field simply relaxes to zero under the
  body and the boundary layer keeps the transition smooth;
- **edge-parallel redirect** (`win_turn`) — the inflow removed at the surface is
  added back along the edge tangent, so a stream heading into the window turns
  and slides alongside it instead of piling up;
- **swirl** (`win_curl`) — a swirl term rolls a head-on stream around the body;
- **bounds push** (`win_wall`) — the window's own motion is projected on the
  outward normal, so the leading edge shoves flow ahead of it relative to the
  window bounds;
- **inertia** — the window velocity is exponentially smoothed with a ~0.15 s
  time constant before it reaches the shader, so the push ramps in and fades
  out instead of snapping;
- **optional no-slip** (`win_slip`) — viscous drag at the surface; default free
  slip, push-and-deflect only.

The obstacle only adds or removes components; it never reconstructs a magnitude
from the field, so no constant offset can creep into a buffer (an earlier
version blended toward the outward normal and, because Buffer C used to be
treated 0.5-centred, left a ~0.5 displacement bias under windows — the "flow
under the window" residue).

Window rects and per-window velocities are tracked in `update()` from
`hg_frame.windows` (velocities from the centre delta; the host only supplies the
focused window's velocity). Rect coordinates are GL-space surface pixels, so
they are scaled by `scale` into buffer pixels before upload.

### Tuning

The reference runs at 60 Hz with full-strength advection, which reads as fast
churn on a desktop. The generator rewrites a few constants (the equations are
untouched):

| pass | constant | reference | port | effect |
|---|---|---|---|---|
| A | `TIMESTEP` | `0.1` | `0.007` | slower acceleration |
| A | `ADVECT_DIST` | `2.0` | `0.3` | shorter transport, stickier field |
| B | `ad` | `6.0` | `0.45` | shorter fluid advection |
| B | `upd` | `0.99` | `0.9997` | more inertia, slower response |
| C | self-advection `*2.0` | `2.0` | `0.12` | slower scale-mixing |
| D | time uniform | `iTime` | `iTime * 0.10` | slower lava-lamp blend |
| Image | `DISP_SCALE` | `1.50` | `0.90` | shorter dispersion; islands stay short streams instead of smearing into long ribbons |

The dispersion scale is what sets the perceived flow length: raising it smears
each paint island further along the velocity field and ties neighbours into long
ribbons; lowering it keeps the islands as separate little flows. Increasing the
buffer constants speeds the honey up; decreasing them risks a static field.
These are compile-time replacements, so regenerate after editing the script.

## Config

`[acrylic]` in the TOML (see the README):

- `scale` — buffer resolution as a fraction of the output. Default `0.8`:
  four-fifths resolution makes every texel cover 1.25 output pixels, so the
  structures read a little larger and the four buffers are ~1.56× cheaper.
  `1.0` is the reference's canvas-resolution behaviour.
- `win_band` — boundary-layer thickness in surface px (default `10`).
- `win_corner` — rounded-corner radius of the obstacle in surface px
  (default `14`).
- `win_speed` — the window speed in px/s that maps to a field value of `1`
  (default `700`); body velocity is clamped to a unit vector in field space.
- `win_slip` — `0..1`, optional no-slip drag at the window surface (default
  `0.0`, free slip: windows push and deflect the flow but never pull it).
- `win_push` — `0..1`, how hard the flow under a window is cleared
  (default `1.0`, no flow at all under the body). Lower it for a little
  residual movement under a window.
- `win_turn` — `0..1`, how much incoming flow is bent into an edge-parallel
  slide (default `0.85`). `0` stops flow dead at the edge.
- `win_curl` — `0..1`, swirl added to that slide so head-on flow rolls around
  the body (default `0.25`).
- `win_wall` — `0..1`, push ahead of a moving window's bounds (default `0.6`);
  the velocity is inertia-smoothed (~0.15 s) before it reaches the shader.

## Verify

```sh
zig build && zig build test
scripts/rebuild.sh
~/.local/bin/hyprglaze --list-effects        # acrylic listed
~/.local/bin/hyprglaze --effect acrylic --fps   # cold-load, watch /tmp/hyprglaze.log
```

The five buffer/Image passes and the paint program are GPU shaders compiled at
load, so `zig build` cannot catch a shader error — always cold-load and read the
log. A uniform typo renders flat and still "succeeds".

At 1920×1200 with `scale = 0.8` the four buffers, the one-off paint pass and the
Image pass run at ~60 FPS on the reference machine.

