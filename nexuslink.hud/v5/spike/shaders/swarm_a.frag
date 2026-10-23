#version 440

// Swarm option A: fragment-shader ray march of the triquetra tube SDF, with
// procedural round-dot cells on the surface and depth based dot size and
// brightness. One draw, no vertex geometry, no per-frame JS.
//
// The tube SDF is baked as a 2D centre-line distance texture (R: thick tube,
// G: ring) because an analytic distance to the 233 traced segments costs too
// much per pixel. The march evaluates sqrt(d2^2 + z^2) - r, which is the exact
// distance to a circular tube around a planar curve. The orb uses the analytic
// sphere length(p) - 1, selected by u_shape.
//
// The SDF texture is RGB8 with alpha 255 (Qt premultiplies image textures, so a
// byte survives only when alpha is opaque). Screen space is y-down, object space
// is y-up, units are "ring radius = 1".

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_size;
    float u_pxPerUnit;
    vec4 u_accent;          // rgb, w unused
    float u_dotR;
    float u_pitch;
    float u_rTube;
    float u_rRing;
    float u_yaw;
    float u_tilt;
    float u_camDist;
    vec2 u_sdfLo;
    float u_sdfSpan;
    float u_sdfRange;
    float u_shape;          // 0 knot, 1 orb
    float u_gain;
    float u_focus;
    float u_activity;
    float u_stipple;
};

layout(binding = 1) uniform sampler2D u_sdf;

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

float hash13(vec3 c)
{
    c = fract(c * vec3(0.1031, 0.1030, 0.0973));
    c += dot(c, c.yzx + 33.33);
    return fract((c.x + c.y) * c.z);
}

vec2 project(vec3 p, mat3 R)
{
    vec3 v = R * p;
    float s = u_pxPerUnit * u_camDist / max(u_camDist - v.z, 0.05);
    return v.xy * s;
}

float centreDist(vec3 p)
{
    if (u_shape > 0.5)
        return length(p) - 1.0;
    vec2 uv = (p.xy - u_sdfLo) / u_sdfSpan;
    vec2 d = texture(u_sdf, uv).rg * u_sdfRange;
    float z = p.z;
    float a = sqrt(d.x * d.x + z * z) - u_rTube;
    float b = sqrt(d.y * d.y + z * z) - u_rRing;
    return min(a, b);
}

void main()
{
    vec2 px = vec2(qt_TexCoord0.x - 0.5, 0.5 - qt_TexCoord0.y) * u_size;
    mat3 R = rotMat(u_yaw, u_tilt);
    mat3 Rt = transpose(R);

    // view ray, pushed back into geometry space
    float k = 1.0 / u_pxPerUnit;
    vec3 oV = vec3(px * k, 0.9);
    vec3 dirV = normalize(vec3(px * k * 0.01, -1.0));
    vec3 o = Rt * oV;
    vec3 d = Rt * dirV;

    float bound = u_shape > 0.5 ? 1.02 : 1.34;
    float b = dot(o, d);
    float c = dot(o, o) - bound * bound;
    float disc = b * b - c;
    if (disc < 0.0) {
        fragColor = vec4(0.0);
        return;
    }
    float sq = sqrt(disc);
    float t0 = -b - sq;      // start at the bound entry: the orb ray begins inside it
    float t1 = -b + sq;

    float t = t0;
    float hit = -1.0;
    for (int i = 0; i < 64; ++i) {
        vec3 p = o + d * t;
        float dist = centreDist(p);
        if (dist < 0.0008) {
            hit = t;
            break;
        }
        t += max(abs(dist) * 0.65, 0.0015);
        if (t > t1) break;
    }
    if (hit < 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    vec3 pg = o + d * hit;
    vec3 vg = R * pg;

    // facing term from the same field
    float e = u_pitch * 0.5;
    float dx = centreDist(pg + vec3(e, 0.0, 0.0)) - centreDist(pg - vec3(e, 0.0, 0.0));
    float dy = centreDist(pg + vec3(0.0, e, 0.0)) - centreDist(pg - vec3(0.0, e, 0.0));
    float dz = centreDist(pg + vec3(0.0, 0.0, e)) - centreDist(pg - vec3(0.0, 0.0, e));
    vec3 n = normalize(vec3(dx, dy, dz) + vec3(1e-6));
    float facing = clamp(abs(dot(normalize(R * n), vec3(0.0, 0.0, 1.0))), 0.0, 1.0);

    // procedural round-dot cells on the surface
    vec3 cell = floor(pg / u_pitch);
    vec3 centre = (cell + 0.5) * u_pitch;
    if (hash13(cell + 0.5) > u_stipple) {
        fragColor = vec4(0.0);
        return;
    }
    vec2 dc = project(centre, R) - px;
    float jr = hash13(cell + 17.0);
    float radius = u_dotR * mix(0.88, 1.12, jr) * u_pxPerUnit * u_camDist / max(u_camDist - vg.z, 0.05);
    float aa = clamp(radius * 0.42, 0.45, 1.1);
    float mask = 1.0 - smoothstep(radius - aa, radius + aa * 0.25, length(dc));
    if (mask <= 0.002) {
        fragColor = vec4(0.0);
        return;
    }

    float depth = clamp(facing * 0.55 + clamp(vg.z / max(u_rTube, 1e-4), -1.0, 1.0) * 0.45, 0.0, 1.0);
    float bright = mix(0.42, 1.0, depth * depth) * mix(0.74, 1.14, hash13(cell + 31.0));
    bright *= mix(1.0, 1.12, u_activity) * (1.0 - 0.55 * u_focus) * u_gain;
    vec3 col = mix(u_accent.rgb * 0.55, u_accent.rgb, depth);
    col = mix(col, vec3(1.0), pow(depth, 4.0) * 0.22);
    fragColor = vec4(col * bright * mask, mask);
}
