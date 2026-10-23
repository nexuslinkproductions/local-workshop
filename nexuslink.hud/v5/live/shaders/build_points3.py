#!/usr/bin/env python3
"""Build knot-points3.png: even (blue noise) point sets for ribbon and ring.

Same 5 texel layout as build_points2.py (2048 x 11) with one change:
texel4 = (u * 255, occl * 255, crowd * 255); crowd is 1 on an isolated strand and
falls toward ~0.35 where several layers of dots stack (crossings), the shader
multiplies alpha by it so overlapping depth layers never add up to white blobs.

Sampling: both tubes are cylinders around a centreline. A point is
  P = C(a) + x * U + s * sqrt(r^2 - x^2) * V
with arc length a, lateral offset x in [-r, r] and depth side s = +1 (front)
or -1 (back). The blue noise (Mitchell best candidate, K candidates, wrapped in
a) is drawn in the PROJECTED plane (a, x), so the two sides together are evenly
spaced as seen from the front, which is what the nearest neighbour CV measures.
Sampling order gives q = rank / N, so the thinning of the density breath
(q > thr hides a point) removes the last, still blue-noise-complementary, points.
"""
import json, os, sys
import numpy as np
from PIL import Image
from scipy.spatial import cKDTree
import build_points2 as b2

HERE = os.path.dirname(os.path.abspath(__file__))
K = 40            # candidates per point
FRONT_FRAC = 0.62


def blue_2d(n, L, W, rng, k=K):
    """best candidate in [0, L) wrapped x [-W, W] (not wrapped)"""
    pts = np.empty((n, 2))
    pts[0] = (rng.random() * L, (rng.random() * 2 - 1) * W)
    pad = 0.12 * L
    for j in range(1, n):
        c = np.c_[rng.random(k) * L, (rng.random(k) * 2 - 1) * W]
        p = pts[:j]
        # wrap copies only near the seam, cheap enough for a few thousand points
        copies = [p]
        lo = p[p[:, 0] < pad] + [L, 0.0]
        hi = p[p[:, 0] > L - pad] - [L, 0.0]
        if len(lo): copies.append(lo)
        if len(hi): copies.append(hi)
        tree = cKDTree(np.vstack(copies))
        d, _ = tree.query(c, 1)
        pts[j] = c[np.argmax(d)]
    return pts


def make_placer(C, ns, r_slice):
    arc, L = b2.cum_arc(C)
    T, U, V = b2.frame(C)
    V = np.where(V[:, 2:3] < 0.0, -V, V)       # V towards the camera (+z)
    rbar = float(r_slice.mean())

    def place(a, xn, s):
        a = np.mod(a, L)
        pos = a / L * ns
        i0 = np.floor(pos).astype(np.int64) % ns
        i1 = (i0 + 1) % ns
        f = (pos - np.floor(pos))[:, None]
        Cc = C[i0] * (1 - f) + C[i1] * f
        rr = r_slice[i0] * (1 - f[:, 0]) + r_slice[i1] * f[:, 0]
        Uc = U[i0] * (1 - f) + U[i1] * f
        Vc = V[i0] * (1 - f) + V[i1] * f
        Uc /= np.linalg.norm(Uc, axis=1)[:, None]
        Vc /= np.linalg.norm(Vc, axis=1)[:, None]
        x = np.clip(xn, -1, 1) * rr
        depth = np.sqrt(np.maximum(rr ** 2 - x ** 2, 0.0))
        nrm = (x[:, None] * Uc + (s * depth)[:, None] * Vc) / rr[:, None]
        nrm /= np.linalg.norm(nrm, axis=1)[:, None]
        return Cc + rr[:, None] * nrm, nrm, i0

    return place, L, rbar


def relax(place, L, a, xn, s, iters=120, near=1e9, step=0.5):
    """repel neighbours in SCREEN space (front pose) along the strand only.
    Pairs from different strand passes (arc distance > near * spacing) are ignored,
    so the crossings keep their two overlapping layers."""
    n = len(a)
    for it in range(iters):
        Q, _, _ = place(a, xn, s)
        S = b2.front(Q)
        d0 = np.median(cKDTree(S).query(S, 2)[0][:, 1]) * 1.25
        tree = cKDTree(S)
        pairs = tree.query_pairs(d0, output_type="ndarray")
        if len(pairs) == 0:
            break
        i, j = pairs[:, 0], pairs[:, 1]
        da = np.abs(a[i] - a[j]); da = np.minimum(da, L - da)
        keep = da < near * d0 / 0.6          # screen px -> knot units
        i, j = i[keep], j[keep]
        v = S[i] - S[j]
        dist = np.maximum(np.linalg.norm(v, axis=1), 1e-3)
        f = ((d0 - dist) / dist)[:, None] * v
        ff = (s[i] > 0) & (s[j] > 0) & (dist < d0 * 1.4)
        f = f + np.where(ff, (d0 * 1.4 - dist) / dist, 0.0)[:, None] * v * 0.6
        disp = np.zeros((n, 2))
        np.add.at(disp, i, f); np.add.at(disp, j, -f)
        eps_a, eps_x = 1.0, 0.02
        Sa = b2.front(place(a + eps_a, xn, s)[0]); Sx = b2.front(place(a, xn + eps_x, s)[0])
        Ja = (Sa - S) / eps_a; Jx = (Sx - S) / eps_x
        det = Ja[:, 0] * Jx[:, 1] - Ja[:, 1] * Jx[:, 0]
        det = np.where(np.abs(det) < 1e-6, 1e-6, det)
        dda = (disp[:, 0] * Jx[:, 1] - disp[:, 1] * Jx[:, 0]) / det
        ddx = (Ja[:, 0] * disp[:, 1] - Ja[:, 1] * disp[:, 0]) / det
        a = a + step * np.clip(dda, -3.0, 3.0)
        xn = np.clip(xn + step * np.clip(ddx, -0.15, 0.15), -0.999, 0.999)
    return a, xn


def build_class(C, ns, r_slice, n, rng, front_frac, do_relax=True):
    place, L, rbar = make_placer(C, ns, r_slice)
    pts = blue_2d(n, L, rbar, rng)
    a, xn = pts[:, 0], pts[:, 1] / rbar
    # generation order = rank: the first front_frac of the points are the front layer, so
    # the front layer is itself blue noise and the density breath removes back points first
    s = np.where(np.arange(n) < int(round(front_frac * n)), 1.0, -1.0)
    if do_relax:
        a, xn = relax(place, L, a, xn, s)
    Q, nrm, i0 = place(a, xn, s)
    u = np.mod(a, L) / L
    q = np.arange(n) / float(n - 1)
    return Q, nrm, u, q, i0


def main():
    d = json.load(open(b2.SRC))
    n = int(d["n"])
    P = np.asarray(d["p"], dtype=np.float64).reshape(n, 3)
    NR = np.asarray(d["nr"], dtype=np.float64).reshape(n, 3)
    c = np.asarray(d["c"], dtype=np.float64)
    s_src = np.asarray(d["s"], dtype=np.float64)
    C0 = np.asarray(d["cl"][0], dtype=np.float64).reshape(-1, 3)
    C1 = np.asarray(d["cl"][1], dtype=np.float64).reshape(-1, 3)
    ns0, ns1 = len(C0), len(C1)
    rib = c < 0.5
    idx = np.where(rib, b2.slice_index(s_src, ns0), b2.slice_index(s_src, ns1))
    r0 = b2.slice_radius(P[rib], C0, idx[rib], ns0)
    r1 = b2.slice_radius(P[~rib], C1, idx[~rib], ns1)
    n0, n1 = int(rib.sum()), int((~rib).sum())
    rng = np.random.default_rng(23)
    print("ribbon r mean %.2f ring r mean %.2f, n %d + %d" % (r0.mean(), r1.mean(), n0, n1))
    Q0, N0, u0, q0, i0 = build_class(C0, ns0, r0, n0, rng, FRONT_FRAC)
    Q1, N1, u1, q1, i1 = build_class(C1, ns1, r1, n1, rng, FRONT_FRAC)
    P2 = np.vstack([Q0, Q1]); N2 = np.vstack([N0, N1])
    c2 = np.r_[np.zeros(n0), np.ones(n1)]
    u2 = np.r_[u0, u1]; q2 = np.r_[q0, q1]
    idx2 = np.r_[i0, i1]
    cv = {k: b2.nn_stats(b2.front(P2[c2 == k])) for k in (0.0, 1.0)}
    print("projected nn CV ribbon %.3f ring %.3f (mean px %.2f / %.2f)" % (
        cv[0.0]["cv"], cv[1.0]["cv"], cv[0.0]["mean"], cv[1.0]["mean"]))
    occl, score, s0 = b2.occl_weight(P2, c2, idx2, {0.0: ns0, 1.0: ns1})
    # crowding: neighbours within RHO px of the front projection that belong to
    # another strand pass (other class, or arc distance > 60 units) count as stacked
    S = b2.front(P2)
    RHO = 6.0
    Ls = np.where(c2 < 0.5, 3536.4673600501646, 2442.3249327113917)
    nbrs = cKDTree(S).query_ball_point(S, RHO)
    same = np.zeros(len(P2)); other = np.zeros(len(P2))
    for i, lst in enumerate(nbrs):
        for j in lst:
            if j == i:
                continue
            du = abs(u2[i] - u2[j]); du = min(du, 1.0 - du)
            if c2[i] == c2[j] and du * Ls[i] < 60.0:
                same[i] += 1
            else:
                other[i] += 1
    ref = float(np.median(same[same > 0]))
    crowd = np.clip(1.0 / (1.0 + other / ref), 0.35, 1.0)
    print("crowd ref same count %.1f, p5 %.2f p50 %.2f min %.2f, frac<0.8 %.3f" % (
        ref, np.percentile(crowd, 5), np.percentile(crowd, 50), crowd.min(), (crowd < 0.8).mean()))
    # nn CV with the crossing layers removed (crowd < 0.8 ignored)
    free = crowd >= 0.8
    for k in (0.0, 1.0):
        m = (c2 == k) & free
        print("  nn CV class %d without crossing points: %.3f (n %d)" % (k, b2.nn_stats(S[m])["cv"], m.sum()))
    extra = {"note": "even sampling in the projected plane, crowd in texel4.b",
             "nnCvBefore": {"0.0": 0.45778823178177036, "1.0": 0.7453012640611779},
             "nnCvAfter": {str(k): v["cv"] for k, v in cv.items()},
             "nnAfter": {str(k): v for k, v in cv.items()},
             "nnCvNoCrossing": {"0.0": b2.nn_stats(S[(c2==0)&free])["cv"], "1.0": b2.nn_stats(S[(c2==1)&free])["cv"]},
             "crowd": {"ref": ref, "rho_px": RHO, "min": float(crowd.min()),
                       "fracBelow08": float((crowd < 0.8).mean())},
             "ribbonResampled": True, "seed": 23, "frontFrac": FRONT_FRAC}
    b2.FILES["even"] = ("knot-points3.png", "knot-points3.meta.json")
    # reuse the writer, then patch texel4.b with crowd
    out_png = b2.write_texture(P2, N2, u2, q2, c2, u2, occl, extra, "even")
    im = np.asarray(Image.open(out_png).convert("RGB")).copy()
    flat = im.reshape(-1, 3)
    flat[5 * np.arange(len(P2)) + 4, 2] = np.clip(np.round(crowd * 255), 0, 255).astype(np.uint8)
    Image.fromarray(im).save(out_png, optimize=True)
    np.savez(os.path.expanduser("~/.hermes/cache/scratch/hud-live/work2/K1c/points3.npz"),
             P=P2, N=N2, u=u2, q=q2, c=c2, occl=occl, crowd=crowd)


if __name__ == "__main__":
    main()
