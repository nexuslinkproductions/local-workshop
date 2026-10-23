#version 440

// Environment slot, fragment stage. Plain base (ENV-SPEC section 1): shade(P) returns baseColor.
// Baked by shaders/env-bake.sh into env.frag.qsb, which Environment.qml loads.
// Drop-in: tools/linux/env/r2qt.py writes a copy of this file with the s6 hall body between the
// SHADE-BEGIN and SHADE-END markers. Bake that copy; do not hand-edit the converted body.
//
// Pixel model: qt_TexCoord0 runs 0..1 over the item, (0,0) top left, y down. The global desktop
// pixel of a fragment is P = ORG + qt_TexCoord0 * R (pixel centres, y down).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// Same block as env.vert. Member names are the QML property names of Environment.qml.
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 origin;
    vec4 world;
    vec2 itemSize;
    float t;
    vec2 par;
    float link;
    float ai;
    vec4 bayA;
    vec4 bayB;
    vec2 disk;
    vec4 baseColor;
    float debugGrid;
};

// s6 hall names (WebGL, see s6/r/src/r.frag) mapped onto the block.
#define ORG origin
#define WORLD world
#define R itemSize
#define T t
#define PAR par
#define LINK link
#define AI ai

vec2 envP;  // global desktop pixel of the current fragment, set by shade()

// gl_FragCoord of the s6 shader: pixel of this item measured the way WebGL does (y up),
// folded so that ORG.x + fc.x and R.y - fc.y give the global pixel envP for any origin.
vec4 qtFragCoord() {
    return vec4(envP.x - origin.x, itemSize.y - envP.y, 0.0, 1.0);
}

// BAY[i] for any index (the s6 slot loop uses a runtime index).
float bayAt(int i) {
    if (i == 0) return bayA.x;
    if (i == 1) return bayA.y;
    if (i == 2) return bayA.z;
    if (i == 3) return bayA.w;
    if (i == 4) return bayB.x;
    return bayB.y;
}

// SHADE-BEGIN
vec4 shade(vec2 P) {
    envP = P;
    return baseColor;
}
// SHADE-END

void main() {
    vec2 P = origin + qt_TexCoord0 * itemSize;
    vec4 c = shade(P);
    if (debugGrid > 0.5) {
        // stitch proof: 100 px lines (1 px) and 1000 px marks in GLOBAL pixels
        vec2 g = floor(P);
        bool onMark = mod(g.x, 1000.0) == 0.0 || mod(g.y, 1000.0) == 0.0;
        bool onLine = mod(g.x, 100.0) == 0.0 || mod(g.y, 100.0) == 0.0;
        if (onMark) c.rgb = vec3(0.95, 0.75, 0.20);
        else if (onLine) c.rgb = vec3(0.12, 0.55, 0.70);
        // magenta 3 px corner at the world origin: shows that the world binding reaches the shader
        if (abs(P.x - world.x) < 3.0 && abs(P.y - world.y) < 3.0) c.rgb = vec3(1.0, 0.0, 1.0);
    }
    fragColor = vec4(c.rgb, 1.0) * qt_Opacity;
}
