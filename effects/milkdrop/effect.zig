//! effects/milkdrop — MilkDrop, the way Ryan Geiss built it.
//!
//! Ported from the built-in `src/effects/milkdrop/context.zig` (with
//! `presets.zig` copied alongside) to the component ABI.
//!
//! A feedback buffer is re-sampled every frame through a per-pixel motion
//! field (zoom, rotation, the four-sine warp, centre, translation, stretch) and
//! decayed, then has this frame's waveforms, shapes and borders drawn on top.
//! Presets are bundles of per-frame equations (`presets.zig`); every so often
//! the next one blends in through a patterned transition, its motion field
//! mixed per pixel. The display pass (`milkdrop.frag`) adds video echo and the
//! gamma/brighten/darken/solarize/invert filters, and lays it over the theme.
//!
//! Structural changes from the built-in, beyond the ABI:
//!   * audio is host-captured — `hg.audio.Analyzer` runs on `hg_frame.wave`
//!     instead of owning a capture thread;
//!   * the feedback ping-pong is two `hg_gl.Target`s and the warp pass an
//!     `hg_gl.Program` (no hand-rolled FBO/textures/VAO);
//!   * the CPU→GL painter is `hg_geometry.zig` (the SDK copy), which
//!     `presets.zig` draws through;
//!   * the theme palette arrives as `hg_frame.palette` floats;
//!   * config comes from the shared `[visualizer]` section (`config_section`),
//!     because the `preset`/`scale`/`cycle` knobs and the audio knobs live
//!     there;
//!   * the RNG seeds from a local monotonic clock (a plugin can't reach the
//!     host's io helper).

const std = @import("std");

const hg = @import("hg.zig");
const hg_gl = @import("hg_gl.zig");
const geometry = @import("hg_geometry.zig");
const presets = @import("presets.zig");

const c = hg.c;
const gl = hg.gl;

const log = std.log.scoped(.milkdrop);

/// Monotonic-clock nanoseconds, for seeding the RNG (a plugin cannot reach
/// the host's io helper).
const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk_id: i32, tp: *Timespec) c_int;

fn nowNs() u64 {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const warp_frag_src: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uPrev;
    \\uniform vec2 uRes;
    \\uniform float uTime;
    \\uniform vec4 uA[5];
    \\uniform vec4 uB[5];
    \\uniform float uBlend;
    \\uniform vec4 uPattern;
    \\out vec4 fragColor;
    \\
    \\float hash12(vec2 p) {
    \\    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    \\    p3 += dot(p3, p3.yzx + 33.33);
    \\    return fract((p3.x + p3.y) * p3.z);
    \\}
    \\
    \\// Where this pixel samples last frame from, for one preset's motion.
    \\// p0 zoom, zoomexp, rot, warp; p1 warp speed, warp scale, cx, cy;
    \\// p2 dx, dy, sx, sy; p3 ripple amp, freq, speed, twist; p4 kaleido.
    \\vec2 motion(vec2 uv, vec4 p0, vec4 p1, vec4 p2, vec4 p3, vec4 p4) {
    \\    float aspect = uRes.x / uRes.y;
    \\    vec2 q = uv - p1.zw;
    \\    q.x *= aspect;
    \\    if (p4.x >= 2.0) {
    \\        float seg = 6.2831853 / floor(p4.x);
    \\        float a = mod(atan(q.y, q.x), seg);
    \\        if (a > seg * 0.5) a = seg - a;
    \\        q = vec2(cos(a), sin(a)) * length(q);
    \\    }
    \\    float rad = length(q) / length(vec2(0.5 * aspect, 0.5));
    \\    float z = pow(p0.x, pow(p0.y, rad * 2.0 - 1.0));
    \\    z += p3.x * sin(rad * p3.y - uTime * p3.z);
    \\    q /= max(z, 0.05);
    \\    float r = p0.z + p3.w * rad;
    \\    float cr = cos(r);
    \\    float sr = sin(r);
    \\    q = mat2(cr, sr, -sr, cr) * q;
    \\    q /= p2.zw;
    \\    q.x /= aspect;
    \\    vec2 u = q + p1.zw - p2.xy;
    \\
    \\    // MilkDrop's warp: four drifting sines.
    \\    float wt = uTime * p1.x;
    \\    float ws = 1.0 / p1.y;
    \\    vec4 f = vec4(11.68 + 4.0 * cos(wt * 1.413 + 10.0), 8.77 + 3.0 * cos(wt * 1.113 + 7.0),
    \\                  10.54 + 3.0 * cos(wt * 1.233 + 3.0), 11.49 + 4.0 * cos(wt * 0.933 + 5.0));
    \\    vec2 xy = uv * 2.0 - 1.0;
    \\    float w = p0.w * 0.0035;
    \\    u.x += w * sin(wt * 0.333 + ws * (xy.x * f.x - xy.y * f.w));
    \\    u.y += w * cos(wt * 0.375 - ws * (xy.x * f.z + xy.y * f.y));
    \\    u.x += w * cos(wt * 0.753 - ws * (xy.x * f.y - xy.y * f.z));
    \\    u.y += w * sin(wt * 0.825 + ws * (xy.x * f.x + xy.y * f.w));
    \\    return u;
    \\}
    \\
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy / uRes;
    \\
    \\    // Transition: B takes over pixel by pixel in the pattern's order.
    \\    float pat = 0.0;
    \\    int kind = int(uPattern.x);
    \\    vec2 cuv = (uv - 0.5) * vec2(uRes.x / uRes.y, 1.0);
    \\    if (kind == 1) pat = clamp(length(cuv) * 1.3, 0.0, 1.0);
    \\    else if (kind == 2) pat = 1.0 - clamp(length(cuv) * 1.3, 0.0, 1.0);
    \\    else if (kind == 3) pat = clamp(dot(uv - 0.5, vec2(cos(uPattern.y), sin(uPattern.y))) + 0.5, 0.0, 1.0);
    \\    else if (kind == 4) pat = 0.5 + 0.25 * sin(cuv.x * 7.0 + uPattern.y) + 0.25 * sin(cuv.y * 9.0 - uPattern.y * 1.7);
    \\    else if (kind == 5) pat = hash12(floor(uv * 12.0) + uPattern.y);
    \\    float k = kind == 0 ? 0.0 : 3.0;
    \\    float b = smoothstep(0.0, 1.0, clamp(uBlend * (1.0 + k) - pat * k, 0.0, 1.0));
    \\
    \\    vec2 ua = motion(uv, uA[0], uA[1], uA[2], uA[3], uA[4]);
    \\    vec2 ub = motion(uv, uB[0], uB[1], uB[2], uB[3], uB[4]);
    \\    vec2 u = mix(ua, ub, b);
    \\    float decay = mix(uA[4].y, uB[4].y, b);
    \\    float wrap = mix(uA[4].z, uB[4].z, b);
    \\
    \\    vec3 prev = texture(uPrev, u).rgb;
    \\    // Without wrap, whatever slides in from off-screen is black.
    \\    vec2 off = step(vec2(0.0), u) * step(u, vec2(1.0));
    \\    prev *= mix(off.x * off.y, 1.0, step(0.5, wrap));
    \\    // Decay, less a hair so no trail lingers forever.
    \\    fragColor = vec4(max(prev * decay - 1.0 / 1024.0, 0.0), 1.0);
    \\}
;

const State = struct {
    music: hg.audio.Analyzer = .{},
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    sim_w: i32,
    sim_h: i32,

    /// Ping-pong feedback: the warp pass reads one and writes the other.
    target: [2]hg_gl.Target = .{ .{}, .{} },
    current: u1 = 0,
    warp_prog: hg_gl.Program = .{},
    painter: geometry.Painter = .{},
    /// GL objects above exist (see ensureGl); false after a failed try too,
    /// with `gl_failed` set so it isn't retried every frame.
    gl_ready: bool = false,
    gl_failed: bool = false,

    wu: hg.Uniforms(.{
        .prev = "uPrev",
        .res = "uRes",
        .time = "uTime",
        .a = "uA[0]",
        .b = "uB[0]",
        .blend = "uBlend",
        .pattern = "uPattern",
    }) = .{},
    mu: hg.Uniforms(.{
        .sprite = "iSprite",
        .echo = "iMdEcho",
        .tone = "iMdTone",
        .invert = "iMdInvert",
    }) = .{},

    /// Backing store for the two batches.
    verts: []geometry.Vertex,
    /// Two geometry batches per frame: alpha-blended, then additive.
    alpha_batch: geometry.Batch,
    add_batch: geometry.Batch,

    now: f64 = 0,
    in: presets.Inputs = .{},
    frame_a: presets.Frame = .{},
    frame_b: presets.Frame = .{},

    // Preset rotation.
    pinned: ?usize,
    cycle: f32,
    cur: usize = 0,
    next: ?usize = null,
    blend: f32 = 0,
    blend_rate: f32 = 0.25,
    pattern: [2]f32 = .{ 0, 0 },
    preset_left: f32 = 0,
    since_switch: f32 = 0,

    /// Idle "dream" wave mix: 1 with no music, 0 with a real signal.
    idle: f32 = 1,
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    const hp = hg.Host{ .raw = @ptrCast(host) };

    const verts = hg.allocator.alloc(geometry.Vertex, geometry.max_verts * 2) catch return null;
    const state = hg.allocator.create(State) catch {
        hg.allocator.free(verts);
        return null;
    };

    var pinned: ?usize = null;
    if (hp.getString("preset")) |name| {
        pinned = presets.find(name);
        if (pinned == null) log.warn("unknown preset '{s}', cycling through all", .{name});
    }
    const scale = std.math.clamp(hp.getFloat("scale", 0.5), 0.25, 1.0);
    const sim_w: i32 = @intFromFloat(@ceil(width * scale));
    const sim_h: i32 = @intFromFloat(@ceil(height * scale));
    const px = [2]f32{ @floatFromInt(sim_w), @floatFromInt(sim_h) };

    var rng = std.Random.DefaultPrng.init(nowNs());
    const first = pinned orelse rng.random().uintLessThan(usize, presets.all.len);

    state.* = .{
        .rng = rng,
        .width = width,
        .height = height,
        .sim_w = sim_w,
        .sim_h = sim_h,
        .verts = verts,
        .alpha_batch = .{ .verts = verts[0..geometry.max_verts], .px = px },
        .add_batch = .{ .verts = verts[geometry.max_verts..], .px = px },
        .pinned = pinned,
        .cycle = std.math.clamp(hp.getFloat("cycle", 24.0), 4.0, 600.0),
        .cur = first,
        .preset_left = 0,
    };
    return @ptrCast(state);
}

fn rand(s: *State) f32 {
    return s.rng.random().float(f32);
}

/// Start blending toward a different preset over `secs`.
fn beginTransition(s: *State, secs: f32) void {
    if (s.pinned != null or s.next != null) return;
    var n = s.rng.random().uintLessThan(usize, presets.all.len - 1);
    if (n >= s.cur) n += 1;
    s.next = n;
    s.blend = 0;
    s.blend_rate = 1.0 / secs;
    s.pattern = .{ @floatFromInt(s.rng.random().uintLessThan(u8, 6)), rand(s) * std.math.tau };
    s.since_switch = 0;
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const fr: *const c.hg_frame = @ptrCast(frame);

    const dt = std.math.clamp(fr.dt, 0.0, 0.05);
    s.now += dt;
    const t: f32 = @floatCast(@mod(s.now, 3600.0));

    var wave = [_]f32{0} ** 256;
    if (fr.wave != null and fr.wave_len >= wave.len) @memcpy(&wave, fr.wave[0..wave.len]);
    const kick = s.music.update(&wave, dt);

    // Real waveform when there is one, the dream wave when quiet.
    var rms: f32 = 0;
    for (wave) |v| rms += v * v;
    rms = @sqrt(rms / 256.0);
    const quiet: f32 = 1.0 - std.math.clamp((rms - 0.01) / 0.05, 0.0, 1.0);
    s.idle += (quiet - s.idle) * @min(1.0, 2.0 * dt);
    if (s.idle > 0.001) {
        for (0..128) |i| {
            const x: f32 = @floatFromInt(i);
            const l = 0.32 * @sin(x * 0.17 + t * 3.1) * @sin(t * 0.63) +
                0.18 * @sin(x * 0.051 - t * 1.37) + 0.08 * @sin(x * 0.61 + t * 5.3);
            const r = 0.32 * @sin(x * 0.17 + t * 3.1 + 1.3) * @sin(t * 0.63 + 0.4) +
                0.18 * @sin(x * 0.047 - t * 1.29) + 0.08 * @sin(x * 0.57 + t * 4.7);
            wave[i] = wave[i] * (1 - s.idle) + l * s.idle;
            wave[128 + i] = wave[128 + i] * (1 - s.idle) + r * s.idle;
        }
    }
    const mags = hg.audio.magnitudes(&wave);

    // Inputs every preset's equations see. Quiet, the bands breathe on
    // slow LFOs instead of sitting at zero.
    const lfo = s.idle * 0.35;
    var in = &s.in;
    in.t = t;
    in.dt = dt;
    in.bass = @max(s.music.bass(), lfo * (0.6 + 0.4 * @sin(t * 0.9)));
    in.mid = @max((s.music.bands.smooth[2] + s.music.bands.smooth[3]) * 0.5, lfo * (0.6 + 0.4 * @sin(t * 0.71 + 2.0)));
    in.treb = @max(s.music.treble(), lfo * (0.6 + 0.4 * @sin(t * 1.13 + 4.0)));
    in.beat = s.music.beat();
    if (kick) in.beats +%= 1;
    // Quiet, a soft synthetic pulse keeps beat-driven presets moving.
    if (s.idle > 0.5) {
        const ph = @mod(t, 2.4);
        in.beat = @max(in.beat, @exp(-ph * 5.0) * 0.6);
        if (ph < dt) in.beats +%= 1;
    }
    in.wave = wave;
    @memcpy(in.spectrum[0..], mags[0..in.spectrum.len]);
    in.aspect = s.width / s.height;
    in.cursor = .{ fr.cursor[0] / s.width, fr.cursor[1] / s.height };
    const fw = fr.focused_win;
    in.focus = if (fw.w >= 1.0)
        .{ (fw.x + fw.w * 0.5) / s.width, (fw.y + fw.h * 0.5) / s.height }
    else
        .{ 0.5, 0.5 };
    const nwin: usize = @intCast(@min(fr.windows_len, @as(u64, in.windows.len)));
    in.window_count = nwin;
    if (nwin > 0 and fr.windows != null) {
        for (fr.windows[0..nwin], 0..) |w, i| {
            in.windows[i] = .{ w.x / s.width, w.y / s.height, w.w / s.width, w.h / s.height };
        }
    }
    if (fr.palette != null and fr.palette_len > 0) in.setPalette(fr.palette, @intCast(fr.palette_len));

    // Rotation: a soft blend on the timer, a quick one on a big kick.
    s.since_switch += dt;
    s.preset_left -= dt;
    if (s.preset_left <= 0) {
        s.preset_left = s.cycle * (0.75 + 0.5 * rand(s));
        if (s.since_switch > 1.0) beginTransition(s, 2.5 + 2.5 * rand(s));
    } else if (kick and s.since_switch > s.cycle * 0.4 and rand(s) < 0.2) {
        s.preset_left = s.cycle * (0.75 + 0.5 * rand(s));
        beginTransition(s, 0.7);
    }
    if (s.next) |n| {
        s.blend += dt * s.blend_rate;
        if (s.blend >= 1.0) {
            s.cur = n;
            s.next = null;
            s.blend = 0;
        }
    }

    s.frame_a = .{};
    presets.all[s.cur].eval(in, &s.frame_a);
    if (s.next) |n| {
        s.frame_b = .{};
        presets.all[n].eval(in, &s.frame_b);
    } else s.frame_b = s.frame_a;

    // Geometry for both presets, each faded by its share of the blend.
    s.alpha_batch.len = 0;
    s.add_batch.len = 0;
    const share = smooth(s.blend);
    s.frame_a.draw(in, &s.alpha_batch, &s.add_batch, if (s.next != null) 1.0 - share else 1.0);
    if (s.next != null) s.frame_b.draw(in, &s.alpha_batch, &s.add_batch, share);
}

fn smooth(x: f32) f32 {
    const t = std.math.clamp(x, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Create the ping-pong targets, warp program and vertex buffer on first
/// upload: `create` runs before the GL context it would draw with exists
/// (and again for a fresh context after a loss).
fn ensureGl(s: *State) bool {
    if (s.gl_ready) return true;
    if (s.gl_failed) return false;
    s.gl_failed = true;

    s.warp_prog = hg_gl.Program.init(warp_frag_src) catch {
        log.err("warp program failed", .{});
        return false;
    };
    s.painter = geometry.Painter.init(geometry.max_verts) catch return false;

    // Half float, so a slow decay fades out instead of sticking at the last
    // 8-bit step (MilkDrop's old residue). 8-bit if unsupported.
    for (&s.target) |*tg| {
        tg.* = hg_gl.Target.init(s.sim_w, s.sim_h, .{
            .format = .rgba16f,
            .half_float_fallback = true,
            .filter = .linear,
            .wrap = .repeat,
        }) catch return false;
    }
    for (&s.target) |*tg| {
        tg.begin();
        gl.glClearColor(0, 0, 0, 1);
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

    if (ensureGl(s)) {
        const prev = s.current;
        const curr = 1 - s.current;

        // --- Pass 1: warp last frame through the motion field ---
        s.target[curr].begin();
        s.wu.use(s.warp_prog.program);
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, s.target[prev].tex);
        s.wu.int(.prev, 0);
        s.wu.f2(.res, @floatFromInt(s.sim_w), @floatFromInt(s.sim_h));
        s.wu.f1(.time, s.in.t);
        const pa = s.frame_a.motion.pack();
        const pb = s.frame_b.motion.pack();
        s.wu.f4v(.a, 5, &pa);
        s.wu.f4v(.b, 5, &pb);
        s.wu.f1(.blend, if (s.next != null) s.blend else 0);
        s.wu.f4(.pattern, s.pattern[0], s.pattern[1], 0, 0);
        s.warp_prog.draw();

        // --- Pass 2: this frame's shapes, borders and waves ---
        s.painter.draw(&s.alpha_batch, .alpha);
        s.painter.draw(&s.add_batch, .additive);

        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
        s.current = curr;
    }

    // --- Display: hand the frame to the main shader ---
    const m = presets.Motion.lerp(s.frame_a.motion, s.frame_b.motion, if (s.next != null) smooth(s.blend) else 0);
    s.mu.use(program);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.target[s.current].tex);
    s.mu.int(.sprite, 0);
    s.mu.f4(.echo, m.echo_alpha, m.echo_zoom, @round(m.echo_orient), 0);
    s.mu.f4(.tone, m.gamma, m.brighten, m.darken, m.solarize);
    s.mu.f1(.invert, m.invert);
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    s.target[0].deinit();
    s.target[1].deinit();
    s.warp_prog.deinit();
    s.painter.deinit();
    hg.allocator.free(s.verts);
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "milkdrop",
    .shader = "milkdrop.frag",
    // `preset`/`scale`/`cycle` and the `music`/`sink` audio knobs live in the
    // shared [visualizer] section.
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
