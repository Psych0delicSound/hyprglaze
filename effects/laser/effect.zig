//! effects/laser — lasers fired from screen corners toward the cursor.
//!
//! Ported from the built-in `src/effects/laser/context.zig` to the component
//! ABI. Each frame the beams are retraced from the live window rects: a ray is
//! fired at the cursor, reflects specularly off window faces and the screen's
//! edges (a mirrored box) and dims by `falloff` at each bounce; the legs are
//! handed to `laser.frag`, which draws them as glowing lines through smoke.
//! The second beam fires from the opposite corner in another theme colour. With
//! music, the first (low) beam swells with the bass and the second (high) with
//! the treble, a travelling wave rides down each, and bass kicks fire pulses
//! along the low beam.
//!
//! Structural changes from the built-in, beyond the ABI:
//!   * audio is host-captured — `hg.audio.Analyzer` runs on `hg_frame.wave`
//!     instead of owning a capture thread;
//!   * window rects are read straight off the frame (frame pointers die at
//!     `update`'s return; nothing is kept);
//!   * the ray solver (`trace.zig`) is copied locally (the compiler stages
//!     every `.zig` in the directory); the f64 clock is the shared
//!     `hg_clock.zig` staged by the loader.
//!
//! The palette colours (`iPalette`/`iPaletteBg`) are the host's standard
//! uniforms; this module only pushes its own.

const std = @import("std");

const hg = @import("hg.zig");

const c = hg.c;

const clock = @import("hg_clock.zig");
const trace = @import("trace.zig");

pub const max_beams = 2;
/// Legs per beam. At the default falloff a beam fades out in ~18.
pub const max_legs = 32;
/// Must match the array sizes in effects/laser/laser.frag.
pub const max_segments = max_beams * max_legs;
/// Kick pulses in flight down the low beam at once.
pub const max_pulses = 4;
/// How long a kick pulse travels before it has faded out, seconds.
const pulse_life: f32 = 1.6;

const Beam = struct {
    origin: [2]f32,
    /// Theme palette index (0-based).
    color: i32,
    /// Last usable aim, kept while the cursor sits on the emitter.
    dir: [2]f32,
    segs: [max_legs]trace.Segment = undefined,
    count: usize = 0,
};

const State = struct {
    music: hg.audio.Analyzer = .{},
    /// Strength of the music response; 0 = none.
    react: f32,
    /// Travelling-wave phase per beam, accumulated so a change in energy
    /// changes the wave's speed rather than jumping its position.
    phase: [max_beams]f32 = .{ 0, 0 },
    /// Kick pulse ages in seconds; >= pulse_life is idle.
    pulses: [max_pulses]f32 = [_]f32{pulse_life} ** max_pulses,
    next_pulse: usize = 0,

    width: f32,
    height: f32,
    falloff: f32,
    min_intensity: f32,
    beam_width: f32,
    smoke: f32,
    speckle: f32,
    /// Speckle pattern seed, re-rolled only when a beam's aim moves.
    seed: f32 = 0,
    beams: [max_beams]Beam,
    beam_count: usize,
    now: f64 = 0,

    u: hg.Uniforms(.{
        .seg = "iLaserSeg[0]",
        .int = "iLaserLeg[0]",
        .count = "iLaserCount",
        .split = "iLaserSplit",
        .width = "iLaserWidth",
        .color = "iLaserColor",
        .color2 = "iLaserColor2",
        .time = "iLaserTime",
        .smoke = "iLaserSmoke",
        .speckle = "iLaserSpeckle",
        .seed = "iLaserSeed",
        .band = "iLaserBand",
        .phase = "iLaserPhase",
        .pulse = "iLaserPulse",
        .react = "iLaserReact",
    }) = .{},
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    const hp = hg.Host{ .raw = @ptrCast(host) };

    // GL space is y-up: "bottom" is y = 0.
    const corner = hp.getString("corner") orelse "bottom-left";
    const inset: f32 = 2.0;
    const left = !std.mem.endsWith(u8, corner, "right");
    const bottom = !std.mem.startsWith(u8, corner, "top");
    const first: [2]f32 = .{ if (left) inset else width - inset, if (bottom) inset else height - inset };
    // The opposite corner: mirror both axes.
    const second: [2]f32 = .{ width - first[0], height - first[1] };
    const centre: [2]f32 = .{ width * 0.5, height * 0.5 };

    const state = hg.allocator.create(State) catch return null;
    state.* = .{
        .react = std.math.clamp(hp.getFloat("react", 1.0), 0.0, 3.0),
        .width = width,
        .height = height,
        .falloff = std.math.clamp(hp.getFloat("falloff", 0.82), 0.05, 0.99),
        .min_intensity = 0.03,
        .beam_width = @max(hp.getFloat("width", 1.6), 0.3),
        .smoke = std.math.clamp(hp.getFloat("smoke", 0.6), 0.0, 2.0),
        .speckle = std.math.clamp(hp.getFloat("speckle", 0.6), 0.0, 1.0),
        .beam_count = @intCast(std.math.clamp(hp.getInt("beams", 2), 1, max_beams)),
        .beams = .{
            // Theme slots, 1-16 (the color_NN numbers): 2 is the red,
            // 5 the blue.
            .{ .origin = first, .color = themeSlot(hp.getInt("color", 2)), .dir = .{ centre[0] - first[0], centre[1] - first[1] } },
            .{ .origin = second, .color = themeSlot(hp.getInt("color2", 5)), .dir = .{ centre[0] - second[0], centre[1] - second[1] } },
        },
    };
    return @ptrCast(state);
}

/// Smoothed energy in each beam's band, scaled by `react`: the lows
/// (bands 0-1) for the first beam, the highs (4-5) for the second.
fn bandEnergy(self: *const State) [2]f32 {
    return .{
        self.music.bass() * self.react,
        self.music.treble() * self.react,
    };
}

fn themeSlot(slot: i64) i32 {
    return @intCast(std.math.clamp(slot, 1, 16) - 1);
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);

    const dt = std.math.clamp(f.dt, 0.0, 0.1);
    s.now += dt;

    var wave: [256]f32 = [_]f32{0} ** 256;
    if (f.wave != null and f.wave_len >= wave.len) @memcpy(&wave, f.wave[0..wave.len]);

    // A kick launches a pulse from the low beam's emitter.
    if (s.music.update(&wave, @min(dt, 0.05))) {
        s.pulses[s.next_pulse] = 0;
        s.next_pulse = (s.next_pulse + 1) % max_pulses;
    }
    for (&s.pulses) |*age| age.* = @min(age.* + dt, pulse_life);
    // The waves run faster as their band gets louder: slow undulation
    // on the lows, quick ripple on the highs.
    const e = bandEnergy(s);
    s.phase[0] = @mod(s.phase[0] + dt * std.math.tau * (0.35 + 0.9 * e[0]), std.math.tau);
    s.phase[1] = @mod(s.phase[1] + dt * std.math.tau * (1.6 + 3.0 * e[1]), std.math.tau);

    var rects: [32]trace.Rect = undefined;
    const n = @min(@as(usize, @intCast(f.windows_len)), rects.len);
    for (0..n) |i| {
        const w = f.windows[i];
        rects[i] = .{ .x = w.x, .y = w.y, .w = w.w, .h = w.h };
    }

    var seed: f32 = 0;
    for (s.beams[0..s.beam_count], 0..) |*b, bi| {
        const aim: [2]f32 = .{ f.cursor[0] - b.origin[0], f.cursor[1] - b.origin[1] };
        if (aim[0] * aim[0] + aim[1] * aim[1] > 16.0) b.dir = aim;
        b.count = trace.trace(b.origin, b.dir, s.width, s.height, rects[0..n], s.falloff, s.min_intensity, &b.segs);
        // Speckle decorrelates when the geometry changes: key the
        // pattern to each beam's aim, quantized to ~a grain at range.
        const q = @round(std.math.atan2(b.dir[1], b.dir[0]) / 0.0015);
        seed += q * (if (bi == 0) @as(f32, 0.6180339) else 0.7548776);
    }
    s.seed = @mod(seed, 97.0);
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));

    s.u.use(program);
    // Beams back to back; legs from iLaserSplit on belong to beam 2.
    var seg: [max_segments][4]f32 = undefined;
    // (intensity, light arriving at the leg's start, flare twinkle,
    //  distance along the beam to the leg's start)
    var legs: [max_segments][4]f32 = undefined;
    var total: usize = 0;
    var split: usize = 0;
    for (s.beams[0..s.beam_count], 0..) |b, bi| {
        if (bi == 1) split = total;
        var along: f32 = 0;
        for (b.segs[0..b.count], 0..) |seg_i, j| {
            seg[total] = .{ seg_i.a[0], seg_i.a[1], seg_i.b[0], seg_i.b[1] };
            const arrived = if (j == 0) 1.0 else b.segs[j - 1].intensity;
            const twinkle = 0.85 + 0.15 * @sin(clock.phase(s.now, 9.0) + @as(f32, @floatFromInt(total)) * 2.3);
            legs[total] = .{ seg_i.intensity, arrived, twinkle, along };
            along += @sqrt((seg_i.b[0] - seg_i.a[0]) * (seg_i.b[0] - seg_i.a[0]) + (seg_i.b[1] - seg_i.a[1]) * (seg_i.b[1] - seg_i.a[1]));
            total += 1;
        }
    }
    if (s.beam_count == 1) split = total;
    const n: i32 = @intCast(total);
    s.u.f4v(.seg, n, &seg[0]);
    s.u.f4v(.int, n, &legs[0]);
    s.u.int(.count, n);
    s.u.int(.split, @intCast(split));
    s.u.f1(.width, s.beam_width);
    s.u.int(.color, s.beams[0].color);
    s.u.int(.color2, s.beams[1].color);
    // Effect-local clock keeps shader time small (fire.zig pattern).
    s.u.f1(.time, @floatCast(@mod(s.now, 1000.0)));
    s.u.f1(.smoke, s.smoke);
    s.u.f1(.speckle, s.speckle);
    s.u.f1(.seed, s.seed);
    const e = bandEnergy(s);
    s.u.f2(.band, e[0], e[1]);
    s.u.f2(.phase, s.phase[0], s.phase[1]);
    // With no audio the bands are zero, so the response is invisible
    // either way; the kicks that would use `react` never fire.
    s.u.f1(.react, s.react);
    if (s.u.loc(.pulse) >= 0) {
        // Pulse age as a fraction of its life; 1 = idle.
        var ages: [max_pulses]f32 = undefined;
        for (s.pulses, 0..) |age, i| ages[i] = age / pulse_life;
        s.u.f4(.pulse, ages[0], ages[1], ages[2], ages[3]);
    }
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "laser",
    .shader = "laser.frag",
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
