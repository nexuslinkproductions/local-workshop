#!/usr/bin/env python3
"""Build the v2 knot point texture (K3), one of three variants.

  --variant noise  best-candidate blue-noise resample of the tube surface
                   -> knot-points2.png / knot-points2.meta.json  (the shipped one)
  --variant keep   the ORIGINAL positions and normals, only u and occl corrected
                   -> knot-points2-keep.png / knot-points2-keep.meta.json
  --variant jit    original positions moved on the tube surface by 0.25..0.35 of
                   the local on-surface nearest neighbour spacing, random
                   tangent direction, deterministic -> knot-points2-jit.png

Layout: 5 texels per point at linear texel index 5*i+k, row width WIDTH=2048.
  texel0 = (x_hi, x_lo, y_hi)
  texel1 = (y_lo, z_hi, z_lo)      x,y,z 16 bit fixed point over [-512, 512)
  texel2 = (nx, ny, nz) * 127.5 + 127.5
  texel3 = (s * 255, q * 255, class * 255)      s = u
  texel4 = (u * 255, occl * 255, 0)     u true arc length 0..1 per class,
                                        occl under-strand weight 0..1 (front pose)
RGB, alpha always 255. Nearest sampling, no mipmap.
"""
import argparse
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
NPZ_DIR = os.path.expanduser("~/.hermes/cache/scratch/hud-live/work2/K3")
WIDTH = 2048
RANGE = 512.0
KNOT_PX = 540.0          # screen px per 900 knot units at the hero size
CAM_D = 2.7 * 900.0
SCALE = KNOT_PX / 900.0  # 0.6

FILES = {
    "noise": ("knot-points2.png", "knot-points2.meta.json"),
    "keep": ("knot-points2-keep.png", "knot-points2-keep.meta.json"),
    "jit": ("knot-points2-jit.png", "knot-points2-jit.meta.json"),
}


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
    """Best-candidate (Mitchell) blue noise on the closed tube parameter domain."""
    pts = np.empty((n, 2))
    pts[0] = (rng.random() * L, rng.random() * circ)
    box = [L, circ]
    for j in range(1, n):
        cand = np.c_[rng.random(10) * L, rng.random(10) * circ]
        best, bestd = 0, -1.0
        tree = cKDTree(pts[:j] % np.array(box), boxsize=box)
        for c in range(10):
            d, _ = tree.query(cand[c] % np.array(box), k=1)
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


# ------------------------------------------------------- on-surface distances
def surf_min_dists(x, y, L, Y, chunk=800, self_=None):
    """Nearest neighbour distance in the unwrapped tube metric (arc, width).

    x is arc length on the closed loop (period L), y is circumferential length
    (period Y). Both in knot units. Exact pairwise, chunked to stay light.
    """
    n = len(x)
    out = np.full(n, np.inf)
    for st in range(0, n, chunk):
        e = min(n, st + chunk)
        dx = np.abs(x[st:e, None] - x[None, :])
        dx = np.minimum(dx, L - dx)
        dy = np.abs(y[st:e, None] - y[None, :])
        dy = np.minimum(dy, Y - dy)
        D = np.hypot(dx, dy)
        D[np.arange(e - st), np.arange(st, e)] = np.inf
        out[st:e] = D.min(1)
    return out


def tube_coords(P, C, idx, ns):
    """Unwrapped surface coordinates of points known to sit on slice idx."""
    arccum, L = cum_arc(C)
    T, U, V = frame(C)
    r_slice = slice_radius(P, C, idx, ns)
    rad = P - C[idx]
    r = np.linalg.norm(rad, axis=1)
    th = np.arctan2(np.sum(rad * V[idx], 1), np.sum(rad * U[idx], 1))
    x = arccum[idx]
    y = th * r_slice[idx]
    return dict(x=x, y=y, th=th, r=r, L=L, r_slice=r_slice, T=T, U=U, V=V,
                nrm0=(rad / np.maximum(r, 1e-9)[:, None]),
                Y=2.0 * np.pi * float(r_slice.mean()))


def jitter_ribbon(P, C, idx, ns, rng, lo=0.25, hi=0.35, dmin_frac=0.6, rounds=12):
    """Move each point along the tube surface by a fraction of the local spacing.

    Displacement d = mag * (cos(phi) * T + sin(phi) * E) with T the local tangent
    and E the circumferential direction, mag in lo..hi times the point's own
    on-surface nearest neighbour distance. The displaced point is then put back
    on the tube surface (radial correction against the nearest centreline
    sample, same per-slice radius plus the point's own radial offset), so it
    never leaves the surface and the 3D move stays of order mag. Points that
    come closer than dmin_frac of the original minimum spacing have their
    offset halved and are rebuilt (deterministic, up to <rounds> times).
    """
    g = tube_coords(P, C, idx, ns)
    x, y, L, Y = g["x"], g["y"], g["L"], g["Y"]
    delta = g["r"] - g["r_slice"][idx]   # own radial offset, kept when rebuilding
    nn0 = surf_min_dists(x, y, L, Y)
    dmin0 = float(nn0.min())
    mag0 = rng.uniform(lo, hi, len(x)) * nn0
    phi = rng.uniform(0.0, 2.0 * np.pi, len(x))
    Tv = g["T"][idx]
    E = np.cross(g["nrm0"], Tv)
    E /= np.linalg.norm(E, axis=1)[:, None] + 1e-12
    d3 = (mag0 * np.cos(phi))[:, None] * Tv + (mag0 * np.sin(phi))[:, None] * E
    scale = np.ones(len(x))
    cand = (idx[:, None] + np.arange(-8, 9)[None, :]) % ns
    ac, Lc = cum_arc(C)

    def place(sc):
        Qr = P + d3 * sc[:, None]
        dd = np.linalg.norm(C[cand] - Qr[:, None, :], axis=2)
        jj = cand[np.arange(len(P)), np.argmin(dd, axis=1)]
        rad = Qr - C[jj]
        rq = np.linalg.norm(rad, axis=1)
        nrm = rad / np.maximum(rq, 1e-9)[:, None]
        rr = g["r_slice"][jj] + delta
        Q = C[jj] + rr[:, None] * nrm
        th = np.arctan2(np.sum(nrm * g["V"][jj], 1), np.sum(nrm * g["U"][jj], 1))
        return Q, nrm, jj, rr, th, th * rr

    thr = dmin_frac * dmin0

    def pairs_under(x2, y2, lim, chunk=800):
        out = []
        nn = len(x2)
        for st in range(0, nn, chunk):
            e = min(nn, st + chunk)
            ddx = np.abs(x2[st:e, None] - x2[None, :])
            ddx = np.minimum(ddx, L - ddx)
            ddy = np.abs(y2[st:e, None] - y2[None, :])
            ddy = np.minimum(ddy, Y - ddy)
            D = np.hypot(ddx, ddy)
            D[np.arange(e - st), np.arange(st, e)] = np.inf
            ii, j = np.where(D < lim)
            if len(ii):
                out.append(np.c_[ii + st, j])
        return np.vstack(out) if out else np.zeros((0, 2), dtype=np.int64)

    Q = nrm = None
    jj = rr = th = y2 = x2 = None
    for it in range(rounds):
        Q, nrm, jj, rr, th, y2 = place(scale)
        x2 = ac[jj] + 0.0
        x2 = np.mod(x2 + np.zeros(len(x2)), L)
        pairs = pairs_under(x2, y2, thr)
        if len(pairs) == 0:
            break
        bad = np.unique(pairs)
        scale[bad] *= 0.5
        print("  jitter round %d: %d pairs under %.2f units on the surface, %d points halved"
              % (it + 1, len(pairs), thr, len(bad)))
    disp = np.linalg.norm(Q - P, axis=1)
    d, _ = cKDTree(Q).query(Q, 2)
    print("  jitter: local spacing mean %.2f min %.2f | mag mean %.2f max %.2f units"
          % (nn0.mean(), nn0.min(), mag0.mean(), mag0.max()))
    print("  jitter: moved mean %.2f p95 %.2f max %.2f units | final 3D NN min %.2f | "
          "surface NN min %.2f (floor %.2f) | halved %d"
          % (disp.mean(), np.percentile(disp, 95), disp.max(), d[:, 1].min(),
             float(surf_min_dists(ac[jj], th * rr, L, Y).min()), thr,
             int((scale < 1.0).sum())))
    u = ac[jj] / L
    return Q, nrm, u, jj, rr, dict(nn0=nn0, dmin0=dmin0, mag=mag0, scale=scale, thr=thr,
                                  disp=disp)


def arccum_u(j, C):
    a, L = cum_arc(C)
    return a[j] / L


def occl_weight(P, cls, idx, nsl, reach=16.0, sig=8.0, dz=8.0):
    """Front-pose under-strand weight in [0,1) (unchanged K3 method)."""
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


def write_texture(P, N, s, q, c, u, occl, meta_extra, variant):
    n = len(P)
    png, metaname = FILES[variant]

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
    out_png = os.path.join(HERE, png)
    Image.frombytes("RGBA", (WIDTH, rows), rgba.tobytes()).convert("RGB").save(
        out_png, optimize=True)

    meta = {
        "N": int(n),
        "width": WIDTH,
        "rows": int(rows),
        "texels": int(total),
        "stride": 5,
        "variant": variant,
        "range": [-RANGE, RANGE],
        "quant": 65535.0 / (2.0 * RANGE),
        "height": 900.0,
        "classCounts": {str(int(k)): int(v) for k, v in
                        zip(*np.unique(c.astype(int), return_counts=True))},
        "sRange": [float(s.min()), float(s.max())],
        "qRange": [float(q.min()), float(q.max())],
        "uRange": [float(u.min()), float(u.max())],
        "occlRange": [float(occl.min()), float(occl.max())],
        "texel4": "(u*255, occl*255, 0)",
        "ribbonResampled": bool(variant == "noise"),
        "ribbonJittered": bool(variant == "jit"),
        "file": out_png,
    }
    meta.update(meta_extra)
    with open(os.path.join(HERE, metaname), "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print("points", n, "texture", WIDTH, "x", rows, "->", out_png)
    return out_png


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", choices=["keep", "jit", "noise"], default="keep")
    ap.add_argument("--npz", default=None)
    args = ap.parse_args()
    var = args.variant

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
    arc0, L0 = cum_arc(C0)
    arc1, L1 = cum_arc(C1)

    cnt0 = np.bincount(idx[rib], minlength=ns0)
    print("variant", var, "| slices ribbon", ns0, "points/slice", np.unique(cnt0),
          "| ring", ns1, "points/slice", np.unique(np.bincount(idx[~rib], minlength=ns1)))
    cv_before = {k: nn_stats(front(P[c == k])) for k in (0.0, 1.0)}
    extra = {}
    n0 = int(rib.sum())
    u1 = arc1[idx[~rib]] / L1

    if var == "keep":
        Q0, N0 = P[rib].copy(), NR[rib].copy()
        u0 = arc0[idx[rib]] / L0
        i0 = idx[rib]
        rr0 = np.linalg.norm(Q0 - C0[i0], axis=1)
        extra["note"] = "original positions and normals, corrected u and occl, no resampling"
    elif var == "jit":
        rng = np.random.default_rng(11)
        Q0, N0, u0, i0, rr0, jinfo = jitter_ribbon(P[rib], C0, idx[rib], ns0, rng)
        extra["jitter"] = {
            "seed": 11,
            "fractionOfLocalSpacing": [0.25, 0.35],
            "localSpacingMean": float(jinfo["nn0"].mean()),
            "localSpacingMin": float(jinfo["nn0"].min()),
            "displacementMean": float(jinfo["mag"].mean()),
            "displacementMax": float(jinfo["mag"].max()),
            "separationFloor": float(jinfo["thr"]),
            "origMinSpacing": float(jinfo["dmin0"]),
            "pointsWithReducedOffset": int((jinfo["scale"] < 1.0).sum()),
            "minPairDistance": float(cKDTree(Q0).query(Q0, 2)[0][:, 1].min()),
        }
        extra["note"] = "original positions jittered on the tube surface, normals recomputed radial"
    else:
        rng = np.random.default_rng(7)
        Q0, N0, u0, i0, rr0 = resample_ribbon(P[rib], C0, idx[rib], ns0, n0, rng)
        extra["note"] = "best-candidate blue-noise resample of the tube surface"

    P2 = np.vstack([Q0, P[~rib]])
    N2 = np.vstack([N0, NR[~rib]])
    q2 = np.r_[q[rib], q[~rib]]
    c2 = np.r_[c[rib], c[~rib]]
    u2 = np.r_[u0, u1]
    s2 = u2.copy()
    idx2 = np.r_[i0, idx[~rib]]

    cv_after = {k: nn_stats(front(P2[c2 == k])) for k in (0.0, 1.0)}
    print("CV before ribbon %.3f ring %.3f | after ribbon %.3f ring %.3f" % (
        cv_before[0.0]["cv"], cv_before[1.0]["cv"],
        cv_after[0.0]["cv"], cv_after[1.0]["cv"]))

    occl, score, s0 = occl_weight(P2, c2, idx2, {0.0: ns0, 1.0: ns1})
    print("occl p50 %.3f p95 %.3f max %.3f frac>0.15 %.3f (s0 %.3f)" % (
        np.percentile(occl, 50), np.percentile(occl, 95), occl.max(),
        float((occl > 0.15).mean()), s0))
    print("u ribbon [%.4f %.4f] ring [%.4f %.4f]" % (
        u2[c2 < 0.5].min(), u2[c2 < 0.5].max(), u2[c2 > 0.5].min(), u2[c2 > 0.5].max()))

    extra["nnCvBefore"] = {k: float(v["cv"]) for k, v in cv_before.items()}
    extra["nnCvAfter"] = {k: float(v["cv"]) for k, v in cv_after.items()}
    extra["nnAfter"] = {k: v for k, v in cv_after.items()}
    extra["occlStats"] = {"p50": float(np.percentile(occl, 50)),
                          "p90": float(np.percentile(occl, 90)),
                          "p99": float(np.percentile(occl, 99)),
                          "max": float(occl.max()),
                          "fracAbove015": float((occl > 0.15).mean())}
    write_texture(P2, N2, s2, q2, c2, u2, occl, extra, var)

    npz = args.npz or os.path.join(NPZ_DIR, "var_%s.npz" % var)
    os.makedirs(os.path.dirname(npz), exist_ok=True)
    np.savez(npz, P=P2, N=N2, s=s2, q=q2, c=c2, u=u2, occl=occl, idx=idx2,
             nr_src=NR, idx_src=idx, P_src=P)
    print("npz", npz)


if __name__ == "__main__":
    main()
