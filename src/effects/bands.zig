//! Host-side re-export of the SDK's time-domain band splitter.
//!
//! The numbers are tuned art and live verbatim in `sdk/hg_audio.zig`; this
//! module keeps the historical import path (`bands.zig`) working for the
//! effects that grew up on the slice-by-time splitter.

const hg_audio = @import("hg_audio");

pub const ranges = hg_audio.ranges;
pub const splitBands = hg_audio.splitBands;
pub const smoothstep = hg_audio.smoothstep;
pub const Splitter = hg_audio.Splitter;
