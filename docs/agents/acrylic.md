# acrylic — design and next steps

`acrylic` is a component effect (`effects/acrylic/`) whose surface is a
**simulated flow field shaping a procedural band pattern** rather than advected
paint. This doc records the liquid model it targets, the current design, and the
agreed next iteration. Read
`docs/agents/layout.md` for where the files live and `docs/effect-porting.md`
for the component recipe.

## The liquid-surface model

A convincing liquid surface is a dynamic map carrying two quantities at every
point: **height** (which makes waves) and **velocity** (which makes flow).
The few visually useful pieces are:

- **Flow inertia.** Water has mass, so when the force that drives it (wind, an
  oar, a current) stops, the motion does not. Represent the flow as a velocity
  field that persists and decays through viscosity (internal friction), e.g. an
  exponential decay of the vector magnitude.
- **Vorticity.** Velocity differences across the flow make it curl; where fast
  water meets still water, eddies form and keep rotating after the main flow
  has slowed. Seed these from the curl of the field.
- **Object → liquid (waves).** A moving object displaces water ahead of it
  (higher pressure) and leaves lower pressure behind, so the water flows back
  in: a wake. A sudden, localized disturbance makes ripples that travel
  outward, oscillate, and lose amplitude.
- **Liquid → object (advection).** A floating object is passive: it is carried
  at roughly the local flow velocity, rotates when its ends sit in different
  velocities, and lags behind sharp turns because of surface drag and its own
  mass.

For **acrylic paint** specifically, the target is a stylized fluid-art look, not
water: acrylic is thick and viscous (and non-Newtonian), so instead of splashes
and circular ripples you get slow streams that flow *around* obstacles without
fully mixing, leaving veins, cells and filaments.

- **Color advection.** The paint moves in layers — a brushstroke deforms,
  stretches and twists into long viscous trails rather than blending flat.
- **Laminar flow around obstacles.** Streams bend smoothly around an object and
  merge gradually behind it, with no turbulent, chaotic wake.
- **Damped motion with "memory".** When the force ends, the paint slows as if
  thickening in place, and the deformed patterns keep their shape.
- **Flow interactions.** A stream pushing into another compresses and deforms
  the boundary (color edges get denser); the interior of a stream moves faster
  than its friction-slowed edges, so shear stretches rounded blobs into
  teardrop- or almond-shaped filaments.
- **Object on acrylic.** Like a heavy object on honey: it drags the nearby
  layers into a trail, compressing the pattern ahead of it and stretching it
  behind.

The practical recipe is two pieces: a **procedural noise base** for the paint
texture, and a **dynamic flow map** — a render texture that objects and motion
write velocity vectors into, sampled by the shader to offset the paint UVs. In
GL that persistent map needs ping-pong framebuffers (`hg_gl.Target`), not a
single stateless fragment pass.

## Current design

The particle pool was retired: it detected window motion well but could not be
turned into a convincing flow field. `acrylic` is now a GPU flow simulation.

- **Flow field** — a ping-pong pair of `hg_gl.Target`s at `scale` (default
  0.25 of the output). Each frame one pass:
  1. semi-Lagrangian self-advection;
  2. a few broad vortices **just outside the screen** (`sources`/`source`) at
     different angles, alternating rotation and pushing inward, so streams
     enter from different directions and meet;
  3. a divergence-free **ambient curl-noise** force (`ambient`);
  4. **vorticity confinement** (`vorticity`) to keep shear layers curling;
  5. a second-order **momentum** spring-damper (`momentum`) chasing a slowly
     rotating target, so the global drift overshoots and reverses;
  6. exponential **viscosity** decay;
  7. **windows as rigid bodies** (`force`/`push`): flow cannot pass through a
     rect — the interior is bled to a stop and nudged gently out — while a soft
     band just outside follows the frame, so the neighbouring paint stretches
     with a moving window.
- **Bands** — the native layer is **procedural bands in a carried coordinate**,
  not advected paint. The display samples the bands at `uv + disp`, where `disp`
  is a material displacement advected by the flow. Because the flow stretches
  that coordinate, the band level sets become long sinuous filaments along the
  stream, and — crucially — the pattern *keeps its form* as it travels instead
  of being re-derived from the current direction every frame. **Black** is the
  broad, low-contrast body; **blue** is a narrow vein system; **white** is a
  rare thin core gated inside a blue vein.
- **Displacement field** — a small second ping-pong pair at `warp_scale`
  (default 0.75) carries `disp` (RG). Each frame it is advected by the flow and
  bled back toward zero at `warp_relax` (default 0.15/s), so it stays anchored
  and cannot drift or smear without bound. A window deforms `disp` locally and
  the deformation lingers; elsewhere the band pattern is left alone.
- **Windows** — rects come from `hg_frame`; the component tracks previous rects
  to derive each window's velocity. There is no CPU simulation and no
  `system.zig`.
- **Verification** — `scripts/acrylic.probe.sh` (mostly black, palette colour
  present, a moved window leaves a wake larger than the ambient drift). The
  flow is a GPU pass, so `zig build` cannot catch shader errors: always cold-
  load the component and read `/tmp/hyprglaze.log`.

The reference pieces in `shaders/customs/` (`flow-ref.frag`, `flow-ref2.frag`,
`flow-ref2-buffer-d.frag`, and the full `flow-ref3*.frag` pass set) are
Shadertoy passes. We took their ideas (stored velocity, curl, vorticity
confinement, multiscale potential, and displacement/dispersion along the field)
rather than their exact code; `flow-ref3` is the elongation/mixing reference the
band shaping is measured against.

### Known gaps

- A window is a box rigid body: flow stops at its edges and is pushed out, but
  it does not yet *deflect* smoothly around the corners, and the boundary drag
  is a uniform band rather than a real no-slip layer.
- The band pattern is now stable frame to frame (a moved window no longer
  reshuffles distant flows), but the carried coordinate is low frequency, so
  the surface currently reads as a few large ribbons rather than many fine
  veins.

## Next iteration plan

### 1. Laminar flow around windows

- Round the obstacle boundary and add a little vorticity at the shear edges so
  the wake merges rather than forming rings; compress ahead of the leading edge
  and stretch behind.
- A true no-slip layer instead of a uniform drag band.

### 2. Acrylic tuning

- Keep tuning the band ratios and the flow against **Black Blue OLED**; black
  must stay the bulk even when a window mixes hard. Current steady state settles
  near 12% coloured and ~88% near-black.
- White is a rare vein core; its amount is provisional and will be fine-tuned.
- More, finer veins: raise the carried-coordinate frequency / add folds without
  reintroducing the global reshuffle.

### Acceptance

- `scripts/acrylic.probe.sh` passes: black dominant, palette colour present,
  and a moved window leaves a wake larger than the ambient drift.
- A still frame reads as thick, layered acrylic; dragging a window drags,
  compresses and folds it, and the pattern keeps deforming for a moment after
  the window stops.
- Update this doc, `README.md` (effect row + `[acrylic]` config) and the probe
  in the same commit as the code.
