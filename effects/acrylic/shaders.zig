//! effects/acrylic/shaders.zig - generated from the flow-ref3 Shadertoy
//! passes by scripts/gen-acrylic-shaders.py. Do not hand-edit.

pub const pass_a: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec3 iResolution;
    \\uniform float iTime;
    \\uniform int iFrame;
    \\uniform vec4 iMouse;
    \\uniform sampler2D uCh0;
    \\uniform sampler2D uCh1;
    \\uniform sampler2D uCh2;
    \\uniform sampler2D uCh3;
    \\uniform vec3 uRes0;
    \\uniform vec3 uRes1;
    \\uniform vec3 iPalette[16];
    \\uniform int iPaletteSize;
    \\uniform vec3 iPaletteBg;
    \\uniform vec3 iPaletteFg;
    \\
    \\
    \\#define pi acos(-1.)
    \\
    \\#define Margins .0
    \\
    \\#define sint(a) (asin(sin(a))*2. - 1.)
    \\
    \\#define rot(a) mat2(cos(a),-sin(a),sin(a),cos(a))
    \\
    \\#define pmod(p,d) mod(p - (d)*0.5, (d)) - 0.5*(d)
    \\
    \\float r11(float i){ return fract(sin(i*12.126)*12.6);}
    \\
    \\//#define xor(a,b,c) min(max((a),-(b)), max((b),-(a) - c)) 
    \\
    \\float ss( float c, float power, float bias){
    \\    c = clamp(c,-0.,1.);
    \\    //c = smoothstep(0.,1.,c);
    \\    
    \\    c = pow(c,1. + bias);
    \\    
    \\    float a = pow( abs(c), power);
    \\    float b = 1.-pow( abs(c - 1.), power);
    \\    
    \\    return mix(a,b,c);
    \\}
    \\float valueNoise(float i, float p){ return mix(r11(floor(i)),r11(floor(i) + 1.), ss(fract(i), p,0.6));}
    \\
    \\float valueNoiseStepped(float i, float p, float steps){ return mix(  floor(r11(floor(i))*steps)/steps, floor(r11(floor(i) + 1.)*steps)/steps, ss(fract(i), p,0.6));}
    \\
    \\
    \\// See: https://www.shadertoy.com/view/ls2Bz1
    \\// Spectral Colour Schemes
    \\// By Alan Zucconi
    \\// Website: www.alanzucconi.com
    \\// Twitter: @AlanZucconi
    \\
    \\// Example of different spectral colour schemes
    \\// to convert visible wavelengths of light (400-700 nm) to RGB colours.
    \\
    \\// The function "spectral_zucconi6" provides the best approximation
    \\// without including any branching.
    \\// Its faster version, "spectral_zucconi", is advised for mobile applications.
    \\
    \\
    \\// Read "Improving the Rainbow" for more information
    \\// http://www.alanzucconi.com/?p=6703
    \\
    \\
    \\
    \\float saturate (float x)
    \\{
    \\    return min(1.0, max(0.0,x));
    \\}
    \\vec3 saturate (vec3 x)
    \\{
    \\    return min(vec3(1.,1.,1.), max(vec3(0.,0.,0.),x));
    \\}
    \\
    \\// --- Spectral Zucconi --------------------------------------------
    \\// By Alan Zucconi
    \\// Based on GPU Gems: https://developer.nvidia.com/sites/all/modules/custom/gpugems/books/GPUGems/gpugems_ch08.html
    \\// But with values optimised to match as close as possible the visible spectrum
    \\// Fits this: https://commons.wikimedia.org/wiki/File:Linear_visible_spectrum.svg
    \\// With weighter MSE (RGB weights: 0.3, 0.59, 0.11)
    \\vec3 bump3y (vec3 x, vec3 yoffset)
    \\{
    \\    vec3 y = vec3(1.,1.,1.) - x * x;
    \\    y = saturate(y-yoffset);
    \\    return y;
    \\}
    \\
    \\// --- Spectral Zucconi 6 --------------------------------------------
    \\
    \\// Based on GPU Gems
    \\// Optimised by Alan Zucconi
    \\vec3 spectral_zucconi6 (float x)
    \\{
    \\    // w: [400, 700]
    \\    // x: [0,   1]
    \\
    \\    const vec3 c1 = vec3(3.54585104, 2.93225262, 2.41593945);
    \\    const vec3 x1 = vec3(0.69549072, 0.49228336, 0.27699880);
    \\    const vec3 y1 = vec3(0.02312639, 0.15225084, 0.52607955);
    \\
    \\    const vec3 c2 = vec3(3.90307140, 3.21182957, 3.96587128);
    \\    const vec3 x2 = vec3(0.11748627, 0.86755042, 0.66077860);
    \\    const vec3 y2 = vec3(0.84897130, 0.88445281, 0.73949448);
    \\
    \\    return
    \\        bump3y(c1 * (x - x1), y1) +
    \\        bump3y(c2 * (x - x2), y2) ;
    \\}
    \\
    \\// --- MATLAB Jet Colour Scheme ----------------------------------------
    \\vec3 spectral_jet(float w)
    \\{
    \\    // w: [400, 700]
    \\    // x: [0,   1]
    \\    float x = saturate((w - 400.0)/ 300.0);
    \\    vec3 c;
    \\
    \\    if (x < 0.25)
    \\        c = vec3(0.0, 4.0 * x, 1.0);
    \\    else if (x < 0.5)
    \\        c = vec3(0.0, 1.0, 1.0 + 4.0 * (0.25 - x));
    \\    else if (x < 0.75)
    \\        c = vec3(4.0 * (x - 0.5), 1.0, 0.0);
    \\    else
    \\        c = vec3(1.0, 1.0 + 4.0 * (0.75 - x), 0.0);
    \\
    \\    // Clamp colour components in [0,1]
    \\    return saturate(c);
    \\}
    \\
    \\
    \\// ---- window rigid bodies: the flow cannot cross a window ----------------
    \\uniform int uWinCount;
    \\uniform vec4 uWin[32];     // xy = lo, zw = size   (buffer px)
    \\uniform vec2 uWinVel[32];  // body velocity        (buffer px / s)
    \\uniform float uWinScale;   // px/s that maps to a field value of 1
    \\uniform float uWinBand;    // boundary-layer thickness (buffer px)
    \\uniform float uWinCorner;  // rounded corner radius  (buffer px)
    \\uniform float uWinNoSlip;  // 0..1, how hard the wall drags the flow
    \\uniform float uWinPush;    // 0..1, how hard the body damps its interior flow
    \\uniform float uWinTurn;    // 0..1, inflow bent into an edge-parallel slide
    \\uniform float uWinCurl;    // extra swirl added to the slide
    \\uniform float uWinWall;    // 0..1, push ahead of a moving window's bounds
    \\
    \\float hgSdBox(vec2 p, vec2 lo, vec2 hi, float r) {
    \\    vec2 c = (lo + hi) * 0.5;
    \\    vec2 h = max((hi - lo) * 0.5 - vec2(r), vec2(0.0));
    \\    vec2 q = abs(p - c) - h;
    \\    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    \\}
    \\
    \\vec2 hgBoxNormal(vec2 p, vec2 lo, vec2 hi, float r) {
    \\    vec2 c = (lo + hi) * 0.5;
    \\    vec2 h = max((hi - lo) * 0.5 - vec2(r), vec2(0.0));
    \\    vec2 q = abs(p - c) - h;
    \\    if (max(q.x, q.y) > 0.0)
    \\        return normalize(max(q, vec2(0.0)) * sign(p - c));
    \\    return (q.x > q.y)
    \\        ? vec2(sign(p.x - c.x), 0.0)
    \\        : vec2(0.0, sign(p.y - c.y));
    \\}
    \\
    \\vec2 hgObstacle(vec2 v, vec2 px) {
    \\    for (int i = 0; i < uWinCount; i++) {
    \\        vec4 w = uWin[i];
    \\        if (w.z < 1.0 || w.w < 1.0) continue;
    \\        vec2 lo = w.xy;
    \\        vec2 hi = w.xy + w.zw;
    \\        float r = min(uWinCorner, min(w.z, w.w) * 0.5);
    \\        float sd = hgSdBox(px, lo, hi, r);
    \\        // The body only exists at its surface and inside it. Without this
    \\        // gate the outward normal reaches across the whole screen and drags
    \\        // every flow toward the window.
    \\        if (sd > uWinBand) continue;
    \\
    \\        vec2 nrm = hgBoxNormal(px, lo, hi, r);
    \\        float t = clamp(1.0 - sd / max(uWinBand, 1.0), 0.0, 1.0);
    \\
    \\        vec2 body = uWinVel[i] / max(uWinScale, 1.0);
    \\        body = length(body) > 1.0 ? normalize(body) : body;
    \\        vec2 rel = v - body;
    \\
    \\        // Inflow that would cross the wall, captured before it is removed.
    \\        float vn = dot(rel, nrm);
    \\        float inflow = -min(vn, 0.0);
    \\
    \\        // No penetration: drop the inward normal component (this is the
    \\        // magnet-fix projection, kept as the base).
    \\        rel -= nrm * min(vn, 0.0);
    \\
    \\        if (sd < 0.0) {
    \\            // Nothing may live under the window. Damp the whole field from
    \\            // the edge inward, so the interior settles to no flow instead of
    \\            // keeping a window-shaped imprint that leaks out as a trail.
    \\            float inside = clamp(-sd / max(uWinBand, 1.0), 0.0, 1.0);
    \\            rel *= 1.0 - clamp(uWinPush, 0.0, 1.0) * inside;
    \\        } else {
    \\            // Surface: bend the removed inflow along the edge and add a swirl
    \\            // so a head-on stream rolls around the body instead of piling up.
    \\            vec2 tang = rel - nrm * dot(rel, nrm);
    \\            float tl = length(tang);
    \\            vec2 tdir = tl > 1e-5 ? tang / tl : vec2(-nrm.y, nrm.x);
    \\            rel += tdir * inflow * uWinTurn;
    \\            rel += vec2(-nrm.y, nrm.x) * (uWinCurl * t * inflow);
    \\            // Push relative to the bounds: project the window's own motion on
    \\            // the outward normal, so the leading edge shoves flow ahead of it.
    \\            float wall = max(dot(body, nrm), 0.0);
    \\            rel += nrm * wall * uWinWall * t;
    \\        }
    \\
    \\        rel *= 1.0 - uWinNoSlip * t;                   // optional no-slip
    \\        v = body + rel;
    \\    }
    \\    return v;
    \\}
    \\
    \\/*
    \\    A fracturing dynamical system
    \\    see: https://www.shadertoy.com/view/MsyXRW
    \\*/
    \\
    \\#define _G0 0.25
    \\#define _G1 0.125
    \\#define _G2 0.0625
    \\#define W0 -3.0
    \\#define W1 0.5
    \\#define TIMESTEP 0.007
    \\#define ADVECT_DIST 0.3
    \\#define DV 0.70710678
    \\
    \\// nonlinearity
    \\float nl(float x) {
    \\    return 1.0 / (1.0 + exp(W0 * (W1 * x - 0.5))); 
    \\}
    \\
    \\vec4 gaussian(vec4 x, vec4 x_nw, vec4 x_n, vec4 x_ne, vec4 x_w, vec4 x_e, vec4 x_sw, vec4 x_s, vec4 x_se) {
    \\    return _G0*x + _G1*(x_n + x_e + x_w + x_s) + _G2*(x_nw + x_sw + x_ne + x_se);
    \\}
    \\
    \\bool reset() {
    \\    return texture(uCh3, vec2(32.5/256.0, 0.5) ).x > 0.5;
    \\}
    \\
    \\vec2 normz(vec2 x) {
    \\    return x == vec2(0.0, 0.0) ? vec2(0.0, 0.0) : normalize(x);
    \\}
    \\
    \\vec4 advect(vec2 ab, vec2 vUv, vec2 step) {
    \\    
    \\    vec2 aUv = vUv - ab * ADVECT_DIST * step;
    \\    
    \\    vec2 n  = vec2(0.0, step.y);
    \\    vec2 ne = vec2(step.x, step.y);
    \\    vec2 e  = vec2(step.x, 0.0);
    \\    vec2 se = vec2(step.x, -step.y);
    \\    vec2 s  = vec2(0.0, -step.y);
    \\    vec2 sw = vec2(-step.x, -step.y);
    \\    vec2 w  = vec2(-step.x, 0.0);
    \\    vec2 nw = vec2(-step.x, step.y);
    \\
    \\    vec4 u =    texture(uCh0, fract(aUv));
    \\    vec4 u_n =  texture(uCh0, fract(aUv+n));
    \\    vec4 u_e =  texture(uCh0, fract(aUv+e));
    \\    vec4 u_s =  texture(uCh0, fract(aUv+s));
    \\    vec4 u_w =  texture(uCh0, fract(aUv+w));
    \\    vec4 u_nw = texture(uCh0, fract(aUv+nw));
    \\    vec4 u_sw = texture(uCh0, fract(aUv+sw));
    \\    vec4 u_ne = texture(uCh0, fract(aUv+ne));
    \\    vec4 u_se = texture(uCh0, fract(aUv+se));
    \\    
    \\    return gaussian(u, u_nw, u_n, u_ne, u_w, u_e, u_sw, u_s, u_se);
    \\}
    \\
    \\#define SQRT_3_OVER_2 0.86602540378
    \\#define SQRT_3_OVER_2_INV 0.13397459621
    \\
    \\vec2 diagH(vec2 x, vec2 x_v, vec2 x_h, vec2 x_d) {
    \\    return 0.5 * ((x + x_v) * SQRT_3_OVER_2_INV + (x_h + x_d) * SQRT_3_OVER_2);
    \\}
    \\
    \\vec2 diagV(vec2 x, vec2 x_v, vec2 x_h, vec2 x_d) {
    \\    return 0.5 * ((x + x_h) * SQRT_3_OVER_2_INV + (x_v + x_d) * SQRT_3_OVER_2);
    \\}
    \\
    \\void mainImage( out vec4 fragColor, in vec2 fragCoord )
    \\{
    \\    vec2 vUv = fragCoord.xy / iResolution.xy;
    \\    vec2 texel = 1. / iResolution.xy;
    \\    
    \\    vec2 n  = vec2(0.0, 1.0);
    \\    vec2 ne = vec2(1.0, 1.0);
    \\    vec2 e  = vec2(1.0, 0.0);
    \\    vec2 se = vec2(1.0, -1.0);
    \\    vec2 s  = vec2(0.0, -1.0);
    \\    vec2 sw = vec2(-1.0, -1.0);
    \\    vec2 w  = vec2(-1.0, 0.0);
    \\    vec2 nw = vec2(-1.0, 1.0);
    \\
    \\    vec4 u =    texture(uCh0, fract(vUv));
    \\    vec4 u_n =  texture(uCh0, fract(vUv+texel*n));
    \\    vec4 u_e =  texture(uCh0, fract(vUv+texel*e));
    \\    vec4 u_s =  texture(uCh0, fract(vUv+texel*s));
    \\    vec4 u_w =  texture(uCh0, fract(vUv+texel*w));
    \\    vec4 u_nw = texture(uCh0, fract(vUv+texel*nw));
    \\    vec4 u_sw = texture(uCh0, fract(vUv+texel*sw));
    \\    vec4 u_ne = texture(uCh0, fract(vUv+texel*ne));
    \\    vec4 u_se = texture(uCh0, fract(vUv+texel*se));
    \\    
    \\    const float vx = 0.5;
    \\    const float vy = SQRT_3_OVER_2;
    \\    const float hx = SQRT_3_OVER_2;
    \\    const float hy = 0.5;
    \\
    \\    float di_n  = nl(distance(u_n.xy + n, u.xy));
    \\    float di_w  = nl(distance(u_w.xy + w, u.xy));
    \\    float di_e  = nl(distance(u_e.xy + e, u.xy));
    \\    float di_s  = nl(distance(u_s.xy + s, u.xy));
    \\    
    \\    float di_nne = nl(distance((diagV(u.xy, u_n.xy, u_e.xy, u_ne.xy) + vec2(+ vx, + vy)), u.xy));
    \\    float di_ene = nl(distance((diagH(u.xy, u_n.xy, u_e.xy, u_ne.xy) + vec2(+ hx, + hy)), u.xy));
    \\    float di_ese = nl(distance((diagH(u.xy, u_s.xy, u_e.xy, u_se.xy) + vec2(+ hx, - hy)), u.xy));
    \\    float di_sse = nl(distance((diagV(u.xy, u_s.xy, u_e.xy, u_se.xy) + vec2(+ vx, - vy)), u.xy));    
    \\    float di_ssw = nl(distance((diagV(u.xy, u_s.xy, u_w.xy, u_sw.xy) + vec2(- vx, - vy)), u.xy));
    \\    float di_wsw = nl(distance((diagH(u.xy, u_s.xy, u_w.xy, u_sw.xy) + vec2(- hx, - hy)), u.xy));
    \\    float di_wnw = nl(distance((diagH(u.xy, u_n.xy, u_w.xy, u_nw.xy) + vec2(- hx, + hy)), u.xy));
    \\    float di_nnw = nl(distance((diagV(u.xy, u_n.xy, u_w.xy, u_nw.xy) + vec2(- vx, + vy)), u.xy));
    \\
    \\    vec2 xy_n  = u_n.xy + n - u.xy;
    \\    vec2 xy_w  = u_w.xy + w - u.xy;
    \\    vec2 xy_e  = u_e.xy + e - u.xy;
    \\    vec2 xy_s  = u_s.xy + s - u.xy;
    \\    
    \\    vec2 xy_nne = (diagV(u.xy, u_n.xy, u_e.xy, u_ne.xy) + vec2(+ vx, + vy)) - u.xy;
    \\    vec2 xy_ene = (diagH(u.xy, u_n.xy, u_e.xy, u_ne.xy) + vec2(+ hx, + hy)) - u.xy;
    \\    vec2 xy_ese = (diagH(u.xy, u_s.xy, u_e.xy, u_se.xy) + vec2(+ hx, - hy)) - u.xy;
    \\    vec2 xy_sse = (diagV(u.xy, u_s.xy, u_e.xy, u_se.xy) + vec2(+ vx, - vy)) - u.xy;
    \\    vec2 xy_ssw = (diagV(u.xy, u_s.xy, u_w.xy, u_sw.xy) + vec2(- vx, - vy)) - u.xy;
    \\    vec2 xy_wsw = (diagH(u.xy, u_s.xy, u_w.xy, u_sw.xy) + vec2(- hx, - hy)) - u.xy;
    \\    vec2 xy_wnw = (diagH(u.xy, u_n.xy, u_w.xy, u_nw.xy) + vec2(- hx, + hy)) - u.xy;
    \\    vec2 xy_nnw = (diagV(u.xy, u_n.xy, u_w.xy, u_nw.xy) + vec2(- vx, + vy)) - u.xy;
    \\
    \\    vec2 ma = di_nne * xy_nne + di_ene * xy_ene + di_ese * xy_ese + di_sse * xy_sse + di_ssw * xy_ssw + di_wsw * xy_wsw + di_wnw * xy_wnw + di_nnw * xy_nnw + di_n * xy_n + di_w * xy_w + di_e * xy_e + di_s * xy_s;
    \\
    \\    vec4 u_blur = gaussian(u, u_nw, u_n, u_ne, u_w, u_e, u_sw, u_s, u_se);
    \\    
    \\    vec4 au = advect(u.xy, vUv, texel);
    \\    vec4 av = advect(u.zw, vUv, texel);
    \\    
    \\    vec2 dv = av.zw + TIMESTEP * ma;
    \\    vec2 du = au.xy + TIMESTEP * dv;
    \\
    \\    if (iMouse.z > 0.0) {
    \\        vec2 d = fragCoord.xy - iMouse.xy;
    \\        float m = exp(-length(d) / 50.0);
    \\        du += 0.2 * m * normz(d);
    \\    }
    \\    
    \\    vec2 init = texture(uCh1, vUv, 4.0).xy;
    \\    // initialize with noise
    \\    if((length(u) < 0.001 && length(init) > 0.001) || reset()) {
    \\        fragColor = 8.0 * (vec4(-0.5) + vec4(init.xy, init.xy));
    \\    } else {
    \\        du = length(du) > 1.0 ? normz(du) : du;
    \\        fragColor = vec4(du, dv);
    \\    }
    \\    
    \\
    \\}
    \\
    \\out vec4 hg_fragColor;
    \\void main() {
    \\    mainImage(hg_fragColor, gl_FragCoord.xy);
    \\    hg_fragColor.xy = hgObstacle(hg_fragColor.xy, gl_FragCoord.xy);
    \\    hg_fragColor.zw = hgObstacle(hg_fragColor.zw, gl_FragCoord.xy);
    \\}
;

pub const pass_b: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec3 iResolution;
    \\uniform float iTime;
    \\uniform int iFrame;
    \\uniform vec4 iMouse;
    \\uniform sampler2D uCh0;
    \\uniform sampler2D uCh1;
    \\uniform sampler2D uCh2;
    \\uniform sampler2D uCh3;
    \\uniform vec3 uRes0;
    \\uniform vec3 uRes1;
    \\uniform vec3 iPalette[16];
    \\uniform int iPaletteSize;
    \\uniform vec3 iPaletteBg;
    \\uniform vec3 iPaletteFg;
    \\
    \\
    \\#define pi acos(-1.)
    \\
    \\#define Margins .0
    \\
    \\#define sint(a) (asin(sin(a))*2. - 1.)
    \\
    \\#define rot(a) mat2(cos(a),-sin(a),sin(a),cos(a))
    \\
    \\#define pmod(p,d) mod(p - (d)*0.5, (d)) - 0.5*(d)
    \\
    \\float r11(float i){ return fract(sin(i*12.126)*12.6);}
    \\
    \\//#define xor(a,b,c) min(max((a),-(b)), max((b),-(a) - c)) 
    \\
    \\float ss( float c, float power, float bias){
    \\    c = clamp(c,-0.,1.);
    \\    //c = smoothstep(0.,1.,c);
    \\    
    \\    c = pow(c,1. + bias);
    \\    
    \\    float a = pow( abs(c), power);
    \\    float b = 1.-pow( abs(c - 1.), power);
    \\    
    \\    return mix(a,b,c);
    \\}
    \\float valueNoise(float i, float p){ return mix(r11(floor(i)),r11(floor(i) + 1.), ss(fract(i), p,0.6));}
    \\
    \\float valueNoiseStepped(float i, float p, float steps){ return mix(  floor(r11(floor(i))*steps)/steps, floor(r11(floor(i) + 1.)*steps)/steps, ss(fract(i), p,0.6));}
    \\
    \\
    \\// See: https://www.shadertoy.com/view/ls2Bz1
    \\// Spectral Colour Schemes
    \\// By Alan Zucconi
    \\// Website: www.alanzucconi.com
    \\// Twitter: @AlanZucconi
    \\
    \\// Example of different spectral colour schemes
    \\// to convert visible wavelengths of light (400-700 nm) to RGB colours.
    \\
    \\// The function "spectral_zucconi6" provides the best approximation
    \\// without including any branching.
    \\// Its faster version, "spectral_zucconi", is advised for mobile applications.
    \\
    \\
    \\// Read "Improving the Rainbow" for more information
    \\// http://www.alanzucconi.com/?p=6703
    \\
    \\
    \\
    \\float saturate (float x)
    \\{
    \\    return min(1.0, max(0.0,x));
    \\}
    \\vec3 saturate (vec3 x)
    \\{
    \\    return min(vec3(1.,1.,1.), max(vec3(0.,0.,0.),x));
    \\}
    \\
    \\// --- Spectral Zucconi --------------------------------------------
    \\// By Alan Zucconi
    \\// Based on GPU Gems: https://developer.nvidia.com/sites/all/modules/custom/gpugems/books/GPUGems/gpugems_ch08.html
    \\// But with values optimised to match as close as possible the visible spectrum
    \\// Fits this: https://commons.wikimedia.org/wiki/File:Linear_visible_spectrum.svg
    \\// With weighter MSE (RGB weights: 0.3, 0.59, 0.11)
    \\vec3 bump3y (vec3 x, vec3 yoffset)
    \\{
    \\    vec3 y = vec3(1.,1.,1.) - x * x;
    \\    y = saturate(y-yoffset);
    \\    return y;
    \\}
    \\
    \\// --- Spectral Zucconi 6 --------------------------------------------
    \\
    \\// Based on GPU Gems
    \\// Optimised by Alan Zucconi
    \\vec3 spectral_zucconi6 (float x)
    \\{
    \\    // w: [400, 700]
    \\    // x: [0,   1]
    \\
    \\    const vec3 c1 = vec3(3.54585104, 2.93225262, 2.41593945);
    \\    const vec3 x1 = vec3(0.69549072, 0.49228336, 0.27699880);
    \\    const vec3 y1 = vec3(0.02312639, 0.15225084, 0.52607955);
    \\
    \\    const vec3 c2 = vec3(3.90307140, 3.21182957, 3.96587128);
    \\    const vec3 x2 = vec3(0.11748627, 0.86755042, 0.66077860);
    \\    const vec3 y2 = vec3(0.84897130, 0.88445281, 0.73949448);
    \\
    \\    return
    \\        bump3y(c1 * (x - x1), y1) +
    \\        bump3y(c2 * (x - x2), y2) ;
    \\}
    \\
    \\// --- MATLAB Jet Colour Scheme ----------------------------------------
    \\vec3 spectral_jet(float w)
    \\{
    \\    // w: [400, 700]
    \\    // x: [0,   1]
    \\    float x = saturate((w - 400.0)/ 300.0);
    \\    vec3 c;
    \\
    \\    if (x < 0.25)
    \\        c = vec3(0.0, 4.0 * x, 1.0);
    \\    else if (x < 0.5)
    \\        c = vec3(0.0, 1.0, 1.0 + 4.0 * (0.25 - x));
    \\    else if (x < 0.75)
    \\        c = vec3(4.0 * (x - 0.5), 1.0, 0.0);
    \\    else
    \\        c = vec3(1.0, 1.0 + 4.0 * (0.75 - x), 0.0);
    \\
    \\    // Clamp colour components in [0,1]
    \\    return saturate(c);
    \\}
    \\
    \\
    \\// ---- window rigid bodies: the flow cannot cross a window ----------------
    \\uniform int uWinCount;
    \\uniform vec4 uWin[32];     // xy = lo, zw = size   (buffer px)
    \\uniform vec2 uWinVel[32];  // body velocity        (buffer px / s)
    \\uniform float uWinScale;   // px/s that maps to a field value of 1
    \\uniform float uWinBand;    // boundary-layer thickness (buffer px)
    \\uniform float uWinCorner;  // rounded corner radius  (buffer px)
    \\uniform float uWinNoSlip;  // 0..1, how hard the wall drags the flow
    \\uniform float uWinPush;    // 0..1, how hard the body damps its interior flow
    \\uniform float uWinTurn;    // 0..1, inflow bent into an edge-parallel slide
    \\uniform float uWinCurl;    // extra swirl added to the slide
    \\uniform float uWinWall;    // 0..1, push ahead of a moving window's bounds
    \\
    \\float hgSdBox(vec2 p, vec2 lo, vec2 hi, float r) {
    \\    vec2 c = (lo + hi) * 0.5;
    \\    vec2 h = max((hi - lo) * 0.5 - vec2(r), vec2(0.0));
    \\    vec2 q = abs(p - c) - h;
    \\    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    \\}
    \\
    \\vec2 hgBoxNormal(vec2 p, vec2 lo, vec2 hi, float r) {
    \\    vec2 c = (lo + hi) * 0.5;
    \\    vec2 h = max((hi - lo) * 0.5 - vec2(r), vec2(0.0));
    \\    vec2 q = abs(p - c) - h;
    \\    if (max(q.x, q.y) > 0.0)
    \\        return normalize(max(q, vec2(0.0)) * sign(p - c));
    \\    return (q.x > q.y)
    \\        ? vec2(sign(p.x - c.x), 0.0)
    \\        : vec2(0.0, sign(p.y - c.y));
    \\}
    \\
    \\vec2 hgObstacle(vec2 v, vec2 px) {
    \\    for (int i = 0; i < uWinCount; i++) {
    \\        vec4 w = uWin[i];
    \\        if (w.z < 1.0 || w.w < 1.0) continue;
    \\        vec2 lo = w.xy;
    \\        vec2 hi = w.xy + w.zw;
    \\        float r = min(uWinCorner, min(w.z, w.w) * 0.5);
    \\        float sd = hgSdBox(px, lo, hi, r);
    \\        // The body only exists at its surface and inside it. Without this
    \\        // gate the outward normal reaches across the whole screen and drags
    \\        // every flow toward the window.
    \\        if (sd > uWinBand) continue;
    \\
    \\        vec2 nrm = hgBoxNormal(px, lo, hi, r);
    \\        float t = clamp(1.0 - sd / max(uWinBand, 1.0), 0.0, 1.0);
    \\
    \\        vec2 body = uWinVel[i] / max(uWinScale, 1.0);
    \\        body = length(body) > 1.0 ? normalize(body) : body;
    \\        vec2 rel = v - body;
    \\
    \\        // Inflow that would cross the wall, captured before it is removed.
    \\        float vn = dot(rel, nrm);
    \\        float inflow = -min(vn, 0.0);
    \\
    \\        // No penetration: drop the inward normal component (this is the
    \\        // magnet-fix projection, kept as the base).
    \\        rel -= nrm * min(vn, 0.0);
    \\
    \\        if (sd < 0.0) {
    \\            // Nothing may live under the window. Damp the whole field from
    \\            // the edge inward, so the interior settles to no flow instead of
    \\            // keeping a window-shaped imprint that leaks out as a trail.
    \\            float inside = clamp(-sd / max(uWinBand, 1.0), 0.0, 1.0);
    \\            rel *= 1.0 - clamp(uWinPush, 0.0, 1.0) * inside;
    \\        } else {
    \\            // Surface: bend the removed inflow along the edge and add a swirl
    \\            // so a head-on stream rolls around the body instead of piling up.
    \\            vec2 tang = rel - nrm * dot(rel, nrm);
    \\            float tl = length(tang);
    \\            vec2 tdir = tl > 1e-5 ? tang / tl : vec2(-nrm.y, nrm.x);
    \\            rel += tdir * inflow * uWinTurn;
    \\            rel += vec2(-nrm.y, nrm.x) * (uWinCurl * t * inflow);
    \\            // Push relative to the bounds: project the window's own motion on
    \\            // the outward normal, so the leading edge shoves flow ahead of it.
    \\            float wall = max(dot(body, nrm), 0.0);
    \\            rel += nrm * wall * uWinWall * t;
    \\        }
    \\
    \\        rel *= 1.0 - uWinNoSlip * t;                   // optional no-slip
    \\        v = body + rel;
    \\    }
    \\    return v;
    \\}
    \\
    \\/*
    \\    A fluid-like dynamical system
    \\    see: https://www.shadertoy.com/view/XddSRX
    \\*/
    \\
    \\vec2 normz(vec2 x) {
    \\    return x == vec2(0.0, 0.0) ? vec2(0.0, 0.0) : normalize(x);
    \\}
    \\
    \\// reverse advection
    \\vec4 advect(vec2 ab, vec2 vUv, vec2 step, float sc) {
    \\    
    \\    vec2 aUv = vUv - ab * sc * step;
    \\    
    \\    const float _G0 = 0.25; // center weight
    \\    const float _G1 = 0.125; // edge-neighbors
    \\    const float _G2 = 0.0625; // vertex-neighbors
    \\    
    \\    // 3x3 neighborhood coordinates
    \\    float step_x = step.x;
    \\    float step_y = step.y;
    \\    vec2 n  = vec2(0.0, step_y);
    \\    vec2 ne = vec2(step_x, step_y);
    \\    vec2 e  = vec2(step_x, 0.0);
    \\    vec2 se = vec2(step_x, -step_y);
    \\    vec2 s  = vec2(0.0, -step_y);
    \\    vec2 sw = vec2(-step_x, -step_y);
    \\    vec2 w  = vec2(-step_x, 0.0);
    \\    vec2 nw = vec2(-step_x, step_y);
    \\
    \\    vec4 uv =    texture(uCh0, fract(aUv));
    \\    vec4 uv_n =  texture(uCh0, fract(aUv+n));
    \\    vec4 uv_e =  texture(uCh0, fract(aUv+e));
    \\    vec4 uv_s =  texture(uCh0, fract(aUv+s));
    \\    vec4 uv_w =  texture(uCh0, fract(aUv+w));
    \\    vec4 uv_nw = texture(uCh0, fract(aUv+nw));
    \\    vec4 uv_sw = texture(uCh0, fract(aUv+sw));
    \\    vec4 uv_ne = texture(uCh0, fract(aUv+ne));
    \\    vec4 uv_se = texture(uCh0, fract(aUv+se));
    \\    
    \\    return _G0*uv + _G1*(uv_n + uv_e + uv_w + uv_s) + _G2*(uv_nw + uv_sw + uv_ne + uv_se);
    \\}
    \\
    \\void mainImage( out vec4 fragColor, in vec2 fragCoord )
    \\{
    \\    const float _K0 = -20.0/6.0; // center weight
    \\    const float _K1 = 4.0/6.0;   // edge-neighbors
    \\    const float _K2 = 1.0/6.0;   // vertex-neighbors
    \\    const float cs = -3.0;  // curl scale
    \\    const float ls = 3.0;  // laplacian scale
    \\    const float ps = 0.0;  // laplacian of divergence scale
    \\    const float ds = -12.0; // divergence scale
    \\    const float dp = -6.0; // divergence update scale
    \\    const float pl = 0.3;   // divergence smoothing
    \\    const float ad = 0.45;   // advection distance scale
    \\    const float pwr = 1.0;  // power when deriving rotation angle from curl
    \\    const float amp = 1.0;  // self-amplification
    \\    const float upd = 0.9997;  // update smoothing
    \\    const float sq2 = 0.6;  // diagonal weight
    \\    
    \\    vec2 vUv = fragCoord.xy / iResolution.xy;
    \\    vec2 texel = 1. / iResolution.xy;
    \\    
    \\    // 3x3 neighborhood coordinates
    \\    float step_x = texel.x;
    \\    float step_y = texel.y;
    \\    vec2 n  = vec2(0.0, step_y);
    \\    vec2 ne = vec2(step_x, step_y);
    \\    vec2 e  = vec2(step_x, 0.0);
    \\    vec2 se = vec2(step_x, -step_y);
    \\    vec2 s  = vec2(0.0, -step_y);
    \\    vec2 sw = vec2(-step_x, -step_y);
    \\    vec2 w  = vec2(-step_x, 0.0);
    \\    vec2 nw = vec2(-step_x, step_y);
    \\
    \\    vec4 uv =    texture(uCh0, fract(vUv));
    \\    vec4 uv_n =  texture(uCh0, fract(vUv+n));
    \\    vec4 uv_e =  texture(uCh0, fract(vUv+e));
    \\    vec4 uv_s =  texture(uCh0, fract(vUv+s));
    \\    vec4 uv_w =  texture(uCh0, fract(vUv+w));
    \\    vec4 uv_nw = texture(uCh0, fract(vUv+nw));
    \\    vec4 uv_sw = texture(uCh0, fract(vUv+sw));
    \\    vec4 uv_ne = texture(uCh0, fract(vUv+ne));
    \\    vec4 uv_se = texture(uCh0, fract(vUv+se));
    \\    
    \\    // uv.x and uv.y are the x and y components, uv.z and uv.w accumulate divergence 
    \\
    \\    // laplacian of all components
    \\    vec4 lapl  = _K0*uv + _K1*(uv_n + uv_e + uv_w + uv_s) + _K2*(uv_nw + uv_sw + uv_ne + uv_se);
    \\    
    \\    // calculate curl
    \\    // vectors point clockwise about the center point
    \\    float curl = uv_n.x - uv_s.x - uv_e.y + uv_w.y + sq2 * (uv_nw.x + uv_nw.y + uv_ne.x - uv_ne.y + uv_sw.y - uv_sw.x - uv_se.y - uv_se.x);
    \\    
    \\    // compute angle of rotation from curl
    \\    float sc = cs * sign(curl) * pow(abs(curl), pwr);
    \\    
    \\    // calculate divergence
    \\    // vectors point inwards towards the center point
    \\    float div  = uv_s.y - uv_n.y - uv_e.x + uv_w.x + sq2 * (uv_nw.x - uv_nw.y - uv_ne.x - uv_ne.y + uv_sw.x + uv_sw.y + uv_se.y - uv_se.x);
    \\    
    \\    vec2 norm = normz(uv.xy);
    \\    
    \\    float sdx = uv.z + dp * uv.x * div + pl * lapl.z;
    \\    float sdy = uv.w + dp * uv.y * div + pl * lapl.w;
    \\
    \\    vec2 ab = advect(vec2(uv.x, uv.y), vUv, texel, ad).xy;
    \\    
    \\    // temp values for the update rule
    \\    float ta = amp * ab.x + ls * lapl.x + norm.x * ps * lapl.z + ds * sdx;
    \\    float tb = amp * ab.y + ls * lapl.y + norm.y * ps * lapl.w + ds * sdy;
    \\
    \\    // rotate
    \\    float a = ta * cos(sc) - tb * sin(sc);
    \\    float b = ta * sin(sc) + tb * cos(sc);
    \\    
    \\    vec4 abd = upd * uv + (1.0 - upd) * vec4(a,b,sdx,sdy);
    \\    
    \\    fragColor = vec4(abd);
    \\    
    \\    abd.xy = clamp(length(abd.xy) > 1.0 ? normz(abd.xy) : abd.xy, -1.0, 1.0);
    \\    fragColor = vec4(abd);
    \\    
    \\}
    \\
    \\out vec4 hg_fragColor;
    \\void main() {
    \\    mainImage(hg_fragColor, gl_FragCoord.xy);
    \\    hg_fragColor.xy = hgObstacle(hg_fragColor.xy, gl_FragCoord.xy);
    \\}
;

pub const pass_c: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec3 iResolution;
    \\uniform float iTime;
    \\uniform int iFrame;
    \\uniform vec4 iMouse;
    \\uniform sampler2D uCh0;
    \\uniform sampler2D uCh1;
    \\uniform sampler2D uCh2;
    \\uniform sampler2D uCh3;
    \\uniform vec3 uRes0;
    \\uniform vec3 uRes1;
    \\uniform vec3 iPalette[16];
    \\uniform int iPaletteSize;
    \\uniform vec3 iPaletteBg;
    \\uniform vec3 iPaletteFg;
    \\
    \\
    \\#define pi acos(-1.)
    \\
    \\#define Margins .0
    \\
    \\#define sint(a) (asin(sin(a))*2. - 1.)
    \\
    \\#define rot(a) mat2(cos(a),-sin(a),sin(a),cos(a))
    \\
    \\#define pmod(p,d) mod(p - (d)*0.5, (d)) - 0.5*(d)
    \\
    \\float r11(float i){ return fract(sin(i*12.126)*12.6);}
    \\
    \\//#define xor(a,b,c) min(max((a),-(b)), max((b),-(a) - c)) 
    \\
    \\float ss( float c, float power, float bias){
    \\    c = clamp(c,-0.,1.);
    \\    //c = smoothstep(0.,1.,c);
    \\    
    \\    c = pow(c,1. + bias);
    \\    
    \\    float a = pow( abs(c), power);
    \\    float b = 1.-pow( abs(c - 1.), power);
    \\    
    \\    return mix(a,b,c);
    \\}
    \\float valueNoise(float i, float p){ return mix(r11(floor(i)),r11(floor(i) + 1.), ss(fract(i), p,0.6));}
    \\
    \\float valueNoiseStepped(float i, float p, float steps){ return mix(  floor(r11(floor(i))*steps)/steps, floor(r11(floor(i) + 1.)*steps)/steps, ss(fract(i), p,0.6));}
    \\
    \\
    \\// See: https://www.shadertoy.com/view/ls2Bz1
    \\// Spectral Colour Schemes
    \\// By Alan Zucconi
    \\// Website: www.alanzucconi.com
    \\// Twitter: @AlanZucconi
    \\
    \\// Example of different spectral colour schemes
    \\// to convert visible wavelengths of light (400-700 nm) to RGB colours.
    \\
    \\// The function "spectral_zucconi6" provides the best approximation
    \\// without including any branching.
    \\// Its faster version, "spectral_zucconi", is advised for mobile applications.
    \\
    \\
    \\// Read "Improving the Rainbow" for more information
    \\// http://www.alanzucconi.com/?p=6703
    \\
    \\
    \\
    \\float saturate (float x)
    \\{
    \\    return min(1.0, max(0.0,x));
    \\}
    \\vec3 saturate (vec3 x)
    \\{
    \\    return min(vec3(1.,1.,1.), max(vec3(0.,0.,0.),x));
    \\}
    \\
    \\// --- Spectral Zucconi --------------------------------------------
    \\// By Alan Zucconi
    \\// Based on GPU Gems: https://developer.nvidia.com/sites/all/modules/custom/gpugems/books/GPUGems/gpugems_ch08.html
    \\// But with values optimised to match as close as possible the visible spectrum
    \\// Fits this: https://commons.wikimedia.org/wiki/File:Linear_visible_spectrum.svg
    \\// With weighter MSE (RGB weights: 0.3, 0.59, 0.11)
    \\vec3 bump3y (vec3 x, vec3 yoffset)
    \\{
    \\    vec3 y = vec3(1.,1.,1.) - x * x;
    \\    y = saturate(y-yoffset);
    \\    return y;
    \\}
    \\
    \\// --- Spectral Zucconi 6 --------------------------------------------
    \\
    \\// Based on GPU Gems
    \\// Optimised by Alan Zucconi
    \\vec3 spectral_zucconi6 (float x)
    \\{
    \\    // w: [400, 700]
    \\    // x: [0,   1]
    \\
    \\    const vec3 c1 = vec3(3.54585104, 2.93225262, 2.41593945);
    \\    const vec3 x1 = vec3(0.69549072, 0.49228336, 0.27699880);
    \\    const vec3 y1 = vec3(0.02312639, 0.15225084, 0.52607955);
    \\
    \\    const vec3 c2 = vec3(3.90307140, 3.21182957, 3.96587128);
    \\    const vec3 x2 = vec3(0.11748627, 0.86755042, 0.66077860);
    \\    const vec3 y2 = vec3(0.84897130, 0.88445281, 0.73949448);
    \\
    \\    return
    \\        bump3y(c1 * (x - x1), y1) +
    \\        bump3y(c2 * (x - x2), y2) ;
    \\}
    \\
    \\// --- MATLAB Jet Colour Scheme ----------------------------------------
    \\vec3 spectral_jet(float w)
    \\{
    \\    // w: [400, 700]
    \\    // x: [0,   1]
    \\    float x = saturate((w - 400.0)/ 300.0);
    \\    vec3 c;
    \\
    \\    if (x < 0.25)
    \\        c = vec3(0.0, 4.0 * x, 1.0);
    \\    else if (x < 0.5)
    \\        c = vec3(0.0, 1.0, 1.0 + 4.0 * (0.25 - x));
    \\    else if (x < 0.75)
    \\        c = vec3(4.0 * (x - 0.5), 1.0, 0.0);
    \\    else
    \\        c = vec3(1.0, 1.0 + 4.0 * (0.75 - x), 0.0);
    \\
    \\    // Clamp colour components in [0,1]
    \\    return saturate(c);
    \\}
    \\
    \\
    \\// ---- window rigid bodies: the flow cannot cross a window ----------------
    \\uniform int uWinCount;
    \\uniform vec4 uWin[32];     // xy = lo, zw = size   (buffer px)
    \\uniform vec2 uWinVel[32];  // body velocity        (buffer px / s)
    \\uniform float uWinScale;   // px/s that maps to a field value of 1
    \\uniform float uWinBand;    // boundary-layer thickness (buffer px)
    \\uniform float uWinCorner;  // rounded corner radius  (buffer px)
    \\uniform float uWinNoSlip;  // 0..1, how hard the wall drags the flow
    \\uniform float uWinPush;    // 0..1, how hard the body damps its interior flow
    \\uniform float uWinTurn;    // 0..1, inflow bent into an edge-parallel slide
    \\uniform float uWinCurl;    // extra swirl added to the slide
    \\uniform float uWinWall;    // 0..1, push ahead of a moving window's bounds
    \\
    \\float hgSdBox(vec2 p, vec2 lo, vec2 hi, float r) {
    \\    vec2 c = (lo + hi) * 0.5;
    \\    vec2 h = max((hi - lo) * 0.5 - vec2(r), vec2(0.0));
    \\    vec2 q = abs(p - c) - h;
    \\    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    \\}
    \\
    \\vec2 hgBoxNormal(vec2 p, vec2 lo, vec2 hi, float r) {
    \\    vec2 c = (lo + hi) * 0.5;
    \\    vec2 h = max((hi - lo) * 0.5 - vec2(r), vec2(0.0));
    \\    vec2 q = abs(p - c) - h;
    \\    if (max(q.x, q.y) > 0.0)
    \\        return normalize(max(q, vec2(0.0)) * sign(p - c));
    \\    return (q.x > q.y)
    \\        ? vec2(sign(p.x - c.x), 0.0)
    \\        : vec2(0.0, sign(p.y - c.y));
    \\}
    \\
    \\vec2 hgObstacle(vec2 v, vec2 px) {
    \\    for (int i = 0; i < uWinCount; i++) {
    \\        vec4 w = uWin[i];
    \\        if (w.z < 1.0 || w.w < 1.0) continue;
    \\        vec2 lo = w.xy;
    \\        vec2 hi = w.xy + w.zw;
    \\        float r = min(uWinCorner, min(w.z, w.w) * 0.5);
    \\        float sd = hgSdBox(px, lo, hi, r);
    \\        // The body only exists at its surface and inside it. Without this
    \\        // gate the outward normal reaches across the whole screen and drags
    \\        // every flow toward the window.
    \\        if (sd > uWinBand) continue;
    \\
    \\        vec2 nrm = hgBoxNormal(px, lo, hi, r);
    \\        float t = clamp(1.0 - sd / max(uWinBand, 1.0), 0.0, 1.0);
    \\
    \\        vec2 body = uWinVel[i] / max(uWinScale, 1.0);
    \\        body = length(body) > 1.0 ? normalize(body) : body;
    \\        vec2 rel = v - body;
    \\
    \\        // Inflow that would cross the wall, captured before it is removed.
    \\        float vn = dot(rel, nrm);
    \\        float inflow = -min(vn, 0.0);
    \\
    \\        // No penetration: drop the inward normal component (this is the
    \\        // magnet-fix projection, kept as the base).
    \\        rel -= nrm * min(vn, 0.0);
    \\
    \\        if (sd < 0.0) {
    \\            // Nothing may live under the window. Damp the whole field from
    \\            // the edge inward, so the interior settles to no flow instead of
    \\            // keeping a window-shaped imprint that leaks out as a trail.
    \\            float inside = clamp(-sd / max(uWinBand, 1.0), 0.0, 1.0);
    \\            rel *= 1.0 - clamp(uWinPush, 0.0, 1.0) * inside;
    \\        } else {
    \\            // Surface: bend the removed inflow along the edge and add a swirl
    \\            // so a head-on stream rolls around the body instead of piling up.
    \\            vec2 tang = rel - nrm * dot(rel, nrm);
    \\            float tl = length(tang);
    \\            vec2 tdir = tl > 1e-5 ? tang / tl : vec2(-nrm.y, nrm.x);
    \\            rel += tdir * inflow * uWinTurn;
    \\            rel += vec2(-nrm.y, nrm.x) * (uWinCurl * t * inflow);
    \\            // Push relative to the bounds: project the window's own motion on
    \\            // the outward normal, so the leading edge shoves flow ahead of it.
    \\            float wall = max(dot(body, nrm), 0.0);
    \\            rel += nrm * wall * uWinWall * t;
    \\        }
    \\
    \\        rel *= 1.0 - uWinNoSlip * t;                   // optional no-slip
    \\        v = body + rel;
    \\    }
    \\    return v;
    \\}
    \\
    \\// created by florian berger (flockaroo) - 2016
    \\// License Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported License.
    \\
    \\// single pass CFD
    \\// ---------------
    \\// this is some "computational flockarooid dynamics" ;)
    \\// the self-advection is done purely rotational on all scales. 
    \\// therefore i dont need any divergence-free velocity field. 
    \\// with stochastic sampling i get the proper "mean values" of rotations 
    \\// over time for higher order scales.
    \\//
    \\// try changing "RotNum" for different accuracies of rotation calculation
    \\// for even RotNum uncomment the line #define SUPPORT_EVEN_ROTNUM
    \\
    \\#define RotNum 5
    \\//#define SUPPORT_EVEN_ROTNUM
    \\
    \\#define Res  uRes0
    \\#define Res1 uRes1
    \\
    \\//#define keyTex uCh3
    \\//#define KEY_I texture(keyTex,vec2((105.5-32.0)/256.0,(0.5+0.0)/3.0)).x
    \\
    \\const float ang = 2.0*3.1415926535/float(RotNum);
    \\mat2 m = mat2(cos(ang),sin(ang),-sin(ang),cos(ang));
    \\mat2 mh = mat2(cos(ang*0.5),sin(ang*0.5),-sin(ang*0.5),cos(ang*0.5));
    \\
    \\vec4 randS(vec2 uv)
    \\{
    \\    return texture(uCh1,uv*Res.xy/Res1.xy)-vec4(0.5);
    \\}
    \\
    \\float getRot(vec2 pos, vec2 b)
    \\{
    \\    vec2 p = b;
    \\    float rot=0.0;
    \\    for(int i=0;i<RotNum;i++)
    \\    {
    \\        rot+=dot(texture(uCh0,fract((pos+p)/Res.xy)).xy-vec2(0.5),p.yx*vec2(1,-1));
    \\        p = m*p;
    \\    }
    \\    return rot/float(RotNum)/dot(b,b);
    \\}
    \\
    \\void mainImage( out vec4 fragColor, in vec2 fragCoord )
    \\{
    \\    vec2 pos = fragCoord.xy;
    \\    float rnd = randS(vec2(float(iFrame)/Res.x,0.5/Res1.y)).x;
    \\    
    \\    vec2 b = vec2(cos(ang*rnd),sin(ang*rnd));
    \\    vec2 v=vec2(0);
    \\    float bbMax=0.7*Res.y; bbMax*=bbMax;
    \\    for(int l=0;l<20;l++)
    \\    {
    \\        if ( dot(b,b) > bbMax ) break;
    \\        vec2 p = b;
    \\        for(int i=0;i<RotNum;i++)
    \\        {
    \\#ifdef SUPPORT_EVEN_ROTNUM
    \\            v+=p.yx*getRot(pos+p,-mh*b);
    \\#else
    \\            // this is faster but works only for odd RotNum
    \\            v+=p.yx*getRot(pos+p,b);
    \\#endif
    \\            p = m*p;
    \\        }
    \\        b*=2.0;
    \\    }
    \\    
    \\     vec2 uv = fragCoord/iResolution.xy; // Normalized pixel coordinates (from 0 to 1)
    \\
    \\  vec4 col = texture(uCh0,fract((pos+v*vec2(-1,1)*0.12)/Res.xy));
    \\  vec4 col2 = texture(uCh3,fract((pos+v*vec2(-1,1)*0.12)/Res.xy));
    \\  vec4 blend = mix(col,col2,(0.25) );
    \\  
    \\  fragColor=blend;
    \\  //  fragColor=texture(uCh0,fract((pos+v*vec2(-1,1)*0.12)/Res.xy));
    \\    
    \\    // add a little "motor" in the center
    \\    vec2 scr=(fragCoord.xy/Res.xy)*2.0-vec2(1.0);
    \\    fragColor.xy += (0.001*scr.xy / (dot(scr,scr)/0.1+0.3));
    \\    
    \\ //   if(iFrame<=4 || KEY_I>0.5) fragColor=texture(uCh2,fragCoord.xy/Res.xy);
    \\}
    \\
    \\out vec4 hg_fragColor;
    \\void main() {
    \\    mainImage(hg_fragColor, gl_FragCoord.xy);
    \\    hg_fragColor.xy = hgObstacle(hg_fragColor.xy, gl_FragCoord.xy);
    \\}
;

pub const pass_d: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec3 iResolution;
    \\uniform float iTime;
    \\uniform int iFrame;
    \\uniform vec4 iMouse;
    \\uniform sampler2D uCh0;
    \\uniform sampler2D uCh1;
    \\uniform sampler2D uCh2;
    \\uniform sampler2D uCh3;
    \\uniform vec3 uRes0;
    \\uniform vec3 uRes1;
    \\uniform vec3 iPalette[16];
    \\uniform int iPaletteSize;
    \\uniform vec3 iPaletteBg;
    \\uniform vec3 iPaletteFg;
    \\
    \\
    \\#define pi acos(-1.)
    \\
    \\#define Margins .0
    \\
    \\#define sint(a) (asin(sin(a))*2. - 1.)
    \\
    \\#define rot(a) mat2(cos(a),-sin(a),sin(a),cos(a))
    \\
    \\#define pmod(p,d) mod(p - (d)*0.5, (d)) - 0.5*(d)
    \\
    \\float r11(float i){ return fract(sin(i*12.126)*12.6);}
    \\
    \\//#define xor(a,b,c) min(max((a),-(b)), max((b),-(a) - c)) 
    \\
    \\float ss( float c, float power, float bias){
    \\    c = clamp(c,-0.,1.);
    \\    //c = smoothstep(0.,1.,c);
    \\    
    \\    c = pow(c,1. + bias);
    \\    
    \\    float a = pow( abs(c), power);
    \\    float b = 1.-pow( abs(c - 1.), power);
    \\    
    \\    return mix(a,b,c);
    \\}
    \\float valueNoise(float i, float p){ return mix(r11(floor(i)),r11(floor(i) + 1.), ss(fract(i), p,0.6));}
    \\
    \\float valueNoiseStepped(float i, float p, float steps){ return mix(  floor(r11(floor(i))*steps)/steps, floor(r11(floor(i) + 1.)*steps)/steps, ss(fract(i), p,0.6));}
    \\
    \\
    \\// See: https://www.shadertoy.com/view/ls2Bz1
    \\// Spectral Colour Schemes
    \\// By Alan Zucconi
    \\// Website: www.alanzucconi.com
    \\// Twitter: @AlanZucconi
    \\
    \\// Example of different spectral colour schemes
    \\// to convert visible wavelengths of light (400-700 nm) to RGB colours.
    \\
    \\// The function "spectral_zucconi6" provides the best approximation
    \\// without including any branching.
    \\// Its faster version, "spectral_zucconi", is advised for mobile applications.
    \\
    \\
    \\// Read "Improving the Rainbow" for more information
    \\// http://www.alanzucconi.com/?p=6703
    \\
    \\
    \\
    \\float saturate (float x)
    \\{
    \\    return min(1.0, max(0.0,x));
    \\}
    \\vec3 saturate (vec3 x)
    \\{
    \\    return min(vec3(1.,1.,1.), max(vec3(0.,0.,0.),x));
    \\}
    \\
    \\// --- Spectral Zucconi --------------------------------------------
    \\// By Alan Zucconi
    \\// Based on GPU Gems: https://developer.nvidia.com/sites/all/modules/custom/gpugems/books/GPUGems/gpugems_ch08.html
    \\// But with values optimised to match as close as possible the visible spectrum
    \\// Fits this: https://commons.wikimedia.org/wiki/File:Linear_visible_spectrum.svg
    \\// With weighter MSE (RGB weights: 0.3, 0.59, 0.11)
    \\vec3 bump3y (vec3 x, vec3 yoffset)
    \\{
    \\    vec3 y = vec3(1.,1.,1.) - x * x;
    \\    y = saturate(y-yoffset);
    \\    return y;
    \\}
    \\
    \\// --- Spectral Zucconi 6 --------------------------------------------
    \\
    \\// Based on GPU Gems
    \\// Optimised by Alan Zucconi
    \\vec3 spectral_zucconi6 (float x)
    \\{
    \\    // w: [400, 700]
    \\    // x: [0,   1]
    \\
    \\    const vec3 c1 = vec3(3.54585104, 2.93225262, 2.41593945);
    \\    const vec3 x1 = vec3(0.69549072, 0.49228336, 0.27699880);
    \\    const vec3 y1 = vec3(0.02312639, 0.15225084, 0.52607955);
    \\
    \\    const vec3 c2 = vec3(3.90307140, 3.21182957, 3.96587128);
    \\    const vec3 x2 = vec3(0.11748627, 0.86755042, 0.66077860);
    \\    const vec3 y2 = vec3(0.84897130, 0.88445281, 0.73949448);
    \\
    \\    return
    \\        bump3y(c1 * (x - x1), y1) +
    \\        bump3y(c2 * (x - x2), y2) ;
    \\}
    \\
    \\// --- MATLAB Jet Colour Scheme ----------------------------------------
    \\vec3 spectral_jet(float w)
    \\{
    \\    // w: [400, 700]
    \\    // x: [0,   1]
    \\    float x = saturate((w - 400.0)/ 300.0);
    \\    vec3 c;
    \\
    \\    if (x < 0.25)
    \\        c = vec3(0.0, 4.0 * x, 1.0);
    \\    else if (x < 0.5)
    \\        c = vec3(0.0, 1.0, 1.0 + 4.0 * (0.25 - x));
    \\    else if (x < 0.75)
    \\        c = vec3(4.0 * (x - 0.5), 1.0, 0.0);
    \\    else
    \\        c = vec3(1.0, 1.0 + 4.0 * (0.75 - x), 0.0);
    \\
    \\    // Clamp colour components in [0,1]
    \\    return saturate(c);
    \\}
    \\
    \\
    \\                                                                                                                                                                                                                                                                                        // See Image tab for details, also visit:
    \\//
    \\// https://xemantic.github.io/shader-web-background/
    \\//
    \\// In the original shader-web-background these values are provided as uniforms
    \\// feel free to play with them and if you will find something prettier than
    \\// the equilibrium I established, please send it back to me :)
    \\const vec2  iFeedbackZoomCenter       = vec2(0., 0.);
    \\const float iFeedbackZoomRate         = .001;
    \\const float iFeedbackFadeRate         = .999;
    \\const float iFeedbackColorShiftZoom   = 0.015;
    \\const float iFeedbackColorShiftImpact = 0.002;
    \\const vec2  iDrawCenter               = vec2(0., 0.);
    \\const float iDrawIntensity            = 100.5;
    \\const float iBlobEdgeSmoothing        = .02;
    \\const float iBlob1Radius              = .69;
    \\const float iBlob1PowFactor           = 30.;
    \\const float iBlob1ColorPulseSpeed     = .024;
    \\const float iBlob2Radius              = .7;
    \\const float iBlob2PowFactor           = 20.;
    \\const float iBlob2ColorPulseSpeed     = 0.15;
    \\const float iBlob2ColorPulseShift     = 0.0;
    \\const float iColorShiftOfRadius       = .225;
    \\const float iFeedbackMouseShiftFactor = .003;
    \\
    \\/*
    \\  Normally it would be provided by texture parameters, but on Mac/iOS the texture REPEAT
    \\  seems to work only for power-of-2 texture sizes.
    \\ */
    \\vec4 repeatedTexture(in sampler2D channel, in vec2 uv) {
    \\    return texture(channel, mod(uv, 1.));
    \\}
    \\
    \\float drawBlob(
    \\    in vec2 st,
    \\    in vec2 center,
    \\    in float radius,
    \\    in float edgeSmoothing
    \\) {
    \\    float dist = length((st - center) / radius);
    \\    return dist * smoothstep(1., 1. - iBlobEdgeSmoothing, dist);
    \\}
    \\
    \\
    \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    \\    // in shader-web-background provided as uniforms: start
    \\    float iMinDimension = min(iResolution.x, iResolution.y);
    \\    vec2 iScreenRatioHalf =
    \\        (iResolution.x >= iResolution.y)
    \\            ? vec2(iResolution.y / iResolution.x * .5, .5)
    \\            : vec2(.5, iResolution.x / iResolution.y);
    \\    vec3 iBlob1Color = spectral_zucconi6(
    \\        mod(iTime * iBlob1ColorPulseSpeed, 1.)
    \\    );
    \\    
    \\    vec3 iBlob2Color = spectral_zucconi6 (
    \\        mod(iTime * iBlob2ColorPulseSpeed + iBlob2ColorPulseShift, 1.)
    \\    );
    \\    vec2 iFeedbackShiftVector =
    \\        (iMouse.x > 0. && iMouse.y > 0.)
    \\            ? (iMouse.xy * 2. - iResolution.xy) / iMinDimension * iFeedbackMouseShiftFactor
    \\            : vec2(0);
    \\    // in shader-web-background provided as uniforms: end
    \\            
    \\    
    \\    vec2 uv = fragCoord / iResolution.xy;
    \\    vec2 st = (fragCoord * 2. - iResolution.xy) / iMinDimension;
    \\
    \\    vec2  drawDelta = st - iDrawCenter;
    \\    float drawAngle = atan(drawDelta.x, drawDelta.y);
    \\    float drawDist = length(drawDelta);
    \\
    \\vec3 feedbk = repeatedTexture(uCh1, uv - st).rgb;
    \\    vec3 colorShift = repeatedTexture(
    \\        uCh0,
    \\        uv - st * iFeedbackColorShiftZoom * iScreenRatioHalf
    \\    ).rgb;
    \\
    \\    vec2 stShift = vec2(0);
    \\    stShift += iFeedbackZoomRate * (st - iFeedbackZoomCenter);
    \\    stShift += (feedbk.bg/colorShift.rb - .5) * iFeedbackColorShiftImpact  * (0.1*abs(cos(iTime*0.1231))) ;
    \\    stShift += iFeedbackShiftVector ;
    \\    stShift *= iScreenRatioHalf;
    \\
    \\    vec3 prevColor = repeatedTexture(uCh2, uv - stShift).rgb;
    \\    prevColor *= iFeedbackFadeRate;
    \\
    \\    vec3 drawColor = vec3(0);
    \\   vec3 extraColor = repeatedTexture(uCh3, uv - stShift).rgb;
    \\    extraColor *= iFeedbackFadeRate;
    \\
    \\    float radius =
    \\        1.
    \\        + (colorShift.r + colorShift.g + colorShift.b) * iColorShiftOfRadius;
    \\    drawColor +=
    \\        pow(
    \\          drawBlob(st, iDrawCenter, radius * (iBlob1Radius ) , iBlobEdgeSmoothing),
    \\          iBlob1PowFactor
    \\        ) * iBlob1Color;
    \\    drawColor +=
    \\        pow(
    \\          drawBlob(st, iDrawCenter, radius * (iBlob2Radius ), iBlobEdgeSmoothing),
    \\          iBlob2PowFactor
    \\        ) * iBlob2Color;
    \\
    \\    vec3 color = vec3(0);
    \\    drawColor *= iDrawIntensity;
    \\    prevColor *= iFeedbackFadeRate;
    \\    color += prevColor;
    \\    color += drawColor;
    \\    color *  (extraColor * extraColor);
    \\    
    \\ //    vec2 uv = fragCoord/iResolution.xy; // Normalized pixel coordinates (from 0 to 1)
    \\
    \\  vec4 col = texture(uCh2, uv);
    \\  vec4 col2 = texture(uCh3,uv);
    \\  vec4 blend = mix(col,col2,(0.8 * abs(sin(iTime / 6.9))));
    \\
    \\    color -   clamp(color, 0., 2.5 );
    \\    fragColor = blend;
    \\//    fragColor = vec4(color, 1.);
    \\}
    \\
    \\out vec4 hg_fragColor;
    \\void main() {
    \\    mainImage(hg_fragColor, gl_FragCoord.xy);
    \\}
;

pub const pass_paint: [:0]const u8 =
    \\
    \\#version 300 es
    \\precision highp float;
    \\uniform vec3 iResolution;
    \\
    \\float hgHash21(vec2 p) {
    \\    p = fract(p * vec2(123.34, 456.21));
    \\    p += dot(p, p + 45.32);
    \\    return fract(p.x * p.y);
    \\}
    \\
    \\// One layer of small, randomly placed paint islands. Each grid cell holds a
    \\// single jittered, randomly rotated ellipse; the hash makes the layout stable
    \\// between frames but different from one cell to the next. Some cells are left
    \\// empty so the stream sizes and spacing stay irregular.
    \\float hgIslands(vec2 p, float scale, float seed, float size) {
    \\    vec2 cell = p * scale + seed;
    \\    vec2 id = floor(cell);
    \\    vec2 f = fract(cell) - 0.5;
    \\
    \\    float h0 = hgHash21(id + seed * 1.7);
    \\    float h1 = hgHash21(id + seed * 3.1 + 11.0);
    \\    float h2 = hgHash21(id + seed * 5.3 + 23.0);
    \\    float h3 = hgHash21(id + seed * 7.9 + 41.0);
    \\    float h4 = hgHash21(id + seed * 9.7 + 59.0);
    \\
    \\    vec2 q = f - (vec2(h0, h1) - 0.5) * 0.55;
    \\    float a = h2 * 6.2831853;
    \\    q = mat2(cos(a), -sin(a), sin(a), cos(a)) * q;
    \\
    \\    // Slightly elongated so the island reads as a short flow, not a dot.
    \\    vec2 e = q / vec2(size * (0.7 + 0.9 * h3), size);
    \\    float d = length(e);
    \\    float b = 1.0 - smoothstep(0.35, 1.0, d);
    \\    return b * b * (0.55 + 0.45 * h3) * step(0.22, h4);
    \\}
    \\
    \\float hgPaint(vec2 uv) {
    \\    vec2 p = (uv - 0.5) * vec2(iResolution.x / max(iResolution.y, 1.0), 1.0);
    \\    float paint = 0.0;
    \\    paint = max(paint, hgIslands(p, 4.5, 0.0, 0.28));
    \\    paint = max(paint, hgIslands(p, 8.0, 3.0, 0.20));
    \\    paint = max(paint, hgIslands(p, 15.0, 7.0, 0.14));
    \\    return paint;
    \\}
    \\
    \\out vec4 hg_fragColor;
    \\void main() {
    \\    hg_fragColor = vec4(vec3(hgPaint(gl_FragCoord.xy / iResolution.xy)), 1.0);
    \\}
;
