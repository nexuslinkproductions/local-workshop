#version 440

// Swarm option B, fragment stage: each fragment sits inside one mesh cell, whose
// four corners are four dots. Test those four dots as round discs and keep the
// front-most. Depth drives dot size and brightness, so the cloud reads as 3D.
//
// A dot is identified by its texel in the data grid, so the stipple hash and the
// brightness jitter are per dot. Hashing the fragment's own cell instead (the
// first cut did) let the four quads that meet at one dot disagree: whatever the
// hash kept, the other three quads dropped, so a round disc rendered as a 1 px
// dash in one quadrant of its cell.
//
// Dot size is u_dotR x the projected scale x a depth mix. The projected scale
// alone spans 1.4x over the sphere, which is a third of a pixel on a 1.7 px
// radius and does not read at all; the depth mix takes a near dot to about 1.9x
// the radius of a far one at the same width.

layout(location = 0) in vec2 vUV;
layout(location = 1) in vec2 vScreen;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_size;
    float u_pxPerUnit;
    vec4 u_accent;
    vec3 u_posBase;
    float u_pitch;
    float u_dotR;
    float u_rTube;
    float u_yaw;
    float u_tilt;
    float u_camDist;
    float u_gain;
    float u_focus;
    float u_activity;
    vec4 u_texInfo;         // x = cols, y = rows, z = kmax
    vec4 u_cellInfo;
    vec2 u_cellN;
    float u_stipple;        // share of dots kept, hashed per dot
    float u_breathScale;    // dot radius multiplier, 1.0 .. 1 + breathScale
    float u_breathBright;   // brightness multiplier, 1.0 .. 1 + breathBright
};

layout(binding = 1) uniform sampler2D u_pts;

mat3 rotMat(float yaw, float tilt)
{
    float cy = cos(yaw), sy = sin(yaw);
    float ct = cos(tilt), st = sin(tilt);
    mat3 ry = mat3(cy, 0.0, -sy,
                   0.0, 1.0, 0.0,
                   sy, 0.0, cy);
    mat3 rx = mat3(1.0, 0.0, 0.0,
                   0.0, ct, st,
                   0.0, -st, ct);
    return ry * rx;
}

bool dotAt(vec2 idx, mat3 R, inout vec3 bestCol, inout float bestMask,
           inout float bestDepth)
{
    vec4 t = texture(u_pts, (idx + 0.5) / u_texInfo.xy);
    if (t.r > 0.996)
        return false;                       // padding texel, no point
    float keep = fract(sin(dot(idx, vec2(12.9898, 78.233))) * 43758.5453);
    if (keep > u_stipple)
        return false;
    vec3 p = u_posBase + floor(t.rgb * 255.0 + 0.5) * u_pitch;
    vec3 v = R * p;
    float s = u_pxPerUnit * u_camDist / max(u_camDist - v.z, 0.05);
    vec2 c = vec2(u_size.x * 0.5 + v.xy.x * s, u_size.y * 0.5 - v.xy.y * s);
    float depth = clamp(0.5 + v.z / max(2.0 * u_rTube, 1e-4) * 0.5, 0.0, 1.0);
    // 0 at the limb, 1 at the point nearest the camera. Perspective alone spans
    // only 1.12 / 0.86 = 1.3x across the sphere and does not read at a 2 px
    // radius; this term takes a near dot to about 2.2x a limb dot and doubles as
    // the surface foreshortening term (a dot seen at a grazing angle covers less
    // area, which is what stops the rim fusing into a ring of overlapping discs).
    float near = clamp(v.z / max(2.0 * u_rTube, 1e-4), 0.0, 1.0);
    // Per-dot jitter on size and brightness: the reference field is organic, with
    // dots that vary by maybe plus or minus 20 percent, not a stamped grid.
    float js = fract(sin(dot(idx, vec2(39.3468, 11.135))) * 43758.5453);
    float radius = u_dotR * s * mix(0.55, 1.0, near) * mix(0.85, 1.15, js)
                   * u_breathScale;
    float d = length(c - vScreen);
    // Same ~0.8 px transition as the knot shader: a 3 px dot needs a solid core
    // or the whole field reads as dim smear instead of points.
    float aa = clamp(radius * 0.50, 0.50, 1.2);
    float mask = 1.0 - smoothstep(radius - aa, radius + aa * 0.80, d);
    if (mask <= 0.002)
        return false;
    if (v.z <= bestDepth)
        return false;
    bestDepth = v.z;
    float j = fract(sin(dot(idx, vec2(39.3468, 11.135))) * 43758.5453);
    // The reference orb is a dim field with a bright near core, not a flat
    // saturated disc: the floor keeps the rim visible on #06080a while the centre
    // carries the light.
    float bright = mix(0.62, 1.0, near) * mix(0.86, 1.10, j);
    bright *= mix(1.0, 1.12, u_activity) * (1.0 - 0.55 * u_focus) * u_gain;
    bright *= u_breathBright;
    vec3 col = mix(u_accent.rgb * 0.72, u_accent.rgb, depth);
    col = mix(col, vec3(1.0), pow(depth, 4.0) * 0.22);
    bestCol = col * bright;
    bestMask = mask;
    return true;
}

void main()
{
    mat3 R = rotMat(u_yaw, u_tilt);
    // The 3 x 3 block of texels around this fragment's cell. GridMesh's texcoord
    // convention (vertex i at i/(n-1) or at (i+0.5)/n) is not part of the
    // contract, and the two differ by half a texel: with a 4-corner test, a
    // fragment in the upper half of a quad resolves the cell one texel too far
    // and drops the dot on the near side, which renders a dot as a half disc with
    // one straight edge. One extra ring of fetches removes the failure class: a
    // dot within a cell of the fragment is always tested, and the distance test
    // drops the rest.
    vec2 lastIdx = u_texInfo.xy - 1.0;
    vec2 cell = floor(vUV * lastIdx);
    vec3 col = vec3(0.0);
    float mask = 0.0;
    float depth = -1e9;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            vec2 idx = clamp(cell + vec2(float(dx), float(dy)),
                             vec2(0.0), lastIdx);
            vec3 c = vec3(0.0);
            float m = 0.0;
            float d = depth;
            if (dotAt(idx, R, c, m, d)) {
                col = c;
                mask = m;
                depth = d;
            }
        }
    }

    // Premultiplied, the same convention as the knot shader: the mask is the
    // alpha, so the disc edge is antialiased instead of hard-clipped.
    fragColor = vec4(col * mask, mask);
}
