# Conventions

Rules that apply to any daemon, effect or component change.

- **GL state.** Effect `init()`/component `create()` must not touch GL (no
  current context is guaranteed); create GL objects on the first `upload`,
  delete/free in `deinit`/`destroy`. `deinit` must release everything,
  including background threads.
- **A component's `upload` runs before the host's main draw**, against the same
  context, so it must leave GL state the host expects — notably **blend off**.
  `destroy` runs with the creating context still current.
- **Frame data is borrowed.** `FrameState` slices (and `hg_frame` pointers) are
  valid only during `update`; copy anything an effect keeps. Also note the
  union update/setup contract in `src/effects.zig`.
- **Clocks.** Accumulate in `f64`; `f32` seconds stall after ~a day.
- **Errors surface as logs**, not exit codes — check the daemon's captured
  output (see `docs/agents/build.md`), not `$?`.
- **Config is hot-reloaded** via inotify (the watcher reinstalls itself after
  each reload, which recreates Hyprland's Lua VM).
- **Randomness.** Plugins cannot reach the host's io helper; a component that
  needs a seed takes a local `clock_gettime(CLOCK_MONOTONIC)` or uses
  `hg_frame.time`.
- **Tests.** Use `std.testing`; parser/transform coverage is high — add unit
  tests for pure logic, harness probes (`docs/agents/harness.md`) for
  compositor behavior.
