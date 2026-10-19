//! effects/acrylic — a viscous, theme-black liquid driven by a GPU flow field.
//!
//! The surface is a velocity field that lives on the GPU in a ping-pong pair of
//! `hg_gl.Target`s. Each frame a fragment pass self-advects it
//! (semi-Lagrangian), then adds the drives:
//!
//!   * **windows** — a moving rect drags the fluid inside it and pushes a
//!     little ahead of its leading edge, so the field bends around it;
//!   * **off-screen sources** — a few broad vortices just outside the viewport
//!     sweep streams in from different directions, so the whole surface moves
//!     without a single uniform rotation;
//!   * **ambient curl noise** — a divergence-free whole-surface swirl;
//!   * **momentum** — a global current, a second-order spring-damper chasing a
//!     slowly rotating target (it overshoots, so the drift reverses);
//!   * **vorticity confinement** — keeps shear layers curling into eddies;
//!   * **viscosity** — an exponential decay that bleeds motion away.
//!
//! A second ping-pong pair carries a single **warp phase** (R). It is advected
//! by the flow and relaxed toward a smooth base field. It is not paint: the
//! display uses it to offset a procedural band coordinate, so a moving window
//! drags the bands into a wake that lingers after the flow itself has relaxed.
//!
//! The native layer is therefore procedural: it samples the local flow
//! direction and lays long, sinuous Balatro-style contour bands along it. Black
//! is the broad, low-contrast body; blue is a narrow vein system; white is a
//! rare thin core inside a blue vein. Nothing colour-like is advected, so the
//! bands keep crisp edges instead of diffusing into a haze.
//!
//! Windows arrive as `hg_frame` rects; this component tracks previous rects to
//! derive each window's velocity. There is no particle simulation.

const std = @import("std");

const hg = @import("hg.zig");
const hg_gl = @import("hg_gl.zig");

const c = hg.c;
const gl = hg.gl;

const log = std.log.scoped(.acrylic);

const max_windows = 32;

/// Velocity is stored in px/s in a half-float target; this is only the display
/// full-brightness reference.
const display_scale: f32 = 400.0;

/// The flow pass: self-advect, then add windows, ambient curl noise, vorticity
/// confinement, momentum and viscosity.
const flow_frag_src: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uPrev;
    \\uniform vec2 uRes;
    \\uniform vec2 uOut;        // output resolution, for advection in uv
    \\uniform float uDt;        // seconds
    \\uniform float uTime;
    \\uniform vec2 uMomentum;   // px/s, already integrated
    \\uniform float uVisc;      // 1/s decay
    \\uniform float uForce;     // window drag strength
    \\uniform float uAmbient;   // curl-noise force strength
    \\uniform float uVort;      // vorticity confinement strength
    \\uniform int uSources;     // a few broad vortices just off-screen
    \\uniform float uSource;    // their strength
    \\uniform vec2 uAspect;
    \\uniform int uWinCount;
    \\uniform vec4 uWin[32];    // uv rect: lo.xy, size.zw
    \\uniform vec2 uWinVel[32]; // px/s
    \\out vec4 fragColor;
    \\
    \\float hash21(vec2 p) {
    \\    p = fract(p * vec2(234.34, 435.345));
    \\    p += dot(p, p + 34.23);
    \\    return fract(p.x * p.y);
    \\}
    \\float vnoise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    vec2 u = f * f * (3.0 - 2.0 * f);
    \\    float a = hash21(i);
    \\    float b = hash21(i + vec2(1.0, 0.0));
    \\    float c = hash21(i + vec2(0.0, 1.0));
    \\    float d = hash21(i + vec2(1.0, 1.0));
    \\    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    \\}
    \\float fbm(vec2 p) {
    \\    float v = 0.0;
    \\    float a = 0.55;
    \\    for (int i = 0; i < 3; i++) {
    \\        v += a * vnoise(p);
    \\        p = mat2(1.6, 1.2, -1.2, 1.6) * p;
    \\        a *= 0.55;
    \\    }
    \\    return v;
    \\}
    \\
    \\// A divergence-free ambient swirl: the curl of a slowly drifting noise
    \\// potential, so the whole surface flows in varied directions.
    \\vec2 ambientForce(vec2 uv) {
    \\    vec2 q = uv * uAspect * 3.0;
    \\    float t = uTime * 0.06;
    \\    float e = 0.14;
    \\    float dx = fbm(q + vec2(e, 0.0) + vec2(t, -t * 0.7)) - fbm(q - vec2(e, 0.0) + vec2(t, -t * 0.7));
    \\    float dy = fbm(q + vec2(0.0, e) + vec2(t, -t * 0.7)) - fbm(q - vec2(0.0, e) + vec2(t, -t * 0.7));
    \\    return vec2(dy, -dx) / (2.0 * e);
    \\}
    \\
    \\float curlAt(vec2 uv) {
    \\    vec2 e = 1.0 / uRes;
    \\    float dvdx = texture(uPrev, uv + vec2(e.x, 0.0)).y - texture(uPrev, uv - vec2(e.x, 0.0)).y;
    \\    float dudy = texture(uPrev, uv + vec2(0.0, e.y)).x - texture(uPrev, uv - vec2(0.0, e.y)).x;
    \\    return dvdx / (2.0 * e.x) - dudy / (2.0 * e.y);
    \\}
    \\
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy / uRes;
    \\    vec2 vel = texture(uPrev, uv).xy;
    \\
    \\    // Semi-Lagrangian self-advection: look back along the flow.
    \\    vec2 back = uv - vel * uDt / uOut;
    \\    vel = texture(uPrev, back).xy;
    \\
    \\    // Ambient curl noise: a whole-surface swirl so the pool is never static.
    \\    vel += ambientForce(uv) * (uAmbient * 900.0) * uDt;
    \\
    \\    // A handful of broad vortices just outside the screen. They sit at
    \\    // different angles and alternate rotation, and each also pushes a
    \\    // little inward, so streams enter from different directions and meet.
    \\    for (int i = 0; i < uSources; i++) {
    \\        float fi = float(i);
    \\        float count = max(float(uSources), 1.0);
    \\        float a = (fi + 0.5) / count * 6.28318 + uTime * 0.02;
    \\        float var = fract(sin(fi * 12.9898) * 43758.5453);
    \\        vec2 c = 0.5 + vec2(cos(a), sin(a)) * uAspect * (1.06 + 0.22 * var);
    \\        vec2 d = (uv - c) * uAspect;
    \\        float r2 = dot(d, d);
    \\        float f = exp(-r2 * 4.0);
    \\        float sgn = mod(fi, 2.0) < 0.5 ? 1.0 : -1.0;
    \\        vec2 perp = vec2(-d.y, d.x) / (sqrt(r2) + 0.08);
    \\        vec2 dir = normalize(-d);
    \\        float str = uSource * (0.6 + 0.8 * var);
    \\        vel += (perp * sgn + dir * 0.55) * str * uDt * f;
    \\    }
    \\
    \\    // Vorticity confinement: sharpen the curl into eddies that outlive it.
    \\    {
    \\        vec2 e = 1.0 / uRes;
    \\        float c0 = curlAt(uv);
    \\        float cx = curlAt(uv + vec2(e.x, 0.0)) - curlAt(uv - vec2(e.x, 0.0));
    \\        float cy = curlAt(uv + vec2(0.0, e.y)) - curlAt(uv - vec2(0.0, e.y));
    \\        vec2 n = vec2(cx, cy);
    \\        float nl = length(n);
    \\        if (nl > 1.0e-4) n /= nl;
    \\        vel += vec2(n.y, -n.x) * c0 * uVort * uDt;
    \\    }
    \\
    \\    // Global drift and viscosity.
    \\    vel += uMomentum * uDt;
    \\    vel *= exp(-uVisc * uDt);
    \\
    \\    // Windows: drag the fluid inside the rect and shear it at the edges.
    \\    for (int i = 0; i < uWinCount; i++) {
    \\        vec4 w = uWin[i];
    \\        vec2 lo = w.xy;
    \\        vec2 hi = w.xy + w.zw;
    \\        float inside = step(lo.x, uv.x) * step(uv.x, hi.x) *
    \\                       step(lo.y, uv.y) * step(uv.y, hi.y);
    \\        vel = mix(vel, uWinVel[i], inside);
    \\        // A soft band just outside pushes fluid ahead of a moving window.
    \\        vec2 d = max(lo - uv, uv - hi);
    \\        float outside = max(max(d.x, d.y), 0.0);
    \\        float band = (1.0 - inside) * exp(-outside * 16.0);
    \\        vel += uWinVel[i] * uForce * uDt * band;
    \\    }
    \\
    \\    fragColor = vec4(vel, 0.0, 1.0);
    \\}
;

/// Warp pass: advects a single scalar `w` (R) with the flow. `w` is not paint;
/// it is a phase offset for the procedural bands. It relaxes toward a smooth
/// base field so it keeps its structure, while a window drags it into a wake
/// that persists for a moment — the memory a memoryless band pattern lacks.
const dye_frag_src: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uVel;
    \\uniform sampler2D uPrev;
    \\uniform vec2 uRes;
    \\uniform vec2 uOut;
    \\uniform float uDt;
    \\uniform float uTime;
    \\uniform float uRelax;
    \\uniform vec2 uAspect;
    \\out vec4 fragColor;
    \\
    \\float hash21(vec2 p) {
    \\    p = fract(p * vec2(234.34, 435.345));
    \\    p += dot(p, p + 34.23);
    \\    return fract(p.x * p.y);
    \\}
    \\float vnoise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    vec2 u = f * f * (3.0 - 2.0 * f);
    \\    float a = hash21(i);
    \\    float b = hash21(i + vec2(1.0, 0.0));
    \\    float c = hash21(i + vec2(0.0, 1.0));
    \\    float d = hash21(i + vec2(1.0, 1.0));
    \\    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    \\}
    \\float fbm(vec2 p) {
    \\    float v = 0.0;
    \\    float a = 0.55;
    \\    for (int i = 0; i < 4; i++) {
    \\        v += a * vnoise(p);
    \\        p = mat2(1.6, 1.2, -1.2, 1.6) * p;
    \\        a *= 0.55;
    \\    }
    \\    return v;
    \\}
    \\
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy / uRes;
    \\    vec2 vel = texture(uVel, uv).xy;
    \\
    \\    // Advect the warp phase along the flow.
    \\    vec2 back = uv - vel * uDt / uOut;
    \\    float w = texture(uPrev, clamp(back, 0.0, 1.0)).r;
    \\
    \\    // Relax toward a slow smooth base field, so the warp keeps structure
    \\    // instead of diffusing away, and drifted dye cannot accumulate.
    \\    float base = fbm(uv * uAspect * 2.5 + vec2(uTime * 0.006, -uTime * 0.005));
    \\    w = mix(w, base, clamp(uRelax * uDt, 0.0, 1.0));
    \\
    \\    fragColor = vec4(clamp(w, 0.0, 1.0), 0.0, 0.0, 1.0);
    \\}
;

const State = struct {
    width: f32,
    height: f32,
    sim_w: i32,
    sim_h: i32,
    dye_w: i32,
    dye_h: i32,

    /// Ping-pong velocity field (RG = velocity px/s).
    vel: [2]hg_gl.Target = .{ .{}, .{} },
    cur: u1 = 0,
    /// Ping-pong warp field: a single advected phase in R.
    dye: [2]hg_gl.Target = .{ .{}, .{} },
    dye_cur: u1 = 0,
    flow_prog: hg_gl.Program = .{},
    dye_prog: hg_gl.Program = .{},
    gl_ready: bool = false,
    gl_failed: bool = false,

    viscosity: f32 = 1.5,
    momentum: f32 = 0.05,
    force: f32 = 18.0,
    ambient: f32 = 0.02,
    /// Single-scale confinement is grid-sensitive: keep it subtle until the
    /// multiscale version (flow-ref2) lands.
    vorticity: f32 = 0.02,
    sources: u32 = 4,
    source: f32 = 450.0,
    warp_relax: f32 = 0.15,

    // Global current: velocity and its phase (second-order so it overshoots).
    cur_vel: [2]f32 = .{ 0, 0 },
    cur_phase: [2]f32 = .{ 0, 0 },

    // Window rects (uv) and velocities (px/s), snapshotted for upload.
    win_count: usize = 0,
    win_rect: [max_windows][4]f32 = undefined,
    win_vel: [max_windows][2]f32 = undefined,

    prev_addr: [max_windows]u64 = [_]u64{0} ** max_windows,
    prev_rect: [max_windows][4]f32 = undefined,
    prev_count: usize = 0,

    now: f64 = 0,
    last_dt: f32 = 0,

    pu: hg.Uniforms(.{
        .prev = "uPrev",
        .res = "uRes",
        .out = "uOut",
        .dt = "uDt",
        .time = "uTime",
        .momentum = "uMomentum",
        .visc = "uVisc",
        .force = "uForce",
        .ambient = "uAmbient",
        .vort = "uVort",
        .sources = "uSources",
        .source = "uSource",
        .aspect = "uAspect",
        .count = "uWinCount",
        .win = "uWin[0]",
        .winvel = "uWinVel[0]",
    }) = .{},
    yu: hg.Uniforms(.{
        .vel = "uVel",
        .prev = "uPrev",
        .res = "uRes",
        .out = "uOut",
        .dt = "uDt",
        .time = "uTime",
        .relax = "uRelax",
        .aspect = "uAspect",
    }) = .{},
    du: hg.Uniforms(.{
        .vel = "iAcrFlowTex",
        .dye = "iAcrDyeTex",
        .active = "iAcrActive",
        .scale = "iAcrFlowScale",
    }) = .{},
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    const hp = hg.Host{ .raw = @ptrCast(host) };

    const state = hg.allocator.create(State) catch return null;

    // A quarter-resolution field is plenty for a smooth velocity map and keeps
    // the pass cheap at 4K.
    const scale = std.math.clamp(hp.getFloat("scale", 0.25), 0.1, 1.0);
    const sim_w: i32 = @intFromFloat(@max(32.0, @round(width * scale)));
    const sim_h: i32 = @intFromFloat(@max(32.0, @round(height * scale)));
    // Paint wants more detail than the velocity, so it runs at half the output
    // unless the user asks for less.
    const dscale = std.math.clamp(hp.getFloat("warp_scale", 0.75), scale, 1.0);
    const dye_w: i32 = @intFromFloat(@max(64.0, @round(width * dscale)));
    const dye_h: i32 = @intFromFloat(@max(64.0, @round(height * dscale)));

    state.* = .{
        .width = width,
        .height = height,
        .sim_w = sim_w,
        .sim_h = sim_h,
        .dye_w = dye_w,
        .dye_h = dye_h,
        .viscosity = std.math.clamp(hp.getFloat("viscosity", 1.5), 0.0, 8.0),
        .momentum = std.math.clamp(hp.getFloat("momentum", 0.05), 0.0, 3.0),
        .force = std.math.clamp(hp.getFloat("force", 18.0), 0.0, 40.0),
        .ambient = std.math.clamp(hp.getFloat("ambient", 0.02), 0.0, 4.0),
        .vorticity = std.math.clamp(hp.getFloat("vorticity", 0.02), 0.0, 0.2),
        .sources = @intCast(std.math.clamp(hp.getInt("sources", 4), 0, 8)),
        .source = std.math.clamp(hp.getFloat("source", 450.0), 0.0, 2000.0),
        .warp_relax = std.math.clamp(hp.getFloat("warp_relax", 0.15), 0.02, 8.0),
    };
    return @ptrCast(state);
}

/// Add `dt` to the second-order current and return the new velocity. Kept
/// second-order (a phase plus a velocity) so the drift can overshoot its
/// rotating target and gently reverse, as the liquid model asks.
fn stepCurrent(s: *State, dt: f32) void {
    const k: f32 = 0.30; // spring, 1/s²
    const damp: f32 = 0.42; // 1/s, under-damped
    const amp: f32 = 600.0 * s.momentum;
    const turn: f32 = 0.22; // rad/s
    const t: f32 = @floatCast(s.now);
    const target = [2]f32{ amp * @cos(t * turn), amp * @sin(t * turn) };
    const ax = (target[0] - s.cur_phase[0]) * k - s.cur_vel[0] * damp;
    const ay = (target[1] - s.cur_phase[1]) * k - s.cur_vel[1] * damp;
    s.cur_vel[0] += ax * dt;
    s.cur_vel[1] += ay * dt;
    s.cur_phase[0] += s.cur_vel[0] * dt;
    s.cur_phase[1] += s.cur_vel[1] * dt;
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);

    const dt = std.math.clamp(f.dt, 0.0, 0.05);
    s.now += dt;
    s.last_dt = dt;

    stepCurrent(s, dt);

    const n: usize = @intCast(@min(f.windows_len, max_windows));
    for (0..n) |i| {
        const w = f.windows[i];
        const to = [4]f32{ w.x, w.y, w.w, w.h };
        var from = to;
        var known = false;
        for (s.prev_addr[0..s.prev_count], s.prev_rect[0..s.prev_count]) |a, r| {
            if (a == w.address and a != 0) {
                from = r;
                known = true;
                break;
            }
        }
        // Rect in uv, snapped to the field grid edges.
        s.win_rect[i] = .{
            w.x / s.width,
            w.y / s.height,
            w.w / s.width,
            w.h / s.height,
        };
        if (known and dt > 0) {
            const cx = (to[0] + to[2] * 0.5) - (from[0] + from[2] * 0.5);
            const cy = (to[1] + to[3] * 0.5) - (from[1] + from[3] * 0.5);
            s.win_vel[i] = .{ cx / dt, cy / dt };
        } else {
            s.win_vel[i] = .{ 0, 0 };
        }

        s.prev_addr[i] = w.address;
        s.prev_rect[i] = to;
    }
    s.prev_count = n;
    s.win_count = n;
}

fn ensureGl(s: *State) bool {
    if (s.gl_ready) return true;
    if (s.gl_failed) return false;
    s.gl_failed = true;

    s.flow_prog = hg_gl.Program.init(flow_frag_src) catch {
        log.err("flow program failed", .{});
        return false;
    };
    s.dye_prog = hg_gl.Program.init(dye_frag_src) catch {
        log.err("warp program failed", .{});
        return false;
    };
    for (&s.vel) |*tg| {
        tg.* = hg_gl.Target.init(s.sim_w, s.sim_h, .{
            .format = .rgba16f,
            .half_float_fallback = true,
            .filter = .linear,
            .wrap = .clamp,
        }) catch return false;
    }
    for (&s.dye) |*tg| {
        tg.* = hg_gl.Target.init(s.dye_w, s.dye_h, .{
            .format = .rgba16f,
            .half_float_fallback = true,
            .filter = .linear,
            .wrap = .clamp,
        }) catch return false;
    }
    for (&s.vel) |*tg| {
        tg.begin();
        gl.glClearColor(0, 0, 0, 1);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    }
    for (&s.dye) |*tg| {
        tg.begin();
        gl.glClearColor(0, 0, 0, 0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    }
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);

    s.gl_failed = false;
    s.gl_ready = true;
    return true;
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    if (!ensureGl(s)) return;

    const prev = s.cur;
    const next = 1 - prev;

    s.vel[next].begin();
    s.pu.use(s.flow_prog.program);
    s.vel[prev].bindTexture(gl.GL_TEXTURE0);
    s.pu.int(.prev, 0);
    s.pu.f2(.res, @floatFromInt(s.sim_w), @floatFromInt(s.sim_h));
    s.pu.f2(.out, s.width, s.height);
    s.pu.f1(.dt, s.last_dt);
    s.pu.f1(.time, @floatCast(@mod(s.now, 3600.0)));
    s.pu.f2(.momentum, s.cur_vel[0], s.cur_vel[1]);
    s.pu.f1(.visc, s.viscosity);
    s.pu.f1(.force, s.force);
    s.pu.f1(.ambient, s.ambient);
    s.pu.f1(.vort, s.vorticity);
    s.pu.int(.sources, @intCast(s.sources));
    s.pu.f1(.source, s.source);
    s.pu.f2(.aspect, s.width / s.height, 1.0);
    s.pu.int(.count, @intCast(s.win_count));
    if (s.win_count > 0) {
        s.pu.f4v(.win, @intCast(s.win_count), &s.win_rect[0]);
        s.pu.f2v(.winvel, @intCast(s.win_count), &s.win_vel[0]);
    }
    s.flow_prog.draw();
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    s.cur = next;

    // --- warp pass: advect the band phase through the new velocity field ---
    const dprev = s.dye_cur;
    const dnext = 1 - dprev;
    s.dye[dnext].begin();
    s.yu.use(s.dye_prog.program);
    s.vel[next].bindTexture(gl.GL_TEXTURE0);
    s.yu.int(.vel, 0);
    s.dye[dprev].bindTexture(gl.GL_TEXTURE1);
    s.yu.int(.prev, 1);
    s.yu.f2(.res, @floatFromInt(s.dye_w), @floatFromInt(s.dye_h));
    s.yu.f2(.out, s.width, s.height);
    s.yu.f1(.dt, s.last_dt);
    s.yu.f1(.time, @floatCast(@mod(s.now, 3600.0)));
    s.yu.f1(.relax, s.warp_relax);
    s.yu.f2(.aspect, s.width / s.height, 1.0);
    s.dye_prog.draw();
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    s.dye_cur = dnext;

    s.du.use(program);
    s.vel[next].bindTexture(gl.GL_TEXTURE0);
    s.du.int(.vel, 0);
    s.dye[dnext].bindTexture(gl.GL_TEXTURE1);
    s.du.int(.dye, 1);
    s.du.f1(.active, 1.0);
    s.du.f1(.scale, display_scale);
    gl.glActiveTexture(gl.GL_TEXTURE0);
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    s.vel[0].deinit();
    s.vel[1].deinit();
    s.dye[0].deinit();
    s.dye[1].deinit();
    s.flow_prog.deinit();
    s.dye_prog.deinit();
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "acrylic",
    .shader = "acrylic.frag",
    .config_section = null,
    .wants_audio = 0,
    .create = create,
    .update = update,
    .upload = upload,
    .destroy = destroy,
};

export fn hg_module_entry() callconv(.c) *const c.hg_module {
    return &module;
}
