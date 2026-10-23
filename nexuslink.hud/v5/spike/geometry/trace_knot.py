"""Trace the nexus knot from the source vector into renderer input.

Source of truth: hud-candidates/logo-r1/src/knot-source.svg ("element dark nexus"),
the file the 48x49 PixelLogo bitmap was rasterised from (IoU 0.931, see
logo-r1/src/bitmap-check.txt). A copy lives next to this script so the repo builds
without the design folder.

The SVG is an autotraced fill: 9 closed ribbons (ring segments and knot arms).
For each ribbon this script recovers the centre line (inward normal march, the
same idea as logo-r1/src/geometry.py, reimplemented without scipy), orders it,
and writes:

  knot.json      ordered centre lines with local half width, in knot-height units
                 (x, y in [-0.5, 0.5], y up = negative)
  knot-points.txt summary of the derived point cloud (N, spacing, radius range)

Run: python3 trace_knot.py
"""
import json
import math
import os
import re

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "knot-source.svg")
OUT_JSON = os.path.join(HERE, "knot.json")

VB_W, VB_H = 859.67, 883.69
OUT = 540.0                      # knot height in output px (design size)
S = OUT / VB_H                   # px per svg unit
Q = 2                            # mask supersample
CX, CY = VB_W / 2.0, VB_H / 2.0
NUM = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")


def parse(d):
    """Flatten an SVG path (M L C S H V Z, absolute and relative) into points."""
    pts, cur, start, last_c2 = [], (0.0, 0.0), (0.0, 0.0), None
    for cmd, args in re.findall(r"([MmCcSsLlHhVvZz])([^MmCcSsLlHhVvZz]*)", d):
        a = list(map(float, NUM.findall(args)))
        rel = cmd.islower()
        C = cmd.upper()

        def P(x, y):
            return (cur[0] + x, cur[1] + y) if rel else (x, y)

        if C == "Z":
            pts.append(start)
            cur = start
            last_c2 = None
            continue
        step = {"M": 2, "L": 2, "C": 6, "S": 4, "H": 1, "V": 1}[C]
        for k in range(0, len(a), step):
            g = a[k:k + step]
            if C == "M":
                cur = P(*g)
                start = cur
                pts.append(cur)
                C = "L"
                last_c2 = None
            elif C == "L":
                cur = P(*g)
                pts.append(cur)
                last_c2 = None
            elif C == "H":
                cur = (cur[0] + g[0] if rel else g[0], cur[1])
                pts.append(cur)
                last_c2 = None
            elif C == "V":
                cur = (cur[0], cur[1] + g[0] if rel else g[0])
                pts.append(cur)
                last_c2 = None
            else:
                if C == "C":
                    c1, c2, e = P(g[0], g[1]), P(g[2], g[3]), P(g[4], g[5])
                else:
                    c1 = (2 * cur[0] - last_c2[0], 2 * cur[1] - last_c2[1]) if last_c2 else cur
                    c2, e = P(g[0], g[1]), P(g[2], g[3])
                p0 = cur
                for i in range(1, 17):
                    t = i / 16.0
                    m = 1.0 - t
                    pts.append((m ** 3 * p0[0] + 3 * m * m * t * c1[0] + 3 * m * t * t * c2[0] + t ** 3 * e[0],
                                m ** 3 * p0[1] + 3 * m * m * t * c1[1] + 3 * m * t * t * c2[1] + t ** 3 * e[1]))
                cur, last_c2 = e, c2
    return np.array(pts, float)


def resample(poly, ds):
    d = np.r_[0.0, np.cumsum(np.hypot(*np.diff(poly, axis=0).T))]
    if d[-1] < 1e-6:
        return poly[:1], np.zeros(1)
    s = np.arange(0.0, d[-1], ds)
    return np.c_[np.interp(s, d, poly[:, 0]), np.interp(s, d, poly[:, 1])], s


def ribbon_mask(poly):
    """Filled mask of one ribbon at Q x output resolution, plus its origin."""
    mn = poly.min(0) - 3.0
    mx = poly.max(0) + 3.0
    w = int(math.ceil((mx[0] - mn[0]) * Q)) + 2
    h = int(math.ceil((mx[1] - mn[1]) * Q)) + 2
    im = Image.new("L", (w, h), 0)
    ImageDraw.Draw(im).polygon([((x - mn[0]) * Q, (y - mn[1]) * Q) for x, y in poly], fill=1)
    return np.array(im, bool), mn


def inside(m, mn, x, y):
    u = int(round((x - mn[0]) * Q))
    v = int(round((y - mn[1]) * Q))
    return 0 <= v < m.shape[0] and 0 <= u < m.shape[1] and m[v, u]


def centre_points(poly, ds=2.0, wmax=70.0):
    """Walk the outline, march inward along the normal, keep the ribbon centre."""
    m, mn = ribbon_mask(poly)
    pts, _ = resample(poly, ds)
    if len(pts) < 3:
        return []
    tang = np.gradient(pts, axis=0)
    tang /= np.linalg.norm(tang, axis=1)[:, None] + 1e-9
    out = []
    for p, t in zip(pts, tang):
        n = np.array([-t[1], t[0]])
        if not inside(m, mn, p[0] + 2.5 * n[0], p[1] + 2.5 * n[1]):
            n = -n
        if not inside(m, mn, p[0] + 2.5 * n[0], p[1] + 2.5 * n[1]):
            continue
        w = 0.5
        while w < wmax and inside(m, mn, p[0] + w * n[0], p[1] + w * n[1]):
            w += 0.5
        if w >= wmax:
            continue
        out.append((p[0] + 0.5 * w * n[0], p[1] + 0.5 * w * n[1], 0.5 * w))
    return out


def dedupe(pts, rmin):
    keep, grid = [], {}
    for x, y, hw in pts:
        gx, gy = int(x // rmin), int(y // rmin)
        hit = False
        for a in (-1, 0, 1):
            for b in (-1, 0, 1):
                for q in grid.get((gx + a, gy + b), ()):
                    if math.hypot(x - q[0], y - q[1]) < rmin:
                        hit = True
                        break
                if hit:
                    break
            if hit:
                break
        if not hit:
            grid.setdefault((gx, gy), []).append((x, y, hw))
            keep.append((x, y, hw))
    return keep


def chain(pts, jump):
    """Greedy nearest-neighbour ordering, split where the gap exceeds jump."""
    pts = list(pts)
    if not pts:
        return []
    left = np.array([[p[0], p[1]] for p in pts])
    hw = np.array([p[2] for p in pts])
    used = np.zeros(len(pts), bool)
    # start at the point farthest from the centroid: a ribbon end, never mid-strand
    c = left.mean(0)
    i = int(np.argmax(((left - c) ** 2).sum(1)))
    order = [i]
    used[i] = True
    chains = []
    for _ in range(len(pts) - 1):
        d = np.hypot(left[:, 0] - left[order[-1], 0], left[:, 1] - left[order[-1], 1])
        d[used] = 1e9
        j = int(np.argmin(d))
        if d[j] > jump:
            chains.append(order)
            order = [j]
        else:
            order.append(j)
        used[j] = True
    chains.append(order)
    return [[(float(left[k, 0]), float(left[k, 1]), float(hw[k])) for k in ch] for ch in chains]


def dp(poly, eps):
    """Douglas-Peucker on an (N,2) polyline."""
    if len(poly) < 3:
        return poly
    a, b = poly[0], poly[-1]
    ab = b - a
    lab = np.hypot(*ab)
    if lab < 1e-9:
        d = np.hypot(*(poly - a).T)
    else:
        d = np.abs(np.cross(ab, poly - a)) / lab
    i = int(np.argmax(d))
    if d[i] > eps:
        left = dp(poly[:i + 1], eps)
        right = dp(poly[i:], eps)
        return np.vstack([left[:-1], right])
    return np.array([a, b])


def main():
    svg = open(SRC).read()
    raw = [parse(d) for d in re.findall(r'<path[^>]* d="([^"]+)"', svg)]
    assert len(raw) == 9, len(raw)
    paths = [np.c_[(p[:, 0] - CX) * S, -(p[:, 1] - CY) * S] for p in raw]   # y up

    report = []
    out = []
    total_len = 0.0
    all_hw = []
    for pi, poly in enumerate(paths):
        pts = dedupe(centre_points(poly), 1.4)
        chains = chain(pts, jump=2.6)
        chains = [c for c in chains if len(c) > 4]
        for ci, ch in enumerate(chains):
            xy = np.array([[p[0], p[1]] for p in ch])
            hw = np.array([p[2] for p in ch])
            simp = dp(xy, 0.45)
            # arc length of the simplified line, used for the capsule budget
            L = float(np.hypot(*np.diff(simp, axis=0).T).sum()) if len(simp) > 1 else 0.0
            total_len += L
            all_hw += list(hw)
            out.append({
                "path": pi,
                "chain": ci,
                "len": round(L, 2),
                "hw": round(float(np.median(hw)), 2),
                "pts": [[round(float(x), 2), round(float(y), 2), round(float(h), 2)] for (x, y), h in zip(simp, hw)],
            })
            report.append("path %d chain %d: %d pts, len %.1f px, halfwidth %.2f px" % (pi, ci, len(simp), L, float(np.median(hw))))

    hw = np.array(all_hw) if all_hw else np.zeros(1)
    summary = "\n".join(report)
    summary += "\n---\n%d chains, total centre-line length %.1f px at knot height %.0f px\n" % (len(out), total_len, OUT)
    summary += "half width min/median/max %.2f / %.2f / %.2f px\n" % (hw.min(), float(np.median(hw)), hw.max())
    print(summary)

    json.dump({"h": OUT, "unit": "px at h=540, origin = knot centre, y up",
               "chains": out}, open(OUT_JSON, "w"), separators=(",", ":"))
    print("wrote", OUT_JSON, os.path.getsize(OUT_JSON), "bytes")


if __name__ == "__main__":
    main()
