#!/usr/bin/env python3
"""Brightness gate: composed HUD render vs the approved s10 mockup.

Usage:
    brightness-gate.py <render.png> [--ref <s10-rest.png>] [--spacing <s10-spacing.json>]
                       [--json <out.json>]

Render the composed scene with tools/linux/brightness/compose.qml (v5-shot.sh).

Exit 0 when every gated metric is within its tolerance, 1 otherwise, 2 on bad input.

Gated metrics (all luminance 0..255, Rec. 601 L from RGB):
  room_mean    mean over the room-only mask (knot and every widget box masked out)
  widget_p95   95th percentile over the union of the widget boxes (text and dots)
  frame_mean   mean over the composed frame (unwired boxes excluded)
  frame_p95    95th percentile over the composed frame
  frame_p99    99th percentile over the composed frame
Each render value is compared with the reference value as a ratio. A metric
passes when |render / ref - 1| <= its tolerance.

Calibration (--live <capture.png>): compares the harness render with a live grim
capture of the same output (top LIVE_BAR_PX rows dropped from both, the omarchy bar is
not part of the harness). Mean and p95 within 5 percent, p99 within 10 percent.
A capture of another size is resized with LANCZOS to the render size first.
Calibrate only with a render of the same tree that the capture came from (the c7d4b62
live P1 tree). A later tree is a different look: its widgets changed, so it fails
calibration by design and is judged by the s10 metrics above.

Information only (not gated): per-widget p95 and mean for each box in the spacing file.
Region geometry comes from s10-spacing.json (boxes and knot), so the gate follows the
mockup, not hand-typed rectangles.
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

# ---- tolerances (defaults, fraction of the reference value) ----
ROOM_TOL = 0.10
WIDGET_TOL = 0.10
FRAME_MEAN_TOL = 0.10
FRAME_P95_TOL = 0.10
FRAME_P99_TOL = 0.10

# ---- live calibration ----
# The omarchy bar draws the top rows of a live capture; the harness never draws it.
LIVE_BAR_PX = 26
CAL_TOL = {"mean": 0.05, "p95": 0.05, "p99": 0.10}

# ---- region geometry ----
WIDGET_PAD_PX = 12      # widget boxes grow by this much before they are masked out of the room
KNOT_PAD_PX = 40        # knot box grows by this much before it is masked out of the room
PCT_MID = 95            # percentile for text and frame "bright" metric
PCT_HI = 99             # percentile for the frame highlight metric

# Widgets that DeckView instantiates at this commit. Boxes not listed here are not on
# screen yet (AGENTS, NOW PLAYING, TODAY, the bottom corner marks), so they are excluded
# from widget_p95 and reported as NOT COMPOSED. Extend the list when a widget is wired.
WIRED_WIDGETS = ("crew", "mac", "find", "local", "storage", "clock", "dates", "launcher")

# ---- luminance weights (Rec. 601) ----
LUMA_R, LUMA_G, LUMA_B = 0.299, 0.587, 0.114

DEFAULT_REF = os.path.expanduser(
    "~/NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/comp-r1/s10/s10-rest.png")
DEFAULT_SPACING = os.path.expanduser(
    "~/NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/comp-r1/s10/s10-spacing.json")


def luma(path, size=None):
    im = Image.open(path).convert("RGB")
    if size is not None and im.size != size:
        im = im.resize(size, Image.Resampling.LANCZOS)
    rgb = np.asarray(im).astype(np.float64)
    return LUMA_R * rgb[..., 0] + LUMA_G * rgb[..., 1] + LUMA_B * rgb[..., 2]


def box_mask(shape, l, t, r, b, pad):
    h, w = shape
    m = np.zeros(shape, dtype=bool)
    x0, y0 = max(0, int(np.floor(l - pad))), max(0, int(np.floor(t - pad)))
    x1, y1 = min(w, int(np.ceil(r + pad))), min(h, int(np.ceil(b + pad)))
    m[y0:y1, x0:x1] = True
    return m


def regions(spacing, shape):
    boxes = spacing["boxes"]
    k = spacing["knot"]
    kl, kt, kr, kb = k["box"]
    knot = box_mask(shape, kl, kt, kr, kb, KNOT_PAD_PX)
    widget = np.zeros(shape, dtype=bool)   # wired widgets only, used by widget_p95
    unwired = np.zeros(shape, dtype=bool)  # boxes not on screen yet, kept out of frame metrics
    room_block = knot.copy()               # every box (wired or not) is kept out of the room
    per_box = {}
    for name, b in boxes.items():
        m = box_mask(shape, b["l"], b["t"], b["r"], b["b"], 0)
        per_box[name] = m
        padded = box_mask(shape, b["l"], b["t"], b["r"], b["b"], WIDGET_PAD_PX)
        room_block |= padded
        if name in WIRED_WIDGETS:
            widget |= padded
        else:
            unwired |= padded
    room = ~room_block
    frame = ~unwired                       # frame metrics: everything that is composed
    return room, widget, frame, per_box


def compare(render, ref, spacing):
    if render.shape != ref.shape:
        raise ValueError(f"shape mismatch render={render.shape} ref={ref.shape}")
    room, widget, frame, per_box = regions(spacing, ref.shape)
    rows = {}

    def add(name, r, f, tol):
        ratio = (float(r) / float(f)) if f else float("inf")
        rows[name] = {"render": round(float(r), 2), "ref": round(float(f), 2),
                      "ratio": round(ratio, 4), "tol": tol,
                      "pass": bool(abs(ratio - 1.0) <= tol)}

    add("room_mean", render[room].mean(), ref[room].mean(), ROOM_TOL)
    add(f"widget_p{PCT_MID}", np.percentile(render[widget], PCT_MID),
        np.percentile(ref[widget], PCT_MID), WIDGET_TOL)
    add("frame_mean", render[frame].mean(), ref[frame].mean(), FRAME_MEAN_TOL)
    add(f"frame_p{PCT_MID}", np.percentile(render[frame], PCT_MID),
        np.percentile(ref[frame], PCT_MID), FRAME_P95_TOL)
    add(f"frame_p{PCT_HI}", np.percentile(render[frame], PCT_HI),
        np.percentile(ref[frame], PCT_HI), FRAME_P99_TOL)

    info = {}
    for name, m in per_box.items():
        info[name] = {
            "p95_render": round(float(np.percentile(render[m], PCT_MID)), 1),
            "p95_ref": round(float(np.percentile(ref[m], PCT_MID)), 1),
            "mean_render": round(float(render[m].mean()), 1),
            "mean_ref": round(float(ref[m].mean()), 1),
        }
    return rows, info


def calibrate(render, live):
    """Harness render vs a live capture of the same output, bar rows dropped from both.

    Returns rows keyed mean/p95/p99 with ratio = harness / live. A factor for the harness
    is 1 / ratio (apply it as a gain only when a metric is outside its CAL_TOL).
    """
    keep = np.ones(render.shape, dtype=bool)
    keep[:LIVE_BAR_PX, :] = False
    rows = {}
    stat = {"mean": np.mean, "p95": lambda v: np.percentile(v, PCT_MID),
            "p99": lambda v: np.percentile(v, PCT_HI)}
    for name, fn in stat.items():
        r, l = float(fn(render[keep])), float(fn(live[keep]))
        ratio = (r / l) if l else float("inf")
        rows[name] = {"render": round(r, 2), "live": round(l, 2), "ratio": round(ratio, 4),
                      "factor": round(1.0 / ratio, 4) if ratio else None,
                      "tol": CAL_TOL[name], "pass": bool(abs(ratio - 1.0) <= CAL_TOL[name])}
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description="Brightness gate: composed HUD render vs s10.")
    ap.add_argument("render")
    ap.add_argument("--ref", default=DEFAULT_REF)
    ap.add_argument("--spacing", default=DEFAULT_SPACING)
    ap.add_argument("--live", default=None, help="live grim capture of the same output (calibration)")
    ap.add_argument("--json", default=None, help="write the full result here")
    a = ap.parse_args(argv)
    try:
        spacing = json.load(open(a.spacing))
        ref = luma(a.ref)
        render = luma(a.render)
        live = luma(a.live, size=(render.shape[1], render.shape[0])) if a.live else None
    except (OSError, ValueError, KeyError) as e:
        print(f"brightness-gate: bad input: {e}", file=sys.stderr)
        return 2
    rows, info = compare(render, ref, spacing)
    ok = all(r["pass"] for r in rows.values())
    for name, r in rows.items():
        print(f"{name:12s} render={r['render']:7.2f} ref={r['ref']:7.2f} "
              f"ratio={r['ratio']:.3f} tol=+/-{int(r['tol'] * 100)}% "
              f"{'PASS' if r['pass'] else 'FAIL'}")
    for name, r in info.items():
        tag = "" if name in WIRED_WIDGETS else "  NOT COMPOSED (excluded)"
        print(f"  info {name:12s} p95 {r['p95_render']:6.1f} vs {r['p95_ref']:6.1f}  "
              f"mean {r['mean_render']:6.1f} vs {r['mean_ref']:6.1f}{tag}")
    print("BRIGHTNESS-GATE " + ("PASS" if ok else "FAIL"))
    cal = None
    if live is not None:
        cal = calibrate(render, live)
        cal_ok = all(r["pass"] for r in cal.values())
        for name, r in cal.items():
            print(f"  calib {name:5s} harness={r['render']:7.2f} live={r['live']:7.2f} "
                  f"ratio={r['ratio']:.3f} factor={r['factor']} tol=+/-{int(r['tol'] * 100)}% "
                  f"{'PASS' if r['pass'] else 'FAIL'}")
        print("CALIBRATION " + ("PASS" if cal_ok else "FAIL"))
        ok = ok and cal_ok
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"pass": ok, "metrics": rows, "boxes": info, "calibration": cal}, f, indent=2)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
