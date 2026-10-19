//! Host-side view of the shared f64 effect clock.
//!
//! The implementation lives in the SDK (`sdk/hg_clock.zig`) so a component
//! effect and a built-in share the exact same code. This module re-exports
//! it; the built-ins import it as `clock`, components import it as
//! `hg_clock.zig` (staged next to their source by the compile-on-load path).

const hg_clock = @import("hg_clock");

pub const phase = hg_clock.phase;
pub const cycles = hg_clock.cycles;
