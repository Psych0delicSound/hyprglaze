//! Host-side view of the shared geometry painter.
//!
//! The implementation lives in the SDK (`sdk/hg_geometry.zig`) so a component
//! effect and a built-in draw through the exact same code. This module
//! re-exports it; the built-ins import it as `geometry`, components import it
//! as `hg_geometry.zig` (staged next to their source by the compile-on-load
//! path).

const hg_geometry = @import("hg_geometry");

pub const Vertex = hg_geometry.Vertex;
pub const max_verts = hg_geometry.max_verts;
pub const Batch = hg_geometry.Batch;
pub const Painter = hg_geometry.Painter;
pub const Point = hg_geometry.Point;
pub const Points = hg_geometry.Points;
pub const PointPainter = hg_geometry.PointPainter;
pub const compileProgram = hg_geometry.compileProgram;
