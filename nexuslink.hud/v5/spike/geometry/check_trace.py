"""Rasterise the traced centre lines and compare them with the s1 knot crop."""
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = "/Users/marcelspatz/.hermes/profiles/kakashi/cache/scratch"
K = json.load(open(os.path.join(HERE, "knot.json")))
S = 540
img = Image.new("L", (S, S), 0)
dr = ImageDraw.Draw(img)
for ch in K["chains"]:
    pts = [(p[0] + S / 2, S / 2 - p[1]) for p in ch["pts"]]
    hw = [p[2] for p in ch["pts"]]
    if len(pts) < 2 or float(np.median(hw)) < 1.5:
        continue
    for i in range(len(pts) - 1):
        w = max(1, int(round(2 * 0.5 * (hw[i] + hw[i + 1]))))
        dr.line([pts[i], pts[i + 1]], fill=1, width=w)
        for (x, y), h in ((pts[i], hw[i]), (pts[i + 1], hw[i + 1])):
            dr.ellipse([x - h, y - h, x + h, y + h], fill=1)
mine = np.array(img, bool)
lum = np.load(SCRATCH + "/s1-lum.npy")
for t in (0.08, 0.10, 0.12, 0.16, 0.20):
    ref = lum > t
    iou = (mine & ref).sum() / max(1, (mine | ref).sum())
    print("thr %.2f  ref cov %.3f  mine cov %.3f  IoU %.3f" % (t, ref.mean(), mine.mean(), iou))

# dot preview: same pitch as the s1 engine (540 / 144 = 3.75 px), round dots
prev = Image.new("RGB", (S, S), (8, 11, 14))
d2 = ImageDraw.Draw(prev)
step = 3.2
ys, xs = np.mgrid[0:S:1, 0:S:1]
acc = np.zeros((S, S), np.float32)
for y in range(0, S, int(step * 100)):
    pass
# sample the mask at a grid, radius follows local coverage in a 3x3 window
gy = np.arange(step / 2, S, step)
gx = np.arange(step / 2, S, step)
GX, GY = np.meshgrid(gx, gy)
on = mine[np.clip(GY.astype(int), 0, S - 1), np.clip(GX.astype(int), 0, S - 1)]
for x, y in zip(GX[on], GY[on]):
    xi, yi = int(x), int(y)
    cov = mine[max(0, yi - 4):yi + 5, max(0, xi - 4):xi + 5].mean()
    r = step * 0.44 * (0.6 + 0.4 * cov)
    g = (x / S + (1 - y / S)) / 2
    col = (int(0 + 143 * g), int(200 + 16 * g), int(240 + 0 * g)) if g < 0.5 else (int(143 + (96 - 143) * (g - 0.5) * 2), int(216 + (165 - 216) * (g - 0.5) * 2), int(232 + (250 - 232) * (g - 0.5) * 2))
    d2.ellipse([x - r, y - r, x + r, y + r], fill=col)
prev.save(HERE + "/trace-preview.jpg", quality=92)
print("preview", os.path.getsize(HERE + "/trace-preview.jpg"), "bytes, dots", int(on.sum()))
prev.resize((1080, 1080), Image.LANCZOS).save(HERE + "/trace-preview-2x.jpg", quality=90)
