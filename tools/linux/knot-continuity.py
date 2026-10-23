#!/usr/bin/env python3
"""knot-continuity.py: regression gate for the s10 knot (alive, calm, never deformed).

Input: a frames.txt written by tools/linux/measure/knot/render_times.sh
(one "t path" line per frame, black background, 700 x 700 knot renders; t may
be fractional, step 1 s for the timeline and 0.5 s around each cycle wrap).
Output: a JSON report, a timeline PNG, and exit 1 when a gate fails.

    python3 knot-continuity.py <frames.txt> [--out DIR] [threshold options]

Lit mask = luminance > 20. Gates:
  frozen       share of pixels whose luminance moved by more than 12 between t
               and t + 4 s. Gate: min over all windows >= MIN_WINDOW_CHG.
  blob         lit area / lit area at t = 0. Gate: max <= MAX_AREA_RATIO.
  hold shape   lit-mask IoU vs t = 0 over every frame in the triquetra hold
               (t mod CYC < HOLD_A - 1 s). Gate: min >= MIN_HOLD_IOU (0.8).
  hold alive   per 2 s window inside the hold, two IMAGE PROXIES (a still has
               no dot data, so these are not per dot numbers):
                 dlum  mean |dL| over the union of the two lit masks, 0..255
                       (proxy of the per dot luminance change)
                 xor   |M0 xor M1| / |M0 or M1| (proxy of dot position change:
                       the share of the lit area that moved)
               Gate: min over the hold >= MIN_HOLD_DLUM and >= MIN_HOLD_XOR.
  apex         lit-mask IoU vs t = 0 for frames within 1 s of the morph apex
               (tau = HOLD_A + LEG). Gate: min >= MIN_APEX_IOU (0.5).
  wrap         at each cycle wrap w, the mean |dL| step between w-0.5 and w
               and between w and w+0.5 vs the average of the steps before
               (w-1 to w-0.5) and after (w to w+0.5). Gate: deviation
               <= MAX_WRAP_DEV (0.20). Skipped with a note if frames are absent.

Thresholds are DEFAULTS, labelled in the README next to this file.
Requires numpy and PIL.
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

MIN_WINDOW_CHG = 0.02   # DEFAULT, fraction of frame changed per 4 s (fixed build 0.035)
MAX_AREA_RATIO = 1.25   # DEFAULT, lit area vs triquetra (fixed build 1.07, blob 2.28)
MIN_HOLD_IOU = 0.8      # DEFAULT, brief: the triquetra reads in the hold
MIN_HOLD_DLUM = 2.0     # DEFAULT, 2 s window, mean |dL| over the lit union (0..255)
MIN_HOLD_XOR = 0.02     # DEFAULT, 2 s window, share of the lit area that moved
MIN_APEX_IOU = 0.5      # DEFAULT, brief: the apex never reads deformed
MAX_WRAP_DEV = 0.20     # DEFAULT, brief: no snap at the cycle wrap
CYCLE_S = 48.0          # shader CYC (wall s)
HOLD_A_S = 26.4         # shader HOLD_A (wall s)
LEG_S = 10.8            # shader LEG (wall s)
LIT = 20.0
DIFF = 12.0


def load(frames_txt):
    base = os.path.dirname(os.path.abspath(frames_txt))
    frames = {}
    for line in open(frames_txt):
        if not line.strip():
            continue
        t, p = line.split(" ", 1)
        p = p.strip()
        if not os.path.isabs(p):
            p = os.path.join(base, p)
        frames[round(float(t), 3)] = p
    return frames


def read(path):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    lum = 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]
    return lum, lum > LIT


def dlum_xor(a, b):
    """(mean |dL| over the lit union, xor share) between two (lum, mask) frames."""
    (la, ma), (lb, mb) = a, b
    union = ma | mb
    n = int(union.sum())
    dlum = float(np.abs(lb - la)[union].mean()) if n else 0.0
    return dlum, float((ma ^ mb).sum()) / max(n, 1)


def silhouette(m, k=15):
    """Coarse shape: the lit mask box-blurred over k x k px, > 0.25. Dense dots
    flicker at the threshold-20 edge, so shape is judged on this, not raw pixels."""
    f = np.pad(m.astype(np.float32), k // 2, mode="constant")
    ii = np.zeros((f.shape[0] + 1, f.shape[1] + 1), np.float64)
    ii[1:, 1:] = f.cumsum(0).cumsum(1)
    s = ii[k:, k:] - ii[:-k, k:] - ii[k:, :-k] + ii[:-k, :-k]
    return s / (k * k) > 0.25


def iou(m, ref):
    return float((m & ref).sum()) / max(float((m | ref).sum()), 1.0)


def in_hold(t, cycle, hold_len, pad=1.0):
    return (t % cycle) < hold_len - pad


def timeline(path, ts, ratios, ious, chg, hw, floor):
    """Strips over t: 4 s change, lit-area ratio, hold IoU, 2 s dlum with its floor."""
    W, H = 1000, 640
    img = Image.new("RGB", (W, H), (8, 10, 14))
    px = img.load()
    t_max = float(ts[-1]) if ts else 1.0

    def X(t):
        return int(40 + (W - 60) * t / max(t_max, 1e-6))

    def Y(v, lo, hi, top, bot):
        y = int(bot - (bot - top) * (v - lo) / max(hi - lo, 1e-9))
        return min(max(y, top), bot)

    def line(pts, col):
        for (x0, y0), (x1, y1) in zip(pts[:-1], pts[1:]):
            steps = max(abs(x1 - x0), abs(y1 - y0), 1)
            for s in range(steps + 1):
                px[x0 + (x1 - x0) * s // steps, y0 + (y1 - y0) * s // steps] = col

    line([(X(t), Y(v, 0.0, 0.08, 20, 200)) for t, v in chg], (120, 220, 240))
    line([(X(t), Y(ratios[t], 0.8, 2.4, 230, 410)) for t in ts], (200, 243, 29))
    line([(X(t), Y(ious[t], 0.0, 1.0, 440, 620)) for t in ts], (240, 120, 200))
    if hw:
        line([(X(t), Y(d, 0.0, 12.0, 20, 200)) for t, d, _ in hw], (255, 255, 255))
    fy = Y(floor, 0.0, 12.0, 20, 200)
    for x in range(40, W - 20, 4):
        px[x, fy] = (255, 80, 80)
    img.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("--out", default=None)
    ap.add_argument("--min-window-chg", type=float, default=MIN_WINDOW_CHG)
    ap.add_argument("--max-area-ratio", type=float, default=MAX_AREA_RATIO)
    ap.add_argument("--min-hold-iou", type=float, default=MIN_HOLD_IOU)
    ap.add_argument("--min-hold-dlum", type=float, default=MIN_HOLD_DLUM)
    ap.add_argument("--min-hold-xor", type=float, default=MIN_HOLD_XOR)
    ap.add_argument("--min-apex-iou", type=float, default=MIN_APEX_IOU)
    ap.add_argument("--max-wrap-dev", type=float, default=MAX_WRAP_DEV)
    ap.add_argument("--cycle", type=float, default=CYCLE_S, help="morph cycle, wall s (shader CYC)")
    ap.add_argument("--hold-len", type=float, default=HOLD_A_S, help="triquetra hold per cycle, s (shader HOLD_A)")
    ap.add_argument("--leg", type=float, default=LEG_S, help="morph leg, s (shader LEG)")
    a = ap.parse_args()

    frames = load(a.frames)
    ts = sorted(frames)
    cache = {}

    def fr(t):
        k = round(t, 3)
        if k not in cache:
            cache[k] = read(frames[k])
        return cache[k]

    def has(t):
        return round(t, 3) in frames

    ref_m = fr(ts[0])[1]
    fails, notes = [], []

    # frozen check: 4 s windows over every frame that has a partner 4 s later
    chg = []
    for t in ts:
        if has(t + 4.0):
            chg.append((t, float((np.abs(fr(t + 4.0)[0] - fr(t)[0]) > DIFF).mean())))
    wchg = np.array([c[1] for c in chg]) if chg else np.array([1.0])
    worst_t = chg[int(np.argmin(wchg))][0] if chg else ts[0]
    if wchg.min() < a.min_window_chg:
        fails.append(f"frozen: 4 s window change {wchg.min():.4f} at t={worst_t:.1f} < {a.min_window_chg}")

    # blob check
    area0 = float(ref_m.sum())
    ratios = {t: float(fr(t)[1].sum()) / max(area0, 1.0) for t in ts}
    rmax_t = max(ratios, key=ratios.get)
    if ratios[rmax_t] > a.max_area_ratio:
        fails.append(f"blob: area ratio {ratios[rmax_t]:.2f} at t={rmax_t:.1f} > {a.max_area_ratio}")

    # hold shape and 2 s liveness proxies (shape on the silhouette, see silhouette())
    sil_ref = silhouette(ref_m)
    ious = {t: iou(silhouette(fr(t)[1]), sil_ref) for t in ts}
    hold_ts = [t for t in ts if in_hold(t, a.cycle, a.hold_len)]
    hold_iou = np.array([ious[t] for t in hold_ts]) if hold_ts else np.array([1.0])
    if hold_ts and hold_iou.min() < a.min_hold_iou:
        bad = hold_ts[int(np.argmin(hold_iou))]
        fails.append(f"deformed hold: shape IoU {hold_iou.min():.3f} at t={bad:.1f} < {a.min_hold_iou}")
    hw = []
    for t in hold_ts:
        if has(t + 2.0) and in_hold(t + 2.0, a.cycle, a.hold_len):
            d, x = dlum_xor(fr(t), fr(t + 2.0))
            hw.append((t, d, x))
    if hw:
        dl = np.array([h[1] for h in hw])
        xr = np.array([h[2] for h in hw])
        if dl.min() < a.min_hold_dlum:
            fails.append(f"still hold: 2 s dlum {dl.min():.2f} at t={hw[int(np.argmin(dl))][0]:.1f} < {a.min_hold_dlum}")
        if xr.min() < a.min_hold_xor:
            fails.append(f"still hold: 2 s xor {xr.min():.4f} at t={hw[int(np.argmin(xr))][0]:.1f} < {a.min_hold_xor}")
    else:
        notes.append("no 2 s hold windows: frames missing")

    # apex: the morph peak, shape must stay readable
    apex_tau = a.hold_len + a.leg
    apex_ts = [t for t in ts if abs((t % a.cycle) - apex_tau) <= 1.0]
    apex_iou = np.array([ious[t] for t in apex_ts]) if apex_ts else np.array([1.0])
    if apex_ts and apex_iou.min() < a.min_apex_iou:
        bad = apex_ts[int(np.argmin(apex_iou))]
        fails.append(f"deformed apex: IoU {apex_iou.min():.3f} at t={bad:.1f} < {a.min_apex_iou}")
    if not apex_ts:
        notes.append("no apex frames: frames missing")

    # wrap: local step smoothness across each cycle wrap
    wraps = []
    for k in range(1, int(ts[-1] // a.cycle) + 1):
        w = k * a.cycle
        if not all(has(x) for x in (w - 1.0, w - 0.5, w, w + 0.5)):
            continue
        st = {x: dlum_xor(fr(x), fr(x + 0.5))[0] for x in (w - 1.0, w - 0.5, w)}
        ref = 0.5 * (st[w - 1.0] + st[w])
        dev = abs(st[w - 0.5] - ref) / max(ref, 1e-6)
        wraps.append({"wrap_t": w, "step_at_wrap": st[w - 0.5], "neighbours": ref, "dev": dev})
        if dev > a.max_wrap_dev:
            fails.append(f"snap at wrap t={w:.0f}: step dev {dev:.2f} > {a.max_wrap_dev}")
    if not wraps:
        notes.append("wrap: no 0.5 s frames around a cycle wrap, skipped")

    rep = {
        "frames": len(ts), "t_range": [ts[0], ts[-1]],
        "window_chg_min": float(wchg.min()), "window_chg_min_t": float(worst_t),
        "window_chg_median": float(np.median(wchg)),
        "area_ratio_max": ratios[rmax_t], "area_ratio_max_t": rmax_t,
        "hold_frames": len(hold_ts), "hold_iou_min": float(hold_iou.min()),
        "hold_dlum_min": float(min(h[1] for h in hw)) if hw else None,
        "hold_dlum_median": float(np.median([h[1] for h in hw])) if hw else None,
        "hold_xor_min": float(min(h[2] for h in hw)) if hw else None,
        "hold_xor_median": float(np.median([h[2] for h in hw])) if hw else None,
        "apex_frames": len(apex_ts), "apex_iou_min": float(apex_iou.min()),
        "wraps": wraps,
        "thresholds": {"min_window_chg": a.min_window_chg, "max_area_ratio": a.max_area_ratio,
                       "min_hold_iou": a.min_hold_iou, "min_hold_dlum": a.min_hold_dlum,
                       "min_hold_xor": a.min_hold_xor, "min_apex_iou": a.min_apex_iou,
                       "max_wrap_dev": a.max_wrap_dev},
        "notes": notes, "fails": fails, "verdict": "FAIL" if fails else "PASS",
    }
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        json.dump(rep, open(os.path.join(a.out, "knot-continuity.json"), "w"), indent=1)
        timeline(os.path.join(a.out, "knot-timeline.png"), ts, ratios, ious,
                 [c for c in chg], hw, a.min_hold_dlum)
    print(json.dumps(rep, indent=1))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
