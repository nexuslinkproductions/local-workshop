#!/usr/bin/env python3
"""knot_port.py: numpy port of the knot vertex math, KNOT-SPEC.md sections A to F.

Reads the v1 point texture (nexuslink.hud/v5/live/shaders/knot-points.png)
exactly like shaders/knot.vert does: 4 texels per point, 16 bit xyz, normal,
s, q, cls. A v2 texture (5 texels per point, texel 5 = u, occl in r, g) is
read when texels_per_point=5; u is then used instead of s for arc length.

Everything is in the same numbers as the shader: P in knot units, R = 450
units, knotPx 540 over a 700x700 item, camera 2.7 * 900, 1 unit = 0.6 px at
knotPx 540 before the perspective factor k.

Screen space: x right, y down, (350, 350) is the item centre, which is what
the shader's spos does (centre + vec2(x1, y1) * k * knotPx / 900).

Public API
  port = KnotPort(...)                     # motion="v2" (spec A..F) or "base"
  d = port.sample(t)                       # dict of arrays for one time
  d["pos"]        (N,2) screen px, global pose only, no local terms
  d["pos_full"]   (N,2) screen px, pose plus local terms B..E
  d["local_px"]   (N,2) pos_full - pos, i.e. the local activity in px
  d["local_len"]  (N,)  |local_px|
  d["terms"]      dict "B","C","D","E" -> (N,3) knot-unit displacement
  d["terms_px"]   dict "B","C","D","E" -> (N,2) screen px, each term alone
  d["dP"]         (N,3) sum of B..E in knot units, before projection
  d["radius"]     (N,)  breathing radius factor, 1 + local radius swell
  d["bright"]     (N,)  brightness factor

CLI: python3 knot_port.py [--t 1.5] [--motion v2|base] [--json]
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

DEFAULT_TEX = ("/home/nexuslink/hud-wt/v5-live/nexuslink.hud/v5/live"
               "/shaders/knot-points.png")
DEFAULT_META = ("/home/nexuslink/hud-wt/v5-live/nexuslink.hud/v5/live"
                "/shaders/knot-points.meta.json")


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


class KnotPort:
    """CPU port of the vertex stage. Pure numpy, no GPU, no Qt."""

    # spec B..E constants
    LOBE_ANG = (math.radians(90.0), math.radians(210.0), math.radians(330.0))
    LOBE_T = (5.0, 6.1, 7.0)
    LOBE_PH = (0.00, 0.37, 0.71)
    LOBE_W = 0.55            # angular width of the lobe weight, radians
    LOBE_AMP = 0.028         # fraction of R, radial, +-7.5 px
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
    # A global pose
    YAW_AMP = math.radians(12.0)
    PITCH_AMP = math.radians(7.0)
    SCALE_AMP = 0.008

    def __init__(self, tex=DEFAULT_TEX, n=4384, width=2048, rows=9,
                 texels_per_point=4, knot_px=540.0, w=700.0, h=700.0,
                 motion="v2", has_u=None, has_occl=None,
                 soft_limit=True, local_limit_pct=4.5):
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
        self.local_limit_pct = float(local_limit_pct)
        self.has_u = (self.tpp >= 5) if has_u is None else bool(has_u)
        self.has_occl = (self.tpp >= 5) if has_occl is None else bool(has_occl)
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

    # ---- B: lobe breathing ---------------------------------------------
    def term_B(self, t):
        n = self.n
        bl = np.zeros(n)
        wsum = np.zeros(n)
        for ak, T, ph in zip(self.LOBE_ANG, self.LOBE_T, self.LOBE_PH):
            wgt = np.exp(-(angdiff(self.ang, ak) / self.LOBE_W) ** 2)
            wsum += wgt
            bl += wgt * float(breath_at(t * 5.5 / T, ph))
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
            out["terms"] = {}
            out["terms_px"] = {}
            out["radius"] = np.ones(self.n)
            out["bright"] = np.ones(self.n)
            return out
        dB, bl = self.term_B(t)
        dC, gC = self.term_C(t)
        dD, V = self.term_D(t)
        dE, rE = self.term_E(t)
        terms = {"B": dB, "C": dC, "D": dD, "E": dE}
        dP_raw = dB + dC + dD + dE
        # the shader soft limits the sum: dloc *= lim * (1 - exp(-dl / lim)) / dl
        dl = np.linalg.norm(dP_raw, axis=1)
        if self.soft_limit:
            lim = R_KNOT * self.local_limit_pct / 100.0
            sc = lim * (1.0 - np.exp(-dl / lim)) / np.maximum(dl, 1e-4)
            dP = dP_raw * sc[:, None]
        else:
            dP = dP_raw.copy()
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
        out["terms"] = terms
        out["terms_px"] = {k: self.project(Q + v, t) - pos
                           for k, v in terms.items()}
        # shading factors of the local terms, for the shader to match
        sB = 2.0 * bl - 1.0
        out["radius"] = (1.0 + 0.08 * sB) * (1.0 + 0.22 * gC) * (1.0 + 0.35 * rE)
        out["bright"] = (1.0 + 0.12 * sB) * (1.0 + 0.40 * gC) * (1.0 + 0.50 * rE)
        out["lobe"] = bl
        out["front"] = gC
        out["event"] = rE
        out["curl"] = V
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--t", type=float, default=0.0)
    ap.add_argument("--motion", default="v2", choices=("v2", "base"))
    ap.add_argument("--tex", default=DEFAULT_TEX)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    p = KnotPort(tex=a.tex, motion=a.motion)
    d = p.sample(a.t)
    rep = {
        "t": d["t"], "motion": a.motion, "n": int(p.n),
        "ribbon": int(p.ribbon.sum()), "ring": int((~p.ribbon).sum()),
        "yaw_deg": d["yaw_deg"], "pitch_deg": d["pitch_deg"],
        "local_px_mean": float(d["local_len"].mean()),
        "local_px_max": float(d["local_len"].max()),
        "dP_max_units": float(d["dP_len"].max()) if "dP_len" in d else 0.0,
        "dP_max_pct_R": (float(d["dP_len"].max()) / R_KNOT * 100.0)
                        if "dP_len" in d else 0.0,
        "pos_bbox": [float(d["pos"][:, 0].min()), float(d["pos"][:, 0].max()),
                     float(d["pos"][:, 1].min()), float(d["pos"][:, 1].max())],
    }
    print(json.dumps(rep, indent=1) if a.json else rep)


if __name__ == "__main__":
    main()
