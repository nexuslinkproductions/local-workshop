#!/usr/bin/env python3
"""knot-iou.py: the s2-fitted knot trace, the SDF bake, and the silhouette meter.

Modes

  trace      Rebuild `kit/assets/swarm-knot-sdf.png` from the s2 reference crop
             (the card's "re-trace the knot FITTED to s2") and print the numbers
             that follow from the trace: strand half width, the renderer's
             px-per-unit, the Swarm size it implies, and the geometry's own
             predicted silhouette IoU against the reference band. The fit is
             measured before any QML runs.

  measure    Silhouette agreement between a Knot still and the s2 crop. Two
             meters on luminance, both after one translation search:

               band_iou              threshold at `--thr`, close with a square of
                                     `--close` px so dots merge into strand bands,
                                     IoU. Dot-phase independent: this is the
                                     headline, and the number the card gates on.
               silhouette_iou_blur6  threshold at 0.35, box blur 6, threshold the
                                     blur at 0.02, IoU. Kept because it is the
                                     meter the C2 verifier used (0.260 there).

  still      Render a Knot still through `tools/qml-shot.sh` at 2560x1440, crop
             the 540 knot box, measure it, and write the JPEGs. One command, so
             every number in docs/knot-iou.md is reproducible without a manual
             render step.

  ceiling    Project the s2 reference's own point cloud (knot3d.json) through the
             s2 engine's camera and measure that image: the ceiling of any
             renderer driven by that cloud, and the reason this card re-traced
             the knot from the still instead (0.766 band, see the doc).

Reference crop: s2-rest.png, 2560x1440, the 540 px box centred on the layout
position of the knot (Tokens.centreX 1280, Tokens.goldenY1 550) = x 1010, y 280.
Every number in docs/knot-iou.md comes from this crop and these meters.

Python + PIL + numpy only.
"""
import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
from collections import deque

import numpy as np
from PIL import Image, ImageFilter

DEFAULT_REF = ("/Users/marcelspatz/NEXUS_AI_CENTER/04_PROJECTS/HUD/"
               "hud-candidates/comp-r1/s2/s2-rest.png")
DEFAULT_CLOUD = ("/Users/marcelspatz/NEXUS_AI_CENTER/04_PROJECTS/HUD/"
                 "hud-candidates/comp-r1/s2/src/knot/knot3d.json")
CROP_CENTRE = (1280, 550)
CROP_SIZE = 540

# Swarm.qml's shader constants, which the bake has to live inside. They are fixed
# by the C2 renderer; the trace adapts to them, not the other way round.
R_TUBE_UNITS = 0.05640288     # u_rTube: tube radius, in units
SDF_RANGE = 0.42              # u_sdfRange: R channel 0..1 maps to 0..0.42 unit
SDF_LO = -1.45                # u_sdfLo
SDF_SPAN = 2.9                # u_sdfSpan
SDF_SIZE = 1024               # kit/assets/swarm-knot-sdf.png
PX_PER_UNIT_FACTOR = 0.30     # Swarm.qml: u_pxPerUnit = 0.30 * size
MARCH_BOUND_UNITS = 1.34      # swarm.frag: the ray-march sphere
MAX_TIP_UNITS = 1.28          # where the trace puts the outermost lobe tip


# ------------------------------------------------------------------- meters
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
                         "at the crop size (%d) first"
                         % (render_lum.shape, ref_lum.shape, CROP_SIZE))
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


# --------------------------------------------------------------- distances
def edt1d(f):
    """Felzenszwalb 1D squared distance transform of f (f = squared cost)."""
    n = len(f)
    d = np.empty(n, np.float64)
    v = np.zeros(n, np.int64)
    z = np.empty(n + 1, np.float64)
    k = 0
    v[0] = 0
    z[0] = -np.inf
    z[1] = np.inf
    for q in range(1, n):
        s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * q - 2.0 * v[k])
        while s <= z[k]:
            k -= 1
            s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * q - 2.0 * v[k])
        k += 1
        v[k] = q
        z[k] = s
        z[k + 1] = np.inf
    k = 0
    for q in range(n):
        while z[k + 1] < q:
            k += 1
        d[q] = (q - v[k]) ** 2 + f[v[k]]
    return d


def edt(mask):
    """Euclidean distance (px) from every pixel to the nearest True pixel."""
    h, w = mask.shape
    f = np.where(mask, 0.0, 1e12)
    out = np.empty((h, w), np.float64)
    for y in range(h):
        out[y] = edt1d(f[y])
    for x in range(w):
        out[:, x] = edt1d(out[:, x])
    return np.sqrt(out)


def blob_filter(mask, min_area):
    """Keep only 4-connected components of at least `min_area` pixels."""
    h, w = mask.shape
    seen = np.zeros((h, w), bool)
    keep = np.zeros((h, w), bool)
    ys, xs = np.nonzero(mask)
    for y0, x0 in zip(ys, xs):
        if seen[y0, x0]:
            continue
        q = deque([(y0, x0)])
        seen[y0, x0] = True
        px = [(y0, x0)]
        while q:
            y, x = q.popleft()
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                yy, xx = y + dy, x + dx
                if 0 <= yy < h and 0 <= xx < w and mask[yy, xx] and not seen[yy, xx]:
                    seen[yy, xx] = True
                    q.append((yy, xx))
                    px.append((yy, xx))
        if len(px) >= min_area:
            for y, x in px:
                keep[y, x] = True
    return keep


# ------------------------------------------------------------------ the trace
def opening(mask, size):
    """Morphological opening: removes anything narrower than `size` px."""
    im = Image.fromarray((mask.astype(np.uint8) * 255))
    im = im.filter(ImageFilter.MinFilter(size)).filter(ImageFilter.MaxFilter(size))
    return np.array(im) > 127


def trace_mask(lum, thr=0.10, close=9, open_px=5, r_max=276.0, min_area=800):
    """The knot's strand band from the s2 crop, without s2's outer dot ring.

    s2's knot carries a faint decorative ring of dots outside the lobes (class
    `ring` in its own cloud; its lower-left arc is bright enough to pass the
    meter's 0.10 threshold, and closing merges parts of it into the knot). This
    card says the Knot has no ring, so the trace runs

        threshold -> closing (dots to strands) -> opening (drop the thin ring
        arcs the closing attached, and any specks) -> r_max cut -> blob filter

    The strands are about 24 px wide, the ring arcs under 7 px, so an opening of
    `open_px` removes the ring and keeps the knot.
    """
    size = lum.shape[0]
    base = lum > thr
    yy, xx = np.mgrid[0:size, 0:size]
    r = np.hypot(xx - (size - 1) / 2.0, yy - (size - 1) / 2.0)
    base &= r <= r_max
    m = closing(base, close)
    m = opening(m, open_px)
    m &= r <= r_max
    m = blob_filter(m, min_area)
    return m, r


def signed_inside(mask, pad=80):
    """Signed distance to the mask boundary, positive inside, on a padded canvas."""
    h, w = mask.shape
    p = np.zeros((h + 2 * pad, w + 2 * pad), bool)
    p[pad:pad + h, pad:pad + w] = mask
    d_in = edt(~p)      # distance to the nearest background pixel
    d_out = edt(p)      # distance to the nearest mask pixel
    s = d_in - d_out    # > 0 inside
    return s[pad:pad + h, pad:pad + w]


def trace_stats(mask):
    area = int(mask.sum())
    p = np.zeros_like(mask)
    p[1:, :] |= mask[1:, :] & ~mask[:-1, :]
    p[:-1, :] |= mask[:-1, :] & ~mask[1:, :]
    p[:, 1:] |= mask[:, 1:] & ~mask[:, :-1]
    p[:, :-1] |= mask[:, :-1] & ~mask[:, 1:]
    perim = int(p.sum())
    s = signed_inside(mask)
    ridge = np.zeros_like(s)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dx or dy:
                ridge = np.maximum(ridge, np.roll(np.roll(s, dy, 0), dx, 1))
    is_ridge = (s > 0) & (s >= ridge - 1e-9) & (s > 1.0)
    yy, xx = np.nonzero(mask)
    size = mask.shape[0]
    r = np.hypot(xx - (size - 1) / 2.0, yy - (size - 1) / 2.0)
    return {
        "area_px": area,
        "perimeter_px": perim,
        "half_width_2ap_px": round(2.0 * area / max(perim, 1), 3),
        "half_width_ridge_px": round(float(np.median(s[is_ridge])), 3),
        "tip_px": round(float(r.max()), 1),
        "bbox": [int(xx.min()), int(yy.min()), int(xx.max()), int(yy.max())],
    }


def bake_sdf(lum, tube_px, offset_px, out_path=None, size=SDF_SIZE,
             thr=0.10, close=9, open_px=5, r_max=276.0, min_area=800):
    """Bake the centre-line distance texture Swarm marches.

    R = (tube_px - offset_px - s_in) / px_per_unit, clipped to 0..SDF_RANGE
    G = 1.0: the ring channel is switched off (the card excludes the ring, and
        u_rRing 0.0127 unit can never be reached from a 0.42 unit distance)
    A = 255: Qt premultiplies image textures; a non-opaque alpha scales the
        bytes toward zero (C2 hit this).

    `offset_px` dilates the silhouette. The shader puts dots at cell centres on
    the surface, so the rendered band is inset by a fraction of a dot pitch; the
    offset is the measured compensation for that inset (see docs/knot-iou.md).
    """
    mask, _ = trace_mask(lum, thr=thr, close=close, open_px=open_px,
                         r_max=r_max, min_area=min_area)
    stats = trace_stats(mask)
    px_per_unit = max(tube_px / R_TUBE_UNITS, stats["tip_px"] / MAX_TIP_UNITS)
    s = signed_inside(mask, pad=80)

    h, w = lum.shape
    u = (np.arange(size) + 0.5) / size * SDF_SPAN + SDF_LO   # units per texel
    UX, UY = np.meshgrid(u, u, indexing="xy")
    # Object space is y-up (the shader's uv.y = (p.y + 1.45) / 2.9) while the
    # crop image is y-down, so the row index runs the other way. Getting this
    # wrong renders the knot upside down; it did, on the first bake.
    ix = np.rint((w - 1) / 2.0 + UX * px_per_unit).astype(np.int64)
    iy = np.rint((h - 1) / 2.0 - UY * px_per_unit).astype(np.int64)
    valid = (ix >= 0) & (ix < w) & (iy >= 0) & (iy < h)
    s_at = np.full((size, size), -1e3, np.float32)
    s_at[valid] = s[iy[valid], ix[valid]]

    d_px = (tube_px - offset_px) - s_at
    d_units = np.clip(d_px / px_per_unit, 0.0, SDF_RANGE)
    r = (d_units / SDF_RANGE * 255.0).astype(np.uint8)

    tex = np.empty((size, size, 4), np.uint8)
    tex[:, :, 0] = r
    tex[:, :, 1] = 255
    tex[:, :, 2] = 0
    tex[:, :, 3] = 255
    if out_path:
        Image.fromarray(tex, "RGBA").save(out_path)

    # The silhouette a render driven by this texture must have: the tube surface
    # is {d <= u_rTube}, i.e. {s_in >= tube_px - offset - rTubePx}. Scored on the
    # crop grid, not on the 1024 texture grid.
    pred = s >= (tube_px - offset_px) - R_TUBE_UNITS * px_per_unit
    info = {
        "px_per_unit": round(px_per_unit, 2),
        "swarm_size_540": round(px_per_unit / PX_PER_UNIT_FACTOR, 1),
        "tube_px": round(tube_px, 3),
        "offset_px": offset_px,
        "tip_units": round(stats["tip_px"] / px_per_unit + R_TUBE_UNITS, 3),
        "march_bound_units": MARCH_BOUND_UNITS,
        "sdf_size": size,
        "sdf_lo": SDF_LO,
        "sdf_span": SDF_SPAN,
        "sdf_range": SDF_RANGE,
        "ring_channel": "off (G = 1.0 -> 0.42 unit, u_rRing 0.0127 never hit)",
        "trace": stats,
    }
    return tex, info, pred, mask


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


# -------------------------------------------------------------------- stills
STILL_QML = """import QtQuick
import NexusHud.V5 1.0

// Generated by tools/knot-iou.py still: the deck frame with one Knot on it, so
// the still is the same 540 px box the deck composes at (Tokens.centreX 1280,
// Tokens.goldenY1 550) and the 540 crop of it is a like-for-like reference crop.
Item {
    width: %(w)d
    height: %(h)d

    Rectangle { anchors.fill: parent; color: "#0a0f1c" }

    Loader {
        source: "file://%(knot)s"
        onLoaded: {
            item.animate = false
            item.assembling = %(assembling)s
            item.assembleProgress = %(progress)s
        }
    }
}
"""


def repo_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(here)


def still(progress, out_prefix, width=2560, height=1440, assembling=True):
    root = repo_root()
    kit = os.path.join(root, "nexuslink.hud", "v5", "kit")
    knot = os.path.join(kit, "Knot.qml")
    if not os.path.isfile(knot):
        raise SystemExit("still: no Knot.qml at %s" % knot)
    tmp = tempfile.mkdtemp(prefix="knot-still-")
    imports = os.path.join(tmp, "imports")
    os.makedirs(os.path.join(imports, "NexusHud"))
    os.symlink(kit, os.path.join(imports, "NexusHud", "V5"))
    wrap = os.path.join(tmp, "still.qml")
    with open(wrap, "w") as f:
        f.write(STILL_QML % {"w": width, "h": height, "knot": knot,
                             "assembling": "true" if assembling else "false",
                             "progress": repr(float(progress))})
    png = os.path.join(tmp, "still.png")
    env = dict(os.environ)
    env["QML2_IMPORT_PATH"] = imports
    env["QML_IMPORT_PATH"] = imports
    env["QT_QPA_PLATFORM"] = "offscreen"
    env["QML_SHOT_DELAY"] = env.get("QML_SHOT_DELAY", "900")
    cmd = [os.path.join(root, "tools", "qml-shot.sh"), wrap, png,
           str(width), str(height)]
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        sys.stderr.write(r.stderr[-4000:])
        raise SystemExit("still: qml-shot failed (exit %d)" % r.returncode)

    deck = Image.open(png).convert("RGB")
    x0 = int(round(CROP_CENTRE[0] - CROP_SIZE / 2.0))
    y0 = int(round(CROP_CENTRE[1] - CROP_SIZE / 2.0))
    crop = deck.crop((x0, y0, x0 + CROP_SIZE, y0 + CROP_SIZE))
    os.makedirs(os.path.dirname(os.path.abspath(out_prefix)), exist_ok=True)
    deck_path = out_prefix + "-deck.jpg"
    crop_path = out_prefix + "-540.jpg"
    crop_png = out_prefix + "-540.png"
    deck.save(deck_path, quality=86, optimize=True)
    crop.save(crop_path, quality=90)
    crop.save(crop_png)
    print("deck  %s  %dx%d" % (deck_path, width, height))
    print("crop  %s  (x %d y %d %dx%d)" % (crop_path, x0, y0, CROP_SIZE, CROP_SIZE))
    return crop_png


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("trace", "measure", "ceiling", "still"))
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
    # trace
    ap.add_argument("--out", help="trace: SDF png to write (default: print only)")
    ap.add_argument("--tube-px", type=float, default=None,
                    help="trace: strand half width in px (default: ridge median)")
    ap.add_argument("--offset-px", type=float, default=0.0,
                    help="trace: dilate the silhouette by this many px")
    ap.add_argument("--trace-thr", type=float, default=0.10)
    ap.add_argument("--trace-close", type=int, default=9)
    ap.add_argument("--open-px", type=int, default=5,
                    help="trace: opening kernel, removes the thin ring arcs")
    ap.add_argument("--r-max", type=float, default=276.0)
    ap.add_argument("--mask-out", help="trace: write the traced band mask (png)")
    # still
    ap.add_argument("--progress", type=float, default=1.0,
                    help="still: assembleProgress 0..1")
    ap.add_argument("--rest", action="store_true",
                    help="still: assembling false (the rest state)")
    ap.add_argument("--width", type=int, default=2560)
    ap.add_argument("--height", type=int, default=1440)
    args = ap.parse_args()

    cx, cy, size = [int(v) for v in args.crop.split(",")]
    ref, crop = crop_reference(args.reference, (cx, cy), size)
    print("reference %s crop x=%d y=%d %dx%d"
          % (args.reference, crop[0], crop[1], crop[2], crop[2]))

    if args.mode == "trace":
        if args.tube_px is None:
            mask, _ = trace_mask(ref, thr=args.trace_thr, close=args.trace_close,
                                 open_px=args.open_px, r_max=args.r_max)
            args.tube_px = trace_stats(mask)["half_width_ridge_px"]
        tex, info, pred, mask = bake_sdf(
            ref, args.tube_px, args.offset_px, args.out,
            thr=args.trace_thr, close=args.trace_close, open_px=args.open_px,
            r_max=args.r_max)
        stats = info["trace"]
        print("trace  band %d px, half width %.2f px (ridge) / %.2f px (2A/P), "
              "tip %.1f px, bbox %s"
              % (stats["area_px"], stats["half_width_ridge_px"],
                 stats["half_width_2ap_px"], stats["tip_px"], stats["bbox"]))
        print("       px_per_unit %.2f -> Swarm size %.1f at a 540 Knot; tip at "
              "%.2f units (march bound %.2f)"
              % (info["px_per_unit"], info["swarm_size_540"], info["tip_units"],
                 info["march_bound_units"]))
        ref_band = closing(ref > args.thr, args.close)
        print("       predicted silhouette vs reference band: IoU %.4f "
              "(coverage %.4f vs %.4f, offset %.1f px, ring excluded from trace)"
              % (iou(closing(pred, args.close), ref_band), float(pred.mean()),
                 float(ref_band.mean()), args.offset_px))
        if args.out:
            print("       wrote %s" % args.out)
        if args.mask_out:
            Image.fromarray(mask.astype(np.uint8) * 255).save(args.mask_out)
            print("       mask %s" % args.mask_out)
        if args.json:
            with open(args.json, "w") as f:
                json.dump(info, f, indent=2)
        return 0

    if args.mode == "still":
        prefix = args.out or os.path.join(tempfile.gettempdir(), "knot-still")
        png = still(args.progress, prefix, args.width, args.height,
                    assembling=not args.rest)
        img = luminance(png)
        res = measure(img, ref, args.thr, args.close, args.search)
        res["mode"] = "still"
        res["source"] = png
        res["progress"] = 1.0 if args.rest else args.progress
        res["assembling"] = not args.rest
        for k in ("band_iou", "silhouette_iou_blur6", "shift_px",
                  "render_coverage", "reference_coverage",
                  "render_core_coverage", "reference_core_coverage"):
            print("  %-24s %s" % (k, res[k]))
        if args.json:
            with open(args.json, "w") as f:
                json.dump(res, f, indent=2)
        return 0

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
