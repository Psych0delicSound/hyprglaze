# acrylic — design and next steps

`acrylic` is a component effect (`effects/acrylic/`) whose surface is a
*simulated* pool rather than a shader pattern. This doc records the liquid
model it targets, the current design, and the agreed next iteration. Read
`docs/agents/layout.md` for where the files live and `docs/effect-porting.md`
for the component recipe.

## The liquid-surface model

A convincing liquid surface is a dynamic map carrying two quantities at every
point: **height** (which makes waves) and **velocity** (which makes flow). You
do not need the Navier–Stokes equations — the few visually useful pieces are:

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

- **Physics** — `system.zig` is the particles XPBD contact solver with the
  magnetic parts removed (no focused-window well, no cursor push, no pops). A
  dense, low-friction, near-inelastic packing of ~380 particles fills the
  surface; windows are kinematic colliders, so dragging one shoves the pool and
  a wake travels through it. A weak ambient current (`currentAccel`) keeps the
  pool breathing.
- **Material** — most particles are theme black (`black`, default 0.88); the
  rest take palette accent slots. The pool is splatted each frame into a coarse
  density / accent-colour / velocity field and `acrylic.frag` shades it: black
  body, velocity-driven wave sheen, density relief. Mostly black, with
  coloured parcels drifting through it.
- **Verification** — `scripts/acrylic.probe.sh` (render is mostly black, has
  colour, and a moved window leaves a wake larger than the ambient drift);
  `effects/acrylic/system.zig` unit tests the solver.

The known gap: the velocity field is **recomputed statelessly** every frame
from the particle positions. Nothing carries motion once the particles settle,
so the surface has neither inertia nor "memory" — the two properties the model
above puts at the centre of a convincing liquid.

## Next iteration plan

Goal: keep the particle simulation as the source of motion, add flow inertia
and acrylic viscosity, and stylize the surface toward the reference liquid
(`liquid_balatro_ref.frag` — localthunk's Balatro fold).

### 1. A persistent flow field with inertia

Replace the stateless velocity splat with a **persistent flow map**:

- Keep the coarse velocity field in a ping-pong pair of `hg_gl.Target`s
  (feedback as in milkdrop). Each frame: decay the previous map by viscosity
  (`flow *= exp(-k*dt)`), then add the current particle and window impulses.
- This is where inertia lives: when the drive stops, the map keeps moving and
  bleeds away, instead of snapping to zero, so a shove leaves motion with
  **memory** behind it.
- Seed **vorticity** from the curl of the field so fast-meets-slow regions curl
  into eddies that outlive the main flow.
- Give the pool **constant momentum**: a global current vector that is itself
  integrated (a spring-damper toward a slowly rotating target, with overshoot),
  so the whole surface always drifts and gently reverses. Expose `momentum`
  (0 = today's calm pool) and `viscosity` (decay rate).

### 2. Acrylic viscosity, not water

The material model is thick, sluggish paint, which is also what stylizes it:

- **Color advection** — transport the accent-colour texture coordinates by the
  flow map so the palette forms long, layered trails that stretch and twist
  rather than blending flat.
- **Laminar flow around obstacles** — streams bend smoothly around windows and
  merge gradually behind them; no turbulent splash.
- **Shear into filaments** — the interior of a stream moves faster than its
  edges, so rounded blobs elongate into teardrop/almond filaments. Implement as
  a shear term on a second, slower-flowing colour layer (front paints over
  back).
- **Displacement** — where two streams meet, compress the boundary so colour
  edges get denser and more pronounced.
- **Damped motion with memory** — patterns keep their deformed shape as the
  flow settles (a direct consequence of §1).

### 3. Object coupling (windows as leaves)

A window is a heavy object on thick honey:

- **Drag trail** — the moving rect drags nearby layers, stretching the pattern
  in the direction of travel.
- **Compression ahead, stretching behind** — write a denser pattern in front of
  the leading edge and a stretched one in the trailing wake, as velocity
  impulses into the flow map (the solver already gives the leading/trailing
  velocity asymmetry).
- Water-only effects (Kelvin wake, capillary/gravity ripples) are deliberately
  omitted: acrylic is laminar, so the wake merges rather than forming rings.
- Flow→object advection (the leaf carried by the water) is not ours to
  implement — Hyprland owns window motion — so the coupling is one-way by
  design.

### 4. Stylize toward the reference (Balatro fold), driven by the flow

Bring back the Balatro fold from `liquid_balatro_ref.frag` — the two narrow
contour bands `c1p`/`c2p` — but as *surface texture driven by the sim*:

- Reuse the fold's spiral/iteration exactly (rotated, 5-step fold, contrast
  modulation), so the filament look matches the reference.
- **Advect the fold input by the persistent flow map** and mask it by the
  density field: the bands are created by the liquid's flow and only appear
  where liquid is present, so window wakes visibly bend and drag them.
- Put the fold over the **procedural noise base** described above, so the
  filaments sit on a slowly swirling ground.
- Keep black dominant: the fold is drawn as thin coloured filaments over the
  black body (palette warm/cool for `c1p`/`c2p`, foreground for crossings),
  with the same coverage gate the previous acrylic used (`black`).
- Add a `fold` knob (0 = off, today's plain pool; 1 = full reference look).

### Acceptance

- Simulation unchanged in behaviour: the probe's wake assertion still passes,
  collisions still unit-tested, and CPU stays in the same ballpark (the flow
  map is one extra coarse pass, cheap).
- A still frame resembles the reference's folded flow; moving a window drags,
  compresses and folds it, and the pattern keeps deforming for a moment after
  the window stops.
- Update this doc, `README.md` (effect row + `[acrylic]` config) and the probe
  in the same commit as the code.
