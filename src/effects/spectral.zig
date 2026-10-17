//! Host-side spectral front-end for the built-in audio effects.
//!
//! The math now lives in the SDK (`sdk/hg_audio.zig`) so component effects
//! share the exact same numbers. This module re-exports that math verbatim and
//! adds the capture-owning `Analyzer` the built-ins use: it spawns the effect's
//! PulseAudio capture (honouring `music`/`sink`) and feeds each frame's
//! waveform through the SDK analyzer. Keep `Analyzer`'s public members
//! (`bands`, `onset`) named as the SDK's, since effects read them directly.

const std = @import("std");
const hg_audio = @import("hg_audio");
const audio_mod = @import("audio.zig");
const config_mod = @import("../core/config.zig");

pub const fft_n = hg_audio.fft_n;
pub const n_bins = hg_audio.n_bins;
pub const hann = hg_audio.hann;
pub const band_edges = hg_audio.band_edges;
pub const fftInPlace = hg_audio.fftInPlace;
pub const magnitudes = hg_audio.magnitudes;
pub const Bands = hg_audio.Bands;
pub const Onset = hg_audio.Onset;

/// The front-end most audio effects share: optional capture (the effect's
/// `music` setting, default on), the six bands and the kick detector.
/// Without capture nothing updates and every value stays zero, which each
/// effect treats as its no-music look.
pub const Analyzer = struct {
    audio: ?*audio_mod.AudioCapture = null,
    bands: Bands = .{},
    onset: Onset = .{},

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Analyzer {
        return .{ .audio = try audio_mod.spawnIfMusic(allocator, params) };
    }

    /// Analyse this frame's capture. Returns true on the frame a kick fires.
    pub fn update(self: *Analyzer, dt: f32) bool {
        const audio = self.audio orelse return false;
        const wave = audio.getWaveform();
        const mags = magnitudes(&wave);
        self.bands.update(&mags, dt);
        return self.onset.update(&mags, dt, self.bands.bands[0]);
    }

    pub fn deinit(self: *Analyzer, allocator: std.mem.Allocator) void {
        if (self.audio) |audio| audio_mod.shutdown(audio, allocator);
        self.audio = null;
    }

    /// Smoothed low end (sub + bass bands).
    pub fn bass(self: *const Analyzer) f32 {
        return (self.bands.smooth[0] + self.bands.smooth[1]) * 0.5;
    }

    /// Smoothed top end (high-mid + treble bands).
    pub fn treble(self: *const Analyzer) f32 {
        return (self.bands.smooth[4] + self.bands.smooth[5]) * 0.5;
    }

    pub fn beat(self: *const Analyzer) f32 {
        return self.onset.beat;
    }
};
