#!/usr/bin/env python3
"""Strip colour audit for the full bleed HUD: prove no wallpaper pixels show.

    crop_check.py <png> [--bar 26] [--field 06080a] [--edge 8]
                  [--tol 6] [--share 99.5] [--wallpaper-mad 8]

Checks four strips of the capture against the HUD field colour:

    top     rows bar .. 40            (the 26 px bar itself is excluded)
    left    columns 0 .. edge, rows bar .. h
    right   columns w-edge .. w, rows bar .. h
    bottom  rows h-edge .. h

For every strip it prints the share of pixels within tol per channel of the
field colour, the mean colour, and, when the omarchy wallpaper is readable,
the mean absolute difference to the same strip of the wallpaper scaled to the
capture size. A strip passes only when the field share is at least --share AND
the wallpaper difference is above --wallpaper-mad (a strip that looks like the
wallpaper fails even if it happens to be near the field colour). When the
wallpaper itself is already within --wallpaper-mad of the field colour at that
strip, the wallpaper arm is reported as n/a: no pixel test can separate the
two there, and the hyprctl layer geometry is the proof instead.

Exit 0 when every strip passes, 1 when one fails, 2 on error (bad image).
"""
import argparse
import os
import sys

try:
    import numpy as np
    from PIL import Image
except ImportError as exc:  # pragma: no cover
    sys.stderr.write("crop_check: missing dependency: %s\n" % exc)
    sys.exit(2)

WALLPAPER_LINK = os.path.expanduser("~/.local/state/omarchy/current/background")
RESAMPLE = getattr(getattr(Image, "Resampling", Image), "LANCZOS")


def hex_rgb(text):
    text = text.strip().lstrip("#")
    if len(text) != 6:
        raise ValueError("field must be 6 hex digits, got %r" % text)
    return tuple(int(text[i:i + 2], 16) for i in (0, 2, 4))


def rgb_hex(rgb):
    return "#%02x%02x%02x" % tuple(int(round(c)) for c in rgb)


def strips(w, h, bar, edge, top_end=40):
    out = []
    top_end = min(top_end, h)
    if h > bar and top_end > bar:
        out.append(("top", (0, bar, w, top_end)))
    if w > edge:
        out.append(("left", (0, bar, edge, h)))
        out.append(("right", (w - edge, bar, w, h)))
    if h > bar + edge:
        out.append(("bottom", (0, h - edge, w, h)))
    return out


def load_wallpaper(w, h):
    try:
        real = os.path.realpath(WALLPAPER_LINK)
        if not os.path.isfile(real):
            return None, "wallpaper symlink target missing: %s" % real
        img = Image.open(real).convert("RGB").resize((w, h), Image.LANCZOS)
        return np.asarray(img, dtype=np.float64), None
    except Exception as exc:  # noqa: BLE001 - report, never crash the audit
        return None, "wallpaper unreadable: %s" % exc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--bar", type=int, default=26)
    ap.add_argument("--field", default="06080a")
    ap.add_argument("--edge", type=int, default=8)
    ap.add_argument("--top-end", type=int, default=40,
                    help="last row of the top strip, exclusive (default 40)")
    ap.add_argument("--tol", type=int, default=6)
    ap.add_argument("--share", type=float, default=99.5)
    ap.add_argument("--wallpaper-mad", type=float, default=8.0)
    args = ap.parse_args()

    try:
        field = np.array(hex_rgb(args.field), dtype=np.float64)
    except ValueError as exc:
        sys.stderr.write("crop_check: %s\n" % exc)
        return 2
    try:
        img = Image.open(args.image).convert("RGB")
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write("crop_check: cannot read %s: %s\n" % (args.image, exc))
        return 2
    w, h = img.size
    if w <= 0 or h <= 0:
        sys.stderr.write("crop_check: empty image\n")
        return 2
    arr = np.asarray(img, dtype=np.float64)
    wp, wp_note = load_wallpaper(w, h)

    print("image: %s (%dx%d)" % (args.image, w, h))
    print("field: %s tol=%d pass_share>=%.2f%% wallpaper_mad>%.1f"
          % (rgb_hex(field), args.tol, args.share, args.wallpaper_mad))
    if wp is None:
        print("wallpaper: SKIP (%s)" % wp_note)

    failed = 0
    total = 0
    for name, (x0, y0, x1, y1) in strips(w, h, args.bar, args.edge, args.top_end):
        crop = arr[y0:y1, x0:x1, :]
        if crop.size == 0:
            continue
        total += 1
        diff = np.abs(crop - field.reshape(1, 1, 3))
        ok = np.all(diff <= args.tol, axis=2)
        share = 100.0 * float(ok.mean())
        mean = crop.reshape(-1, 3).mean(axis=0)
        reasons = []
        if share < args.share:
            reasons.append("field share %.2f%% < %.2f%%" % (share, args.share))
        line = "%-6s x=%d..%d y=%d..%d share=%6.2f%% mean=%s" % (
            name, x0, x1, y0, y1, share, rgb_hex(mean))
        if wp is not None:
            wcrop = wp[y0:y1, x0:x1, :]
            mad = float(np.abs(crop - wcrop).mean())
            wp_field = float(np.abs(wcrop - field.reshape(1, 1, 3)).mean())
            line += " wallpaper_mad=%6.2f" % mad
            if wp_field <= args.wallpaper_mad:
                # The wallpaper itself is as close to the field as the pass
                # threshold, so no pixel test can tell the two apart here.
                line += " wp_field_mad=%5.2f wallpaper=n/a" % wp_field
            elif mad <= args.wallpaper_mad:
                reasons.append("matches wallpaper (mad %.2f <= %.1f)"
                               % (mad, args.wallpaper_mad))
            else:
                line += " wp_field_mad=%5.2f" % wp_field
        verdict = "PASS" if not reasons else "FAIL"
        if reasons:
            failed += 1
            line += " %s (%s)" % (verdict, "; ".join(reasons))
        else:
            line += " %s" % verdict
        print(line)

    if total == 0:
        sys.stderr.write("crop_check: no strip fits the image\n")
        return 2
    if failed:
        print("VERDICT: FAIL (%d of %d strips)" % (failed, total))
        return 1
    print("VERDICT: PASS (%d of %d strips)" % (total, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
