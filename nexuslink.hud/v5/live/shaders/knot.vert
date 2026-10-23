#version 440

// One sprite quad per point, expanded in the vertex stage.
// Mesh is GridMesh{resolution: (2N, 1)}, so a grid column c belongs to
// point pid = floor(c/2) and side c%2. Cells between two columns of the
// same point are the quad; cells between different points are bridges and
// are killed in the fragment stage by comparing a flat copy of the point id
// with an interpolated copy.
//
// Motion (spec KNOT-SPEC sections A to G, addendum v2.1 items 1 to 5):
//  A  small global pose (yaw 12, pitch 7) + 0.8 percent scale pulse
//  B  three lobes breathing on their own clocks (5.0 / 6.1 / 7.0 s), slow FM
//     plus a small per point phase offset so a lobe never pulses as one block
//  C  peristaltic wavefronts along the strand (swell with a trailing trough)
//  D  curl-noise micro-currents, small groups swirl together
//  E  local events: a ring swelling out from a hashed point, every 4 to 9 s
//  F  five acid sparks gliding along the strands
// v3 (repair K): a per strand activity envelope (static 3 lobe term plus two
// slow drifting terms, periods 29 and 37 s) multiplies the strand terms C and D,
// so different segments are more or less active over time; the local terms are
// 2 to 3 times larger than v2 and soft limited at 10 percent of R (G, exp form, see KNOT-SPEC-ADD item 4); the
// point set is even (knot-points3.png) and texel4.b carries a crowd weight that
// keeps stacked depth layers from adding up to white blobs at the crossings.
// v4 (repair round 3): the strand fronts are single travelling bulges (gaussian
// window 0.075 u, tube swell along the point normal N3 plus a push along dirW,
// brightness crest and bigger dots on the crest), the lobes breathe in
// THICKNESS (dots move along N3, so the ribbon width changes, not only the
// brightness), depth brightness is flattened and per dot alpha is capped so
// no pixel group clips to white.

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

// ---- point texture layout, keep in sync with KnotSwarm.qml ---------------
// v2 (K3, shaders/knot-points2.png, 2048 x 11):
//   t0 = P.xy (16 bit each), t1 = P.z (16 bit) + spare,
//   t2 = N3 (8 bit per axis), t3 = u, q, cls + spare,
//   t4 = (u * 255, occl * 255, 0). u is the true arc length per class and
//   occl the under strand weight (0 away from the crossings).
const float TEXEL_STRIDE = 5.0;   // texels per point
const float TEX_ROWS = 11.0;      // texture rows
const float TEX_WIDTH = 2048.0;   // texture width

const float PI = 3.141592653589793;
const float TAU = 6.283185307179586;
const float KNOT_H = 900.0;
const float R = 450.0;            // knot radius in knot units
const float DEPTH_K = 0.35;       // how much of the z depth cue survives (1 = old)
const float ALPHA_CAP = 0.80;     // per dot alpha ceiling, acid sparks excepted

vec4 texAt(float i) {
    float px = mod(i, TEX_WIDTH);
    float row = floor(i / TEX_WIDTH);
    return textureLod(src, vec2((px + 0.5) / TEX_WIDTH, (row + 0.5) / TEX_ROWS), 0.0);
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

// shortest signed difference between two angles, in radians
float angDiff(float a, float b) {
    float d = a - b;
    return d - TAU * floor((d + PI) / TAU);
}

// one peristaltic front: swell at f, small trough trailing behind it
float frontG(float uu, float o, float dir, float period, float tt) {
    float f = fract(o + dir * tt / period);
    float d = fract(uu - f + 0.5) - 0.5;
    float a = exp(-(d / 0.065) * (d / 0.065));
    float b = exp(-((d + 0.09 * dir) / 0.065) * ((d + 0.09 * dir) / 0.065));
    return a - 0.20 * b;
}

// per strand activity envelope, mean 1: a static 3 lobe term and two slow
// drifting terms (29 s and 37 s) so segments take turns being active
float envU(float uu, float tt) {
    float e = (1.0 + 0.65 * sin(TAU * 3.0 * uu + 0.9))
            * (1.0 + 0.30 * sin(TAU * (2.0 * uu - tt / 29.0) + 2.2))
            * (1.0 + 0.20 * sin(TAU * (5.0 * uu + tt / 37.0) + 4.1));
    return min(e, 1.8);
}

// curl-noise vector potential (spec D), p in units of 55 knot units
vec3 pot(vec3 p, float tt) {
    return vec3(
        sin(1.3 * p.y + 0.8 * sin(0.7 * p.z + 0.21 * tt) + 0.31 * tt),
        sin(1.1 * p.z + 0.6 * sin(0.9 * p.x + 0.17 * tt) + 0.27 * tt + 2.0),
        sin(1.2 * p.x + 0.7 * sin(0.8 * p.y + 0.23 * tt) + 0.24 * tt + 4.0));
}

vec3 curlA(vec3 p, float tt) {
    const float e = 0.05;
    vec3 dx = pot(p + vec3(e, 0.0, 0.0), tt) - pot(p - vec3(e, 0.0, 0.0), tt);
    vec3 dy = pot(p + vec3(0.0, e, 0.0), tt) - pot(p - vec3(0.0, e, 0.0), tt);
    vec3 dz = pot(p + vec3(0.0, 0.0, e), tt) - pot(p - vec3(0.0, 0.0, e), tt);
    const float inv = 0.5 / e;
    return vec3(dy.z - dz.y, dz.x - dx.z, dx.y - dy.x) * inv;
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

    vec4 t0 = texAt(TEXEL_STRIDE * pid + 0.0);
    vec4 t1 = texAt(TEXEL_STRIDE * pid + 1.0);
    vec4 t2 = texAt(TEXEL_STRIDE * pid + 2.0);
    vec4 t3 = texAt(TEXEL_STRIDE * pid + 3.0);
    vec4 t4 = texAt(TEXEL_STRIDE * pid + 4.0);

    vec3 P;
    P.x = b255(t0.r) * 256.0 + b255(t0.g);
    P.y = b255(t0.b) * 256.0 + b255(t1.r);
    P.z = b255(t1.g) * 256.0 + b255(t1.b);
    P = P / 65535.0 * 1024.0 - 512.0;

    vec3 N3 = t2.rgb * 2.0 - 1.0;
    float q = t3.g;
    float cls = t3.b;

    // true arc length along its own class (v2 texel 4 red), 0..1
    float su = t4.r;
    // under strand weight, 0 away from the crossings, 0.839 at the deepest
    float occl2 = clamp(t4.g * 1.19, 0.0, 1.0);
    // crowd weight (texel4.b): 1 on an isolated strand, down to 0.35 where
    // another pass stacks behind it in projection
    float crowd = t4.b;

    vec3 er = normalize(vec3(P.x, P.y, 0.0));
    vec3 dirW = normalize(er * 0.8 + N3 * 0.45);

    // ---- A: smaller global pose, 0.8 percent scale pulse ----------------
    float ny = (sin(TAU * t / 31.0) + 0.55 * sin(TAU * t / 26.0 + 1.1)
              + 0.32 * sin(TAU * t / 38.0 + 2.3)) / 1.87;
    float np = (sin(TAU * t / 34.0 + 0.7) + 0.55 * sin(TAU * t / 27.5 + 2.1)
              + 0.32 * sin(TAU * t / 39.0 + 4.0)) / 1.87;
    float gn = returnGain(t);
    float yaw = ny * gn * radians(12.0);
    float pitch = np * gn * radians(7.0);

    float br0 = breathAt(t, 0.0);
    vec3 Q = P * (1.0 + 0.008 * br0);

    // ---- B: three lobes, each on its own clock (measured tip angles) ----
    float ang = atan(P.y, P.x);
    float a0 = radians(34.0), a1 = radians(142.4), a2 = radians(266.4);
    float d0 = angDiff(ang, a0) / 0.55;
    float d1 = angDiff(ang, a1) / 0.55;
    float d2 = angDiff(ang, a2) / 0.55;
    float w0 = exp(-d0 * d0);
    float w1 = exp(-d1 * d1);
    float w2 = exp(-d2 * d2);
    float wsum = max(w0 + w1 + w2, 1e-5);

    // slow frequency modulation per lobe clock, plus a small deterministic
    // per point phase offset so a lobe does not pulse as one solid block
    float fm0 = 0.06 * sin(TAU * t / 31.0) + 0.00;
    float fm1 = 0.06 * sin(TAU * t / 38.0 + 2.0) + 0.00;
    float fm2 = 0.06 * sin(TAU * t / 45.0 + 4.0) + 0.00;
    float pp = 0.035 * (fract(sin(pid * 12.9898) * 43758.5453) - 0.5);

    float bl = (w0 * breathAt(t * 5.5 / 5.0, 0.00 + fm0 + pp)
              + w1 * breathAt(t * 5.5 / 6.1, 0.37 + fm1 + pp)
              + w2 * breathAt(t * 5.5 / 7.0, 0.71 + fm2 + pp)) / wsum;
    float lb = 2.0 * bl - 1.0;

    // ---- C: peristaltic fronts along the strand (u) ---------------------
    float g;
    if (cls < 0.5) {
        g = frontG(su, 0.10, 1.0, 8.5, t)
          + frontG(su, 0.60, -1.0, 11.5, t);
    } else {
        g = 0.5 * (frontG(su, 0.20, 1.0, 9.5, t)
                 + frontG(su, 0.60, -1.0, 13.0, t));
    }
    // the bulge keeps most of its height all the way round: only 60 percent of the
    // strand envelope reaches the front, clamped to 0.5 .. 1.5
    float env = envU(su, t);
    g *= clamp(mix(1.0, env, 0.6), 0.5, 1.5);
    // two fronts meeting must not double the bulge (and its speed): soft saturation
    g = g * inversesqrt(1.0 + (g / 1.5) * (g / 1.5));
    // tube radius in knot units (ribbon 20, ring 5.5), used for the thickness terms
    float rr = cls < 0.5 ? 20.0 : 5.5;

    // ---- D: curl-noise micro-currents -----------------------------------
    vec3 vel = curlA(P / 55.0, t);
    vec3 dD = vel * (R * 0.054 * env);
    float dl0 = length(dD);
    float dlim = R * 0.062;
    dD *= dlim * (1.0 - exp(-dl0 / dlim)) / max(dl0, 1e-4);

    // ---- E: local events, a ring travelling away from a hashed point ----
    float ev = 0.0;
    for (int j = 0; j < 2; j++) {
        float L = j == 0 ? 5.3 : 8.1;
        float off = j == 0 ? 0.0 : 2.9;
        float tt = t + off;
        float ei = floor(tt / L);
        float age = tt - ei * L;
        float s0 = fract(sin(ei * 12.9898 + float(j) * 78.233) * 43758.5453);
        float d = abs(fract(su - s0 + 0.5) - 0.5);
        float front = age * 0.05;
        float x = (d - front) / 0.07;
        float r = exp(-x * x) * smoothstep(0.0, 1.6, age) * exp(-age / 3.0)
                * (1.0 - smoothstep(0.6 * L, L, age));   // gone before the slot restarts: no pop
        ev = max(ev, r);
    }
    float evK = cls < 0.5 ? 1.0 : 0.5;   // the ring moves at half amplitude

    // ---- sum the local terms, soft limited at 10 percent of R ------------
    // B: lobe scale about the centre plus lobe THICKNESS (dots along N3)
    // C/E: bulge = tube swell along N3 + push along dirW
    float ringK = cls < 0.5 ? 1.0 : 0.5;
    vec3 dloc = vec3(P.x, P.y, 0.0) * (0.024 * lb)
              + N3 * (rr * 0.80 * lb)
              + N3 * (R * 0.055 * g * ringK + R * 0.040 * ev * evK)
              + dirW * (R * 0.035 * g + R * 0.030 * ev * evK)
              + dD;
    float lim = R * 0.10;
    float dl = length(dloc);
    dloc *= lim * (1.0 - exp(-dl / lim)) / max(dl, 1e-4);
    Q += dloc;

    // ---- brightness and size from the same local terms ------------------
    float crest = max(g, 0.0);
    float bfac = (1.0 + 0.15 * lb) * (1.0 + 0.75 * g) * (1.0 + 0.60 * ev * evK);
    float rfac = (1.0 + 0.10 * lb) * (1.0 + 0.35 * crest) * (1.0 + 0.40 * ev * evK);
    bfac = clamp(bfac, 0.60, 1.90);
    rfac = clamp(rfac, 0.75, 1.50);

    // v2 under strand dimming: the weave reads at the three crossings
    // (addendum item 3: radius shrinks, alpha dims further down)
    rfac = clamp(rfac * (1.0 - 0.25 * occl2), 0.60, 1.80);

    // ---- project --------------------------------------------------------
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
    float d = clamp(0.5 + z2 / 140.0, 0.0, 1.0);
    float f = clamp(0.5 + 0.5 * nz2, 0.0, 1.0);

    // density breath: a point is present while the threshold is above its q
    float thr = 0.86 + 0.14 * br0;
    float vis = smoothstep(q - 0.03, q + 0.03, thr);

    // ---- F: five acid sparks gliding along the strands (u) --------------
    float spark = 0.0;
    float carrier = fract(sin(pid * 78.233 + 1.7) * 43758.5453) < 0.33 ? 1.0 : 0.3;
    for (int i = 0; i < 5; i++) {
        float ck = i < 3 ? 0.0 : 1.0;
        if (abs(cls - ck) > 0.5) continue;
        float lap = i == 0 ? 14.0 : (i == 1 ? 19.0 : (i == 2 ? 26.0
                  : (i == 3 ? 18.0 : 31.0)));
        float dir = i == 1 ? -1.0 : 1.0;
        float o = i == 0 ? 0.05 : (i == 1 ? 0.42 : (i == 2 ? 0.77
                : (i == 3 ? 0.28 : 0.66)));
        float sh = fract(dir * t / lap + o);
        float ds = fract(su - sh + 0.5) - 0.5;   // signed, in loop units
        float head = exp(-(ds / 0.002) * (ds / 0.002));
        float behind = -ds * dir;                // > 0 behind the head
        // tail only behind the head; ahead of it behind is <= 0 and must give 0
        // (exp(0) = 1 there tinted half of the loop acid green)
        float tail = behind > 0.0 ? exp(-behind / 0.012) : 0.0;
        // the head is a small cluster of carrier dots (about 4 in 10 points of the
        // head), not a solid band across the strand: 4 to 6 acid dots like the mockup
        head *= carrier;
        spark = max(spark, max(head, 0.55 * tail));
    }

    vec3 cAzure = vec3(96.0, 165.0, 250.0) / 255.0;
    vec3 cIce = vec3(143.0, 216.0, 232.0) / 255.0;
    vec3 cWhite = vec3(244.0, 248.0, 251.0) / 255.0;
    vec3 cAcid = vec3(200.0, 243.0, 29.0) / 255.0;

    // depth cue flattened: the three lobes sit at different z, and the full range
    // made the near lobe 3 to 5 times brighter than the far one (v3 hotspot)
    float dd = mix(0.5, d, DEPTH_K);
    vec3 col = mix(cAzure, cIce, clamp(0.55 * dd + 0.45 * f, 0.0, 1.0));
    col = mix(col, cWhite, 0.35 * step(0.5, cls));
    // the crest of a travelling bulge turns toward white-ice so it reads against the azure
    col = mix(col, cWhite, 0.25 * clamp(g, 0.0, 1.0));
    col *= min(bfac, 1.15);   // the rest of the crest goes into alpha and radius: no channel clips
    col = mix(col, cAcid, spark);

    // depth and facing
    float alpha = (0.34 + 0.56 * dd) * (0.40 + 0.60 * f) * (0.86 + 0.14 * br0)
                * vis * mix(0.80, 1.55, clamp((bfac - 0.60) / 1.10, 0.0, 1.0));
    // v2: alpha dims on the strand that passes under a crossing
    alpha *= (1.0 - 0.75 * occl2) * mix(1.0, crowd, 0.9);
    // cap per dot so overlapping dots cannot add up to a clipped white patch;
    // the ring (cls 1) is a thin sparse circle, kept at 70 percent of the ribbon
    alpha = min(alpha, ALPHA_CAP) * (cls < 0.5 ? 1.0 : 0.70);
    alpha = mix(alpha, 1.0, spark * 0.85 * (0.4 + 0.6 * f));
    if (vis < 0.01) alpha = 0.0;

    float rpx = 1.75 * (knotPx / 540.0) * mix(0.82, 1.12, dd) * rfac;
    rpx = clamp(rpx, 1.0, 3.4);
    float hh = rpx + 1.5;

    vec2 centre = vec2(uW, uH) * 0.5;
    vec2 spos = centre + vec2(x1, y1) * k * (knotPx / KNOT_H);
    vec2 pos = spos + corner * hh;

    v_local = corner * hh;
    v_radius = rpx;
    v_color = vec4(clamp(col, 0.0, 1.0), clamp(alpha, 0.0, 1.0));
    v_pidSmooth = pid;

    gl_Position = qt_Matrix * vec4(pos, 0.0, 1.0);
}
