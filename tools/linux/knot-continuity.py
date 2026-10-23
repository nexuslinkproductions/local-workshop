#!/usr/bin/env python3
"""knot-continuity.py: regression gate for the s10 knot (no freeze, no blob hold).

Input: a frames.txt written by tools/linux/measure/knot/render_times.sh
(one "t path" line per frame, black background, 700 x 700 knot renders at a
fixed step; default step 2 s, t = 0..140). Output: a JSON report, a timeline PNG,
and exit 1 when a gate fails.

    python3 knot-continuity.py <frames.txt> [--out DIR] [--min-window-chg X]
                               [--max-area-ratio Y]

Metrics (all on the rendered pixels, luminance > 20 counts as lit):
  window_chg   share of pixels whose luminance moved by more than 12 between
               the frame at t and the frame at t + 4 s. Unit: fraction of the
               700 x 700 frame, not px. It is 0 for a frozen knot. Gate: the
               minimum over all 4 s windows must be >= MIN_WINDOW_CHG.
  area_ratio   lit area divided by the lit area at t = 0 (the triquetra). A
               blob or bloomed hold makes it jump. Gate: max over frames must
               be <= MAX_AREA_RATIO.
  iou_ref      overlap of the lit mask with the t = 0 mask (shape, 1.0 at rest).
               Reported, not gated: it drops during the legal morph.

Defaults were measured on the fixed build (ws/v5-s10-fix-knot, step 2 s):
window_chg min 0.035, area_ratio max 1.07. The bloomed form-2 hold of
ws/v5-s10 (a743970) measured area_ratio 2.28, and the live c7d4b62 window
minimum was 0.040. Thresholds sit between the fixed build and the failures.
Requires numpy and PIL.
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

MIN_WINDOW_CHG = 0.02   # fraction of frame changed per 4 s; fixed build 0.035
MAX_AREA_RATIO = 1.25   # lit area vs triquetra; fixed build 1.07, blob 2.28
MIN_HOLD_IOU = 0.5      # shape IoU vs t = 0 inside the triquetra hold (no deformed hold)
CYCLE_S = 48.0          # shader CYC (wall s)
HOLD_A_S = 26.4         # shader HOLD_A (wall s)
LIT = 20.0
DIFF = 12.0


def load(frames_txt):
    rows = []
    base = os.path.dirname(os.path.abspath(frames_txt))
    for line in open(frames_txt):
        if not line.strip():
            continue
        t, p = line.split(" ", 1)
        p = p.strip()
        if not os.path.isabs(p):
            p = os.path.join(base, p)
        rows.append((float(t), p))
    rows.sort()
    return rows


def luminance(path):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def analyse(frames_txt, step_s=2.0):
    rows = load(frames_txt)
    ts = np.array([t for t, _ in rows])
    lum = [luminance(p) for _, p in rows]
    lit = [l > LIT for l in lum]
    area = np.array([m.sum() for m in lit], float)
    ref = lit[0]
    iou = np.array([(m & ref).sum() / max((m | ref).sum(), 1) for m in lit])
    k = max(1, int(round(4.0 / step_s)))
    windows = []
    for i in range(len(lum) - k):
        chg = float((np.abs(lum[i + k] - lum[i]) > DIFF).mean())
        windows.append((float(ts[i]), chg))
    return ts, area, area / max(area[0], 1.0), iou, windows


def timeline(path, ts, ratio, windows):
    W, H = 900, 420
    img = Image.new("RGB", (W, H), (8, 10, 14))
    px = img.load()
    t_max = float(ts[-1]) if len(ts) else 1.0

    def xy(t, v, lo, hi, top, bot):
        x = int(40 + (W - 60) * t / max(t_max, 1e-6))
        y = int(bot - (bot - top) * (v - lo) / max(hi - lo, 1e-9))
        return x, min(max(y, top), bot)

    for series, lo, hi, top, bot, col in [
        ([w[1] for w in windows], 0.0, 0.08, 20, 190, (120, 220, 240)),
        (list(ratio), 0.8, 2.4, 230, 400, (200, 243, 29)),
    ]:
        tt = [w[0] for w in windows] if series is not None and len(series) == len(windows) else list(ts)
        for a, b in zip(range(len(series) - 1), range(1, len(series))):
            x0, y0 = xy(tt[a], series[a], lo, hi, top, bot)
            x1, y1 = xy(tt[b], series[b], lo, hi, top, bot)
            steps = max(abs(x1 - x0), abs(y1 - y0), 1)
            for s in range(steps + 1):
                px[x0 + (x1 - x0) * s // steps, y0 + (y1 - y0) * s // steps] = col
    img.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("--out", default=None)
    ap.add_argument("--step", type=float, default=2.0)
    ap.add_argument("--min-window-chg", type=float, default=MIN_WINDOW_CHG)
    ap.add_argument("--max-area-ratio", type=float, default=MAX_AREA_RATIO)
    ap.add_argument("--min-hold-iou", type=float, default=MIN_HOLD_IOU)
    ap.add_argument("--cycle", type=float, default=CYCLE_S, help="morph cycle, wall s (shader CYC)")
    ap.add_argument("--hold-len", type=float, default=HOLD_A_S, help="triquetra hold per cycle, s (shader HOLD_A)")
    a = ap.parse_args()
    ts, area, ratio, iou, windows = analyse(a.frames, a.step)
    wchg = np.array([w[1] for w in windows])
    worst = int(np.argmin(wchg))
    fails = []
    if wchg.min() < a.min_window_chg:
        fails.append(f"frozen: 4 s window change {wchg.min():.4f} at t={windows[worst][0]:.1f} < {a.min_window_chg}")
    if ratio.max() > a.max_area_ratio:
        fails.append(f"blob: area ratio {ratio.max():.2f} at t={ts[int(np.argmax(ratio))]:.1f} > {a.max_area_ratio}")
    # deformed hold: inside the triquetra hold (not the morph legs) the shape must still match t = 0
    hold = [i for i, t in enumerate(ts) if (t % a.cycle) < a.hold_len - 1.0]
    hold_iou = iou[hold] if hold else np.array([1.0])
    if hold and hold_iou.min() < a.min_hold_iou:
        bad = hold[int(np.argmin(hold_iou))]
        fails.append(f"deformed hold: shape IoU {hold_iou.min():.3f} at t={ts[bad]:.1f} < {a.min_hold_iou}")
    rep = {
        "frames": len(ts), "t_range": [float(ts[0]), float(ts[-1])],
        "window_chg_min": float(wchg.min()), "window_chg_min_t": windows[worst][0],
        "window_chg_p05": float(np.percentile(wchg, 5)), "window_chg_median": float(np.median(wchg)),
        "area_ratio_max": float(ratio.max()), "area_ratio_min": float(ratio.min()),
        "iou_ref_min": float(iou.min()), "thresholds": {"min_window_chg": a.min_window_chg,
                                                         "max_area_ratio": a.max_area_ratio},
        "fails": fails, "verdict": "FAIL" if fails else "PASS",
    }
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        json.dump(rep, open(os.path.join(a.out, "knot-continuity.json"), "w"), indent=1)
        timeline(os.path.join(a.out, "knot-timeline.png"), ts, ratio, windows)
    print(json.dumps(rep, indent=1))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
