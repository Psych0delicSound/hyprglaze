//! effects/visualizer — audio waveform drawn by a particle shader.
//!
//! Ported from the built-in `src/effects/visualizer/context.zig` to the
//! component ABI. The effect has no state of its own beyond the frame's
//! waveform: the host captures the monitor mix and hands it in as
//! `hg_frame.wave` (256 samples: 128 left, then 128 right), which this module
//! packs four-per-vec4 into the shader's `iParticles` array. Audio is host-side
//! (`wants_audio`), so there is no capture thread here.

const hg = @import("hg.zig");

const c = hg.c;

const State = struct {
    /// This frame's waveform, copied out of `hg_frame` (its slices are only
    /// valid during `update`, and `upload` runs later).
    wave: [256]f32 = [_]f32{0} ** 256,

    u: hg.Uniforms(.{
        .particles = "iParticles[0]",
        .count = "iParticleCount",
    }) = .{},
};

fn create(host: [*c]const c.hg_host, width: f32, height: f32) callconv(.c) ?*anyopaque {
    _ = host;
    _ = width;
    _ = height;
    const state = hg.allocator.create(State) catch return null;
    state.* = .{};
    return @ptrCast(state);
}

fn update(handle: ?*anyopaque, frame: [*c]const c.hg_frame) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    const f: *const c.hg_frame = @ptrCast(frame);

    if (f.wave != null and f.wave_len >= s.wave.len) {
        @memcpy(&s.wave, f.wave[0..s.wave.len]);
    } else {
        @memset(&s.wave, 0.0);
    }
}

fn upload(handle: ?*anyopaque, program: u32) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    s.u.use(program);
    // 256 floats = 64 vec4 slots, matching the shader's iParticles packing.
    s.u.f4v(.particles, 64, &s.wave);
    s.u.int(.count, 64);
}

fn destroy(handle: ?*anyopaque) callconv(.c) void {
    const self = handle orelse return;
    const s: *State = @ptrCast(@alignCast(self));
    hg.allocator.destroy(s);
}

const module = c.hg_module{
    .abi_version = hg.abi_version,
    .id = "visualizer",
    .shader = "visualizer.frag",
    .wants_audio = 1,
    .create = create,
    .update = update,
    .upload = upload,
    .destroy = destroy,
};

export fn hg_module_entry() callconv(.c) *const c.hg_module {
    return &module;
}
