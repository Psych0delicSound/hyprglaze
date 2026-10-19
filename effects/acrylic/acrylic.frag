#version 300 es
precision highp float;

// acrylic — Balatro-style paint bands shaped by the component's GPU flow field.
//
// The native layer is procedural: it samples the local flow direction and lays
// long, sinuous contour bands along it. The black body is broad and low
// contrast, blue veins are narrow bands, and white is a rare thin core inside a
// blue vein. Nothing is advected, so the bands keep crisp edges instead of
// diffusing into a haze.

uniform vec3 iResolution;
uniform float iTime;

uniform sampler2D iAcrFlowTex;   // RG velocity in px/s
uniform sampler2D iAcrDyeTex;    // advected warp phase in R
uniform float iAcrActive;
uniform float iAcrFlowScale;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

float hash21(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p = mat2(1.6, 1.2, -1.2, 1.6) * p;
        a *= 0.55;
    }
    return v;
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec3 black = iPaletteSize > 0 ? iPaletteBg : vec3(0.012, 0.013, 0.015);

    if (iAcrActive < 0.5) {
        fragColor = vec4(black, 1.0);
        return;
    }

    vec3 blue = iPaletteSize > 2 ? iPalette[2] : vec3(0.18, 0.56, 1.0);
    vec3 deep = iPaletteSize > 11 ? iPalette[11] : vec3(0.07, 0.25, 0.68);
    vec3 white = iPaletteSize > 15 ? iPalette[15] : vec3(1.0);

    // Local flow frame: the bands run along the stream. Blending toward a fixed
    // direction at low speed avoids a hard seam where the field goes calm.
    vec2 vel = texture(iAcrFlowTex, uv).xy;
    float speed = length(vel);
    vec2 vd = vel / max(speed, 1.0e-4);
    vec2 gd = vec2(0.7071, 0.7071);
    vec2 d0 = mix(gd, vd, smoothstep(0.0, 4.0, speed));
    vec2 dir = length(d0) > 0.1 ? normalize(d0) : gd;
    vec2 side = vec2(-dir.y, dir.x);

    // Aspect-corrected centred coordinates.
    vec2 p = (uv - 0.5) * vec2(iResolution.x / iResolution.y, 1.0);
    vec2 q = p * 3.0;

    float along = dot(q, dir);
    float across = dot(q, side);
    float t = iTime;

    // The advected warp carries the window's drag as a persistent phase offset.
    float warp = texture(iAcrDyeTex, uv).r;

    // Long sinuous contours: the across-flow coordinate is warped mainly along
    // the flow, so its level sets stretch into filaments instead of blobs.
    float f = across + (warp - 0.5) * 10.0
            + 0.45 * sin(along * 0.80 + t * 0.05)
            + 0.22 * sin(along * 1.50 - across * 0.50 + t * 0.07)
            + 0.10 * sin(along * 2.60 + across * 1.00 - t * 0.09);

    // Slow organic modulation so the bands are never perfectly regular.
    float n = fbm(p * 1.4 + vec2(t * 0.010, -t * 0.008));

    // Black body: broad bands, a low-contrast dark sheen rather than a field.
    float bblack = 0.5 + 0.5 * sin(f * 1.00 + 0.6 + n * 0.8 + t * 0.015);
    float black_cov = smoothstep(0.20, 0.80, bblack);
    vec3 black_liq = mix(black, deep, 0.08 + 0.13 * black_cov);

    // Blue veins: narrow bands, the second liquid.
    float bblue = 0.5 + 0.5 * sin(f * 2.80 + 1.9 + n * 0.9 + t * 0.030);
    float blue_cov = smoothstep(0.95, 0.998, bblue);

    // White: rare thin cores that only exist inside a blue vein.
    float bwhite = 0.5 + 0.5 * sin(f * 5.50 + 3.4 + n * 1.2 + t * 0.035);
    float white_cov = smoothstep(0.980, 0.9998, bwhite) * smoothstep(0.45, 0.95, blue_cov);

    vec3 col = black;
    col = mix(col, black_liq, 0.92);

    vec3 blue_mix = mix(deep, blue, smoothstep(0.30, 0.95, blue_cov));
    col = mix(col, blue_mix, blue_cov * 0.92);
    col = mix(col, white, white_cov * 0.72);

    // A faint wet sheen on the moving paint.
    float sp = clamp(speed / max(iAcrFlowScale, 1.0), 0.0, 1.0);
    col += mix(black, white, 0.05) * sp * (0.30 + 0.55 * blue_cov);

    // Whisper of grain so the black never bands.
    col += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233)) + t) * 43758.5453) - 0.5) * 0.014;

    fragColor = vec4(col, 1.0);
}
