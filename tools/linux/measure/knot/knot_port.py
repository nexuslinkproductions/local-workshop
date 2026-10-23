#!/usr/bin/env python3
"""knot_port.py: numpy port of the knot vertex math, round 4 (KNOT-SPEC-R4).

Mirrors every term of nexuslink.hud/v5/live/shaders/knot.vert: the global pose
(pitch and roll only, no yaw), the 7 s scale pulse, the three lobe thickness
clocks, the travelling fronts, the curl currents, the local events, the
summed local limiter at 4 percent of R, and the morph between the triquetra
and the two baked alternate forms.

Default read path is knot-points4.png: 11 texels per point, 16 bit xyz,
normal, s/q/cls, (u, occl, crowd), then form 1 (P, N) in texels 5..7 and
form 2 (P, N) in texels 8..10.

Same numbers as the shader: P in knot units, R = 450 units, knotPx 540 over
a 700x700 item, camera 2.7 * 900, 1 unit = 0.6 px at knotPx 540 before the
perspective factor k. Screen space: x right, y down, (350, 350) is the centre.

CLI: python3 knot_port.py [--t 1.5] [--json] [--tex PATH]
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
DEFAULT_TEX = SHADER_DIR + "/knot-points4.png"
V3_TEX = SHADER_DIR + "/knot-points3.png"

# morph schedule, mirrors CYC / HOLD_A / LEG / HOLD_B / STAGGER in knot.vert
CYC = 60.0
HOLD_A = 33.0
LEG = 12.0
HOLD_B = 3.0
STAGGER = 0.20
FORM_HOLD = HOLD_A + LEG + HOLD_B


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def smootherstep(x):
    e = np.clip(np.asarray(x, dtype=np.float64), 0.0, 1.0)
    return e * e * e * (e * (6.0 * e - 15.0) + 10.0)


def fract(x):
    return x - np.floor(x)


def breath_at(tt, ph, period):
    """One sine eased breath cycle per period, smooth both ways."""
    return 0.5 - 0.5 * np.cos(TAU * np.mod(np.asarray(tt, dtype=np.float64)
                                           / period + ph, 1.0))


def angdiff(a, b):
    return np.mod(a - b + PI, TAU) - PI


def hash01(x):
    h = np.sin(np.asarray(x, dtype=np.float64) * 12.9898) * 43758.5453
    return fract(h)


def morph_x(tt):
    """Morph weight 0..1 of the whole knot at time tt (shader morphX)."""
    tau = (tt / CYC % 1.0) * CYC
    if tau < HOLD_A:
        return 0.0
    if tau < HOLD_A + LEG:
        return (tau - HOLD_A) / LEG
    if tau < HOLD_A + LEG + HOLD_B:
        return 1.0
    return 1.0 - (tau - HOLD_A - LEG - HOLD_B) / LEG


def unit(v):
    ln = np.linalg.norm(v, axis=1, keepdims=True)
    ln[ln < 1e-9] = 1.0
    return v / ln


class KnotPort:
    """CPU port of the vertex stage. Pure numpy, no GPU, no Qt."""

    # ---- section 2 constants (round 4) ---------------------------------
    LOBE_ANG = tuple(math.radians(a) for a in (34.0, 142.4, 266.4))
    LOBE_T = (9.0, 11.0, 13.0)
    LOBE_PH = (0.00, 0.37, 0.71)
    LOBE_W = 0.55
    LOBE_AMP = 0.010
    LOBE_THICK = 0.32
    RR_RIBBON = 20.0
    RR_RING = 5.5
    LOBE_FM = 0.06
    LOBE_FM_T = (31.0, 38.0, 45.0)
    LOBE_PT_AMP = 0.035
    C_T = (11.0, 15.0)
    C_DIR = (1.0, -1.0)
    C_OFF = (0.10, 0.60)
    C_W = 0.10
    C_TROUGH = 0.09
    C_TROUGH_K = 0.15
    C_SW = 0.028
    C_PUSH = 0.014
    C_ENV_MIX = 0.6
    CR_T = (12.0, 16.0)
    CR_DIR = (1.0, -1.0)
    CR_OFF = (0.25, 0.70)
    D_SCALE = 35.0
    D_STEP = 0.05
    # B2c: curl gain 0.022 -> 0.002 and spatial scale 55 -> 35 (see knot.vert).
    # At 0.022 the curl alone moved the dot centroid 6.3 px in x; the drift of
    # a term that small is not worth 3 px of sideways sway of the whole knot.
    D_GAIN = 0.002
    D_AMP = 0.025
    E_L = (9.0, 13.0)
    E_OFF = (0.0, 2.9)
    E_SPEED = 0.05
    E_W = 0.10
    E_RISE = 3.0
    E_SW = 0.016
    E_PUSH = 0.012
    E_RING_AMP = 0.5
    SPARK_LAP = (14.0, 19.0, 26.0, 18.0, 31.0)
    SPARK_DIR = (1.0, -1.0, 1.0, 1.0, -1.0)
    SPARK_CLS = (0, 0, 0, 1, 1)
    SPARK_OFF = (0.05, 0.42, 0.77, 0.28, 0.66)
    SPARK_HEAD = 0.002
    SPARK_CARRIER = 0.33
    SPARK_TAIL = 0.012
    YAW_AMP = 0.0
    PITCH_AMP = math.radians(1.6)
    ROLL_AMP = math.radians(1.6)
    # roll pivot: the dot centroid of the BASE pose (triquetra, all 4384 dots)
    # in screen px from the item centre at knotPx 540, pitch 0, roll 0, scale
    # pulse 1. Rolling about the knot centre instead swept the whole dot
    # centroid 1.2 px sideways. Same two numbers are hard coded in knot.vert
    # (ROLL_PIVOT_PX); __init__ asserts this file's own measurement of the
    # texture matches them within 0.2 px.
    PIVOT_PX = (-4.203, 35.411)
    SCALE_AMP = 0.008
    SCALE_T = 7.0
    B_LB, B_G, B_EV = 0.08, 0.40, 0.30
    R_LB, R_G, R_EV = 0.05, 0.18, 0.20

    def __init__(self, tex=DEFAULT_TEX, n=4384, width=2048, rows=24,
                 texels_per_point=11, knot_px=540.0, w=700.0, h=700.0,
                 soft_limit=True, local_limit_pct=4.0, limit_mode="exp"):
        self.tex = tex
        self.n = int(n)
        self.width = int(width)
        self.rows = int(rows)
        self.tpp = int(texels_per_point)
        self.knot_px = float(knot_px)
        self.w = float(w)
        self.h = float(h)
        self.soft_limit = bool(soft_limit)
        self.limit_mode = limit_mode
        self.local_limit_pct = float(local_limit_pct)
        self.has_morph = self.tpp >= 11
        self.lim = R_KNOT * self.local_limit_pct / 100.0
        self._load()

    def _texels(self, idx):
        idx = np.asarray(idx, dtype=np.int64)
        return self._img[np.floor_divide(idx, self.width),
                         np.mod(idx, self.width), :].astype(np.float64) / 255.0

    def _load(self):
        n, tpp = self.n, self.tpp
        im = Image.open(self.tex).convert("RGB")
        self._img = np.asarray(im, dtype=np.uint8)
        self.tex_size = im.size
        idx = (np.arange(n, dtype=np.int64)[:, None] * tpp
               + np.arange(tpp, dtype=np.int64)[None, :])
        q = np.floor(self._texels(idx) * 255.0 + 0.5)

        def dec(a, b):
            p = np.empty((n, 3))
            p[:, 0] = a[:, 0] * 256.0 + a[:, 1]
            p[:, 1] = a[:, 2] * 256.0 + b[:, 0]
            p[:, 2] = b[:, 1] * 256.0 + b[:, 2]
            return p / 65535.0 * 1024.0 - 512.0

        self.P = dec(q[:, 0], q[:, 1])
        self.N3 = q[:, 2] / 255.0 * 2.0 - 1.0
        self.s = q[:, 3, 0] / 255.0
        self.q_thr = q[:, 3, 1] / 255.0
        self.cls = np.rint(q[:, 3, 2] / 255.0).astype(np.int32)
        self.u = q[:, 4, 0] / 255.0
        self.occl = q[:, 4, 1] / 255.0
        self.crowd = q[:, 4, 2] / 255.0
        if self.has_morph:
            self.P1 = dec(q[:, 5], q[:, 6])
            self.P2 = dec(q[:, 8], q[:, 9])
            # same hemisphere as N3, so the mix never passes through zero
            n1 = unit(q[:, 7] / 255.0 * 2.0 - 1.0)
            n2 = unit(q[:, 10] / 255.0 * 2.0 - 1.0)
            s1 = np.sum(n1 * self.N3, axis=1) < 0.0
            s2 = np.sum(n2 * self.N3, axis=1) < 0.0
            self.N1 = np.where(s1[:, None], -n1, n1)
            self.N2 = np.where(s2[:, None], -n2, n2)
        else:
            self.P1, self.P2 = self.P.copy(), self.P.copy()
            self.N1, self.N2 = self.N3.copy(), self.N3.copy()

        self.ribbon = self.cls == 0
        self.pid = np.arange(n, dtype=np.float64)
        self.ang = np.arctan2(self.P[:, 1], self.P[:, 0])
        self.ph_point = self.LOBE_PT_AMP * (hash01(self.pid * 1.0 + 0.5) - 0.5)
        self.occl2 = np.clip(self.occl * 1.19, 0.0, 1.0)
        self.rr = np.where(self.ribbon, self.RR_RIBBON, self.RR_RING)
        w = np.stack([np.exp(-(angdiff(self.ang, ak) / self.LOBE_W) ** 2)
                      for ak in self.LOBE_ANG], axis=0)
        self.wlobe = w / np.maximum(w.sum(axis=0), 1e-5)
        self.hstag = 0.5 * self.wlobe[1] + 1.0 * self.wlobe[2]
        h = fract(np.sin(self.pid * 78.233 + 1.7) * 43758.5453)
        self.carrier = np.where(h < self.SPARK_CARRIER, 1.0, 0.3)

        # the roll pivot hard coded here (and in knot.vert as ROLL_PIVOT_PX)
        # must still describe THIS texture: measure it again and refuse to run
        # on a mismatch, so a rebaked point set cannot silently drift
        mx, my = self.measure_pivot_px()
        err = max(abs(mx - self.PIVOT_PX[0]), abs(my - self.PIVOT_PX[1]))
        assert err <= 0.2, (
            "roll pivot mismatch: texture centroid (%.3f, %.3f) px vs "
            "PIVOT_PX (%.3f, %.3f) px, err %.3f px > 0.2 (update PIVOT_PX in "
            "knot_port.py and ROLL_PIVOT_PX in knot.vert)"
            % (mx, my, self.PIVOT_PX[0], self.PIVOT_PX[1], err))

    def form_of_cycle(self, t):
        return 1 if int(math.floor(t / CYC)) % 2 == 0 else 2

    def morph_weight(self, t):
        x = morph_x(float(t))
        return x, smootherstep((x - STAGGER * self.hstag) / (1.0 - STAGGER))

    # ---- A: global pose -------------------------------------------------
    def pose(self, t):
        b0 = float(breath_at(t, 0.0, self.SCALE_T))
        pitch = self.PITCH_AMP * (math.sin(TAU * t / 71.0 + 0.7)
                                  + 0.5 * math.sin(TAU * t / 97.0 + 2.1)) / 1.5
        roll = self.ROLL_AMP * (math.sin(TAU * t / 83.0 + 1.9)
                                + 0.5 * math.sin(TAU * t / 113.0 + 0.4)) / 1.5
        return b0, pitch, roll

    def project(self, Q, pitch, roll):
        Q = np.asarray(Q, dtype=np.float64)
        cpt, spt = math.cos(pitch), math.sin(pitch)
        y1 = Q[:, 1] * cpt - Q[:, 2] * spt
        z2 = Q[:, 1] * spt + Q[:, 2] * cpt
        x1 = Q[:, 0]
        k = CAM_D / (CAM_D - z2)
        fs = k * (self.knot_px / KNOT_H)
        # roll in the screen plane about PIVOT_PX, NOT about the item centre:
        # the base pose centroid sits about 35 px below the centre, so a roll
        # about the centre translates the dot centroid sideways by
        # roll * 35 px (1.2 px peak to peak over 0..120 s)
        crl, srl = math.cos(roll), math.sin(roll)
        kp = self.knot_px / 540.0
        pvx, pvy = self.PIVOT_PX[0] * kp, self.PIVOT_PX[1] * kp
        dx = x1 * fs - pvx
        dy = y1 * fs - pvy
        return np.stack([self.w * 0.5 + pvx + dx * crl - dy * srl,
                         self.h * 0.5 + pvy + dx * srl + dy * crl], axis=1)

    def measure_pivot_px(self):
        """Own measurement of the roll pivot from the point texture.

        Mean screen offset from the item centre of all dots of the base pose
        at pitch 0, roll 0, scale pulse 1, knotPx 540. __init__ asserts this
        matches PIVOT_PX (the numbers knot.vert hard codes) to 0.2 px.
        """
        q = self.P
        k = CAM_D / (CAM_D - q[:, 2])
        fs = k * (540.0 / KNOT_H)
        return float(np.mean(q[:, 0] * fs)), float(np.mean(q[:, 1] * fs))

    def env(self, t):
        u = self.u
        e = ((1.0 + 0.65 * np.sin(TAU * 3.0 * u + 0.9))
             * (1.0 + 0.30 * np.sin(TAU * (2.0 * u - t / 29.0) + 2.2))
             * (1.0 + 0.20 * np.sin(TAU * (5.0 * u + t / 37.0) + 4.1)))
        return np.minimum(e, 1.8)

    # ---- B: lobe breathing ----------------------------------------------
    def lobe_phase(self, t):
        ph = np.empty((3, self.n))
        for k, T in enumerate(self.LOBE_T):
            fm = self.LOBE_FM * math.sin(TAU * t / self.LOBE_FM_T[k] + 2.0 * k)
            ph[k] = t / T + self.LOBE_PH[k] + fm + self.ph_point
        return ph

    def term_B(self, t, ctx):
        ph = self.lobe_phase(t)
        bl = np.zeros(self.n)
        for k in range(3):
            bl += self.wlobe[k] * breath_at(ph[k], 0.0, 1.0)
        lb = 2.0 * bl - 1.0
        sc = self.LOBE_AMP * lb
        d = (np.stack([ctx["Pm"][:, 0] * sc, ctx["Pm"][:, 1] * sc,
                       np.zeros(self.n)], axis=1)
             + ctx["Nm"] * (self.rr * self.LOBE_THICK * lb)[:, None])
        return d, lb

    # ---- C: peristaltic fronts ------------------------------------------
    def _front(self, t, T, dirn, off, uu):
        f = fract(off + dirn * t / T)
        d = fract(uu - f + 0.5) - 0.5
        return (np.exp(-(d / self.C_W) ** 2)
                - self.C_TROUGH_K * np.exp(-((d + self.C_TROUGH * dirn)
                                             / self.C_W) ** 2))

    def term_C(self, t, ctx):
        g = np.zeros(self.n)
        ring = ~self.ribbon
        for T, dirn, off in zip(self.C_T, self.C_DIR, self.C_OFF):
            gi = self._front(t, T, dirn, off, self.u)
            g = np.where(self.ribbon, g + gi, g)
        for T, dirn, off in zip(self.CR_T, self.CR_DIR, self.CR_OFF):
            g = np.where(ring, g + 0.5 * self._front(t, T, dirn, off, self.u), g)
        g = g * np.clip(1.0 + self.C_ENV_MIX * (self.env(t) - 1.0), 0.5, 1.5)
        g = g / np.sqrt(1.0 + (g / 1.5) ** 2)
        ring_k = np.where(self.ribbon, 1.0, 0.5)
        d = (ctx["Nm"] * (R_KNOT * self.C_SW * g * ring_k)[:, None]
             + ctx["dirW"] * (R_KNOT * self.C_PUSH * g)[:, None])
        return d, g

    # ---- D: curl noise ---------------------------------------------------
    @staticmethod
    def _potential(p, t):
        px, py, pz = p[:, 0], p[:, 1], p[:, 2]
        a1 = np.sin(1.3 * py + 0.8 * np.sin(0.7 * pz + 0.21 * t) + 0.31 * t)
        a2 = np.sin(1.1 * pz + 0.6 * np.sin(0.9 * px + 0.17 * t) + 0.27 * t + 2.0)
        a3 = np.sin(1.2 * px + 0.7 * np.sin(0.8 * py + 0.23 * t) + 0.24 * t + 4.0)
        return np.stack([a1, a2, a3], axis=1)

    def term_D(self, t, ctx):
        p = ctx["Pm"] / self.D_SCALE
        h = self.D_STEP
        ex = np.array([h, 0.0, 0.0])
        ey = np.array([0.0, h, 0.0])
        ez = np.array([0.0, 0.0, h])
        dA_dz = (self._potential(p + ez, t) - self._potential(p - ez, t)) / (2.0 * h)
        dA_dy = (self._potential(p + ey, t) - self._potential(p - ey, t)) / (2.0 * h)
        dA_dx = (self._potential(p + ex, t) - self._potential(p - ex, t)) / (2.0 * h)
        V = np.stack([dA_dy[:, 2] - dA_dz[:, 1],
                      dA_dz[:, 0] - dA_dx[:, 2],
                      dA_dx[:, 1] - dA_dy[:, 0]], axis=1)
        disp = V * (R_KNOT * self.D_GAIN * self.env(t))[:, None]
        cap = R_KNOT * self.D_AMP
        ln = np.linalg.norm(disp, axis=1)
        # same tanh saturation as knot.vert (R4 fix): the exp cap left a
        # 1.4 percent slope on the plateau, which made a one frame speed step
        # where the curl field dips near a critical point
        u0 = np.clip(ln / cap, 0.0, 20.0)
        sc = cap * (1.0 - 2.0 / (np.exp(2.0 * u0) + 1.0)) / np.maximum(ln, 1e-4)
        return disp * sc[:, None], V

    # ---- E: local events -------------------------------------------------
    def term_E(self, t, ctx):
        r = np.zeros(self.n)
        for j in range(len(self.E_L)):
            L = self.E_L[j]
            age = (t + self.E_OFF[j]) % L
            e = math.floor((t + self.E_OFF[j]) / L)
            h = math.sin(e * 12.9898 + j * 78.233) * 43758.5453
            s0 = h - math.floor(h)
            front = age * self.E_SPEED
            d = np.abs(fract(self.u - s0 + 0.5) - 0.5)
            prof = (np.exp(-((d - front) / self.E_W) ** 2)
                    * float(smoothstep(0.0, self.E_RISE, age))
                    * math.exp(-age / 3.0)
                    * (1.0 - float(smoothstep(0.6 * L, L, age))))
            r = np.maximum(r, prof)
        evk = np.where(self.ribbon, 1.0, self.E_RING_AMP)
        d = (ctx["Nm"] * (R_KNOT * self.E_SW * r * evk)[:, None]
             + ctx["dirW"] * (R_KNOT * self.E_PUSH * r * evk)[:, None])
        return d, r

    def term_F(self, t):
        out = np.zeros(self.n)
        head_w = np.zeros(self.n, dtype=bool)
        for lap, dirn, cls, off in zip(self.SPARK_LAP, self.SPARK_DIR,
                                       self.SPARK_CLS, self.SPARK_OFF):
            hpos = fract(off + dirn * t / lap)
            d = fract(self.u - hpos + 0.5) - 0.5
            behind = -d
            tail = np.where(behind > 0.0, np.exp(-behind / self.SPARK_TAIL), 0.0)
            head = np.exp(-(d / self.SPARK_HEAD) ** 2) * self.carrier
            m = (self.cls == cls)
            out = np.maximum(out, np.where(m, np.maximum(head, 0.55 * tail), 0.0))
            head_w |= m & (head > 0.5)
        return out, head_w

    def _limit(self, dP_raw):
        dl = np.linalg.norm(dP_raw, axis=1)
        if not self.soft_limit or self.limit_mode == "none":
            return dP_raw.copy(), dl
        lim = self.lim
        if self.limit_mode == "exp":
            sc = lim * (1.0 - np.exp(-dl / lim)) / np.maximum(dl, 1e-4)
        else:
            sc = lim * np.tanh(dl / lim) / np.maximum(dl, 1e-6)
        return dP_raw * sc[:, None], dl

    # ---- sample ----------------------------------------------------------
    def sample(self, t, force_hold=False):
        t = float(t)
        b0, pitch, roll = self.pose(t)
        xm, sm = self.morph_weight(t)
        form = self.form_of_cycle(t)
        if force_hold:
            Pform, Nform = self.P, self.N3
            sm = np.zeros(self.n)
            xm = 0.0
        else:
            Pform = self.P1 if form == 1 else self.P2
            Nform = self.N1 if form == 1 else self.N2
        Pm = self.P + (Pform - self.P) * sm[:, None]
        Nm = unit(self.N3 + (Nform - self.N3) * sm[:, None])
        er = unit(np.stack([Pm[:, 0], Pm[:, 1], np.zeros(self.n)], axis=1))
        # er * 0.8 + Nm * 0.45 passes through zero if the blended normal turns
        # almost antiparallel to er mid morph; fall back to er there (the shader
        # has the same guard)
        dw = er * 0.8 + Nm * 0.45
        dwn = np.linalg.norm(dw, axis=1, keepdims=True)
        dirW = np.where(dwn < 0.15, er, dw / np.maximum(dwn, 1e-9))
        occl2 = self.occl2 * (1.0 - sm)
        crowd = self.crowd + (1.0 - self.crowd) * sm

        Qm = Pm * (1.0 + self.SCALE_AMP * b0)
        pos = self.project(Qm, pitch, roll)
        ctx = {"Pm": Pm, "Nm": Nm, "dirW": dirW}
        dB, bl = self.term_B(t, ctx)
        dC, gC = self.term_C(t, ctx)
        dD, V = self.term_D(t, ctx)
        dE, rE = self.term_E(t, ctx)
        terms = {"B": dB, "C": dC, "D": dD, "E": dE}
        dP_raw = dB + dC + dD + dE
        dP, dl = self._limit(dP_raw)
        pos_full = self.project(Qm + dP, pitch, roll)
        out = {"t": t, "morph_x": float(xm), "morph_s": sm, "form": form,
               "breath": b0, "pitch_deg": math.degrees(pitch),
               "roll_deg": math.degrees(roll), "yaw_deg": 0.0,
               "occl2": occl2, "crowd": crowd, "pos": pos,
               "pos_hold": self.project(self.P * (1.0 + self.SCALE_AMP * b0),
                                        pitch, roll),
               "pos_full": pos_full, "local_px": pos_full - pos,
               "local_len": np.linalg.norm(pos_full - pos, axis=1),
               "dP": dP, "dP_raw": dP_raw,
               "dP_len": np.linalg.norm(dP, axis=1), "dP_raw_len": dl,
               "terms": terms, "lobe": bl, "front": gC, "event": rE,
               "terms_px": {k: self.project(Qm + v, pitch, roll) - pos
                            for k, v in terms.items()}}
        out["morph_px"] = pos - out["pos_hold"]
        out["spark"], out["spark_head"] = self.term_F(t)
        lb = bl
        crest = np.maximum(gC, 0.0)
        evk = np.where(self.ribbon, 1.0, self.E_RING_AMP)
        out["radius"] = np.clip(np.clip((1.0 + self.R_LB * lb) * (1.0 + self.R_G * crest)
                                        * (1.0 + self.R_EV * rE * evk), 0.75, 1.50)
                                * (1.0 - 0.25 * occl2), 0.60, 1.80)
        out["bright"] = (np.clip((1.0 + self.B_LB * lb) * (1.0 + self.B_G * gC)
                                 * (1.0 + self.B_EV * rE * evk), 0.60, 1.90)
                         * (1.0 - 0.75 * occl2)
                         * np.clip(1.0 + 0.9 * (crowd - 1.0), 0.0, 2.0))
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--t", type=float, default=0.0)
    ap.add_argument("--tex", default=DEFAULT_TEX)
    ap.add_argument("--tpp", type=int, default=11)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--limit", default="exp", choices=("tanh", "exp", "none"))
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    p = KnotPort(tex=a.tex, texels_per_point=a.tpp, rows=a.rows,
                 limit_mode=a.limit)
    d = p.sample(a.t)
    rep = {"t": d["t"], "n": int(p.n), "tex": a.tex, "tpp": p.tpp,
           "rows": p.rows, "ribbon": int(p.ribbon.sum()),
           "ring": int((~p.ribbon).sum()),
           "yaw_deg": 0.0, "pitch_deg": round(d["pitch_deg"], 4),
           "roll_deg": round(d["roll_deg"], 4),
           "morph_x": round(d["morph_x"], 4), "form": d["form"],
           "morph_s_min": round(float(d["morph_s"].min()), 4),
           "morph_s_max": round(float(d["morph_s"].max()), 4),
           "local_px_mean": round(float(d["local_len"].mean()), 3),
           "local_px_max": round(float(d["local_len"].max()), 3),
           "dP_max_pct_R": round(float(d["dP_len"].max()) / R_KNOT * 100.0, 3),
           "bright_min": round(float(d["bright"].min()), 3),
           "radius_min": round(float(d["radius"].min()), 3)}
    print(json.dumps(rep, indent=1) if a.json else rep)


if __name__ == "__main__":
    main()
