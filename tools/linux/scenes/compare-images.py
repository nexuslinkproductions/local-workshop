#!/usr/bin/env python3
"""Compare deck B renders with the scout images of the same name (PIL).

Usage: compare-images.py NEW_DIR [SCOUT_DIR]

SCOUT_DIR defaults to ~/.hermes/cache/scratch/deck-b/render. For every
NEW_DIR/*.png with a file of the same name in SCOUT_DIR, prints:
  mean  = mean absolute difference over all R, G, B values (0-255)
  pct8  = percent of pixels whose largest channel difference is above 8
"""
import os
import pathlib
import sys

from PIL import Image, ImageChops, ImageStat


def compare(a_path, b_path):
    a = Image.open(a_path).convert("RGB")
    b = Image.open(b_path).convert("RGB")
    if a.size != b.size:
        return None, None, "size %s vs %s" % (a.size, b.size)
    d = ImageChops.difference(a, b)
    mean = sum(ImageStat.Stat(d).mean) / 3.0
    r, g, bl = d.split()
    peak = ImageChops.lighter(ImageChops.lighter(r, g), bl)
    hist = peak.histogram()
    total = a.size[0] * a.size[1]
    over = sum(hist[9:])
    return mean, 100.0 * over / total, "%dx%d" % a.size


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    new_dir = pathlib.Path(argv[1])
    scout = pathlib.Path(argv[2]) if len(argv) > 2 else pathlib.Path(
        os.path.expanduser("~/.hermes/cache/scratch/deck-b/render"))
    compared = 0
    print("%-30s %9s %9s  %s" % ("image", "mean", "pct>8", "note"))
    for p in sorted(new_dir.glob("*.png")):
        q = scout / p.name
        if not q.exists():
            print("%-30s %9s %9s  no scout image" % (p.name, "-", "-"))
            continue
        mean, pct, note = compare(p, q)
        if mean is None:
            print("%-30s %9s %9s  %s" % (p.name, "-", "-", note))
            continue
        compared += 1
        print("%-30s %9.3f %8.3f%%  %s" % (p.name, mean, pct, note))
    if compared == 0:
        print("compare-images: no pairs compared")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
