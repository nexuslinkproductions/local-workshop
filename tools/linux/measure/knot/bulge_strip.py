#!/usr/bin/env python3
"""bulge_strip.py: labelled strip of renders with the port's bulge marked.

    python3 bulge_strip.py <frames.txt> <out.png> [t0 t1 t2 ...]

For each chosen frame t (default 0.5 s apart, 4 frames) two panels: the raw
render, and the same render with the port points whose front term C adds more
than 9 px (bulge_px, after the limiter) drawn as magenta rings. Shows where the
bulge is in the render and that it is a different strand position per frame.
"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import knot_port as kp

def main():
    fr = [l.split() for l in open(sys.argv[1]) if l.strip()]
    ts = [float(x) for x in sys.argv[3:]] or [0.0, 0.5, 1.0, 1.5]
    port = kp.KnotPort()
    panels = []
    font = ImageFont.load_default()
    for t in ts:
        path = [p for tt, p in fr if abs(float(tt) - t) < 1e-3][0]
        im = Image.open(path).convert("RGB")
        d = port.sample(t)
        ov = im.copy(); dr = ImageDraw.Draw(ov)
        m = d["bulge_px"] > 9.0
        for x, y in d["pos_full"][m]:
            dr.ellipse((x - 3, y - 3, x + 3, y + 3), outline=(255, 0, 200))
        for img, lab in ((im, "t=%.2f s render" % t), (ov, "t=%.2f s + bulge markers" % t)):
            ImageDraw.Draw(img).text((8, 8), lab, fill=(255, 255, 255), font=font)
        panels.append((im, ov))
    w, h = panels[0][0].size
    # rows = times, 2 columns
    out = Image.new("RGB", (2 * w, len(ts) * h))
    for i, (a, b) in enumerate(panels):
        out.paste(a, (0, i * h)); out.paste(b, (w, i * h))
    out.save(sys.argv[2])
    print(out.size, "->", sys.argv[2])

main()
