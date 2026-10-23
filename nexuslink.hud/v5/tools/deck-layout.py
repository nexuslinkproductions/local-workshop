#!/usr/bin/env python3
"""I1 layout check: measured widget positions against the golden/thirds guides.

Reads a 2560x1440 deck still and measures where the deck's elements actually
landed, then compares each to the position the layout asks for (and, for the
knot, to the s2 reference crop). The tolerance is 8 px, which is acceptance
criterion 1.

    v5/tools/deck-layout.py nexuslink.hud/v5/stills/i1-deck-rest.png

There is no Pillow on this Mac's python3, so the PNG is converted to BMP with
`sips` and read with numpy: a 24 or 32 bit bottom-up BMP is a header plus rows.

Exit 0 every element inside 8 px, 1 a miss, 3 toolchain, 64 usage, 65 no still.
"""
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np

TOL = 8.0            # px, acceptance criterion 1
W, H = 2560, 1440


def png_to_luma(png_path):
    """sips PNG -> BMP, then numpy -> a float luminance field."""
    tmpdir = tempfile.mkdtemp(prefix="deck-layout.")
    bmp = os.path.join(tmpdir, "still.bmp")
    r = subprocess.run(["sips", "-s", "format", "bmp", png_path, "--out", bmp],
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.isfile(bmp):
        print("deck-layout: sips could not convert the still: %s" % r.stderr.strip(),
              file=sys.stderr)
        sys.exit(3)
    with open(bmp, "rb") as f:
        data = f.read()
    if data[:2] != b"BM":
        print("deck-layout: not a BMP", file=sys.stderr)
        sys.exit(3)
    offset = struct.unpack_from("<I", data, 10)[0]
    header = struct.unpack_from("<I", data, 14)[0]
    if header < 40:
        print("deck-layout: unsupported BMP header %d" % header, file=sys.stderr)
        sys.exit(3)
    w = struct.unpack_from("<i", data, 18)[0]
    h = struct.unpack_from("<i", data, 22)[0]
    bpp = struct.unpack_from("<H", data, 28)[0]
    if bpp not in (24, 32):
        print("deck-layout: unsupported BMP depth %d" % bpp, file=sys.stderr)
        sys.exit(3)
    bottom_up = h > 0
    h = abs(h)
    row_bytes = ((bpp * w + 31) // 32) * 4
    raw = np.frombuffer(data, dtype=np.uint8, count=row_bytes * h, offset=offset)
    rows = raw.reshape(h, row_bytes)[:, : w * (bpp // 8)]
    px = rows.reshape(h, w, bpp // 8).astype(np.float32)
    if bottom_up:
        px = px[::-1]
    b, g, r_ = px[:, :, 0], px[:, :, 1], px[:, :, 2]
    return 0.2126 * r_ + 0.7152 * g + 0.0722 * b


def blob(luma, window, floor=26.0):
    """Bounding box and centroid of pixels above `floor` inside `window`."""
    x0, y0, x1, y1 = window
    sub = luma[y0:y1, x0:x1]
    mask = sub > floor
    if not mask.any():
        return None
    ys, xs = np.nonzero(mask)
    return {
        "bbox": (x0 + xs.min(), y0 + ys.min(), x0 + xs.max() + 1, y0 + ys.max() + 1),
        "centre": (x0 + float(xs.mean()), y0 + float(ys.mean())),
        "pixels": int(mask.sum()),
    }


def check(name, measured, expected, mode):
    """Compare one blob to one expectation. mode: centre | origin | bottom | xcentre."""
    if measured is None:
        print("   %-12s MISSING (nothing above the floor)" % name)
        return False
    x0, y0, x1, y1 = measured["bbox"]
    if mode == "centre":
        got, want = measured["centre"], expected
    elif mode == "origin":
        got, want = (x0, y0), expected
    elif mode == "bottom":
        got, want = (x1, y1), expected
    elif mode == "xcentre":
        got, want = ((x0 + x1) / 2.0, y1), expected
    elif mode == "yonly":
        got, want = ((measured["centre"][1],), (expected[1],))
    else:
        raise ValueError(mode)
    dx = max(abs(got[i] - want[i]) for i in range(len(want)))
    ok = dx <= TOL
    print("   %-12s %-9s measured %-26s expected %-26s delta %5.1f px  %s"
          % (name, mode, tuple(round(v, 1) for v in got),
             tuple(round(v, 1) for v in want), dx, "ok" if ok else "OUT"))
    return ok


def main(argv):
    if len(argv) < 2:
        print("usage: deck-layout.py <still.png>", file=sys.stderr)
        return 64
    if not os.path.isfile(argv[1]):
        print("deck-layout: no such file: %s" % argv[1], file=sys.stderr)
        return 65
    luma = png_to_luma(argv[1])
    if luma.shape != (H, W):
        print("deck-layout: still is %dx%d, expected %dx%d"
              % (luma.shape[1], luma.shape[0], W, H), file=sys.stderr)
        return 65

    print("== layout check %s" % os.path.basename(argv[1]))
    ok = True

    # Guides (Tokens): goldenY1 550, goldenY2 890, thirdX1 853, centreX 1280.
    # Margin band centres: thirdX1/2 = 426.5 and 2560 - 426.5 = 2133.5.
    # Lower band: bars start at lowerY - barHeight - sp2 = 865.7 (barHeight
    # 11.34). A lit dot bar is measured by its ORIGIN, because the lit dots only
    # cover the left share of the bar; the vertical LOCAL stack by its x-centre
    # plus its bottom edge, because the lit dot sits at the bottom.
    lowerBarX = 890 - 11.34 - 13          # first bar y
    checks = [
        # name,      window,                 mode,     expected
        ("knot",     (940, 200, 1620, 940),  "centre", (1280.0, 550.0)),
        ("crew",     (250, 380, 620, 700),   "centre", (426.5, 550.0)),
        ("local",    (2060, 400, 2210, 680), "xcentre", (2133.5, 666.5)),
        ("mac",      (250, 830, 620, 902),   "origin", (310.0, lowerBarX)),
        ("storage",  (1980, 830, 2300, 902), "origin", (2017.0, lowerBarX)),
        ("find",     (1850, 150, 2500, 280), "centre", (2184.0, 214.0)),
        ("clock",    (1000, 60, 1560, 260),  "centre", (1280.0, 144.0)),
        # The launcher is measured by the ROW, not by x: the middle of the arc is
        # not exactly the box centre because the hero tile sits 40 px apart.
        ("launcherM", (1690, 1080, 1840, 1300), "yonly", (0.0, 1192.0)),
    ]
    for name, window, mode, expected in checks:
        ok = check(name, blob(luma, window), expected, mode) and ok

    # The knot's extent, not just its centre: 540 px is the size on the guide and
    # the s2 reference crop is 540x540 at (1010, 280).
    knot = blob(luma, (940, 200, 1620, 940))
    if knot is not None:
        bx0, by0, bx1, by1 = knot["bbox"]
        bw, bh = bx1 - bx0, by1 - by0
        inside = bw <= 540 + 2 * TOL and bh <= 540 + 2 * TOL
        print("   knot extent  %dx%d at (%d,%d), inside the 540 px box  %s"
              % (bw, bh, bx0, by0, "ok" if inside else "OUT"))
        ok = ok and inside

    # The launcher spans the planned box: the outer ring of the first tile at
    # 1135 and of the 1.3x hero at 2407, tiles on the row at 1192.
    arc = blob(luma, (1000, 1040, 2520, 1330))
    if arc is not None:
        ax0, ay0, ax1, ay1 = arc["bbox"]
        inside = abs(ax0 - 1135) <= TOL and abs(ax1 - 2407) <= TOL
        print("   arc extent   x %d..%d (planned 1135..2407)  %s"
              % (ax0, ax1, "ok" if inside else "OUT"))
        ok = ok and inside

    print("   %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
