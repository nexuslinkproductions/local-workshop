#!/usr/bin/env python3
"""grounding-score.py — the ONE crop-and-zoom grounding scorer.

Used by bench/grounding-test.sh (live run) and bench/grounding-rescore.py (re-score an
audit dump offline). One implementation on purpose: the first version counted hits over
ALL targets while by-class only listed targets that produced a parseable answer, so the
two numbers disagreed (Qwen topstrip read hits=8/16 with cover=4/16).

Rules now enforced (see selftest()):
  * covered = the target box INTERSECTS the crop (the model had a chance to see it).
  * hits are counted ONLY over covered targets; the headline is hits/covered.
  * by-class lists EVERY target in the set; a target that is out of crop, unparsed or
    errored is a miss with a reason, so by-class always sums to the full target count.
  * the coordinate convention (abs pixels of the crop vs 0-1000 grid) is picked once per
    strategy by majority among COVERED targets.
"""
W, H = 1920, 1080


def parse_targets(path):
    """<label>\\t<x1>,<y1>,<x2>,<y2>[\\t<class>] -> [(label, (x1,y1,x2,y2), class)]"""
    out = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        out.append((f[0], tuple(int(v) for v in f[1].split(",")), f[2] if len(f) > 2 else "?"))
    return out


def region_for(strategy, box, w=W, h=H):
    """-> (rx, ry, rw, rh, scale): crop region in full-screen px + upscale factor."""
    if strategy == "topstrip":
        return (0, 0, 1920, 270, 2.0)
    if strategy == "quadrant":
        x1, y1, x2, y2 = box
        cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
        qx = 0 if cx < w // 2 else w // 2
        qy = 0 if cy < h // 2 else h // 2
        return (qx, qy, w // 2, h // 2, 2.0)
    return (0, 0, w, h, 1.0)


def map_back(px, py, rx, ry, rw, rh, scale, conv):
    """A model answer on a (possibly 2x-upscaled) crop -> full-screen px.
    abs  = pixel in the upscaled crop image;  norm = 0-1000 grid over the crop."""
    if conv == "abs":
        return px / scale + rx, py / scale + ry
    return px / 1000.0 * rw + rx, py / 1000.0 * rh + ry


def score(strategy, targets, answers):
    """answers: {label: (raw_reply, (px,py) or None, error_or_None)}.
    -> dict(hits, covered, n, conv, hits_abs, hits_norm, by_class, detail, per)"""
    per = []
    for lab, (x1, y1, x2, y2), cls in targets:
        rx, ry, rw, rh, scale = region_for(strategy, (x1, y1, x2, y2))
        # covered = the target box overlaps the crop at all
        covered = not (x2 < rx or x1 > rx + rw or y2 < ry or y1 > ry + rh)
        raw, pt, err = answers.get(lab, (None, None, "missing"))
        if err or pt is None:
            per.append(dict(lab=lab, cls=cls, covered=covered, abs=False, norm=False,
                            ax=None, ay=None, nx=None, ny=None, why=err or "nojson"))
            continue
        ax, ay = map_back(pt[0], pt[1], rx, ry, rw, rh, scale, "abs")
        nx, ny = map_back(pt[0], pt[1], rx, ry, rw, rh, scale, "norm")
        per.append(dict(lab=lab, cls=cls, covered=covered,
                        abs=(x1 <= ax <= x2 and y1 <= ay <= y2),
                        norm=(x1 <= nx <= x2 and y1 <= ny <= y2),
                        ax=ax, ay=ay, nx=nx, ny=ny, why=None))
    cov = [p for p in per if p["covered"]]
    hits_abs = sum(1 for p in cov if p["abs"])
    hits_norm = sum(1 for p in cov if p["norm"])
    conv = "norm" if hits_norm > hits_abs else "abs"
    hits = hits_norm if conv == "norm" else hits_abs
    classes = {}
    for p in per:                       # EVERY target, misses included
        c = classes.setdefault(p["cls"], [0, 0])
        c[0] += 1
        c[1] += int(p["covered"] and p[conv])
    detail = []
    for p in per:
        if not p["covered"]:
            detail.append(f"{p['lab']}:out-of-crop")
            continue
        if p["ax"] is None:
            detail.append(f"{p['lab']}:{p['why'] or 'miss'}")
            continue
        px, py = (p["nx"], p["ny"]) if conv == "norm" else (p["ax"], p["ay"])
        if p[conv]:
            detail.append(f"{p['lab']}:({px:.0f},{py:.0f})HIT/{conv}")
        else:
            detail.append(f"{p['lab']}:({px:.0f},{py:.0f})miss/{conv}")
    return dict(hits=hits, covered=len(cov), n=len(per), conv=conv, hits_abs=hits_abs,
                hits_norm=hits_norm, by_class=classes, detail=detail, per=per)


def summary(strategy, r, extra=""):
    """-> (tool_call_pass, notes). The ONE formatter: live run and offline rescore both use it."""
    cls = ", ".join(f"{k} {v[1]}/{v[0]}" for k, v in sorted(r["by_class"].items()))
    head = (f"grounding-{strategy} hits={r['hits']}/{r['covered']} covered (of {r['n']}) "
            f"conv={r['conv']} (abs={r['hits_abs']} norm={r['hits_norm']}) by-class[{cls}]")
    note = " ".join(x for x in (head, extra) if x) + " | " + "; ".join(r["detail"])
    return f"{r['hits']}/{r['covered']}", note[:900]


def selftest():
    # map-back + region picks
    for rx, ry, rw, rh, s in [(0, 0, 1920, 270, 2.0), (960, 0, 960, 540, 2.0),
                              (0, 540, 960, 540, 2.0), (960, 540, 960, 540, 2.0),
                              (0, 0, 1920, 1080, 1.0)]:
        assert map_back(rw * s / 2, rh * s / 2, rx, ry, rw, rh, s, "abs") == (rx + rw / 2, ry + rh / 2)
        assert map_back(500, 500, rx, ry, rw, rh, s, "norm") == (rx + rw / 2, ry + rh / 2)
    assert region_for("topstrip", (0, 0, 0, 0))[:4] == (0, 0, 1920, 270)
    assert region_for("quadrant", (1200, 10, 1300, 26))[:4] == (960, 0, 960, 540)
    assert region_for("quadrant", (120, 560, 210, 578))[:4] == (0, 540, 960, 540)
    assert region_for("none", (0, 0, 0, 0))[:4] == (0, 0, 1920, 1080)
    # scoring invariants on a hand-built case
    tg = [("a", (100, 100, 200, 140), "big"),      # in crop, answered right (abs)
          ("b", (300, 100, 400, 140), "big"),      # in crop, answered wrong
          ("c", (100, 600, 200, 640), "low"),      # out of crop for topstrip
          ("d", (500, 100, 600, 140), "big")]      # in crop, no answer
    # topstrip is 2x-upscaled, so the crop-image pixel for full-screen (150,120) is (300,240)
    ans = {"a": ('{"x":300,"y":240}', (300, 240), None),
           "b": ('{"x":1800,"y":1800}', (1800, 1800), None),
           "d": ("", None, "nojson")}
    r = score("topstrip", tg, ans)
    assert r["covered"] == 3 and r["n"] == 4, r
    assert r["hits"] <= r["covered"], r
    assert sum(v[0] for v in r["by_class"].values()) == r["n"], r
    assert sum(v[1] for v in r["by_class"].values()) == r["hits"], r
    assert r["hits"] == 1, r
    assert "c:out-of-crop" in r["detail"] and "d:nojson" in r["detail"], r
    print("grounding-score selftest ok: map-back, region, cover/hits invariants")


if __name__ == "__main__":
    selftest()
