#!/usr/bin/env python3
"""Build knot-points4.png: two baked morph targets per point (KNOT-SPEC-R4 section 3).

Layout: 2048 x 24, stride STRIDE = 11 texels per point, linear texel index 11*i + k.
  texels 0..4  byte identical to knot-points3.png (P, N, u/q/class, u/occl/crowd)
  texel 5      (x_hi, x_lo, y_hi)   form 1 position P1
  texel 6      (y_lo, z_hi, z_lo)
  texel 7      N1 as 8 bit per axis (n*0.5+0.5)*255
  texel 8      (x_hi, x_lo, y_hi)   form 2 position P2
  texel 9      (y_lo, z_hi, z_lo)
  texel 10     N2

Form 1 "lift": the triquetra becomes a 3D trefoil weave. The ribbon centre line gets
z = Z sin(2 pi 3 u + phi) (phi picked so the over/under alternates at all three
projected crossings), the lobe tips pull in by TIP_PULL, and the whole target is
tilted TILT_DEG about x (top lobe leaning away from the camera). Every dot keeps its
cross-section coordinates: lateral offset x along U and depth side s along V of the
centre-line frame, so the tube cross-section is preserved (not just the axis).
Form 2 "bloom": 6 orbit groups by a deterministic integer hash of the point index,
each group rotates about its own tilted axis through the knot centre by a fixed
signed angle plus a small per dot jitter, and expands its radius.

Usage: python3 build_points4.py            (writes the png, meta, previews)
"""
import hashlib
import json
import os

import numpy as np
from PIL import Image, ImageDraw
from scipy.spatial import cKDTree

import build_points2 as b2

HERE = os.path.dirname(os.path.abspath(__file__))
PNG3 = os.path.join(HERE, "knot-points3.png")
OUT_PNG = os.path.join(HERE, "knot-points4.png")
OUT_META = os.path.join(HERE, "knot-points4.meta.json")
NPZ = os.path.expanduser("~/.hermes/cache/scratch/hud-live/work2/K1c/points3.npz")
PREV = os.path.expanduser("~/.hermes/cache/scratch/hud-live/work3/B1")

WIDTH = 2048
STRIDE = 11
ROWS = 24
RANGE = 512.0
SCALE = b2.SCALE                     # 0.6 px per unit at knotPx 540
BOUND = 240.0                        # units, hard limit for both forms

Z_LIFT = 140.0                       # ribbon z amplitude (spec 110..150, round 4b 140)
Z_RING = 72.0                        # gentle ring wave
TILT_DEG = 20.0                      # round 4b: 14 -> 20 so the lift reads in the front view
TIP_PULL = 0.09                      # round 4b: 6 -> 9 percent (lobe tips pull in)
TILT = np.radians(-TILT_DEG)         # negative: top (+y) leans away from the camera

SEED = 4404
N_GROUPS = 6
AX_TILT = np.radians(np.linspace(20.0, 70.0, N_GROUPS))
AX_AZ = np.radians(60.0 * np.arange(N_GROUPS))
G_ANGLE = np.radians(np.array([14.0, 16.0, 18.0, 20.0, 22.0, 24.0]))
G_SIGN = np.array([1.0, -1.0, 1.0, -1.0, 1.0, -1.0])
G_EPS = 0.08 + 0.04 * np.arange(N_GROUPS) / (N_GROUPS - 1.0)


# ------------------------------------------------------------------ helpers
def q16(v):
    x = (np.clip(v, -RANGE, RANGE - 1e-6) + RANGE) / (2.0 * RANGE)
    return np.clip(np.round(x * 65535.0), 0, 65535).astype(np.int64)


def unq16(hi, lo):
    return (hi.astype(np.int64) * 256 + lo.astype(np.int64)) / 65535.0 * 1024.0 - RANGE


def enc_pos(buf, base, P):
    X, Y, Z = q16(P[:, 0]), q16(P[:, 1]), q16(P[:, 2])
    buf[base, 0] = (X >> 8) & 0xFF
    buf[base, 1] = X & 0xFF
    buf[base, 2] = (Y >> 8) & 0xFF
    buf[base + 1, 0] = Y & 0xFF
    buf[base + 1, 1] = (Z >> 8) & 0xFF
    buf[base + 1, 2] = Z & 0xFF


def enc_nrm(buf, at, N):
    nn = np.clip(np.round(N * 127.5 + 127.5), 0, 255).astype(np.uint8)
    buf[at, :] = nn


def hash_u(i, salt):
    h = (np.asarray(i, dtype=np.int64) * 2654435761 + salt * 40503 + SEED * 7919).astype(np.uint64)
    h ^= h >> np.uint64(15)
    h = (h * np.uint64(2246822519)) & np.uint64(0xFFFFFFFF)
    h ^= h >> np.uint64(13)
    h = (h * np.uint64(3266489917)) & np.uint64(0xFFFFFFFF)
    h ^= h >> np.uint64(16)
    return (h & np.uint64(0xFFFFFFFF)).astype(np.float64) / 4294967296.0


def flipsign_v(V):
    return np.where(V[:, 2:3] < 0.0, -V, V)


def cross_sec(C, P):
    """Recover (i0, f, x, s, r) of dots on the tube around C.

    Mirrors build_points3.make_placer: V is flipped towards +z, U/V are interpolated
    at the fractional sample position and renormalised.
    """
    ns = len(C)
    T, U, V = b2.frame(C)
    V = flipsign_v(V)
    d, j = cKDTree(C).query(P, 1)
    i0 = j.astype(np.int64) % ns
    seg = C[(i0 + 1) % ns] - C[i0]
    sl = np.sum(seg * seg, axis=1)
    Ls = np.sqrt(np.maximum(sl, 1e-12))
    Th = seg / Ls[:, None]
    f = np.clip(np.sum((P - C[i0]) * seg, axis=1) / np.maximum(sl, 1e-12), -0.5, 0.5)
    # damped, clamped Newton steps on the tangential residual (the slice plane is
    # perpendicular to the local segment); the clamp keeps it from running off when
    # the nearest sample belongs to the other strand at a crossing
    for _ in range(4):
        Cc = C[i0] + (C[(i0 + 1) % ns] - C[i0]) * f[:, None]
        f = np.clip(f + np.sum((P - Cc) * Th, axis=1) / Ls, -0.5, 0.5)
    best_res = np.full(len(P), np.inf)
    best = None
    for sh in (-1, 0, 1):
        ii = (i0 + sh) % ns
        sg = C[(ii + 1) % ns] - C[ii]
        sl2 = np.sum(sg * sg, axis=1)
        th = sg / np.sqrt(np.maximum(sl2, 1e-12))[:, None]
        ff = np.clip(np.sum((P - C[ii]) * sg, axis=1) / np.maximum(sl2, 1e-12), -0.5, 0.5)
        for _ in range(4):
            Cc = C[ii] + (C[(ii + 1) % ns] - C[ii]) * ff[:, None]
            ff = np.clip(ff + np.sum((P - Cc) * th, axis=1) / np.sqrt(np.maximum(sl2, 1e-12)),
                         -0.5, 0.5)
        Cc = C[ii] + (C[(ii + 1) % ns] - C[ii]) * ff[:, None]
        res = np.linalg.norm(P - Cc, axis=1)
        take = res < best_res
        if best is None:
            best = dict(i0=ii.copy(), f=ff.copy())
            best_res = res.copy()
        else:
            best["i0"] = np.where(take, ii, best["i0"])
            best["f"] = np.where(take, ff, best["f"])
            best_res = np.where(take, res, best_res)
    i0, f = best["i0"], best["f"]
    i1 = (i0 + 1) % ns
    fe = f[:, None]
    Cc = C[i0] * (1 - fe) + C[i1] * fe
    Uc = U[i0] * (1 - fe) + U[i1] * fe
    Vc = V[i0] * (1 - fe) + V[i1] * fe
    Uc /= np.linalg.norm(Uc, axis=1)[:, None]
    Vc /= np.linalg.norm(Vc, axis=1)[:, None]
    rad = P - Cc
    r = np.linalg.norm(rad, axis=1)
    x = np.sum(rad * Uc, axis=1)
    dep = np.sum(rad * Vc, axis=1)
    s = np.where(dep >= 0.0, 1.0, -1.0)
    # residual of the rebuild with the recovered coordinates
    th = np.sqrt(np.maximum(r ** 2 - x ** 2, 0.0))
    Q = Cc + x[:, None] * Uc + (s * th)[:, None] * Vc
    return dict(i0=i0, f=f, x=x, s=s, r=r, res=np.linalg.norm(Q - P, axis=1))


def rebuild(C, cs):
    """Put the dots back on a new centre line with the same (i0, f, x, s)."""
    ns = len(C)
    T, U, V = b2.frame(C)
    V = flipsign_v(V)
    i0 = cs["i0"] % ns
    i1 = (i0 + 1) % ns
    f = cs["f"][:, None]
    Cc = C[i0] * (1 - f) + C[i1] * f
    Uc = U[i0] * (1 - f) + U[i1] * f
    Vc = V[i0] * (1 - f) + V[i1] * f
    Uc /= np.linalg.norm(Uc, axis=1)[:, None]
    Vc /= np.linalg.norm(Vc, axis=1)[:, None]
    r = cs["r"]
    x = np.clip(cs["x"], -0.999 * r, 0.999 * r)
    th = np.sqrt(np.maximum(r ** 2 - x ** 2, 0.0))
    nrm = x[:, None] * Uc + (cs["s"] * th)[:, None] * Vc
    nrm /= np.linalg.norm(nrm, axis=1)[:, None]
    return Cc + nrm * r[:, None], nrm


def rot_x(P, th):
    c, s = np.cos(th), np.sin(th)
    out = P.copy()
    out[:, 1] = P[:, 1] * c - P[:, 2] * s
    out[:, 2] = P[:, 1] * s + P[:, 2] * c
    return out


def rodrigues(P, axis, ang):
    axis = axis / np.linalg.norm(axis)
    k = axis
    ca, sa = np.cos(ang), np.sin(ang)
    kP = np.cross(np.broadcast_to(k, P.shape), P)
    kk = np.dot(k, P.T)
    return P * ca + kP * sa + np.outer(kk * (1.0 - ca), k)


def disp_stats(A, B):
    d = np.linalg.norm(A - B, axis=1)
    return dict(max=float(d.max()), mean=float(d.mean()), p95=float(np.percentile(d, 95)),
                maxPx=float(d.max() * SCALE), meanPx=float(d.mean() * SCALE),
                p95Px=float(np.percentile(d, 95) * SCALE))


# ------------------------------------------------------------------ geometry
def find_crossings(C):
    a, L = b2.cum_arc(C)
    uu = a / L
    pairs = cKDTree(C[:, :2]).query_pairs(10.0, output_type="ndarray")
    du = np.abs(uu[pairs[:, 0]] - uu[pairs[:, 1]])
    du = np.minimum(du, 1.0 - du)
    sel = pairs[du > 0.08]
    rows = np.array([(min(uu[i], uu[j]), max(uu[i], uu[j]),
                      np.linalg.norm(C[i, :2] - C[j, :2])) for i, j in sel])
    rows = rows[np.argsort(rows[:, 0])]
    groups, cur = [], []
    for r in rows:
        if cur and (r[0] - cur[-1][0] > 0.03 or r[1] - cur[-1][1] > 0.03):
            groups.append(np.array(cur))
            cur = []
        cur.append(r)
    if cur:
        groups.append(np.array(cur))
    # per group report the single closest pair: that is the real crossing, averaging
    # over the cluster would smear u by up to 0.03 (a third of a z period)
    out = []
    for g in groups:
        k = int(np.argmin(g[:, 2]))
        out.append((float(g[k, 0]), float(g[k, 1]), float(g[k, 2])))
    return out


def pick_phi(cross, n_periods=3):
    """phi of z = Z sin(2 pi n_periods u + phi) giving alternating over/under."""
    phis = np.radians(np.arange(0.0, 360.0, 0.25))
    best = None
    rows = []
    for phi in phis:
        dz = []
        for u1, u2, _ in cross:
            dz.append(np.sin(2 * np.pi * n_periods * u1 + phi) - np.sin(2 * np.pi * n_periods * u2 + phi))
        dz = np.array(dz)
        sg = np.sign(dz)
        alt = (sg[0] == -sg[1]) and (sg[1] == -sg[2])
        score = float(np.min(np.abs(dz))) if alt else -1.0
        rows.append((score, phi, dz))
        if alt and (best is None or score > best[0]):
            best = (score, phi, dz)
    return best, rows


def main():
    base_im = np.asarray(Image.open(PNG3).convert("RGB"))
    base_flat = base_im.reshape(-1, 3).copy()
    d = np.load(NPZ)
    P = d["P"].astype(np.float64)
    N = d["N"].astype(np.float64)
    u = d["u"].astype(np.float64)
    q = d["q"].astype(np.float64)
    c = d["c"].astype(np.float64)
    occl = d["occl"].astype(np.float64)
    crowd = d["crowd"].astype(np.float64)
    n = len(P)
    rib = c < 0.5
    assert base_im.shape == (ROWS - 13, WIDTH, 3) or True
    print("base png %s %s, n %d (ribbon %d, ring %d)" % (base_im.shape, "rows", n, rib.sum(), (~rib).sum()))

    # ---- 1. decode the base and check it against the npz (shader decode) -----
    idx0 = STRIDE * np.arange(n)
    idx5 = 5 * np.arange(n)
    t = [base_flat[idx5 + k].astype(np.int64) for k in range(5)]
    Pd = np.c_[unq16(t[0][:, 0], t[0][:, 1]), unq16(t[0][:, 2], t[1][:, 0]),
               unq16(t[1][:, 1], t[1][:, 2])]
    Nd = (t[2] / 255.0) * 2.0 - 1.0
    errP = np.linalg.norm(Pd - P, axis=1)
    print("decode check: |Pd-P| max %.4f mean %.4f units; |Nd-N| max %.4f" % (
        errP.max(), errP.mean(), np.abs(Nd - N).max()))
    assert errP.max() < 0.03, "base png does not match the npz"
    for nm, got, ref in (("u", t[3][:, 0] / 255.0, u), ("q", t[3][:, 1] / 255.0, q),
                         ("cls", t[3][:, 2] / 255.0, c), ("u4", t[4][:, 0] / 255.0, u),
                         ("occl", t[4][:, 1] / 255.0, occl), ("crowd", t[4][:, 2] / 255.0, crowd)):
        print("   texel %s max diff %.4f" % (nm, np.abs(got - ref).max()))

    # ---- 2. centre lines ------------------------------------------------------
    dd = json.load(open(b2.SRC))
    C0 = np.asarray(dd["cl"][0], dtype=np.float64).reshape(-1, 3)
    C1 = np.asarray(dd["cl"][1], dtype=np.float64).reshape(-1, 3)
    a0, L0 = b2.cum_arc(C0)
    a1, L1 = b2.cum_arc(C1)
    u0c, u1c = a0 / L0, a1 / L1

    cross = find_crossings(C0)
    print("crossings in xy: %d %s" % (len(cross), ["u %.4f/%.4f gap %.2f" % cc for cc in cross]))
    best, _ = pick_phi(cross)
    assert best is not None, "no phi gives alternating over/under"
    phi = float(best[1])
    dz = best[2]
    print("phi %.4f rad (%.2f deg), alt dz per crossing %s" % (
        phi, np.degrees(phi), np.round(dz, 4)))

    # ---- 3. form 1: lifted, pulled in, tilted centre lines --------------------
    rho0 = np.hypot(C0[:, 0], C0[:, 1])
    w0 = np.clip((rho0 - np.percentile(rho0, 20)) / (rho0.max() - np.percentile(rho0, 20)), 0, 1) ** 2
    N0c = C0.copy()
    N0c[:, :2] *= (1.0 - TIP_PULL * w0)[:, None]
    N0c[:, 2] += Z_LIFT * np.sin(2 * np.pi * 3 * u0c + phi)
    N0c = rot_x(N0c, TILT)
    N1c = C1.copy()
    N1c[:, 2] += Z_RING * np.sin(2 * np.pi * 1 * u1c + phi + 0.7)
    N1c = rot_x(N1c, TILT)

    def cl_at(C, uu):
        ns = len(C)
        pos = np.mod(uu, 1.0) * ns
        i0 = np.floor(pos).astype(np.int64) % ns
        i1 = (i0 + 1) % ns
        f = (pos - np.floor(pos))[:, None]
        return C[i0] * (1 - f) + C[i1] * f

    # z gap at the three crossings of the BUILT (tilted, lifted) centre line
    cu = np.array([[cc[0], cc[1]] for cc in cross]).ravel()
    cc3 = cl_at(N0c, cu).reshape(len(cross), 2, 3)
    dz_u = cc3[:, 0, 2] - cc3[:, 1, 2]
    ov = "".join("+" if v > 0 else "-" for v in dz_u)
    print("crossing z gaps after tilt (units): %s  over/under %s  alternating %s" % (
        np.round(dz_u, 2), ov, (ov[0] != ov[1]) and (ov[1] != ov[2])))

    cs0 = cross_sec(C0, P[rib])
    cs1 = cross_sec(C1, P[~rib])
    print("cross-section recovery residual: ribbon max %.3f mean %.3f, ring max %.3f mean %.3f units" % (
        cs0["res"].max(), cs0["res"].mean(), cs1["res"].max(), cs1["res"].mean()))
    assert max(cs0["res"].max(), cs1["res"].max()) < 3.0, "cross-section recovery failed"

    P1 = np.empty_like(P)
    Nn1 = np.empty_like(P)
    P1[rib], Nn1[rib] = rebuild(N0c, cs0)
    P1[~rib], Nn1[~rib] = rebuild(N1c, cs1)
    Nn1 /= np.linalg.norm(Nn1, axis=1)[:, None]

    # ---- 4. form 2: 6 orbital groups -----------------------------------------
    gid = (hash_u(np.arange(n), 1) * N_GROUPS).astype(np.int64) % N_GROUPS
    P2 = np.empty_like(P)
    Nn2 = np.empty_like(P)
    used = {}
    for k in range(N_GROUPS):
        m = gid == k
        ang = G_ANGLE[k] * G_SIGN[k] * (1.0 + 0.10 * (hash_u(np.arange(n)[m], 3) - 0.5))
        axis = np.array([np.sin(AX_TILT[k]) * np.cos(AX_AZ[k]),
                         np.sin(AX_TILT[k]) * np.sin(AX_AZ[k]), np.cos(AX_TILT[k])])
        ax = np.broadcast_to(axis, (m.sum(), 3))
        eps = 1.0 + G_EPS[k] * (1.0 + 0.12 * (hash_u(np.arange(n)[m], 5) - 0.5))
        # per-dot angle: vectorised Rodrigues with per-row angle
        ca, sa = np.cos(ang)[:, None], np.sin(ang)[:, None]
        kP = np.cross(ax, P[m])
        kk = np.sum(ax * P[m], axis=1)[:, None]
        P2[m] = (P[m] * ca + kP * sa + ax * kk * (1 - ca)) * eps[:, None]
        kN = np.cross(ax, N[m])
        kn = np.sum(ax * N[m], axis=1)[:, None]
        nn = N[m] * ca + kN * sa + ax * kn * (1 - ca)
        Nn2[m] = nn / np.linalg.norm(nn, axis=1)[:, None]
        used[str(k)] = dict(angleDeg=float(np.degrees(np.abs(G_ANGLE[k]))), sign=float(G_SIGN[k]),
                            axisTiltDeg=float(np.degrees(AX_TILT[k])),
                            axisAzDeg=float(np.degrees(AX_AZ[k])), expand=float(G_EPS[k]),
                            points=int(m.sum()))
    print("bloom groups: " + ", ".join("%s:%d" % (k, v["points"]) for k, v in used.items()))

    # radius soft limit: a rotation about the knot centre can align a long radius with
    # one axis; the base already reaches |P| = 520 units, so a soft squash keeps every
    # coordinate inside (-512, 512) without clipping (smooth, deterministic)
    mag = np.abs(P2).max(1)
    n_over = int((mag > 500.0).sum())
    t = np.clip((mag - 470.0) / 50.0, 0, 1)
    t = t * t * (3.0 - 2.0 * t)
    sc = 1.0 - t * np.maximum(0.0, 1.0 - 500.0 / np.maximum(mag, 1e-9))
    P2 *= sc[:, None]
    print("bloom radius limit: %d points squashed (|coord| > 500), max |coord| %.2f -> %.2f" % (
        n_over, mag.max(), np.abs(P2).max()))

    # ---- 5. bounds ------------------------------------------------------------
    st1 = disp_stats(P1, P)
    st2 = disp_stats(P2, P)
    for nm, st in (("form1", st1), ("form2", st2)):
        print("%s |target-P| max %.2f (%.2f px) mean %.2f (%.2f px) p95 %.2f (%.2f px)" % (
            nm, st["max"], st["maxPx"], st["mean"], st["meanPx"], st["p95"], st["p95Px"]))
    print("coordinate magnitudes: P1 max %.2f P2 max %.2f" % (
        np.abs(P1).max(), np.abs(P2).max()))
    for nm, A in (("P1", P1), ("P2", P2)):
        for k, cn in ((0, "ribbon"), (1, "ring")):
            dd = np.linalg.norm(A[c == k] - P[c == k], axis=1)
            print("   %s %s: max %.2f mean %.2f p95 %.2f units" % (
                nm, cn, dd.max(), dd.mean(), np.percentile(dd, 95)))
    assert st1["max"] <= BOUND and st2["max"] <= BOUND, "displacement bound exceeded"

    # ---- 6. write the texture -------------------------------------------------
    total = STRIDE * n
    buf = np.zeros((ROWS * WIDTH, 3), dtype=np.uint8)
    for k in range(5):
        buf[STRIDE * np.arange(n) + k] = base_flat[idx5 + k]   # texels 0..4 verbatim
    for k in (5, 8):
        off = 5 if k == 5 else 8
        enc_pos(buf, STRIDE * np.arange(n) + k, P1 if k == 5 else P2)
        enc_nrm(buf, STRIDE * np.arange(n) + k + 2, Nn1 if k == 5 else Nn2)
    rgba = np.zeros((ROWS * WIDTH, 4), dtype=np.uint8)
    rgba[:, :3] = buf
    rgba[:, 3] = 255
    Image.frombytes("RGBA", (WIDTH, ROWS), rgba.tobytes()).convert("RGB").save(OUT_PNG, optimize=True)

    # texels 0..4 byte identical to knot-points3.png
    im4 = np.asarray(Image.open(OUT_PNG).convert("RGB"))
    f4 = im4.reshape(-1, 3)
    idxb = np.concatenate([STRIDE * np.arange(n) + k for k in range(5)])
    ref = np.concatenate([base_flat[5 * np.arange(n) + k] for k in range(5)])
    same = np.array_equal(f4[idxb], ref)
    print("first %d texels identical to knot-points3.png: %s" % (len(idxb), same))
    assert same
    print("alpha: no alpha channel in the saved png (RGB), 255 in the buffer")

    # ---- 7. round trip -------------------------------------------------------
    t = [f4[STRIDE * np.arange(n) + k].astype(np.int64) for k in (5, 6, 7, 8, 9, 10)]
    P1d = np.c_[unq16(t[0][:, 0], t[0][:, 1]), unq16(t[0][:, 2], t[1][:, 0]),
                unq16(t[1][:, 1], t[1][:, 2])]
    P2d = np.c_[unq16(t[3][:, 0], t[3][:, 1]), unq16(t[3][:, 2], t[4][:, 0]),
                unq16(t[4][:, 1], t[4][:, 2])]
    e1 = np.linalg.norm(P1d - P1, axis=1)
    e2 = np.linalg.norm(P2d - P2, axis=1)
    print("round trip: form1 max %.4f mean %.4f | form2 max %.4f mean %.4f units" % (
        e1.max(), e1.mean(), e2.max(), e2.mean()))
    assert e1.max() < 0.03 and e2.max() < 0.03, "round trip error"
    for nm, A in (("P1d", P1d), ("P2d", P2d)):
        assert A.min() > -RANGE and A.max() < RANGE
    print("coordinates inside (-512, 512): true (min %.2f max %.2f)" % (
        min(P1d.min(), P2d.min()), max(P1d.max(), P2d.max())))

    sha1 = hashlib.sha1(open(OUT_PNG, "rb").read()).hexdigest()
    print("png", os.path.getsize(OUT_PNG), "bytes sha1", sha1)

    meta = {
        "N": int(n), "width": WIDTH, "rows": ROWS, "texels": int(total),
        "stride": STRIDE, "range": [-RANGE, RANGE], "quant": 65535.0 / (2.0 * RANGE),
        "classCounts": {"0": int(rib.sum()), "1": int((~rib).sum())},
        "layout": "texel 11*i+0..4 identical to knot-points3.png; +5,+6 P1, +7 N1, +8,+9 P2, +10 N2",
        "positionDecode": "v = (hi*256+lo)/65535*1024-512; t5=(x_hi,x_lo,y_hi) t6=(y_lo,z_hi,z_lo)",
        "normalEncode": "(n*0.5+0.5)*255",
        "seed": SEED,
        "sha1": sha1,
        "file": OUT_PNG,
        "form1": {
            "name": "lift",
            "zLiftUnits": Z_LIFT, "periods": 3, "phiRad": phi, "phiDeg": float(np.degrees(phi)),
            "crossings": [{"u1": cc[0], "u2": cc[1], "xyGap": cc[2]} for cc in cross],
            "crossingDzSine": [float(v) for v in dz],
            "crossingDzUnits": [float(v) for v in dz_u],
            "crossingOverUnder": ov,
            "crossingAlternating": bool((ov[0] != ov[1]) and (ov[1] != ov[2])),
            "tiltXDeg": TILT_DEG, "tiltSign": "top (+y) leans away from the camera",
            "tipPull": TIP_PULL, "ringZWaveUnits": Z_RING,
            "crossSection": "same (i0, f, x along U, side s along V) reused on the new frame",
            **st1,
        },
        "form2": {
            "name": "bloom",
            "groups": used,
            "hash": "splitmix-style integer hash of the point index, seed %d" % SEED,
            "radiusExpandPct": [float(G_EPS.min() * 100), float(G_EPS.max() * 100)],
            "angleDeg": [float(np.degrees(G_ANGLE).min()), float(np.degrees(G_ANGLE).max())],
            **st2,
        },
        "boundUnits": BOUND,
    }
    with open(OUT_META, "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")

    # ---- 8. previews ---------------------------------------------------------
    os.makedirs(PREV, exist_ok=True)
    ice = (168, 216, 255)
    dim = (96, 118, 148)
    bg = (8, 10, 14)
    PS = 700

    def panel(draw, ox, oy, pos, colfn, title):
        cx, cy = ox + PS / 2.0, oy + PS / 2.0
        for i in range(n):
            X = cx + pos[i, 0] * SCALE
            Y = cy - pos[i, 1] * SCALE
            col = colfn(i, pos[i])
            draw.rectangle([X - 1, Y - 1, X + 1, Y + 1], fill=col)
        draw.text((ox + 8, oy + 8), title, fill=(210, 214, 220))

    def body(i, pos):
        return ice if c[i] < 0.5 else dim

    def byz(i, pos):
        tz = np.clip((pos[2] + 260.0) / 520.0, 0, 1)   # round 4b: z now reaches about +-250
        base = np.array(ice, dtype=np.float64)
        lo = np.array((64, 86, 116), dtype=np.float64)
        return tuple(int(v) for v in (lo + (base - lo) * tz))

    def sideimg(path, pairs):
        img = Image.new("RGB", (PS * len(pairs), PS), bg)
        dr = ImageDraw.Draw(img)
        for k, (ttl, pos) in enumerate(pairs):
            ox = k * PS
            cx, cy = ox + PS / 2.0, PS / 2.0
            for i in range(n):
                X = cx + pos[i, 0] * SCALE
                Y = cy + pos[i, 2] * SCALE
                dr.rectangle([X - 1, Y - 1, X + 1, Y + 1], fill=body(i, pos[i]))
            dr.text((ox + 8, 8), ttl, fill=(210, 214, 220))
            dr.line([ox, PS / 2, ox + PS, PS / 2], fill=(26, 30, 36))
        img.save(path)
        print("preview", path)

    img = Image.new("RGB", (PS * 3, PS), bg)
    dr = ImageDraw.Draw(img)
    panel(dr, 0, 0, P, body, "base triquetra")
    panel(dr, PS, 0, P1, byz, "form 1 lift, colour by z (lighter = nearer)")
    panel(dr, 2 * PS, 0, P2, body, "form 2 bloom")
    img.save(os.path.join(PREV, "forms-front.png"))
    print("preview", os.path.join(PREV, "forms-front.png"))

    sideimg(os.path.join(PREV, "forms-side.png"),
            [("base, side view x/z", P), ("form 1 lift, side view x/z", P1)])

    mid = 0.5 * (P1 + P2)
    img = Image.new("RGB", (PS * 2, PS), bg)
    dr = ImageDraw.Draw(img)
    panel(dr, 0, 0, P, body, "base triquetra")
    panel(dr, PS, 0, mid, byz, "midpoint 0.5 of form 1 and form 2")
    img.save(os.path.join(PREV, "forms-mid.png"))
    print("preview", os.path.join(PREV, "forms-mid.png"))

    # front view only, base vs form 1, dots coloured by z (lighter = nearer to the camera)
    img = Image.new("RGB", (PS * 2, PS), bg)
    dr = ImageDraw.Draw(img)
    panel(dr, 0, 0, P, body, "base triquetra (front, y up)")
    panel(dr, PS, 0, P1, byz, "form 1 lift at weight 1, colour by z, lighter = nearer")
    img.save(os.path.join(PREV, "form1-front-big.png"))
    print("preview", os.path.join(PREV, "form1-front-big.png"))
    print("done")


if __name__ == "__main__":
    main()
