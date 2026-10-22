#version 300 es
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


#define pi acos(-1.)

#define Margins .0

#define sint(a) (asin(sin(a))*2. - 1.)

#define rot(a) mat2(cos(a),-sin(a),sin(a),cos(a))

#define pmod(p,d) mod(p - (d)*0.5, (d)) - 0.5*(d)

float r11(float i){ return fract(sin(i*12.126)*12.6);}

//#define xor(a,b,c) min(max((a),-(b)), max((b),-(a) - c)) 

float ss( float c, float power, float bias){
    c = clamp(c,-0.,1.);
    //c = smoothstep(0.,1.,c);
    
    c = pow(c,1. + bias);
    
    float a = pow( abs(c), power);
    float b = 1.-pow( abs(c - 1.), power);
    
    return mix(a,b,c);
}
float valueNoise(float i, float p){ return mix(r11(floor(i)),r11(floor(i) + 1.), ss(fract(i), p,0.6));}

float valueNoiseStepped(float i, float p, float steps){ return mix(  floor(r11(floor(i))*steps)/steps, floor(r11(floor(i) + 1.)*steps)/steps, ss(fract(i), p,0.6));}


// See: https://www.shadertoy.com/view/ls2Bz1
// Spectral Colour Schemes
// By Alan Zucconi
// Website: www.alanzucconi.com
// Twitter: @AlanZucconi

// Example of different spectral colour schemes
// to convert visible wavelengths of light (400-700 nm) to RGB colours.

// The function "spectral_zucconi6" provides the best approximation
// without including any branching.
// Its faster version, "spectral_zucconi", is advised for mobile applications.


// Read "Improving the Rainbow" for more information
// http://www.alanzucconi.com/?p=6703



float saturate (float x)
{
    return min(1.0, max(0.0,x));
}
vec3 saturate (vec3 x)
{
    return min(vec3(1.,1.,1.), max(vec3(0.,0.,0.),x));
}

// --- Spectral Zucconi --------------------------------------------
// By Alan Zucconi
// Based on GPU Gems: https://developer.nvidia.com/sites/all/modules/custom/gpugems/books/GPUGems/gpugems_ch08.html
// But with values optimised to match as close as possible the visible spectrum
// Fits this: https://commons.wikimedia.org/wiki/File:Linear_visible_spectrum.svg
// With weighter MSE (RGB weights: 0.3, 0.59, 0.11)
vec3 bump3y (vec3 x, vec3 yoffset)
{
    vec3 y = vec3(1.,1.,1.) - x * x;
    y = saturate(y-yoffset);
    return y;
}

// --- Spectral Zucconi 6 --------------------------------------------

// Based on GPU Gems
// Optimised by Alan Zucconi
vec3 spectral_zucconi6 (float x)
{
    // w: [400, 700]
    // x: [0,   1]

    const vec3 c1 = vec3(3.54585104, 2.93225262, 2.41593945);
    const vec3 x1 = vec3(0.69549072, 0.49228336, 0.27699880);
    const vec3 y1 = vec3(0.02312639, 0.15225084, 0.52607955);

    const vec3 c2 = vec3(3.90307140, 3.21182957, 3.96587128);
    const vec3 x2 = vec3(0.11748627, 0.86755042, 0.66077860);
    const vec3 y2 = vec3(0.84897130, 0.88445281, 0.73949448);

    return
        bump3y(c1 * (x - x1), y1) +
        bump3y(c2 * (x - x2), y2) ;
}

// --- MATLAB Jet Colour Scheme ----------------------------------------
vec3 spectral_jet(float w)
{
    // w: [400, 700]
    // x: [0,   1]
    float x = saturate((w - 400.0)/ 300.0);
    vec3 c;

    if (x < 0.25)
        c = vec3(0.0, 4.0 * x, 1.0);
    else if (x < 0.5)
        c = vec3(0.0, 1.0, 1.0 + 4.0 * (0.25 - x));
    else if (x < 0.75)
        c = vec3(4.0 * (x - 0.5), 1.0, 0.0);
    else
        c = vec3(1.0, 1.0 + 4.0 * (0.75 - x), 0.0);

    // Clamp colour components in [0,1]
    return saturate(c);
}


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


// Mashup Fork of "Displacement with Dispersion" by cornusammonis. https://shadertoy.com/view/4ldGDB
// 2021-08-28 10:34:29
// & this https://www.shadertoy.com/view/MsGSRd by flockeroo

// displacement amount
#define DISP_SCALE 0.90

// chromatic dispersion samples
#define SAMPLES 64

// contrast
#define SIGMOID_CONTRAST 12.0

// channels to use for displacement, either xy or zw
#define CH xy


vec3 contrast(vec3 x) {
    return 1.0 / (1.0 + exp(-SIGMOID_CONTRAST * (x - 0.5)));    
}

vec2 normz(vec2 x) {
    return x == vec2(0) ? vec2(0) : normalize(x);
}

/*
    This function supplies a weight vector for each color channel.
    It's analogous to (but not a physically accurate model of)
    the response curves for each of the 3 cone types in the human eye.
    The three functions for red, green, and blue have the same integral
    over [0, 1], which is 1/3.
    Here are some other potential terms for the green weight that 
    integrate to 1/3:
        2.0*(1-x)*x
        10.0*((1-x)*x)^2
        46.667*((1-i)*i)^3
        210.0*((1-x)*x)^4
        924.0*((1-x)*x)^5
    By the way, this series of coefficients is OEIS A004731 divided by 3,
    which is a pretty interesting series: https://oeis.org/A002457
*/
vec3 sampleWeights(float i) {
    return vec3(i * i, 46.6666*pow((1.0-i)*i,3.0), (1.0 - i) * (1.0 - i));
}

vec3 sampleDisp(vec2 uv, vec2 dispNorm, float disp) {
    vec3 col = vec3(0);
    const float SD = 1.0 / float(SAMPLES);
    float wl = 0.0;
    vec3 denom = vec3(0);
    for(int i = 0; i < SAMPLES; i++) {
        vec3 sw = sampleWeights(wl);
        denom += sw;
        col += sw * hgTheme(uv + dispNorm * disp * wl);
        wl  += SD;
    }
    
    // For a large enough number of samples,
    // the return below is equivalent to 3.0 * col * SD;
    return col / denom;
}

// Fork of "Barbarella's Lava Lamp 3" by xenn. https://shadertoy.com/view/sstGWl
// 2021-09-06 05:11:27

//Chromatic aberration, film grain and tone mapping

float NoiseSeed;

float randomFloat(){
  NoiseSeed = sin(NoiseSeed) * 84522.13219145687;
  return fract(NoiseSeed);
}

vec3 ACESFilm(vec3 x)
{
    float a = .51;
    float b = 0.03;
    float c = 3.43;
    float d = 0.59;
    float e = 03.14;
    return (x*(a*x+b))/(x*(c*x+d)+e);
}




void mainImage( out vec4 fragColor, in vec2 fragCoord ){
    vec2 texel = 1. / iResolution.xy;
    vec2 uv = fragCoord.xy / iResolution.xy;

    vec2 n  = vec2(0.0, texel.y);
    vec2 e  = vec2(texel.x, 0.0);
    vec2 s  = vec2(0.0, -texel.y);
    vec2 w  = vec2(-texel.x, 0.0);

    vec2 dd   = texture(uCh0, uv).CH;
    vec2 d_n = texture(uCh0, fract(uv+n)).CH;
    vec2 d_e = texture(uCh0, fract(uv+e)).CH;
    vec2 d_s = texture(uCh0, fract(uv+s)).CH;
    vec2 d_w = texture(uCh0, fract(uv+w)).CH; 

    // antialias our vector field by blurring
    vec2 db = 0.4 * dd + 0.15 * (d_n+d_e+d_s+d_w);

    float ld = length(db);
    vec2 ln = normz(db);

    vec3 col = sampleDisp(uv, ln, DISP_SCALE * ld);
    
//    fragColor = vec4(contrast(col), 1.0);

//}

//void mainImage( out vec4 fragColor, in vec2 fragCoord ) {
    
    if(fragCoord.y / iResolution.y < Margins || fragCoord.y / iResolution.y > 1.0-Margins){
        fragColor = vec4(ACESFilm(vec3(0)), 1.0);
        return;
    }
    
    NoiseSeed = float(iFrame)* .003186154 + fragCoord.y * 17.2986546543 + fragCoord.x;
    
//    vec2 uv = fragCoord.xy/iResolution.xy;
    
    vec2 d = (uv-vec2(.5)) * .0075;
    vec3 color = vec3(texture(uCh0, uv - -.0 * d).r,
                      texture(uCh0, uv - .0 * d).g,
                      texture(uCh0, uv - -.0 * d).b);
                                  
    vec3 colz = hgTheme(uv);
                      
        vec3 col2 = vec3(texture(uCh2, uv - 0.0 * d).r,
                      texture(uCh2, uv - .0 * d).g,
                      texture(uCh2, uv - -.0 * d).b);
                      
                      colz = max(colz,col2);
                  //    color = max(col2,col);
                      col2 = mix(col2,color,0.5);
                     col2 = max(colz,color);
                      
                       
    //  color = min(col,color);
    float noise = .9 + randomFloat()*.15;
//      fragColor = vec4(ACESFilm(((color * 0.5)+ (min(col,color)))*noise), 1.0);
    
     colz = hgPalette((col.r + col.g + col.b) / 3.0);
     colz = hgWindowLight(colz, gl_FragCoord.xy);
     colz += (hgGrain(floor(gl_FragCoord.xy / 2.0), floor(iTime * 10.0)) - 0.5) * 0.035;
     fragColor=vec4(colz,1.0);
}









out vec4 hg_fragColor;
void main() {
    mainImage(hg_fragColor, gl_FragCoord.xy);
}
