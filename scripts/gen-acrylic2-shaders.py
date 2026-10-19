#!/usr/bin/env python3
"""Regenerate effects/acrylic2 from the original flow-ref3 Shadertoy passes.

Reads flow-ref3*.frag from a reference directory (the Shadertoy export) and
rewrites:

    effects/acrylic2/acrylic2.frag   the Image pass (host display shader)
    effects/acrylic2/shaders.zig      Buffers A-D as Zig string constants

The pass bodies and the Common tab are copied verbatim, with three additions:

  * Shadertoy plumbing: `iChannelN` -> `uChN`, `iChannelResolution[N]` ->
    `uResN`, a `main()` wrapper around the untouched `mainImage()`, and tabs
    expanded to spaces (Zig string literals reject raw tabs).
  * Window rigid bodies (`hgObstacle`, appended to Buffers A/B/C): windows are
    solid no-penetration bodies in the flow, so the fields bend around them.
  * A theme-colour source in the Image pass, replacing the reference's colour
    texture (`iChannel1`). The honey's colours now follow the live palette
    instead of a shipped JPEG, while the displacement/dispersion maths is
    untouched.

Usage:  scripts/gen-acrylic2-shaders.py [REF_DIR]
        (default $HOME/Works/shaders/desktop)
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "effects", "acrylic2")
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Works/shaders/desktop")

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

# Window rigid bodies. A window is a solid body: the field may not cross its
# boundary. `infl` is a soft boundary layer; relative motion decays to the
# body velocity at the surface (no-slip), and the inward normal component is
# removed outright (no penetration). Rectangles arrive in *buffer* pixels.
OBSTACLE = """
// ---- window rigid bodies: the flow cannot cross a window ----------------
uniform int uWinCount;
uniform vec4 uWin[32];     // xy = lo, zw = size   (buffer px)
uniform vec2 uWinVel[32];  // body velocity        (buffer px / s)
uniform float uWinScale;   // px/s that maps to a field value of 1
uniform float uWinBand;    // boundary-layer thickness (buffer px)
uniform float uWinCorner;  // rounded corner radius  (buffer px)
uniform float uWinNoSlip;  // 0..1, how hard the wall drags the flow

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
        vec2 nrm = hgBoxNormal(px, lo, hi, r);
        float infl = exp(-max(sd, 0.0) / max(uWinBand, 1.0));
        float inside = 1.0 - step(0.0, sd);

        vec2 body = uWinVel[i] / max(uWinScale, 1.0);
        body = length(body) > 1.0 ? normalize(body) : body;
        vec2 rel = v - body;
        rel -= nrm * min(dot(rel, nrm), 0.0);          // no penetration
        rel *= (1.0 - uWinNoSlip * infl) * (1.0 - inside);
        v = body + rel;
    }
    return v;
}
"""

# Theme-colour source for the Image pass. It stands in for the reference's
# colour texture: a fixed smooth field sampled through the live palette. The
# dispersion in `sampleDisp` then separates the palette into colour fringes.
THEME = """
// ---- theme colour source (replaces the reference colour texture) --------
float hgPattern(vec2 uv) {
    vec2 p = uv * vec2(iResolution.x / max(iResolution.y, 1.0), 1.0);
    float f = 0.0;
    f += 0.55 * sin(p.x * 2.1 + 1.7 * sin(p.y * 1.7 - 0.4));
    f += 0.30 * sin(p.y * 3.3 + 2.1 * sin(p.x * 2.6 + 0.9));
    f += 0.15 * sin((p.x + p.y) * 5.3 + 1.3);
    return 0.5 + 0.5 * f;
}

vec3 hgPalette(float v) {
    v = clamp(v, 0.0, 1.0);
    if (iPaletteSize < 2) return mix(iPaletteBg, iPaletteFg, v);
    float x = v * float(iPaletteSize - 1);
    int i = int(floor(x));
    int j = min(i + 1, iPaletteSize - 1);
    return mix(iPalette[i], iPalette[j], fract(x));
}

vec3 hgTheme(vec2 uv) { return hgPalette(hgPattern(uv)); }
"""

COMMON = open(os.path.join(SRC, "flow-ref3-buffer-common.frag")).read()


def transform(text):
    text = text.expandtabs(4)
    text = text.replace("iChannelResolution[0]", "uRes0")
    text = text.replace("iChannelResolution[1]", "uRes1")
    for i in range(4):
        text = text.replace("iChannel%d" % i, "uCh%d" % i)
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
    return body


def build(fname, extra="", post=()):
    body = open(os.path.join(SRC, fname)).read()
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
        # C stores its velocity 0.5-centred in xy; keep that convention.
        "vec2 vC = hg_fragColor.xy - 0.5;",
        "vC = hgObstacle(vC, gl_FragCoord.xy);",
        "hg_fragColor.xy = vC + 0.5;",
    ]),
    ("pass_d", "flow-ref3-buffer-d.frag", []),
]


def main():
    out = [
        "//! effects/acrylic2/shaders.zig - generated from the flow-ref3 Shadertoy",
        "//! passes by scripts/gen-acrylic2-shaders.py. Do not hand-edit.",
        "",
    ]
    for name, fname, post in PASSES:
        out.append(zstr(name, build(fname, OBSTACLE if post else "", post)))
    with open(os.path.join(OUT, "shaders.zig"), "w") as f:
        f.write("\n".join(out))
    with open(os.path.join(OUT, "acrylic2.frag"), "w") as f:
        f.write(build("flow-ref3.frag", THEME))
    print("wrote shaders.zig and acrylic2.frag from", SRC)


if __name__ == "__main__":
    main()
