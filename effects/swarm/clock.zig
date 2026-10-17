//! Effect clocks accumulate seconds in f64. An f32 counter stops resolving
//! a 120 Hz frame step after about 18 hours of uptime and stalls outright
//! after a few days, which a wallpaper that runs for a whole session
//! reaches. These turn a long clock into small, exact f32 arguments for
//! CPU-side oscillators.

const std = @import("std");

/// Angle in radians (0..tau) of an oscillator turning at `rate` rad/s.
pub fn phase(t: f64, rate: f64) f32 {
    return @floatCast(@mod(t * rate, std.math.tau));
}

/// Position (0..1) through a cycle repeating `rate` times per second.
pub fn cycles(t: f64, rate: f64) f32 {
    return @floatCast(@mod(t * rate, 1.0));
}

test "phase and cycles stay exact on a long clock" {
    const week: f64 = 7 * 24 * 3600 + 0.25;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), cycles(week, 1.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), phase(week, std.math.tau), 1e-5);
}
