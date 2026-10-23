#!/usr/bin/env python3
"""compare_gpu.py: does the CPU port explain a GPU render of the knot?

    compare_gpu.py <gpu.png> <t> [--port-png out.png] [--motion v2|base]

Rasterises the port's projected points at time t as round dots (radius 2.3 px
times the perspective factor the shader uses) into an image of the same size,
finds the bright pixel centroids of the GPU frame (8-connected components of
luminance above --thr), and reports the nearest neighbour distance from every
GPU dot centroid to the nearest port dot, median and p95, in px. A low median
means the port and the shader project the same points; a median near the dot
spacing means they do not.

The port dot radius follows knot.vert: rpx = 2.3 * knotPx/540 * mix(0.6, 1.22, d)
with d from the rotated z, so the comparison is not biased by size.
"""

import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw

try:
    from scipy import ndimage
    HAVE_SCIPY = True
except Exception:
    HAVE_SCIPY = False

try:
    from scipy.spatial import cKDTree
    HAVE_TREE = True
except Exception:
    HAVE_TREE = False

import knot_port as kp


def bright_centroids(path, thr):
    im = Image.open(path).convert("RGB")
    a = np.asarray(im, dtype=np.float64) / 255.0
    lum = 0.2126 * a[:, :, 0] + 0.7152 * a[:, :, 1] + 0.0722 * a[:, :, 2]
    mask = lum > thr
    if not mask.any():
        return np.zeros((0, 2)), mask, lum
    if HAVE_SCIPY:
        lab, n = ndimage.label(mask, structure=np.ones((3, 3), dtype=int))
        idx = np.arange(1, n + 1)
        sizes = ndimage.sum(mask, lab, idx)
        keep = sizes >= 3
        cy = ndimage.center_of_mass(mask, lab, idx[keep])
        return np.array([[c[1], c[0]] for c in cy], dtype=np.float64), mask, lum
    ys, xs = np.nonzero(mask)
    return np.stack([xs, ys], axis=1).astype(np.float64), mask, lum


def port_dots(port, t, w, h):
    d = port.sample(t)
    pos = d["pos_full"]
    q = d["Q"] if "Q" in d else port.P
    _, yaw, pitch, _ = port.pose(t)
    cyw, syw = np.cos(yaw), np.sin(yaw)
    cpt, spt = np.cos(pitch), np.sin(pitch)
    z1 = -q[:, 0] * syw + q[:, 2] * cyw
    z2 = q[:, 1] * spt + z1 * cpt
    k = kp.CAM_D / (kp.CAM_D - z2)
    dd = np.clip(0.5 + z2 / 160.0, 0.0, 1.0)
    rad = 2.3 * (port.knot_px / 540.0) * (0.6 + 0.62 * dd)
    return pos, np.maximum(rad, 1.0), d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("gpu_png")
    ap.add_argument("t", type=float)
    ap.add_argument("--thr", type=float, default=0.10)
    ap.add_argument("--motion", default="v2", choices=("v2", "base"))
    ap.add_argument("--port-png", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--tex", default=kp.DEFAULT_TEX)
    a = ap.parse_args()

    port = kp.KnotPort(tex=a.tex, motion=a.motion)
    im = Image.open(a.gpu_png).convert("RGB")
    W, H = im.size
    port.w, port.h = float(W), float(H)
    pos, rad, d = port_dots(port, a.t, W, H)

    cen, mask, lum = bright_centroids(a.gpu_png, a.thr)
    if len(cen) == 0:
        print(json.dumps({"gpu": a.gpu_png, "t": a.t, "error": "no bright pixels",
                          "threshold": a.thr}))
        return 1

    if HAVE_TREE:
        tree = cKDTree(pos)
        dist, _ = tree.query(cen, k=1)
    else:
        dist = np.empty(len(cen))
        for i in range(0, len(cen), 512):
            chunk = cen[i:i + 512]
            d2 = ((chunk[:, None, :] - pos[None, :, :]) ** 2).sum(axis=2)
            dist[i:i + 512] = np.sqrt(d2.min(axis=1))

    rep = {
        "gpu": os.path.abspath(a.gpu_png), "t": a.t, "size": [W, H],
        "motion": a.motion, "threshold": a.thr,
        "gpu_dot_centroids": int(len(cen)),
        "gpu_bright_px_fraction": round(float(mask.mean()), 5),
        "port_points": int(len(pos)),
        "nn_median_px": round(float(np.median(dist)), 3),
        "nn_p90_px": round(float(np.percentile(dist, 90)), 3),
        "nn_p95_px": round(float(np.percentile(dist, 95)), 3),
        "nn_max_px": round(float(dist.max()), 3),
        "within_2px": round(float((dist <= 2.0).mean()), 3),
        "within_4px": round(float((dist <= 4.0).mean()), 3),
    }
    if a.port_png:
        out = im.copy()
        dr = ImageDraw.Draw(out)
        for (x, y), r in zip(pos, rad):
            if -3 <= x <= W + 3 and -3 <= y <= H + 3:
                dr.ellipse([x - r, y - r, x + r, y + r], outline=(255, 80, 80))
        out.save(a.port_png)
        rep["port_png"] = os.path.abspath(a.port_png)
    print(json.dumps(rep, indent=1))
    if a.json:
        with open(a.json, "w", encoding="ascii") as f:
            json.dump(rep, f, indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
