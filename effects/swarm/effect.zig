//! effects/swarm — a murmuration that roosts on your windows and scatters at
//! a hawk.
//!
//! Ported from the built-in `src/effects/swarm/context.zig` to the component
//! ABI. The flock simulation (`boids.zig`), its clock (`clock.zig`) and the
//! window rectangle it steers around (`rect.zig`) travel with the component;
//! everything else comes from the host through `hg_frame`:
//!
//!   * audio is host-captured — the six-band/beat `hg.audio.Splitter` runs on
//!     `hg_frame.wave` instead of owning a capture thread;
//!   * windows, cursor and palette are copied from the frame (frame pointers
//!     are only valid during `update`);
//!   * the offscreen compute pass builds its program (and the standard
//!     `iResolution`/`iWindows`/`iPalette*` uniforms) with `hg_gl.Program`.
//!
//! Field resolution: the flock is splatted into a coarse grid each frame and
//! the shader renders the field, not the boids — that's what turns dots into a
//! continuous murmuration. The main `swarm.frag` nearest-upscales that canvas
//! to the screen, so the pixelation IS the optimization.

const std = @import("std");

const hg = @import("hg.zig");
const hg_gl = @import("hg_gl.zig");
const boids = @import("boids.zig");
const rect = @import("rect.zig");

const c = hg.c;
const gl = hg.gl;

// ~19px cells at 3072x1728.
const field_w = 160;
const field_h = 90;
const field_cells = field_w * field_h;

// Velocity normalization for the RG channels (pixels/sec mapped to ±1).
const vel_scale: f32 = 700.0;

const max_windows = hg_gl.max_windows;
const max_palette = hg_gl.max_palette;

// One fragment per block: canvas = screen / pixel_size, then the main shader
// nearest-upscales. At 30px blocks that's ~6k fragments doing the streaks/fbm
// math instead of millions.
const compute_frag: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\
    \\uniform vec3 iResolution;
    \\uniform float iPixel;
    \\uniform float iSwarmTime;
    \\uniform vec4 iWindows[32];
    \\uniform int iWindowCount;
    \\
    \\uniform vec3 iPalette[16];
    \\uniform int iPaletteSize;
    \\uniform vec3 iPaletteBg;
    \\uniform vec3 iPaletteFg;
    \\
    \\uniform sampler2D iField;
    \\uniform float iBeat;
    \\uniform float iBass;
    \\uniform float iEnergy;
    \\uniform float iMute;
    \\uniform float iContour;
    \\
    \\out vec4 fragColor;
    \\
    \\float hash21(vec2 p) {
    \\    p = fract(p * vec2(123.34, 456.21));
    \\    p += dot(p, p + 45.32);
    \\    return fract(p.x * p.y);
    \\}
    \\
    \\float vnoise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    float a = hash21(i);
    \\    float b = hash21(i + vec2(1.0, 0.0));
    \\    float c = hash21(i + vec2(0.0, 1.0));
    \\    float d = hash21(i + vec2(1.0, 1.0));
    \\    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    \\}
    \\
    \\float fbm(vec2 p) {
    \\    float v = 0.0;
    \\    float a = 0.5;
    \\    for (int i = 0; i < 4; i++) {
    \\        v += a * vnoise(p);
    \\        p = p * 2.1 + 17.3;
    \\        a *= 0.5;
    \\    }
    \\    return v;
    \\}
    \\
    \\float streakDensity(vec2 uv, vec2 vel_uv) {
    \\    float total = texture(iField, uv).a * 1.2;
    \\    float wsum = 1.2;
    \\    for (int k = 1; k <= 3; k++) {
    \\        float t = float(k) / 3.0;
    \\        float w = 1.0 - t * 0.65;
    \\        total += texture(iField, uv - vel_uv * t).a * w;
    \\        total += texture(iField, uv + vel_uv * t * 0.4).a * w * 0.6;
    \\        wsum += w * 1.6;
    \\    }
    \\    return total / wsum;
    \\}
    \\
    \\float sdRoundBox(vec2 p, vec2 center, vec2 half_size, float radius) {
    \\    vec2 d = abs(p - center) - half_size + radius;
    \\    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
    \\}
    \\
    \\void main() {
    \\    vec2 fc = gl_FragCoord.xy * iPixel;
    \\    vec2 uv = fc / iResolution.xy;
    \\
    \\    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02, 0.025, 0.04);
    \\    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    \\    vec3 elev0 = (iPaletteSize > 4) ? iPalette[4] : vec3(0.25, 0.35, 0.70);
    \\    vec3 elev1 = (iPaletteSize > 6) ? iPalette[6] : vec3(0.30, 0.60, 0.80);
    \\    vec3 elev2 = (iPaletteSize > 2) ? iPalette[2] : vec3(0.30, 0.70, 0.40);
    \\    vec3 elev3 = (iPaletteSize > 3) ? iPalette[3] : vec3(0.80, 0.70, 0.30);
    \\    vec3 hot   = (iPaletteSize > 9) ? iPalette[9] : vec3(1.0, 0.4, 0.3);
    \\
    \\    float sky = 1.0 - uv.y * 0.25;
    \\    vec3 col = bg * (0.8 * sky + 0.06 * fbm(uv * 3.0 + iSwarmTime * 0.02));
    \\
    \\    vec4 field = texture(iField, uv);
    \\    vec2 vel = (field.rg - 0.5) * 2.0;
    \\    float agit = field.b;
    \\
    \\    vec2 vel_uv = vel * 0.08;
    \\    float dens = streakDensity(uv, vel_uv);
    \\
    \\    float feather = fbm(fc * 0.013 - vel * 2.5 + vec2(0.0, iSwarmTime * 0.35));
    \\    dens *= 0.55 + 0.9 * feather;
    \\    dens *= 1.0 + iBass * 0.5;
    \\
    \\    float panic = agit * (0.7 + 0.3 * vnoise(fc * 0.05 + iSwarmTime * 9.0));
    \\
    \\    const float levels = 4.0;
    \\    float q = dens * levels;
    \\    float level = floor(q);
    \\    float g = fract(q);
    \\    float line_d = min(g, 1.0 - g);
    \\    float lw = fwidth(q) * 0.7 + 0.01;
    \\    float iso = 1.0 - smoothstep(lw, lw * 1.8, line_d);
    \\
    \\    float lt = (iContour > 0.5)
    \\        ? clamp(level / levels, 0.0, 1.0)
    \\        : floor(clamp(dens, 0.0, 1.0) * 5.0 + 0.5) / 5.0;
    \\    float e = lt * 4.0;
    \\    vec3 ramp;
    \\    if      (e < 1.0) ramp = mix(elev0, elev1, e);
    \\    else if (e < 2.0) ramp = mix(elev1, elev2, e - 1.0);
    \\    else if (e < 3.0) ramp = mix(elev2, elev3, e - 2.0);
    \\    else              ramp = mix(elev3, fg, min(e - 3.0, 1.0));
    \\    float lum = dot(ramp, vec3(0.299, 0.587, 0.114));
    \\    ramp = mix(ramp, vec3(lum), iMute);
    \\    ramp = mix(ramp, fg, 0.15);
    \\    ramp = mix(ramp, hot, clamp(panic * 1.4, 0.0, 0.75));
    \\
    \\    float present = smoothstep(0.02, 0.10, dens);
    \\    if (iContour > 0.5) {
    \\        col += ramp * iso * present * (0.8 + iEnergy * 0.4);
    \\    } else {
    \\        float fill = smoothstep(0.03, 0.75, dens);
    \\        fill = floor(fill * 5.0 + 0.5) / 5.0;
    \\        col += ramp * fill * (0.7 + iEnergy * 0.4);
    \\    }
    \\
    \\    for (int i = 0; i < iWindowCount && i < 32; i++) {
    \\        vec4 win = iWindows[i];
    \\        if (win.z < 1.0 || win.w < 1.0) continue;
    \\        float d = sdRoundBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5, 8.0);
    \\        if (d < 0.0 || d > 60.0) continue;
    \\        col += ramp * exp(-d * d / 800.0) * 0.08 * present * (1.0 + iBeat);
    \\    }
    \\
    \\    col += (hash21(fc + fract(iSwarmTime) * 100.0) - 0.5) * 0.012;
    \\
    \\    fragColor = vec4(col, 1.0);
    \\}
;

const Accum = struct {
    dens: [field_cells]f32,
    velx: [field_cells]f32,
    vely: [field_cells]f32,
    agit: [field_cells]f32,
    bytes: [field_cells * 4]u8,
};

const State = struct {
    sys: boids.BoidSystem,
    accum: *Accum,

    now: f64 = 0,
    an: hg.audio.Splitter = .{},

    quiet_t: f32 = 0,
    roost: f32 = 0,

    // Frame snapshot for the compute pass (hg_frame pointers are only valid
    // during `update`).
    windows: [max_windows]c.hg_rect = undefined,
    window_count: u8 = 0,
    palette: [max_palette][3]f32 = undefined,
    palette_len: u32 = 0,
    palette_bg: [3]f32 = .{ 0, 0, 0 },
    palette_fg: [3]f32 = .{ 1, 1, 1 },

    // Render config (set at create from the effect's config section).
    mute: f32 = 0.55,
    pixel: f32 = 30.0,
    contour: bool = false,

    // GL resources — created lazily on first upload, when GL is current.
    field_tex: gl.GLuint = 0,
    canvas_tex: gl.GLuint = 0,
    fbo: gl.GLuint = 0,
    canvas_w: gl.GLsizei = 0,
    canvas_h: gl.GLsizei = 0,
    compute: ?hg_gl.Program = null,

    cu: hg.Uniforms(.{
        .field = "iField",
        .pixel = "iPixel",
        .time = "iSwarmTime",
        .beat = "iBeat",
        .bass = "iBass",
        .energy = "iEnergy",
        .mute = "iMute",
        .contour = "iContour",
    }) = .{},
    mu: hg.Uniforms(.{ .canvas = "iCanvas" }) = .{},
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    const hp = hg.Host{ .raw = @ptrCast(host) };
    const state = hg.allocator.create(State) catch return null;
    const accum = hg.allocator.create(Accum) catch {
        hg.allocator.destroy(state);
        return null;
    };
    accum.* = std.mem.zeroes(Accum);

    const count: u32 = @intCast(std.math.clamp(hp.getInt("count", 240), 0, boids.max_boids));
    var sys = boids.BoidSystem.init(count, width, height);
    sys.base_speed = hp.getFloat("speed", 220.0);
    sys.perception = hp.getFloat("perception", 240.0);
    sys.separation_dist = hp.getFloat("separation", 54.0);

    state.* = .{
        .sys = sys,
        .accum = accum,
        .mute = hp.getFloat("mute", 0.55),
        .pixel = std.math.clamp(hp.getFloat("pixel", 30.0), 1.0, 120.0),
        .contour = hp.getBool("contour", false),
    };
    return @ptrCast(state);
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);

    const dt = @min(f.dt, 0.05);
    s.now += dt;

    var wave: [256]f32 = [_]f32{0} ** 256;
    if (f.wave != null and f.wave_len >= wave.len) @memcpy(&wave, f.wave[0..wave.len]);

    // 6 spectrum bands + beat detection (shared SDK splitter).
    const beat_hit = s.an.update(&wave, dt);
    var punch: f32 = 1.0;
    if (beat_hit)
        punch = std.math.clamp(s.an.flux / (s.an.flux_avg * 3.0 + 0.03), 1.0, 2.0);

    // Silence settles the flock; sound lifts it.
    if (s.an.energy < 0.05) {
        s.quiet_t += dt;
    } else {
        s.quiet_t = @max(0.0, s.quiet_t - dt * 6.0);
    }
    const roost_target: f32 = std.math.clamp((s.quiet_t - 4.0) / 3.0, 0.0, 1.0);
    const roost_prev = s.roost;
    const roost_k: f32 = if (roost_target > s.roost) 0.5 else 2.5;
    s.roost += (roost_target - s.roost) * @min(1.0, roost_k * dt);
    const burst = roost_prev > 0.55 and s.roost <= 0.55;

    // Snapshot windows, then hand the flock plain rects to steer around.
    s.window_count = @intCast(@min(f.windows_len, max_windows));
    for (0..s.window_count) |i| s.windows[i] = f.windows[i];

    var rects: [max_windows]rect.Rect = undefined;
    for (0..s.window_count) |i| {
        const w = s.windows[i];
        rects[i] = .{ .x = w.x, .y = w.y, .w = w.w, .h = w.h };
    }

    s.sys.update(dt, f.cursor[0], f.cursor[1], rects[0..s.window_count], .{
        .bass = s.an.bass,
        .beat = s.an.beat,
        .beat_hit = beat_hit,
        .punch = punch,
        .total_energy = s.an.energy,
        .roost = s.roost,
        .burst = burst,
    });

    // Snapshot the palette (frame pointers don't outlive update).
    s.palette_len = if (f.palette == null) 0 else @min(f.palette_len, max_palette);
    for (0..s.palette_len) |i| {
        s.palette[i] = .{ f.palette[i * 3], f.palette[i * 3 + 1], f.palette[i * 3 + 2] };
    }
    s.palette_bg = .{ f.palette_bg[0], f.palette_bg[1], f.palette_bg[2] };
    s.palette_fg = .{ f.palette_fg[0], f.palette_fg[1], f.palette_fg[2] };

    splatField(s);
}

/// Rasterize the flock into the density/velocity/agitation field. Each boid
/// drops a 7x7 gaussian; velocity is density-weighted so the shader can streak
/// the cloud along local motion.
fn splatField(s: *State) void {
    const a = s.accum;
    @memset(&a.dens, 0);
    @memset(&a.velx, 0);
    @memset(&a.vely, 0);
    @memset(&a.agit, 0);

    const sx = @as(f32, field_w) / s.sys.width;
    const sy = @as(f32, field_h) / s.sys.height;

    for (0..s.sys.count) |i| {
        const b = s.sys.boids[i];
        const fx = b.x * sx;
        const fy = b.y * sy;
        const cx: i32 = @intFromFloat(@floor(fx));
        const cy: i32 = @intFromFloat(@floor(fy));

        var oy: i32 = -3;
        while (oy <= 3) : (oy += 1) {
            var ox: i32 = -3;
            while (ox <= 3) : (ox += 1) {
                const gx = cx + ox;
                const gy = cy + oy;
                if (gx < 0 or gx >= field_w or gy < 0 or gy >= field_h) continue;
                const dx = (@as(f32, @floatFromInt(gx)) + 0.5) - fx;
                const dy = (@as(f32, @floatFromInt(gy)) + 0.5) - fy;
                const w = @exp(-(dx * dx + dy * dy) * 0.22);
                const idx: usize = @intCast(gy * field_w + gx);
                a.dens[idx] += w;
                a.velx[idx] += b.vx * w;
                a.vely[idx] += b.vy * w;
                a.agit[idx] += b.agit * w;
            }
        }
    }

    // Pack to RGBA8: R/G = density-weighted velocity (biased ±vel_scale),
    // B = agitation, A = soft-saturated density.
    for (0..field_cells) |i| {
        const d = a.dens[i];
        var vx: f32 = 0;
        var vy: f32 = 0;
        var ag: f32 = 0;
        if (d > 0.001) {
            vx = std.math.clamp(a.velx[i] / d / vel_scale, -1.0, 1.0);
            vy = std.math.clamp(a.vely[i] / d / vel_scale, -1.0, 1.0);
            ag = std.math.clamp(a.agit[i] / d, 0.0, 1.0);
        }
        const dens = 1.0 - @exp(-d * 0.55);
        a.bytes[i * 4 + 0] = @intFromFloat((vx * 0.5 + 0.5) * 255.0);
        a.bytes[i * 4 + 1] = @intFromFloat((vy * 0.5 + 0.5) * 255.0);
        a.bytes[i * 4 + 2] = @intFromFloat(ag * 255.0);
        a.bytes[i * 4 + 3] = @intFromFloat(dens * 255.0);
    }
}

fn ensureGl(s: *State) bool {
    if (s.compute != null) return true;

    s.compute = hg_gl.Program.init(compute_frag) catch return false;

    gl.glGenTextures(1, &s.field_tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.field_tex);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, field_w, field_h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    // Canvas: one texel per block, nearest-upscaled by the main shader.
    s.canvas_w = @intFromFloat(@ceil(s.sys.width / s.pixel));
    s.canvas_h = @intFromFloat(@ceil(s.sys.height / s.pixel));
    gl.glGenTextures(1, &s.canvas_tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.canvas_tex);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, s.canvas_w, s.canvas_h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    gl.glGenFramebuffers(1, &s.fbo);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, s.fbo);
    gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, s.canvas_tex, 0);
    const status = gl.glCheckFramebufferStatus(gl.GL_FRAMEBUFFER);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    return status == gl.GL_FRAMEBUFFER_COMPLETE;
}

/// Push the snapshot palette onto a compute program (its `iPalette*` locations
/// are public fields of `hg_gl.Program`).
fn pushPalette(s: *const State, p: *const hg_gl.Program) void {
    var i: u32 = 0;
    while (i < s.palette_len) : (i += 1) {
        if (p.i_palette[i] >= 0)
            gl.glUniform3f(p.i_palette[i], s.palette[i][0], s.palette[i][1], s.palette[i][2]);
    }
    if (p.i_palette_size >= 0) gl.glUniform1i(p.i_palette_size, @intCast(s.palette_len));
    if (p.i_palette_bg >= 0)
        gl.glUniform3f(p.i_palette_bg, s.palette_bg[0], s.palette_bg[1], s.palette_bg[2]);
    if (p.i_palette_fg >= 0)
        gl.glUniform3f(p.i_palette_fg, s.palette_fg[0], s.palette_fg[1], s.palette_fg[2]);
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    if (!ensureGl(s)) return;
    const cp = &s.compute.?;

    // ---- compute pass: render the effect at one fragment per block ----
    cp.use();

    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.field_tex);
    gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, field_w, field_h, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &s.accum.bytes[0]);

    s.cu.use(cp.program);
    s.cu.int(.field, 0);
    pushPalette(s, cp);
    cp.setResolution(s.sys.width, s.sys.height);
    for (0..s.window_count) |i| {
        if (cp.i_windows[i] >= 0) {
            const w = s.windows[i];
            gl.glUniform4f(cp.i_windows[i], w.x, w.y, w.w, w.h);
        }
    }
    if (cp.i_window_count >= 0) gl.glUniform1i(cp.i_window_count, s.window_count);

    s.cu.f1(.pixel, s.pixel);
    s.cu.f1(.time, @floatCast(s.now));
    s.cu.f1(.beat, s.an.beat);
    s.cu.f1(.bass, s.an.bass);
    s.cu.f1(.energy, s.an.energy);
    s.cu.f1(.mute, s.mute);
    s.cu.f1(.contour, if (s.contour) 1.0 else 0.0);

    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, s.fbo);
    gl.glViewport(0, 0, s.canvas_w, s.canvas_h);
    cp.draw();
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);

    // ---- main pass: hand the canvas to the upscale shader ----
    s.mu.use(program);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.canvas_tex);
    s.mu.int(.canvas, 0);
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    if (s.fbo != 0) gl.glDeleteFramebuffers(1, &s.fbo);
    if (s.canvas_tex != 0) gl.glDeleteTextures(1, &s.canvas_tex);
    if (s.field_tex != 0) gl.glDeleteTextures(1, &s.field_tex);
    if (s.compute) |*cp| cp.deinit();
    hg.allocator.destroy(s.accum);
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "swarm",
    .shader = "swarm.frag",
    .wants_audio = 1,
    .create = create,
    .update = update,
    .upload = upload,
    .destroy = destroy,
};

export fn hg_module_entry() callconv(.c) *const c.hg_module {
    return &module;
}
