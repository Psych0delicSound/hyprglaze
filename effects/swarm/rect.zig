//! The window rectangle as the flock solver sees it (a slice of the SDK-free
//! `src/effects/particles/system.zig` Rect). Local to the swarm component.

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};
