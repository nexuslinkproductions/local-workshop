#!/usr/bin/env python3
"""knot_port.py: numpy port of the knot vertex math, KNOT-SPEC.md plus the
wave 2 addendum v2.1 (KNOT-SPEC-ADD.md).

Default read path is the v2 point texture (knot-points2.png): 5 texels per
point, 16 bit xyz, normal, s, q, cls, then (u, occl, 0) in texel 5. Pass
--tex <knot-points.png> (or texels_per_point=4) for the v1 texture, where u
falls back to s and occl is 1.

Everything is in the same numbers as the shader: P in knot units, R = 450
units, knotPx 540 over a 700x700 item, camera 2.7 * 900, 1 unit = 0.6 px at
knotPx 540 before the perspective factor k. Screen space: x right, y down,
(350, 350) is the item centre.

v2.1 changes against wave 1 (all measured, see KNOT-SPEC-ADD.md):
  - lobe centres at the measured tip angles 34.0, 142.4, 266.4 degrees
  - slow FM on every lobe clock and a small per-point phase offset in the lobe
  - occlusion dimming: occl2 = clamp(occl * 1.19, 0, 1); alpha *= 1 - 0.65 occl2;
    radius *= 1 - 0.25 occl2
  - u (true arc length) for every strand parameter: waves, events, sparks
  - soft limiter on the summed local displacement, L = 0.045 R
    (tanh, the addendum's form; "exp" reproduces the shader's
     lim * (1 - exp(-dl / lim)) / dl variant)

Public API
  port = KnotPort(...)                     # motion="v2" (spec A..F) or "base"
  d = port.sample(t)                       # dict of arrays for one time
  d["pos"]        (N,2) screen px, global pose only, no local terms
  d["pos_full"]   (N,2) screen px, pose plus local terms B..E
  d["local_px"]   (N,2) pos_full - pos, i.e. the local activity in px
  d["local_len"]  (N,)  |local_px|
  d["terms"]      dict "B","C","D","E" -> (N,3) knot-unit displacement
  d["terms_px"]   dict "B","C","D","E" -> (N,2) screen px, each term alone
  d["dP"]         (N,3) sum of B..E in knot units, after the limiter
  d["dP_raw"]     (N,3) same before the limiter
  d["radius"]     (N,)  breathing radius factor, 1 + local radius swell
  d["bright"]     (N,)  brightness factor including occlusion and sparks

CLI: python3 knot_port.py [--t 1.5] [--motion v2|base] [--json] [--tex PATH]
"""

import argparse
import json
import math

import numpy as np
from PIL import Image

PI = math.pi
TAU = 2.0 * math.pi
R_KNOT = 450.0
KNOT_H = 900.0
CAM_D = 2.7 * KNOT_H

SHADER_DIR = ("/home/nexuslink/hud-wt/v5-live/nexuslink.hud/v5/live"
              "/shaders")
DEFAULT_TEX = SHADER_DIR + "/knot-points2-keep.png"
V1_TEX = SHADER_DIR + "/knot-points.png"


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def fract(x):
    return x - np.floor(x)


def breath_at(tt, ph):
    """5.5 s breath, 40 percent inhale, 60 percent exhale, sine eased."""
    u = np.mod(np.asarray(tt, dtype=np.float64) / 5.5 + ph, 1.0)
    inh = 0.5 - 0.5 * np.cos(PI * u / 0.4)
    exh = 0.5 + 0.5 * np.cos(PI * (u - 0.4) / 0.6)
    return np.where(u < 0.4, inh, exh)


def return_gain(tt):
    """Slow wander gain, 12 s return toward front (knot.vert)."""
    w = 0.5 - 0.5 * math.cos(TAU * tt / 12.0)
    return 0.18 + 0.82 * float(smoothstep(0.12, 0.8, w))


def angdiff(a, b):
    return np.mod(a - b + PI, TAU) - PI


def hash01(x):
    """Deterministic 0..1 hash, fract(sin(x * 12.9898) * 43758.5453)."""
    h = np.sin(np.asarray(x, dtype=np.float64) * 12.9898) * 43758.5453
    return fract(h)


class KnotPort:
    """CPU port of the vertex stage. Pure numpy, no GPU, no Qt."""

    # ---- spec B..E constants (v2.1) ------------------------------------
    # measured tip angles (K3), not 90/210/330
    LOBE_ANG = tuple(math.radians(a) for a in (34.0, 142.4, 266.4))
    LOBE_T = (5.0, 6.1, 7.0)
    LOBE_PH = (0.00, 0.37, 0.71)
    LOBE_W = 0.55            # angular width of the lobe weight, radians
    LOBE_AMP = 0.028         # fraction of R, radial, +-7.5 px
    LOBE_FM = 0.06           # cycles, slow frequency modulation depth
    LOBE_FM_T = (31.0, 38.0, 45.0)   # 31 + 7k seconds
    LOBE_PT_AMP = 0.035      # cycles, per point phase offset, +- half
    # C ribbon fronts
    C_T = (4.2, 6.4, 8.6)
    C_DIR = (1.0, -1.0, 1.0)
    C_OFF = (0.10, 0.55, 0.80)
    C_W = 0.045
    C_AMP = 0.016            # fraction of R
    # C ring fronts (port choice: two fronts, half amplitude, own periods)
    CR_T = (7.5, 11.0)
    CR_DIR = (1.0, -1.0)
    CR_OFF = (0.25, 0.70)
    # D curl noise
    D_SCALE = 55.0
    D_STEP = 0.05
    D_AMP = 0.018            # fraction of R, 8 units = 5 px
    D_SWIRL = 0.0            # optional 0.35 rad twist around dirW, off
    # E local events
    E_L = (4.6, 6.3, 8.4)
    E_OFF = (0.0, 1.9, 3.7)
    E_SPEED = 0.055
    E_W = 0.03
    E_AMP = 0.030            # fraction of R
    E_RING_AMP = 0.5
    # F sparks: laps, direction, class
    SPARK_LAP = (14.0, 19.0, 26.0, 18.0, 31.0)
    SPARK_DIR = (1.0, -1.0, 1.0, 1.0, -1.0)
    SPARK_CLS = (0, 0, 0, 1, 1)
    SPARK_OFF = (0.00, 0.37, 0.71, 0.20, 0.63)
    SPARK_HEAD = 0.0035
    SPARK_TAIL = 0.012
    # A global pose
    YAW_AMP = math.radians(12.0)
    PITCH_AMP = math.radians(7.0)
    SCALE_AMP = 0.008

    def __init__(self, tex=DEFAULT_TEX, n=4384, width=2048, rows=11,
                 texels_per_point=5, knot_px=540.0, w=700.0, h=700.0,
                 motion="v2", has_u=None, has_occl=None,
                 soft_limit=True, local_limit_pct=4.5, limit_mode="tanh"):
        self.tex = tex
        self.n = int(n)
        self.width = int(width)
        self.rows = int(rows)
        self.tpp = int(texels_per_point)
        self.knot_px = float(knot_px)
        self.w = float(w)
        self.h = float(h)
        self.motion = motion
        self.soft_limit = bool(soft_limit)
        self.limit_mode = limit_mode
        self.local_limit_pct = float(local_limit_pct)
        self.has_u = (self.tpp >= 5) if has_u is None else bool(has_u)
        self.has_occl = (self.tpp >= 5) if has_occl is None else bool(has_occl)
        self.lim = R_KNOT * self.local_limit_pct / 100.0
        self._load()

    # ---- texture -------------------------------------------------------
    def _texels(self, idx):
        """Nearest-sampled texel fetch, exactly like texAt() in knot.vert."""
        idx = np.asarray(idx, dtype=np.int64)
        px = np.mod(idx, self.width)
        row = np.floor_divide(idx, self.width)
        return self._img[row, px, :].astype(np.float64) / 255.0

    def _load(self):
        n, tpp = self.n, self.tpp
        im = Image.open(self.tex).convert("RGB")
        self._img = np.asarray(im, dtype=np.uint8)
        self.tex_size = im.size
        idx = (np.arange(n, dtype=np.int64)[:, None] * tpp
               + np.arange(tpp, dtype=np.int64)[None, :])
        tex = self._texels(idx)
        # b255 is the byte the PNG stores; float decode then round is the same
        q = np.floor(tex * 255.0 + 0.5)
        t0, t1, t2, t3 = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
        P = np.empty((n, 3))
        P[:, 0] = t0[:, 0] * 256.0 + t0[:, 1]
        P[:, 1] = t0[:, 2] * 256.0 + t1[:, 0]
        P[:, 2] = t1[:, 1] * 256.0 + t1[:, 2]
        self.P = P / 65535.0 * 1024.0 - 512.0
        self.N3 = t2 / 255.0 * 2.0 - 1.0
        self.s = t3[:, 0] / 255.0
        self.q_thr = t3[:, 1] / 255.0
        self.cls = np.rint(t3[:, 2] / 255.0).astype(np.int32)
        if self.has_u:
            t4 = q[:, 4]
            self.u = t4[:, 0] / 255.0
            self.occl = t4[:, 1] / 255.0
        else:
            self.u = self.s.copy()
            self.occl = np.ones(n)
        # er = normalize(vec3(P.x, P.y, 0)); dirW = normalize(er * 0.8 + N * 0.45)
        er = np.stack([self.P[:, 0], self.P[:, 1], np.zeros(n)], axis=1)
        ln = np.linalg.norm(er, axis=1, keepdims=True)
        ln[ln < 1e-9] = 1.0
        self.er = er / ln
        dv = self.er * 0.8 + self.N3 * 0.45
        ln = np.linalg.norm(dv, axis=1, keepdims=True)
        ln[ln < 1e-9] = 1.0
        self.dirW = dv / ln
        self.ang = np.arctan2(self.P[:, 1], self.P[:, 0])
        self.ribbon = self.cls == 0
        self.pid = np.arange(n, dtype=np.float64)
        # v2.1: per point phase offset inside a lobe
        self.ph_point = self.LOBE_PT_AMP * (hash01(self.pid * 1.0 + 0.5) - 0.5)
        # v2.1: occlusion dimming factors
        self.occl2 = np.clip(self.occl * 1.19, 0.0, 1.0)
        self.occl_bright = 1.0 - 0.65 * self.occl2
        self.occl_radius = 1.0 - 0.25 * self.occl2

    # ---- A: global pose -------------------------------------------------
    def pose(self, t):
        if self.motion == "base":
            # original model, work2/base knot.vert: yaw 30, pitch 18,
            # global scale 2 percent, per lobe phase 0 .. 0.07 cycles
            ph = 0.07 * (0.5 - 0.5 * np.cos(3.0 * (self.ang + PI)))
            b = breath_at(t, ph)
            Q = self.P * (1.0 + 0.02 * b)[:, None]
            ny = (math.sin(TAU * t / 31.0) + 0.55 * math.sin(TAU * t / 26.0 + 1.1)
                  + 0.32 * math.sin(TAU * t / 38.0 + 2.3)) / 1.87
            npch = (math.sin(TAU * t / 34.0 + 0.7)
                    + 0.55 * math.sin(TAU * t / 27.5 + 2.1)
                    + 0.32 * math.sin(TAU * t / 39.0 + 4.0)) / 1.87
            gn = return_gain(t)
            yaw = ny * gn * math.radians(30.0)
            pitch = npch * gn * math.radians(18.0)
            return Q, yaw, pitch, b
        b0 = float(breath_at(t, 0.0))
        Q = self.P * (1.0 + self.SCALE_AMP * b0)
        ny = (math.sin(TAU * t / 31.0) + 0.55 * math.sin(TAU * t / 26.0 + 1.1)
              + 0.32 * math.sin(TAU * t / 38.0 + 2.3)) / 1.87
        npch = (math.sin(TAU * t / 34.0 + 0.7)
                + 0.55 * math.sin(TAU * t / 27.5 + 2.1)
                + 0.32 * math.sin(TAU * t / 39.0 + 4.0)) / 1.87
        gn = return_gain(t)
        yaw = ny * gn * self.YAW_AMP
        pitch = npch * gn * self.PITCH_AMP
        return Q, yaw, pitch, b0

    def project(self, Q, t):
        Q = np.asarray(Q, dtype=np.float64)
        _, yaw, pitch, _ = self.pose(t)
        cyw, syw = math.cos(yaw), math.sin(yaw)
        cpt, spt = math.cos(pitch), math.sin(pitch)
        x1 = Q[:, 0] * cyw + Q[:, 2] * syw
        z1 = -Q[:, 0] * syw + Q[:, 2] * cyw
        y1 = Q[:, 1] * cpt - z1 * spt
        z2 = Q[:, 1] * spt + z1 * cpt
        k = CAM_D / (CAM_D - z2)
        # shader: spos = (uW, uH) * 0.5 + vec2(x1, y1) * k * knotPx / KNOT_H
        f = k * (self.knot_px / KNOT_H)
        return np.stack([self.w * 0.5 + x1 * f, self.h * 0.5 + y1 * f], axis=1)

    # ---- B: lobe breathing (v2.1: tip angles, slow FM, per point phase) --
    def lobe_phase(self, t):
        """Lobe clock phase in cycles, (3, N) after the per point offset."""
        ph = np.empty((3, self.n))
        for k, T in enumerate(self.LOBE_T):
            fm = self.LOBE_FM * math.sin(TAU * t / self.LOBE_FM_T[k] + 2.0 * k)
            ph[k] = t / T + self.LOBE_PH[k] + fm + self.ph_point
        return ph

    def term_B(self, t):
        ph = self.lobe_phase(t)
        bl = np.zeros(self.n)
        wsum = np.zeros(self.n)
        for k, ak in enumerate(self.LOBE_ANG):
            wgt = np.exp(-(angdiff(self.ang, ak) / self.LOBE_W) ** 2)
            wsum += wgt
            # breath_at divides by 5.5, so feed 5.5 * phase in cycles
            bl += wgt * breath_at(5.5 * ph[k], 0.0)
        bl = bl / np.maximum(wsum, 1e-9)
        amp = R_KNOT * self.LOBE_AMP * (2.0 * bl - 1.0)
        d = self.er * amp[:, None]
        return d, (2.0 * bl - 1.0)

    # ---- C: peristaltic fronts ------------------------------------------
    def _front(self, t, T, dirn, off, uu):
        f = fract(off + dirn * t / T)
        d = fract(uu - f + 0.5) - 0.5
        return (np.exp(-(d / self.C_W) ** 2)
                - 0.35 * np.exp(-((d + 0.05 * dirn) / self.C_W) ** 2))

    def term_C(self, t):
        g = np.zeros(self.n)
        ring = ~self.ribbon
        for T, dirn, off in zip(self.C_T, self.C_DIR, self.C_OFF):
            gi = self._front(t, T, dirn, off, self.u)
            g = np.where(self.ribbon, g + gi, g)
        for T, dirn, off in zip(self.CR_T, self.CR_DIR, self.CR_OFF):
            g = np.where(ring, g + 0.5 * self._front(t, T, dirn, off, self.u), g)
        amp = R_KNOT * self.C_AMP
        return self.dirW * (amp * g)[:, None], g

    # ---- D: curl noise ---------------------------------------------------
    @staticmethod
    def _potential(p, t):
        px, py, pz = p[:, 0], p[:, 1], p[:, 2]
        a1 = np.sin(1.3 * py + 0.8 * np.sin(0.7 * pz + 0.21 * t) + 0.31 * t)
        a2 = np.sin(1.1 * pz + 0.6 * np.sin(0.9 * px + 0.17 * t)
                    + 0.27 * t + 2.0)
        a3 = np.sin(1.2 * px + 0.7 * np.sin(0.8 * py + 0.23 * t)
                    + 0.24 * t + 4.0)
        return np.stack([a1, a2, a3], axis=1)

    def term_D(self, t):
        p = self.P / self.D_SCALE
        h = self.D_STEP
        ex = np.array([h, 0.0, 0.0])
        ey = np.array([0.0, h, 0.0])
        ez = np.array([0.0, 0.0, h])
        Ap = self._potential(p + ez, t)
        Am = self._potential(p - ez, t)
        dA_dz = (Ap - Am) / (2.0 * h)
        Ap = self._potential(p + ey, t)
        Am = self._potential(p - ey, t)
        dA_dy = (Ap - Am) / (2.0 * h)
        Ap = self._potential(p + ex, t)
        Am = self._potential(p - ex, t)
        dA_dx = (Ap - Am) / (2.0 * h)
        V = np.stack([dA_dy[:, 2] - dA_dz[:, 1],
                      dA_dz[:, 0] - dA_dx[:, 2],
                      dA_dx[:, 1] - dA_dy[:, 0]], axis=1)
        disp = V * (R_KNOT * self.D_AMP / 2.0)
        cap = R_KNOT * self.D_AMP
        ln = np.linalg.norm(disp, axis=1)
        sc = np.where(ln > cap, cap / np.maximum(ln, 1e-12), 1.0)
        disp = disp * sc[:, None]
        if self.D_SWIRL > 0.0:
            disp = self._rot_about_dirW(disp, self.D_SWIRL)
        return disp, V

    def _rot_about_dirW(self, v, th):
        """Rodrigues rotation of v around the per point dirW axis."""
        kax = self.dirW
        c, s = math.cos(th), math.sin(th)
        kv = np.cross(kax, v)
        kd = np.sum(kax * v, axis=1, keepdims=True)
        return v * c + kv * s + kax * kd * (1.0 - c)

    # ---- E: local events -------------------------------------------------
    def term_E(self, t):
        n = self.n
        r = np.zeros(n)
        for j in range(3):
            L = self.E_L[j]
            off = self.E_OFF[j]
            e = math.floor((t + off) / L)
            age = (t + off) - e * L
            h = math.sin(e * 12.9898 + j * 78.233) * 43758.5453
            s0 = h - math.floor(h)
            front = age * self.E_SPEED
            d = np.abs(fract(self.u - s0 + 0.5) - 0.5)
            prof = (np.exp(-((d - front) / self.E_W) ** 2)
                    * float(smoothstep(0.0, 0.25, age)) * math.exp(-age / 2.0))
            prof = np.where(self.ribbon, prof, self.E_RING_AMP * prof)
            r = np.maximum(r, prof)
        amp = R_KNOT * self.E_AMP
        return self.dirW * (amp * r)[:, None], r

    # ---- F: sparks (brightness only, v2.1: tail strictly behind) ---------
    def term_F(self, t):
        """Acid spark intensity 0..1 per point, head plus tail behind it."""
        out = np.zeros(self.n)
        head_w = np.zeros(self.n, dtype=bool)
        for lap, dirn, cls, off in zip(self.SPARK_LAP, self.SPARK_DIR,
                                       self.SPARK_CLS, self.SPARK_OFF):
            hpos = fract(off + dirn * t / lap)
            d = fract(self.u - hpos + 0.5) - 0.5
            behind = -d                       # > 0 only behind the head
            tail = np.where(behind > 0.0,
                            np.exp(-behind / self.SPARK_TAIL), 0.0)
            head = np.exp(-(d / self.SPARK_HEAD) ** 2)
            m = (self.cls == cls)
            v = np.where(m, np.maximum(head, 0.85 * tail), 0.0)
            out = np.maximum(out, v)
            head_w |= m & (head > 0.5)
        return out, head_w

    # ---- limiter ---------------------------------------------------------
    def _limit(self, dP_raw):
        dl = np.linalg.norm(dP_raw, axis=1)
        if not self.soft_limit or self.limit_mode == "none":
            return dP_raw.copy(), dl
        lim = self.lim
        if self.limit_mode == "exp":
            # shader form currently in knot.vert
            sc = lim * (1.0 - np.exp(-dl / lim)) / np.maximum(dl, 1e-4)
        else:
            # addendum v2.1 form: L * tanh(len / L) / len
            sc = lim * np.tanh(dl / lim) / np.maximum(dl, 1e-6)
        return dP_raw * sc[:, None], dl

    # ---- sample ----------------------------------------------------------
    def sample(self, t):
        t = float(t)
        Q, yaw, pitch, b = self.pose(t)
        out = {"t": t, "Q": Q, "yaw_deg": math.degrees(yaw),
               "pitch_deg": math.degrees(pitch), "breath": b}
        if self.motion == "base":
            out["pos"] = self.project(Q, t)
            out["pos_full"] = out["pos"].copy()
            out["local_px"] = np.zeros((self.n, 2))
            out["local_len"] = np.zeros(self.n)
            out["dP"] = np.zeros((self.n, 3))
            out["dP_raw"] = np.zeros((self.n, 3))
            out["dP_len"] = np.zeros(self.n)
            out["dP_raw_len"] = np.zeros(self.n)
            out["dP_exp_len"] = np.zeros(self.n)
            out["terms"] = {}
            out["terms_px"] = {}
            out["radius"] = np.ones(self.n)
            out["bright"] = np.ones(self.n)
            out["spark"] = np.zeros(self.n)
            return out
        dB, bl = self.term_B(t)
        dC, gC = self.term_C(t)
        dD, V = self.term_D(t)
        dE, rE = self.term_E(t)
        terms = {"B": dB, "C": dC, "D": dD, "E": dE}
        dP_raw = dB + dC + dD + dE
        dP, dl = self._limit(dP_raw)
        if self.limit_mode == "exp":
            dP_exp = dP
        else:
            # the shader's current form, for comparison in the report
            lim = self.lim
            dP_exp = dP_raw * (lim * (1.0 - np.exp(-dl / lim))
                               / np.maximum(dl, 1e-4))[:, None]
        pos = self.project(Q, t)
        pos_full = self.project(Q + dP, t)
        out["pos"] = pos
        out["pos_full"] = pos_full
        out["local_px"] = pos_full - pos
        out["local_len"] = np.linalg.norm(out["local_px"], axis=1)
        out["dP"] = dP
        out["dP_raw"] = dP_raw
        out["dP_len"] = np.linalg.norm(dP, axis=1)
        out["dP_raw_len"] = dl
        out["dP_exp_len"] = np.linalg.norm(dP_exp, axis=1)
        out["terms"] = terms
        out["terms_px"] = {k: self.project(Q + v, t) - pos
                           for k, v in terms.items()}
        # shading factors of the local terms plus v2.1 occlusion and sparks
        sB = 2.0 * bl - 1.0
        sp, sp_head = self.term_F(t)
        out["radius"] = ((1.0 + 0.08 * sB) * (1.0 + 0.22 * gC)
                         * (1.0 + 0.35 * rE) * self.occl_radius)
        out["bright"] = ((1.0 + 0.12 * sB) * (1.0 + 0.40 * gC)
                         * (1.0 + 0.50 * rE) * self.occl_bright
                         * (1.0 + 1.5 * sp))
        out["lobe"] = bl
        out["front"] = gC
        out["event"] = rE
        out["curl"] = V
        out["spark"] = sp
        out["spark_head"] = sp_head
        out["occl2"] = self.occl2
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--t", type=float, default=0.0)
    ap.add_argument("--motion", default="v2", choices=("v2", "base"))
    ap.add_argument("--tex", default=DEFAULT_TEX)
    ap.add_argument("--tpp", type=int, default=5,
                    help="texels per point: 5 for v2 (default), 4 for v1")
    ap.add_argument("--rows", type=int, default=11)
    ap.add_argument("--limit", default="tanh", choices=("tanh", "exp", "none"))
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    p = KnotPort(tex=a.tex, motion=a.motion, texels_per_point=a.tpp,
                 rows=a.rows, limit_mode=a.limit)
    d = p.sample(a.t)
    rep = {
        "t": d["t"], "motion": a.motion, "n": int(p.n),
        "tex": a.tex, "texels_per_point": p.tpp,
        "ribbon": int(p.ribbon.sum()), "ring": int((~p.ribbon).sum()),
        "yaw_deg": round(d["yaw_deg"], 4), "pitch_deg": round(d["pitch_deg"], 4),
        "local_px_mean": float(d["local_len"].mean()),
        "local_px_max": float(d["local_len"].max()),
        "dP_max_units": float(d["dP_len"].max()) if "dP_len" in d else 0.0,
        "dP_max_pct_R": (float(d["dP_len"].max()) / R_KNOT * 100.0)
                        if "dP_len" in d else 0.0,
        "dP_raw_max_pct_R": (float(d["dP_raw_len"].max()) / R_KNOT * 100.0)
                            if "dP_raw_len" in d else 0.0,
        "spark_points": int(d["spark_head"].sum()) if "spark_head" in d else 0,
        "bright_min": float(d["bright"].min()),
        "bright_max": float(d["bright"].max()),
        "radius_min": float(d["radius"].min()),
        "radius_max": float(d["radius"].max()),
        "pos_bbox": [float(d["pos"][:, 0].min()), float(d["pos"][:, 0].max()),
                     float(d["pos"][:, 1].min()), float(d["pos"][:, 1].max())],
    }
    print(json.dumps(rep, indent=1) if a.json else rep)


if __name__ == "__main__":
    main()
