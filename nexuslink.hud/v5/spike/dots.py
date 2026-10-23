"""Audit the dot field of a swarm still: are the dots discrete and round?

`score.py` answers "does the silhouette match s2". This answers the neighbour
question that a silhouette metric is blind to: given the dots we drew, does each
one read as a round point with dark gaps around it, or have the discs merged
into a tile mosaic / smeared into dashes?

Measures, all on the luminance mask at a threshold (0.35 by default):

  pitch_px     median nearest-neighbour distance between peak centres; the dot
               lattice spacing actually drawn, not the value in the QML
  peaks        local maxima above the threshold (roughly one per dot)
  components   connected components above the threshold
  merge        components / peaks: 1.0 means every dot stands alone; well below
               1.0 means neighbouring dots have fused into clusters
  cell_fill    lit area / (peaks * pitch^2): the fraction of one lattice cell
               that is lit. A disc of diameter 0.75 * pitch fills about 0.44;
               discs that fill whole cells score near 1.0
  aspect       median bbox long side / short side of components with area >= 2.
               1.0 is round, 2.0 is a dash, 3.0 is a streak
  round_share  share of those components with aspect <= 1.5

Usage: python3 dots.py <render.png> [--threshold 0.35] [--json out.json]
"""

import argparse
import json
import sys

import numpy as np

from score import components, load_lum, local_maxima


def peak_pitch(peaks, sample=3000):
    ys, xs = np.nonzero(peaks)
    if len(xs) < 3:
        return None
    rng = np.random.default_rng(0)
    idx = rng.choice(len(xs), size=min(sample, len(xs)), replace=False)
    p = np.stack([xs[idx], ys[idx]], 1).astype(np.float32)
    allp = np.stack([xs, ys], 1).astype(np.float32)
    # nearest neighbour, then drop the self hit (distance 0). Done in chunks so
    # a 1080 still does not build a 3000 x 5000 matrix in one go.
    nn = np.empty(len(p), np.float32)
    for i in range(0, len(p), 256):
        chunk = p[i:i + 256]
        d = np.hypot(chunk[:, None, 0] - allp[None, :, 0],
                     chunk[:, None, 1] - allp[None, :, 1])
        d[d < 1e-6] = np.inf
        nn[i:i + 256] = d.min(1)
    nn = nn[np.isfinite(nn)]
    return float(np.median(nn)) if len(nn) else None


def component_shapes(lum, mask):
    """Area and bbox aspect per connected component, without scipy."""
    h, w = mask.shape
    seen = np.zeros((h, w), bool)
    areas, aspects = [], []
    ys, xs = np.nonzero(mask)
    order = np.argsort(ys * w + xs)
    for i in order:
        y0, x0 = int(ys[i]), int(xs[i])
        if seen[y0, x0]:
            continue
        stack = [(y0, x0)]
        seen[y0, x0] = True
        n = 0
        miny = maxy = y0
        minx = maxx = x0
        while stack:
            cy, cx = stack.pop()
            n += 1
            if cy < miny: miny = cy
            if cy > maxy: maxy = cy
            if cx < minx: minx = cx
            if cx > maxx: maxx = cx
            for ny, nx in ((cy - 1, cx), (cy + 1, cx), (cy, cx - 1), (cy, cx + 1)):
                if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        hgt = maxy - miny + 1
        wid = maxx - minx + 1
        areas.append(n)
        aspects.append(max(hgt, wid) / float(max(1, min(hgt, wid))))
    return np.array(areas, np.float32), np.array(aspects, np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("render")
    ap.add_argument("--threshold", type=float, default=0.35)
    ap.add_argument("--json")
    args = ap.parse_args()

    lum = load_lum(args.render)
    mask = lum > args.threshold
    lit = float(mask.mean())
    peaks = local_maxima(lum, args.threshold)
    n_peaks = int(peaks.sum())
    pitch = peak_pitch(peaks)
    areas, aspects = component_shapes(lum, mask)
    n_comp = int(len(areas))

    big = aspects[areas >= 2]
    res = {
        "render": args.render,
        "threshold": args.threshold,
        "size": list(lum.shape),
        "coverage": round(lit, 5),
        "peaks": n_peaks,
        "pitch_px": None if pitch is None else round(pitch, 2),
        "components": n_comp,
        "merge": None if not n_peaks else round(n_comp / n_peaks, 3),
        "cell_fill": None if not (n_peaks and pitch) else round(
            lit * lum.size / (n_peaks * pitch * pitch), 3),
        "component_area_median": round(float(np.median(areas)), 2) if n_comp else None,
        "aspect_median": round(float(np.median(big)), 2) if len(big) else None,
        "round_share": round(float((big <= 1.5).mean()), 3) if len(big) else None,
    }
    print(json.dumps(res, indent=2))
    if args.json:
        with open(args.json, "w") as f:
            json.dump(res, f, indent=2)
    return 0 if n_peaks else 1


if __name__ == "__main__":
    sys.exit(main())
