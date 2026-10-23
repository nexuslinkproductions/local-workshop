#version 440

// One sprite quad per point, expanded in the vertex stage.
// Mesh is GridMesh{resolution: (2N, 1)}, so a grid column c belongs to
// point pid = floor(c/2) and side c%2. Cells between two columns of the
// same point are the quad; cells between different points are bridges and
// are killed in the fragment stage by comparing a flat copy of the point id
// with an interpolated copy.

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec4 qt_MultiTexCoord0;

layout(location = 0) out vec2 v_local;
layout(location = 1) out float v_radius;
layout(location = 2) out vec4 v_color;
layout(location = 3) out float v_pidSmooth;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float uN;
    float uWidth;
    float uRows;
    float t;
    float knotPx;
    float uW;
    float uH;
};

layout(binding = 1) uniform sampler2D src;

const float PI = 3.141592653589793;
const float TAU = 6.283185307179586;
const float KNOT_H = 900.0;

vec4 texAt(float i) {
    float px = mod(i, uWidth);
    float row = floor(i / uWidth);
    return textureLod(src, vec2((px + 0.5) / uWidth, (row + 0.5) / uRows), 0.0);
}

float b255(float v) { return floor(v * 255.0 + 0.5); }

// slow wander, three incommensurate sines per axis, 12 s return toward front
float returnGain(float tt) {
    float w = 0.5 - 0.5 * cos(TAU * tt / 12.0);
    return 0.18 + 0.82 * smoothstep(0.12, 0.8, w);
}

// 5.5 s breath, 40 percent inhale, 60 percent exhale, sine eased both ways
float breathAt(float tt, float ph) {
    float u = fract(tt / 5.5 + ph);
    return u < 0.4
        ? 0.5 - 0.5 * cos(PI * u / 0.4)
        : 0.5 + 0.5 * cos(PI * (u - 0.4) / 0.6);
}

void main() {
    float c = floor(qt_MultiTexCoord0.x * (2.0 * uN) + 0.5);
    float pid = floor(c * 0.5);
    float side = mod(c, 2.0);
    float cyl = qt_MultiTexCoord0.y;
    vec2 corner = vec2(side * 2.0 - 1.0, cyl * 2.0 - 1.0);

    v_local = vec2(0.0);
    v_radius = 1.0;
    v_color = vec4(0.0);
    v_pidSmooth = pid;

    if (pid < 0.0 || pid >= uN) {
        v_pidSmooth = pid + 1.0;
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        return;
    }

    vec4 t0 = texAt(4.0 * pid + 0.0);
    vec4 t1 = texAt(4.0 * pid + 1.0);
    vec4 t2 = texAt(4.0 * pid + 2.0);
    vec4 t3 = texAt(4.0 * pid + 3.0);

    vec3 P;
    P.x = b255(t0.r) * 256.0 + b255(t0.g);
    P.y = b255(t0.b) * 256.0 + b255(t1.r);
    P.z = b255(t1.g) * 256.0 + b255(t1.b);
    P = P / 65535.0 * 1024.0 - 512.0;

    vec3 N3 = t2.rgb * 2.0 - 1.0;
    float sp = t3.r;
    float q = t3.g;
    float cls = t3.b;

    // per lobe breath phase: three lobes around the knot centre, 0 .. 0.07 cycles
    float ang = atan(P.y, P.x);
    float ph = 0.07 * (0.5 - 0.5 * cos(3.0 * (ang + PI)));

    float b = breathAt(t, ph);
    vec3 Q = P * (1.0 + 0.02 * b);

    float ny = (sin(TAU * t / 31.0) + 0.55 * sin(TAU * t / 26.0 + 1.1)
              + 0.32 * sin(TAU * t / 38.0 + 2.3)) / 1.87;
    float np = (sin(TAU * t / 34.0 + 0.7) + 0.55 * sin(TAU * t / 27.5 + 2.1)
              + 0.32 * sin(TAU * t / 39.0 + 4.0)) / 1.87;
    float gn = returnGain(t);
    float yaw = ny * gn * radians(30.0);
    float pitch = np * gn * radians(18.0);

    float cyw = cos(yaw), syw = sin(yaw);
    float cpt = cos(pitch), spt = sin(pitch);

    float x1 = Q.x * cyw + Q.z * syw;
    float z1 = -Q.x * syw + Q.z * cyw;
    float y1 = Q.y * cpt - z1 * spt;
    float z2 = Q.y * spt + z1 * cpt;

    float nx1 = N3.x * cyw + N3.z * syw;
    float nz1 = -N3.x * syw + N3.z * cyw;
    float ny1 = N3.y * cpt - nz1 * spt;
    float nz2 = N3.y * spt + nz1 * cpt;

    float camD = 2.7 * KNOT_H;
    float k = camD / (camD - z2);
    float d = clamp(0.5 + z2 / 160.0, 0.0, 1.0);
    float f = clamp(0.5 + 0.5 * nz2, 0.0, 1.0);

    // density breath: a point is present while the threshold is above its q
    float thr = 0.86 + 0.14 * b;
    float vis = smoothstep(q - 0.02, q + 0.02, thr);

    // 4 acid sparks gliding along the strands, two on the ribbon, two on the ring
    float spark = 0.0;
    for (int i = 0; i < 4; i++) {
        float ck = i < 2 ? 0.0 : 1.0;
        if (abs(cls - ck) > 0.5) continue;
        float period = ck > 0.5 ? 60.0 : 45.0;
        float s0 = float(i) * 0.25 + 0.13;
        float spk = fract(t / period + s0);
        float ds = abs(fract(sp - spk + 0.5) - 0.5);
        float m = 1.0 - smoothstep(0.0, 0.0028, ds);
        m *= 0.65 + 0.35 * sin(TAU * t / 3.7 + float(i) * 1.9);
        spark = max(spark, m);
    }

    vec3 cAzure = vec3(96.0, 165.0, 250.0) / 255.0;
    vec3 cIce = vec3(143.0, 216.0, 232.0) / 255.0;
    vec3 cWhite = vec3(244.0, 248.0, 251.0) / 255.0;
    vec3 cAcid = vec3(200.0, 243.0, 29.0) / 255.0;

    vec3 col = mix(cAzure, cIce, clamp(0.55 * d + 0.45 * f, 0.0, 1.0));
    col = mix(col, cWhite, 0.35 * step(0.5, cls));
    col = mix(col, cAcid, spark);

    float alpha = (0.16 + 0.84 * d) * (0.28 + 0.72 * f) * (0.86 + 0.14 * b) * vis;
    alpha = mix(alpha, 1.0, spark * 0.85);
    if (vis < 0.01) alpha = 0.0;

    float rpx = 2.3 * (knotPx / 540.0) * mix(0.6, 1.22, d);
    float hh = rpx + 1.5;

    vec2 centre = vec2(uW, uH) * 0.5;
    vec2 spos = centre + vec2(x1, y1) * k * (knotPx / KNOT_H);
    vec2 pos = spos + corner * hh;

    v_local = corner * hh;
    v_radius = rpx;
    v_color = vec4(col, alpha);
    v_pidSmooth = pid;

    gl_Position = qt_Matrix * vec4(pos, 0.0, 1.0);
}
