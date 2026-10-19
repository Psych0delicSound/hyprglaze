#version 300 es
precision highp float;

// Glitch: the display end of a circuit-bent video feedback loop. The loop
// itself runs in src/effects/glitch.zig at video resolution; this pass is
// the monitor: it maps the loop's monochrome signal onto the theme's
// surface tones, lets accents bleed off sideways like delayed chroma, rings
// on hard edges, and draws the scanlines the signal really has.

uniform vec3 iResolution;
// The loop's last frames, newest at layer iGlitchHead: r luma, g accent
// strength, b accent hue.
uniform highp sampler2DArray iGlitchHist;
uniform int iGlitchHead;
uniform vec4 iGlitchSlit;     // slit-scan: depth (frames), band height (uv), seed
uniform vec2 iGlitchSim;      // loop resolution
uniform vec4 iGlitchTear;     // tear band: y (0..1), x shift (uv), half height
uniform float iGlitchChroma;  // chroma delay, loop pixels
uniform vec4 iGlitchPix;      // mosaic: block (loop px, 0 = off), zone share, seed
uniform vec4 iGlitchDither;   // ordered dither: levels (0 = off), cell (screen px)
uniform vec4 iGlitchVsync;    // vsync: roll offset (0..1), blanking bar height, bounce (screen px)

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

const int SLOTS = 16;

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// 4x4 Bayer threshold, 0..1.
float bayer4(vec2 p) {
    ivec2 i = ivec2(mod(p, 4.0));
    int m[16] = int[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
    return (float(m[i.y * 4 + i.x]) + 0.5) / 16.0;
}

vec3 bgColor() {
    return iPaletteSize > 0 ? iPaletteBg : vec3(0.09, 0.08, 0.13);
}

// Surface tones: background up to the muted grey (bright black), with a
// trace of foreground only where ringing overshoots past full signal.
vec3 surface(float y) {
    vec3 bg = bgColor();
    vec3 muted = iPaletteSize > 8 ? iPalette[8] : mix(bg, vec3(0.6), 0.4);
    vec3 fg = iPaletteSize > 0 ? iPaletteFg : vec3(0.85);
    vec3 lift = mix(bg, muted, 0.4);
    if (y < 0.5) return mix(bg, lift, y / 0.5);
    if (y < 1.0) return mix(lift, muted, (y - 0.5) / 0.5);
    return mix(muted, fg, min(y - 1.0, 1.0) * 0.6);
}

// Chromatic slots, normal then bright (skipping the neutrals 0, 7, 8, 15).
const int ACCENTS[12] = int[12](1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14);

vec3 accent(float hue) {
    int n = iPaletteSize > 14 ? 12 : 6;
    int k = ACCENTS[clamp(int(hue * float(n)), 0, n - 1)];
    return iPaletteSize > k ? iPalette[k] : vec3(0.8, 0.4, 0.6);
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;

    // Lost vertical hold: the picture bounces and rolls, and the blanking
    // interval it should hide scrolls through as a dark bar.
    uv.y = fract(uv.y + iGlitchVsync.x + iGlitchVsync.z / iResolution.y);
    float blank = iGlitchVsync.y > 0.0 ? 1.0 - step(iGlitchVsync.y, uv.y) : 0.0;

    // A torn band of the frame slips sideways.
    if (abs(uv.y - iGlitchTear.x) < iGlitchTear.z) uv.x = fract(uv.x + iGlitchTear.y);

    // Mosaic: zones of the frame drop to a coarse block grid.
    vec2 sim = uv * iGlitchSim;
    if (iGlitchPix.x > 0.0) {
        float b = iGlitchPix.x;
        if (hash12(floor(sim / (b * 6.0)) + iGlitchPix.z) < iGlitchPix.y) {
            sim = (floor(sim / b) + 0.5) * b;
            uv.x = sim.x / iGlitchSim.x;
        }
    }

    // Sample the loop row by row: nearest vertically (scanlines), smooth
    // along the line like an analogue signal.
    float row = (floor(sim.y) + 0.5) / iGlitchSim.y;
    // Slit-scan: each band of rows plays back from its own moment.
    float delay = floor(hash12(vec2(floor(uv.y / iGlitchSlit.y), iGlitchSlit.z)) * iGlitchSlit.x);
    float layer = float((iGlitchHead - int(delay) + SLOTS) % SLOTS);
    vec3 suv = vec3(uv.x, row, layer);
    float px = 1.0 / iGlitchSim.x;
    float y = texture(iGlitchHist, suv).r;

    // Composite ringing: a hard edge overshoots and leaves a ghost.
    float yl = texture(iGlitchHist, suv - vec3(1.5 * px, 0.0, 0.0)).r;
    y = clamp(y + (y - yl) * 0.55, 0.0, 1.6);

    // Crude ordered dither down to a few levels, in fat screen cells.
    if (iGlitchDither.x > 0.0) {
        float lv = iGlitchDither.x;
        float t = bayer4(floor(gl_FragCoord.xy / iGlitchDither.y));
        y = floor(min(y, 1.0) * lv + t) / lv;
    }

    vec3 col = surface(y);

    // Chroma arrives late: accents land to the right of the luma they rode.
    vec3 cuv = suv - vec3(iGlitchChroma * px, 0.0, 0.0);
    float a = texture(iGlitchHist, cuv).g;
    ivec2 ct = ivec2(mod(floor(cuv.xy * iGlitchSim), iGlitchSim));
    float hue = texelFetch(iGlitchHist, ivec3(ct, int(layer)), 0).b;
    col = mix(col, accent(hue), smoothstep(0.12, 0.6, a) * 0.85);

    // Scanline gap, darkened toward the background.
    float f = abs(fract(sim.y) - 0.5) * 2.0;
    col = mix(col, bgColor(), smoothstep(0.5, 1.0, f) * 0.22);

    // The blanking bar: darker than black, with the sync pulse a sliver
    // of muted grey through it.
    if (blank > 0.0) {
        float pulse = 1.0 - step(0.12, abs(uv.y / iGlitchVsync.y - 0.6));
        col = mix(bgColor() * 0.55, surface(0.8), pulse * 0.5);
    }

    fragColor = vec4(col, 1.0);
}
