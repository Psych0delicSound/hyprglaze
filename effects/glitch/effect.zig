//! effects/glitch — a circuit-bent video feedback loop.
//!
//! Ported from the built-in `src/effects/glitch.zig` to the component ABI.
//! The loop runs in an offscreen pass at video resolution: each sim tick
//! re-films the last frame through a zoom and twist about the focused window,
//! so every frame recurses outward in a tunnel of its own copies. The bends
//! are what a probe on the wrong pin does: the camera's frame rate drops or
//! locks (stutter, freeze), horizontal bands stop updating, hsync drifts and
//! shears rows, vsync loses lock and rolls, and shorted data lines overflow
//! the signal so it wraps into contour bands.
//!
//! Structural changes from the built-in, beyond the ABI:
//!   * audio is host-captured — `hg.audio.Analyzer` runs on `hg_frame.wave`
//!     instead of owning a capture thread;
//!   * the sim program and ping-pong targets are built with `hg_gl.Program` /
//!     `hg_gl.Target`; the history texture array stays hand-rolled because a
//!     blit-to-layer is bespoke to this effect;
//!   * windows, focus and cursor are snapshotted from the frame (frame
//!     pointers are only valid during `update`).
//!
//! Texture channels: r = luma, g = accent strength, b = accent hue (0..1).

const std = @import("std");

const hg = @import("hg.zig");
const hg_gl = @import("hg_gl.zig");

const c = hg.c;
const gl = hg.gl;

const max_windows = hg_gl.max_windows;

/// Monotonic-clock nanoseconds, for seeding the RNG (a plugin cannot reach
/// the host's io helper).
const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk_id: i32, tp: *Timespec) c_int;

fn nowNs() u64 {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const sim_frag: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec3 iResolution;
    \\uniform vec4 iWindow;
    \\uniform vec4 iWindows[32];
    \\uniform int iWindowCount;
    \\uniform vec4 iMouse;
    \\uniform sampler2D uPrev;
    \\uniform float uDiv;
    \\uniform vec2 uCenter;
    \\uniform vec4 uXform;
    \\uniform vec4 uTone;
    \\uniform vec4 uSync;
    \\uniform vec4 uBands;
    \\uniform vec4 uShort;
    \\uniform vec2 uAccent;
    \\uniform vec4 uLoop;
    \\uniform float uMeanLod;
    \\uniform float uTick;
    \\out vec4 fragColor;
    \\
    \\float hash12(vec2 p) {
    \\    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    \\    p3 += dot(p3, p3.yzx + 33.33);
    \\    return fract((p3.x + p3.y) * p3.z);
    \\}
    \\
    \\float boxSd(vec2 p, vec4 r) {
    \\    vec2 q = abs(p - (r.xy + r.zw * 0.5)) - r.zw * 0.5;
    \\    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    \\}
    \\
    \\void main() {
    \\    vec2 fc = gl_FragCoord.xy;
    \\    vec2 res = iResolution.xy;
    \\
    \\    // Stuck bands: rows whose line buffer stopped latching.
    \\    float band = floor(fc.y / uBands.z);
    \\    if (hash12(vec2(band, uBands.y)) < uBands.x) {
    \\        fragColor = texelFetch(uPrev, ivec2(fc), 0);
    \\        return;
    \\    }
    \\
    \\    // Sync: hsync jitter shears rows, vsync slip rolls the frame. Both
    \\    // are per-tick offsets, so the loop integrates them into drift.
    \\    float dx = uSync.x * (sin(fc.y * 0.021 + uSync.y) + 0.5 * sin(fc.y * 0.093 - uSync.y * 1.7));
    \\    dx += uSync.w * step(0.5, hash12(vec2(floor(fc.y / 3.0), floor(uTick))));
    \\    vec2 src = fc + vec2(dx, uSync.z);
    \\
    \\    // The camera: zoom and twist about the centre, then pan.
    \\    vec2 q = src - uCenter;
    \\    float cr = cos(uXform.y);
    \\    float sr = sin(uXform.y);
    \\    q = mat2(cr, sr, -sr, cr) * q / uXform.x;
    \\    vec2 s = uCenter + q + uXform.zw;
    \\    // Mirror bend: a second camera filming the first one's reflection.
    \\    if (uLoop.z > 0.0) {
    \\        vec2 m = vec2(2.0 * uCenter.x - s.x, s.y);
    \\        if (textureLod(uPrev, m / res, 0.0).r > textureLod(uPrev, s / res, 0.0).r) s = mix(s, m, uLoop.z);
    \\    }
    \\    vec2 suv = s / res;
    \\    vec4 prev = textureLod(uPrev, suv, 0.0);
    \\    vec4 near = texelFetch(uPrev, ivec2(mod(floor(s), res)), 0);
    \\
    \\    // The lens: a defocus blur, and the sharpening the camera adds back,
    \\    // overshoot and all. Fed back, the overshoot grows into ripples.
    \\    vec2 o = uLoop.x / res;
    \\    float blur = (textureLod(uPrev, suv + vec2(o.x, 0.0), 0.0).r + textureLod(uPrev, suv - vec2(o.x, 0.0), 0.0).r +
    \\                  textureLod(uPrev, suv + vec2(0.0, o.y), 0.0).r + textureLod(uPrev, suv - vec2(0.0, o.y), 0.0).r) * 0.25;
    \\    float y = mix(blur, prev.r, 0.5) + uLoop.y * (prev.r - blur);
    \\
    \\    // Gain and an S-curve: mids get pushed to black or white, which is
    \\    // what turns a blurry echo into crisp feedback structure.
    \\    // Auto exposure: the camera's AGC reads the frame's mean (the top mip)
    \\    // and backs the gain off as it runs bright, so no flood can hold.
    \\    float mean = textureLod(uPrev, vec2(0.5), uMeanLod).r;
    \\    y *= uTone.x * clamp(0.28 / max(mean, 1e-3), 0.65, 1.15);
    \\    y = clamp((y - uTone.z) * uTone.y + 0.5, 0.0, 1.0);
    \\
    \\    // Shorted inverter: whole zones flip polarity for a tick.
    \\    if (hash12(floor(fc / 48.0) + floor(uTick) * 0.37) < uLoop.w) y = 1.0 - y;
    \\
    \\    // Shorted data lines: in bent zones the signal overflows and wraps
    \\    // (contour bands), or the low bits stick (posterised slabs).
    \\    vec2 zone = floor(fc / vec2(uShort.z * 5.0, uShort.z));
    \\    float zh = hash12(zone + uShort.y);
    \\    if (zh < uShort.x) y = fract(y * 1.9 + 0.07);
    \\    else if (zh < uShort.x * 1.7) y = floor(y * 3.0 + 0.5) / 3.0;
    \\
    \\    // Snow.
    \\    y += (hash12(fc + fract(uTick * 0.618) * 913.0) - 0.5) * uTone.w;
    \\
    \\    // Light: every window frame, a doubled frame round the focused one,
    \\    // and the cursor. The camera sees these and nothing else.
    \\    vec2 pb = fc * uDiv;
    \\    float lw = 1.2 * uDiv;
    \\    float lit = 0.0;
    \\    for (int i = 0; i < 32; i++) {
    \\        if (i >= iWindowCount) break;
    \\        vec4 r = iWindows[i];
    \\        if (r.z < 1.0) continue;
    \\        float d = boxSd(pb, r) - 2.0 * uDiv;
    \\        lit = max(lit, 1.0 - smoothstep(0.0, lw, abs(d)));
    \\    }
    \\    float hot = 0.0;
    \\    if (iWindow.z >= 1.0) {
    \\        float d = boxSd(pb, iWindow) - 6.0 * uDiv;
    \\        hot = 1.0 - smoothstep(0.0, lw, abs(d));
    \\    }
    \\    float cur = 1.0 - smoothstep(1.5 * uDiv, 3.0 * uDiv, length(pb - iMouse.xy));
    \\    hot = max(hot, cur);
    \\    y = max(y, max(lit * 0.8, hot));
    \\
    \\    // Accent rides the loop on its own channel and fades fast.
    \\    float a = prev.g * 0.955;
    \\    float hue = near.b;
    \\    float inj = hot * uAccent.x;
    \\    if (inj > a) { a = inj; hue = uAccent.y; }
    \\
    \\    fragColor = vec4(clamp(y, 0.0, 1.0), a, hue, 1.0);
    \\}
;

/// Sim lines tall at 1x: the loop runs at video resolution.
const default_lines: f32 = 720.0;
/// Most sim ticks one display frame may run (catch-up after a hitch).
const max_ticks_per_frame = 3;
/// Frames of history the display can skip back through.
const hist_slots = 16;

const State = struct {
    rng: std.Random.DefaultPrng,
    music: hg.audio.Analyzer = .{},

    width: f32,
    height: f32,
    /// Buffer pixels per sim pixel.
    div: f32,
    sim_w: i32,
    sim_h: i32,

    sim: ?hg_gl.Program = null,
    /// Ping-pong feedback: two RGBA8 targets, each with its own framebuffer.
    /// Mipmapped so the sim's AGC can read the frame mean from the top mip.
    targets: [2]hg_gl.Target = .{ .{}, .{} },
    /// Index of the texture holding the newest frame.
    current: u1 = 0,
    /// The last `hist_slots` frames, newest at layer `head`.
    hist_tex: gl.GLuint = 0,
    hist_fbo: gl.GLuint = 0,
    head: i32 = 0,
    gl_failed: bool = false,

    su: hg.Uniforms(.{
        .prev = "uPrev",
        .div = "uDiv",
        .center = "uCenter",
        .xform = "uXform",
        .tone = "uTone",
        .sync = "uSync",
        .bands = "uBands",
        .short = "uShort",
        .accent = "uAccent",
        .loop = "uLoop",
        .mean_lod = "uMeanLod",
        .tick = "uTick",
    }) = .{},
    /// The sim's desktop uniforms that `hg_gl.Program` does not carry.
    hu: hg.Uniforms(.{ .window = "iWindow", .mouse = "iMouse" }) = .{},
    mu: hg.Uniforms(.{
        .hist = "iGlitchHist",
        .head = "iGlitchHead",
        .slit = "iGlitchSlit",
        .sim = "iGlitchSim",
        .tear = "iGlitchTear",
        .chroma = "iGlitchChroma",
        .pix = "iGlitchPix",
        .dither = "iGlitchDither",
        .vsync = "iGlitchVsync",
    }) = .{},

    // Desktop snapshot for the sim pass (frame slices die with update).
    windows: [max_windows][4]f32 = undefined,
    window_count: usize = 0,
    focus: [4]f32 = .{ 0, 0, 0, 0 },
    cursor: [2]f32 = .{ 0, 0 },

    now: f64 = 0,
    tick: u32 = 0,
    tick_acc: f32 = 0,
    pending_ticks: u32 = 0,

    // The camera, sample-and-hold: it jumps between settings, never glides.
    zoom: f32 = 1.03,
    twist: f32 = 0.02,
    pan: [2]f32 = .{ 0, 0 },
    /// Camera aim offset from the focused window centre, buffer px.
    aim: [2]f32 = .{ 0, 0 },
    gain: f32 = 0.97,
    contrast: f32 = 1.15,
    /// S-curve pivot: above 0.5 the loop leans toward black.
    pivot: f32 = 0.55,
    /// Defocus radius (sim px) and how hard the camera sharpens it back.
    lens: f32 = 1.5,
    sharpen: f32 = 0.6,
    scene_left: f32 = 0,

    // Bends: each runs for its `_left` seconds once triggered.
    /// Camera frame rate while stuttering (ticks/s); 60 otherwise.
    stutter_rate: f32 = 60,
    stutter_left: f32 = 0,
    freeze_left: f32 = 0,
    band_prob: f32 = 0,
    band_h: f32 = 24,
    band_seed: f32 = 0,
    band_reseed: f32 = 0,
    band_left: f32 = 0,
    skew: f32 = 0.4,
    skew_phase: f32 = 0,
    skew_left: f32 = 0,
    shred: f32 = 0,
    roll: f32 = 0,
    roll_left: f32 = 0,
    short_amt: f32 = 0,
    short_seed: f32 = 0,
    short_zone: f32 = 12,
    short_left: f32 = 0,
    accent_hue: f32 = 0,
    accent_left: f32 = 0,
    tear: [3]f32 = .{ 0, 0, 0 },
    tear_left: f32 = 0,
    /// Display bends: mosaic, ordered dither, and lost vertical hold.
    pix: [3]f32 = .{ 0, 0, 0 },
    pix_left: f32 = 0,
    dither: [2]f32 = .{ 0, 0 },
    dither_left: f32 = 0,
    vroll_speed: f32 = 0,
    vroll: f32 = 0,
    vbar: f32 = 0,
    vbounce: f32 = 0,
    vsync_left: f32 = 0,
    mirror_left: f32 = 0,
    invert: f32 = 0,
    invert_left: f32 = 0,
    /// Skip: the display loops the last `skip_len` frames like a scratched
    /// disc, and history stops recording so the loop holds still.
    skip_len: i32 = 0,
    skip_step: i32 = 0,
    skip_hold: f32 = 0,
    skip_left: f32 = 0,
    /// Slit-scan: bands of rows show frames up to `slit_depth` old.
    slit_depth: f32 = 0,
    slit_band: f32 = 0.05,
    slit_seed: f32 = 0,
    slit_left: f32 = 0,
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    const hp = hg.Host{ .raw = @ptrCast(host) };
    const state = hg.allocator.create(State) catch return null;

    const lines = std.math.clamp(hp.getFloat("lines", default_lines), 120.0, 2160.0);
    const div = @max(1.0, height / lines);
    state.* = .{
        .rng = std.Random.DefaultPrng.init(nowNs()),
        .width = width,
        .height = height,
        .div = div,
        .sim_w = @intFromFloat(@ceil(width / div)),
        .sim_h = @intFromFloat(@ceil(height / div)),
    };
    return @ptrCast(state);
}

fn rand(s: *State) f32 {
    return s.rng.random().float(f32);
}

fn range(s: *State, lo: f32, hi: f32) f32 {
    return lo + (hi - lo) * rand(s);
}

/// Poisson trigger: fires on average `per_sec` times a second.
fn chance(s: *State, per_sec: f32, dt: f32) bool {
    return rand(s) < per_sec * dt;
}

/// New camera setting. Zoom above 1 pushes copies outward from the
/// aim point; twist curls them into a spiral, either way round.
fn jumpScene(s: *State) void {
    s.zoom = range(s, 1.008, 1.06);
    const sign: f32 = if (rand(s) < 0.5) -1.0 else 1.0;
    s.twist = sign * range(s, 0.0, 0.07) * range(s, 0.2, 1.0);
    s.pan = .{ range(s, -1.0, 1.0) * range(s, 0.0, 1.5), range(s, -1.0, 1.0) * range(s, 0.0, 1.5) };
    s.aim = .{ range(s, -0.25, 0.25) * s.width, range(s, -0.2, 0.2) * s.height };
    if (rand(s) < 0.4) s.aim = .{ 0, 0 };
    s.gain = range(s, 0.95, 1.03);
    s.contrast = range(s, 1.05, 1.45);
    s.pivot = range(s, 0.52, 0.6);
    s.lens = range(s, 0.8, 3.5);
    s.sharpen = range(s, 0.2, 1.4);
    s.scene_left = range(s, 2.0, 6.5);
}

fn stutter(s: *State) void {
    const rates = [_]f32{ 4, 6, 8, 12, 15, 20, 30 };
    s.stutter_rate = rates[s.rng.random().uintLessThan(usize, rates.len)];
    s.stutter_left = range(s, 0.3, 1.4);
}

fn freeze(s: *State, max: f32) void {
    s.freeze_left = range(s, 0.06, max);
}

fn stickBands(s: *State) void {
    s.band_prob = range(s, 0.15, 0.55);
    s.band_h = range(s, 4.0, 60.0);
    s.band_left = range(s, 0.4, 1.8);
}

fn slipSync(s: *State) void {
    s.skew = range(s, 1.5, 7.0);
    s.shred = if (rand(s) < 0.5) range(s, -4.0, 4.0) else 0;
    s.skew_left = range(s, 0.3, 1.8);
}

fn rollFrame(s: *State) void {
    const sign: f32 = if (rand(s) < 0.5) -1.0 else 1.0;
    s.roll = sign * range(s, 2.0, 22.0);
    s.roll_left = range(s, 0.4, 1.6);
}

fn shortLines(s: *State) void {
    s.short_amt = range(s, 0.06, 0.3);
    s.short_seed = range(s, 0.0, 500.0);
    s.short_zone = range(s, 4.0, 28.0);
    s.short_left = range(s, 0.25, 1.3);
}

fn burstAccent(s: *State) void {
    s.accent_hue = rand(s);
    s.accent_left = range(s, 0.3, 1.2);
}

fn mirror(s: *State) void {
    s.mirror_left = range(s, 0.5, 2.5);
}

fn shortInverter(s: *State) void {
    s.invert = range(s, 0.02, 0.15);
    s.invert_left = range(s, 0.1, 0.5);
}

fn skip(s: *State) void {
    const lens = [_]i32{ 2, 3, 4, 6, 8 };
    s.skip_len = lens[s.rng.random().uintLessThan(usize, lens.len)];
    s.skip_step = 0;
    s.skip_hold = 0;
    s.skip_left = range(s, 0.25, 1.2);
}

fn slitScan(s: *State) void {
    s.slit_depth = range(s, 4.0, @as(f32, hist_slots - 1));
    s.slit_band = range(s, 0.004, 0.08);
    s.slit_seed = range(s, 0.0, 100.0);
    s.slit_left = range(s, 0.5, 2.5);
}

fn pixelate(s: *State) void {
    const blocks = [_]f32{ 3, 4, 6, 8, 12, 16, 24 };
    const share: f32 = if (rand(s) < 0.3) 1.0 else range(s, 0.15, 0.6);
    s.pix = .{ blocks[s.rng.random().uintLessThan(usize, blocks.len)], share, range(s, 0.0, 100.0) };
    s.pix_left = range(s, 0.25, 2.0);
}

fn crushDither(s: *State) void {
    const cells = [_]f32{ 2, 3, 4, 6 };
    s.dither = .{
        @floatFromInt(1 + s.rng.random().uintLessThan(u8, 3)),
        cells[s.rng.random().uintLessThan(usize, cells.len)],
    };
    s.dither_left = range(s, 0.8, 4.0);
}

fn loseVsync(s: *State) void {
    const sign: f32 = if (rand(s) < 0.5) -1.0 else 1.0;
    // Sometimes a full roll, sometimes it only shudders in place.
    s.vroll_speed = if (rand(s) < 0.65) sign * range(s, 0.3, 3.0) else 0;
    s.vbar = range(s, 0.03, 0.09);
    s.vbounce = range(s, 2.0, 30.0);
    s.vsync_left = range(s, 0.4, 2.5);
}

fn tearFrame(s: *State) void {
    s.tear = .{ rand(s), range(s, -0.2, 0.2), range(s, 0.01, 0.12) };
    s.tear_left = range(s, 0.04, 0.25);
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);

    const dt = std.math.clamp(f.dt, 0.0, 0.05);
    s.now += dt;

    var wave: [256]f32 = [_]f32{0} ** 256;
    if (f.wave != null and f.wave_len >= wave.len) @memcpy(&wave, f.wave[0..wave.len]);
    const kick = s.music.update(&wave, dt);
    const energy = s.music.bands.energy_ema;

    // Snapshot the desktop for the sim pass.
    s.window_count = @min(f.windows_len, s.windows.len);
    var on_screen = false;
    for (0..s.window_count) |i| {
        const w = f.windows[i];
        s.windows[i] = .{ w.x, w.y, w.w, w.h };
        if (w.w >= 1.0 and w.x < s.width and w.x + w.w > 0 and w.y < s.height and w.y + w.h > 0) on_screen = true;
    }
    const fw = f.focused_win;
    s.focus = .{ fw.x, fw.y, fw.w, fw.h };
    s.cursor = .{ f.cursor[0], f.cursor[1] };
    // An empty screen gives the camera nothing to film, and the loop
    // starves to black. Stand a ghost frame in the middle instead.
    if (!on_screen) {
        const sz = s.height * 0.3;
        s.focus = .{ (s.width - sz) * 0.5, (s.height - sz) * 0.5, sz, sz };
    }

    // Bends fire at random; music raises every rate, and each kick
    // throws one more in.
    const heat = 1.0 + energy * 2.5;
    s.scene_left -= dt;
    if (s.scene_left <= 0) jumpScene(s);
    if (chance(s, 0.22 * heat, dt)) stutter(s);
    if (chance(s, 0.12 * heat, dt)) freeze(s, 0.45);
    if (chance(s, 0.2 * heat, dt)) stickBands(s);
    if (chance(s, 0.18 * heat, dt)) slipSync(s);
    if (chance(s, 0.07 * heat, dt)) rollFrame(s);
    if (chance(s, 0.14 * heat, dt)) shortLines(s);
    if (chance(s, 0.1 * heat, dt)) burstAccent(s);
    if (chance(s, 0.3 * heat, dt)) tearFrame(s);
    if (chance(s, 0.08 * heat, dt)) mirror(s);
    if (chance(s, 0.1 * heat, dt)) shortInverter(s);
    if (chance(s, 0.16 * heat, dt)) skip(s);
    if (chance(s, 0.12 * heat, dt)) slitScan(s);
    if (chance(s, 0.16 * heat, dt)) pixelate(s);
    if (chance(s, 0.1 * heat, dt)) crushDither(s);
    if (chance(s, 0.09 * heat, dt)) loseVsync(s);
    if (kick) switch (s.rng.random().uintLessThan(u8, 10)) {
        8 => pixelate(s),
        9 => loseVsync(s),
        0 => jumpScene(s),
        1 => skip(s),
        2 => tearFrame(s),
        3 => burstAccent(s),
        4 => stickBands(s),
        5 => shortInverter(s),
        6 => slitScan(s),
        else => shortLines(s),
    };

    s.stutter_left -= dt;
    s.freeze_left -= dt;
    s.band_left -= dt;
    s.skew_left -= dt;
    s.roll_left -= dt;
    s.short_left -= dt;
    s.accent_left -= dt;
    s.tear_left -= dt;
    s.mirror_left -= dt;
    s.invert_left -= dt;
    s.slit_left -= dt;
    s.skip_left -= dt;
    s.pix_left -= dt;
    s.dither_left -= dt;
    s.vsync_left -= dt;
    if (s.vsync_left > 0) {
        s.vroll = @mod(s.vroll + s.vroll_speed * dt, 1.0);
    } else {
        // The hold catches: the roll snaps back to frame.
        s.vroll = 0;
    }
    if (s.skip_left > 0) {
        // Each looped frame holds for one or two display frames.
        s.skip_hold -= dt;
        if (s.skip_hold <= 0) {
            s.skip_step = @mod(s.skip_step + 1, s.skip_len);
            s.skip_hold = 1.0 / 30.0;
        }
    }
    if (s.band_left > 0) {
        // Stuck bands flicker between rows rather than holding still.
        s.band_reseed -= dt;
        if (s.band_reseed <= 0) {
            s.band_seed = range(s, 0.0, 1000.0);
            s.band_reseed = range(s, 0.04, 0.25);
        }
    }
    s.skew_phase += dt * (if (s.skew_left > 0) @as(f32, 9.0) else 0.7);

    // Camera clock: 60 ticks/s, unless stuttering or frozen.
    if (s.freeze_left <= 0) {
        const rate: f32 = if (s.stutter_left > 0) s.stutter_rate else 60.0;
        s.tick_acc += dt * rate;
        const n: u32 = @intFromFloat(@floor(s.tick_acc));
        s.tick_acc -= @floatFromInt(n);
        s.pending_ticks = @min(s.pending_ticks + n, max_ticks_per_frame);
    }
}

fn ensureGl(s: *State) bool {
    if (s.sim != null) return true;
    if (s.gl_failed) return false;
    s.gl_failed = true;

    s.sim = hg_gl.Program.init(sim_frag) catch return false;

    for (&s.targets) |*t| {
        t.* = hg_gl.Target.init(s.sim_w, s.sim_h, .{
            .format = .rgba8,
            .filter = .linear,
            .wrap = .repeat,
            .mipmaps = true,
        }) catch return false;
        t.begin();
        gl.glClearColor(0, 0, 0, 1);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        t.generateMipmaps();
    }

    gl.glGenTextures(1, &s.hist_tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D_ARRAY, s.hist_tex);
    gl.glTexStorage3D(gl.GL_TEXTURE_2D_ARRAY, 1, gl.GL_RGBA8, s.sim_w, s.sim_h, hist_slots);
    gl.glTexParameteri(gl.GL_TEXTURE_2D_ARRAY, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D_ARRAY, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D_ARRAY, gl.GL_TEXTURE_WRAP_S, gl.GL_REPEAT);
    gl.glTexParameteri(gl.GL_TEXTURE_2D_ARRAY, gl.GL_TEXTURE_WRAP_T, gl.GL_REPEAT);
    gl.glGenFramebuffers(1, &s.hist_fbo);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, s.hist_fbo);
    for (0..hist_slots) |layer| {
        gl.glFramebufferTextureLayer(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, s.hist_tex, 0, @intCast(layer));
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    }
    const complete = gl.glCheckFramebufferStatus(gl.GL_FRAMEBUFFER) == gl.GL_FRAMEBUFFER_COMPLETE;
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    if (!complete) return false;

    s.gl_failed = false;
    return true;
}

/// One camera frame: film the current target into the other.
fn runTick(s: *State, sp: *const hg_gl.Program) void {
    const src = s.current;
    const dst = 1 - s.current;
    s.targets[dst].begin();
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, s.targets[src].tex);

    s.tick +%= 1;
    // Aim at the focused window (the whole screen when none), offset
    // by the scene's aim, in sim pixels.
    var cx = s.width * 0.5;
    var cy = s.height * 0.5;
    if (s.focus[2] >= 1.0) {
        cx = s.focus[0] + s.focus[2] * 0.5;
        cy = s.focus[1] + s.focus[3] * 0.5;
    }
    cx = (cx + s.aim[0]) / s.div;
    cy = (cy + s.aim[1]) / s.div;
    const bass = s.music.bass();
    const treble = s.music.treble();

    s.su.int(.prev, 0);
    s.su.f1(.div, s.div);
    s.su.f2(.center, cx, cy);
    s.su.f4(.xform, s.zoom + bass * 0.02, s.twist, s.pan[0], s.pan[1]);
    s.su.f4(.tone, s.gain, s.contrast, s.pivot, 0.05 + treble * 0.12);
    const skewing = s.skew_left > 0;
    s.su.f4(
        .sync,
        if (skewing) s.skew else 0.35,
        s.skew_phase,
        if (s.roll_left > 0) s.roll else 0,
        if (skewing) s.shred else 0,
    );
    s.su.f4(.bands, if (s.band_left > 0) s.band_prob else 0, s.band_seed, s.band_h, 0);
    s.su.f4(.short, if (s.short_left > 0) s.short_amt else 0, s.short_seed, s.short_zone, 0);
    s.su.f2(.accent, if (s.accent_left > 0) 1.0 else 0.0, s.accent_hue);
    s.su.f4(
        .loop,
        s.lens,
        s.sharpen,
        if (s.mirror_left > 0) 1.0 else 0.0,
        if (s.invert_left > 0) s.invert else 0.0,
    );
    s.su.f1(.tick, @floatFromInt(s.tick % 100000));
    s.su.f1(.mean_lod, @floor(std.math.log2(@as(f32, @floatFromInt(@max(s.sim_w, s.sim_h))))));

    gl.glBindVertexArray(sp.vao);
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 3);
    s.targets[dst].generateMipmaps();
    s.current = dst;

    // Record it, unless a skip is holding history still.
    if (s.skip_left > 0) return;
    s.head = @mod(s.head + 1, hist_slots);
    gl.glBindFramebuffer(gl.GL_DRAW_FRAMEBUFFER, s.hist_fbo);
    gl.glFramebufferTextureLayer(gl.GL_DRAW_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, s.hist_tex, 0, s.head);
    gl.glBlitFramebuffer(0, 0, s.sim_w, s.sim_h, 0, 0, s.sim_w, s.sim_h, gl.GL_COLOR_BUFFER_BIT, gl.GL_NEAREST);
    gl.glBindFramebuffer(gl.GL_DRAW_FRAMEBUFFER, 0);
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));

    if (ensureGl(s)) {
        const sp = &s.sim.?;
        sp.use();
        s.su.use(sp.program);
        s.hu.use(sp.program);
        if (sp.i_resolution >= 0)
            gl.glUniform3f(sp.i_resolution, @floatFromInt(s.sim_w), @floatFromInt(s.sim_h), 1.0);
        for (s.windows[0..s.window_count], 0..) |w, i| {
            if (sp.i_windows[i] >= 0) gl.glUniform4f(sp.i_windows[i], w[0], w[1], w[2], w[3]);
        }
        if (sp.i_window_count >= 0) gl.glUniform1i(sp.i_window_count, @intCast(s.window_count));
        s.hu.f4(.window, s.focus[0], s.focus[1], s.focus[2], s.focus[3]);
        s.hu.f4(.mouse, s.cursor[0], s.cursor[1], 0, 0);

        while (s.pending_ticks > 0) : (s.pending_ticks -= 1) runTick(s, sp);
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    }

    s.mu.use(program);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D_ARRAY, s.hist_tex);
    s.mu.int(.hist, 0);
    const shown = if (s.skip_left > 0) s.head - (s.skip_len - 1) + s.skip_step else s.head;
    s.mu.int(.head, @mod(shown, hist_slots));
    if (s.slit_left > 0)
        s.mu.f4(.slit, s.slit_depth, s.slit_band, s.slit_seed, 0)
    else
        s.mu.f4(.slit, 0, 1, 0, 0);
    s.mu.f2(.sim, @floatFromInt(s.sim_w), @floatFromInt(s.sim_h));
    if (s.tear_left > 0)
        s.mu.f4(.tear, s.tear[0], s.tear[1], s.tear[2], 0)
    else
        s.mu.f4(.tear, 0, 0, 0, 0);
    s.mu.f1(.chroma, 2.0 + s.music.beat() * 6.0);
    s.mu.f4(.pix, if (s.pix_left > 0) s.pix[0] else 0, s.pix[1], s.pix[2], 0);
    s.mu.f4(.dither, if (s.dither_left > 0) s.dither[0] else 0, s.dither[1], 0, 0);
    if (s.vsync_left > 0) {
        const bounce = (rand(s) - 0.5) * 2.0 * s.vbounce;
        s.mu.f4(.vsync, s.vroll, if (s.vroll_speed != 0) s.vbar else 0, bounce, 0);
    } else s.mu.f4(.vsync, 0, 0, 0, 0);
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    for (&s.targets) |*t| t.deinit();
    if (s.hist_fbo != 0) gl.glDeleteFramebuffers(1, &s.hist_fbo);
    if (s.hist_tex != 0) gl.glDeleteTextures(1, &s.hist_tex);
    if (s.sim) |*sp| sp.deinit();
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "glitch",
    .shader = "glitch.frag",
    .config_section = null,
    .wants_audio = 1,
    .create = create,
    .update = update,
    .upload = upload,
    .destroy = destroy,
};

export fn hg_module_entry() callconv(.c) *const c.hg_module {
    return &module;
}
