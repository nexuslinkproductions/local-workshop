#!/usr/bin/env python3
"""lobe_lum.py: luminance per lobe of a knot render (700x700, centre 350,350).

    python3 lobe_lum.py a.png [b.png ...]

Pixels are assigned to the nearest lobe tip angle (34.0, 142.4, 266.4 deg, screen
y down, same frame as the shader). Prints mean luma over lit pixels (luma > 0.04),
lit pixel count, clipped fraction (min channel > 0.9) and the ratio of each lobe
to the mean of the three lobes. Gate: every ratio <= 1.4, clipped fraction ~ 0.
"""
import sys, math
import numpy as np
from PIL import Image

TIPS = [math.radians(a) for a in (34.0, 142.4, 266.4)]

def lobes(png):
    a = np.asarray(Image.open(png).convert("RGB"), dtype=np.float64) / 255.0
    L = 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
    h, w = L.shape
    yy, xx = np.mgrid[0:h, 0:w]
    ang = np.arctan2(yy - h / 2.0, xx - w / 2.0)
    dist = np.stack([np.abs((ang - t + math.pi) % (2 * math.pi) - math.pi) for t in TIPS])
    lobe = dist.argmin(0)
    lit = L > 0.04
    white = a.min(axis=2) > 0.9
    out = []
    for k in range(3):
        m = lit & (lobe == k)
        # energy per lobe: total luma (what the eye integrates) and mean over lit px
        out.append(dict(mean=float(L[m].mean()), p95=float(np.percentile(L[m], 95)), lit=int(m.sum()), total=float(L[m].sum()),
                        white=float(white[m].mean())))
    return out

if __name__ == "__main__":
    for p in sys.argv[1:]:
        o = lobes(p)
        mm = np.mean([x["mean"] for x in o])
        print(p)
        for k, x in enumerate(o):
            print("  lobe %d tip %5.1f  mean luma %.3f (x%.2f)  p95 %.3f  lit px %5d  clipped %.4f"
                  % (k, math.degrees(TIPS[k]), x["mean"], x["mean"] / mm, x["p95"], x["lit"], x["white"]))
