#!/usr/bin/env python3
"""render_metrics.py: GPU render the knot at several t and print image metrics.

  python3 render_metrics.py <outdir> <tag> t0 t1 ...

Uses K2/knot-scene-tmpl.qml (TVALUE) with kit/live symlinks in <outdir>, one
v5-shot.sh process per frame (it takes the render lock itself).
Metrics per frame: bright fraction (luma > 0.5), acid share of bright pixels
(g > 0.35, b < 0.30, g - b > 0.20), near white fraction (min channel > 0.9),
hotspot ratio = p99.9 of the 9x9 box mean luma over the knot / its median,
and the same ratio over the 3 deepest crossings (40 px discs).
"""
import os, subprocess, sys, json
import numpy as np
from PIL import Image
from scipy.ndimage import uniform_filter

HERE = os.path.dirname(os.path.abspath(__file__))
SHOT = os.path.join(HERE, "..", "..", "v5-shot.sh")
# Scene template with the literal TVALUE. KNOT_TMPL overrides; the round 3 K2
# scene is kept as the fallback, the round 4 scene lives in work3/B3.
TMPL = os.environ.get("KNOT_TMPL",
                      "/home/nexuslink/.hermes/cache/scratch/hud-live/work3/B3/scene.qml")
if not os.path.exists(TMPL):
    TMPL = "/home/nexuslink/.hermes/cache/scratch/hud-live/work2/K2/knot-scene-tmpl.qml"
KIT = os.environ.get("KNOT_KIT", "/home/nexuslink/hud-wt/v5-live/nexuslink.hud/v5/kit")
LIVE = os.environ.get("KNOT_LIVE", "/home/nexuslink/hud-wt/v5-live/nexuslink.hud/v5/live")


def render(outdir, tag, t):
    os.makedirs(outdir, exist_ok=True)
    for n, p in (("kit", KIT), ("live", LIVE)):
        l = os.path.join(outdir, n)
        if not os.path.exists(l):
            os.symlink(p, l)
    qml = os.path.join(outdir, "%s-t%s.qml" % (tag, t))
    png = os.path.join(outdir, "%s-t%s.png" % (tag, t))
    s = open(TMPL).read().replace("TVALUE", str(t))
    open(qml, "w").write(s)
    r = subprocess.run(["nice", "-n", "19", SHOT, qml, png, "700", "700"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-400:], r.stderr[-400:])
    return png


def metrics(png):
    a = np.asarray(Image.open(png).convert("RGB"), dtype=np.float64) / 255.0
    R, G, B = a[..., 0], a[..., 1], a[..., 2]
    L = 0.299 * R + 0.587 * G + 0.114 * B
    bright = L > 0.5
    acid = bright & (G > 0.35) & (B < 0.30) & ((G - B) > 0.20)
    white = a.min(axis=2) > 0.9
    box = uniform_filter(L, 9)
    m = box > 0.06
    med = float(np.median(box[m])) if m.any() else 1.0
    out = dict(png=png, bright_frac=float(bright.mean()), acid_px=int(acid.sum()),
               acid_share=float(acid.sum() / max(bright.sum(), 1)),
               white_per_1e4=float(white.mean() * 1e4),
               hot_p999_over_median=float(np.percentile(box[m], 99.9) / med),
               box_max_over_median=float(box.max() / med),
               distinct=int(len(np.unique(a.reshape(-1, 3), axis=0))))
    return out


if __name__ == "__main__":
    outdir, tag = sys.argv[1], sys.argv[2]
    res = {}
    for t in sys.argv[3:]:
        png = render(outdir, tag, t)
        res[t] = metrics(png)
        m = res[t]
        print("t=%s bright %.4f acid %.3f%% (%d px) white/1e4 %.2f hot999 %.2f boxmax %.2f distinct %d" % (
            t, m["bright_frac"], 100 * m["acid_share"], m["acid_px"], m["white_per_1e4"],
            m["hot_p999_over_median"], m["box_max_over_median"], m["distinct"]))
    json.dump(res, open(os.path.join(outdir, "%s-render-metrics.json" % tag), "w"), indent=1)
