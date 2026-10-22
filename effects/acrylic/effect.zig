//! effects/acrylic — a faithful, 1:1 port of the flow-ref3 Shadertoy
//! ("kind of viscous, like honey", https://www.shadertoy.com/view/7sGGRD).
//!
//! flow-ref3 chains five passes. Buffer A and Buffer B are *dynamical systems*
//! — a "fracturing" field (MsyXRW) and a fluid-like field (XddSRX) — Buffer C
//! is flockaroo's rotational single-pass CFD, Buffer D is xenn's lava-lamp
//! feedback, and the Image pass displaces a colour input along A's field with
//! chromatic dispersion. This component keeps every pass, every constant and
//! the exact channel graph from the Shadertoy JSON:
//!
//!     A <- D(prev), noise, keyboard
//!     B <- A
//!     C <- C(prev), noise, colour, B
//!     D <- B, colour, C, B
//!     Image <- D, colour, C
//!
//! The GLSL lives in `shaders.zig` (generated from the original `.frag` files,
//! bodies verbatim) and `acrylic.frag` (the Image pass, loaded by the host).
//! `scripts/gen-acrylic-shaders.py` documents the only changes: Shadertoy
//! plumbing, window rigid bodies appended to Buffers A/B/C, a static
//! small-island paint texture (rendered once by `pass_paint`) in place of the
//! reference's colour texture, a whole-screen rotation, and random impulses
//! that stir the flow.
//!
//! Two additions keep the wallpaper alive, which the reference does not need:
//!
//!   * the whole screen turns. The component drives a slow, steady angle in
//!     one direction; the Image pass samples the field through it and the
//!     buffer passes turn their pixel coordinates the other way, so a window
//!     keeps its hole in the flow while the honey turns around it;
//!   * random impulses. The honey settles into one static pattern if nothing
//!     disturbs it, so the component throws a few blobs of force at the flow
//!     (Buffer D, which the Image pass reads) every now and then. Each blob
//!     pushes, drags and swirls the field, so the flow keeps moving and
//!     keeps bending.
//!
//! The Shadertoy input textures are synthesised: smooth value noise for Buffer
//! A's seed and white noise for Buffer C's random rotation (both deterministic),
//! and a 1x1 zero for the keyboard texture, so the "reset" branch never fires.

const std = @import("std");

const hg = @import("hg.zig");
const hg_gl = @import("hg_gl.zig");
const shaders = @import("shaders.zig");

const c = hg.c;
const gl = hg.gl;

const log = std.log.scoped(.acrylic);

const max_windows = 32;

/// How many stirring blobs can be alive at once.
const max_impulses = 4;

/// Every uniform the passes share. One cached-location table serves all of
/// them: `Uniforms.use` re-resolves when the program changes.
const U = hg.Uniforms(.{
    .res = "iResolution",
    .time = "iTime",
    .frame = "iFrame",
    .mouse = "iMouse",
    .ch0 = "uCh0",
    .ch1 = "uCh1",
    .ch2 = "uCh2",
    .ch3 = "uCh3",
    .res0 = "uRes0",
    .res1 = "uRes1",
    .win_count = "uWinCount",
    .win_rect = "uWin[0]",
    .win_vel = "uWinVel[0]",
    .win_scale = "uWinScale",
    .win_band = "uWinBand",
    .win_corner = "uWinCorner",
    .win_slip = "uWinNoSlip",
    .win_push = "uWinPush",
    .win_turn = "uWinTurn",
    .win_curl = "uWinCurl",
    .win_wall = "uWinWall",
    .rot = "uRotate",
    .rot_center = "uRotCenter",
    .imp = "uImpulse[0]",
    .imp_dir = "uImpulseDir[0]",
    .imp_count = "uImpulseCount",
});

/// xorshift64: the impulses only need noise, not a cryptographic stream.
const Rng = struct {
    s: u64 = 0x2545f4914f6cdd1d,

    fn next(self: *Rng) u64 {
        var x = self.s;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.s = x;
        return x;
    }

    /// Uniform in [0, 1).
    fn unit(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) * (1.0 / 16777216.0);
    }

    /// Uniform in [lo, hi).
    fn range(self: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.unit();
    }
};

/// One stirring blob. The honey is content to sit still, so the component
/// throws a blob of force at the flow every now and then.
const Impulse = struct {
    active: bool = false,
    /// Centre, in buffer pixels of the *screen* frame.
    x: f32 = 0,
    y: f32 = 0,
    /// Unit travel direction (screen frame).
    dx: f32 = 1,
    dy: f32 = 0,
    /// How fast the blob travels, buffer px/s.
    speed: f32 = 0,
    /// Blob radius, buffer px.
    radius: f32 = 100,
    age: f32 = 0,
    life: f32 = 1,
    strength: f32 = 0,
};

const Tracked = struct {
    addr: u64 = 0,
    cx: f32 = 0,
    cy: f32 = 0,
    /// Exponentially smoothed centre velocity (px/s). The push uses this so a
    /// moving window shoves the flow with a little inertia instead of an
    /// instantaneous jolt.
    svx: f32 = 0,
    svy: f32 = 0,
};

const State = struct {
    width: f32,
    height: f32,
    buf_w: i32,
    buf_h: i32,
    /// Buffer resolution relative to the surface. 0.8 renders the grid at
    /// four-fifths, making every flow structure a little larger on screen.
    scale: f32,

    // Four ping-pong pairs, one per Shadertoy buffer.
    a: [2]hg_gl.Target = .{ .{}, .{} },
    a_cur: u1 = 0,
    b: [2]hg_gl.Target = .{ .{}, .{} },
    b_cur: u1 = 0,
    c: [2]hg_gl.Target = .{ .{}, .{} },
    c_cur: u1 = 0,
    d: [2]hg_gl.Target = .{ .{}, .{} },
    d_cur: u1 = 0,

    // Static paint source: the Image pass's replacement for the reference's
    // colour texture. Rendered once into a small-island field, then sampled by
    // the 64 dispersion taps (a texture read instead of procedural noise).
    paint: hg_gl.Target = .{},

    prog_a: hg_gl.Program = .{},
    prog_b: hg_gl.Program = .{},
    prog_c: hg_gl.Program = .{},
    prog_d: hg_gl.Program = .{},
    prog_paint: hg_gl.Program = .{},

    tex_noise_a: gl.GLuint = 0,
    tex_noise_c: gl.GLuint = 0,
    tex_key: gl.GLuint = 0,
    noise_a_res: [2]f32 = .{ 1, 1 },
    noise_c_res: [2]f32 = .{ 1, 1 },

    // Window rigid bodies, in buffer pixels (already multiplied by `scale`).
    win_count: i32 = 0,
    win_rect: [max_windows][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** max_windows,
    win_vel: [max_windows][2]f32 = [_][2]f32{.{ 0, 0 }} ** max_windows,
    win_band: f32 = 10.0, // surface px
    win_corner: f32 = 14.0, // surface px
    win_speed: f32 = 700.0, // surface px/s that maps to a field value of 1
    win_slip: f32 = 0.0, // 0..1
    win_push: f32 = 1.0, // 0..1 interior clearing (no flow under a window)
    win_turn: f32 = 0.85, // 0..1 inflow bent along the edge
    win_curl: f32 = 0.25, // 0..1 swirl added to the slide
    win_wall: f32 = 0.6, // 0..1 push ahead of a moving window bounds
    tracked: [max_windows]Tracked = [_]Tracked{.{}} ** max_windows,
    tracked_count: usize = 0,

    // Whole-screen rotation: a slow, steady turn in one direction, eased in
    // over a few seconds and never reversing.
    rot_angle: f32 = 0,
    rot_vel: f32 = 0,
    rot_target: f32 = 0,
    rot_speed: f32 = 0.12, // max |angular velocity|, rad/s
    rot_mult: f32 = 1.0,

    // Random impulses that stir the flow.
    impulses: [max_impulses]Impulse = [_]Impulse{.{}} ** max_impulses,
    imp_buf: [max_impulses][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** max_impulses,
    imp_dir_buf: [max_impulses][2]f32 = [_][2]f32{.{ 0, 0 }} ** max_impulses,
    imp_timer: f32 = 0,
    imp_rate: f32 = 0.6, // impulses per second
    imp_strength: f32 = 1.0,
    rng: Rng = .{},

    u: U = .{},
    frame: i32 = 0,
    time: f32 = 0,
    cursor: [2]f32 = .{ 0, 0 },

    gl_ready: bool = false,
    gl_failed: bool = false,
};

/// Seed the impulse/rotation noise from the monotonic clock, so two runs of
/// the daemon do not stir in the same pattern.
fn seedRng() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0x2545f4914f6cdd1d;
    const sec: u64 = @intCast(@max(ts.sec, 0));
    const nsec: u64 = @intCast(@max(ts.nsec, 0));
    return sec *% 1_000_000_000 +% nsec;
}

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    const hp = hg.Host{ .raw = @ptrCast(host) };
    const state = hg.allocator.create(State) catch return null;

    // 0.8: buffers at four-fifths resolution, so each texel covers 1.25
    // output pixels and the honey's structures read a little larger.
    const scale = std.math.clamp(hp.getFloat("scale", 0.8), 0.1, 1.0);
    const buf_w: i32 = @intFromFloat(@max(16.0, @round(width * scale)));
    const buf_h: i32 = @intFromFloat(@max(16.0, @round(height * scale)));

    const imp_strength = std.math.clamp(hp.getFloat("impulse", 1.0), 0.0, 8.0) * 0.25;
    const imp_rate = std.math.clamp(hp.getFloat("impulse_rate", 0.6), 0.0, 20.0) * 0.2;
    const rot_speed = std.math.clamp(hp.getFloat("rotate_speed", 0.12), 0.0, 2.0) * 0.32;
    const rot_mult = std.math.clamp(hp.getFloat("rotate", 1.0), 0.0, 8.0);

    var rng = Rng{ .s = seedRng() | 1 };

    state.* = .{
        .width = width,
        .height = height,
        .buf_w = buf_w,
        .buf_h = buf_h,
        .scale = scale,
        .win_band = @max(hp.getFloat("win_band", 10.0), 0.0),
        .win_corner = @max(hp.getFloat("win_corner", 14.0), 0.0),
        .win_speed = @max(hp.getFloat("win_speed", 700.0), 1.0),
        .win_slip = std.math.clamp(hp.getFloat("win_slip", 0.0), 0.0, 1.0),
        .win_push = std.math.clamp(hp.getFloat("win_push", 1.0), 0.0, 1.0),
        .win_turn = std.math.clamp(hp.getFloat("win_turn", 0.85), 0.0, 1.0),
        .win_curl = std.math.clamp(hp.getFloat("win_curl", 0.25), 0.0, 1.0),
        .win_wall = std.math.clamp(hp.getFloat("win_wall", 0.6), 0.0, 1.0),
        .rot_speed = rot_speed,
        .rot_mult = rot_mult,
        // Start out turning, so the picture is never static.
        .rot_target = rot_speed * rot_mult,
        .imp_strength = imp_strength,
        .imp_rate = imp_rate,
        .imp_timer = rng.range(3.0, 14.0),
        .rng = rng,
    };
    return @ptrCast(state);
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);
    s.time = @floatCast(f.time);
    s.cursor = .{ f.cursor[0], f.cursor[1] };

    // Per-window velocity from the centre delta: the host only tracks the
    // focused window, and a rigid body needs its own motion to drag the flow.
    const n: usize = @min(@as(usize, f.windows_len), max_windows);
    const dt = @max(f.dt, 1e-4);
    var next: [max_windows]Tracked = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = f.windows[i];
        if (r.w < 1.0 or r.h < 1.0) continue;
        const cx = r.x + r.w * 0.5;
        const cy = r.y + r.h * 0.5;

        var vx: f32 = 0;
        var vy: f32 = 0;
        var svx: f32 = 0;
        var svy: f32 = 0;
        for (s.tracked[0..s.tracked_count]) |p| {
            if (p.addr != 0 and p.addr == r.address) {
                vx = (cx - p.cx) / dt;
                vy = (cy - p.cy) / dt;
                svx = p.svx;
                svy = p.svy;
                break;
            }
        }
        vx = std.math.clamp(vx, -6000.0, 6000.0);
        vy = std.math.clamp(vy, -6000.0, 6000.0);
        // Inertia: follow the instantaneous velocity with a ~0.15 s time
        // constant, so the push ramps in and fades out instead of snapping.
        const k: f32 = 1.0 - @exp(-dt / 0.15);
        svx += (vx - svx) * k;
        svy += (vy - svy) * k;

        s.win_rect[count] = .{ r.x * s.scale, r.y * s.scale, r.w * s.scale, r.h * s.scale };
        s.win_vel[count] = .{ svx * s.scale, svy * s.scale };
        next[count] = .{ .addr = r.address, .cx = cx, .cy = cy, .svx = svx, .svy = svy };
        count += 1;
    }
    s.win_count = @intCast(count);
    s.tracked = next;
    s.tracked_count = count;

    stepRotation(s, dt);
    stepImpulses(s, dt);
}

/// Ease the screen's rotation towards a steady target velocity: one direction,
/// ramping in smoothly and never reversing.
fn stepRotation(s: *State, dt: f32) void {
    // Smooth, long ease (~5 s) towards the target speed.
    s.rot_vel += (s.rot_target - s.rot_vel) * (1.0 - @exp(-dt / 5.0));
    s.rot_angle += s.rot_vel * dt;
    // Keep the angle in [-pi, pi] so the trigonometry stays precise.
    if (s.rot_angle > std.math.pi) s.rot_angle -= std.math.tau;
    if (s.rot_angle < -std.math.pi) s.rot_angle += std.math.tau;
}

/// Throw the next stirring blob, and age the live ones.
fn stepImpulses(s: *State, dt: f32) void {
    s.imp_timer -= dt;
    if (s.imp_timer <= 0) {
        if (s.imp_rate > 0.0 and s.imp_strength > 0.0) {
            // Exponential delay: the stirring comes in bursts, with quiet
            // stretches in between.
            const u = @max(s.rng.unit(), 1.0e-6);
            s.imp_timer = -@log(u) / s.imp_rate;
            spawnImpulse(s);
        } else {
            s.imp_timer = 1.0;
        }
    }

    for (&s.impulses) |*im| {
        if (!im.active) continue;
        im.age += dt;
        if (im.age >= im.life) {
            im.active = false;
            continue;
        }
        im.x += im.dx * im.speed * dt;
        im.y += im.dy * im.speed * dt;
    }
}

fn spawnImpulse(s: *State) void {
    var slot: usize = max_impulses;
    for (s.impulses, 0..) |im, i| {
        if (!im.active) {
            slot = i;
            break;
        }
    }
    if (slot == max_impulses) return;

    const bw = @as(f32, @floatFromInt(s.buf_w));
    const bh = @as(f32, @floatFromInt(s.buf_h));
    const dir_a = s.rng.range(0.0, std.math.tau);
    s.impulses[slot] = .{
        .active = true,
        // Keep the blob off the very edge: the screen rotates, so a blob at
        // the rim would spend most of its life outside the picture.
        .x = s.rng.range(0.18, 0.82) * bw,
        .y = s.rng.range(0.18, 0.82) * bh,
        .dx = @cos(dir_a),
        .dy = @sin(dir_a),
        .speed = s.rng.range(8.0, 30.0),
        .radius = s.rng.range(90.0, 150.0),
        .age = 0,
        .life = s.rng.range(7.0, 11.0),
        .strength = s.imp_strength * s.rng.range(0.7, 1.2),
    };
}

/// Quad ease-in-out: a gentle ramp at both ends, so the blob swells in and
/// dies away without a corner in the force.
fn easeQuadInOut(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    if (x < 0.5) return 2.0 * x * x;
    const y = 1.0 - x;
    return 1.0 - 2.0 * y * y;
}

/// Quad-eased swell and fade: slow to stir, slow to fade, no corners.
fn impulseEnvelope(im: Impulse) f32 {
    const attack: f32 = 0.9;
    const release: f32 = 1.6;
    if (im.age < attack) return easeQuadInOut(im.age / attack);
    const fade_start = @max(im.life - release, attack);
    if (im.age < fade_start) return 1.0;
    return easeQuadInOut(1.0 - (im.age - fade_start) / @max(im.life - fade_start, 1.0e-4));
}

fn bindTex(unit: gl.GLenum, tex: gl.GLuint) void {
    gl.glActiveTexture(unit);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
}

fn makeTexture(w: u32, h: u32, rgba: []const u8) gl.GLuint {
    var tex: gl.GLuint = 0;
    gl.glGenTextures(1, &tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        gl.GL_RGBA8,
        @intCast(w),
        @intCast(h),
        0,
        gl.GL_RGBA,
        gl.GL_UNSIGNED_BYTE,
        rgba.ptr,
    );
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR_MIPMAP_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_REPEAT);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_REPEAT);
    gl.glGenerateMipmap(gl.GL_TEXTURE_2D);
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
    return tex;
}

fn hash2(x: i32, y: i32, seed: u32) f32 {
    var hsh: u32 = @as(u32, @bitCast(x)) *% 374761393 +%
        @as(u32, @bitCast(y)) *% 668265263 +% seed *% 2246822519;
    hsh = (hsh ^ (hsh >> 13)) *% 1274126177;
    hsh ^= hsh >> 16;
    return @as(f32, @floatFromInt((hsh >> 8) & 0xffff)) / 65535.0;
}

fn smooth(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

fn valueNoise(x: f32, y: f32, seed: u32) f32 {
    const xi = @floor(x);
    const yi = @floor(y);
    const u = smooth(x - xi);
    const v = smooth(y - yi);
    const ix: i32 = @intFromFloat(xi);
    const iy: i32 = @intFromFloat(yi);
    const a = hash2(ix, iy, seed);
    const b = hash2(ix + 1, iy, seed);
    const cc = hash2(ix, iy + 1, seed);
    const d = hash2(ix + 1, iy + 1, seed);
    return (a * (1.0 - u) + b * u) * (1.0 - v) + (cc * (1.0 - u) + d * u) * v;
}

fn fbm(x: f32, y: f32, seed: u32) f32 {
    var f: f32 = 0;
    var amp: f32 = 0.5;
    var freq: f32 = 1.0;
    var s = seed;
    for (0..4) |_| {
        f += amp * valueNoise(x * freq, y * freq, s);
        freq *= 2.0;
        amp *= 0.5;
        s +%= 0x9e3779b9;
    }
    return f;
}

/// Smooth multi-octave noise: Buffer A seeds from this, so coherent blobs
/// form instead of a per-pixel salt-and-pepper field.
fn smoothNoise(alloc: std.mem.Allocator, w: u32, h: u32) []u8 {
    const out = alloc.alloc(u8, @as(usize, w) * h * 4) catch return &.{};
    for (0..h) |y| {
        for (0..w) |x| {
            const i = (y * w + x) * 4;
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            out[i + 0] = @intFromFloat(std.math.clamp(fbm(fx / 28.0, fy / 28.0, 1), 0, 1) * 255);
            out[i + 1] = @intFromFloat(std.math.clamp(fbm(fx / 28.0, fy / 28.0, 2), 0, 1) * 255);
            out[i + 2] = @intFromFloat(std.math.clamp(fbm(fx / 28.0, fy / 28.0, 3), 0, 1) * 255);
            out[i + 3] = 255;
        }
    }
    return out;
}

/// White noise: Buffer C steps a random rotation each frame, so it wants
/// uncorrelated values rather than coherent structure.
fn whiteNoise(alloc: std.mem.Allocator, w: u32, h: u32) []u8 {
    const out = alloc.alloc(u8, @as(usize, w) * h * 4) catch return &.{};
    for (0..h) |y| {
        for (0..w) |x| {
            const i = (y * w + x) * 4;
            out[i + 0] = @intFromFloat(hash2(@intCast(x), @intCast(y), 11) * 255);
            out[i + 1] = @intFromFloat(hash2(@intCast(x), @intCast(y), 29) * 255);
            out[i + 2] = @intFromFloat(hash2(@intCast(x), @intCast(y), 47) * 255);
            out[i + 3] = 255;
        }
    }
    return out;
}

fn noiseTexture(alloc: std.mem.Allocator, w: u32, h: u32, smooth_field: bool) gl.GLuint {
    const buf = if (smooth_field) smoothNoise(alloc, w, h) else whiteNoise(alloc, w, h);
    defer if (buf.len > 0) alloc.free(buf);
    if (buf.len == 0) return 0;
    return makeTexture(w, h, buf);
}

fn ensureGl(s: *State) bool {
    if (s.gl_ready) return true;
    if (s.gl_failed) return false;
    s.gl_failed = true;

    s.prog_a = hg_gl.Program.init(shaders.pass_a) catch {
        log.err("buffer-a program failed", .{});
        return false;
    };
    s.prog_b = hg_gl.Program.init(shaders.pass_b) catch {
        log.err("buffer-b program failed", .{});
        return false;
    };
    s.prog_c = hg_gl.Program.init(shaders.pass_c) catch {
        log.err("buffer-c program failed", .{});
        return false;
    };
    s.prog_d = hg_gl.Program.init(shaders.pass_d) catch {
        log.err("buffer-d program failed", .{});
        return false;
    };
    s.prog_paint = hg_gl.Program.init(shaders.pass_paint) catch {
        log.err("paint program failed", .{});
        return false;
    };

    const opts = hg_gl.Target.Options{
        .format = .rgba16f,
        .half_float_fallback = true,
        .filter = .linear,
        // The whole screen rotates, so the Image pass samples the buffers
        // past their edge: they have to wrap instead of clamping.
        .wrap = .repeat,
    };
    for (&s.a) |*t| t.* = hg_gl.Target.init(s.buf_w, s.buf_h, opts) catch return false;
    for (&s.b) |*t| t.* = hg_gl.Target.init(s.buf_w, s.buf_h, opts) catch return false;
    for (&s.c) |*t| t.* = hg_gl.Target.init(s.buf_w, s.buf_h, opts) catch return false;
    for (&s.d) |*t| t.* = hg_gl.Target.init(s.buf_w, s.buf_h, opts) catch return false;

    // The paint source is static: render the island field once. Repeat wrap
    // keeps dispersion taps that cross an edge continuous with the far side.
    s.paint = hg_gl.Target.init(s.buf_w, s.buf_h, .{
        .format = .rgba8,
        .filter = .linear,
        .wrap = .repeat,
    }) catch return false;
    s.paint.begin();
    s.u.use(s.prog_paint.program);
    s.u.f3(.res, @floatFromInt(s.buf_w), @floatFromInt(s.buf_h), 1.0);
    s.prog_paint.draw();
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);

    for (&s.a) |*t| clear(t);
    for (&s.b) |*t| clear(t);
    for (&s.c) |*t| clear(t);
    for (&s.d) |*t| clear(t);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);

    const w: u32 = 256;
    const h: u32 = 256;
    s.tex_noise_a = noiseTexture(hg.allocator, w, h, true);
    s.tex_noise_c = noiseTexture(hg.allocator, w, h, false);
    s.noise_a_res = .{ @floatFromInt(w), @floatFromInt(h) };
    s.noise_c_res = s.noise_a_res;

    // 1x1 zero: Buffer A's keyboard texture (reset never fires) and the
    // placeholder for every channel the port no longer samples.
    const zero = [_]u8{ 0, 0, 0, 0 };
    s.tex_key = makeTexture(1, 1, &zero);

    gl.glActiveTexture(gl.GL_TEXTURE0);

    s.gl_failed = false;
    s.gl_ready = true;
    return true;
}

fn clear(t: *const hg_gl.Target) void {
    t.begin();
    gl.glClearColor(0, 0, 0, 0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
}

fn setWindows(s: *State, u: *U, speed: f32) void {
    u.int(.win_count, s.win_count);
    if (s.win_count > 0) {
        u.f4v(.win_rect, s.win_count, &s.win_rect);
        u.f2v(.win_vel, s.win_count, &s.win_vel);
    }
    u.f1(.win_scale, speed * s.scale);
    u.f1(.win_band, s.win_band * s.scale);
    u.f1(.win_corner, s.win_corner * s.scale);
    u.f1(.win_slip, s.win_slip);
    u.f1(.win_push, s.win_push);
    u.f1(.win_turn, s.win_turn);
    u.f1(.win_curl, s.win_curl);
    u.f1(.win_wall, s.win_wall);
}

/// The rotation is driven from the CPU: a slow, steady angle that eases in
/// once and never changes direction. The shaders only need its cosine and
/// sine, plus the centre they turn about — in the framebuffer's own pixels.
fn setRotation(s: *State, u: *U, cx: f32, cy: f32) void {
    u.f2(.rot, @cos(s.rot_angle), @sin(s.rot_angle));
    u.f2(.rot_center, cx, cy);
}

/// The stirring blobs, packed for the `uImpulse`/`uImpulseDir` arrays.
fn setImpulses(s: *State, u: *U) void {
    var n: usize = 0;
    for (s.impulses) |im| {
        if (!im.active) continue;
        const strength = im.strength * impulseEnvelope(im);
        if (strength <= 0.0) continue;
        s.imp_buf[n] = .{ im.x, im.y, im.radius, strength };
        s.imp_dir_buf[n] = .{ im.dx, im.dy };
        n += 1;
    }
    u.int(.imp_count, @intCast(n));
    if (n > 0) {
        u.f4v(.imp, @intCast(n), &s.imp_buf);
        u.f2v(.imp_dir, @intCast(n), &s.imp_dir_buf);
    }
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    if (!ensureGl(s)) return;

    const bw: f32 = @floatFromInt(s.buf_w);
    const bh: f32 = @floatFromInt(s.buf_h);
    const zero = s.tex_key;

    // --- Buffer A: A <- D(prev), noise, keyboard ---------------------------
    const aw: u1 = 1 - s.a_cur;
    s.a[aw].begin();
    s.u.use(s.prog_a.program);
    bindTex(gl.GL_TEXTURE0, s.d[s.d_cur].tex);
    s.u.int(.ch0, 0);
    bindTex(gl.GL_TEXTURE1, s.tex_noise_a);
    s.u.int(.ch1, 1);
    bindTex(gl.GL_TEXTURE3, s.tex_key);
    s.u.int(.ch3, 3);
    s.u.f3(.res, bw, bh, 1.0);
    s.u.f1(.time, s.time);
    s.u.int(.frame, s.frame);
    s.u.f4(.mouse, s.cursor[0], s.cursor[1], 0.0, 0.0);
    setWindows(s, &s.u, s.win_speed);
    setRotation(s, &s.u, bw * 0.5, bh * 0.5);
    s.prog_a.draw();
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    s.a_cur = aw;

    // --- Buffer B: B <- A --------------------------------------------------
    const bnext: u1 = 1 - s.b_cur;
    s.b[bnext].begin();
    s.u.use(s.prog_b.program);
    bindTex(gl.GL_TEXTURE0, s.a[s.a_cur].tex);
    s.u.int(.ch0, 0);
    s.u.f3(.res, bw, bh, 1.0);
    s.u.f1(.time, s.time);
    s.u.int(.frame, s.frame);
    s.u.f4(.mouse, s.cursor[0], s.cursor[1], 0.0, 0.0);
    setWindows(s, &s.u, s.win_speed);
    setRotation(s, &s.u, bw * 0.5, bh * 0.5);
    s.prog_b.draw();
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    s.b_cur = bnext;

    // --- Buffer C: C <- C(prev), noise, colour, B --------------------------
    const cnext: u1 = 1 - s.c_cur;
    s.c[cnext].begin();
    s.u.use(s.prog_c.program);
    bindTex(gl.GL_TEXTURE0, s.c[s.c_cur].tex);
    s.u.int(.ch0, 0);
    bindTex(gl.GL_TEXTURE1, s.tex_noise_c);
    s.u.int(.ch1, 1);
    bindTex(gl.GL_TEXTURE2, zero);
    s.u.int(.ch2, 2);
    bindTex(gl.GL_TEXTURE3, s.b[s.b_cur].tex);
    s.u.int(.ch3, 3);
    s.u.f3(.res, bw, bh, 1.0);
    s.u.f3(.res0, bw, bh, 1.0);
    s.u.f3(.res1, s.noise_c_res[0], s.noise_c_res[1], 1.0);
    s.u.f1(.time, s.time);
    s.u.int(.frame, s.frame);
    s.u.f4(.mouse, s.cursor[0], s.cursor[1], 0.0, 0.0);
    // C's velocity is 0.5-centred in a field of order 0.1; a huge reference
    // speed makes the body velocity effectively zero, so the obstacle only
    // freezes and deflects.
    setWindows(s, &s.u, 1.0e9);
    setRotation(s, &s.u, bw * 0.5, bh * 0.5);
    s.prog_c.draw();
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    s.c_cur = cnext;

    // --- Buffer D: D <- B, colour, C, B ------------------------------------
    const dnext: u1 = 1 - s.d_cur;
    s.d[dnext].begin();
    s.u.use(s.prog_d.program);
    bindTex(gl.GL_TEXTURE0, s.b[s.b_cur].tex);
    s.u.int(.ch0, 0);
    bindTex(gl.GL_TEXTURE1, zero);
    s.u.int(.ch1, 1);
    bindTex(gl.GL_TEXTURE2, s.c[s.c_cur].tex);
    s.u.int(.ch2, 2);
    bindTex(gl.GL_TEXTURE3, s.b[s.b_cur].tex);
    s.u.int(.ch3, 3);
    s.u.f3(.res, bw, bh, 1.0);
    // D's slow lava-lamp oscillation sets which field feeds A next; run it
    // slower so the large-scale composition breathes instead of churning.
    s.u.f1(.time, s.time * 0.10);
    s.u.int(.frame, s.frame);
    s.u.f4(.mouse, s.cursor[0], s.cursor[1], 0.0, 0.0);
    setRotation(s, &s.u, bw * 0.5, bh * 0.5);
    // The impulses are stirred into Buffer D: it is the state the Image pass
    // reads, so they bend the flow and reach the paint directly.
    setImpulses(s, &s.u);
    s.prog_d.draw();
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    s.d_cur = dnext;

    // --- Image: D, colour, C into the host's display program ---------------
    s.u.use(program);
    // The Image pass turns about the centre of the *surface*, in surface
    // pixels; the buffer passes turn about the centre of the buffer.
    setRotation(s, &s.u, s.width * 0.5, s.height * 0.5);
    bindTex(gl.GL_TEXTURE0, s.d[s.d_cur].tex);
    s.u.int(.ch0, 0);
    bindTex(gl.GL_TEXTURE1, s.paint.tex);
    s.u.int(.ch1, 1);
    bindTex(gl.GL_TEXTURE2, s.c[s.c_cur].tex);
    s.u.int(.ch2, 2);
    s.u.int(.frame, s.frame);
    gl.glActiveTexture(gl.GL_TEXTURE0);

    s.frame += 1;
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    for (&s.a) |*t| t.deinit();
    for (&s.b) |*t| t.deinit();
    for (&s.c) |*t| t.deinit();
    for (&s.d) |*t| t.deinit();
    s.paint.deinit();
    s.prog_a.deinit();
    s.prog_b.deinit();
    s.prog_c.deinit();
    s.prog_d.deinit();
    s.prog_paint.deinit();
    if (s.tex_noise_a != 0) gl.glDeleteTextures(1, &s.tex_noise_a);
    if (s.tex_noise_c != 0) gl.glDeleteTextures(1, &s.tex_noise_c);
    if (s.tex_key != 0) gl.glDeleteTextures(1, &s.tex_key);
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
