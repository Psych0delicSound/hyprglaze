#version 300 es
precision highp float;

uniform vec3 iResolution;

// Balls from effects/particles/effect.zig, two vec4 each:
//   (x, y, radius, colour seed), (streak tail x, y, 0, 0)
uniform vec4 iBalls[300];
uniform int iBallCount;
// Bursts: (x, y, radius, palette slot + age in [0,1)); radius 0 = idle.
uniform vec4 iPops[8];

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;

out vec4 fragColor;

vec3 ballColor(float seed) {
    int ci = 1 + int(mod(seed * 5.99, 6.0));
    return (iPaletteSize > ci) ? iPalette[ci] : vec3(0.6);
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec3 col = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02);

    for (int i = 0; i < iBallCount && i < 150; i++) {
        vec4 A = iBalls[i * 2];
        vec2 tail = iBalls[i * 2 + 1].xy;
        float r = A.z;

        // Reject against the box spanning head and tail.
        vec2 lo = min(A.xy, tail) - r - 2.0;
        vec2 hi = max(A.xy, tail) + r + 2.0;
        if (fc.x < lo.x || fc.y < lo.y || fc.x > hi.x || fc.y > hi.y) continue;

        // The ball itself: always the full disc.
        float disc = 1.0 - smoothstep(-0.75, 0.75, length(fc - A.xy) - r);
        // Motion streak behind it: a capsule back along the velocity,
        // tapering and fading toward the tail. At rest it vanishes into
        // the disc.
        vec2 ba = tail - A.xy;
        float h = clamp(dot(fc - A.xy, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
        float d = length(fc - A.xy - ba * h) - mix(r, r * 0.3, h);
        float streak = (1.0 - smoothstep(-0.75, 0.75, d)) * mix(1.0, 0.12, h);
        col = mix(col, ballColor(A.w), max(disc, streak) * 0.85);
    }

    // Bursts: a thin ring expanding from the popped ball and fading out.
    for (int i = 0; i < 8; i++) {
        vec4 P = iPops[i];
        if (P.z <= 0.0) continue;
        float age = fract(P.w);
        float slot = floor(P.w);
        float ring_r = P.z * (1.0 + age * 3.0);
        float d = abs(length(fc - P.xy) - ring_r);
        if (d > 3.0) continue;
        int ci = 1 + int(slot);
        vec3 pc = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.8);
        float ring = 1.0 - smoothstep(0.5, 1.8, d);
        col = mix(col, pc, ring * (1.0 - age) * 0.8);
    }

    fragColor = vec4(col, 1.0);
}
