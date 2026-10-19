//! 2D laser ray tracing: a beam fired from a point reflects specularly off
//! window rects and the screen's edges (a mirrored box), losing a fixed
//! fraction of its intensity at every bounce until it is too faint to see.
//!
//! Each leg is a ray-vs-AABB test (the slab method) against every window,
//! plus the exit from the screen box; the nearest hit wins and the beam
//! reflects about that face's normal: r = d - 2(d.n)n, which for axis-
//! aligned faces just flips one component (both at an exact corner).

const std = @import("std");

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub const Segment = struct {
    a: [2]f32,
    b: [2]f32,
    /// Beam intensity along this leg, 1 on the first.
    intensity: f32,
};

/// Hits closer than this are the surface just left; ignoring them keeps a
/// reflected ray from re-hitting its own face.
const eps: f32 = 1e-3;
/// Two faces hit within this distance of each other are a corner.
const corner_eps: f32 = 1e-3;

const Hit = struct { t: f32, flip_x: bool, flip_y: bool };

/// Trace the beam from `origin` along `dir` inside the screen box
/// [0,width] x [0,height]. Fills `out` with its legs and returns how many:
/// it stops when the intensity falls below `min_intensity` or `out` is full.
pub fn trace(
    origin: [2]f32,
    dir_in: [2]f32,
    width: f32,
    height: f32,
    windows: []const Rect,
    falloff: f32,
    min_intensity: f32,
    out: []Segment,
) usize {
    const len = @sqrt(dir_in[0] * dir_in[0] + dir_in[1] * dir_in[1]);
    if (len < 1e-6) return 0;
    var d: [2]f32 = .{ dir_in[0] / len, dir_in[1] / len };
    var p = origin;
    var intensity: f32 = 1.0;
    var n: usize = 0;

    while (n < out.len and intensity >= min_intensity) {
        var best = screenExit(p, d, width, height);
        for (windows) |r| {
            if (r.w < 1 or r.h < 1) continue;
            // A beam starting under a window passes beneath it: a window is
            // a mirror only from outside.
            if (p[0] > r.x + eps and p[0] < r.x + r.w - eps and
                p[1] > r.y + eps and p[1] < r.y + r.h - eps) continue;
            if (rayRect(p, d, r)) |h| {
                if (h.t < best.t) best = h;
            }
        }
        if (!std.math.isFinite(best.t)) break;
        const q: [2]f32 = .{ p[0] + d[0] * best.t, p[1] + d[1] * best.t };
        out[n] = .{ .a = p, .b = q, .intensity = intensity };
        n += 1;
        if (best.flip_x) d[0] = -d[0];
        if (best.flip_y) d[1] = -d[1];
        p = q;
        intensity *= falloff;
    }
    return n;
}

/// Where the ray leaves the screen box, flipping whichever component(s)
/// hit a wall.
fn screenExit(p: [2]f32, d: [2]f32, width: f32, height: f32) Hit {
    const inf = std.math.inf(f32);
    const tx: f32 = if (d[0] > 0) (width - p[0]) / d[0] else if (d[0] < 0) -p[0] / d[0] else inf;
    const ty: f32 = if (d[1] > 0) (height - p[1]) / d[1] else if (d[1] < 0) -p[1] / d[1] else inf;
    const t = @max(@min(tx, ty), 0);
    return .{
        .t = t,
        .flip_x = @abs(tx - t) <= corner_eps,
        .flip_y = @abs(ty - t) <= corner_eps,
    };
}

/// Slab-method entry into rect `r` from outside, or null on a miss.
fn rayRect(p: [2]f32, d: [2]f32, r: Rect) ?Hit {
    const inf = std.math.inf(f32);
    var tx0: f32 = -inf;
    var tx1: f32 = inf;
    if (d[0] != 0) {
        const a = (r.x - p[0]) / d[0];
        const b = (r.x + r.w - p[0]) / d[0];
        tx0 = @min(a, b);
        tx1 = @max(a, b);
    } else if (p[0] < r.x or p[0] > r.x + r.w) return null;
    var ty0: f32 = -inf;
    var ty1: f32 = inf;
    if (d[1] != 0) {
        const a = (r.y - p[1]) / d[1];
        const b = (r.y + r.h - p[1]) / d[1];
        ty0 = @min(a, b);
        ty1 = @max(a, b);
    } else if (p[1] < r.y or p[1] > r.y + r.h) return null;

    const t_enter = @max(tx0, ty0);
    const t_exit = @min(tx1, ty1);
    if (t_enter > t_exit or t_enter <= eps) return null;
    // The slab entered last is the face hit; both at once is a corner.
    return .{
        .t = t_enter,
        .flip_x = tx0 >= ty0 - corner_eps,
        .flip_y = ty0 >= tx0 - corner_eps,
    };
}

// --- Tests ---

fn approx(a: [2]f32, b: [2]f32) !void {
    try std.testing.expectApproxEqAbs(b[0], a[0], 0.01);
    try std.testing.expectApproxEqAbs(b[1], a[1], 0.01);
}

test "a beam reflects off a window face and dims" {
    var out: [8]Segment = undefined;
    const win = [_]Rect{.{ .x = 400, .y = 0, .w = 100, .h = 1000 }};
    // From (100,100) heading +x: hits the window's left face at x=400.
    const n = trace(.{ 100, 100 }, .{ 1, 0 }, 1000, 1000, &win, 0.5, 0.2, &out);
    try approx(out[0].b, .{ 400, 100 });
    try std.testing.expectEqual(@as(f32, 1.0), out[0].intensity);
    // Straight back to the screen's left edge, at half intensity.
    try approx(out[1].b, .{ 0, 100 });
    try std.testing.expectEqual(@as(f32, 0.5), out[1].intensity);
    // 1, 0.5, 0.25 — the next would fall below 0.2.
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "angle in equals angle out" {
    var out: [2]Segment = undefined;
    const win = [_]Rect{.{ .x = 0, .y = 500, .w = 1000, .h = 100 }};
    // 45 degrees up from (100,100) meets the window's bottom face at y=500.
    _ = trace(.{ 100, 100 }, .{ 1, 1 }, 1000, 1000, &win, 0.9, 0.01, &out);
    try approx(out[0].b, .{ 500, 500 });
    // Reflected down-right: 500 more to the floor, landing at (1000, 0).
    try approx(out[1].b, .{ 1000, 0 });
}

test "the screen is a mirrored box, corners flip both components" {
    var out: [2]Segment = undefined;
    _ = trace(.{ 0, 0 }, .{ 1, 1 }, 500, 500, &.{}, 0.9, 0.01, &out);
    try approx(out[0].b, .{ 500, 500 });
    // Straight back out of the corner it went into.
    try approx(out[1].b, .{ 0, 0 });
}

test "a beam starting under a window passes beneath it" {
    var out: [2]Segment = undefined;
    const win = [_]Rect{.{ .x = 0, .y = 0, .w = 300, .h = 300 }};
    _ = trace(.{ 10, 10 }, .{ 1, 0 }, 1000, 1000, &win, 0.9, 0.01, &out);
    try approx(out[0].b, .{ 1000, 10 });
}

test "a beam grazing past a window misses it" {
    var out: [1]Segment = undefined;
    const win = [_]Rect{.{ .x = 400, .y = 200, .w = 100, .h = 100 }};
    _ = trace(.{ 0, 100 }, .{ 1, 0 }, 1000, 1000, &win, 0.9, 0.01, &out);
    try approx(out[0].b, .{ 1000, 100 });
}
