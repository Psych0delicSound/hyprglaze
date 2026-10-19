#version 300 es
precision highp float;

uniform vec3 iResolution;

// Effect-local uniforms, pushed by effects/acrylic/effect.zig.
uniform float iAcrTime;    // effect-local clock, seconds
uniform float iAcrActive;  // 1 once the component has uploaded its fields
uniform sampler2D iAcrField;    // RGB accent light, A liquid density
uniform sampler2D iAcrFlowTex;  // RG velocity (biased ±), B agitation

// Theme palette (standard uniforms).
uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

// ---------------------------------------------------------------------------
// The liquid is simulated on the CPU. `iAcrField` is a coarse, linear-filtered
// density/colour field splatted from the particle pool; `iAcrFlowTex` carries
// the density-weighted velocity. The surface is mostly theme black: the black
// particles dominate the pool, and the minority accent particles only tint the
// cells they occupy. Window motion shows up as velocity and as density waves,
// which this shader turns into a wet sheen on the black body.
// ---------------------------------------------------------------------------

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
    float a = 0.55;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = mat2(1.6, 1.2, -1.2, 1.6) * p;
        a *= 0.55;
    }
    return v;
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;

    vec3 black = iPaletteSize > 0 ? iPaletteBg : vec3(0.012, 0.013, 0.015);
    vec3 tip = iPaletteSize > 0 ? iPaletteFg : vec3(0.94, 0.95, 0.97);

    // Without the component (HG_NO_PLUGINS fallback) there is no field to
    // sample: the surface is simply the theme black.
    if (iAcrActive < 0.5) {
        fragColor = vec4(black, 1.0);
        return;
    }

    ivec2 fs = textureSize(iAcrField, 0);
    vec2 texel = 1.0 / vec2(fs);

    vec4 field = texture(iAcrField, uv);
    float dens = field.a;
    vec3 accent = field.rgb;

    // Velocity in px/s, decoded from the biased RG channels.
    vec2 vel = (texture(iAcrFlowTex, uv).rg * 2.0 - 1.0) * 900.0;
    float speed = length(vel);

    // Drag the colour lookup backwards along the flow: the minority colours
    // smear into wakes, which makes the liquid motion legible on black.
    vec2 trail = clamp(vel / 900.0, vec2(-1.0), vec2(1.0)) * 0.035;
    vec3 accent_trail = texture(iAcrField, uv - trail).rgb;
    accent = mix(accent, accent_trail, 0.45);

    // Density gradient -> a fake surface normal for relief.
    float hl = texture(iAcrField, uv - vec2(texel.x, 0.0)).a;
    float hr = texture(iAcrField, uv + vec2(texel.x, 0.0)).a;
    float hd = texture(iAcrField, uv - vec2(0.0, texel.y)).a;
    float hu = texture(iAcrField, uv + vec2(0.0, texel.y)).a;
    vec2 grad = vec2(hr - hl, hu - hd);

    // Fast liquid catches the light: waves and window wakes brighten here.
    float wave = smoothstep(0.03, 0.55, speed / 900.0);
    float relief = clamp(length(grad) * 6.0, 0.0, 1.0);

    // --- colour ------------------------------------------------------------
    // The body is the theme black, lifted a little where the pool is dense.
    vec3 col = black * (0.70 + 0.50 * dens);

    // The minority colours *tint* the liquid rather than glowing on top of it:
    // where accent particles are dense the black gives way to their colour.
    float cmask = clamp(max(accent.r, max(accent.g, accent.b)), 0.0, 1.0);
    col = mix(col, accent * 0.9, cmask);

    // Fast liquid catches the light. The wake of a moving window is a bright
    // travelling band, so the black surface reads as water, not a flat fill.
    vec3 sheen = mix(black, tip, 0.5);
    col += sheen * wave * 0.50;

    // Density relief: slower folds in the surface.
    col += mix(black, tip, 0.10) * relief * 0.40;

    // A soft specular glint on wave crests.
    vec3 n = normalize(vec3(-grad * 9.0, 1.0));
    float spec = pow(max(dot(n, normalize(vec3(0.35, 0.55, 0.75))), 0.0), 22.0);
    col += tip * spec * (0.02 + 0.05 * wave);

    // A whisper of fine grain so the black never bands.
    col += (fbm(uv * 55.0 + iAcrTime * 0.05) - 0.5) * 0.016;

    fragColor = vec4(col, 1.0);
}
