#version 300 es
precision highp float;

// MilkDrop's display pass. The feedback loop itself runs in
// src/effects/milkdrop; this applies the preset's video echo (a second,
// zoomed and optionally flipped copy of the frame laid over it) and its
// gamma/brighten/darken/solarize/invert filters, then screens the light
// over the theme's background.

uniform vec3 iResolution;
uniform sampler2D iSprite;   // the feedback frame: light over black
uniform vec4 iMdEcho;        // alpha, zoom, orientation (0 none, 1 x, 2 y, 3 both)
uniform vec4 iMdTone;        // gamma, brighten, darken, solarize (0..1 each but gamma)
uniform float iMdInvert;

uniform int iPaletteSize;
uniform vec3 iPaletteBg;

out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec3 col = texture(iSprite, uv).rgb;

    if (iMdEcho.x > 0.001) {
        vec2 e = (uv - 0.5) / max(iMdEcho.y, 0.01);
        int o = int(iMdEcho.z + 0.5);
        if (o == 1 || o == 3) e.x = -e.x;
        if (o == 2 || o == 3) e.y = -e.y;
        vec3 echo = texture(iSprite, e + 0.5).rgb;
        col = mix(col, echo, iMdEcho.x);
    }

    col *= iMdTone.x;
    col = clamp(col, 0.0, 1.0);
    col = mix(col, sqrt(col), iMdTone.y);
    col = mix(col, col * col, iMdTone.z);
    col = mix(col, col * (1.0 - col) * 4.0, iMdTone.w);
    col = mix(col, 1.0 - col, iMdInvert);

    vec3 bg = iPaletteSize > 0 ? iPaletteBg : vec3(0.02);
    fragColor = vec4(1.0 - (1.0 - bg) * (1.0 - col), 1.0);
}
