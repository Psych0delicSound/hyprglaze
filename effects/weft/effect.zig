//! effects/weft — windows shining through a diffraction weave.
//!
//! This is the Phase-0 reference component: a Zig effect compiled to a shared
//! object by the host's compile-on-load path and driven through the C ABI in
//! `sdk/include/hg_plugin.h`. The fragment shader lives next to it.

const hg = @import("hg.zig");

const c = hg.c;
const gl = hg.gl;

// The music IS woven into the interference: the audio waveform itself —
// smoothed ~50ms so it keeps its shape without frame jitter, peak-normalized
// so volume doesn't change depth — threads through the fringes as a phase
// displacement sampled along each thread's length. Silence is clean, still
// threads. Halo reach, drift, grain cadence, and detune are constants.
const State = struct {
    /// Lattice phase drift (slow, constant).
    drift: f64 = 0,
    /// Grain reseed clock (fixed film cadence).
    grain_clock: f64 = 0,
    /// Mono waveform, EMA-smoothed per sample (~50ms memory).
    wave_s: [128]f32 = [_]f32{0} ** 128,
    /// Peak-normalized copy shipped to the shader.
    wave_n: [128]f32 = [_]f32{0} ** 128,
    /// Slow AGC peak (~3s decay).
    wave_peak: f32 = 0,

    scale: f32,
    reach: f32,
    grain: f32,

    u: hg.Uniforms(.{
        .drift = "iWeftDrift",
        .grain_t = "iWeftGrainT",
        .wave = "iWeftWave[0]",
        .scale = "iWeftScale",
        .reach = "iWeftReach",
        .grain = "iWeftGrain",
    }) = .{},
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    _ = width;
    _ = height;
    const h = hg.Host{ .raw = @ptrCast(host) };
    const state = hg.allocator.create(State) catch return null;
    state.* = .{
        .scale = std_clamp(h.getFloat("scale", 26.0), 8.0, 120.0),
        .reach = std_clamp(h.getFloat("reach", 1.0), 0.3, 3.0),
        .grain = std_clamp(h.getFloat("grain", 1.0), 0.0, 2.0),
    };
    return @ptrCast(state);
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);
    const frame_dt = f.dt;
    if (f.wave != null and f.wave_len >= 256) {
        var peak_new: f32 = 0;
        const a = @min(@as(f32, 1.0), 18.0 * frame_dt); // ~55ms shape memory
        for (0..128) |i| {
            const smp = (f.wave[i] + f.wave[128 + i]) * 0.5;
            s.wave_s[i] += (smp - s.wave_s[i]) * a;
            peak_new = @max(peak_new, @abs(s.wave_s[i]));
        }
        s.wave_peak = @max(s.wave_peak * @exp(-frame_dt / 3.0), peak_new);
        const inv: f32 = if (s.wave_peak > 0.01) 1.0 / s.wave_peak else 0.0;
        for (0..128) |i| {
            s.wave_n[i] = std_clamp(s.wave_s[i] * inv, -1.0, 1.0);
        }
    }
    s.grain_clock += frame_dt * 10.0;
    s.drift += frame_dt * 0.06;
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    s.u.use(program);
    s.u.f1(.drift, @floatCast(s.drift));
    s.u.f1(.grain_t, @floatCast(s.grain_clock));
    s.u.f1v(.wave, 128, &s.wave_n[0]);
    s.u.f1(.scale, s.scale);
    s.u.f1(.reach, s.reach);
    s.u.f1(.grain, s.grain);
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    hg.allocator.destroy(s);
}

fn std_clamp(x: f32, lo: f32, hi: f32) f32 {
    return @min(@max(x, lo), hi);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "weft",
    .shader = "weft.frag",
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
