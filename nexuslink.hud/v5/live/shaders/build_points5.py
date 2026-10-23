#!/usr/bin/env python3
"""Build the v5 knot point texture: the fine particle strand (KNOT-SPEC-R5 sections 1-3).

Writes knot-points5.png (2048 wide, 11 texels per point) and knot-points5.meta.json
next to this file, or into --out-dir. Reuses build_points2 (source path, frames,
cumulative arc) and build_points4 (cross-section recovery, morph forms, constants);
neither file is edited.

  python3 build_points5.py                       production build (real forms 1 and 2)
  python3 build_points5.py --rest-only           milestone D1: forms equal to rest
  python3 build_points5.py --out-dir DIR         scratch build (determinism check)
  python3 build_points5.py --out-dir DIR --rest-yaw-deg 11 --rest-pitch-deg -6
                                                 comparison bake only, not production
"""
import argparse
import hashlib
import itertools
import json
import math
import os
import sys
import time

import numpy as np
from PIL import Image
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import build_points2 as b2  # noqa: E402
import build_points4 as b4  # noqa: E402

PNG_NAME = "knot-points5.png"
META_NAME = "knot-points5.meta.json"
OLD_PNG = os.path.join(HERE, "knot-points4.png")
SEED = 5005
N_PART = {0: 24000, 1: 9000}
SIGMA_V = 0.36
RAD_TUBE = {0: 20.0, 1: 5.5}
Z_OFF = 0.55            # front half of a round tube: z offset as share of RAD_TUBE
Z_NOISE = 0.8
GAP = 3.2               # px of dark gap around an over strand
DZ_OVER = 14.0          # units: a sample counts as over only if this much nearer
ARC_SKIP = 60           # samples: same-strand samples closer than this are not a crossing
KNOT_PX = 540.0
H = 900.0
SC = KNOT_PX / H        # 0.6 px per unit
CAM = 2.7 * H
WIDTH = 2048
STRIDE = 11
RANGE = 512.0
RMIN = {0: 0.55, 1: 0.55}
RMAX = {0: 1.75, 1: 1.5}


# ------------------------------------------------------------------ projection
def rot_pose(P, yaw_deg, pitch_deg):
    """Rest pose rotation as knot_r.rot (yaw about y, then pitch about x). Identity at 0, 0."""
    if yaw_deg == 0.0 and pitch_deg == 0.0:
        return P
    cy, sy = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
    cp, sp = math.cos(math.radians(pitch_deg)), math.sin(math.radians(pitch_deg))
    x1 = P[:, 0] * cy + P[:, 2] * sy
    z1 = -P[:, 0] * sy + P[:, 2] * cy
    return np.c_[x1, P[:, 1] * cp - z1 * sp, P[:, 1] * sp + z1 * cp]


def project(Q):
    """Screen px at knotPx 540 (knot_r.proj): perspective k = CAM / (CAM - z)."""
    k = CAM / (CAM - Q[:, 2])
    return np.c_[Q[:, 0] * k * SC, Q[:, 1] * k * SC], k


def pivot_px(P):
    """knot_port.measure_pivot_px formula on positions P (units): mean screen offset."""
    k = CAM / (CAM - P[:, 2])
    fs = k * (540.0 / H)
    return float(np.mean(P[:, 0] * fs)), float(np.mean(P[:, 1] * fs))


# ------------------------------------------------------------------ rest set
def build_rest(CL):
    """Spec section 1: stratified arc jitter, gaussian lateral offset, front half tube."""
    rng = np.random.default_rng(SEED)
    parts = {k: [] for k in ("P", "N", "u", "lat", "q", "cls", "idx")}
    for c in (0, 1):
        C = CL[c]
        n = len(C)
        Nc = N_PART[c]
        R = RAD_TUBE[c]
        t = np.roll(C, -2, 0) - np.roll(C, 2, 0)          # as knot_r.py
        t[:, 2] = 0.0
        t /= np.hypot(t[:, 0], t[:, 1])[:, None]
        seg = (np.arange(Nc) + rng.random(Nc)) / Nc * n
        i0 = np.floor(seg).astype(np.int64) % n
        i1 = (i0 + 1) % n
        f = (seg - np.floor(seg))[:, None]
        P = C[i0] * (1.0 - f) + C[i1] * f
        T = t[i0]
        v = np.clip(rng.normal(0.0, SIGMA_V, Nc), -1.0, 1.0)
        sv = np.sqrt(np.clip(1.0 - v * v, 0.0, None))
        Q = P + np.c_[-T[:, 1], T[:, 0], np.zeros(Nc)] * (v * R)[:, None]
        Q[:, 2] += sv * R * Z_OFF + rng.normal(0.0, Z_NOISE, Nc)
        q = rng.random(Nc)
        # outward surface normal of the front half: same sense as the old 'noise' normal
        Nv = np.c_[-T[:, 1] * v, T[:, 0] * v, sv]
        Nv /= np.linalg.norm(Nv, axis=1)[:, None]
        parts["P"].append(Q)
        parts["N"].append(Nv)
        parts["u"].append(seg / n)
        parts["lat"].append(np.abs(v))
        parts["q"].append(q)
        parts["cls"].append(np.full(Nc, c, dtype=np.int64))
        parts["idx"].append(i0)
    return {k: np.concatenate(v) for k, v in parts.items()}


def knock_weights(P, cls, idx, CL, yaw_deg=0.0, pitch_deg=0.0):
    """Knockout weight (1 = fully cut) by KD tree, chunked (spec section 1, knot_r.py rule)."""
    Qp = rot_pose(P, yaw_deg, pitch_deg)
    xy, _ = project(Qp)
    zs, xys, ks = [], [], []
    for c in (0, 1):
        Qc = rot_pose(CL[c], yaw_deg, pitch_deg)
        xyc, kc = project(Qc)
        zs.append(Qc[:, 2])
        xys.append(xyc)
        ks.append(kc)
    allz = np.r_[zs[0], zs[1]]
    allxy = np.vstack(xys)
    allhw = np.r_[ks[0] * RAD_TUBE[0], ks[1] * RAD_TUBE[1]] * SC
    allid = np.r_[np.zeros(len(CL[0]), np.int64), np.ones(len(CL[1]), np.int64)]
    allidx = np.r_[np.arange(len(CL[0])), np.arange(len(CL[1]))]
    nlen = {0: len(CL[0]), 1: len(CL[1])}
    RQ = float((0.9 * allhw + GAP).max()) + 0.5
    tree = cKDTree(allxy)
    m = np.ones(len(P))
    nP = len(P)
    chunk = 3000
    for st in range(0, nP, chunk):
        e = min(nP, st + chunk)
        lists = tree.query_ball_point(xy[st:e], r=RQ)
        lens = np.fromiter((len(x) for x in lists), dtype=np.int64, count=e - st)
        tot = int(lens.sum())
        if tot == 0:
            continue
        s = np.fromiter(itertools.chain.from_iterable(lists), dtype=np.int64, count=tot)
        j = np.repeat(np.arange(st, e), lens)
        cj = cls[j]
        ij = idx[j]
        nn = np.where(cj == 0, nlen[0], nlen[1])
        dsi = np.abs(allidx[s] - ij)
        dsi = np.minimum(dsi, nn - dsi)
        skip = (allid[s] == cj) & (dsi < ARC_SKIP)
        dz = allz[s] - Qp[j, 2]
        dd = np.hypot(allxy[s, 0] - xy[j, 0], allxy[s, 1] - xy[j, 1])
        hw = allhw[s]
        keep = (~skip) & (dz > DZ_OVER) & (dd < 0.9 * hw + GAP)
        val = np.clip((dd - 0.9 * hw) / GAP, 0.0, 1.0)
        np.minimum.at(m, j[keep], val[keep])
    return 1.0 - m


# ------------------------------------------------------------------ morph forms
def lift_centrelines(C0, C1, phi, cross):
    """Form 1 centre lines exactly as build_points4.main (u from the centre line arc)."""
    a0, L0 = b2.cum_arc(C0)
    a1, L1 = b2.cum_arc(C1)
    u0c, u1c = a0 / L0, a1 / L1
    rho0 = np.hypot(C0[:, 0], C0[:, 1])
    w0 = np.clip((rho0 - np.percentile(rho0, 20)) / (rho0.max() - np.percentile(rho0, 20)), 0, 1) ** 2
    N0c = C0.copy()
    N0c[:, :2] *= (1.0 - b4.TIP_PULL * w0)[:, None]
    N0c[:, 2] += b4.Z_LIFT * np.sin(2 * np.pi * 3 * u0c + phi)
    N0c = b4.rot_x(N0c, b4.TILT)
    N1c = C1.copy()
    N1c[:, 2] += b4.Z_RING * np.sin(2 * np.pi * 1 * u1c + phi + 0.7)
    N1c = b4.rot_x(N1c, b4.TILT)
    return N0c, N1c


def cl_at(C, uu):
    ns = len(C)
    pos = np.mod(uu, 1.0) * ns
    i0 = np.floor(pos).astype(np.int64) % ns
    i1 = (i0 + 1) % ns
    f = (pos - np.floor(pos))[:, None]
    return C[i0] * (1 - f) + C[i1] * f


def make_forms(P, N, cls, CL, phi, cross):
    """Form 1 lift (build_points4 rebuild on the new set) and form 2 bloom (6 orbit groups)."""
    C0, C1 = CL[0], CL[1]
    rib = cls == 0
    n = len(P)
    N0c, N1c = lift_centrelines(C0, C1, phi, cross)
    cs0 = b4.cross_sec(C0, P[rib])
    cs1 = b4.cross_sec(C1, P[~rib])
    res_all = np.r_[cs0["res"], cs1["res"]]
    res_max = float(res_all.max())
    # the new set carries the z offset and gaussian lateral spread on top of the old tube, so the
    # recovery residual is larger than the old set's 3.0 gate; the gate is relaxed to 6.0 and the
    # distribution is written to the meta (see report)
    assert res_max < 6.0, "cross-section recovery failed, max residual %.3f" % res_max
    res_stats = dict(p50=float(np.percentile(res_all, 50)), p95=float(np.percentile(res_all, 95)),
                     p99=float(np.percentile(res_all, 99)), count_gt3=int((res_all > 3.0).sum()),
                     count_gt1=int((res_all > 1.0).sum()), n=int(res_all.size))
    P1 = np.empty_like(P)
    N1 = np.empty_like(P)
    P1[rib], N1[rib] = b4.rebuild(N0c, cs0)
    P1[~rib], N1[~rib] = b4.rebuild(N1c, cs1)
    N1 /= np.linalg.norm(N1, axis=1)[:, None]

    ar = np.arange(n)
    gid = (b4.hash_u(ar, 1) * b4.N_GROUPS).astype(np.int64) % b4.N_GROUPS
    P2 = np.empty_like(P)
    N2 = np.empty_like(P)
    groups = {}
    for k in range(b4.N_GROUPS):
        m = gid == k
        im = ar[m]
        ang = b4.G_ANGLE[k] * b4.G_SIGN[k] * (1.0 + 0.10 * (b4.hash_u(im, 3) - 0.5))
        axis = np.array([np.sin(b4.AX_TILT[k]) * np.cos(b4.AX_AZ[k]),
                         np.sin(b4.AX_TILT[k]) * np.sin(b4.AX_AZ[k]), np.cos(b4.AX_TILT[k])])
        ax = np.broadcast_to(axis, (int(m.sum()), 3))
        eps = 1.0 + b4.G_EPS[k] * (1.0 + 0.12 * (b4.hash_u(im, 5) - 0.5))
        ca, sa = np.cos(ang)[:, None], np.sin(ang)[:, None]
        kP = np.cross(ax, P[m])
        kk = np.sum(ax * P[m], axis=1)[:, None]
        P2[m] = (P[m] * ca + kP * sa + ax * kk * (1 - ca)) * eps[:, None]
        kN = np.cross(ax, N[m])
        kn = np.sum(ax * N[m], axis=1)[:, None]
        nn = N[m] * ca + kN * sa + ax * kn * (1 - ca)
        N2[m] = nn / np.linalg.norm(nn, axis=1)[:, None]
        groups[str(k)] = dict(points=int(m.sum()), angleDeg=float(np.degrees(abs(b4.G_ANGLE[k]))),
                              sign=float(b4.G_SIGN[k]), expand=float(b4.G_EPS[k]))
    mag = np.abs(P2).max(1)
    n_over = int((mag > 500.0).sum())
    t = np.clip((mag - 470.0) / 50.0, 0, 1)
    t = t * t * (3.0 - 2.0 * t)
    sc = 1.0 - t * np.maximum(0.0, 1.0 - 500.0 / np.maximum(mag, 1e-9))
    P2 *= sc[:, None]

    # crossing report on the tilted, lifted ribbon centre line (as build_points4.main)
    cu = np.array([[cc[0], cc[1]] for cc in cross]).ravel()
    dz_u = (cl_at(N0c, cu).reshape(len(cross), 2, 3)[:, 0, 2]
            - cl_at(N0c, cu).reshape(len(cross), 2, 3)[:, 1, 2])
    ov = "".join("+" if v > 0 else "-" for v in dz_u)

    def stat(A):
        st = b4.disp_stats(A, P)
        d = np.linalg.norm(A - P, axis=1)
        st["staticDots"] = int((d < 1e-9).sum())
        st["maxAbsCoord"] = float(np.abs(A).max())
        st["ribbonMean"] = float(d[rib].mean())
        st["ringMean"] = float(d[~rib].mean())
        return st

    info = dict(
        form1=dict(name="lift", zLiftUnits=b4.Z_LIFT, zRingUnits=b4.Z_RING, tiltDeg=b4.TILT_DEG,
                   tipPull=b4.TIP_PULL, periods=3, phiRad=phi, phiDeg=float(np.degrees(phi)),
                   crossingDzUnits=[float(v) for v in dz_u], crossingOverUnder=ov,
                   crossingAlternating=bool((ov[0] != ov[1]) and (ov[1] != ov[2])),
                   residualMax=res_max, residualMean=float(res_all.mean()), residualStats=res_stats,
                   **stat(P1)),
        form2=dict(name="bloom", hash="build_points4.hash_u seed %d" % b4.SEED, groups=groups,
                   squashedPoints=n_over, **stat(P2)),
        boundUnits=b4.BOUND,
    )
    assert info["form1"]["max"] <= b4.BOUND and info["form2"]["max"] <= b4.BOUND, \
        "displacement bound exceeded"
    assert info["form1"]["maxAbsCoord"] < RANGE and info["form2"]["maxAbsCoord"] < RANGE, \
        "target coordinate outside +-512"
    return P1, N1, P2, N2, info


# ------------------------------------------------------------------ texture
def b8(v):
    return ((np.clip(v, 0.0, 1.0) * 255.0) + 0.5).astype(np.int64)


def encode_texture(out_png, P, N, lat, q, cls, u, knock, crowd, P1, N1, P2, N2):
    n = len(P)
    rows = (STRIDE * n + WIDTH - 1) // WIDTH
    buf = np.zeros((rows * WIDTH, 3), dtype=np.uint8)
    base = STRIDE * np.arange(n)
    b4.enc_pos(buf, base + 0, P)            # texel 0,1 rest position
    b4.enc_nrm(buf, base + 2, N)            # texel 2 N3
    buf[base + 3, 0] = b8(lat)
    buf[base + 3, 1] = b8(q)
    buf[base + 3, 2] = b8(cls)
    buf[base + 4, 0] = b8(u)
    buf[base + 4, 1] = b8(knock)
    buf[base + 4, 2] = b8(crowd)
    b4.enc_pos(buf, base + 5, P1)           # texel 5,6 form 1 position
    b4.enc_nrm(buf, base + 7, N1)           # texel 7 form 1 normal
    b4.enc_pos(buf, base + 8, P2)           # texel 8,9 form 2 position
    b4.enc_nrm(buf, base + 10, N2)          # texel 10 form 2 normal
    rgba = np.zeros((rows * WIDTH, 4), dtype=np.uint8)
    rgba[:, :3] = buf
    rgba[:, 3] = 255
    Image.frombytes("RGBA", (WIDTH, rows), rgba.tobytes()).convert("RGB").save(out_png, optimize=True)
    return rows


def decode_points(png, n):
    im = np.asarray(Image.open(png).convert("RGB"))
    flat = im.reshape(-1, 3).astype(np.int64)
    base = STRIDE * np.arange(n)
    t = [flat[base + k] for k in range(STRIDE)]

    def pos(a, bb):
        return np.c_[b4.unq16(a[:, 0], a[:, 1]), b4.unq16(a[:, 2], bb[:, 0]),
                     b4.unq16(bb[:, 1], bb[:, 2])]

    out = dict(P=pos(t[0], t[1]), N=t[2] / 255.0 * 2.0 - 1.0,
               lat=t[3][:, 0] / 255.0, q=t[3][:, 1] / 255.0, cls=np.rint(t[3][:, 2] / 255.0),
               u=t[4][:, 0] / 255.0, knock=t[4][:, 1] / 255.0, crowd=t[4][:, 2] / 255.0,
               P1=pos(t[5], t[6]), N1=t[7] / 255.0 * 2.0 - 1.0,
               P2=pos(t[8], t[9]), N2=t[10] / 255.0 * 2.0 - 1.0)
    return out, im.shape[0]


def stat(a):
    a = np.asarray(a, dtype=np.float64)
    return dict(min=float(a.min()), max=float(a.max()), mean=float(a.mean()),
                p50=float(np.percentile(a, 50)), p95=float(np.percentile(a, 95)))


def clusters(u, mask, gap=0.01, top=12):
    uu = np.sort(u[mask])
    if uu.size == 0:
        return []
    cuts = np.where(np.diff(uu) > gap)[0]
    starts = np.r_[0, cuts + 1]
    ends = np.r_[cuts, uu.size - 1]
    out = [dict(u0=round(float(uu[a]), 4), u1=round(float(uu[b]), 4), n=int(b - a + 1))
           for a, b in zip(starts, ends)]
    out.sort(key=lambda d: -d["n"])
    return out[:top]


def main():
    ap = argparse.ArgumentParser(description="Build knot-points5.png (fine particle strand).")
    ap.add_argument("--out-dir", default=HERE)
    ap.add_argument("--rest-only", action="store_true", help="D1: forms 1 and 2 equal to rest")
    ap.add_argument("--rest-yaw-deg", type=float, default=0.0)
    ap.add_argument("--rest-pitch-deg", type=float, default=0.0)
    args = ap.parse_args()
    t0 = time.time()
    os.makedirs(args.out_dir, exist_ok=True)
    out_png = os.path.join(args.out_dir, PNG_NAME)
    out_meta = os.path.join(args.out_dir, META_NAME)

    K = json.load(open(b2.SRC))
    CL = [np.asarray(c, dtype=np.float64).reshape(-1, 3) for c in K["cl"][:2]]
    rest = build_rest(CL)
    P, N = rest["P"], rest["N"]
    cls, idx = rest["cls"], rest["idx"]
    n = len(P)
    rib = cls == 0
    print("rest set: N %d (ribbon %d, ring %d) t=%.1fs" % (n, rib.sum(), (~rib).sum(), time.time() - t0))

    knock = knock_weights(P, cls, idx, CL, args.rest_yaw_deg, args.rest_pitch_deg)
    print("knock: >0.5 %.4f  >0.95 %.4f  t=%.1fs" % ((knock > 0.5).mean(), (knock > 0.95).mean(),
                                                    time.time() - t0))

    cross, phi, _ = None, None, None
    cross = b4.find_crossings(CL[0])
    best, _ = b4.pick_phi(cross)
    assert best is not None, "no phi gives alternating over/under"
    phi = float(best[1])
    if args.rest_only:
        P1, N1, P2, N2 = P.copy(), N.copy(), P.copy(), N.copy()
        forms_info = dict(stage="D1: forms 1 and 2 temporarily equal to rest")
    else:
        P1, N1, P2, N2, forms_info = make_forms(P, N, cls, CL, phi, cross)
        print("form1 max %.2f mean %.2f p95 %.2f | form2 max %.2f mean %.2f p95 %.2f (units) t=%.1fs" % (
            forms_info["form1"]["max"], forms_info["form1"]["mean"], forms_info["form1"]["p95"],
            forms_info["form2"]["max"], forms_info["form2"]["mean"], forms_info["form2"]["p95"],
            time.time() - t0))

    if args.rest_yaw_deg != 0.0 or args.rest_pitch_deg != 0.0:
        rr = lambda A: rot_pose(A, args.rest_yaw_deg, args.rest_pitch_deg)  # noqa: E731
        P, N, P1, N1, P2, N2 = rr(P), rr(N), rr(P1), rr(N1), rr(P2), rr(N2)
        print("comparison bake: rest pose yaw %.2f pitch %.2f (not production)" % (
            args.rest_yaw_deg, args.rest_pitch_deg))

    rows = encode_texture(out_png, P, N, rest["lat"], rest["q"], cls.astype(np.float64),
                          rest["u"], knock, np.ones(n), P1, N1, P2, N2)
    print("texture %d x %d -> %s t=%.1fs" % (WIDTH, rows, out_png, time.time() - t0))

    # ---- decode the PNG back (the shader's view) -------------------------
    d, rows_read = decode_points(out_png, n)
    errP = np.linalg.norm(d["P"] - P, axis=1)
    errP1 = np.linalg.norm(d["P1"] - P1, axis=1)
    errP2 = np.linalg.norm(d["P2"] - P2, axis=1)
    errN = float(np.abs(d["N"] - N).max())
    e_lat = float(np.abs(d["lat"] - rest["lat"]).max())
    e_q = float(np.abs(d["q"] - rest["q"]).max())
    e_u = float(np.abs(d["u"] - rest["u"]).max())
    e_k = float(np.abs(d["knock"] - knock).max())
    e_c = float(np.abs(d["crowd"] - 1.0).max())
    e_cls = float(np.abs(d["cls"] - cls).max())
    dec = dict(rows=int(rows_read), P_max=float(errP.max()), P_mean=float(errP.mean()),
               P1_max=float(errP1.max()), P2_max=float(errP2.max()), N_max=errN,
               lat_max=e_lat, q_max=e_q, u_max=e_u, knock_max=e_k, crowd_max=e_c, cls_max=e_cls,
               classCountsDecoded=[int((d["cls"] == 0).sum()), int((d["cls"] == 1).sum())])
    print("decode: %s" % json.dumps(dec))
    tol = 1.0 / 255.0 + 1e-9
    assert errP.max() < 0.03, "position decode"
    if args.rest_yaw_deg == 0.0 and args.rest_pitch_deg == 0.0:
        # production: forms must decode too; a rotated comparison bake may clip forms at +-512
        assert errP1.max() < 0.03 and errP2.max() < 0.03, "form position decode"
    assert max(e_lat, e_q, e_u, e_k, e_c) <= tol and errN <= 1.0 / 127.5 + 1e-9, "byte decode"
    assert e_cls == 0.0

    # pivot: same formula as knot_port.measure_pivot_px on the decoded texture
    pvx, pvy = pivot_px(d["P"])
    old, _ = decode_points(OLD_PNG, 4384)
    ovx, ovy = pivot_px(old["P"])
    print("pivotPx (decoded) %.4f %.4f | pivot formula on knot-points4.png %.4f %.4f (knot_port PIVOT_PX -4.203 35.411)"
          % (pvx, pvy, ovx, ovy))

    sha1 = hashlib.sha1(open(out_png, "rb").read()).hexdigest()
    kn_hi = knock > 0.5
    meta = dict(
        name=PNG_NAME, stage=("D1" if args.rest_only else "final"),
        N=int(n), width=WIDTH, rows=int(rows), stride=STRIDE, texels=int(STRIDE * n),
        classCounts={"0": int((cls == 0).sum()), "1": int((cls == 1).sum())},
        layout=("t0 (x_hi,x_lo,y_hi) t1 (y_lo,z_hi,z_lo) rest pos; t2 N3; t3 (lat,q,cls); "
                "t4 (u,knock,crowd); t5,t6 form1 pos; t7 form1 N; t8,t9 form2 pos; t10 form2 N"),
        positionDecode="v = (hi*256+lo)/65535*1024-512", normalEncode="(n*0.5+0.5)*255",
        constants=dict(seed=SEED, sigmaLateral=SIGMA_V, radTubeUnits=dict(ribbon=RAD_TUBE[0], ring=RAD_TUBE[1]),
                       zOffsetShare=Z_OFF, zNoiseUnits=Z_NOISE, gapPx=GAP, dzOverUnits=DZ_OVER,
                       arcSkipSamples=ARC_SKIP, pxPerUnit=SC, camD=CAM, knotPx=KNOT_PX,
                       rminPx=RMIN, rmaxPx=RMAX, tiltDeg=b4.TILT_DEG, tipPull=b4.TIP_PULL,
                       zLiftUnits=b4.Z_LIFT, zRingUnits=b4.Z_RING, boundUnits=b4.BOUND,
                       phiRad=phi, sourceCentreline=b2.SRC),
        restYawDeg=args.rest_yaw_deg, restPitchDeg=args.rest_pitch_deg,
        uConvention="u = seg / n_c per class (sample index fraction, not true arc length)",
        normalConvention=("outward, N3 = normalize((-Ty*v, Tx*v, sqrt(1-v^2))): same sense as the "
                          "build_points2 noise normal (cos*U + sin*V, away from the centre line)"),
        stats=dict(lat=stat(rest["lat"]), q=stat(rest["q"]), knock=stat(knock), u=stat(rest["u"])),
        knockBands=dict(fracAbove05=float(kn_hi.mean()), fracAbove095=float((knock > 0.95).mean()),
                        ribbonClusters=clusters(rest["u"], kn_hi & rib),
                        ringClusters=clusters(rest["u"], kn_hi & ~rib)),
        forms=forms_info,
        pivotPx=[pvx, pvy],
        pivotMethod="knot_port.measure_pivot_px formula on decoded texture positions",
        pivotFormulaCheckKnotPoints4=[ovx, ovy],
        decodeCheck=dec,
        pngSha1=sha1, pngBytes=os.path.getsize(out_png),
        buildSeconds=round(time.time() - t0, 2),
    )
    with open(out_meta, "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print("meta -> %s sha1 %s build %.1fs" % (out_meta, sha1, time.time() - t0))
    print("knock clusters ribbon: %s" % json.dumps(meta["knockBands"]["ribbonClusters"][:6]))


if __name__ == "__main__":
    main()
