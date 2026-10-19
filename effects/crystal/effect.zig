//! effects/crystal — a cleaved gem the desktop lives inside.
//!
//! Ported from the built-in `src/effects/crystal.zig` to the component ABI.
//! The only structural change is audio: instead of owning a capture thread, it
//! reads the host-provided waveform (`hg_frame.wave`) through the SDK analyzer
//! (`hg.audio.Analyzer`), which computes the same FFT bands and kick envelope.
//!
//! A cleaved gem the desktop lives inside. The facets are shader-side —
//! drifting fracture planes, so faces are irregular convex polygons with
//! straight cleavage edges — and each face holds one constant normal, so a
//! sweeping light flashes whole faces at once the way a real cut stone
//! sparkles when you turn it. Windows are light sources buried in the stone.
//!
//! This component owns the one thing the shader can't keep: the turn clock.
//! It creeps on its own, quickens with energy, and lurches on kicks — so a
//! beat sends a wave of faces catching the light in sequence. Accumulated
//! here rather than derived from iTime so a tempo change never snaps the
//! stone's angle.

const hg = @import("hg.zig");

const c = hg.c;

fn clamp(x: f32, lo: f32, hi: f32) f32 {
    return @min(@max(x, lo), hi);
}

const State = struct {
    music: hg.audio.Analyzer = .{},

    /// Light-sweep angle, and the decaying angular kick a beat adds to it.
    turn: f64 = 0,
    turn_vel: f32 = 0,

    dispersion: f32,
    brightness: f32,

    u: hg.Uniforms(.{
        .turn = "iCrysTurn",
        .bands = "iCrysBands[0]",
        .bass = "iCrysBass",
        .beat = "iCrysBeat",
        .disp = "iCrysDisp",
        .bright = "iCrysBright",
    }) = .{},
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    _ = width;
    _ = height;
    const hp = hg.Host{ .raw = @ptrCast(host) };
    const state = hg.allocator.create(State) catch return null;
    state.* = .{
        .dispersion = clamp(hp.getFloat("dispersion", 1.0), 0.0, 4.0),
        .brightness = clamp(hp.getFloat("brightness", 1.0), 0.0, 3.0),
    };
    return @ptrCast(state);
}

/// A shared zero block, used when audio is off so analysis silently decays to
/// the no-music look.
const silence: [256]f32 = [_]f32{0} ** 256;

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);

    const dt = clamp(f.dt, 0.0, 0.05);
    const wave: *const [256]f32 = if (f.wave != null and f.wave_len >= 256) @ptrCast(f.wave) else &silence;

    const beat_hit = s.music.update(wave, dt);
    if (beat_hit) s.turn_vel += 2.4 * clamp(s.music.onset.beat, 0.0, 1.5);
    s.turn_vel *= @exp(-3.0 * dt);
    s.turn += dt * (0.20 + s.music.bands.energy_ema * 0.75 + s.turn_vel);
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    s.u.use(program);
    s.u.f1(.turn, @floatCast(s.turn));
    s.u.f1v(.bands, 6, &s.music.bands.smooth[0]);
    s.u.f1(.bass, s.music.bass());
    s.u.f1(.beat, s.music.onset.beat);
    s.u.f1(.disp, s.dispersion);
    s.u.f1(.bright, s.brightness);
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "crystal",
    .shader = "crystal.frag",
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
