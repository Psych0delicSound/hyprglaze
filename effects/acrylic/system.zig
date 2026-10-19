//! Liquid-particle physics for the acrylic effect.
//!
//! Adapted from `effects/particles/system.zig` (substepped XPBD — Macklin et
//! al., "Small Steps in Physics Simulation", 2019). The solver is the same:
//! each frame splits into substeps, projects contacts out of penetration
//! (screen walls, window rects, other particles), derives velocity from the
//! corrected positions, then runs a velocity pass.
//!
//! What makes it a *liquid* rather than the particles effect:
//!   * no magnetic attraction — neither the focused-window gravity well nor
//!     the cursor push is applied; the pool is only stirred by its own
//!     inertia, a very slow ambient current, and the windows;
//!   * near-zero restitution and friction, so a dense packing flows and a
//!     moving window pushes a pressure wave through it instead of batting
//!     individual balls;
//!   * no impact "pops" (a liquid does not burst into rings).
//!
//! Windows are kinematic colliders: infinite mass, their rect interpolated
//! across the frame's substeps, each point carrying the velocity of the edges
//! around it. A window moving through the pool is the leaf on the water.

const std = @import("std");

pub const max_balls = 480;
pub const max_colliders = 32;
/// Accent slots a particle's `color` can address (0..accent_slots-1);
/// `color == -1` is the dominant theme-black liquid.
pub const accent_slots = 6;

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Ball = struct {
    x: [2]f32,
    v: [2]f32,
    r: f32,
    inv_mass: f32,
    /// -1 = theme black (the bulk of the liquid), else an accent slot.
    color: i8,
};

/// A window as the solver sees it: its rect at the start and end of the
/// frame. `moving` false means its displacement is not its own (a workspace
/// slide's camera, or the frame it appeared): it still blocks, but imparts no
/// velocity.
pub const Collider = struct {
    from: Rect,
    to: Rect,
    moving: bool,
};

pub const Params = struct {
    substeps: u32 = 6,
    /// Slow ambient current acceleration (px/s²); keeps the pool alive
    /// without any attraction.
    current: f32 = 16.0,
    /// Linear drag, 1/s — the liquid's viscosity.
    drag: f32 = 0.55,
    restitution: f32 = 0.02,
    wall_restitution: f32 = 0.04,
    friction: f32 = 0.03,
    /// Approach speeds below this rest instead of bouncing.
    rest_speed: f32 = 40.0,
    /// Box2D's maxLinearCorrection: the most a contact may push a ball per
    /// substep. A window that opens on top of the pool slides particles out
    /// over a few frames instead of teleporting them.
    max_correction: f32 = 4.0,
    max_speed: f32 = 3000.0,
};

const Contact = struct {
    a: u16,
    /// Other ball, or none for a wall/window.
    b: ?u16,
    n: [2]f32, // unit, pointing toward `a`
    /// Obstacle velocity at the contact point (walls/windows).
    wall_v: [2]f32,
    /// The contact began this substep.
    fresh: bool,
};

const max_contacts = 8192;

// Contact persistence, one bit per (ball, obstacle) and (ball, ball),
// double-buffered across substeps. Obstacles: the 4 screen walls, then
// colliders by index.
const pair_words = (max_balls + 63) / 64;
const Touching = struct {
    obstacle: [max_balls]u64 = [_]u64{0} ** max_balls,
    pair: [max_balls][pair_words]u64 = [_][pair_words]u64{[_]u64{0} ** pair_words} ** max_balls,
};

pub const ParticleSystem = struct {
    balls: [max_balls]Ball = undefined,
    count: u32,
    width: f32,
    height: f32,
    params: Params = .{},
    rng: std.Random.DefaultPrng,

    contacts: [max_contacts]Contact = undefined,
    contact_count: usize = 0,
    touch: [2]Touching = .{ .{}, .{} },
    touch_cur: u1 = 0,
    // Velocity before the position pass, per ball, for restitution.
    v_pre: [max_balls][2]f32 = undefined,

    /// Seed the pool on a jittered grid across the whole surface. `radius` is
    /// the particle radius in px; `black_frac` is the share that is theme
    /// black (the rest pick an accent slot), so black stays the bulk colour.
    pub fn init(
        count: u32,
        width: f32,
        height: f32,
        radius: f32,
        black_frac: f32,
    ) ParticleSystem {
        var sys = ParticleSystem{
            .count = @min(count, max_balls),
            .width = width,
            .height = height,
            .rng = std.Random.DefaultPrng.init(0x5EED_C0FFEE),
        };
        const rand = sys.rng.random();
        const n = sys.count;
        if (n == 0) return sys;

        const aspect = width / @max(height, 1.0);
        const cols: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(n)) * aspect)))));
        const rows: u32 = (n + cols - 1) / cols;
        const dx = width / @as(f32, @floatFromInt(cols));
        const dy = height / @as(f32, @floatFromInt(rows));

        for (0..n) |i| {
            const col: u32 = @intCast(i % cols);
            const row: u32 = @intCast(i / cols);
            const jx = (rand.float(f32) - 0.5) * dx * 0.35;
            const jy = (rand.float(f32) - 0.5) * dy * 0.35;
            const rr = radius * (0.9 + rand.float(f32) * 0.2);
            const x = std.math.clamp(
                (@as(f32, @floatFromInt(col)) + 0.5) * dx + jx,
                rr,
                @max(width - rr, rr),
            );
            const y = std.math.clamp(
                (@as(f32, @floatFromInt(row)) + 0.5) * dy + jy,
                rr,
                @max(height - rr, rr),
            );
            const accent = rand.float(f32) >= black_frac;
            sys.balls[i] = .{
                .x = .{ x, y },
                .v = .{ 0, 0 },
                .r = rr,
                .inv_mass = 1.0 / (rr * rr),
                .color = if (accent) @intCast(rand.intRangeAtMost(u8, 0, accent_slots - 1)) else -1,
            };
        }
        return sys;
    }

    /// Advance one frame of `dt` seconds. `time` drives the ambient current.
    pub fn step(self: *ParticleSystem, dt: f32, time: f64, colliders: []const Collider) void {
        if (dt <= 0) return;
        const n: u32 = @max(self.params.substeps, 1);
        const h = dt / @as(f32, @floatFromInt(n));
        const ncol = @min(colliders.len, max_colliders);

        for (0..n) |s| {
            const t1 = @as(f32, @floatFromInt(s + 1)) / @as(f32, @floatFromInt(n));

            // ---- integrate external accelerations ----
            const decay = @exp(-self.params.drag * h);
            var prev: [max_balls][2]f32 = undefined;
            for (self.balls[0..self.count], 0..) |*b, i| {
                const a = self.currentAccel(b.x, time);
                b.v[0] = (b.v[0] + a[0] * h) * decay;
                b.v[1] = (b.v[1] + a[1] * h) * decay;
                self.v_pre[i] = b.v;
                prev[i] = b.x;
                b.x[0] += b.v[0] * h;
                b.x[1] += b.v[1] * h;
            }

            // ---- position pass: project contacts ----
            self.contact_count = 0;
            self.touch_cur ^= 1;
            self.touch[self.touch_cur] = .{};
            for (self.balls[0..self.count], 0..) |*b, i| {
                self.solveWalls(b, @intCast(i));
                for (colliders[0..ncol], 0..) |col, k| self.solveWindow(b, @intCast(i), @intCast(4 + k), col, t1, dt, h);
            }
            self.solvePairs();

            // ---- velocities from positions, then the velocity pass ----
            for (self.balls[0..self.count], 0..) |*b, i| {
                b.v = .{ (b.x[0] - prev[i][0]) / h, (b.x[1] - prev[i][1]) / h };
            }
            self.velocityPass();

            for (self.balls[0..self.count]) |*b| {
                const sp = @sqrt(b.v[0] * b.v[0] + b.v[1] * b.v[1]);
                if (sp > self.params.max_speed) {
                    const k = self.params.max_speed / sp;
                    b.v = .{ b.v[0] * k, b.v[1] * k };
                }
            }
        }
    }

    /// A very slow, divergence-free-ish swirl so a calm pool still breathes.
    /// This is not an attraction: it has no centre and no cursor term.
    fn currentAccel(self: *const ParticleSystem, x: [2]f32, time: f64) [2]f32 {
        const amp = self.params.current;
        if (amp <= 0) return .{ 0, 0 };
        const k = 1.3 / @max(self.height, 1.0);
        const t = @as(f32, @floatCast(time));
        return .{
            amp * @sin(x[1] * k + t * 0.55),
            amp * @cos(x[0] * k * 0.9 - t * 0.47),
        };
    }

    fn addContact(self: *ParticleSystem, c: Contact) void {
        if (self.contact_count >= max_contacts) return;
        self.contacts[self.contact_count] = c;
        self.contact_count += 1;
    }

    /// Mark ball `a` touching obstacle `ob` this substep; true if it was
    /// not touching it the substep before.
    fn touchObstacle(self: *ParticleSystem, a: u16, ob: u6) bool {
        const bit = @as(u64, 1) << ob;
        self.touch[self.touch_cur].obstacle[a] |= bit;
        return self.touch[self.touch_cur ^ 1].obstacle[a] & bit == 0;
    }

    fn touchPair(self: *ParticleSystem, a: u16, b: u16) bool {
        const w = b / 64;
        const bit = @as(u64, 1) << @intCast(b % 64);
        self.touch[self.touch_cur].pair[a][w] |= bit;
        return self.touch[self.touch_cur ^ 1].pair[a][w] & bit == 0;
    }

    fn wallContact(self: *ParticleSystem, i: u16, ob: u6, n: [2]f32) void {
        self.addContact(.{ .a = i, .b = null, .n = n, .wall_v = .{ 0, 0 }, .fresh = self.touchObstacle(i, ob) });
    }

    fn solveWalls(self: *ParticleSystem, b: *Ball, i: u16) void {
        const r = b.r;
        if (b.x[0] < r) {
            b.x[0] = r;
            self.wallContact(i, 0, .{ 1, 0 });
        } else if (b.x[0] > self.width - r) {
            b.x[0] = self.width - r;
            self.wallContact(i, 1, .{ -1, 0 });
        }
        if (b.x[1] < r) {
            b.x[1] = r;
            self.wallContact(i, 2, .{ 0, 1 });
        } else if (b.x[1] > self.height - r) {
            b.x[1] = self.height - r;
            self.wallContact(i, 3, .{ 0, -1 });
        }
    }

    /// Ball against a window's rect at substep fraction `t`: signed
    /// distance to the box, pushed out along its gradient.
    fn solveWindow(self: *ParticleSystem, b: *Ball, i: u16, ob: u6, col: Collider, t: f32, dt: f32, h: f32) void {
        const rect = lerpRect(col.from, col.to, t);
        if (rect.w < 1 or rect.h < 1) return;
        const hx = rect.w * 0.5;
        const hy = rect.h * 0.5;
        const px = b.x[0] - (rect.x + hx);
        const py = b.x[1] - (rect.y + hy);
        const qx = @abs(px) - hx;
        const qy = @abs(py) - hy;
        // Cheap reject before the square root.
        if (qx > b.r or qy > b.r) return;

        var dist: f32 = undefined;
        var nrm: [2]f32 = undefined;
        if (qx > 0 and qy > 0) {
            // Outside a corner: the rounded part of the expanded box.
            dist = @sqrt(qx * qx + qy * qy);
            if (dist >= b.r) return;
            nrm = .{ sgn(px) * qx / dist, sgn(py) * qy / dist };
        } else if (qx > qy) {
            dist = qx; // beside (or inside, nearest) a vertical edge
            nrm = .{ sgn(px), 0 };
        } else {
            dist = qy;
            nrm = .{ 0, sgn(py) };
        }
        const depth = b.r - dist;
        if (depth <= 0) return;

        // Velocity of the rect at the contact point: each coordinate
        // interpolates between the velocities of the two edges bounding it.
        var wv: [2]f32 = .{ 0, 0 };
        if (col.moving and dt > 0) {
            const u = std.math.clamp((b.x[0] - rect.x) / rect.w, 0.0, 1.0);
            const v = std.math.clamp((b.x[1] - rect.y) / rect.h, 0.0, 1.0);
            const vl = (col.to.x - col.from.x) / dt;
            const vr = ((col.to.x + col.to.w) - (col.from.x + col.from.w)) / dt;
            const vb = (col.to.y - col.from.y) / dt;
            const vt = ((col.to.y + col.to.h) - (col.from.y + col.from.h)) / dt;
            wv = .{ vl + (vr - vl) * u, vb + (vt - vb) * v };
        }

        // The correction cap is for overlap that was already there (a
        // window opening on the pool). An edge advancing into a particle may
        // always push it the full distance it advanced this substep.
        const advance = @max(wv[0] * nrm[0] + wv[1] * nrm[1], 0) * h;
        const push = @min(depth, self.params.max_correction + advance);
        b.x[0] += nrm[0] * push;
        b.x[1] += nrm[1] * push;
        self.addContact(.{ .a = i, .b = null, .n = nrm, .wall_v = wv, .fresh = self.touchObstacle(i, ob) });
    }

    fn solvePairs(self: *ParticleSystem) void {
        var i: u16 = 0;
        while (i < self.count) : (i += 1) {
            var j: u16 = i + 1;
            while (j < self.count) : (j += 1) {
                const a = &self.balls[i];
                const b = &self.balls[j];
                const dx = a.x[0] - b.x[0];
                const dy = a.x[1] - b.x[1];
                const rr = a.r + b.r;
                if (@abs(dx) >= rr or @abs(dy) >= rr) continue;
                const d2 = dx * dx + dy * dy;
                if (d2 >= rr * rr) continue;
                const d = @sqrt(d2);
                const nrm: [2]f32 = if (d > 1e-4) .{ dx / d, dy / d } else .{ 1, 0 };
                const depth = @min(rr - d, self.params.max_correction);
                const wsum = a.inv_mass + b.inv_mass;
                const ka = depth * a.inv_mass / wsum;
                const kb = depth * b.inv_mass / wsum;
                a.x[0] += nrm[0] * ka;
                a.x[1] += nrm[1] * ka;
                b.x[0] -= nrm[0] * kb;
                b.x[1] -= nrm[1] * kb;
                self.addContact(.{ .a = i, .b = j, .n = nrm, .wall_v = .{ 0, 0 }, .fresh = self.touchPair(i, j) });
            }
        }
    }

    /// Restitution and friction on this substep's contacts, relative to
    /// whatever the particle touched.
    fn velocityPass(self: *ParticleSystem) void {
        const p = self.params;
        for (self.contacts[0..self.contact_count]) |ct| {
            const a = &self.balls[ct.a];
            const n = ct.n;
            if (ct.b) |bi| {
                const b = &self.balls[bi];
                const vrel = .{ a.v[0] - b.v[0], a.v[1] - b.v[1] };
                const vn = vrel[0] * n[0] + vrel[1] * n[1];
                const pre = self.v_pre[ct.a];
                const pre_b = self.v_pre[bi];
                const vn_pre = (pre[0] - pre_b[0]) * n[0] + (pre[1] - pre_b[1]) * n[1];
                const target: f32 = if (ct.fresh and -vn_pre > p.rest_speed) -p.restitution * vn_pre else 0;
                const dvn = target - vn;
                const wsum = a.inv_mass + b.inv_mass;
                var dv = .{ n[0] * dvn, n[1] * dvn };
                // Coulomb-style friction, bounded by the normal change.
                const vt = .{ vrel[0] - n[0] * vn, vrel[1] - n[1] * vn };
                const vtl = @sqrt(vt[0] * vt[0] + vt[1] * vt[1]);
                if (vtl > 1e-3) {
                    const k = @min(p.friction * @abs(dvn), vtl) / vtl;
                    dv[0] -= vt[0] * k;
                    dv[1] -= vt[1] * k;
                }
                a.v[0] += dv[0] * a.inv_mass / wsum;
                a.v[1] += dv[1] * a.inv_mass / wsum;
                b.v[0] -= dv[0] * b.inv_mass / wsum;
                b.v[1] -= dv[1] * b.inv_mass / wsum;
            } else {
                const wv = ct.wall_v;
                const vrel = .{ a.v[0] - wv[0], a.v[1] - wv[1] };
                const vn = vrel[0] * n[0] + vrel[1] * n[1];
                const pre = self.v_pre[ct.a];
                const vn_pre = (pre[0] - wv[0]) * n[0] + (pre[1] - wv[1]) * n[1];
                const target: f32 = if (ct.fresh and -vn_pre > p.rest_speed) -p.wall_restitution * vn_pre else 0;
                // Never pull a particle back into the obstacle.
                const dvn = @max(target - vn, -vn);
                var dv = .{ n[0] * dvn, n[1] * dvn };
                const vt = .{ vrel[0] - n[0] * vn, vrel[1] - n[1] * vn };
                const vtl = @sqrt(vt[0] * vt[0] + vt[1] * vt[1]);
                if (vtl > 1e-3) {
                    const k = @min(p.friction * @abs(dvn), vtl) / vtl;
                    dv[0] -= vt[0] * k;
                    dv[1] -= vt[1] * k;
                }
                a.v[0] += dv[0];
                a.v[1] += dv[1];
            }
        }
    }
};

/// Sign that never returns 0, so a particle dead centre in a rect still has a
/// way out.
fn sgn(x: f32) f32 {
    return if (x < 0) -1.0 else 1.0;
}

fn lerpRect(a: Rect, b: Rect, t: f32) Rect {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
        .w = a.w + (b.w - a.w) * t,
        .h = a.h + (b.h - a.h) * t,
    };
}

// --- Tests ---

fn oneBall(x: [2]f32, v: [2]f32) ParticleSystem {
    var sys = ParticleSystem.init(0, 1000, 1000, 10, 1.0);
    sys.count = 1;
    sys.balls[0] = .{ .x = x, .v = v, .r = 10, .inv_mass = 0.01, .color = -1 };
    sys.params.drag = 0;
    sys.params.current = 0;
    return sys;
}

test "a fast particle bounces off a window instead of tunnelling through it" {
    var sys = oneBall(.{ 100, 500 }, .{ 3000, 0 });
    const win = Rect{ .x = 300, .y = 300, .w = 60, .h = 400 };
    const cols = [_]Collider{.{ .from = win, .to = win, .moving = false }};
    // 200px to the window at 3000px/s: hit within 4 frames, then away.
    for (0..8) |_| sys.step(1.0 / 60.0, 0, &cols);
    try std.testing.expect(sys.balls[0].x[0] < 300);
    try std.testing.expect(sys.balls[0].v[0] < 0);
}

test "a moving window pushes a resting particle ahead of it" {
    var sys = oneBall(.{ 290, 500 }, .{ 0, 0 });
    const a = Rect{ .x = 300, .y = 300, .w = 200, .h = 400 };
    const b = Rect{ .x = 280, .y = 300, .w = 200, .h = 400 };
    const cols = [_]Collider{.{ .from = a, .to = b, .moving = true }};
    sys.step(1.0 / 60.0, 0, &cols);
    // Window moving left at 1200px/s: the particle leaves with it.
    try std.testing.expect(sys.balls[0].v[0] < -600);
    try std.testing.expect(sys.balls[0].x[0] <= 270.5);
}

test "the pool stays inside the screen" {
    var sys = ParticleSystem.init(120, 800, 600, 20, 0.85);
    for (0..120) |_| sys.step(1.0 / 60.0, 1.0, &.{});
    for (sys.balls[0..sys.count]) |b| {
        try std.testing.expect(b.x[0] >= b.r - 0.01 and b.x[0] <= 800 - b.r + 0.01);
        try std.testing.expect(b.x[1] >= b.r - 0.01 and b.x[1] <= 600 - b.r + 0.01);
    }
}
