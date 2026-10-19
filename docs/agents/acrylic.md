# acrylic — design and next steps

`acrylic` is a component effect (`effects/acrylic/`) whose surface is a
*simulated* pool rather than a shader pattern. This doc records the liquid
model it targets, the current design, and the agreed next iteration. Read
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
  2. a few broad vortices **just outside the screen** (`sources`/`source`),
     which sweep streams in from different directions;
  3. a divergence-free **ambient curl-noise** force (`ambient`);
  4. **vorticity confinement** (`vorticity`) to keep shear layers curling;
  5. a second-order **momentum** spring-damper (`momentum`) chasing a slowly
     rotating target, so the global drift overshoots and reverses;
  6. exponential **viscosity** decay;
  7. window drag: a moving rect carries the fluid inside it and pushes a soft
      band ahead of its leading edge.
- **Paint** — a second ping-pong pair at `dye_scale` (default 0.5). Pigment is
  semi-Lagrangian advected by the flow, bleeds at `dye_decay`, and is fed by
  thin veins from a slow noise field; two palette slots pick the pigments.
  It is stored **premultiplied** (`rgb = colour*coverage`) so the theme black
  stays the body and filtering does not fog the surface.
- **Windows** — rects come from `hg_frame`; the component tracks previous rects
  to derive each window's velocity. There is no CPU simulation and no
  `system.zig`.
- **Verification** — `scripts/acrylic.probe.sh` (mostly black, palette colour
  present, a moved window leaves a wake larger than the ambient drift). The
  flow is a GPU pass, so `zig build` cannot catch shader errors: always cold-
  load the component and read `/tmp/hyprglaze.log`.

The reference pieces in `shaders/customs/` (`flow-ref.frag`, `flow-ref2.frag`,
`flow-ref2-buffer-d.frag`) are partial Shadertoy passes — display + solver
fragments that still need their Common tab. We took their ideas (stored
velocity, curl, vorticity confinement, multiscale potential) rather than their
exact code.

### Known gaps

- Colour hierarchy: black must dominate the surface, blue second, white a
  minimum, even when the flow mixes hard.
- Colour mixing is currently a single blended pigment; acrylic should keep
  distinct layers that intrude and flex into each other without fully mixing.
- Momentum is still global enough to rotate the whole surface; the off-screen
  sources should be the primary motion and push against each other.
- Windows are hard zero-velocity holes, not smooth laminar deflectors.
- The Balatro fold is not implemented yet.

## Next iteration plan

### 1. Colour hierarchy and acrylic layering

- Make the **black liquid the largest source**: much higher injection rate and
  coverage than blue, with white a rare highlight.
- Keep pigments in **separate layers** (or premultiplied channels per colour)
  and advect them with slightly different response, so a fast colour intrudes
  into a slower one and the boundary flexes instead of averaging to a flat
  blend.
- Add a coverage gate that favours black: coloured veins survive only where
  they are dense, so strong stirring still leaves the surface mostly black.
- Tune against the **Black Blue OLED** theme (dark blue 50% / light blue 40% /
  white 10% of the paint, black covering most of the screen).

### 2. Directional sources instead of global rotation

- Reduce or zero the global `momentum` rotation; it currently turns every
  stream the same way.
- Use several off-screen sources at different angles and radii, with their own
  strengths and slow drift, so their streams meet and push oncoming flow.
- Keep the spring-damper only for a slow, low-amplitude bias.

### 3. Laminar flow around windows

- Replace the hard zero-velocity rect with an obstacle boundary that deflects
  the stream smoothly, and add a little vorticity at the shear edges so the
  wake merges rather than forming rings.
- Compression ahead of the leading edge, stretch behind.

### 4. Stylize toward the reference (Balatro fold)

Bring back the fold from `liquid_balatro_ref.frag` — the two contour bands
`c1p`/`c2p` — as surface texture driven by the sim:

- reuse the fold's rotated 5-step iteration and contrast modulation;
- advect the fold input by the flow map and mask it by paint coverage;
- keep black dominant: thin coloured filaments over the black body;
- add a `fold` knob (0 = plain dye, 1 = full reference look).

### Acceptance

- `scripts/acrylic.probe.sh` passes: black dominant, palette colour present,
  and a moved window leaves a wake larger than the ambient drift.
- A still frame reads as thick, layered acrylic; dragging a window drags,
  compresses and folds it, and the pattern keeps deforming for a moment after
  the window stops.
- Update this doc, `README.md` (effect row + `[acrylic]` config) and the probe
  in the same commit as the code.
