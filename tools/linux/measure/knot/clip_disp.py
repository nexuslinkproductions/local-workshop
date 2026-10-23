#!/usr/bin/env python3
"""clip_disp.py: per frame displacement of the knot in a rendered clip.

    python3 clip_disp.py <clipdir-with-frames.txt> [lag]

Frame differencing only, no optical flow. Consecutive frames of a 24 fps knot
clip differ by a fraction of a pixel, which is below the noise floor of any
correlation on the crisp dot pattern, so the shift is measured over a lag of
<lag> frames (default 12 = 0.5 s) with phase correlation and divided by the lag.
That is the mean per frame displacement over that half second, robust and cheap
(one FFT pair per window, about 0.05 s).

Prints one line per window: t, px per frame, px over the lag, confidence, then
the max over the clip. Multiply px by 540/700 for knot px (knotPx 540 on 700 px).
"""
import math
import sys

import numpy as np
from PIL import Image

KNOT_PX = 540.0


def lum(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]


def phase(a, b):
    A = np.fft.rfft2(a)
    B = np.fft.rfft2(b)
    P = A * np.conj(B)
    m = np.abs(P)
    P = np.where(m > 1e-9, P / np.maximum(m, 1e-9), 0)
    c = np.fft.irfft2(P, s=a.shape)
    i = int(np.argmax(c))
    y, x = divmod(i, c.shape[1])
    peak, sd = c[y, x], c.std() + 1e-12

    def para(m, z, p):
        d = m - 2 * z + p
        return 0.0 if abs(d) < 1e-12 else 0.5 * (m - p) / d

    fx = x + para(c[y, (x - 1) % c.shape[1]], peak, c[y, (x + 1) % c.shape[1]])
    fy = y + para(c[(y - 1) % c.shape[0], x], peak, c[(y + 1) % c.shape[0], x])
    if fx > c.shape[1] / 2:
        fx -= c.shape[1]
    if fy > c.shape[0] / 2:
        fy -= c.shape[0]
    return fx, fy, (peak - c.mean()) / sd


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 64
    d = sys.argv[1]
    lag = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    frames = []
    for line in open(d + "/frames.txt", encoding="ascii"):
        p = line.split()
        if len(p) >= 2:
            frames.append((float(p[0]), p[1]))
    frames.sort()
    if len(frames) <= lag:
        print("clip_disp: need more than %d frames, have %d" % (lag, len(frames)))
        return 1
    k = KNOT_PX / 700.0
    rows = []
    for i in range(0, len(frames) - lag):
        a = lum(frames[i][1])
        b = lum(frames[i + lag][1])
        dx, dy, conf = phase(a, b)
        dt = frames[i + lag][0] - frames[i][0]
        dist = math.hypot(dx, dy)
        # the lag is a number of frames: per frame displacement is dist / lag
        rows.append((frames[i][0], dist / lag, dist, conf, dt))
    print("clip_disp: %s  %d frames, lag %d (%.3f s), knot px factor %.3f"
          % (d, len(frames), lag, rows[0][4], k))
    print("   t       px/frame   px/lag   conf")
    for t, v, dist, conf, dt in rows:
        print("  %7.3f  %9.3f  %8.3f  %5.1f" % (t, v, dist, conf))
    mx = max(r[1] for r in rows)
    im = max(range(len(rows)), key=lambda i: rows[i][1])
    print("clip_disp: max %.3f px/frame (%.3f knot px/frame) at t=%.3f; "
          "mean %.3f px/frame over %d windows"
          % (mx, mx * k, rows[im][0], float(np.mean([r[1] for r in rows])), len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
