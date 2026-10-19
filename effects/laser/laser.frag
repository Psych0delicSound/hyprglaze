#version 300 es
precision highp float;

uniform vec3 iResolution;

// Beam legs from laser/context.zig: (x1, y1, x2, y2) and intensity, two
// beams back to back. Legs from iLaserSplit on are the second beam. A
// beam's first leg starts at its emitter; every later leg at a bounce.
uniform vec4 iLaserSeg[64];
// Per leg: (intensity, light that arrived at its start, flare twinkle,
// distance along its beam to the leg's start).
uniform vec4 iLaserLeg[64];
uniform int iLaserCount;
uniform int iLaserSplit;
uniform float iLaserWidth;
uniform int iLaserColor;
uniform int iLaserColor2;
uniform float iLaserTime;
// Smoke the beams light up (in-scattering); 0 = none.
uniform float iLaserSmoke;
// Laser speckle on scattered light (0 = none), and the pattern's seed: it
// changes only when the beams move, as real speckle decorrelates.
uniform float iLaserSpeckle;
uniform float iLaserSeed;
// Music: each beam's band energy (x = the first beam's lows, y = the
// second's highs), the phase of the wave travelling along each, kick pulse
// ages as a fraction of their life (1 = idle), and the response strength.
uniform vec2 iLaserBand;
uniform vec2 iLaserPhase;
uniform vec4 iLaserPulse;
uniform float iLaserReact;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;

out vec4 fragColor;

// ---- smoke: domain-warped fbm, drifting and slowly evolving ----

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    mat2 rot = mat2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = rot * p * 2.03;
        a *= 0.5;
    }
    return v;
}

// Wispy density in [0, 1]. Coordinates are in screen heights, so the
// smoke has the same scale at any resolution.
float smokeDensity(vec2 fc) {
    vec2 p = fc / iResolution.y * 2.6;
    float t = iLaserTime * 0.05;
    // Warp by a second, slower field so the wisps curl instead of just
    // scrolling; the whole mass drifts gently up and to the side.
    vec2 q = vec2(fbm(p + vec2(0.0, t)), fbm(p + vec2(5.2, 1.3) - t * 0.7));
    float n = fbm(p + 2.2 * q + vec2(t * 0.6, -t * 0.9));
    return smoothstep(0.35, 0.8, n);
}

// ---- speckle: coherent light scattered off a rough medium interferes into
// grains whose brightness is exponentially distributed (mean 1): mostly dim,
// a few sparkling. Grain ~1.6px, smoothly interpolated.

// Integer lattice hash (PCG-style multiply-xorshift): uncorrelated
// between neighbouring cells, which grain needs and the float hash above
// (fine for smooth noise) does not give.
float ihash(ivec2 c, uint seed) {
    uvec2 q = uvec2(c) * uvec2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y ^ seed) * 1597334673u;
    n ^= n >> 16;
    n *= 2246822519u;
    n ^= n >> 13;
    return float(n) * (1.0 / 4294967295.0);
}

float expSample(vec2 cell) {
    uint seed = uint(iLaserSeed * 44497.0);
    return -log(max(1.0 - ihash(ivec2(cell), seed), 1e-3));
}

float speckle(vec2 fc) {
    vec2 p = fc / 1.6;
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(expSample(i), expSample(i + vec2(1, 0)), u.x),
               mix(expSample(i + vec2(0, 1)), expSample(i + vec2(1, 1)), u.x), u.y);
}

// Distance to the segment, and how far along it (0-1) the nearest point is.
vec2 segDist(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return vec2(length(pa - ba * h), h);
}

// How a beam carries its music at distance `s` along it (from its emitter,
// through its bounces): a swell with its band's energy, times a travelling
// wave of brightness — long and slow on the low beam, fine and fast on the
// high one — plus, on the low beam, bright packets fired by kicks.
float resonance(bool high, float s) {
    float H = iResolution.y;
    float e = high ? iLaserBand.y : iLaserBand.x;
    float k = 6.2831853 / (H * (high ? 0.022 : 0.12));
    float wave = 1.0 + 0.55 * e * sin(s * k - (high ? iLaserPhase.y : iLaserPhase.x));
    float gain = (1.0 + 0.6 * e) * wave;
    if (!high && iLaserReact > 0.0) {
        float speed = H * 1.4;
        float width = H * 0.03;
        for (int j = 0; j < 4; j++) {
            float age = iLaserPulse[j];
            if (age >= 1.0) continue;
            float x = (s - speed * age * 1.6) / width;
            gain += 1.4 * iLaserReact * exp(-x * x) * (1.0 - age);
        }
    }
    return gain;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02, 0.02, 0.03);
    vec3 beam1 = (iPaletteSize > iLaserColor) ? iPalette[iLaserColor] : vec3(1.0, 0.15, 0.2);
    vec3 beam2 = (iPaletteSize > iLaserColor2) ? iPalette[iLaserColor2] : vec3(0.2, 0.5, 1.0);

    float w = iLaserWidth;
    vec3 light = vec3(0.0);
    // Light that reaches this pixel's smoke, gathered across the legs; the
    // (costly) density is only evaluated where it could be seen.
    vec3 lit = vec3(0.0);
    // How far a beam's light carries into the smoke around it.
    float scatter_r = iResolution.y * 0.05;
    // Near-field terms fade to nothing within this reach; beyond it a leg
    // only lights the smoke.
    float near_r = w * 40.0;
    vec3 flare_glow = vec3(0.0);
    for (int i = 0; i < iLaserCount && i < 64; i++) {
        bool high = i >= iLaserSplit;
        vec3 beam = high ? beam2 : beam1;
        vec4 s = iLaserSeg[i];
        vec4 L = iLaserLeg[i];
        float I = L.x;
        float arrived = L.y;
        vec2 dh = segDist(fc, s.xy, s.zw);
        float d = dh.x;
        float r = length(fc - s.xy);
        // The band's swell also reaches the smoke; the travelling wave and
        // the pulses are drawn on the beam itself.
        float swell = 1.0 + 0.6 * (high ? iLaserBand.y : iLaserBand.x);

        if (d < near_r || r < near_r) {
            float g = resonance(high, L.w + dh.y * length(s.zw - s.xy));
            // A louder beam also runs a little thicker.
            float wb = w * (1.0 + 0.3 * (high ? iLaserBand.y : iLaserBand.x));
            // The hot core burns toward white; the halo keeps the colour.
            vec3 core_c = mix(beam, vec3(1.0), 0.65);
            light += core_c * exp(-(d * d) / (wb * wb)) * I * g;
            light += beam * exp(-d / (wb * 5.0)) * I * 0.35 * g;
            // A flare where the beam struck (or left its emitter), sized
            // and lit by what arrived.
            light += core_c * exp(-r * r / (w * w * 9.0)) * arrived * 0.9 * swell;
            flare_glow += beam * exp(-r / (w * 7.0)) * arrived * 0.45 * L.z * swell;
        }
        // Light carried into the smoke around the beam, and the patch a
        // strike lights up.
        lit += beam * swell * (exp(-d / scatter_r) * I * 0.4 + exp(-r / (scatter_r * 2.5)) * arrived * 0.5);
    }

    // Scattered light is speckled; the beam core in clear air is not.
    float sp = mix(1.0, speckle(fc), iLaserSpeckle);
    light += flare_glow * sp;

    // In-scattering: smoke glows in the colour of the light passing it.
    if (iLaserSmoke > 0.0 && max(lit.r, max(lit.g, lit.b)) * iLaserSmoke > 0.004)
        light += lit * smokeDensity(fc) * iLaserSmoke * sp;

    // Soft shoulder so overlapping legs and flares saturate gracefully.
    vec3 col = bg + light / (1.0 + 0.25 * light);
    fragColor = vec4(col, 1.0);
}
