#!/usr/bin/env python3
"""strand_metrics.py: look gates R9 to R12 for the knot as one continuous fine strand.

Contract: work5/KNOT-SPEC-R5.md section 5 (K3a). Pure numpy, PIL and scipy.

API
  evaluate_gates(render_png, tex_png=None, meta_json=None, target_png=None, *,
                 scale=1, rest_yaw_deg=0.0, rest_pitch_deg=0.0,
                 target_yaw_deg=11.0, target_pitch_deg=-6.0, centreline=None)
    -> list of dict(name, value, need, status, note); status is PASS, FAIL or SKIPPED.
  The keyword-only arguments are extensions; the four positional ones are the spec.

CLI
  python3 strand_metrics.py gates --render X.png [--tex T.png --meta M.json]
        [--target r-knot.png] [--scale 1|2] [--yaw DEG --pitch DEG] [--centreline knot3d.json]
  python3 strand_metrics.py profile --render X.png [--scale 1|2] [--yaw DEG --pitch DEG]
  python3 strand_metrics.py synth --kind honeycomb|poisson --out DIR [--centreline knot3d.json]
  python3 strand_metrics.py selftest [--target r-knot.png] [--target-meta M.json]
        [--old A.png --old B.png] [--centreline knot3d.json]
        (env fallbacks: STRAND_TARGET, STRAND_TARGET_META, STRAND_OLD (path list, ':' separated))

Scale: 1x means knotPx 540 (0.6 px per 900-unit frame unit). A render made at knotPx 1080
(2x) is box-downsampled 2x2 with --scale 2 (scale=2) before measuring. target_png is always the
2x close-up r-knot.png and is box-downsampled automatically.

Registration: the strand mask is luminance above 25 percent of the P95 of the image. Its centroid
is matched to the centroid of the projected centreline, so a shifted knot still measures.

Pose: the bake rest pose is identity (yaw 0, pitch 0). The s6 target and the round 4 renders were
rendered at yaw 11, pitch -6: pass rest_yaw_deg=11, rest_pitch_deg=-6 for those. target_png uses
target_yaw_deg / target_pitch_deg (default 11, -6).

Centreline: knot3d.json key "cl" (strand 0 = ribbon, strand 1 = ring). Looked up as the centreline
argument, then $KNOT3D_JSON, then knot3d.json or knot/knot3d.json next to this file. If none is
found, R9 and R11 are SKIPPED. No fixed absolute path is read.

Baked set (tex_png, optional): layout of KNOT-SPEC-R5 section 3, width 2048, stride 11, texels 0,1
(position), 3 (lat, q, cls), 4 (knock, crowd) are read. meta_json needs N; radiusPx.median (px at 1x)
is used for R12 when present, else the radius is taken from the sprite recipe. Without tex_png the
NN part of R10 and the recipe radius are SKIPPED.

Gates (thresholds in THR; K3a calibration in work5/K3a/CALIBRATION.md):
  R9  every 1 px sample of the ribbon centreline outside crossing windows: min of the 3x3
      neighbourhood > 0.6 x median core (3x3 mean; spec 0.5, changed by calibration); fail fraction
      <= 0.5 percent, longest failing run <= 3 px.
  R10 NN coefficient of variation of the baked ribbon particles >= 0.35 (tex only); radial power
      spectrum of the strand-masked, mean-removed render, max over 1/6..1/2 cycles per px divided by
      the band mean after a log-log line is divided out (spec: no detrend; changed by calibration),
      <= 1.8 (spec 3, changed by calibration).
  R11 cross section profile (mean over arc samples outside windows, recentred on its peak):
      10 to 90 percent edge width in [4, 9] px; FWHM within 15 percent of the target's; core to
      lat 0.9 edge luminance ratio >= 3 (lat 0.9 = 0.9 x 12 px half width).
  R12 median particle radius in [0.8, 1.6] px and N >= 30000.
"""
import os
import sys
import json
import math
import argparse
import tempfile

import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
FRAME = 900.0
CAM = 2.7 * FRAME          # perspective camera distance in frame units
PXU = 0.6                  # px per frame unit at knotPx 540 (1x)
RAD = {0: 20.0, 1: 5.5}    # tube radius in frame units: ribbon, ring
HW = RAD[0] * PXU          # ribbon half width at 1x, px (12.0)
GAP = 3.2                  # px of gap each side of an over strand
DZ = 14.0                  # frame units: depth difference that makes an over/under crossing
ARC_MIN = 60               # same-strand samples closer than this along the arc are not crossings
RCROSS = 0.9 * HW + GAP + HW + 2.0
RMIN, RMAX = 0.55, 1.75    # ribbon particle radius range in px at 1x (sprite recipe)
WIDTH, STRIDE = 2048, 11
THR = dict(fail_frac=0.005, run_px=3, core_frac=0.6, nn_cv=0.35, ring=1.8,
           edge_lo=4.0, edge_hi=9.0, fwhm_tol=0.15, core_edge=3.0,
           rad_lo=0.8, rad_hi=1.6, n_min=30000)
# CALIBRATION (work5/K3a/CALIBRATION.md): core_frac 0.5 -> 0.6 (old final-t0 has no failing sample at 0.5,
# 94 percent at 0.6; target 0.08 percent at 0.6). ring 3.0 -> 1.8 on the detrended max/mean (raw max/mean
# fails the target itself at 3.14; detrended target 1.39, old fix-t12 2.17, synthetic honeycomb 15.4).


def load_lum(path, scale=1):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    L = 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
    s = int(scale)
    if s > 1:
        h, w = (L.shape[0] // s) * s, (L.shape[1] // s) * s
        L = L[:h, :w].reshape(h // s, s, w // s, s).mean(axis=(1, 3))
    return L


def find_centreline(path=None):
    for c in (path, os.environ.get("KNOT3D_JSON"),
              os.path.join(HERE, "knot3d.json"), os.path.join(HERE, "knot", "knot3d.json")):
        if c and os.path.isfile(c):
            K = json.load(open(c))
            return [np.asarray(s, dtype=np.float64).reshape(-1, 3) for s in K["cl"]]
    return None


def rot(p, yaw_deg, pitch_deg):
    yaw, pitch = math.radians(yaw_deg), math.radians(pitch_deg)
    cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
    x1 = p[:, 0] * cy + p[:, 2] * sy
    z1 = -p[:, 0] * sy + p[:, 2] * cy
    return np.c_[x1, p[:, 1] * cp - z1 * sp, p[:, 1] * sp + z1 * cp]


def project(q):
    k = CAM / (CAM - q[:, 2])
    return np.c_[q[:, 0] * k * PXU, q[:, 1] * k * PXU], k


def geometry(cl, yaw, pitch):
    out = []
    for c in cl:
        q = rot(c, yaw, pitch)
        xy, k = project(q)
        out.append(dict(q=q, xy=xy, k=k))
    return out


def crossing_flags(G):
    """True per ribbon sample (strand 0) inside a crossing window: within RCROSS of a ring sample,
    or of a ribbon sample at least ARC_MIN samples away along the arc, with |dz| > DZ."""
    A = G[0]
    n = len(A["xy"])
    flags = np.zeros(n, bool)
    za = A["q"][:, 2]
    for T, same in ((G[1], False), (A, True)):
        nb = cKDTree(T["xy"]).query_ball_point(A["xy"], RCROSS)
        zt = T["q"][:, 2]
        for i, lst in enumerate(nb):
            if flags[i] or len(lst) == 0:
                continue
            j = np.asarray(lst)
            ok = np.abs(zt[j] - za[i]) > DZ
            if same:
                arc = np.abs(j - i)
                ok &= np.minimum(arc, n - arc) >= ARC_MIN
            if ok.any():
                flags[i] = True
    return flags


def resample(xy, step=1.0):
    """Closed polyline resampled every `step` px of screen arc; oi = fractional original index."""
    n = len(xy)
    seg = np.roll(xy, -1, axis=0) - xy
    ln = np.hypot(seg[:, 0], seg[:, 1])
    cum = np.r_[0.0, np.cumsum(ln)]
    total = cum[-1]
    m = max(int(total / step), 2)
    s = np.arange(m) * (total / m)
    idx = np.clip(np.searchsorted(cum, s, side="right") - 1, 0, n - 1)
    f = (s - cum[idx]) / np.maximum(ln[idx], 1e-9)
    nxt = (idx + 1) % n
    p = xy[idx] * (1 - f)[:, None] + xy[nxt] * f[:, None]
    return p, idx + f


def analyse(png, scale=1, yaw=0.0, pitch=0.0, cl=None):
    L = load_lum(png, scale)
    G = geometry(cl, yaw, pitch)
    flags = crossing_flags(G)
    allxy = np.vstack([G[0]["xy"], G[1]["xy"]])
    thr = 0.25 * float(np.percentile(L, 95))
    ys, xs = np.nonzero(L > thr)
    off = np.array([xs.mean(), ys.mean()]) - allxy.mean(axis=0)
    p, oi = resample(G[0]["xy"])
    n = len(G[0]["xy"])
    win = flags[np.round(oi).astype(int) % n]
    # refinement: the centroid of the mask is biased by the uneven brightness of the knot, so the
    # offset is searched within +-12 px for the best mean 3x3 luminance under the ribbon samples
    # outside the windows (the ribbon core is the reference); the centroid offset is the start.
    mean3 = ndimage.uniform_filter(L, 3)
    ok = ~win
    best, best_off = -1.0, off
    for dy in range(-12, 13):
        for dx in range(-12, 13):
            o = off + np.array([dx, dy], dtype=np.float64)
            pp = p[ok] + o
            sc = float(ndimage.map_coordinates(mean3, [pp[:, 1], pp[:, 0]], order=1, mode="nearest").mean())
            if sc > best:
                best, best_off = sc, o
    off = best_off
    p = p + off
    t = np.roll(p, -1, 0) - np.roll(p, 1, 0)
    t /= np.maximum(np.hypot(t[:, 0], t[:, 1]), 1e-9)[:, None]
    nrm = np.c_[-t[:, 1], t[:, 0]]
    return dict(L=L, p=p, win=win, nrm=nrm, off=off, thr=thr, n=len(p))


def gate_r9(A):
    L = A["L"]
    ok = ~A["win"]
    mean3 = ndimage.uniform_filter(L, 3)
    min3 = ndimage.minimum_filter(L, 3)
    co = [A["p"][:, 1], A["p"][:, 0]]
    cc = ndimage.map_coordinates(mean3, co, order=1, mode="nearest")
    vv = ndimage.map_coordinates(min3, co, order=1, mode="nearest")
    core = float(np.median(cc[ok])) if ok.any() else 0.0
    fail = (vv < THR["core_frac"] * core) & ok
    run = best = 0
    for f, w in zip(fail, A["win"]):
        if w:
            run = 0
            continue
        run = run + 1 if f else 0
        best = max(best, run)
    frac = float(fail.sum()) / max(int(ok.sum()), 1)
    return dict(core=core, frac=frac, run=best, win_frac=float(A["win"].mean()))


def cut_levels(x, y, level):
    """Distance from the centre to the first crossing of `level` on each side (right, left)."""
    c = int(np.argmin(np.abs(x)))
    out = []
    for order in (range(c, len(x)), range(c, -1, -1)):
        xr, prev = float("nan"), None
        for i in order:
            if y[i] < level:
                if prev is None:
                    xr = x[i]
                else:
                    tt = (y[prev] - level) / (y[prev] - y[i])
                    xr = x[prev] + tt * (x[i] - x[prev])
                break
            prev = i
        out.append(abs(float(xr)))
    return out


def gate_profile(A, half=16.0, step=0.5):
    L = A["L"]
    ok = ~A["win"]
    d = np.arange(-half, half + 1e-9, step)
    pts = A["p"][ok][:, None, :] + d[None, :, None] * A["nrm"][ok][:, None, :]
    v = ndimage.map_coordinates(L, [pts[..., 1].ravel(), pts[..., 0].ravel()], order=1, mode="nearest")
    prof = v.reshape(pts.shape[0], -1).mean(axis=0)
    sm = ndimage.gaussian_filter1d(prof, 2.0)
    band = np.abs(d) <= 4.0
    d0 = float(d[band][np.argmax(sm[band])])
    x = d - d0
    peak = float(sm[np.abs(x) <= 2.0].max())
    bg = float(np.percentile(prof[np.abs(x) >= 12.0], 20))   # low quantile: a neighbour strand may sit at 12 to 16 px
    amp = peak - bg
    c90 = cut_levels(x, sm, bg + 0.9 * amp)
    c10 = cut_levels(x, sm, bg + 0.1 * amp)
    c50 = cut_levels(x, sm, bg + 0.5 * amp)
    edge = float(np.mean([c10[k] - c90[k] for k in (0, 1)]))
    fwhm = float(c50[0] + c50[1])
    core = float(sm[np.abs(x) <= 1.0].mean())
    e09 = float(np.interp([-0.9 * HW, 0.9 * HW], x, sm).mean())
    ratio = core / max(e09, 1e-9)
    return dict(d=d, x=x, prof=prof, sm=sm, bg=bg, peak=peak, amp=amp,
                edge=edge, fwhm=fwhm, core=core, edge09=e09, ratio=ratio)


def ring_ratio(A):
    L = A["L"]
    H, W = L.shape
    M = np.zeros((H, W), bool)
    xi = np.round(A["p"][:, 0]).astype(int)
    yi = np.round(A["p"][:, 1]).astype(int)
    ok = (xi >= 0) & (xi < W) & (yi >= 0) & (yi < H)
    M[yi[ok], xi[ok]] = True
    m = ndimage.distance_transform_edt(~M) <= HW
    x = np.where(m, L - L[m].mean(), 0.0)
    P = np.abs(np.fft.fft2(x)) ** 2
    fy = np.fft.fftfreq(H)[:, None]
    fx = np.fft.fftfreq(W)[None, :]
    R = np.sqrt(fx * fx + fy * fy)
    df = 1.0 / max(H, W)
    b = np.rint(R / df).astype(int).ravel()
    S = np.bincount(b, P.ravel())
    C = np.bincount(b)
    rad = S / np.maximum(C, 1)
    fc = np.arange(len(rad)) * df
    band = (fc >= 1 / 6.0) & (fc <= 0.5) & (C > 0)
    raw = float(rad[band].max() / max(rad[band].mean(), 1e-12))
    # the raw max/mean is biased by the slope of the spectrum inside the band (a dot of radius r
    # rolls off across 1/6..1/2), so the ring test divides by a log-log line fitted over the band
    bi = np.where(band)[0]
    lf, ly = np.log(fc[bi]), np.log(np.maximum(rad[bi], 1e-30))
    b1, b0 = np.polyfit(lf, ly, 1)
    res = rad[bi] / np.exp(b0 + b1 * lf)
    return float(res.max() / max(res.mean(), 1e-12)), raw


def read_tex(tex_png, meta):
    im = np.asarray(Image.open(tex_png).convert("RGB"), dtype=np.int64)
    W = im.shape[1]
    N = int(meta["N"])
    if im.shape[0] * W < N * STRIDE:
        raise ValueError("texture too small for N=%d" % N)
    pid = np.arange(N)

    def tx(k):
        idx = STRIDE * pid + k
        return im[idx // W, idx % W]
    t0, t1, t3, t4 = tx(0), tx(1), tx(3), tx(4)
    x = (t0[:, 0] * 256 + t0[:, 1]) / 65535.0 * 1024 - 512
    y = (t0[:, 2] * 256 + t1[:, 0]) / 65535.0 * 1024 - 512
    z = (t1[:, 1] * 256 + t1[:, 2]) / 65535.0 * 1024 - 512
    return dict(pid=pid, x=x, y=y, z=z, lat=t3[:, 0] / 255.0,
                cls=(t3[:, 2] > 127).astype(int), knock=t4[:, 1] / 255.0)


def nn_cv(T):
    sel = T["cls"] == 0
    xy, _ = project(np.c_[T["x"][sel], T["y"][sel], T["z"][sel]])
    d, _ = cKDTree(xy).query(xy, k=2)
    nn = d[:, 1]
    return float(nn.std() / nn.mean()), int(sel.sum())


def recipe_radius(T):
    sel = T["cls"] == 0
    pid = T["pid"][sel].astype(np.float64)
    h1 = np.mod(np.sin(pid * 12.9898) * 43758.5453, 1.0)
    r = RMIN + (RMAX - RMIN) * (1 - T["lat"][sel]) ** 0.9 * (0.72 + 0.28 * h1)
    return float(np.median(np.clip(r, 0.45, 3.0)))


def evaluate_gates(render_png, tex_png=None, meta_json=None, target_png=None, *,
                   scale=1, rest_yaw_deg=0.0, rest_pitch_deg=0.0,
                   target_yaw_deg=11.0, target_pitch_deg=-6.0, centreline=None):
    cl = find_centreline(centreline)
    meta = json.load(open(meta_json)) if meta_json else {}
    rows = []

    def add(name, value, need, status, note=""):
        rows.append(dict(name=name, value=value, need=need, status=status, note=note))

    def st(ok):
        return "PASS" if ok else "FAIL"

    if cl is None:
        for nm in ("R9a fail fraction", "R9b longest run px", "R11a edge 10-90 px",
                   "R11b FWHM px", "R11c core/edge 0.9"):
            add(nm, None, "", "SKIPPED", "no knot3d.json (centreline argument or KNOT3D_JSON)")
    else:
        A = analyse(render_png, scale, rest_yaw_deg, rest_pitch_deg, cl)
        r9 = gate_r9(A)
        add("R9a fail fraction", round(r9["frac"], 5), "<= 0.005",
            st(r9["frac"] <= THR["fail_frac"]), "3x3 min < %.2f x core %.3f; windows %.1f%% of path"
            % (THR["core_frac"], r9["core"], 100 * r9["win_frac"]))
        add("R9b longest run px", r9["run"], "<= 3", st(r9["run"] <= THR["run_px"]), "")
        pr = gate_profile(A)
        add("R11a edge 10-90 px", round(pr["edge"], 2), "4 to 9",
            st(THR["edge_lo"] <= pr["edge"] <= THR["edge_hi"]), "peak %.3f bg %.3f" % (pr["peak"], pr["bg"]))
        ref = None
        if target_png:
            At = analyse(target_png, 2, target_yaw_deg, target_pitch_deg, cl)
            ref = gate_profile(At)["fwhm"]
        if ref is None:
            add("R11b FWHM px", round(pr["fwhm"], 2), "within 15% of target", "SKIPPED", "no target_png")
        else:
            add("R11b FWHM px", round(pr["fwhm"], 2), "within 15% of target",
                st(abs(pr["fwhm"] - ref) <= THR["fwhm_tol"] * ref), "target FWHM %.2f" % ref)
        add("R11c core/edge 0.9", round(pr["ratio"], 2), ">= 3",
            st(pr["ratio"] >= THR["core_edge"]), "core %.3f edge(0.9 HW) %.3f" % (pr["core"], pr["edge09"]))
        ring, ring_raw = ring_ratio(A)
        add("R10 ring ratio", round(ring, 3), "<= %g" % THR["ring"], st(ring <= THR["ring"]),
            "detrended band max/mean; raw %.2f" % ring_raw)
    T = None
    if tex_png:
        if "N" not in meta:
            raise ValueError("tex_png needs meta_json with N")
        T = read_tex(tex_png, meta)
    if T is not None:
        cv, nb = nn_cv(T)
        add("R10 NN CV", round(cv, 4), ">= 0.35", st(cv >= THR["nn_cv"]), "ribbon particles n=%d" % nb)
    else:
        add("R10 NN CV", None, ">= 0.35", "SKIPPED", "no tex_png")
    rad, src = None, ""
    if "radiusPx" in meta and "median" in meta["radiusPx"]:
        rad, src = float(meta["radiusPx"]["median"]), "meta"
    elif T is not None:
        rad, src = recipe_radius(T), "sprite recipe"
    if rad is None:
        add("R12 median radius px", None, "0.8 to 1.6", "SKIPPED", "no radiusPx in meta and no tex")
    else:
        add("R12 median radius px", round(rad, 3), "0.8 to 1.6",
            st(THR["rad_lo"] <= rad <= THR["rad_hi"]), "source " + src)
    if "N" in meta:
        add("R12 N", int(meta["N"]), ">= 30000", st(int(meta["N"]) >= THR["n_min"]), "from meta")
    else:
        add("R12 N", None, ">= 30000", "SKIPPED", "no N in meta")
    return rows


def status_of(rows, prefix):
    sel = [r["status"] for r in rows if r["name"].startswith(prefix)]
    if not sel or all(s == "SKIPPED" for s in sel):
        return "SKIPPED"
    return "FAIL" if "FAIL" in sel else "PASS"


def print_rows(rows):
    for r in rows:
        v = "-" if r["value"] is None else str(r["value"])
        print("%-7s %-22s %10s  need %-22s %s" % (r["status"], r["name"], v, r["need"], r["note"]))


def synth(kind, out_dir, cl, seed=1):
    """Synthetic ribbon sets in the render frame (identity pose, knot centre at 350,350):
    honeycomb = hex lattice 4.4 px with 12 percent jitter filling the 24 px ribbon band;
    poisson = 4384 uniform points in the same band. Writes render png, tex png and meta json."""
    os.makedirs(out_dir, exist_ok=True)
    rng = np.random.default_rng(seed)
    G = geometry(cl, 0.0, 0.0)
    p, _ = resample(G[0]["xy"])
    tree = cKDTree(p)
    if kind == "honeycomb":
        s = 4.4
        ii, jj = np.meshgrid(np.arange(-200, 201), np.arange(-200, 201))
        base = np.c_[ii.ravel() * s + jj.ravel() * s / 2, jj.ravel() * s * math.sqrt(3) / 2]
        base = base + rng.uniform(-0.12 * s, 0.12 * s, base.shape)
        pts = base[tree.query(base, k=1)[0] <= HW]
    else:
        pts = np.zeros((0, 2))
        mn, mx = p.min(axis=0) - HW, p.max(axis=0) + HW
        while len(pts) < 4384:
            c = rng.uniform(mn, mx, (20000, 2))
            pts = np.vstack([pts, c[tree.query(c, k=1)[0] <= HW]])
        pts = pts[:4384]
    N = len(pts)
    rad = 2.3
    acc = np.zeros((700, 700))
    yy, xx = np.mgrid[-4:5, -4:5]
    g = np.exp(-(xx ** 2 + yy ** 2) / (2 * (rad / 2.0) ** 2)) * 0.5
    for x, y in pts + np.array([350.0, 350.0]):
        xi, yi = int(round(x)), int(round(y))
        if 4 <= xi < 696 and 4 <= yi < 696:
            acc[yi - 4:yi + 5, xi - 4:xi + 5] += g
    L = np.clip(acc, 0, 1)
    rgb = np.stack([150 * L, 220 * L, 236 * L], axis=-1).astype(np.uint8)
    png = os.path.join(out_dir, kind + "-render.png")
    Image.fromarray(rgb).save(png)
    lat = np.clip(tree.query(pts, k=1)[0] / HW, 0, 1)
    T = dict(x=pts[:, 0] / PXU, y=pts[:, 1] / PXU, z=np.zeros(N), lat=lat,
             q=np.full(N, 0.5), cls=np.zeros(N, int), knock=np.zeros(N))
    rows = -(-N * STRIDE // WIDTH)
    arr = np.zeros((rows * WIDTH, 3), np.int64)
    pid = np.arange(N)

    def u16(v):
        u = np.clip(np.round((v + 512) / 1024 * 65535), 0, 65535).astype(np.int64)
        return u >> 8, u & 255
    xh, xl = u16(T["x"])
    yh, yl = u16(T["y"])
    zh, zl = u16(T["z"])
    arr[STRIDE * pid + 0] = np.c_[xh, xl, yh]
    arr[STRIDE * pid + 1] = np.c_[yl, zh, zl]
    arr[STRIDE * pid + 2] = 128
    arr[STRIDE * pid + 3] = np.c_[np.round(lat * 255), np.round(T["q"] * 255), T["cls"] * 255]
    arr[STRIDE * pid + 4] = np.c_[np.zeros(N), np.round(T["knock"] * 255), np.full(N, 255)]
    tex = os.path.join(out_dir, kind + "-tex.png")
    Image.fromarray(arr.reshape(rows, WIDTH, 3).astype(np.uint8)).save(tex)
    meta = dict(N=N, width=WIDTH, rows=rows, stride=STRIDE, kind=kind, seed=seed,
                classCounts={"0": N, "1": 0}, radiusPx={"median": rad},
                note="synthetic set from strand_metrics.py synth; texels 0-4 only")
    mj = os.path.join(out_dir, kind + "-meta.json")
    json.dump(meta, open(mj, "w"), indent=1)
    return png, tex, mj


def selftest(args):
    cl_path = args.centreline
    cl = find_centreline(cl_path)
    if cl is None:
        print("selftest FAIL: no knot3d.json (use --centreline or KNOT3D_JSON)")
        return 1
    tmp = tempfile.mkdtemp(prefix="strand_selftest_")
    fails = []
    for kind in ("honeycomb", "poisson"):
        png, tex, mj = synth(kind, os.path.join(tmp, kind), cl)
        rows = evaluate_gates(png, tex, mj, None, centreline=cl_path)
        print("== synthetic %s" % kind)
        print_rows(rows)
        if kind == "honeycomb" and status_of(rows, "R10") != "FAIL":
            fails.append("honeycomb must FAIL R10")
        if kind == "poisson" and status_of(rows, "R10 NN") != "PASS":
            fails.append("poisson NN CV must PASS R10 NN")
    target = args.target or os.environ.get("STRAND_TARGET")
    tmeta = args.target_meta or os.environ.get("STRAND_TARGET_META")
    if target:
        rows = evaluate_gates(target, None, tmeta, target, scale=2, rest_yaw_deg=11.0,
                              rest_pitch_deg=-6.0, centreline=cl_path)
        print("== target (2x, pose 11/-6)")
        print_rows(rows)
        for g in ("R9", "R10", "R11", "R12"):
            if status_of(rows, g) != "PASS":
                fails.append("target must PASS %s" % g)
        # C5: target at 1x with every 3rd pixel row zeroed must FAIL R9
        im = Image.open(target).convert("RGB").reduce(2)
        arr = np.asarray(im).copy()
        arr[0::3, :, :] = 0
        mut = os.path.join(tmp, "target_mut3.png")
        Image.fromarray(arr).save(mut)
        rows = evaluate_gates(mut, None, tmeta, target, scale=1, rest_yaw_deg=11.0,
                              rest_pitch_deg=-6.0, centreline=cl_path)
        print("== target 1x, every 3rd row zeroed (C5)")
        print_rows(rows)
        if status_of(rows, "R9") != "FAIL":
            fails.append("C5 mutant must FAIL R9")
    olds = list(args.old or [])
    if not olds and os.environ.get("STRAND_OLD"):
        olds = [q for q in os.environ["STRAND_OLD"].split(":") if q]
    for o in olds:
        rows = evaluate_gates(o, None, None, target, rest_yaw_deg=11.0, rest_pitch_deg=-6.0,
                              centreline=cl_path)
        print("== old %s" % os.path.basename(o))
        print_rows(rows)
        if status_of(rows, "R9") != "FAIL":
            fails.append("%s must FAIL R9" % os.path.basename(o))
        if "fix-t12" in os.path.basename(o) and status_of(rows, "R10") != "FAIL":
            fails.append("%s must FAIL R10" % os.path.basename(o))
    if not target or not olds:
        print("note: real-image cases not all configured (STRAND_TARGET / STRAND_OLD), synthetic only")
    print("note: old final-t0 R10 render gate is not separated (see CALIBRATION.md); not asserted")
    print("selftest %s (%d failed assertions)" % ("PASS" if not fails else "FAIL", len(fails)))
    for f in fails:
        print("  - " + f)
    return 0 if not fails else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="R9 to R12 strand gates (see module docstring)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gates")
    g.add_argument("--render", required=True)
    g.add_argument("--tex")
    g.add_argument("--meta")
    g.add_argument("--target")
    g.add_argument("--scale", type=int, default=1)
    g.add_argument("--yaw", type=float, default=0.0)
    g.add_argument("--pitch", type=float, default=0.0)
    g.add_argument("--centreline")
    pf = sub.add_parser("profile")
    pf.add_argument("--render", required=True)
    pf.add_argument("--scale", type=int, default=1)
    pf.add_argument("--yaw", type=float, default=0.0)
    pf.add_argument("--pitch", type=float, default=0.0)
    pf.add_argument("--centreline")
    sy = sub.add_parser("synth")
    sy.add_argument("--kind", choices=["honeycomb", "poisson"], required=True)
    sy.add_argument("--out", required=True)
    sy.add_argument("--centreline")
    se = sub.add_parser("selftest")
    se.add_argument("--target")
    se.add_argument("--target-meta", dest="target_meta")
    se.add_argument("--old", action="append")
    se.add_argument("--centreline")
    a = ap.parse_args(argv)
    if a.cmd == "gates":
        rows = evaluate_gates(a.render, a.tex, a.meta, a.target, scale=a.scale,
                              rest_yaw_deg=a.yaw, rest_pitch_deg=a.pitch, centreline=a.centreline)
        print_rows(rows)
        return 1 if any(r["status"] == "FAIL" for r in rows) else 0
    if a.cmd == "profile":
        cl = find_centreline(a.centreline)
        if cl is None:
            print("no knot3d.json")
            return 1
        pr = gate_profile(analyse(a.render, a.scale, a.yaw, a.pitch, cl))
        print("lateral_px  mean_luma  smoothed")
        for xv, pv, sv in zip(pr["x"], pr["prof"], pr["sm"]):
            if abs(xv - round(xv)) < 1e-6:
                print("%8.1f  %9.4f  %8.4f" % (xv, pv, sv))
        print("edge10-90 %.2f  fwhm %.2f  core/edge0.9 %.2f" % (pr["edge"], pr["fwhm"], pr["ratio"]))
        return 0
    if a.cmd == "synth":
        cl = find_centreline(a.centreline)
        if cl is None:
            print("no knot3d.json")
            return 1
        print(" ".join(synth(a.kind, a.out, cl)))
        return 0
    return selftest(a)


if __name__ == "__main__":
    sys.exit(main())
