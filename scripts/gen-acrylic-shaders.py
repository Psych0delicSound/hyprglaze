#!/usr/bin/env python3
"""Regenerate effects/acrylic from the original flow-ref3 Shadertoy passes.

Reads flow-ref3*.frag from a reference directory (the Shadertoy export) and
rewrites:

    effects/acrylic/acrylic.frag   the Image pass (host display shader)
    effects/acrylic/shaders.zig      Buffers A-D as Zig string constants

The pass bodies and the Common tab are copied verbatim, with these additions:

  * Shadertoy plumbing: `iChannelN` -> `uChN`, `iChannelResolution[N]` ->
    `uResN`, a `main()` wrapper around the untouched `mainImage()`, and tabs
    expanded to spaces (Zig string literals reject raw tabs).
  * Window rigid bodies (`hgObstacle`, appended to Buffers A/B/C): windows are
    solid no-penetration bodies in the flow, so the fields bend around them.
  * A theme-colour source replacing the reference's colour texture
    (`iChannel1`): a static field of small, hashed paint islands, rendered once
    at buffer resolution into `uCh1` by `pass_paint`. The Image pass's
    dispersion shortens (`DISP_SCALE`) so each island stays a short stream
    instead of smearing into a screen-spanning ribbon; the dispersed intensity
    is quantised onto the live palette (mostly OLED black, with deep/light-blue
    and white streaks). The displacement maths is untouched.
  * Slow/viscous `tune()` constants in Buffers A/B/C (advection distances and
    timestep down, fluid inertia up). The equations are untouched.

Usage:  scripts/gen-acrylic-shaders.py [REF_DIR]
        (default $HOME/Works/shaders/desktop)
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "effects", "acrylic")
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Works/shaders/desktop")
DEBUG_GRAY = os.environ.get("HG_ACRYLIC_DEBUG_GRAY") == "1"

PRELUDE = """#version 300 es
precision highp float;
uniform vec3 iResolution;
uniform float iTime;
uniform int iFrame;
uniform vec4 iMouse;
uniform sampler2D uCh0;
uniform sampler2D uCh1;
uniform sampler2D uCh2;
uniform sampler2D uCh3;
uniform vec3 uRes0;
uniform vec3 uRes1;
uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;
"""

# Window rigid bodies. A window is a solid, impermeable body in the flow. The
# base is the magnet-fix projection: the inward normal component of the field is
# removed, so flow bends around the window instead of crossing it. On top of
# that, only component add/removes (nothing that reconstructs a magnitude, so
# there is no offset drift):
#   * inside the body the tangential part is damped (`uWinPush`), so material
#     cannot circulate under the window and only the outward component survives;
#   * at the surface the removed inflow is bent into an edge-parallel slide
#     (`uWinTurn`) with an extra swirl (`uWinCurl`), so head-on flow rolls
#     around the body;
#   * `uWinNoSlip` optionally drags the field toward rest at the surface.
# Rectangles arrive in *buffer* pixels.
OBSTACLE = """
// ---- window rigid bodies: the flow cannot cross a window ----------------
uniform int uWinCount;
uniform vec4 uWin[32];     // xy = lo, zw = size   (buffer px)
uniform vec2 uWinVel[32];  // body velocity        (buffer px / s)
uniform float uWinScale;   // px/s that maps to a field value of 1
uniform float uWinBand;    // boundary-layer thickness (buffer px)
uniform float uWinCorner;  // rounded corner radius  (buffer px)
uniform float uWinNoSlip;  // 0..1, how hard the wall drags the flow
uniform float uWinPush;    // 0..1, how hard the body damps its interior flow
uniform float uWinTurn;    // 0..1, inflow bent into an edge-parallel slide
uniform float uWinCurl;    // extra swirl added to the slide
uniform float uWinWall;    // 0..1, push ahead of a moving window's bounds

float hgSdBox(vec2 p, vec2 lo, vec2 hi, float r) {
    vec2 c = (lo + hi) * 0.5;
    vec2 h = max((hi - lo) * 0.5 - vec2(r), vec2(0.0));
    vec2 q = abs(p - c) - h;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

vec2 hgBoxNormal(vec2 p, vec2 lo, vec2 hi, float r) {
    vec2 c = (lo + hi) * 0.5;
    vec2 h = max((hi - lo) * 0.5 - vec2(r), vec2(0.0));
    vec2 q = abs(p - c) - h;
    if (max(q.x, q.y) > 0.0)
        return normalize(max(q, vec2(0.0)) * sign(p - c));
    return (q.x > q.y)
        ? vec2(sign(p.x - c.x), 0.0)
        : vec2(0.0, sign(p.y - c.y));
}

vec2 hgObstacle(vec2 v, vec2 px) {
    for (int i = 0; i < uWinCount; i++) {
        vec4 w = uWin[i];
        if (w.z < 1.0 || w.w < 1.0) continue;
        vec2 lo = w.xy;
        vec2 hi = w.xy + w.zw;
        float r = min(uWinCorner, min(w.z, w.w) * 0.5);
        float sd = hgSdBox(px, lo, hi, r);
        // The body only exists at its surface and inside it. Without this
        // gate the outward normal reaches across the whole screen and drags
        // every flow toward the window.
        if (sd > uWinBand) continue;

        vec2 nrm = hgBoxNormal(px, lo, hi, r);
        float t = clamp(1.0 - sd / max(uWinBand, 1.0), 0.0, 1.0);

        vec2 body = uWinVel[i] / max(uWinScale, 1.0);
        body = length(body) > 1.0 ? normalize(body) : body;
        vec2 rel = v - body;

        // Inflow that would cross the wall, captured before it is removed.
        float vn = dot(rel, nrm);
        float inflow = -min(vn, 0.0);

        // No penetration: drop the inward normal component (this is the
        // magnet-fix projection, kept as the base).
        rel -= nrm * min(vn, 0.0);

        if (sd < 0.0) {
            // Nothing may live under the window. Damp the whole field from
            // the edge inward, so the interior settles to no flow instead of
            // keeping a window-shaped imprint that leaks out as a trail.
            float inside = clamp(-sd / max(uWinBand, 1.0), 0.0, 1.0);
            rel *= 1.0 - clamp(uWinPush, 0.0, 1.0) * inside;
        } else {
            // Surface: bend the removed inflow along the edge and add a swirl
            // so a head-on stream rolls around the body instead of piling up.
            vec2 tang = rel - nrm * dot(rel, nrm);
            float tl = length(tang);
            vec2 tdir = tl > 1e-5 ? tang / tl : vec2(-nrm.y, nrm.x);
            rel += tdir * inflow * uWinTurn;
            rel += vec2(-nrm.y, nrm.x) * (uWinCurl * t * inflow);
            // Push relative to the bounds: project the window's own motion on
            // the outward normal, so the leading edge shoves flow ahead of it.
            float wall = max(dot(body, nrm), 0.0);
            rel += nrm * wall * uWinWall * t;
        }

        rel *= 1.0 - uWinNoSlip * t;                   // optional no-slip
        v = body + rel;
    }
    return v;
}
"""

# Paint source. It stands in for the reference's colour texture: a static
# field of small, randomly placed islands rather than one continuous vein
# network. Rendered once at buffer resolution into `uCh1` (see effect.zig), so
# the Image pass's 64 dispersion taps are texture reads instead of re-evaluating
# a procedural source per tap. The scattered islands keep the idle field from
# collapsing into a single screen-spanning flow, and the flow's own displacement
# bends them into short, distinct streams that collide and slide past each other.
PAINT = """
#version 300 es
precision highp float;
uniform vec3 iResolution;

float hgHash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// One layer of small, randomly placed paint islands. Each grid cell holds a
// single jittered, randomly rotated ellipse; the hash makes the layout stable
// between frames but different from one cell to the next. Some cells are left
// empty so the stream sizes and spacing stay irregular.
float hgIslands(vec2 p, float scale, float seed, float size) {
    vec2 cell = p * scale + seed;
    vec2 id = floor(cell);
    vec2 f = fract(cell) - 0.5;

    float h0 = hgHash21(id + seed * 1.7);
    float h1 = hgHash21(id + seed * 3.1 + 11.0);
    float h2 = hgHash21(id + seed * 5.3 + 23.0);
    float h3 = hgHash21(id + seed * 7.9 + 41.0);
    float h4 = hgHash21(id + seed * 9.7 + 59.0);

    vec2 q = f - (vec2(h0, h1) - 0.5) * 0.55;
    float a = h2 * 6.2831853;
    q = mat2(cos(a), -sin(a), sin(a), cos(a)) * q;

    // Slightly elongated so the island reads as a short flow, not a dot.
    vec2 e = q / vec2(size * (0.7 + 0.9 * h3), size);
    float d = length(e);
    float b = 1.0 - smoothstep(0.35, 1.0, d);
    return b * b * (0.55 + 0.45 * h3) * step(0.22, h4);
}

float hgPaint(vec2 uv) {
    vec2 p = (uv - 0.5) * vec2(iResolution.x / max(iResolution.y, 1.0), 1.0);
    float paint = 0.0;
    paint = max(paint, hgIslands(p, 4.5, 0.0, 0.28));
    paint = max(paint, hgIslands(p, 8.0, 3.0, 0.20));
    paint = max(paint, hgIslands(p, 15.0, 7.0, 0.14));
    return paint;
}

out vec4 hg_fragColor;
void main() {
    hg_fragColor = vec4(vec3(hgPaint(gl_FragCoord.xy / iResolution.xy)), 1.0);
}
"""

# The Image pass samples the rendered paint source. The final stage maps the
# dispersed intensity onto the theme's black / deep-blue / light-blue / white
# ramp.
THEME = """
// ---- theme paint source (replaces the reference colour texture) ----------
// Display-only inputs (the host sets these for the Image/display shader).
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

// uCh1 is the small-island paint field rendered once by the component.
vec3 hgTheme(vec2 uv) { return texture(uCh1, uv).rgb; }

// Rounded-box SDF for the window light (same shape as the flow obstacle).
float hgWinSd(vec2 p, vec4 w, float r) {
    vec2 c = w.xy + w.zw * 0.5;
    vec2 h = max(w.zw * 0.5 - vec2(r), vec2(0.0));
    vec2 q = abs(p - c) - h;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Dark-light logic borrowed from weft, but much weaker: flows lift near a
// window and the far field rests a little darker. It only scales colour, so
// the black body stays black.
vec3 hgWindowLight(vec3 col, vec2 px) {
    float halo = 0.0;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 w = iWindows[i];
        if (w.z < 1.0 || w.w < 1.0) continue;
        float d = hgWinSd(px, w, 12.0);
        float focus = 0.0;
        if (i == iFocusedIndex) focus = smoothstep(0.0, 1.0, iTransition);
        if (i == iPrevIndex) focus = max(focus, 1.0 - smoothstep(0.0, 1.0, iTransition));
        halo += exp(-max(d, 0.0) / (90.0 + 50.0 * focus)) * (0.6 + 0.4 * focus);
    }
    halo = clamp(halo, 0.0, 1.0);
    return col * mix(0.78, 1.14, halo);
}

// weft's field grain, additive so it survives on a black surface.
float hgGrain(vec2 cell, float seed) {
    uvec3 v = uvec3(uvec2(ivec2(cell) + 8192), uint(seed));
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z;
    return float(v.x & 0x00ffffffu) / 16777216.0;
}

// Black body, deep-blue veins, rarer light-blue veins, rare white cores.
vec3 hgPalette(float p) {
    vec3 black = iPaletteBg;
    vec3 deep  = (iPaletteSize > 10) ? iPalette[10] : vec3(0.07, 0.25, 0.68);
    vec3 light = (iPaletteSize > 2)  ? iPalette[2]  : vec3(0.18, 0.56, 1.00);
    vec3 white = (iPaletteSize > 15) ? iPalette[15] : vec3(1.0);
    vec3 c = black;
    c = mix(c, deep,  smoothstep(0.200, 0.240, p));
    c = mix(c, light, smoothstep(0.420, 0.470, p));
    c = mix(c, white, smoothstep(0.660, 0.710, p));
    return c;
}
"""

COMMON = open(os.path.join(SRC, "flow-ref3-buffer-common.frag")).read()


def transform(text):
    text = text.expandtabs(4)
    text = text.replace("iChannelResolution[0]", "uRes0")
    text = text.replace("iChannelResolution[1]", "uRes1")
    for i in range(4):
        text = text.replace("iChannel%d" % i, "uCh%d" % i)
    return text


# Slow, viscous tuning of the reference dynamics. The fracturing and fluid
# fields advect a shorter distance per frame, the fluid update keeps more of its
# previous state (inertia), and the single-pass CFD carries the carried
# coordinate less far, so the paint stretches and lingers instead of churning.
def tune(fname, text):
    if fname == "flow-ref3-buffer-a.frag":
        text = text.replace("#define TIMESTEP 0.1", "#define TIMESTEP 0.007")
        text = text.replace("#define ADVECT_DIST 2.0", "#define ADVECT_DIST 0.3")
    elif fname == "flow-ref3-buffer-b.frag":
        text = text.replace("const float ad = 6.0;", "const float ad = 0.45;")
        text = text.replace("const float upd = 0.99;", "const float upd = 0.9997;")
    elif fname == "flow-ref3-buffer-c.frag":
        text = text.replace("v*vec2(-1,1)*2.0", "v*vec2(-1,1)*0.12")
    elif fname == "flow-ref3.frag":
        # Shorter dispersion: the paint islands stay short, separate streams
        # instead of being smeared into screen-spanning ribbons.
        text = text.replace("#define DISP_SCALE 1.50", "#define DISP_SCALE 0.90")
    return text


def theme_image(body):
    """Make the Image pass sample the palette instead of the colour texture."""
    body = body.replace(
        "texture(iChannel1, uv + dispNorm * disp * wl).xyz",
        "hgTheme(uv + dispNorm * disp * wl)",
    )
    # The remaining channel-1 probe only feeds `colz`, which is overwritten.
    body = re.sub(
        r"vec3 colz = vec3\(texture\(iChannel1,.*?\);",
        "vec3 colz = hgTheme(uv);",
        body,
        count=1,
        flags=re.S,
    )
    # The reference finishes with contrast + ACES + a lava-lamp glow, which
    # floods the screen with colour. Replace it with the theme ramp driven by
    # the dispersed paint intensity.
    if DEBUG_GRAY:
        replacement = "colz = vec3((col.r + col.g + col.b) / 3.0);"
    else:
        replacement = (
            "colz = hgPalette((col.r + col.g + col.b) / 3.0);\n"
            "     colz = hgWindowLight(colz, gl_FragCoord.xy);\n"
            "     colz += (hgGrain(floor(gl_FragCoord.xy / 2.0), floor(iTime * 10.0)) - 0.5) * 0.035;"
        )
    body = re.sub(
        r"colz = vec3\(contrast\(col\).*?;",
        replacement,
        body,
        count=1,
        flags=re.S,
    )
    return body


def build(fname, extra="", post=()):
    body = open(os.path.join(SRC, fname)).read()
    body = tune(fname, body)
    if fname == "flow-ref3.frag":
        body = theme_image(body)
    epilogue = ["", "out vec4 hg_fragColor;", "void main() {",
                "    mainImage(hg_fragColor, gl_FragCoord.xy);"]
    for line in post:
        epilogue.append("    " + line)
    epilogue += ["}", ""]
    return (PRELUDE + "\n" + transform(COMMON) + "\n" + extra + "\n"
            + transform(body) + "\n".join(epilogue))


def zstr(name, value):
    lines = value.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    body = "\n".join("    \\\\" + ln for ln in lines)
    return "pub const %s: [:0]const u8 =\n%s\n;\n" % (name, body)


PASSES = [
    ("pass_a", "flow-ref3-buffer-a.frag", [
        "hg_fragColor.xy = hgObstacle(hg_fragColor.xy, gl_FragCoord.xy);",
        "hg_fragColor.zw = hgObstacle(hg_fragColor.zw, gl_FragCoord.xy);",
    ]),
    ("pass_b", "flow-ref3-buffer-b.frag", [
        "hg_fragColor.xy = hgObstacle(hg_fragColor.xy, gl_FragCoord.xy);",
    ]),
    ("pass_c", "flow-ref3-buffer-c.frag", [
        "hg_fragColor.xy = hgObstacle(hg_fragColor.xy, gl_FragCoord.xy);",
    ]),
    ("pass_d", "flow-ref3-buffer-d.frag", []),
]


def main():
    out = [
        "//! effects/acrylic/shaders.zig - generated from the flow-ref3 Shadertoy",
        "//! passes by scripts/gen-acrylic-shaders.py. Do not hand-edit.",
        "",
    ]
    for name, fname, post in PASSES:
        out.append(zstr(name, build(fname, OBSTACLE if post else "", post)))
    out.append(zstr("pass_paint", PAINT))
    with open(os.path.join(OUT, "shaders.zig"), "w") as f:
        f.write("\n".join(out))
    with open(os.path.join(OUT, "acrylic.frag"), "w") as f:
        f.write(build("flow-ref3.frag", THEME))
    print("wrote shaders.zig and acrylic.frag from", SRC)


if __name__ == "__main__":
    main()
