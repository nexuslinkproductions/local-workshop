#!/usr/bin/env python3
"""contact_sheet.py: 4x3 contact sheet of a rendered knot sequence.

    contact_sheet.py <framesdir-or-frames.txt> <out.png> [cols] [rows]

Reads frames.txt ("t path" per line, written by render_seq.sh), falls back to
frame-NNNN.png in the directory (t = NNNN / 24). Each cell is a frame scaled
to fit, the frame time written under it in Satoshi if it is loadable, else in
the PIL default font. All text ASCII, 4x3 by default.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

FPS = 24.0
FONT_CANDIDATES = [
    "/home/nexuslink/hud-wt/v5-live/nexuslink.hud/v5/fonts/Satoshi-Medium.ttf",
    "/home/nexuslink/hud-wt/v5-live/nexuslink.hud/v5/fonts/Satoshi-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
]


def load_font(size):
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size), os.path.basename(p)
            except Exception:
                pass
    return ImageFont.load_default(), "pil-default"


def frames_from(src):
    out = []
    if os.path.isdir(src):
        for fn in sorted(os.listdir(src)):
            if fn.startswith("frame-") and fn.endswith(".png"):
                idx = int(fn[6:10])
                out.append((idx / FPS, os.path.join(src, fn)))
    else:
        with open(src, encoding="ascii") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    out.append((float(parts[0]), parts[1]))
    return sorted(out)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 64
    src, out = sys.argv[1], sys.argv[2]
    cols = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    rows = int(sys.argv[4]) if len(sys.argv) > 4 else 3
    frames = frames_from(src)
    if not frames:
        print("contact_sheet: no frames found in", src)
        return 1
    need = cols * rows
    if len(frames) > need:
        frames = frames[:need]
    cell = 320
    gap = 10
    label_h = 26
    W = cols * cell + (cols + 1) * gap
    H = rows * (cell + label_h) + (rows + 1) * gap
    sheet = Image.new("RGB", (W, H), (6, 8, 10))
    draw = ImageDraw.Draw(sheet)
    font, fname = load_font(16)
    for i, (t, path) in enumerate(frames):
        r, c = divmod(i, cols)
        x = gap + c * (cell + gap)
        y = gap + r * (cell + label_h + gap)
        try:
            im = Image.open(path).convert("RGB")
        except Exception as e:
            print("contact_sheet: cannot read", path, e)
            continue
        im.thumbnail((cell, cell), Image.LANCZOS)
        sheet.paste(im, (x + (cell - im.width) // 2,
                         y + (cell - im.height) // 2))
        txt = f"t = {t:5.2f} s"
        draw.text((x + 2, y + cell + 4), txt, fill=(200, 215, 225), font=font)
    sheet.save(out)
    print(f"contact_sheet: {len(frames)} frames, {cols}x{rows}, "
          f"{W}x{H} px, font {fname} -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
