#!/usr/bin/env python3
"""Pack knot3d.json into a point-data texture for the KnotSwarm shader.

Layout: 4 texels per point at linear texel index 4*i+k, row width WIDTH.
  texel0 = (x_hi, x_lo, y_hi)
  texel1 = (y_lo, z_hi, z_lo)      x,y,z 16 bit fixed point over [-512, 512)
  texel2 = (nx, ny, nz) * 127.5 + 127.5
  texel3 = (s * 255, q * 255, class * 255)
RGB, alpha always 255. Nearest sampling, no mipmap.
"""
import json
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(
    os.path.expanduser("~"),
    "NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/comp-r1/s3/src/knot/knot3d.json",
)
WIDTH = 2048
RANGE = 512.0  # units, [-RANGE, RANGE)


def main():
    with open(SRC) as f:
        d = json.load(f)
    n = int(d["n"])
    p = np.asarray(d["p"], dtype=np.float64).reshape(n, 3)
    nr = np.asarray(d["nr"], dtype=np.float64).reshape(n, 3)
    s = np.asarray(d["s"], dtype=np.float64).reshape(n)
    q = np.asarray(d["q"], dtype=np.float64).reshape(n)
    c = np.asarray(d["c"], dtype=np.float64).reshape(n)

    # 16 bit fixed point over [-512, 512)
    def q16(v):
        u = (np.clip(v, -RANGE, RANGE - 1e-6) + RANGE) / (2.0 * RANGE)
        return np.clip(np.round(u * 65535.0), 0, 65535).astype(np.int64)

    X, Y, Z = q16(p[:, 0]), q16(p[:, 1]), q16(p[:, 2])

    def b(v):
        return ((np.clip(v, 0.0, 1.0) * 255.0) + 0.5).astype(np.int64)

    nm = np.clip(np.round(nr * 127.5 + 127.5), 0, 255).astype(np.int64)

    total = 4 * n
    rows = (total + WIDTH - 1) // WIDTH
    buf = np.zeros((rows * WIDTH, 3), dtype=np.uint8)

    idx = np.arange(n)
    t0 = 4 * idx + 0
    t1 = 4 * idx + 1
    t2 = 4 * idx + 2
    t3 = 4 * idx + 3

    buf[t0, 0] = (X >> 8) & 0xFF
    buf[t0, 1] = X & 0xFF
    buf[t0, 2] = (Y >> 8) & 0xFF
    buf[t1, 0] = Y & 0xFF
    buf[t1, 1] = (Z >> 8) & 0xFF
    buf[t1, 2] = Z & 0xFF
    buf[t2, :] = nm
    buf[t3, 0] = b(s)
    buf[t3, 1] = b(q)
    buf[t3, 2] = b(c)

    rgba = np.zeros((rows * WIDTH, 4), dtype=np.uint8)
    rgba[:, :3] = buf
    rgba[:, 3] = 255

    img = Image.frombytes("RGBA", (WIDTH, rows), rgba.tobytes())
    out_png = os.path.join(HERE, "knot-points.png")
    img.convert("RGB").save(out_png, optimize=True)

    meta = {
        "N": n,
        "width": WIDTH,
        "rows": rows,
        "texels": total,
        "range": [-RANGE, RANGE],
        "quant": 65535.0 / (2.0 * RANGE),
        "height": float(d.get("H", 900)),
        "classCounts": {str(int(k)): int(v) for k, v in
                        zip(*np.unique(c.astype(int), return_counts=True))},
        "sRange": [float(s.min()), float(s.max())],
        "qRange": [float(q.min()), float(q.max())],
        "file": out_png,
    }
    with open(os.path.join(HERE, "knot-points.meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print("points", n, "texture", WIDTH, "x", rows, "->", out_png)
    print("classes", meta["classCounts"], "q", meta["qRange"], "s", meta["sRange"])


if __name__ == "__main__":
    main()
