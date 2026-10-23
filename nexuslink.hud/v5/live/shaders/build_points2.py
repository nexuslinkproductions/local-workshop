#!/usr/bin/env python3
"""Build the v2 knot point texture (K3).

Source: knot3d.json (n, p, nr, s, q, c) built by build_knot.py. The v1 texture
packed 4 texels per point from that file. This build keeps the same N and the
same meaning for texels 0..3 of each point, adds a 5th texel, and replaces the
ribbon (class 0) lattice with a jittered blue-noise sampling of the same tube
surface (the source tube was a staggered 11-around helix lattice, which reads
as rows across the ribbon).

Layout: 5 texels per point at linear texel index 5*i+k, row width WIDTH=2048.
  texel0 = (x_hi, x_lo, y_hi)
  texel1 = (y_lo, z_hi, z_lo)      x,y,z 16 bit fixed point over [-512, 512)
  texel2 = (nx, ny, nz) * 127.5 + 127.5
  texel3 = (s * 255, q * 255, class * 255)
  texel4 = (u * 255, occl * 255, 0)     u true arc length 0..1 per class,
                                        occl under-strand weight 0..1 (front pose)
RGB, alpha always 255. Nearest sampling, no mipmap.
"""
import json
import os

import numpy as np
from PIL import Image
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(
    os.path.expanduser("~"),
    "NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/comp-r1/s3/src/knot/knot3d.json",
)
NPZ = os.path.expanduser("~/.hermes/cache/scratch/hud-live/work2/K3/knot2.npz")
WIDTH = 2048
RANGE = 512.0
KNOT_PX = 540.0          # screen px per 900 knot units at the hero size
CAM_D = 2.7 * 900.0
SCALE = KNOT_PX / 900.0  # 0.6


# ---------------------------------------------------------------- projection
def front(P):
    """Front pose (yaw 0, pitch 0) exactly as knot.vert: screen px at knotPx 540."""
    k = CAM_D / (CAM_D - P[:, 2])
    return np.c_[P[:, 0] * k, P[:, 1] * k] * SCALE


def nn_stats(S):
    d, _ = cKDTree(S).query(S, 2)
    d = d[:, 1]
    return dict(mean=float(d.mean()), sd=float(d.std()), cv=float(d.std() / d.mean()),
                p05=float(np.percentile(d, 5)), p50=float(np.percentile(d, 50)),
                p95=float(np.percentile(d, 95)), mn=float(d.min()), mx=float(d.max()))


# ------------------------------------------------------------------ geometry
def cum_arc(C):
    """closed-loop cumulative arc length and total"""
    seg = np.linalg.norm(np.diff(np.vstack([C, C[:1]]), axis=0), axis=1)
    a = np.r_[0.0, np.cumsum(seg)[:-1]]
    return a, float(seg.sum())


def frame(C):
    T = np.gradient(np.vstack([C[-1:], C, C[:1]]), axis=0)[1:-1]
    T /= np.linalg.norm(T, axis=1)[:, None] + 1e-12
    U = np.cross(T, [0.0, 0.0, 1.0])
    U /= np.linalg.norm(U, axis=1)[:, None] + 1e-12
    V = np.cross(T, U)
    return T, U, V


def slice_index(s, ns):
    return np.mod(np.rint(s * ns).astype(np.int64), ns)


def blue_noise_cylinder(n, L, circ, rng):
    """Best-candidate (Mitchell) blue noise on the closed tube parameter domain.

    Works in (arc length, circumference) so the metric is close to Euclidean on
    the surface. Returns arc fraction t in [0,1) and width fraction w in [0,1).
    """
    pts = np.empty((n, 2))
    pts[0] = (rng.random() * L, rng.random() * circ)
    box = [L, circ]
    for j in range(1, n):
        cand = np.c_[rng.random(10) * L, rng.random(10) * circ]
        best, bestd = 0, -1.0
        tree = cKDTree(pts[:j] % np.array(box), boxsize=box)
        for c in range(10):
            q = cand[c]
            d, _ = tree.query(q % np.array(box), k=1)
            if d > bestd:
                bestd, best = d, c
        pts[j] = cand[best]
    return pts[:, 0] / L, (pts[:, 1] / circ) % 1.0


def slice_radius(P, C, idx, ns):
    r = np.zeros(ns)
    cnt = np.zeros(ns)
    np.add.at(r, idx, np.linalg.norm(P - C[idx], axis=1))
    np.add.at(cnt, idx, 1.0)
    have = cnt > 0
    r[have] /= cnt[have]
    if not have.all():
        r[~have] = np.interp(np.where(~have)[0], np.where(have)[0], r[have])
    return r


def resample_ribbon(P, C, idx, ns, n_out, rng):
    arccum, L = cum_arc(C)
    r = slice_radius(P, C, idx, ns)
    T, U, V = frame(C)
    t, w = blue_noise_cylinder(n_out, L, 2.0 * np.pi * float(r.mean()), rng)
    pos = t * ns
    i0 = np.floor(pos).astype(np.int64) % ns
    i1 = (i0 + 1) % ns
    f = (pos - np.floor(pos))[:, None]
    Cc = C[i0] * (1 - f) + C[i1] * f
    rr = r[i0] * (1 - f[:, 0]) + r[i1] * f[:, 0]
    Uc = U[i0] * (1 - f) + U[i1] * f
    Vc = V[i0] * (1 - f) + V[i1] * f
    Uc /= np.linalg.norm(Uc, axis=1)[:, None]
    Vc /= np.linalg.norm(Vc, axis=1)[:, None]
    ang = 2.0 * np.pi * w
    nrm = np.cos(ang)[:, None] * Uc + np.sin(ang)[:, None] * Vc
    nrm /= np.linalg.norm(nrm, axis=1)[:, None]
    Q = Cc + rr[:, None] * nrm
    u = np.interp(pos, np.arange(ns), arccum) / L
    return Q, nrm, u, i0, rr


def occl_weight(P, cls, idx, nsl, reach=16.0, sig=8.0, dz=8.0):
    """Front-pose under-strand weight in [0,1).

    score_i = sum over points of the other strand (wrap-aware slice distance
    > 10, so the two sides of the same tube never count) within reach screen px
    of exp(-(d/sig)^2) * clamp((z_j - z_i)/dz, 0, 1).
    occl = score / (score + s0), s0 = half the 99th percentile of the score.
    """
    S = front(P)
    z = P[:, 2]
    tree = cKDTree(S)
    score = np.zeros(len(P))
    for i in range(len(P)):
        acc = 0.0
        for j in tree.query_ball_point(S[i], reach):
            if j == i:
                continue
            if cls[j] == cls[i]:
                ns = nsl[int(cls[i])]
                dd = abs(int(idx[j]) - int(idx[i]))
                dd = min(dd, ns - dd)
                if dd <= 10:
                    continue
            d = float(np.linalg.norm(S[j] - S[i]))
            acc += float(np.exp(-(d / sig) ** 2)) * min(1.0, max(0.0, (z[j] - z[i]) / dz))
        score[i] = acc
    pos = score > 0
    s0 = max(1e-3, 0.5 * float(np.percentile(score[pos], 99))) if pos.any() else 1.0
    return score / (score + s0), score, s0


def main():
    with open(SRC) as f:
        d = json.load(f)
    n = int(d["n"])
    P = np.asarray(d["p"], dtype=np.float64).reshape(n, 3)
    NR = np.asarray(d["nr"], dtype=np.float64).reshape(n, 3)
    s = np.asarray(d["s"], dtype=np.float64)
    q = np.asarray(d["q"], dtype=np.float64)
    c = np.asarray(d["c"], dtype=np.float64)
    C0 = np.asarray(d["cl"][0], dtype=np.float64).reshape(-1, 3)
    C1 = np.asarray(d["cl"][1], dtype=np.float64).reshape(-1, 3)
    ns0, ns1 = len(C0), len(C1)
    rib = c < 0.5
    idx = np.where(rib, slice_index(s, ns0), slice_index(s, ns1))

    cnt0 = np.bincount(idx[rib], minlength=ns0)
    cnt1 = np.bincount(idx[~rib], minlength=ns1)
    print("slices ribbon", ns0, "points/slice", np.unique(cnt0),
          "| ring", ns1, "points/slice", np.unique(cnt1))
    r0 = np.linalg.norm(P[rib] - C0[idx[rib]], axis=1)
    print("source tube radius ribbon mean %.3f sd %.4f" % (r0.mean(), r0.std()))

    cv_before = {k: nn_stats(front(P[c == k])) for k in (0.0, 1.0)}

    n0 = int(rib.sum())
    rng = np.random.default_rng(7)
    Q0, N0, u0, i0, rr0 = resample_ribbon(P[rib], C0, idx[rib], ns0, n0, rng)
    arcc1, L1 = cum_arc(C1)
    u1 = arcc1[idx[~rib]] / L1

    P2 = np.vstack([Q0, P[~rib]])
    N2 = np.vstack([N0, NR[~rib]])
    q2 = np.r_[q[rib], q[~rib]]
    c2 = np.r_[c[rib], c[~rib]]
    u2 = np.r_[u0, u1]
    # the source s was the slice index fraction, which is only approximately the
    # arc parameter (measured deviation in audit.txt, section 1). After the
    # resample the only meaningful strand parameter is u, so s follows it.
    s2 = u2.copy()
    idx2 = np.r_[i0, idx[~rib]]

    cv_after = {k: nn_stats(front(P2[c2 == k])) for k in (0.0, 1.0)}
    print("CV before ribbon %.3f ring %.3f | after ribbon %.3f ring %.3f" % (
        cv_before[0.0]["cv"], cv_before[1.0]["cv"],
        cv_after[0.0]["cv"], cv_after[1.0]["cv"]))
    dist = np.min(np.linalg.norm(Q0[:, None, :] - P[rib][None, :, :], axis=2), axis=1)
    print("new ribbon point to nearest old point: mean %.2f max %.2f units" % (
        dist.mean(), dist.max()))

    occl, score, s0 = occl_weight(P2, c2, idx2, {0.0: ns0, 1.0: ns1})
    print("occl p50 %.3f p95 %.3f max %.3f frac>0.15 %.3f (s0 %.3f)" % (
        np.percentile(occl, 50), np.percentile(occl, 95), occl.max(),
        float((occl > 0.15).mean()), s0))
    print("u ribbon [%.4f %.4f] ring [%.4f %.4f]" % (
        u2[c2 < 0.5].min(), u2[c2 < 0.5].max(), u2[c2 > 0.5].min(), u2[c2 > 0.5].max()))

    write_texture(P2, N2, s2, q2, c2, u2, occl, cv_before, cv_after, d)
    os.makedirs(os.path.dirname(NPZ), exist_ok=True)
    np.savez(NPZ, P=P2, N=N2, s=s2, q=q2, c=c2, u=u2, occl=occl, idx=idx2)


def write_texture(P, N, s, q, c, u, occl, cv_before, cv_after, d):
    n = len(P)

    def q16(v):
        x = (np.clip(v, -RANGE, RANGE - 1e-6) + RANGE) / (2.0 * RANGE)
        return np.clip(np.round(x * 65535.0), 0, 65535).astype(np.int64)

    X, Y, Z = q16(P[:, 0]), q16(P[:, 1]), q16(P[:, 2])

    def b(v):
        return ((np.clip(v, 0.0, 1.0) * 255.0) + 0.5).astype(np.int64)

    nm = np.clip(np.round(N * 127.5 + 127.5), 0, 255).astype(np.int64)
    total = 5 * n
    rows = (total + WIDTH - 1) // WIDTH
    buf = np.zeros((rows * WIDTH, 3), dtype=np.uint8)
    t0, t1, t2, t3, t4 = (5 * np.arange(n) + k for k in range(5))
    buf[t0, 0] = (X >> 8) & 0xFF
    buf[t0, 1] = X & 0xFF
    buf[t0, 2] = (Y >> 8) & 0xFF
    buf[t1, 0] = Y & 0xFF
    buf[t1, 1] = (Z >> 8) & 0xFF
    buf[t1, 2] = Z & 0xFF
    buf[t2, :] = nm
    buf[t3, 0] = b(s)
    buf[t3, 1] = b(q)
    buf[t3, 2] = b(c)
    buf[t4, 0] = b(u)
    buf[t4, 1] = b(occl)
    buf[t4, 2] = 0

    rgba = np.zeros((rows * WIDTH, 4), dtype=np.uint8)
    rgba[:, :3] = buf
    rgba[:, 3] = 255
    out_png = os.path.join(HERE, "knot-points2.png")
    Image.frombytes("RGBA", (WIDTH, rows), rgba.tobytes()).convert("RGB").save(
        out_png, optimize=True)

    meta = {
        "N": int(n),
        "width": WIDTH,
        "rows": int(rows),
        "texels": int(total),
        "stride": 5,
        "range": [-RANGE, RANGE],
        "quant": 65535.0 / (2.0 * RANGE),
        "height": float(d.get("H", 900)),
        "classCounts": {str(int(k)): int(v) for k, v in
                        zip(*np.unique(c.astype(int), return_counts=True))},
        "sRange": [float(s.min()), float(s.max())],
        "qRange": [float(q.min()), float(q.max())],
        "uRange": [float(u.min()), float(u.max())],
        "occlRange": [float(occl.min()), float(occl.max())],
        "texel4": "(u*255, occl*255, 0)",
        "ribbonResampled": True,
        "nnCvBefore": {k: float(v["cv"]) for k, v in cv_before.items()},
        "nnCvAfter": {k: float(v["cv"]) for k, v in cv_after.items()},
        "nnBefore": {k: v for k, v in cv_before.items()},
        "nnAfter": {k: v for k, v in cv_after.items()},
        "file": out_png,
    }
    with open(os.path.join(HERE, "knot-points2.meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print("points", n, "texture", WIDTH, "x", rows, "->", out_png)
    print("classes", meta["classCounts"])


if __name__ == "__main__":
    main()
