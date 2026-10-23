#!/usr/bin/env python3
"""W3 still diff: did a component repair change the deck's resting appearance?

The deck composes PulseRing, DotArc and DotBar at focusLevel 0, so the motion
repair must be invisible at rest: the same still rendered before and after has to
come out identical (offscreen RHI readback on the same machine is deterministic;
a few pixels of antialiasing noise are tolerated and counted separately).

    nexuslink.hud/v5/tools/w3-still-diff.py base.png after.png

The bounding box of the changed pixels is printed, so a real difference names
where it is instead of only how much.

Exit 0 identical within tolerance, 1 the still moved, 3 toolchain, 64 usage.
"""
import os
import sys

try:
    from PIL import Image, ImageChops
except ImportError:
    print("w3-still-diff: Pillow is not installed (pip3 install pillow)",
          file=sys.stderr)
    sys.exit(3)

NOISE = 2           # out of 255: below this is readback noise
TOLERATED_SHARE = 0.01   # percent of the frame


def main(argv):
    if len(argv) != 2:
        print("usage: w3-still-diff.py base.png after.png", file=sys.stderr)
        return 64
    for path in argv:
        if not os.path.isfile(path):
            print("w3-still-diff: no such image: %s" % path, file=sys.stderr)
            return 3

    base = Image.open(argv[0]).convert("RGB")
    after = Image.open(argv[1]).convert("RGB")
    if base.size != after.size:
        print("w3-still-diff: sizes differ: %s vs %s" % (base.size, after.size),
              file=sys.stderr)
        return 1

    delta = ImageChops.difference(base, after)
    grey = delta.convert("L")
    pixels = grey.tobytes()
    w, h = grey.size
    total = w * h

    changed = 0
    noisy = 0
    xs, ys = [], []
    for i, v in enumerate(pixels):
        if v > NOISE:
            changed += 1
            xs.append(i % w)
            ys.append(i // w)
        elif v > 0:
            noisy += 1
    share = changed / float(total) * 100.0
    print("image          %dx%d, %d pixels" % (w, h, total))
    print("max channel    %d" % max(pixels))
    print("changed        %d px above noise %.1f (%.4f %% of the frame)"
          % (changed, NOISE, share))
    print("readback noise %d px at or below %.1f and above 0" % (noisy, NOISE))
    if changed:
        print("changed box    x %d..%d  y %d..%d"
              % (min(xs), max(xs), min(ys), max(ys)))
    ok = share <= TOLERATED_SHARE
    print("VERDICT %s: the resting still %s"
          % ("PASS" if ok else "FAIL",
             "is unchanged" if ok else "moved (%.4f %% of the frame)" % share))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
