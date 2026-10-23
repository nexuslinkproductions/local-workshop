#version 440

// Swarm option B, fragment stage: each pixel belongs to one mesh cell, whose
// four corners are four dots. Test those four dots as round discs and keep the
// front-most. Depth drives dot size and brightness, so the cloud reads as 3D.

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
    float u_stipple;        // share of lattice points kept, per-dot hash
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

bool dotAt(vec2 uv, mat3 R, inout vec3 bestCol, inout float bestDepth)
{
    vec2 texel = (uv * u_texInfo.xy + 0.5) / u_texInfo.xy;
    vec2 cell = floor(uv * u_texInfo.xy);
    // Per-dot stipple. The shell is a dense cube-lattice sample: at orb size the
    // dots land about one pitch apart and read as a mesh. Dropping a share of
    // the lattice points by hash turns it back into discrete round points with
    // dark gaps. Same idea as the knot's u_stipple, hashed per dot instead of
    // per cell.
    float keep = fract(sin(dot(cell, vec2(12.9898, 78.233))) * 43758.5453);
    if (keep > u_stipple)
        return false;
    vec4 t = texture(u_pts, texel);
    if (t.r > 0.996)
        return false;
    vec3 p = u_posBase + floor(t.rgb * 255.0 + 0.5) * u_pitch;
    vec3 v = R * p;
    float s = u_pxPerUnit * u_camDist / max(u_camDist - v.z, 0.05);
    vec2 c = vec2(u_size.x * 0.5 + v.xy.x * s, u_size.y * 0.5 - v.xy.y * s);
    float radius = max(0.45, u_dotR * s);
    float d = length(c - vScreen);
    // Same ~0.8 px transition as the knot shader: a 3 px dot needs a solid core
    // or the whole field reads as dim smear instead of points.
    float aa = clamp(radius * 0.34, 0.45, 1.1);
    float mask = 1.0 - smoothstep(radius - aa, radius + aa * 0.50, d);
    if (mask <= 0.002)
        return false;

    float depth = clamp(0.5 + v.z / max(2.0 * u_rTube, 1e-4) * 0.5, 0.0, 1.0);
    if (v.z <= bestDepth)
        return false;
    bestDepth = v.z;
    float j = fract(sin(dot(uv * u_texInfo.xy, vec2(12.9898, 78.233))) * 43758.5453);
    float bright = mix(0.55, 1.0, depth * depth) * mix(0.82, 1.10, j);
    bright *= mix(1.0, 1.12, u_activity) * (1.0 - 0.55 * u_focus) * u_gain;
    vec3 col = mix(u_accent.rgb * 0.72, u_accent.rgb, depth);
    col = mix(col, vec3(1.0), pow(depth, 4.0) * 0.22);
    bestCol = col * bright;
    return true;
}

void main()
{
    mat3 R = rotMat(u_yaw, u_tilt);
    vec2 cell = floor(vUV * u_texInfo.xy);
    vec3 col = vec3(0.0);
    float alpha = 0.0;
    float depth = -1e9;

    vec2 base = (cell + 0.5) / u_texInfo.xy;
    vec2 step1 = 1.0 / u_texInfo.xy;
    vec3 c0 = vec3(0.0);
    float d0 = depth;
    if (dotAt(base, R, c0, d0)) { col = c0; alpha = 1.0; depth = d0; }
    c0 = vec3(0.0); d0 = depth;
    if (dotAt(base + vec2(step1.x, 0.0), R, c0, d0)) { col = c0; alpha = 1.0; depth = d0; }
    c0 = vec3(0.0); d0 = depth;
    if (dotAt(base + vec2(0.0, step1.y), R, c0, d0)) { col = c0; alpha = 1.0; depth = d0; }
    c0 = vec3(0.0); d0 = depth;
    if (dotAt(base + step1, R, c0, d0)) { col = c0; alpha = 1.0; depth = d0; }

    fragColor = vec4(col, alpha);
}
