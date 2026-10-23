"""Score a swarm still against a reference knot frame.

Metrics, all on luminance masks so they are comparable across renderers:
  coverage@t   fraction of pixels above threshold t (0.10 glow-ish, 0.25, 0.35
               core, 0.50 peak)
  dots         local maxima count above 0.35 and the median connected component
               area of those peaks, which is the dot size distribution
  IoU          silhouette IoU of mask@0.10 and mask@0.35 against the reference,
               after aligning both on their mask centroid, plus the best IoU over
               a +-10 px shift search (that one is the "shape ceiling")

Usage: python3 score.py <render.png> <reference.jpg|png> [--json out.json]
"""
import argparse
import json

import numpy as np
from PIL import Image


def load_lum(path):
    im = Image.open(path).convert("RGB")
    a = np.array(im).astype(np.float32) / 255.0
    return a @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def local_maxima(lum, thr):
    p = np.pad(lum, 1, mode="constant")
    c = p[1:-1, 1:-1]
    mx = np.ones_like(c, bool)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            mx &= c >= p[1 + dy:p.shape[0] - 1 + dy, 1 + dx:p.shape[1] - 1 + dx]
    return mx & (c > thr)


def components(mask):
    """4-connected component sizes, iterative flood fill (no scipy here)."""
    h, w = mask.shape
    labels = np.zeros((h, w), np.int32)
    sizes = []
    cur = 0
    for y in range(h):
        for x in range(w):
            if mask[y, x] and labels[y, x] == 0:
                cur += 1
                n = 0
                stack = [(y, x)]
                labels[y, x] = cur
                while stack:
                    cy, cx = stack.pop()
                    n += 1
                    for ny, nx in ((cy - 1, cx), (cy + 1, cx), (cy, cx - 1), (cy, cx + 1)):
                        if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and labels[ny, nx] == 0:
                            labels[ny, nx] = cur
                            stack.append((ny, nx))
                sizes.append(n)
    return np.array(sizes)


def centroid(mask):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return 0.0, 0.0
    return float(xs.mean()), float(ys.mean())


def shift(mask, dx, dy):
    out = np.zeros_like(mask)
    h, w = mask.shape
    ys0, ys1 = max(0, dy), min(h, h + dy)
    xs0, xs1 = max(0, dx), min(w, w + dx)
    out[ys0:ys1, xs0:xs1] = mask[ys0 - dy:ys1 - dy, xs0 - dx:xs1 - dx]
    return out


def iou(a, b):
    u = (a | b).sum()
    return float((a & b).sum() / u) if u else 0.0


def metrics(lum, ref, label):
    out = {"label": label, "size": list(lum.shape)}
    for t in (0.10, 0.25, 0.35, 0.50):
        out["coverage@%.2f" % t] = round(float((lum > t).mean()), 5)
    for t in (0.35,):
        peaks = local_maxima(lum, t)
        out["peaks@%.2f" % t] = int(peaks.sum())
        sizes = components(peaks)
        if len(sizes):
            out["peak_area_median"] = float(np.median(sizes))
            out["peak_area_p10"] = float(np.percentile(sizes, 10))
            out["peak_area_p90"] = float(np.percentile(sizes, 90))
        out["render_centroid"] = [round(v, 1) for v in centroid(lum > t)]
    out["ref_centroid"] = [round(v, 1) for v in centroid(ref > 0.35)]
    return out


def box_blur(a, radius):
    """2D box blur through a summed-area table, no scipy."""
    h, w = a.shape
    pad = np.zeros((h + 1, w + 1), np.float64)
    pad[1:, 1:] = np.cumsum(np.cumsum(a.astype(np.float64), 0), 1)
    ys = np.arange(h)
    xs = np.arange(w)
    y0 = np.clip(ys - radius, 0, h)
    y1 = np.clip(ys + radius + 1, 0, h)
    x0 = np.clip(xs - radius, 0, w)
    x1 = np.clip(xs + radius + 1, 0, w)
    s = (pad[np.ix_(y1, x1)] - pad[np.ix_(y0, x1)]
         - pad[np.ix_(y1, x0)] + pad[np.ix_(y0, x0)])
    n = (y1 - y0)[:, None] * (x1 - x0)[None, :]
    return (s / np.maximum(n, 1)).astype(np.float32)


def silhouette_iou(a, b, radius):
    """IoU of two masks after a box blur, which removes dot phase and leaves shape."""
    ba = box_blur((a > 0.35).astype(np.float32), radius)
    bb = box_blur((b > 0.35).astype(np.float32), radius)
    t = max(1e-6, 0.5 * (ba.max() + bb.max()) * 0.35)
    return iou(ba > t, bb > t)


def silh_iou(a, b, radius):
    """IoU of two masks after a box blur, absolute threshold.

    A fixed 0.02 coverage after a box blur is thin enough to keep the silhouette
    and wide enough to ignore dot phase, which makes the number comparable
    across renderers and against the reference.
    """
    ba = box_blur((a > 0.35).astype(np.float32), radius)
    bb = box_blur((b > 0.35).astype(np.float32), radius)
    return iou(ba > 0.02, bb > 0.02)


def chamfer(a_peaks, b_peaks, sample=1500):
    """Mean and p90 nearest-neighbour distance between two dot fields, in px."""
    ya, xa = np.nonzero(a_peaks)
    yb, xb = np.nonzero(b_peaks)
    if len(xa) == 0 or len(xb) == 0:
        return None, None
    ia = np.random.default_rng(0).choice(len(xa), size=min(sample, len(xa)), replace=False)
    pa = np.stack([xa[ia], ya[ia]], 1).astype(np.float32)
    pb = np.stack([xb, yb], 1).astype(np.float32)
    d = np.hypot(pa[:, None, 0] - pb[None, :, 0], pa[:, None, 1] - pb[None, :, 1]).min(1)
    return float(d.mean()), float(np.percentile(d, 90))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("render")
    ap.add_argument("reference")
    ap.add_argument("--json")
    args = ap.parse_args()

    a = load_lum(args.render)
    b = load_lum(args.reference)
    res = {"render": args.render, "reference": args.reference}
    res["render_metrics"] = metrics(a, b, "render")
    res["reference_metrics"] = metrics(b, b, "reference")

    # align on the mask@0.35 centroid, then IoU on the same masks
    ca, cb = centroid(a > 0.35), centroid(b > 0.35)
    dx, dy = int(round(cb[0] - ca[0])), int(round(cb[1] - ca[1]))
    best = {"iou@0.35": 0.0, "iou@0.10": 0.0, "dx": 0, "dy": 0}
    for sy in range(-10, 11, 2):
        for sx in range(-10, 11, 2):
            sa = shift(a, dx + sx, dy + sy)
            v = iou(sa > 0.35, b > 0.35)
            if v > best["iou@0.35"]:
                best = {"iou@0.35": round(v, 4),
                        "iou@0.10": round(iou(sa > 0.10, b > 0.10), 4),
                        "dx": dx + sx, "dy": dy + sy}
    sa = shift(a, dx, dy)
    res["aligned"] = {
        "shift": [dx, dy],
        "iou@0.35": round(iou(sa > 0.35, b > 0.35), 4),
        "iou@0.10": round(iou(sa > 0.10, b > 0.10), 4),
        "silhouette_iou_blur6": round(silh_iou(sa, b, 6), 4),
        "silhouette_iou_blur12": round(silh_iou(sa, b, 12), 4),
        "chamfer_mean_px": None,
        "chamfer_p90_px": None,
    }
    mean_d, p90_d = chamfer(sa > 0.35, b > 0.35)
    res["aligned"]["chamfer_mean_px"] = None if mean_d is None else round(mean_d, 2)
    res["aligned"]["chamfer_p90_px"] = None if p90_d is None else round(p90_d, 2)
    res["best_shift"] = best
    # best silhouette over the same shift search
    best_sil = 0.0
    for sy in range(-12, 13, 4):
        for sx in range(-12, 13, 4):
            best_sil = max(best_sil, silhouette_iou(shift(a, dx + sx, dy + sy), b, 6))
    res["silhouette_iou_blur6_best"] = round(best_sil, 4)
    print(json.dumps(res, indent=2))
    if args.json:
        with open(args.json, "w") as f:
            json.dump(res, f, indent=2)


if __name__ == "__main__":
    main()
