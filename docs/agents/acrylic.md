# acrylic — design and next steps

`acrylic` is a component effect (`effects/acrylic/`) whose surface is a
*simulated* pool rather than a shader pattern. This doc records the current
design and the agreed next iteration. Read `docs/agents/layout.md` for where
the files live and `docs/effect-porting.md` for the component recipe.

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

## Next iteration plan

Goal: the still surface should read like the reference liquid
(`liquid_balatro_ref.frag` — localthunk's Balatro fold) while the simulation
stays the source of motion. Three additions, none of which may remove the
particle simulation.

### 1. Constant momentum

Today the only bulk motion is the weak sinusoidal `currentAccel`, which has no
memory. Give the pool a *persistent* momentum:

- Add a small global current field with a dominant direction that slowly
  rotates (per-particle acceleration biased the same way, plus the existing
  curl term). Everything then drifts the same way at rest, instead of only
  reacting to windows.
- Expose it as a `momentum` knob (0 = today's calm pool).

### 2. Inertia

- Lower drag further and/or drive the current from an integrator with its own
  velocity and a spring toward a slowly rotating target direction, so the
  current accelerates smoothly and reverses with overshoot rather than being
  recomputed statelessly from `time`.
- The particles already carry mass (`inv_mass`) and the solver derives velocity
  from corrected positions; inertia is mostly a matter of not damping it away.
  Sweep `viscosity`/`momentum` so a shove keeps moving, then decays.

### 3. Stylize toward the reference (without losing the simulation)

Bring back the Balatro fold from `liquid_balatro_ref.frag` — the two narrow
contour bands `c1p`/`c2p` — but as *surface texture driven by the sim*:

- Reuse the fold's spiral/iteration exactly (rotated, 5-step fold, contrast
  modulation), so the filament look matches the reference.
- **Advect the fold input by the splatted velocity field** and mask it by the
  density field: the bands are created by the liquid's flow and only appear
  where liquid is present, so window wakes visibly bend them.
- Keep black dominant: the fold is drawn as thin coloured filaments over the
  black body (palette warm/cool for `c1p`/`c2p`, foreground for crossings),
  with the same coverage gate the previous acrylic used (`black`).
- Add a `fold` knob (0 = off, today's plain pool; 1 = full reference look).

### Acceptance

- Simulation unchanged in behaviour: the probe's wake assertion still passes,
  collisions still unit-tested, and CPU stays in the same ballpark.
- A still frame resembles the reference's folded flow; moving a window drags
  and folds it.
- Update this doc, `README.md` (effect row + `[acrylic]` config) and the probe
  in the same commit as the code.
