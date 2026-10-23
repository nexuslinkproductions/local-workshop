#!/usr/bin/env python3
"""knot-iou.py: silhouette agreement between a Knot.qml still and the s2 knot.

Two metrics, both on luminance masks so they compare across renderers:

  silhouette_iou_blur6   the meter the C2 verifier used: threshold both images
                         at 0.35, box blur radius 6, threshold the blur at
                         0.02, IoU. Sensitive to dot phase and to dot
                         brightness, but it is the number already on the board
                         for option A (0.260), so it stays the headline.

  band_iou               dot phase removed: threshold at `--thr`, close with a
                         square of `--close` px (dilate then erode) so the dots
                         merge into strand bands, then IoU. This is the meter
                         that answers "is this the same knot shape".

Both are reported after the same translation search (`--search` px, step 2,
then +-1 refine), because the Knot item is centred in its own 540 px frame
while the reference crop sits at the s2 layout position.

Usage
  tools/knot-iou.py measure <render.png|jpg> [--reference PATH] [--crop X,Y,N]
  tools/knot-iou.py ceiling [--cloud PATH] [--t SECONDS]

  `ceiling` projects the s2 reference's own point cloud (knot3d.json) with the
  s2 engine's camera and brightness model and measures that image, which is the
  best any renderer derived from that cloud can score against the reference.

Reference crop: s2-rest.png, 2560x1440, square of N px centred on the layout
position of the knot (Tokens.centreX 1280, Tokens.goldenY1 550). Every number
in docs/knot-iou.md comes from this crop and these two meters.
"""
import argparse
import json
import math
import sys

import numpy as np
from PIL import Image, ImageFilter

DEFAULT_REF = ("/Users/marcelspatz/NEXUS_AI_CENTER/04_PROJECTS/HUD/"
               "hud-candidates/comp-r1/s2/s2-rest.png")
DEFAULT_CLOUD = ("/Users/marcelspatz/NEXUS_AI_CENTER/04_PROJECTS/HUD/"
                 "hud-candidates/comp-r1/s2/src/knot/knot3d.json")
CROP_CENTRE = (1280, 550)
CROP_SIZE = 540


def luminance(path):
    a = np.array(Image.open(path).convert("RGB")).astype(np.float32) / 255.0
    return a @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def box_blur(a, radius):
    h, w = a.shape
    pad = np.zeros((h + 1, w + 1), np.float64)
    pad[1:, 1:] = np.cumsum(np.cumsum(a.astype(np.float64), 0), 1)
    ys, xs = np.arange(h), np.arange(w)
    y0, y1 = np.clip(ys - radius, 0, h), np.clip(ys + radius + 1, 0, h)
    x0, x1 = np.clip(xs - radius, 0, w), np.clip(xs + radius + 1, 0, w)
    s = (pad[np.ix_(y1, x1)] - pad[np.ix_(y0, x1)]
         - pad[np.ix_(y1, x0)] + pad[np.ix_(y0, x0)])
    n = (y1 - y0)[:, None] * (x1 - x0)[None, :]
    return (s / np.maximum(n, 1)).astype(np.float32)


def iou(a, b):
    u = (a | b).sum()
    return float((a & b).sum() / u) if u else 0.0


def closing(mask, size):
    im = Image.fromarray((mask.astype(np.uint8) * 255))
    im = im.filter(ImageFilter.MaxFilter(size)).filter(ImageFilter.MinFilter(size))
    return np.array(im) > 127


def shift(mask, dx, dy):
    out = np.zeros_like(mask)
    h, w = mask.shape
    ys0, ys1 = max(0, dy), min(h, h + dy)
    xs0, xs1 = max(0, dx), min(w, w + dx)
    out[ys0:ys1, xs0:xs1] = mask[ys0 - dy:ys1 - dy, xs0 - dx:xs1 - dx]
    return out


def crop_reference(path, centre, size):
    l = luminance(path)
    h, w = l.shape
    x0 = int(round(centre[0] - size / 2.0))
    y0 = int(round(centre[1] - size / 2.0))
    x0 = max(0, min(w - size, x0))
    y0 = max(0, min(h - size, y0))
    return l[y0:y0 + size, x0:x0 + size], (x0, y0, size)


def register(render_mask, ref_mask, thr, close, search):
    """Best translation for `render_mask` onto `ref_mask` under the band meter."""
    rb = closing(ref_mask, close)
    mb = closing(render_mask, close)
    best = (-1.0, (0, 0))
    for dy in range(-search, search + 1, 2):
        for dx in range(-search, search + 1, 2):
            v = iou(shift(mb, dx, dy), rb)
            if v > best[0]:
                best = (v, (dx, dy))
    cx, cy = best[1]
    for dy in range(cy - 1, cy + 2):
        for dx in range(cx - 1, cx + 2):
            v = iou(shift(mb, dx, dy), rb)
            if v > best[0]:
                best = (v, (dx, dy))
    return best[1]


def measure(render_lum, ref_lum, thr=0.10, close=9, search=12):
    if render_lum.shape != ref_lum.shape:
        raise SystemExit("render is %s, reference crop is %s: render the Knot item "
                         "at the crop size (540) first"
                         % (render_lum.shape, ref_lum.shape))
    rm = render_lum > thr
    fm = ref_lum > thr
    dx, dy = register(rm, fm, thr, close, search)
    s = shift(rm, dx, dy)
    blur = iou(box_blur(shift((render_lum > 0.35).astype(np.float32), dx, dy), 6) > 0.02,
               box_blur((ref_lum > 0.35).astype(np.float32), 6) > 0.02)
    return {
        "shift_px": [dx, dy],
        "threshold": thr,
        "close_px": close,
        "band_iou": round(iou(closing(s, close), closing(fm, close)), 4),
        "silhouette_iou_blur6": round(blur, 4),
        "render_coverage": round(float(rm.mean()), 5),
        "reference_coverage": round(float(fm.mean()), 5),
        "render_core_coverage": round(float((render_lum > 0.35).mean()), 5),
        "reference_core_coverage": round(float((ref_lum > 0.35).mean()), 5),
    }


# --------------------------------------------------------------- s2 replica
def _sm(a, b, x):
    x = np.clip((x - a) / (b - a), 0.0, 1.0)
    return x * x * (3 - 2 * x)


def _pose(t):
    tau, seed = 2 * math.pi, 0.0
    a = lambda p, ph: math.sin(tau * t / p + ph + seed)
    ny = 0.5 * a(31, 0.7) + 0.3 * a(26, 2.1) + 0.2 * a(38, 4.0)
    npp = 0.5 * a(34, 1.9) + 0.3 * a(27.5, 0.4) + 0.2 * a(39, 3.3)
    g = 0.18 + 0.82 * float(_sm(0.12, 0.8, 0.5 - 0.5 * math.cos(tau * t / 12.0)))
    return math.radians(ny * g * 30.0), math.radians(npp * g * 18.0)


def _breath(t, ph, T=5.5):
    u = ((t / T + ph) % 1 + 1) % 1
    a = 0.5 - 0.5 * np.cos(np.pi * np.clip(u, 0, 0.4) / 0.4)
    b = 0.5 + 0.5 * np.cos(np.pi * (np.clip(u, 0.4, 1.0) - 0.4) / 0.6)
    return np.where(u < 0.4, a, b)


def _lobe_phase(x, y):
    th = np.arctan2(y, x)
    s = np.zeros_like(th)
    ws = np.zeros_like(th)
    for ang, off in ((-math.pi / 2, 0.0), (math.pi * 5 / 6, 0.035), (math.pi / 6, 0.07)):
        w = np.exp(3 * np.cos(th - ang))
        s += off * w
        ws += w
    return s / ws


def render_s2_cloud(cloud_path, size, t, gain=1.15, cam=2.7):
    """s2's swarm3d.js render at its own pose model, as luminance."""
    K = json.load(open(cloud_path))
    P = np.array(K["p"], np.float32).reshape(-1, 3)
    NR = np.array(K["nr"], np.float32).reshape(-1, 3)
    Q = np.array(K["q"], np.float32)
    C = np.array(K["c"], np.int32)
    H = float(K["H"])
    span = 80.0
    yaw, pitch = _pose(t)
    cy, sy = math.cos(yaw), math.sin(yaw)
    cp, sp = math.cos(pitch), math.sin(pitch)
    sc, cd = size / H, cam * H
    r0 = 2.3 * size / 540.0
    b = _breath(t, _lobe_phase(P[:, 0], P[:, 1]))
    k0 = 1 + 0.02 * b
    x, y, z = P[:, 0] * k0, P[:, 1] * k0, P[:, 2] * k0
    x1 = x * cy + z * sy
    z1 = -x * sy + z * cy
    y1 = y * cp - z1 * sp
    z2 = y * sp + z1 * cp
    nx, ny, nz = NR[:, 0], NR[:, 1], NR[:, 2]
    nx1 = nx * cy + nz * sy
    nz1 = -nx * sy + nz * cy
    ny1 = ny * cp - nz1 * sp
    nz2 = ny * sp + nz1 * cp
    k = cd / (cd - z2)
    d = np.clip(0.5 + z2 / (2 * span), 0, 1)
    f = np.clip(0.5 + 0.5 * nz2, 0, 1)
    thr = 0.86 + 0.14 * b
    pres = _sm(thr + 0.04, thr - 0.06, Q)
    rr = r0 * k * (0.6 + 0.62 * d) * (0.8 + 0.2 * f) * np.where(C == 1, 0.85, 1.0) \
        * (0.82 + 0.18 * pres)
    al = (0.16 + 0.84 * d) * (0.28 + 0.72 * f) * (0.86 + 0.14 * b) * pres
    azure = np.array([86, 150, 238], np.float32) / 255
    ice = np.array([150, 220, 236], np.float32) / 255
    white = np.array([236, 247, 252], np.float32) / 255
    w = (0.55 * d + 0.45 * f)[:, None]
    col = azure[None, :] + (ice - azure)[None, :] * w
    col = np.where((C == 1)[:, None], col + (white[None, :] - col) * 0.35, col)
    clum = col @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    sx = x1 * k * sc
    sy_ = y1 * k * sc
    # occlusion: dim a point that has a clearly nearer point on top of it
    buckets = {}
    gx = np.floor(sx / 8.0).astype(np.int32)
    gy = np.floor(sy_ / 8.0).astype(np.int32)
    key = lambda a, b: a * 100003 + b
    for i in range(len(P)):
        buckets.setdefault(key(gx[i], gy[i]), []).append(i)
    dim = np.ones(len(P), np.float32)
    for i in range(len(P)):
        m = 0.0
        for a_ in (-1, 0, 1):
            for b_ in (-1, 0, 1):
                arr = buckets.get(key(gx[i] + a_, gy[i] + b_))
                if not arr:
                    continue
                for j in arr:
                    dz = z2[j] - z2[i]
                    if dz <= 12.0:
                        continue
                    reach = rr[j] + rr[i] + 0.8
                    dd = math.hypot(sx[j] - sx[i], sy_[j] - sy_[i])
                    if dd >= reach:
                        continue
                    m = max(m, min(1.0, (dz - 12.0) / 24.0) * min(1.0, (reach - dd) / (reach * 0.5)))
        dim[i] = 1 - 0.9 * m
    al = al * dim * gain
    img = np.zeros((size, size), np.float32)
    for i in range(len(P)):
        if al[i] <= 0.01 or rr[i] <= 0.3:
            continue
        r = rr[i]
        bx = size / 2.0 + sx[i]
        by = size / 2.0 + sy_[i]
        x0, x1_ = int(math.floor(bx - r - 1)), int(math.ceil(bx + r + 1))
        y0, y1_ = int(math.floor(by - r - 1)), int(math.ceil(by + r + 1))
        if x1_ < 0 or y1_ < 0 or x0 >= size or y0 >= size:
            continue
        xs = np.arange(max(0, x0), min(size, x1_))
        ys = np.arange(max(0, y0), min(size, y1_))
        if not len(xs) or not len(ys):
            continue
        X, Y = np.meshgrid(xs - bx, ys - by)
        cov = np.clip(r + 0.5 - np.hypot(X, Y), 0, 1) * al[i]
        sub = img[ys[0]:ys[-1] + 1, xs[0]:xs[-1] + 1]
        img[ys[0]:ys[-1] + 1, xs[0]:xs[-1] + 1] = sub + (clum[i] * cov) * (1 - sub)
    return img


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("measure", "ceiling"))
    ap.add_argument("render", nargs="?", help="still to measure (measure mode)")
    ap.add_argument("--reference", default=DEFAULT_REF)
    ap.add_argument("--cloud", default=DEFAULT_CLOUD)
    ap.add_argument("--crop", default="%d,%d,%d" % (CROP_CENTRE + (CROP_SIZE,)))
    ap.add_argument("--thr", type=float, default=0.10)
    ap.add_argument("--close", type=int, default=9)
    ap.add_argument("--search", type=int, default=12)
    ap.add_argument("--t", type=float, default=0.0, help="s2 motion time for ceiling")
    ap.add_argument("--cam", type=float, default=2.7,
                    help="camera distance in knot heights for ceiling (s2 uses 2.7)")
    ap.add_argument("--save", help="write the measured image (png)")
    ap.add_argument("--json", help="write the numbers to this json file")
    ap.add_argument("--min-band", type=float, default=0.90,
                    help="band IoU that counts as a pass")
    args = ap.parse_args()

    cx, cy, size = [int(v) for v in args.crop.split(",")]
    ref, crop = crop_reference(args.reference, (cx, cy), size)
    print("reference %s crop x=%d y=%d %dx%d" % (args.reference, crop[0], crop[1], crop[2], crop[2]))

    if args.mode == "measure":
        if not args.render:
            raise SystemExit("measure needs a render path")
        img = luminance(args.render)
    else:
        img = render_s2_cloud(args.cloud, size, args.t, cam=args.cam)
        print("s2 cloud replica: %s at t=%.2f s, cam %.2f x H"
              % (args.cloud, args.t, args.cam))

    res = measure(img, ref, args.thr, args.close, args.search)
    res["mode"] = args.mode
    res["source"] = args.render or args.cloud
    for k in ("band_iou", "silhouette_iou_blur6", "shift_px",
              "render_coverage", "reference_coverage",
              "render_core_coverage", "reference_core_coverage"):
        print("  %-24s %s" % (k, res[k]))
    if args.save:
        Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(args.save)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(res, f, indent=2)
    ok = res["band_iou"] >= args.min_band
    print("VERDICT band_iou %.4f vs bar %.2f -> %s"
          % (res["band_iou"], args.min_band, "PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
