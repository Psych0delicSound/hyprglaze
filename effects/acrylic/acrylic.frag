#version 300 es
precision highp float;

// acrylic — viscous paint advected by the component's GPU flow field.
//
// The velocity field is simulated on the GPU; this layer shows the paint that
// was advected through it. Pigment is premultiplied (rgb = colour*coverage),
// so the theme black stays the body and colours stay filaments.

uniform vec3 iResolution;
uniform float iTime;

uniform sampler2D iAcrFlowTex;   // RG velocity in px/s
uniform sampler2D iAcrDyeTex;    // premultiplied pigment + coverage
uniform float iAcrActive;
uniform float iAcrFlowScale;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec3 black = iPaletteSize > 0 ? iPaletteBg : vec3(0.012, 0.013, 0.015);

    if (iAcrActive < 0.5) {
        fragColor = vec4(black, 1.0);
        return;
    }

    vec4 dye = texture(iAcrDyeTex, uv);
    float cov = clamp(dye.a, 0.0, 1.0);
    vec3 paint = clamp(dye.rgb / max(dye.a, 1.0e-3), 0.0, 1.0);

    vec3 col = black;
    // Narrow edge: coverage ramps sharply, so the veins stay filaments rather
    // than fogging the whole surface.
    col = mix(col, paint * 0.95, smoothstep(0.12, 0.65, cov));

    // A faint wet sheen on the moving paint.
    vec2 v = texture(iAcrFlowTex, uv).xy;
    float sp = clamp(length(v) / max(iAcrFlowScale, 1.0), 0.0, 1.0);
    col += mix(black, vec3(0.72, 0.84, 1.0), 0.10) * sp * cov;

    // A whisper of grain so the black never bands.
    col += (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233)) + iTime) * 43758.5453) - 0.5) * 0.016;

    fragColor = vec4(col, 1.0);
}
