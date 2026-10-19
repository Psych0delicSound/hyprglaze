#version 300 es
precision highp float;

// Starfield: the stars themselves are geometry the effect draws into
// iSprite, and the nebula that zooms past forever is rendered small into
// iStarNebula (both in src/effects/starfield.zig). This lays them over a
// fixed field of stars too far away to move.

uniform vec3 iResolution;
uniform sampler2D iSprite;
uniform sampler2D iStarNebula; // the nebula, rendered small
uniform vec2 iStarVp;      // vanishing point, uv
uniform float iStarRoll;   // camera roll, radians
uniform float iStarWarp;   // hyperspace, 0..1

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec3 pal(int i, vec3 fallback) {
    return iPaletteSize > i ? iPalette[i] : fallback;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;
    float aspect = iResolution.x / iResolution.y;

    // View space: centred on the vanishing point, square, unrolled.
    vec2 p = (uv - iStarVp) * vec2(aspect, 1.0);
    float cr = cos(-iStarRoll);
    float sr = sin(-iStarRoll);
    p = mat2(cr, sr, -sr, cr) * p;

    vec3 neb = texture(iStarNebula, uv).rgb * 0.16 * (1.0 - iStarWarp * 0.6);

    // Distant stars: fixed to the sky (they roll with it, never approach).
    float cell = 22.0 * iResolution.y / 1440.0;
    vec2 g = p * iResolution.y / cell;
    vec2 gi = floor(g);
    float h = hash12(gi + 17.0);
    float far = 0.0;
    if (h < 0.4) {
        vec2 sp = gi + 0.2 + 0.6 * vec2(hash12(gi + 3.0), hash12(gi + 9.0));
        float d = length(g - sp) * cell;
        float m = pow(hash12(gi + 41.0), 3.0);
        far = (1.0 - smoothstep(0.4, 1.3, d)) * (0.12 + 0.5 * m);
    }
    far *= 1.0 - iStarWarp;
    vec3 fg = iPaletteSize > 0 ? iPaletteFg : vec3(0.9);

    // Hyperspace: a glow opens down the tunnel ahead.
    float tunnel = exp(-length(p) * 3.0) * iStarWarp;
    vec3 warp_col = mix(pal(6, vec3(0.4, 0.7, 0.9)), fg, 0.4) * tunnel * 0.35;

    vec3 light = neb + fg * far + warp_col + texture(iSprite, uv).rgb;
    vec3 bg = iPaletteSize > 0 ? iPaletteBg : vec3(0.01, 0.01, 0.02);
    vec3 col = bg + light * (1.0 - bg);
    col *= 1.0 - 0.1 * length(uv - 0.5);
    fragColor = vec4(min(col, 1.0), 1.0);
}
