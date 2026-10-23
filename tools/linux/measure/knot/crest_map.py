#!/usr/bin/env python3
"""crest_map.py: where is the bulge crest in the GPU render, frame by frame.

    python3 crest_map.py <frames.txt> <out.png>

For every frame the render luminance is sampled (5x5 mean) at the port's projected
ribbon points, averaged in 64 arc bins (u), and the per-bin time mean is removed.
A travelling crest shows as a diagonal bright stripe (rows = time, columns = u).
Prints, per frame, the arc position of the strongest crest bin in the render and the
position of the front term C in the port, plus the correlation between the two maps.
"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import knot_port as kp

NB = 64

def main():
    fr = [l.split() for l in open(sys.argv[1]) if l.strip()]
    port = kp.KnotPort()
    rib = port.ribbon
    bi = np.floor(port.u * NB).astype(int)
    lum, gmap, ts = [], [], []
    for t, path in fr:
        t = float(t)
        a = np.asarray(Image.open(path).convert("RGB"), float) / 255.0
        L = 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
        d = port.sample(t)
        pos = d["pos_full"]
        v = np.zeros(port.n)
        for i, (x, y) in enumerate(pos):
            xi, yi = int(round(x)), int(round(y))
            v[i] = L[max(yi - 2, 0):yi + 3, max(xi - 2, 0):xi + 3].mean()
        lum.append(np.array([v[rib & (bi == b)].mean() for b in range(NB)]))
        gmap.append(np.array([d["front"][rib & (bi == b)].mean() for b in range(NB)]))
        ts.append(t)
    lum = np.array(lum); gmap = np.array(gmap)
    ex = lum - lum.mean(axis=0, keepdims=True)
    gx = gmap - gmap.mean(axis=0, keepdims=True)
    cc = float(np.corrcoef(ex.ravel(), gx.ravel())[0, 1])
    print("render crest vs port front map: corr %.3f over %d frames x %d bins" % (cc, len(ts), NB))
    for t, row, g in zip(ts, ex, gmap):
        print("t=%.2f render crest bin %2d (u %.3f)  port front peak bin %2d" % (
            t, int(row.argmax()), (row.argmax() + .5) / NB, int(g.argmax())))
    cell = 12
    H = len(ts) * cell * 2 + 30
    img = Image.new("RGB", (NB * cell + 60, H), (6, 8, 10))
    dr = ImageDraw.Draw(img); f = ImageFont.load_default()
    for k, (m, name) in enumerate(((ex, "render"), (gx, "port"))):
        mm = np.abs(m).max()
        for i in range(len(ts)):
            for b in range(NB):
                x = m[i, b] / mm
                c = (int(255 * max(x, 0)), int(200 * max(x, 0)), int(255 * max(-x, 0)))
                dr.rectangle((60 + b * cell, 24 + (k * len(ts) + i) * cell, 60 + (b + 1) * cell - 1, 24 + (k * len(ts) + i + 1) * cell - 1), fill=c)
            dr.text((4, 24 + (k * len(ts) + i) * cell), "%s %.2f" % (name, ts[i]), fill=(200, 215, 225), font=f)
    dr.text((60, 6), "arc position u 0..1 (columns), time (rows): render luminance excess, then port front g", fill=(255, 255, 255), font=f)
    img.save(sys.argv[2]); print("->", sys.argv[2])

main()
