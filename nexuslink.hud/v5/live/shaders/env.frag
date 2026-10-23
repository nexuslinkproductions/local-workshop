#version 440

// Environment slot, fragment stage. The s10 room (ported from comp-r1/s10 src/a.frag):
// floor reflection of the far wall, wall wash, pilasters, plinth, blast door, instruments,
// MAC GATE and SECTOR 7 labels. No engraving, no sigil, no spark dots (s10 removed them).
// Baked by shaders/env-bake.sh into env.frag.qsb, which Environment.qml loads.
//
// Pixel model: qt_TexCoord0 runs 0..1 over the item, (0,0) top left, y down. The global
// desktop pixel of a fragment is P = ORG + qt_TexCoord0 * R (pixel centres, y down). The room
// is drawn in global desktop pixels, so DP-2 (origin 0,0), DP-1 (origin 2560,0) and HDMI-A-5
// (origin -1920,0) line up into one room.

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

// s10 names (see comp-r1/s10 src/a.frag) mapped onto the block.
#define ORG origin
#define WORLD world
#define R itemSize
#define T t
#define PAR par
#define LINK link
#define AI ai

vec2 envP;  // global desktop pixel of the current fragment, set by shade()

// gl_FragCoord of the s10 shader: pixel of this item measured the way WebGL does (y up),
// folded so that ORG.x + fc.x and R.y - fc.y give the global pixel envP for any origin.
vec4 qtFragCoord() {
    return vec4(envP.x - origin.x, itemSize.y - envP.y, 0.0, 1.0);
}

// BAY[i] for any index (the s10 slot loop uses a runtime index).
float bayAt(int i) {
    if (i == 0) return bayA.x;
    if (i == 1) return bayA.y;
    if (i == 2) return bayA.z;
    if (i == 3) return bayA.w;
    if (i == 4) return bayB.x;
    return bayB.y;
}

// SHADE-BEGIN
// s10 background: s9 minus the wall marks behind the knot. Floor reflection of the far wall kept.
// Takes GLOBAL DESKTOP pixels: p = ORG + fragment, so DP-2 alone (ORG 0,0) and the 3-screen panorama
// (ORG -1920,0) run the same code.
// Camera: vanishing point (1280, 620) near the knot centre. Eye is low: floor 1400 px-units below, ceiling 2250 above (s7 A).
// Units: lateral X in world units (S px at depth 1), heights Y in px at depth 1, Y down. Far wall at depth ZW is frontal, so its marks are drawn in screen px.
// Uniforms with live data: LINK (Mac rtt ms), AI (0..1), BAY[6] crew slots, DISK[2] used share.
const float CX = 1280.0, YH = 620.0, S = 260.0, KF = 1400.0, KC = 2250.0, ZW = 4.4, XR = 11.0;
const float WT = KC / ZW, WB = KF / ZW, WH = XR * S / ZW;   // far wall: 511 px above the eye line, 318 below, 650 either side (s7 A)
const float TG = 1.2, IG = 1.8, MG = 1.5;
const vec3 ICE = vec3(0.56, 0.85, 0.91), ACID = vec3(0.78, 0.95, 0.11), AMB = vec3(1.0, 0.71, 0.33);

float h21(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float vn(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
  return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y); }
float disc(vec2 d, float r){ return 1.0 - smoothstep(r - 0.6, r + 0.6, length(d)); }
float ln(float dpx, float w){ return 1.0 - smoothstep(0.5 * w, 0.5 * w + 1.0, dpx); }
float box(vec2 d, vec2 h){ vec2 q = abs(d) - h; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0); }
float slotBay(int j){ return (j >= 0 && j < 6) ? bayAt(j) : 0.0; }
float sdSeg(vec2 p, vec2 a, vec2 b){ vec2 pa = p - a, ba = b - a; float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0); return length(pa - ba * h); }
vec2 sp(float X, float Y, float z){ return vec2(CX + X * S / z, YH + Y / z); }       // world to desktop px

// ---- hanging bars: soft tube, two rods up to the ceiling. Returns light. Same call with negative height gives the floor image ----
vec3 bar(vec2 p, float X, float Yb, float z0, float z1){
  vec2 a = sp(X, -Yb, z0), b = sp(X, -Yb, z1); float d = sdSeg(p, a, b);
  float core = ln(d, 3.2) * 0.60 + exp(-d * d / 50.0) * 0.045;
  float r0 = ln(abs(p.x - a.x), 1.4) * step(YH - KC / z0, p.y) * step(p.y, a.y);
  float r1 = ln(abs(p.x - b.x), 1.4) * step(YH - KC / z1, p.y) * step(p.y, b.y);
  return vec3(core, (r0 + r1) * 0.05 + 0.03 * ln(d, 9.0), 0.0);
}

// ---- far wall: everything on it in desktop px. Returns tone, ink, instruments through out parameters ----
void farWall(vec2 p, out float tone, out float ink, out vec3 mk, out float met){
  float wx = p.x - CX, wy = p.y - YH, top = wy + WT;                              // top: 0 at the wall head, 791 at the floor
  tone = 0.030; ink = 0.0; mk = vec3(0.0); met = 0.0;
  float edge = smoothstep(0.0, 26.0, WH - abs(wx));
  // board-formed micro-cement: horizontal boards 62 px, per-board tone, long grain
  float bi = floor(top / 62.0), bf = top / 62.0 - bi;
  tone += (h21(vec2(bi, 3.1)) - 0.5) * 0.007 - 0.006 * (1.0 - smoothstep(0.0, 0.05, bf)) + (vn(vec2(wx / 210.0 + bi * 7.0, top / 3.0)) - 0.5) * 0.007;
  tone *= mix(0.55, 1.0, smoothstep(0.0, 300.0, top)) * mix(0.8, 1.0, smoothstep(0.0, 120.0, WT + WB - top));       // light falls off toward the head, floor bounce lifts the foot
  tone += 0.016 * exp(-pow((wy + 130.0) / 330.0, 2.0)) * exp(-pow(wx / 520.0, 2.0));                              // broad wall wash behind the knot, no hard shape
  tone += 0.004 * exp(-pow((wy + 70.0) / 260.0, 2.0)) * exp(-pow(wx / 300.0, 2.0));                               // faint vertical falloff behind the knot centre, about 6 percent of the wall there
  // pilasters: two per side, carry the wall up to the head; face lit, right flank in shadow
  float pw = 0.0;
  for (int i = 0; i < 2; i++){ float pc = i == 0 ? 352.0 : 640.0; float u = abs(wx) - pc; float sd = sign(wx);
    float face = ln(abs(u), 30.0); pw = max(pw, face);
    ink += 0.020 * ln(abs(abs(u) - 15.0), 1.2); tone -= 0.008 * ln(abs(u + 21.0 * sd * -1.0), 12.0) * 0.0; }
  tone += 0.016 * pw; ink += 0.016 * pw * (0.5 + 0.5 * sin(top * 0.9)) * 0.0;
  // head: smoked glass strip with LED seam and the hairline of the carbon ceiling above
  float gl = ln(abs(top - 24.0), 22.0); tone = mix(tone, 0.016 + 0.004 * vn(vec2(wx / 90.0, top / 9.0)), gl * 0.85);
  ink += 0.050 * ln(abs(top - 36.0), 1.5) + 0.016 * ln(abs(top - 12.0), 1.0);
  // plinth: brushed graphite panels, 130 px wide, hairline joints and a bevel lip
  float pl = smoothstep(0.0, 1.5, top - (WT + WB - 28.0));
  float px = floor(wx / 130.0);
  float brushed = (vn(vec2(wx / 70.0, top * 1.3)) - 0.5) * 0.012;
  tone = mix(tone, 0.034 + brushed + (h21(vec2(px, 9.0)) - 0.5) * 0.006, pl * edge); met = max(met, pl);
  ink += 0.040 * ln(abs(top - (WT + WB - 28.0)), 1.3) + 0.030 * ln(abs(fract(wx / 130.0 + 0.5) - 0.5) * 130.0, 1.0) * pl;
  ink += 0.012 * ln(abs(top - (WT + WB - 16.0)), 1.0);
  // blast door in the left bay: frame, two leaves, seam, lamp and 12 cell strip on the right jamb
  float rtt = LINK; bool linkUp = rtt < 100.0; vec3 linkC = linkUp ? ACID : AMB; vec3 coreC = linkUp ? ICE : AMB;
  vec2 dc = vec2(wx + 496.0, wy + 60.0);                                          // door centre, 170 x 348, moved up to sit on the 2.2x wall
  float dd = box(dc, vec2(85.0, 174.0));
  if (dd < 0.0){ tone = mix(tone, 0.038 + (vn(vec2(wx / 60.0, top * 1.1)) - 0.5) * 0.010, 0.9); met = max(met, 0.8); ink += 0.045 * ln(abs(dc.x), 1.6); ink += 0.014 * ln(abs(fract((dc.y + 40.0) / 64.0) - 0.5) * 64.0, 1.0); }
  ink += 0.090 * ln(abs(dd - 4.0), 5.0);
  tone -= 0.012 * (1.0 - smoothstep(0.0, 14.0, dd)) * step(0.0, dd);                // reveal shadow around the frame
  float sx = wx + 396.0;                                                          // jamb x
  float cv = (wy - 20.0) / 24.0; float ci = floor(cv), cf = fract(cv);
  float cellOn = ln(abs(sx), 8.0) * smoothstep(0.12, 0.2, cf) * smoothstep(0.88, 0.8, cf) * step(0.0, cv) * step(cv, 12.0);
  vec3 cc = ci >= 10.0 ? AMB : ICE;
  mk += cellOn * cc * (ci < ceil(rtt / 2.0) ? 0.30 : 0.045);                       // one cell per 2 ms, amber from 20 ms
  mk += disc(vec2(sx, wy - 2.0), 3.6) * linkC * 0.8;                                // door lamp
  // conduit stub: the Mac cable meets the door on its left flank
  float cu = abs(wy - 98.0); mk += coreC * 0.07 * (1.0 - smoothstep(1.5, 3.5, cu)) * step(wx, -581.0) * step(-650.0, wx); ink += 0.05 * ln(abs(cu - 4.0), 1.2) * step(wx, -581.0);
  // crew slots: three per flank bay above the door and mirrored, inner to outer, alternating left and right
  float m = abs(wx); float sl = floor((m - 397.0) / 66.0 + 0.5); float sc = 430.0 + 66.0 * sl; // nearest of 430, 496, 562 (clamped below)
  float inB = step(0.0, sl) * step(sl, 2.0); int slot = int(sl * 2.0 + (wx > 0.0 ? 1.0 : 0.0) + 0.5);
  float w = inB > 0.5 ? slotBay(slot) : 0.0; float sxl = m - sc;
  float up = clamp(-(wy + 224.0) / 140.0, 0.0, 1.0);                               // washer: light rises from the lamp up the wall, fades by 140 px
  tone += 0.040 * w * exp(-sxl * sxl / 260.0) * up * (1.0 - up * 0.6) * step(wy, -224.0) * inB * 1.6;
  ink += 0.030 * ln(abs(sxl), 5.0) * step(wy, -224.0) * step(-300.0, wy) * inB;
  mk += disc(vec2(sxl, wy + 218.0), 2.9) * inB * (w > 0.9 ? ACID * 0.9 : ICE * (0.15 + 0.6 * w) * step(0.01, w));
  tone *= edge; ink *= edge;
}

vec4 shade(vec2 P){
  envP = P;
  vec2 p = vec2(ORG.x + qtFragCoord().x, R.y - qtFragCoord().y);                  // global desktop px, y down (equals P)
  float dx = p.x - CX, dy = p.y - YH;
  float adx = max(abs(dx), 0.5), ady = max(abs(dy), 0.5);
  float zP = dy > 0.0 ? KF / ady : KC / ady, zS = XR * S / adx;                    // floor or ceiling hit, side wall hit
  float z = min(min(zP, zS), ZW);
  float fog = exp(-z * 0.08);
  float Y = dy * z, X = dx * z / S;                                                 // plane coordinates
  float tone = 0.0, ink = 0.0, met = 0.0; vec3 mk = vec3(0.0);
  bool linkUp = LINK < 100.0; vec3 linkC = linkUp ? ACID : AMB; vec3 coreC = linkUp ? ICE : AMB;
  if (ZW <= zP && ZW <= zS){
    farWall(p, tone, ink, mk, met);
  } else if (zS < zP){
    // ---- SIDE WALLS, 1900 above the eye and 1580 below. Pilasters every 0.7 depth units carry the eye up ----
    float zz = z; float pscale = XR * S / (zz * zz);
    float seamAO = smoothstep(0.0, 0.55, 1.0 - abs(Y) / 1900.0 * 0.0 ) ;
    float head = smoothstep(0.0, 140.0 / zz, KC - (-Y));                            // approach to the ceiling
    float flo = smoothstep(0.0, 120.0 / zz, KF - Y);
    float band = 0.5 + 0.5 * cos(6.2832 * zz / 0.7); float pzd = abs(fract(zz / 0.7 + 0.5) - 0.5) * 2.0;   // 0 at pilaster centre
    float board = Y / 150.0; float bi = floor(board), bf = board - bi;
    tone = 0.021 + 0.022 * smoothstep(1.4, 4.4, zz);
    tone += (h21(vec2(bi, floor(zz * 5.0))) - 0.5) * 0.006 - 0.005 * (1.0 - smoothstep(0.0, 0.05, bf)) * smoothstep(1.2, 2.2, zz) + (vn(vec2(zz * 40.0, Y / (6.0 * zz) + bi * 3.0)) - 0.5) * 0.006;
    // pilaster: face lifted, shadow strip beside it, hairline
    if (pzd < 0.30) tone += 0.020; else tone -= tone * 0.32 * smoothstep(0.55, 0.30, pzd);
    ink += 0.050 * ln(abs(pzd - 0.30) * pscale * 0.35, 1.5) * step(zz, ZW - 0.05);
    // light from the three bar groups: spill on the wall at their height and depth
    float sY = 1.0 / zz;
    tone += 0.032 * exp(-pow((Y + 1850.0) / 520.0, 2.0) - pow((zz - 3.0) / 1.3, 2.0));
    tone += 0.030 * exp(-pow((Y + 1350.0) / 430.0, 2.0) - pow((zz - 2.9) / 1.2, 2.0));
    tone += 0.022 * exp(-pow((Y + 800.0) / 380.0, 2.0) - pow((zz - 3.3) / 1.4, 2.0));
    tone += 0.010 * smoothstep(0.0, 1.0, (Y + 2250.0) / 3650.0);                    // floor bounce, soft
    // plinth: brushed graphite panels with bevel, Y 1180..1580
    float pl = smoothstep(0.0, 1.5 / zz * 0.5, Y - 1000.0) ;
    float pr = Y - 1000.0;
    tone = mix(tone, 0.030 + (vn(vec2(zz * 22.0, Y / (zz * 40.0))) - 0.5) * 0.010, pl); met = max(met, pl);
    ink += 0.045 * ln(abs(pr) / zz, 1.3) + 0.030 * ln(abs(fract(zz / 0.35 + 0.5) - 0.5) * pscale * 0.35, 1.0) * pl;
    // smoked glass strips with LED seam: two heights
    float g1 = ln(abs(Y + 1500.0) / zz, 54.0 / zz * 1.0) ; tone = mix(tone, 0.014, g1 * 0.8);
        mk += ICE * 0.075 * ln(abs(Y + 1500.0 + 27.0) / zz, 1.6) * smoothstep(1.0, 2.0, zz);
    float g2 = ln(abs(Y + 330.0) / zz, 40.0 / zz); tone = mix(tone, 0.016, g2 * 0.8);
    mk += ICE * 0.050 * ln(abs(Y + 330.0 + 20.0) / zz, 1.4) * smoothstep(1.0, 2.0, zz);
    // expansion seam near head
    ink += 0.018 * ln(abs(Y + 2050.0) / zz, 1.0);
    if (dx < 0.0){
      // Mac link conduit at Y 430, runs to the far wall and meets the door
      float cu = abs(dy - 430.0 / zz); ink += 0.05 * ln(abs(cu - 5.0), 1.2); mk += coreC * 0.07 * (1.0 - smoothstep(1.5, 4.0, cu));
      // decorative vent stack, tall, near the far corner
      float vz = (zz - 3.95) / 0.35; float vin = step(0.0, vz) * step(vz, 1.0);
      float sl2 = abs(fract(Y / 70.0) - 0.5); tone -= tone * 0.55 * vin; ink += 0.028 * vin * ln(sl2 * 70.0 / zz, 1.0);
      ink += 0.040 * ln(abs(vz) * 0.35 * pscale, 1.3) * step(abs(vz - 0.5), 0.52);
    } else {
      // right side: data stack. Slat gaps open with local AI load
      float vz = (zz - 3.4) / 0.8; float vin = step(0.0, vz) * step(vz, 1.0);
      float sl2 = fract(Y / 70.0); float data = step(880.0, Y) * step(Y, 1040.0);
      tone -= tone * 0.55 * vin; ink += 0.028 * vin * ln(abs(sl2 - 0.5) * 70.0 / zz, 1.0);
      ink += 0.040 * ln(abs(vz) * 0.8 * pscale, 1.3) * step(abs(vz - 0.5), 0.52) + 0.040 * ln(abs(vz - 1.0) * 0.8 * pscale, 1.3) * step(abs(vz - 0.5), 0.52);
      float v = (Y - 880.0) / 160.0 * 7.0; float f = fract(v); float fw = 14.0 * zz / (160.0 / 7.0 * 1.0) * 0.0 + 0.12;
      float gap = smoothstep(0.0, fw, f) * smoothstep(AI * 0.8 + fw, AI * 0.8, f);
      mk += ICE * gap * (0.030 + 0.12 * AI) * vin * data;
    }
    tone *= mix(0.9, 1.0, head) ; ink *= head;
  } else {
    // ---- FLOOR (dy > 0) and CEILING (dy < 0) ----
    bool fl = dy > 0.0; float zpx = (fl ? KF : KC) / (z * z), xpx = S / z;
    float ao = mix(0.55, 1.0, smoothstep(0.0, 1.8, XR - abs(X))) * mix(0.60, 1.0, smoothstep(0.0, 1.0, ZW - z));
    if (!fl){
      // carbon lattice ceiling: twill of two diagonal families, 0.5 unit pitch, beams of a gantry below it
      float u1 = abs(fract((X + z) / 0.5) - 0.5), u2 = abs(fract((X - z) / 0.5) - 0.5); float lat = min(u1, u2) * 0.5;
      float fadeL = smoothstep(2.5, 7.0, 0.5 * zpx * 0.35);
      tone = 0.012 + 0.014 * smoothstep(3.0, 4.4, z);
      tone += 0.010 * (1.0 - smoothstep(0.0, 0.05, lat)) * smoothstep(0.0, 1.0, zpx * 0.1);
      tone += 0.0035 * sin((X + z) * 12.57) * sin((X - z) * 12.57);
      ink += 0.020 * ln(lat * min(xpx, 40.0), 1.0) * smoothstep(1.0, 3.0, xpx * 0.5);
      tone *= ao;
    } else {
      // resin floor: dark, glossy, expansion joints only on a coarse grid, centre seam
      tone = 0.026 + 0.020 * smoothstep(0.0, 1.0, 1.0 - abs(z - ZW) / 3.0);
      float jz = abs(fract(z / 1.1 + 0.5) - 0.5) * 1.1;
      ink += 0.014 * ln(jz * zpx, 1.0) * smoothstep(2.0, 6.0, 1.1 * zpx) * ao;
      ink += 0.012 * ln(abs(X) * xpx, 1.0) * ao;
      // gloss lanes under the hanging bars, soft
      tone += 0.0085 * (exp(-pow((abs(X) - 4.2) / 0.5, 2.0)) + 0.8 * exp(-pow((abs(X) - 7.0) / 0.6, 2.0))) * smoothstep(1.6, 3.2, z);
      tone += (vn(vec2(X * 0.7, z * 1.4)) - 0.5) * 0.006;
      // reflection of the lower far wall in the resin: vertical flip about the floor line, fades with distance from it
      float yj = YH + WB; float fd = (p.y - yj); float rfl = exp(-fd / 260.0) * 0.90;   // 0.90 (s9: 0.60): raised so the reflection keeps its light without the wall marks
      if (fd > 0.0 && fd < 480.0){
        float t2, i2, m2; vec3 k2; float mm; float t3, i3; vec3 k3; float mm3;
        farWall(vec2(p.x, yj - fd), t2, i2, k2, mm);
        farWall(vec2(p.x, yj - fd * 1.04 - 6.0), t3, i3, k3, mm3);
        tone += 0.5 * (t2 + t3) * 0.5 * rfl * 0.7; ink += (i2 + i3) * 0.5 * rfl; mk += (k2 + k3) * 0.5 * rfl * 0.9;
      }
      // cable trenches at |X| = 6.2: right = root disk, left = second disk. Gauge fill runs from the hatch toward the far wall.
      float tx = abs(abs(X) - 6.2); bool right = X > 0.0; float used = right ? disk.x : disk.y;
      float z0 = 2.0; float inT = step(z0, z) * step(z, ZW - 0.05);
      float fillEnd = z0 + (ZW - z0) * used;
      tone -= tone * 0.8 * (1.0 - smoothstep(0.30, 0.30 + 1.0 / xpx, tx)) * inT;
      ink += 0.060 * ln(abs(tx - 0.32) * xpx, 1.4) * inT * ao;
      float gg = ln(tx * xpx, min(4.0, 0.11 * xpx));
      vec3 gc = (!right && used > 0.8) ? AMB : ICE;
      mk += gc * gg * inT * (z < fillEnd ? 0.24 : 0.045) * ao;
      mk += gc * gg * inT * ln(abs(z - fillEnd) * zpx, 2.5) * 0.20;
      mk += gc * 0.34 * disc(vec2(tx * xpx, (z - z0) * zpx), 3.8);
    }
  }
  // ---- overhead structure and lights, in front of every surface: gantry rails, two bridges, trolley, three bar groups with rods ----
  vec3 lt = vec3(0.0); float bm = 0.0;
  for (int i = 0; i < 2; i++){
    float sg = i == 0 ? -1.0 : 1.0;
    // gantry rails along the depth axis under the ceiling
    vec2 ra = sp(sg * 8.4, -2190.0, 1.4), rb = sp(sg * 8.4, -2190.0, ZW);
    float dr = sdSeg(p, ra, rb); ink += 0.070 * ln(dr, 4.0); tone += 0.010 * ln(dr, 9.0);
    // bar groups: top 1600 at X 5.0 (z 1.9 to 4.1), middle 1050 at X 7.4 (z 1.6 to 3.9), low 500 at X 9.6 (z 1.4 to 3.4)
    vec3 b1 = bar(p, sg * 5.0, 1850.0, 2.2, 4.1), b2 = bar(p, sg * 7.4, 1350.0, 1.7, 3.9), b3 = bar(p, sg * 9.6, 800.0, 1.4, 3.4);
    lt += vec3(b1.x, b2.x, b3.x); ink += (b1.y + b2.y + b3.y);
  }
  // bridges across the hall at depth 3.55 and 4.1 under the ceiling, with a trolley on the near one
  for (int k = 0; k < 2; k++){
    float bz = k == 0 ? 3.55 : 4.1; float by = YH - 2190.0 / bz; float bw = 8.4 * S / bz;
    float inb = step(abs(dx), bw) * step(by - 0.0, p.y) * step(p.y, by + 74.0 / bz * 0.5 * 2.0);
    tone += 0.022 * inb; ink += 0.090 * ln(abs(p.y - by - 0.5), 1.4) * step(abs(dx), bw); ink += 0.035 * ln(abs(p.y - by - 74.0 / bz), 1.2) * step(abs(dx), bw);
    mk += ICE * 0.12 * ln(abs(p.y - by - 74.0 / bz * 0.5), 1.8) * step(abs(dx), bw) * 0.0;
    if (k == 0){ float tr = box(vec2(dx - 330.0, p.y - by - 16.0), vec2(26.0, 16.0)); tone += 0.030 * (1.0 - smoothstep(0.0, 1.0, tr)); ink += 0.06 * ln(abs(tr), 1.2); }
  }
  tone += 0.0;
  tone *= TG; ink *= IG; mk *= MG;
  float bright = lt.x * 0.62 + lt.y * 0.52 + lt.z * 0.40;
  vec3 tint = mix(vec3(0.60, 0.88, 1.0), vec3(0.80, 0.88, 0.95), met);
  vec3 col = vec3(0.015, 0.021, 0.029) + tone * tint + (ink * ICE + mk) * mix(0.62, 1.0, fog) + bright * vec3(0.62, 0.84, 0.95);
  float band2 = exp(-pow(dy / 120.0, 2.0)) * (0.5 + 0.5 * vn(p / vec2(900.0, 300.0) + vec2(T * 0.006, 0.0)));   // faint haze at eye level
  col += 0.004 * band2 * tint;
  float nz = vn(p / 640.0 + vec2(T * 0.008, 0.0)) * 0.65 + vn(p / 230.0 - vec2(0.0, T * 0.012)) * 0.35; col += (nz - 0.5) * 0.010 * tint;
  vec2 v = (p - vec2(1280.0, 720.0)) / vec2(1280.0, 720.0); v *= vec2(0.85, 1.0);
  col *= 1.0 - 0.38 * pow(clamp(dot(v, v) * 0.55, 0.0, 1.0), 1.2);
  col += (h21(p + fract(T)) - 0.5) / 255.0 * 1.6;
  return vec4(col, 1.0);
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
