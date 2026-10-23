#version 440

// One sprite quad per point, expanded in the vertex stage.
// Mesh is GridMesh{resolution: (2N, 1)}, so a grid column c belongs to
// point pid = floor(c/2) and side c%2. Cells between two columns of the
// same point are the quad; cells between different points are bridges and
// are killed in the fragment stage by comparing a flat copy of the point id
// with an interpolated copy.
//
// Motion (KNOT-SPEC-R4, round 4: soft and gentle, plus the morph):
//  A  global pose only: pitch 1.6 deg (71 s and 97 s), roll 1.6 deg
//     (83 s and 113 s), NO yaw and no side to side translation, global
//     scale pulse 0.8 percent peak to peak with a 7 s period
//  B  three lobes breathing in thickness on their own clocks (9 / 11 / 13 s),
//     each with slow FM and a per point phase offset
//  C  peristaltic wavefronts along the strand, one travelling gaussian bulge
//     with a small trailing trough; loops are 11 and 15 s (ribbon) and 12 and
//     16 s (ring), window 0.10 u wide, no stepping
//  D  curl-noise micro-currents, small groups swirl together
//  E  local events: a ring swelling out from a hashed point, one every 9 or
//     13 s, slow 3 s rise, gone before the slot restarts
//  F  five acid sparks gliding along the strands
//  G  morph between the triquetra and two alternate forms, baked per point
//     into knot-points4.png (texels 5..10), blended here
//
// Round 4 runs about 40 percent of the round 3 local motion, with longer
// periods and wider windows, and the summed local term is soft limited at
// 4 percent of R (18 units, 10.8 px at knotPx 540). A per strand activity
// envelope (static 3 lobe term plus two slow drifting terms, periods 29 and
// 37 s) still multiplies the strand terms C and D. Texel4.b carries a crowd
// weight that keeps stacked depth layers from adding up to white blobs at
// the crossings, depth brightness is flattened and per dot alpha is capped
// so no pixel group clips to white.

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
// v4 (shaders/knot-points4.png, 2048 x 24, 11 texels per point):
//   t0  = P.xy (16 bit each), t1 = P.z (16 bit) + spare,
//   t2  = N3 (8 bit per axis), t3 = u, q, cls + spare,
//   t4  = (u * 255, occl * 255, crowd * 255). u is the true arc length per
//   class, occl the under strand weight (0 away from the crossings).
//   t5,t6 = form 1 position (same 16 bit encoding), t7 = form 1 normal,
//   t8,t9 = form 2 position, t10 = form 2 normal.
//   Texels 0..4 are byte for byte the round 3 data (knot-points3.png).
const float TEXEL_STRIDE = 11.0;  // texels per point
const float TEX_ROWS = 24.0;      // texture rows
const float TEX_WIDTH = 2048.0;   // texture width

const float PI = 3.141592653589793;
const float TAU = 6.283185307179586;
const float KNOT_H = 900.0;
const float R = 450.0;            // knot radius in knot units
const float DEPTH_K = 0.35;       // how much of the z depth cue survives (1 = old)
const float ALPHA_CAP = 0.80;     // per dot alpha ceiling, acid sparks excepted

// morph schedule, mirrors MORPH_* in tools/linux/measure/knot/knot_port.py
const float CYC = 60.0;           // full alternation cycle, s
const float HOLD_A = 33.0;        // hold on the triquetra, s
const float LEG = 12.0;           // one leg, s
const float HOLD_B = 3.0;         // hold on the form, s
const float STAGGER = 0.20;       // per point stagger, share of the leg

vec4 texAt(float i) {
    float px = mod(i, TEX_WIDTH);
    float row = floor(i / TEX_WIDTH);
    return textureLod(src, vec2((px + 0.5) / TEX_WIDTH, (row + 0.5) / TEX_ROWS), 0.0);
}

float b255(float v) { return floor(v * 255.0 + 0.5); }

// 16 bit position decode, same encoding as texels 0 and 1
vec3 posDecode(vec4 a, vec4 b) {
    vec3 v;
    v.x = b255(a.r) * 256.0 + b255(a.g);
    v.y = b255(a.b) * 256.0 + b255(b.r);
    v.z = b255(b.g) * 256.0 + b255(b.b);
    return v / 65535.0 * 1024.0 - 512.0;
}

// sine eased breath, one full cycle per period, smooth both ways
float breathAt(float tt, float ph, float period) {
    return 0.5 - 0.5 * cos(TAU * fract(tt / period + ph));
}

// smootherstep, no overshoot, zero slope at both ends
float smootherstep01(float e) {
    e = clamp(e, 0.0, 1.0);
    return e * e * e * (e * (6.0 * e - 15.0) + 10.0);
}

// morph weight 0..1 for the whole knot at time tt
float morphX(float tt) {
    float tau = fract(tt / CYC) * CYC;
    if (tau < HOLD_A) return 0.0;
    if (tau < HOLD_A + LEG) return (tau - HOLD_A) / LEG;
    if (tau < HOLD_A + LEG + HOLD_B) return 1.0;
    return 1.0 - (tau - HOLD_A - LEG - HOLD_B) / LEG;
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
    float a = exp(-(d / 0.10) * (d / 0.10));
    float b = exp(-((d + 0.09 * dir) / 0.10) * ((d + 0.09 * dir) / 0.10));
    return a - 0.15 * b;
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

    float base = TEXEL_STRIDE * pid;
    vec4 t0 = texAt(base + 0.0);
    vec4 t1 = texAt(base + 1.0);
    vec4 t2 = texAt(base + 2.0);
    vec4 t3 = texAt(base + 3.0);
    vec4 t4 = texAt(base + 4.0);

    vec3 P = posDecode(t0, t1);
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

    // ---- B: lobe weights, from the ORIGINAL P so the clocks never jump ---
    // (they also drive the per point morph stagger below)
    float ang = atan(P.y, P.x);
    float a0 = radians(34.0), a1 = radians(142.4), a2 = radians(266.4);
    float d0 = angDiff(ang, a0) / 0.55;
    float d1 = angDiff(ang, a1) / 0.55;
    float d2 = angDiff(ang, a2) / 0.55;
    float w0 = exp(-d0 * d0);
    float w1 = exp(-d1 * d1);
    float w2 = exp(-d2 * d2);
    float wsum = max(w0 + w1 + w2, 1e-5);

    // ---- G: morph, form of this cycle, then the per point weight ---------
    // cycle k is form 1 when k is even, form 2 when k is odd
    float kcyc = floor(t / CYC);
    float fsel = mod(kcyc, 2.0);
    vec4 t5 = texAt(base + 5.0);
    vec4 t6 = texAt(base + 6.0);
    vec4 t7 = texAt(base + 7.0);
    vec4 t8 = texAt(base + 8.0);
    vec4 t9 = texAt(base + 9.0);
    vec4 t10 = texAt(base + 10.0);
    vec3 Pform = posDecode(mix(t5, t8, fsel), mix(t6, t9, fsel));
    vec3 Nform = mix(t7, t10, fsel).rgb * 2.0 - 1.0;
    // keep the baked form normal in the same hemisphere as N3: a mix through
    // zero would make Nm (and dirW, and the local push along it) flip in one
    // frame for a dot whose two normals are nearly opposite
    if (dot(N3, Nform) < 0.0) Nform = -Nform;

    float xm = morphX(t);
    // stagger: lobe 0 leads, lobe 2 trails, so the morph travels round the knot
    float hstag = (0.0 * w0 + 0.5 * w1 + 1.0 * w2) / wsum;
    float sm = smootherstep01((xm - STAGGER * hstag) / (1.0 - STAGGER));

    vec3 Pm = mix(P, Pform, sm);
    vec3 Nm = normalize(mix(N3, Nform, sm));
    // both fades go to neutral as the point reaches the form
    occl2 *= (1.0 - sm);
    crowd = mix(crowd, 1.0, sm);

    vec3 er = normalize(vec3(Pm.x, Pm.y, 0.0));
    // er * 0.8 + Nm * 0.45 goes through zero if the blended normal turns almost
    // antiparallel to er mid morph (dirW would flip in one frame); fall back
    // to er there, the magnitude is the same either way
    vec3 dw = er * 0.8 + Nm * 0.45;
    vec3 dirW = length(dw) < 0.15 ? er : normalize(dw);

    // ---- A: quiet global pose, no yaw, 0.8 percent scale pulse ----------
    float pitch = radians(1.6) * (sin(TAU * t / 71.0 + 0.7)
                + 0.5 * sin(TAU * t / 97.0 + 2.1)) / 1.5;
    float roll = radians(1.6) * (sin(TAU * t / 83.0 + 1.9)
               + 0.5 * sin(TAU * t / 113.0 + 0.4)) / 1.5;

    float br0 = 0.5 - 0.5 * cos(TAU * t / 7.0);
    vec3 Q = Pm * (1.0 + 0.008 * br0);

    // ---- B: three lobes, each on its own clock (9 / 11 / 13 s) ----------
    // slow frequency modulation per lobe clock, plus a small deterministic
    // per point phase offset so a lobe does not pulse as one solid block
    float fm0 = 0.06 * sin(TAU * t / 31.0) + 0.00;
    float fm1 = 0.06 * sin(TAU * t / 38.0 + 2.0) + 0.00;
    float fm2 = 0.06 * sin(TAU * t / 45.0 + 4.0) + 0.00;
    float pp = 0.035 * (fract(sin(pid * 12.9898) * 43758.5453) - 0.5);

    float bl = (w0 * breathAt(t, 0.00 + fm0 + pp, 9.0)
              + w1 * breathAt(t, 0.37 + fm1 + pp, 11.0)
              + w2 * breathAt(t, 0.71 + fm2 + pp, 13.0)) / wsum;
    float lb = 2.0 * bl - 1.0;

    // ---- C: peristaltic fronts along the strand (u) ---------------------
    float g;
    if (cls < 0.5) {
        g = frontG(su, 0.10, 1.0, 11.0, t)
          + frontG(su, 0.60, -1.0, 15.0, t);
    } else {
        g = 0.5 * (frontG(su, 0.20, 1.0, 12.0, t)
                 + frontG(su, 0.60, -1.0, 16.0, t));
    }
    // only 60 percent of the strand envelope reaches the front, clamp 0.5 .. 1.5
    float env = envU(su, t);
    g *= clamp(mix(1.0, env, 0.6), 0.5, 1.5);
    // two fronts meeting must not double the bulge (and its speed)
    g = g * inversesqrt(1.0 + (g / 1.5) * (g / 1.5));
    // tube radius in knot units (ribbon 20, ring 5.5), for the thickness terms
    float rr = cls < 0.5 ? 20.0 : 5.5;

    // ---- D: curl-noise micro-currents -----------------------------------
    vec3 vel = curlA(Pm / 55.0, t);
    vec3 dD = vel * (R * 0.022 * env);
    float dl0 = length(dD);
    float dlim = R * 0.025;
    // R4: saturate the curl with tanh, not the exponential cap used before.
    // The curl field is driven 4 to 5 times past the knee (about half of the
    // dots sit on the plateau), and the exponential cap still has 1.4 percent
    // slope out there, so where the field dips near a critical point the
    // plateau ends in a one frame step in speed (measured 0.39 px/frame^2 on
    // one ring dot). tanh's plateau is flat (sech^2 < 1e-3 above 4x) and its
    // shoulder is smooth, which brings the same measurement to 0.11.
    float u0 = clamp(dl0 / dlim, 0.0, 20.0);
    dD *= dlim * (1.0 - 2.0 / (exp(2.0 * u0) + 1.0)) / max(dl0, 1e-4);

    // ---- E: local events, a ring travelling away from a hashed point ----
    float ev = 0.0;
    for (int j = 0; j < 2; j++) {
        float L = j == 0 ? 9.0 : 13.0;
        float off = j == 0 ? 0.0 : 2.9;
        float tt = t + off;
        float ei = floor(tt / L);
        float age = tt - ei * L;
        float s0 = fract(sin(ei * 12.9898 + float(j) * 78.233) * 43758.5453);
        float d = abs(fract(su - s0 + 0.5) - 0.5);
        float front = age * 0.05;
        float x = (d - front) / 0.10;
        float r = exp(-x * x) * smoothstep(0.0, 3.0, age) * exp(-age / 3.0)
                * (1.0 - smoothstep(0.6 * L, L, age));   // gone before the slot restarts
        ev = max(ev, r);
    }
    float evK = cls < 0.5 ? 1.0 : 0.5;   // the ring moves at half amplitude

    // ---- sum the local terms, soft limited at 4 percent of R ------------
    // B: lobe scale about the centre plus lobe THICKNESS (dots along Nm)
    // C/E: bulge = tube swell along Nm + push along dirW
    float ringK = cls < 0.5 ? 1.0 : 0.5;
    vec3 dloc = vec3(Pm.x, Pm.y, 0.0) * (0.010 * lb)
              + Nm * (rr * 0.32 * lb)
              + Nm * (R * 0.022 * g * ringK + R * 0.016 * ev * evK)
              + dirW * (R * 0.014 * g + R * 0.012 * ev * evK)
              + dD;
    float lim = R * 0.04;
    float dl = length(dloc);
    dloc *= lim * (1.0 - exp(-dl / lim)) / max(dl, 1e-4);
    Q += dloc;

    // ---- brightness and size from the same local terms ------------------
    float crest = max(g, 0.0);
    float bfac = (1.0 + 0.08 * lb) * (1.0 + 0.40 * g) * (1.0 + 0.30 * ev * evK);
    float rfac = (1.0 + 0.05 * lb) * (1.0 + 0.18 * crest) * (1.0 + 0.20 * ev * evK);
    bfac = clamp(bfac, 0.60, 1.90);
    rfac = clamp(rfac, 0.75, 1.50);

    // v2 under strand dimming: the weave reads at the three crossings
    rfac = clamp(rfac * (1.0 - 0.25 * occl2), 0.60, 1.80);

    // ---- project: pitch about x, then roll in the screen plane ----------
    float cpt = cos(pitch), spt = sin(pitch);
    float crl = cos(roll), srl = sin(roll);

    float y1 = Q.y * cpt - Q.z * spt;
    float z2 = Q.y * spt + Q.z * cpt;
    float x1 = Q.x;
    float xr = x1 * crl - y1 * srl;
    float yr = x1 * srl + y1 * crl;

    float nz2 = Nm.y * spt + Nm.z * cpt;

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
        // tail only behind the head, ahead of it behind is <= 0 and must give 0
        float tail = behind > 0.0 ? exp(-behind / 0.012) : 0.0;
        // the head is a small cluster of carrier dots, not a solid band
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
    vec2 spos = centre + vec2(xr, yr) * k * (knotPx / KNOT_H);
    vec2 pos = spos + corner * hh;

    v_local = corner * hh;
    v_radius = rpx;
    v_color = vec4(clamp(col, 0.0, 1.0), clamp(alpha, 0.0, 1.0));
    v_pidSmooth = pid;

    gl_Position = qt_Matrix * vec4(pos, 0.0, 1.0);
}
