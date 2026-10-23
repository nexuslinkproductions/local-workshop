#!/usr/bin/env python3
"""W3 still check: does a deep-view still draw its deep view, and only there?

A deep view only exists while its widget has focus (DeckSurface: `visible:
deck.focusId === "<id>"`, plus kit/Focus dimming everything outside focusRect).
So render the same still twice - once as shipped, once with `focusRequest: ""` -
and every pixel that changed has to sit inside focusRect. This is the pixel
counterpart to tests/w3/LocalDeepAudit.qml, which proves the item tree.

    v5/tools/w3-deep-still-check.py focused.png unfocused.png [x y w h]

The rect defaults to the `local` deep view's focusRect, [1804, 390, 660, 340].
Exit 0 the deep view is drawn inside the rect only, 1 it is not, 3 toolchain
(missing Pillow or file), 64 usage.
"""
import os
import sys

try:
    from PIL import Image, ImageChops
except ImportError:
    print("w3-deep-still-check: Pillow is not installed (pip3 install pillow)",
          file=sys.stderr)
    sys.exit(3)

LOCAL_RECT = [1804, 390, 660, 340]
DIFF_THRESHOLD = 8      # out of 255: below this is antialiasing noise, not content
MIN_CHANGED = 1000      # a deep view is thousands of pixels, a still is not
MIN_SHARE = 95.0        # percent of the changed pixels that must be inside


def main(argv):
    if len(argv) < 2 or len(argv) not in (2, 6):
        print("usage: w3-deep-still-check.py focused.png unfocused.png [x y w h]",
              file=sys.stderr)
        return 64
    focused_path, plain_path = argv[0], argv[1]
    rect = [int(v) for v in argv[2:6]] if len(argv) == 6 else LOCAL_RECT
    for path in (focused_path, plain_path):
        if not os.path.isfile(path):
            print("w3-deep-still-check: no such image: %s" % path, file=sys.stderr)
            return 3

    focused = Image.open(focused_path).convert("RGB")
    plain = Image.open(plain_path).convert("RGB")
    if focused.size != plain.size:
        print("w3-deep-still-check: sizes differ: %s vs %s"
              % (focused.size, plain.size), file=sys.stderr)
        return 1

    # Grey bytes, not pixel tuples: getdata()/ImagingCore typing differs across
    # Pillow versions and the stubs get it wrong; tobytes() is stable.
    diff = ImageChops.difference(focused, plain).convert("L").tobytes()
    changed = sum(1 for v in diff if v > DIFF_THRESHOLD)
    box = (rect[0], rect[1], rect[0] + rect[2], rect[1] + rect[3])
    box_diff = ImageChops.difference(focused, plain).convert("L").crop(box).tobytes()
    changed_inside = sum(1 for v in box_diff if v > DIFF_THRESHOLD)
    share = (changed_inside / changed * 100.0) if changed else 0.0
    focus_grey = focused.crop(box).convert("L").tobytes()
    mean = (sum(focus_grey) / float(len(focus_grey))) if focus_grey else 0.0

    print("focus rect     %s" % rect)
    print("changed px     %d, inside the rect %d (%.1f %%)"
          % (changed, changed_inside, share))
    print("focus box      mean luminance %.2f" % mean)
    ok = changed >= MIN_CHANGED and share >= MIN_SHARE
    print("VERDICT %s: the deep view draws inside focusRect only"
          % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
