#!/usr/bin/env python3
"""knot-iou.py: the s2-fitted knot trace, the SDF bake, and the silhouette meter.

Modes

  trace      Rebuild the knot SDF from the s2 reference crop (the card's
             "re-trace the knot FITTED to s2") and print the numbers that follow
             from the trace: strand half width, the renderer's px-per-unit, the
             Swarm size it implies, and the geometry's own predicted silhouette
             IoU against the reference band. The fit is measured before any QML
             runs.

  measure    Silhouette agreement between a Knot still and the s2 crop. Two
             meters on luminance, both after one translation search:

               band_iou              threshold at `--thr`, close with a square of
                                     `--close` px so dots merge into strand bands,
                                     IoU. Dot-phase independent: this is the
                                     headline.
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

Python 3 + PIL only, no numpy: a mask is one int per row (one bit per pixel at
8-bit spacing), so an IoU is a row-wise AND plus a byte popcount, and the
distance transforms are the same Felzenszwalb passes in plain lists.
"""
import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import tempfile
from collections import deque

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
SDF_SIZE = 1024               # kit/assets/swarm-knot-sdf-s2.png
PX_PER_UNIT_FACTOR = 0.30     # Swarm.qml: u_pxPerUnit = 0.30 * size
MARCH_BOUND_UNITS = 1.34      # swarm.frag: the ray-march sphere
MAX_TIP_UNITS = 1.28          # where the trace puts the outermost lobe tip

_TO01 = bytes(1 if i > 127 else 0 for i in range(256))
_TO255 = bytes(255 if i else 0 for i in range(256))


# ------------------------------------------------------------- pixel containers
class Plane:
    """A float plane: luminance, a 0/1 field, or a distance field."""
    __slots__ = ("v", "w", "h")

    def __init__(self, v, w, h):
        self.v, self.w, self.h = v, w, h


class Mask:
    """A binary mask: one int per row, one byte per pixel, bit set = inside.

    Storing a byte per pixel (value 1) instead of a bit keeps `to_bytes(w)` a
    direct popcount and makes horizontal shifts an int shift, so an IoU is
    cheap without numpy.
    """
    __slots__ = ("w", "h", "rows")

    def __init__(self, w, h, rows):
        self.w, self.h, self.rows = w, h, rows

    def count(self):
        w = self.w
        return sum(r.to_bytes(w, "big").count(1) for r in self.rows)

    def bits(self):
        """Flat list of 0/1, row-major."""
        out = []
        w = self.w
        for r in self.rows:
            out.extend(r.to_bytes(w, "big"))
        return out


def mask_from_bits(bits, w, h):
    rows = []
    for y in range(h):
        rows.append(int.from_bytes(bytes(bits[y * w:(y + 1) * w]), "big"))
    return Mask(w, h, rows)


def mask_from_plane(plane, thr):
    """`plane > thr`, exactly the comparison the meters use."""
    w, h = plane.w, plane.h
    v = plane.v
    bits = bytearray(w * h)
    for i in range(w * h):
        if v[i] > thr:
            bits[i] = 1
    return mask_from_bits(bits, w, h)


def mask_to_image(mask):
    data = b"".join(r.to_bytes(mask.w, "big").translate(_TO255)
                    for r in mask.rows)
    return Image.frombytes("L", (mask.w, mask.h), data)


def mask_from_image(im):
    data = im.tobytes()
    w, h = im.size
    rows = [int.from_bytes(data[y * w:(y + 1) * w].translate(_TO01), "big")
            for y in range(h)]
    return Mask(w, h, rows)


def plane_from_mask(mask):
    return Plane([float(b) for b in mask.bits()], mask.w, mask.h)


def complement(mask):
    """Byte-wise complement: a row stores one byte per pixel with value 0 or 1."""
    ones = int.from_bytes(b"\x01" * mask.w, "big")
    return Mask(mask.w, mask.h, [r ^ ones for r in mask.rows])


def pad_mask(mask, pad):
    w, h = mask.w + 2 * pad, mask.h + 2 * pad
    rows = [0] * h
    for y in range(mask.h):
        rows[y + pad] = mask.rows[y] << (8 * pad)
    return Mask(w, h, rows)


# ------------------------------------------------------------------- meters
def read_lum(src):
    """Rec.709 luminance as a Plane. `src` is a path or an open PIL image."""
    im = src.convert("RGB") if isinstance(src, Image.Image) else Image.open(src).convert("RGB")
    w, h = im.size
    d = im.tobytes()
    vals = [0.0] * (w * h)
    for i in range(w * h):
        j = 3 * i
        vals[i] = (0.2126 * d[j] + 0.7152 * d[j + 1] + 0.0722 * d[j + 2]) / 255.0
    return Plane(vals, w, h)


def box_blur(plane, radius):
    """Mean over a (2*radius+1)^2 window, edge-clipped (an integral image)."""
    w, h, a = plane.w, plane.h, plane.v
    ii = [[0.0] * (w + 1) for _ in range(h + 1)]
    for y in range(h):
        row, prev, acc = ii[y + 1], ii[y], 0.0
        base = y * w
        for x in range(w):
            acc += a[base + x]
            row[x + 1] = prev[x + 1] + acc
    y0s = [min(max(y - radius, 0), h) for y in range(h)]
    y1s = [min(max(y + radius + 1, 0), h) for y in range(h)]
    x0s = [min(max(x - radius, 0), w) for x in range(w)]
    x1s = [min(max(x + radius + 1, 0), w) for x in range(w)]
    out = [0.0] * (w * h)
    for y in range(h):
        y0, y1 = y0s[y], y1s[y]
        r0, r1 = ii[y0], ii[y1]
        o = y * w
        for x in range(w):
            x0, x1 = x0s[x], x1s[x]
            s = r1[x1] - r0[x1] - r1[x0] + r0[x0]
            n = (y1 - y0) * (x1 - x0)
            out[o + x] = s / n if n > 0 else 0.0
    return Plane(out, w, h)


def iou(a, b):
    w = a.w
    inter = 0
    for ra, rb in zip(a.rows, b.rows):
        inter += (ra & rb).to_bytes(w, "big").count(1)
    u = a.count() + b.count() - inter
    return float(inter) / u if u else 0.0


def closing(mask, size):
    im = mask_to_image(mask)
    im = im.filter(ImageFilter.MaxFilter(size)).filter(ImageFilter.MinFilter(size))
    return mask_from_image(im)


def opening(mask, size):
    """Morphological opening: removes anything narrower than `size` px."""
    im = mask_to_image(mask)
    im = im.filter(ImageFilter.MinFilter(size)).filter(ImageFilter.MaxFilter(size))
    return mask_from_image(im)


def shift(mask, dx, dy):
    w, h = mask.w, mask.h
    row_mask = (1 << (8 * w)) - 1
    out = [0] * h
    for y in range(h):
        sy = y - dy
        if 0 <= sy < h:
            v = mask.rows[sy]
            if dx > 0:
                v = (v << (8 * dx)) & row_mask
            elif dx < 0:
                v = v >> (8 * -dx)
            out[y] = v
    return Mask(w, h, out)


def crop_reference(path, centre, size):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    x0 = int(round(centre[0] - size / 2.0))
    y0 = int(round(centre[1] - size / 2.0))
    x0 = max(0, min(w - size, x0))
    y0 = max(0, min(h - size, y0))
    return read_lum(im.crop((x0, y0, x0 + size, y0 + size))), (x0, y0, size)


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
    if (render_lum.w, render_lum.h) != (ref_lum.w, ref_lum.h):
        raise SystemExit("render is %dx%d, reference crop is %dx%d: render the "
                         "Knot item at the crop size (%d) first"
                         % (render_lum.w, render_lum.h, ref_lum.w, ref_lum.h,
                            CROP_SIZE))
    rm = mask_from_plane(render_lum, thr)
    fm = mask_from_plane(ref_lum, thr)
    dx, dy = register(rm, fm, thr, close, search)
    s = shift(rm, dx, dy)
    render_core = mask_from_plane(render_lum, 0.35)
    render_core_shifted = shift(render_core, dx, dy)
    ref_core = mask_from_plane(ref_lum, 0.35)
    blur = iou(mask_from_plane(box_blur(plane_from_mask(render_core_shifted), 6), 0.02),
               mask_from_plane(box_blur(plane_from_mask(ref_core), 6), 0.02))
    n = float(rm.w * rm.h)
    return {
        "shift_px": [dx, dy],
        "threshold": thr,
        "close_px": close,
        "band_iou": round(iou(closing(s, close), closing(fm, close)), 4),
        "silhouette_iou_blur6": round(blur, 4),
        "render_coverage": round(rm.count() / n, 5),
        "reference_coverage": round(fm.count() / n, 5),
        "render_core_coverage": round(render_core.count() / n, 5),
        "reference_core_coverage": round(ref_core.count() / n, 5),
    }


# --------------------------------------------------------------- distances
def edt1d(f):
    """Felzenszwalb 1D squared distance transform of f (f = squared cost)."""
    n = len(f)
    d = [0.0] * n
    v = [0] * n
    z = [0.0] * (n + 1)
    k = 0
    v[0] = 0
    z[0] = -math.inf
    z[1] = math.inf
    for q in range(1, n):
        s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * q - 2.0 * v[k])
        while s <= z[k]:
            k -= 1
            s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * q - 2.0 * v[k])
        k += 1
        v[k] = q
        z[k] = s
        z[k + 1] = math.inf
    k = 0
    for q in range(n):
        while z[k + 1] < q:
            k += 1
        d[q] = (q - v[k]) ** 2 + f[v[k]]
    return d


def edt(mask):
    """Euclidean distance (px) from every pixel to the nearest set pixel."""
    w, h = mask.w, mask.h
    out = [0.0] * (w * h)
    INF = 1e12
    for y in range(h):
        row = mask.rows[y].to_bytes(w, "big")
        out[y * w:(y + 1) * w] = edt1d([0.0 if b else INF for b in row])
    col = [0.0] * h
    for x in range(w):
        for y in range(h):
            col[y] = out[y * w + x]
        d = edt1d(col)
        for y in range(h):
            out[y * w + x] = d[y]
    return [math.sqrt(v) for v in out]


def signed_inside(mask, pad=80):
    """Signed distance to the mask boundary, positive inside, on a padded canvas."""
    w, h, pw = mask.w, mask.h, mask.w + 2 * pad
    p = pad_mask(mask, pad)
    d_in = edt(complement(p))   # distance to the nearest background pixel
    d_out = edt(p)              # distance to the nearest mask pixel
    s = [a - b for a, b in zip(d_in, d_out)]   # > 0 inside
    out = []
    for y in range(h):
        o = (y + pad) * pw + pad
        out.extend(s[o:o + w])
    return out


def blob_filter(mask, min_area):
    """Keep only 4-connected components of at least `min_area` pixels."""
    w, h = mask.w, mask.h
    bits = mask.bits()
    seen = bytearray(w * h)
    keep = bytearray(w * h)
    for y0 in range(h):
        for x0 in range(w):
            idx = y0 * w + x0
            if not bits[idx] or seen[idx]:
                continue
            q = deque([(y0, x0)])
            seen[idx] = 1
            px = [(y0, x0)]
            while q:
                y, x = q.popleft()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < h and 0 <= xx < w:
                        j = yy * w + xx
                        if bits[j] and not seen[j]:
                            seen[j] = 1
                            q.append((yy, xx))
                            px.append((yy, xx))
            if len(px) >= min_area:
                for y, x in px:
                    keep[y * w + x] = 1
    return mask_from_bits(keep, w, h)


# ------------------------------------------------------------------ the trace
def trace_mask(lum, thr=0.10, close=9, open_px=7, r_max=276.0, min_area=2000):
    """The knot's strand band from the s2 crop, without s2's outer dot ring.

    s2's knot carries a faint decorative ring of dots outside the lobes (class
    `ring` in its own cloud; parts of it are bright enough to pass the meter's
    0.10 threshold, and closing merges some of it into the knot). This card says
    the Knot has no ring, so the trace runs

        threshold -> closing (dots to strands) -> opening (drop the thin ring
        arcs the closing attached) -> r_max cut -> component floor

    The strands are about 26 px wide, the ring arcs under 8 px, so an opening of
    `open_px` removes most of the ring and keeps the knot. `min_area` then drops
    what is left detached: one 1,043 px arc on the left survives the opening, and
    the knot itself is a single 51k px blob, so a 2,000 px floor removes the arc
    without touching the mark.
    """
    w, h = lum.w, lum.h
    cx = cy = (w - 1) / 2.0
    base = bytearray(w * h)
    v = lum.v
    for y in range(h):
        dy = y - cy
        o = y * w
        for x in range(w):
            dx = x - cx
            if v[o + x] > thr and dx * dx + dy * dy <= r_max * r_max:
                base[o + x] = 1
    m = closing(mask_from_bits(base, w, h), close)
    m = opening(m, open_px)
    bits = m.bits()
    for y in range(h):
        dy = y - cy
        o = y * w
        for x in range(w):
            if bits[o + x]:
                dx = x - cx
                if dx * dx + dy * dy > r_max * r_max:
                    bits[o + x] = 0
    m = blob_filter(mask_from_bits(bits, w, h), min_area)
    return m


def trace_stats(mask, s=None):
    w, h = mask.w, mask.h
    bits = mask.bits()
    area = sum(bits)
    perim = 0
    for y in range(h):
        o = y * w
        for x in range(w):
            if not bits[o + x]:
                continue
            if (x == 0 or not bits[o + x - 1] or x == w - 1 or not bits[o + x + 1]
                    or y == 0 or not bits[o - w + x] or y == h - 1
                    or not bits[o + w + x]):
                perim += 1
    if s is None:
        s = signed_inside(mask)
    # ridge: s >= every 8-neighbour (np.roll semantics, so the edges wrap)
    ridge = [0.0] * (w * h)
    for y in range(h):
        for x in range(w):
            i = y * w + x
            best = s[i]
            for dy in (-1, 0, 1):
                yy = (y + dy) % h
                for dx in (-1, 0, 1):
                    if dx or dy:
                        v = s[yy * w + (x + dx) % w]
                        if v > best:
                            best = v
            ridge[i] = best
    is_ridge = [s[i] for i in range(w * h)
                if s[i] > 0 and s[i] >= ridge[i] - 1e-9 and s[i] > 1.0]
    ys, xs = [], []
    tip = 0.0
    cx = cy = (w - 1) / 2.0
    for y in range(h):
        o = y * w
        for x in range(w):
            if bits[o + x]:
                xs.append(x)
                ys.append(y)
                r = math.hypot(x - cx, y - cy)
                if r > tip:
                    tip = r
    return {
        "area_px": area,
        "perimeter_px": perim,
        "half_width_2ap_px": round(2.0 * area / max(perim, 1), 3),
        "half_width_ridge_px": round(float(statistics.median(is_ridge)), 3),
        "tip_px": round(tip, 1),
        "bbox": [min(xs), min(ys), max(xs), max(ys)],
    }


def _hash01(a, b, seed):
    """Deterministic 0..1 hash of two integers (the scatter offsets)."""
    v = (a * 73856093) ^ (b * 19349663) ^ (seed * 83492791)
    v &= 0xFFFFFFFF
    v ^= v >> 13
    v = (v * 1274126177) & 0xFFFFFFFF
    v ^= v >> 16
    return v / 4294967296.0


def scatter_field(mask, pitch_px=5.5, offset_px=28.0, seed=17):
    """Distance in px to the nearest scattered dot, plus the dot count.

    The scattered cloud is the traced band's dot lattice with one hashed offset
    per cell: the same points at `assembleProgress 0`, a few tens of px away from
    where they settle. It is baked into the texture's B channel so the shader can
    blend the two distance fields instead of displacing dots per fragment (a
    displaced fragment of a raymarched surface has nothing left to draw it).
    """
    w, h, pitch = mask.w, mask.h, pitch_px
    bits = mask.bits()
    pts = bytearray(w * h)
    n = 0
    cy = 0
    while (cy + 0.5) * pitch < h:
        y = (cy + 0.5) * pitch
        cx = 0
        while (cx + 0.5) * pitch < w:
            x = (cx + 0.5) * pitch
            ix, iy = int(x), int(y)
            if bits[iy * w + ix]:
                ang = 2.0 * math.pi * _hash01(cx, cy, seed)
                rad = offset_px * math.sqrt(_hash01(cx, cy, seed + 101))
                px = int(round(x + rad * math.cos(ang)))
                py = int(round(y + rad * math.sin(ang)))
                if 0 <= px < w and 0 <= py < h:
                    pts[py * w + px] = 1
                    n += 1
            cx += 1
        cy += 1
    return edt(mask_from_bits(pts, w, h)), n


def bake_sdf(lum, tube_px, offset_px, out_path=None, size=SDF_SIZE,
             thr=0.10, close=9, open_px=7, r_max=276.0, min_area=2000,
             scatter_pitch=5.5, scatter_offset=28.0, scatter_seed=17):
    """Bake the centre-line distance texture Swarm marches.

    R = (tube_px - offset_px - s_in) / px_per_unit, clipped to 0..SDF_RANGE
    G = 1.0: the ring channel is switched off (the card excludes the ring, and
        u_rRing 0.0127 unit can never be reached from a 0.42 unit distance)
    B = distance to the nearest dot of the scattered cloud (`scatter_field`),
        the same units. The shader blends this with R below `assembleProgress 1`,
        which is how the knot assembles from scattered points; at 1 the sample is
        never read, so the rest frame is untouched.
    A = 255: Qt premultiplies image textures; a non-opaque alpha scales the
        bytes toward zero (C2 hit this).

    `offset_px` dilates the silhouette. The shader puts dots at cell centres on
    the surface, so the rendered band is inset by a fraction of a dot pitch; the
    offset is the measured compensation for that inset (see docs/knot-iou.md).
    """
    mask = trace_mask(lum, thr=thr, close=close, open_px=open_px,
                      r_max=r_max, min_area=min_area)
    w, h = lum.w, lum.h
    s = signed_inside(mask, pad=80)
    stats = trace_stats(mask, s)
    px_per_unit = max(tube_px / R_TUBE_UNITS, stats["tip_px"] / MAX_TIP_UNITS)
    d_scatter, n_scatter = scatter_field(mask, pitch_px=scatter_pitch,
                                         offset_px=scatter_offset,
                                         seed=scatter_seed)

    u_of = [(i + 0.5) / size * SDF_SPAN + SDF_LO for i in range(size)]
    cx = (w - 1) / 2.0
    cy = (h - 1) / 2.0
    edge = (tube_px - offset_px) / px_per_unit
    tex = bytearray(size * size * 4)
    for ty in range(size):
        iy = int(round(cy - u_of[ty] * px_per_unit))
        row = ty * size * 4
        in_row = 0 <= iy < h
        for tx in range(size):
            ix = int(round(cx + u_of[tx] * px_per_unit))
            ok = in_row and 0 <= ix < w
            sv = s[iy * w + ix] if ok else -1e3
            d_units = ((tube_px - offset_px) - sv) / px_per_unit
            if d_units < 0.0:
                d_units = 0.0
            elif d_units > SDF_RANGE:
                d_units = SDF_RANGE
            b_units = d_scatter[iy * w + ix] / px_per_unit if ok else SDF_RANGE
            if b_units > SDF_RANGE:
                b_units = SDF_RANGE
            i = row + tx * 4
            tex[i] = int(d_units / SDF_RANGE * 255.0)
            tex[i + 1] = 255
            tex[i + 2] = int(b_units / SDF_RANGE * 255.0)
            tex[i + 3] = 255
    if out_path:
        Image.frombytes("RGBA", (size, size), bytes(tex)).save(out_path)

    # The silhouette a render driven by this texture must have: the tube surface
    # is {d <= u_rTube}, i.e. {s_in >= tube_px - offset - rTubePx}. Scored on the
    # crop grid, not on the 1024 texture grid.
    limit = (tube_px - offset_px) - R_TUBE_UNITS * px_per_unit
    pred = mask_from_bits([1 if sv >= limit else 0 for sv in s], w, h)
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
        "scatter": {
            "channel": "B (distance to the nearest scattered dot, 0..0.42 unit)",
            "dots": n_scatter,
            "pitch_px": scatter_pitch,
            "offset_px": scatter_offset,
            "seed": scatter_seed,
        },
        "trace": stats,
    }
    return tex, info, pred, mask


# --------------------------------------------------------------- s2 replica
def _sm(a, b, x):
    x = (x - a) / (b - a)
    x = 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)
    return x * x * (3 - 2 * x)


def _pose(t):
    tau, seed = 2 * math.pi, 0.0
    a = lambda p, ph: math.sin(tau * t / p + ph + seed)
    ny = 0.5 * a(31, 0.7) + 0.3 * a(26, 2.1) + 0.2 * a(38, 4.0)
    npp = 0.5 * a(34, 1.9) + 0.3 * a(27.5, 0.4) + 0.2 * a(39, 3.3)
    g = 0.18 + 0.82 * _sm(0.12, 0.8, 0.5 - 0.5 * math.cos(tau * t / 12.0))
    return math.radians(ny * g * 30.0), math.radians(npp * g * 18.0)


def _breath(t, ph, T=5.5):
    u = ((t / T + ph) % 1 + 1) % 1
    if u < 0.4:
        return 0.5 - 0.5 * math.cos(math.pi * (0.0 if u < 0.0 else u) / 0.4)
    u = 1.0 if u > 1.0 else u
    return 0.5 + 0.5 * math.cos(math.pi * (u - 0.4) / 0.6)


def _lobe_phase(x, y):
    th = math.atan2(y, x)
    s = ws = 0.0
    for ang, off in ((-math.pi / 2, 0.0), (math.pi * 5 / 6, 0.035),
                     (math.pi / 6, 0.07)):
        w = math.exp(3 * math.cos(th - ang))
        s += off * w
        ws += w
    return s / ws


def render_s2_cloud(cloud_path, size, t, gain=1.15, cam=2.7):
    """s2's swarm3d.js render at its own pose model, as luminance."""
    with open(cloud_path) as f:
        K = json.load(f)
    Px, Py, Pz = K["p"][0::3], K["p"][1::3], K["p"][2::3]
    Nx, Ny, Nz = K["nr"][0::3], K["nr"][1::3], K["nr"][2::3]
    Q, C = K["q"], K["c"]
    H = float(K["H"])
    n = len(Q)
    span = 80.0
    yaw, pitch = _pose(t)
    cyw, syw = math.cos(yaw), math.sin(yaw)
    cp, sp = math.cos(pitch), math.sin(pitch)
    sc, cd = size / H, cam * H
    r0 = 2.3 * size / 540.0
    azure = (86 / 255.0, 150 / 255.0, 238 / 255.0)
    ice = (150 / 255.0, 220 / 255.0, 236 / 255.0)
    white = (236 / 255.0, 247 / 255.0, 252 / 255.0)
    lw = (0.2126, 0.7152, 0.0722)

    xs, ys, zs, sx, sy_, rr, al, clum = ([0.0] * n for _ in range(8))
    for i in range(n):
        b = _breath(t, _lobe_phase(Px[i], Py[i]))
        k0 = 1 + 0.02 * b
        x, y, z = Px[i] * k0, Py[i] * k0, Pz[i] * k0
        x1 = x * cyw + z * syw
        z1 = -x * syw + z * cyw
        y1 = y * cp - z1 * sp
        z2 = y * sp + z1 * cp
        nx, ny, nz = Nx[i], Ny[i], Nz[i]
        nx1 = nx * cyw + nz * syw
        nz1 = -nx * syw + nz * cyw
        ny1 = ny * cp - nz1 * sp
        nz2 = ny * sp + nz1 * cp
        k = cd / (cd - z2)
        d = min(max(0.5 + z2 / (2 * span), 0.0), 1.0)
        f = min(max(0.5 + 0.5 * nz2, 0.0), 1.0)
        thr = 0.86 + 0.14 * b
        pres = _sm(thr + 0.04, thr - 0.06, Q[i])
        ring = 0.85 if C[i] == 1 else 1.0
        rr[i] = (r0 * k * (0.6 + 0.62 * d) * (0.8 + 0.2 * f) * ring
                 * (0.82 + 0.18 * pres))
        al[i] = ((0.16 + 0.84 * d) * (0.28 + 0.72 * f)
                 * (0.86 + 0.14 * b) * pres)
        w = 0.55 * d + 0.45 * f
        c0 = azure[0] + (ice[0] - azure[0]) * w
        c1 = azure[1] + (ice[1] - azure[1]) * w
        c2 = azure[2] + (ice[2] - azure[2]) * w
        if C[i] == 1:
            c0 += (white[0] - c0) * 0.35
            c1 += (white[1] - c1) * 0.35
            c2 += (white[2] - c2) * 0.35
        clum[i] = c0 * lw[0] + c1 * lw[1] + c2 * lw[2]
        xs[i] = x1 * k * sc
        ys[i] = y1 * k * sc
        zs[i] = z2

    # occlusion: dim a point that has a clearly nearer point on top of it
    buckets = {}
    gx = [int(math.floor(v / 8.0)) for v in xs]
    gy = [int(math.floor(v / 8.0)) for v in ys]
    for i in range(n):
        buckets.setdefault((gx[i], gy[i]), []).append(i)
    dim = [1.0] * n
    for i in range(n):
        m = 0.0
        for a_ in (-1, 0, 1):
            for b_ in (-1, 0, 1):
                arr = buckets.get((gx[i] + a_, gy[i] + b_))
                if not arr:
                    continue
                for j in arr:
                    dz = zs[j] - zs[i]
                    if dz <= 12.0:
                        continue
                    reach = rr[j] + rr[i] + 0.8
                    dd = math.hypot(xs[j] - xs[i], ys[j] - ys[i])
                    if dd >= reach:
                        continue
                    m = max(m, min(1.0, (dz - 12.0) / 24.0)
                            * min(1.0, (reach - dd) / (reach * 0.5)))
        dim[i] = 1 - 0.9 * m

    img = [0.0] * (size * size)
    for i in range(n):
        a = al[i] * dim[i] * gain
        if a <= 0.01 or rr[i] <= 0.3:
            continue
        r = rr[i]
        bx = size / 2.0 + xs[i]
        by = size / 2.0 + ys[i]
        x0 = int(math.floor(bx - r - 1))
        x1_ = int(math.ceil(bx + r + 1))
        y0 = int(math.floor(by - r - 1))
        y1_ = int(math.ceil(by + r + 1))
        if x1_ < 0 or y1_ < 0 or x0 >= size or y0 >= size:
            continue
        for yy in range(max(0, y0), min(size, y1_)):
            dy = yy - by
            o = yy * size
            for xx in range(max(0, x0), min(size, x1_)):
                dx = xx - bx
                cov = min(max(r + 0.5 - math.hypot(dx, dy), 0.0), 1.0) * a
                sub = img[o + xx]
                img[o + xx] = sub + (clum[i] * cov) * (1 - sub)
    return Plane(img, size, size)


# -------------------------------------------------------------------- stills
STILL_QML = """import QtQuick
import NexusHud.V5 1.0

// Generated by nexuslink.hud/v5/tools/knot-iou.py still: the deck frame with one
// Knot on it, so the still is the same 540 px box the deck composes at
// (Tokens.centreX 1280, Tokens.goldenY1 550) and the 540 crop of it is a
// like-for-like reference crop.
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
    """<repo>: this file is <repo>/tools/knot-iou.py."""
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
    ap.add_argument("--offset-px", type=float, default=1.0,
                    help="trace: dilate the silhouette by this many px")
    ap.add_argument("--trace-thr", type=float, default=0.10)
    ap.add_argument("--trace-close", type=int, default=9)
    ap.add_argument("--open-px", type=int, default=7,
                    help="trace: opening kernel, removes the thin ring arcs")
    ap.add_argument("--r-max", type=float, default=276.0)
    ap.add_argument("--scatter-pitch", type=float, default=5.5,
                    help="trace: dot pitch of the scattered cloud, px")
    ap.add_argument("--scatter-offset", type=float, default=28.0,
                    help="trace: max hashed scatter offset, px")
    ap.add_argument("--scatter-seed", type=int, default=17)
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
            mask = trace_mask(ref, thr=args.trace_thr, close=args.trace_close,
                              open_px=args.open_px, r_max=args.r_max)
            args.tube_px = trace_stats(mask)["half_width_ridge_px"]
        tex, info, pred, mask = bake_sdf(
            ref, args.tube_px, args.offset_px, args.out,
            thr=args.trace_thr, close=args.trace_close, open_px=args.open_px,
            r_max=args.r_max, scatter_pitch=args.scatter_pitch,
            scatter_offset=args.scatter_offset, scatter_seed=args.scatter_seed)
        stats = info["trace"]
        print("trace  band %d px, half width %.2f px (ridge) / %.2f px (2A/P), "
              "tip %.1f px, bbox %s"
              % (stats["area_px"], stats["half_width_ridge_px"],
                 stats["half_width_2ap_px"], stats["tip_px"], stats["bbox"]))
        print("       px_per_unit %.2f -> Swarm size %.1f at a 540 Knot; tip at "
              "%.2f units (march bound %.2f)"
              % (info["px_per_unit"], info["swarm_size_540"], info["tip_units"],
                 info["march_bound_units"]))
        ref_band = closing(mask_from_plane(ref, args.thr), args.close)
        print("       predicted silhouette vs reference band: IoU %.4f "
              "(coverage %.4f vs %.4f, offset %.1f px, ring excluded from trace)"
              % (iou(closing(pred, args.close), ref_band),
                 pred.count() / float(pred.w * pred.h),
                 ref_band.count() / float(ref_band.w * ref_band.h),
                 args.offset_px))
        print("       scatter %d dots at %.1f px pitch, hashed offset up to "
              "%.1f px -> texture B channel (assembleProgress 0)"
              % (info["scatter"]["dots"], info["scatter"]["pitch_px"],
                 info["scatter"]["offset_px"]))
        if args.out:
            print("       wrote %s" % args.out)
        if args.mask_out:
            mask_to_image(mask).save(args.mask_out)
            print("       mask %s" % args.mask_out)
        if args.json:
            with open(args.json, "w") as f:
                json.dump(info, f, indent=2)
        return 0

    if args.mode == "still":
        prefix = args.out or os.path.join(tempfile.gettempdir(), "knot-still")
        png = still(args.progress, prefix, args.width, args.height,
                    assembling=not args.rest)
        img = read_lum(png)
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
        img = read_lum(args.render)
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
        w, h = img.w, img.h
        Image.frombytes("L", (w, h), bytes(
            int(min(max(v, 0.0), 1.0) * 255) for v in img.v)).save(args.save)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(res, f, indent=2)
    ok = res["band_iou"] >= args.min_band
    print("VERDICT band_iou %.4f vs bar %.2f -> %s"
          % (res["band_iou"], args.min_band, "PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
