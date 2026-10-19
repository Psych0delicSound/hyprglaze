//! effects/starfield — flight through a 3D starfield.
//!
//! Ported from the built-in `src/effects/starfield.zig` to the component ABI.
//! Stars live in a box ahead of the camera and stream toward it; each is
//! projected through the vanishing point and drawn into an offscreen layer as
//! soft geometry, a glow, a core and, moving fast, a streak back along its
//! path, the brightest near ones with diffraction spikes. The vanishing point
//! eases toward the cursor, so the cursor steers the ship, and the camera banks
//! into the turn. The main shader (starfield.frag) lays the star layer over a
//! nebula that zooms past forever and a fixed field of distant stars.
//!
//! Music pushes the cruise speed and every kick surges it; now and then, music
//! or not, the ship jumps to hyperspace for a few seconds.
//!
//! Structural changes from the built-in, beyond the ABI:
//!   * audio is host-captured — `hg.audio.Analyzer` runs on `hg_frame.wave`
//!     instead of owning a capture thread;
//!   * the star layer and the nebula are `hg_gl.Target`s and the nebula's
//!     program is an `hg_gl.Program` (no hand-rolled FBO/VAO);
//!   * the shared CPU→GL painter is `hg_geometry.zig` (the SDK copy);
//!   * config comes from the shared `[visualizer]` section (`config_section`),
//!     because `stars`/`jumps` and the audio knobs live there;
//!   * the RNG seeds from a local monotonic clock (a plugin can't reach the
//!     host's io helper).

const std = @import("std");

const hg = @import("hg.zig");
const hg_gl = @import("hg_gl.zig");
const geometry = @import("hg_geometry.zig");

const c = hg.c;
const gl = hg.gl;

/// Monotonic-clock nanoseconds, for seeding the RNG (a plugin cannot reach
/// the host's io helper).
const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk_id: i32, tp: *Timespec) c_int;

fn nowNs() u64 {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// The nebula is soft, so it renders at a quarter of the screen's size
// (sixteenth of the pixels) and the main shader scales it up.
const nebula_frag_src: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec2 uRes;
    \\uniform vec2 uVp;
    \\uniform float uRoll;
    \\uniform float uFlight;
    \\uniform vec3 uTint[3];
    \\out vec4 fragColor;
    \\
    \\float hash12(vec2 p) {
    \\    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    \\    p3 += dot(p3, p3.yzx + 33.33);
    \\    return fract((p3.x + p3.y) * p3.z);
    \\}
    \\float noise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x),
    \\               mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
    \\}
    \\float fbm(vec2 p) {
    \\    float v = 0.0;
    \\    float a = 0.5;
    \\    for (int i = 0; i < 5; i++) {
    \\        v += a * noise(p);
    \\        p = mat2(1.6, 1.2, -1.2, 1.6) * p;
    \\        a *= 0.5;
    \\    }
    \\    return v;
    \\}
    \\// One octave of zoom: domain-warped clouds with darker dust lanes.
    \\vec3 cloud(vec2 q) {
    \\    vec2 w = vec2(fbm(q * 1.7 + 3.1), fbm(q * 1.7 - 5.7));
    \\    float d = fbm(q * 2.2 + w * 1.4);
    \\    float lane = fbm(q * 4.0 - w);
    \\    d = smoothstep(0.42, 0.85, d) * (0.55 + 0.45 * smoothstep(0.3, 0.7, lane));
    \\    vec3 tint = mix(mix(uTint[0], uTint[1], smoothstep(0.3, 0.7, w.x)), uTint[2], smoothstep(0.55, 0.8, w.y) * 0.5);
    \\    return tint * d;
    \\}
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy / uRes;
    \\    vec2 p = (uv - uVp) * vec2(uRes.x / uRes.y, 1.0);
    \\    float cr = cos(-uRoll);
    \\    float sr = sin(-uRoll);
    \\    p = mat2(cr, sr, -sr, cr) * p;
    \\    // Two octaves cross-fading on a log-periodic cycle: it comes at us
    \\    // without end. 0.04 * 1000 is whole, so the flight wrap is seamless.
    \\    float s = fract(uFlight * 0.04);
    \\    vec3 neb = cloud(p * exp2(-s) * 1.3) * (1.0 - s) + cloud(p * exp2(1.0 - s) * 1.3) * s;
    \\    fragColor = vec4(neb, 1.0);
    \\}
;

const Star = struct {
    x: f32,
    y: f32,
    z: f32,
    /// Intrinsic brightness, 0..1, skewed dim: most stars are faint.
    mag: f32,
    /// 0 = the theme's foreground, else a chromatic slot.
    tint: u8,
    phase: f32,
};

const max_stars = 4000;
const near: f32 = 0.03;
const far: f32 = 1.0;
/// Projection scale, screen heights per unit at z = 1.
const focal: f32 = 0.45;
/// Half-extent of the star box across, in world units at any depth.
const spread: f32 = 1.6;

fn clamp(x: f32, lo: f32, hi: f32) f32 {
    return @min(@max(x, lo), hi);
}

const State = struct {
    music: hg.audio.Analyzer = .{},
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    count: usize,
    stars: []Star,

    verts: []geometry.Vertex,
    batch: geometry.Batch,
    point_verts: []geometry.Point,
    points: geometry.Points,

    painter: geometry.Painter = .{},
    point_painter: geometry.PointPainter = .{},
    /// The star layer, drawn at full size then sampled by the main shader.
    sprite: hg_gl.Target = .{},
    /// The nebula, drawn small and scaled up by the main shader.
    nebula: hg_gl.Target = .{},
    neb_prog: hg_gl.Program = .{},
    nu: hg.Uniforms(.{
        .res = "uRes",
        .vp = "uVp",
        .roll = "uRoll",
        .flight = "uFlight",
        .tint = "uTint[0]",
    }) = .{},
    gl_ready: bool = false,
    gl_failed: bool = false,

    u: hg.Uniforms(.{
        .sprite = "iSprite",
        .nebula = "iStarNebula",
        .vp = "iStarVp",
        .roll = "iStarRoll",
        .warp = "iStarWarp",
    }) = .{},

    /// Vanishing point, uv; eased toward the cursor.
    vp: [2]f32 = .{ 0.5, 0.5 },
    vp_vel: [2]f32 = .{ 0, 0 },
    roll: f32 = 0,
    bank: f32 = 0,
    /// cos and sin of the roll as drawn this frame (roll + bank).
    roll_cs: [2]f32 = .{ 1, 0 },
    speed: f32 = 0.12,
    surge: f32 = 0,
    /// Distance flown, for the nebula's zoom.
    flight: f64 = 0,
    now: f64 = 0,

    jumps: bool,
    jump_left: f32 = 0,
    /// Hyperspace envelope, 0..1.
    warp: f32 = 0,
    next_jump: f32 = 0,

    colors: [16][3]f32 = [_][3]f32{.{ 0.8, 0.85, 1.0 }} ** 16,
    color_count: usize = 0,
    fg: [3]f32 = .{ 0.92, 0.92, 0.96 },
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    const hp = hg.Host{ .raw = @ptrCast(host) };
    const count: usize = @intCast(std.math.clamp(hp.getInt("stars", 2500), 100, max_stars));

    const stars = hg.allocator.alloc(Star, count) catch return null;
    const verts = hg.allocator.alloc(geometry.Vertex, count * 48) catch {
        hg.allocator.free(stars);
        return null;
    };
    const point_verts = hg.allocator.alloc(geometry.Point, count * 3) catch {
        hg.allocator.free(stars);
        hg.allocator.free(verts);
        return null;
    };
    const state = hg.allocator.create(State) catch {
        hg.allocator.free(stars);
        hg.allocator.free(verts);
        hg.allocator.free(point_verts);
        return null;
    };

    state.* = .{
        .rng = std.Random.DefaultPrng.init(nowNs()),
        .width = width,
        .height = height,
        .count = count,
        .stars = stars,
        .verts = verts,
        .batch = .{ .verts = verts, .px = .{ width, height } },
        .point_verts = point_verts,
        .points = .{ .verts = point_verts },
        .jumps = hp.getBool("jumps", true),
    };
    for (state.stars) |*s| s.* = spawn(state, range(state, near, far));
    state.next_jump = range(state, 40.0, 90.0);
    return @ptrCast(state);
}

fn rand(s: *State) f32 {
    return s.rng.random().float(f32);
}

fn range(s: *State, lo: f32, hi: f32) f32 {
    return lo + (hi - lo) * rand(s);
}

fn spawn(s: *State, z: f32) Star {
    const aspect = s.width / s.height;
    const m = rand(s);
    return .{
        .x = range(s, -spread, spread) * aspect,
        .y = range(s, -spread, spread),
        .z = z,
        .mag = 0.22 + 0.78 * m * m,
        .tint = if (rand(s) < 0.7) 0 else 1 + s.rng.random().uintLessThan(u8, 12),
        .phase = range(s, 0.0, std.math.tau),
    };
}

fn color(s: *const State, tint: u8) [3]f32 {
    if (tint == 0 or s.color_count < 8) return s.fg;
    const slots = [_]usize{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 };
    const n: usize = if (s.color_count >= 15) 12 else 6;
    const col = s.colors[slots[(tint - 1) % n]];
    // Starlight is pale: tints lean toward the foreground.
    return .{
        col[0] + (s.fg[0] - col[0]) * 0.35,
        col[1] + (s.fg[1] - col[1]) * 0.35,
        col[2] + (s.fg[2] - col[2]) * 0.35,
    };
}

/// Screen uv of a world point seen from the camera (rolled about the
/// view axis, looking through the vanishing point).
fn project(s: *const State, x: f32, y: f32, z: f32) [2]f32 {
    const aspect = s.width / s.height;
    const cr = s.roll_cs[0];
    const sr = s.roll_cs[1];
    const rx = x * cr - y * sr;
    const ry = x * sr + y * cr;
    return .{ s.vp[0] + rx / z * focal / aspect, s.vp[1] + ry / z * focal };
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);

    const dt = clamp(f.dt, 0.0, 0.05);

    var wave: [256]f32 = [_]f32{0} ** 256;
    if (f.wave != null and f.wave_len >= wave.len) @memcpy(&wave, f.wave[0..wave.len]);
    const kick = s.music.update(&wave, dt);
    s.now += dt;

    if (f.palette != null and f.palette_len > 0) {
        const n = @min(@as(usize, @intCast(f.palette_len)), s.colors.len);
        s.color_count = n;
        for (0..n) |i| s.colors[i] = .{ f.palette[i * 3], f.palette[i * 3 + 1], f.palette[i * 3 + 2] };
        s.fg = .{ f.palette_fg[0], f.palette_fg[1], f.palette_fg[2] };
    }

    // Steering: a damped spring pulls the vanishing point toward the
    // cursor (held in from the edges), and the camera banks against
    // the turn's sideways velocity.
    const target = [2]f32{
        0.5 + (clamp(f.cursor[0] / s.width, 0.0, 1.0) - 0.5) * 0.6,
        0.5 + (clamp(f.cursor[1] / s.height, 0.0, 1.0) - 0.5) * 0.6,
    };
    const k: f32 = 2.2;
    const damp: f32 = 2.6;
    for (0..2) |i| {
        s.vp_vel[i] += ((target[i] - s.vp[i]) * k - s.vp_vel[i] * damp) * dt;
        s.vp[i] += s.vp_vel[i] * dt;
    }
    const bank_target = clamp(-s.vp_vel[0] * 1.6, -0.35, 0.35);
    s.bank += (bank_target - s.bank) * @min(1.0, 2.0 * dt);
    s.roll += dt * 0.006;
    s.roll_cs = .{ @cos(s.roll + s.bank), @sin(s.roll + s.bank) };

    // Speed: cruise, music, kicks, and hyperspace.
    if (kick) s.surge = 1.0;
    s.surge *= @exp(-3.0 * dt);
    if (s.jumps) {
        s.next_jump -= dt;
        if (s.next_jump <= 0 and s.jump_left <= 0) {
            s.jump_left = range(s, 2.5, 4.5);
            s.next_jump = range(s, 60.0, 150.0);
        }
    }
    s.jump_left -= dt;
    const warp_target: f32 = if (s.jump_left > 0) 1.0 else 0.0;
    // Spool up slower than the drop out.
    s.warp += (warp_target - s.warp) * @min(1.0, (if (warp_target > s.warp) @as(f32, 1.2) else 2.5) * dt);
    const cruise = 0.1 + s.music.bass() * 0.12 + s.surge * 0.25;
    s.speed = cruise + s.warp * s.warp * 2.4;
    s.flight += s.speed * dt;

    // Fly: stars come at the camera; past it or out of view, a fresh
    // one appears at the back of the box.
    const tw: f32 = @floatCast(@mod(s.now, 1000.0));
    s.batch.len = 0;
    s.points.len = 0;
    const px_scale = s.height / 1440.0;
    // Streaks trail back over the distance flown in this many seconds.
    const trail_secs: f32 = 0.018 + s.surge * 0.03 + s.warp * 0.14;
    for (s.stars) |*star| {
        star.z -= s.speed * dt;
        var p = project(s, star.x, star.y, star.z);
        if (star.z < near or p[0] < -0.2 or p[0] > 1.2 or p[1] < -0.2 or p[1] > 1.2) {
            star.* = spawn(s, range(s, far * 0.85, far));
            p = project(s, star.x, star.y, star.z);
        }

        // Fade in from the back of the box; brighten as it nears.
        const depth = (far - star.z) / (far - near);
        const fade_in = clamp((far - star.z) / 0.25, 0.0, 1.0);
        const twinkle = 0.85 + 0.15 * @sin(tw * (2.0 + star.mag * 3.0) + star.phase);
        const bright = star.mag * fade_in * (0.35 + 0.65 * depth) * (if (star.z > 0.4) twinkle else 1.0);
        if (bright < 0.01) continue;
        const r = clamp(0.18 * star.mag / star.z, 0.9, 6.5) * px_scale;
        const col = color(s, star.tint);
        const head = [4]f32{ col[0], col[1], col[2], @min(bright * 1.3, 1.0) };
        const glow = [4]f32{ col[0], col[1], col[2], bright * 0.16 };

        // Only what shows: a far star is one dot; streaks, the white
        // core and the halo come in as it nears and brightens.
        const tail = project(s, star.x, star.y, star.z + s.speed * trail_secs);
        const sx = (p[0] - tail[0]) * s.width;
        const sy = (p[1] - tail[1]) * s.height;
        if (sx * sx + sy * sy > 1.0) {
            s.batch.line(tail, p, r * 1.6, head);
            if (bright > 0.25) s.batch.line(tail, p, r * 5.0, glow);
        }
        s.points.dot(p, r * 3.0, head);
        if (r > 1.5 * px_scale) s.points.dot(p, r * 1.4, .{ 1, 1, 1, head[3] * 0.6 });
        if (bright * r > 0.8 * px_scale) s.points.dot(p, r * 10.0, glow);

        // Diffraction spikes on the brightest, nearest stars.
        if (star.mag > 0.75 and star.z < 0.35 and s.warp < 0.3) {
            const len = r * 9.0 / s.width;
            const len_y = r * 9.0 / s.height;
            const spike = [4]f32{ col[0], col[1], col[2], bright * 0.5 * (1.0 - s.warp / 0.3) };
            s.batch.line(.{ p[0] - len, p[1] }, .{ p[0] + len, p[1] }, 1.2 * px_scale, spike);
            s.batch.line(.{ p[0], p[1] - len_y }, .{ p[0], p[1] + len_y }, 1.2 * px_scale, spike);
        }
    }
}

fn ensureGl(s: *State) bool {
    if (s.gl_ready) return true;
    if (s.gl_failed) return false;
    s.gl_failed = true;
    s.painter = geometry.Painter.init(s.verts.len) catch return false;
    s.point_painter = geometry.PointPainter.init(s.point_verts.len) catch return false;

    const w: i32 = @intFromFloat(s.width);
    const h: i32 = @intFromFloat(s.height);
    // Half float keeps overlapping glows from clipping; 8-bit if not.
    s.sprite = hg_gl.Target.init(w, h, .{
        .format = .rgba16f,
        .half_float_fallback = true,
        .filter = .nearest,
        .wrap = .clamp,
    }) catch return false;

    const nw = @divTrunc(w + 3, 4);
    const nh = @divTrunc(h + 3, 4);
    s.nebula = hg_gl.Target.init(nw, nh, .{
        .format = .rgba16f,
        .half_float_fallback = true,
        .filter = .linear,
        .wrap = .clamp,
    }) catch return false;

    s.neb_prog = hg_gl.Program.init(nebula_frag_src) catch return false;

    s.gl_ready = true;
    s.gl_failed = false;
    return true;
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));

    if (ensureGl(s)) {
        // The stars, as soft geometry, into the full-size layer.
        s.sprite.begin();
        gl.glClearColor(0, 0, 0, 0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        s.painter.draw(&s.batch, .additive);
        s.point_painter.draw(&s.points);

        // The nebula, at a quarter of the screen's size.
        s.nebula.begin();
        s.neb_prog.use();
        s.nu.use(s.neb_prog.program);
        s.nu.f2(.res, @floatFromInt(s.nebula.width), @floatFromInt(s.nebula.height));
        s.nu.f2(.vp, s.vp[0], s.vp[1]);
        s.nu.f1(.roll, s.roll + s.bank);
        s.nu.f1(.flight, @floatCast(@mod(s.flight, 1000.0)));
        const tints = [9]f32{
            s.colors[4][0], s.colors[4][1], s.colors[4][2],
            s.colors[5][0], s.colors[5][1], s.colors[5][2],
            s.colors[6][0], s.colors[6][1], s.colors[6][2],
        };
        s.nu.f3v(.tint, 3, &tints);
        s.neb_prog.draw();
        gl.glBindVertexArray(0);
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    }

    s.u.use(program);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.sprite.tex);
    s.u.int(.sprite, 0);
    gl.glActiveTexture(gl.GL_TEXTURE1);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.nebula.tex);
    s.u.int(.nebula, 1);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    s.u.f2(.vp, s.vp[0], s.vp[1]);
    s.u.f1(.roll, s.roll + s.bank);
    s.u.f1(.warp, s.warp);
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    s.sprite.deinit();
    s.nebula.deinit();
    s.neb_prog.deinit();
    s.painter.deinit();
    s.point_painter.deinit();
    hg.allocator.free(s.stars);
    hg.allocator.free(s.verts);
    hg.allocator.free(s.point_verts);
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "starfield",
    .shader = "starfield.frag",
    // `stars`/`jumps` and the `music`/`sink` audio knobs live in the shared
    // [visualizer] section.
    .config_section = "visualizer",
    .wants_audio = 1,
    .create = create,
    .update = update,
    .upload = upload,
    .destroy = destroy,
};

export fn hg_module_entry() callconv(.c) *const c.hg_module {
    return &module;
}
