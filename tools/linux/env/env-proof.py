#!/usr/bin/env python3
# env-proof.py: proofs for the Environment slot (E1). Writes scenes, PNGs and summary.json
# under <out-dir> (scratch), renders with tools/linux/v5-shot.sh under the render lock,
# stitches the tiles and measures. Never writes into the plugin folder.
#
#   python3 env-proof.py plain <live-dir> <out-dir>
#       F2: plain base, every pixel equals baseColor. F3: three origins with debugGrid, stitched.
#   python3 env-proof.py hall  <live-dir> <out-dir> <r.frag> <s6-r-dir>
#       F4: converts r.frag (r2qt.py), bakes it into <out-dir>/hall (never the plugin), renders
#       DP-2 and the three panorama tiles, compares with s6-r-dir/r-bg-only.png and r-panorama.png.
#
# <live-dir> is nexuslink.hud/v5/live (its shaders hold the baked env.vert.qsb and env.frag.qsb).
import json
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
V5SHOT = os.path.normpath(os.path.join(HERE, "..", "v5-shot.sh"))
LOCK = "/tmp/hudlive-render.lock"
BASE = (6, 8, 10)
LINE = (31, 140, 178)    # grid line colour (0.12, 0.55, 0.70) in 8 bit
MARK = (242, 191, 51)    # 1000 px mark colour (0.95, 0.75, 0.20)
MAGENTA = (255, 0, 255)
WORLD = (-1920, 0, 6400, 1440)
# name, origin x, origin y, width, height, canvas x of the tile in the 6400 wide panorama
TILES = [("hdmi", -1920, 0, 1920, 1200, 0),
         ("dp2", 0, 0, 2560, 1440, 1920),
         ("dp1", 2560, 0, 1920, 1200, 4480)]
HALL_U = dict(t=24, link=7.5, ai=0.4231, ba="0.5, 0.5, 0.5, 1.0", bb="0.5, 0.0, 0.0, 0.0",
              dk="0.4749, 0.8126")

SCENE = """import QtQuick
import "{live_rel}"

// scratch scene written by tools/linux/env/env-proof.py (not part of the plugin)
Item {{
    id: root
    width: {w}
    height: {h}

    Environment {{
        anchors.fill: parent
        objectName: "{name}"
        origin: Qt.point({ox}, {oy})
        world: Qt.rect({wx}, {wy}, {ww}, {wh})
        debugGrid: {grid}
        t: {t}
        link: {link}
        ai: {ai}
        bayA: Qt.vector4d({ba})
        bayB: Qt.vector4d({bb})
        disk: Qt.vector2d({dk})
    }}
}}
"""


def fail(msg):
    sys.stderr.write("env-proof: " + msg + "\n")
    sys.exit(1)


def write_scene(path, live, name, w, h, ox, oy, world, grid=False, t=0, link=0, ai=0,
                ba="0, 0, 0, 0", bb="0, 0, 0, 0", dk="0, 0"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    live_rel = os.path.relpath(live, os.path.dirname(path)).replace(os.sep, "/")
    txt = SCENE.format(live_rel=live_rel, w=w, h=h, name=name, ox=ox, oy=oy, wx=world[0],
                       wy=world[1], ww=world[2], wh=world[3],
                       grid="true" if grid else "false", t=t, link=link, ai=ai,
                       ba=ba, bb=bb, dk=dk)
    with open(path, "w", encoding="ascii") as f:
        f.write(txt)
    return path


def render(scene, png, w, h, allow_flat=False):
    env = dict(os.environ)
    if allow_flat:
        env["V5_ALLOW_FLAT"] = "1"
    cmd = ["flock", LOCK, "nice", "-n", "19", "ionice", "-c3", V5SHOT, scene, png,
           str(w), str(h)]
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=600)
    lines = (p.stdout or "").strip().splitlines()
    return {"rc": p.returncode, "line": lines[-1] if lines else "",
            "err": (p.stderr or "").strip()[-300:]}


def near(c, ref, tol):
    return all(abs(c[i] - ref[i]) <= tol for i in range(3))


def grid_check(img, ox, oy, w, h):
    """Vertical lines on row 50 and horizontal lines on column 50, in GLOBAL pixels."""
    px = img.load()
    found_x = {}
    for x in range(w):
        c = px[x, 50]
        if near(c, MARK, 10):
            found_x[x] = "mark"
        elif near(c, LINE, 10):
            found_x[x] = "line"
    exp_x = {}
    for g in range(ox, ox + w):
        if g % 100 == 0:
            exp_x[g - ox] = "mark" if g % 1000 == 0 else "line"
    found_y = {}
    for y in range(h):
        c = px[50, y]
        if near(c, MARK, 10):
            found_y[y] = "mark"
        elif near(c, LINE, 10):
            found_y[y] = "line"
    exp_y = {}
    for g in range(oy, oy + h):
        if g % 100 == 0:
            exp_y[g - oy] = "mark" if g % 1000 == 0 else "line"
    miss_x = sorted(set(exp_x) - set(found_x))
    extra_x = sorted(set(found_x) - set(exp_x))
    kind_x = sorted(k for k in exp_x if k in found_x and found_x[k] != exp_x[k])
    miss_y = sorted(set(exp_y) - set(found_y))
    extra_y = sorted(set(found_y) - set(exp_y))
    return {"expected_x": len(exp_x), "found_x": len(found_x), "missing_x": miss_x[:10],
            "extra_x": extra_x[:10], "kind_mismatch_x": kind_x[:10],
            "expected_y": len(exp_y), "found_y": len(found_y), "missing_y": miss_y[:10],
            "extra_y": extra_y[:10],
            "first_global_x": [ox + k for k in sorted(found_x)[:6]],
            "ok": not miss_x and not extra_x and not kind_x and not miss_y and not extra_y}


def hist_stats(diff):
    h = diff.histogram()
    n = diff.width * diff.height
    out = []
    for c in range(3):
        hc = h[c * 256:(c + 1) * 256]
        mean = sum(v * k for v, k in enumerate(hc)) / float(n)
        acc, p99, mx, got = 0, 0, 0, False
        for v, k in enumerate(hc):
            if k:
                mx = v
            acc += k
            if not got and acc >= 0.99 * n:
                p99, got = v, True
        out.append({"mean": round(mean, 4), "p99": p99, "max": mx})
    return out


def mean_of(stats):
    return round(sum(s["mean"] for s in stats) / 3.0, 4)


def col_diff(img, c1, c2):
    a = img.crop((c1, 0, c1 + 1, img.height))
    b = img.crop((c2, 0, c2 + 1, img.height))
    return mean_of(hist_stats(ImageChops.difference(a, b)))


def median(vals):
    s = sorted(vals)
    return s[len(s) // 2]


def col_pair(a, b, c):
    return mean_of(hist_stats(ImageChops.difference(a.crop((c, 0, c + 1, a.height)),
                                                    b.crop((c, 0, c + 1, b.height)))))


def p99(vals):
    s = sorted(vals)
    return s[min(len(s) - 1, int(0.99 * len(s)))]


def stitch(tiles_png, out_png):
    canvas = Image.new("RGB", (6400, 1440), (0, 0, 0))
    for name, ox, oy, w, h, cx in TILES:
        im = Image.open(tiles_png[name]).convert("RGB")
        canvas.paste(im, (cx, 0))
    canvas.save(out_png)
    return canvas


def mode_plain(live, out):
    os.makedirs(out, exist_ok=True)
    res = {}
    sc = write_scene(os.path.join(out, "scenes", "plain-dp2.qml"), live, "scene",
                     2560, 1440, 0, 0, (0, 0, 2560, 1440))
    png = os.path.join(out, "plain-dp2.png")
    r = render(sc, png, 2560, 1440, allow_flat=True)
    img = Image.open(png).convert("RGB")
    ext = img.getextrema()
    res["F2"] = {"render": r, "extrema": ext,
                 "pass": ext == ((BASE[0], BASE[0]), (BASE[1], BASE[1]), (BASE[2], BASE[2]))
                 and r["rc"] == 0}
    tiles = {}
    for name, ox, oy, w, h, cx in TILES:
        sc = write_scene(os.path.join(out, "scenes", "grid-%s.qml" % name), live, name,
                         w, h, ox, oy, WORLD, grid=True)
        png = os.path.join(out, "grid-%s.png" % name)
        # a grid frame has 3 or 4 colours by design, so the flat-frame guard is skipped here
        r = render(sc, png, w, h, allow_flat=True)
        tiles[name] = png
        res["grid_" + name] = {"render": r}
    canvas = stitch(tiles, os.path.join(out, "grid-stitch-6400.png"))
    for name, ox, oy, w, h, cx in TILES:
        tile = Image.open(tiles[name]).convert("RGB")
        res["grid_" + name]["check"] = grid_check(tile, ox, oy, w, h)
        res["grid_" + name]["canvas_x"] = cx
    # canvas level: the world corner marker and the borders
    px = canvas.load()
    mag = [(x, y) for y in range(0, 6) for x in range(0, 6) if px[x, y] == MAGENTA]
    res["F3_world_marker"] = {"magenta_px": len(mag), "bbox": [min(mag), max(mag)] if mag else None,
                              "expected_px": 9, "expected_at": "canvas 0..2 x 0..2"}
    borders = {}
    for bx, label in ((1920, "hdmi|dp2"), (4480, "dp2|dp1")):
        found = [x for x in range(bx - 4, bx + 4) if near(px[x, 50], LINE, 10) or near(px[x, 50], MARK, 10)]
        expected = [x for x in range(bx - 4, bx + 4) if (x - 1920) % 100 == 0]
        borders[label] = {"found_canvas_x": found, "expected_canvas_x": expected,
                          "offsets": sorted(set(found) ^ set(expected))}
    res["F3_borders"] = borders
    res["F3_seam_columns"] = {}
    for bx, label in ((1919, "1919|1920"), (4479, "4479|4480")):
        d_b = col_diff(canvas, bx, bx + 1)
        ords = [col_diff(canvas, c, c + 1) for c in range(0, 6399, 7) if abs(c - 1919) > 2 and abs(c - 4479) > 2]
        res["F3_seam_columns"][label] = {"border_mean_abs": d_b, "ordinary_median": median(ords),
                                        "ordinary_p99": p99(ords)}
    with open(os.path.join(out, "summary-plain.json"), "w") as f:
        json.dump(res, f, indent=1, sort_keys=True)
    print(json.dumps(res, sort_keys=True))


def mode_hall(live, out, r_frag, s6r):
    os.makedirs(out, exist_ok=True)
    hall = os.path.join(out, "hall")
    shutil.rmtree(hall, ignore_errors=True)
    os.makedirs(hall)
    frag = os.path.join(hall, "env-hall.frag")
    c = subprocess.run([sys.executable, os.path.join(HERE, "r2qt.py"), r_frag,
                        os.path.join(live, "shaders", "env.frag"), frag],
                       capture_output=True, text=True)
    if c.returncode != 0:
        fail("r2qt failed: " + c.stderr)
    print(c.stdout.strip())
    b = subprocess.run([os.path.join(live, "shaders", "env-bake.sh")],
                       env=dict(os.environ, FRAG=frag), capture_output=True, text=True)
    if b.returncode != 0:
        fail("bake failed: " + (b.stderr or b.stdout)[-600:])
    tree = os.path.join(hall, "tree", "live")
    shutil.copytree(live, tree)
    shutil.copy(frag + ".qsb", os.path.join(tree, "shaders", "env.frag.qsb"))
    res = {"convert": c.stdout.strip(), "bake_rc": b.returncode}
    dp2 = os.path.join(hall, "hall-dp2.png")
    sc = write_scene(os.path.join(hall, "scenes", "hall-dp2.qml"), tree, "hall-dp2",
                     2560, 1440, 0, 0, (0, 0, 2560, 1440), **HALL_U)
    res["dp2_render"] = render(sc, dp2, 2560, 1440)
    ref = Image.open(os.path.join(s6r, "r-bg-only.png")).convert("RGB")
    got = Image.open(dp2).convert("RGB")
    res["F4_dp2_vs_r-bg-only"] = {"size": [got.width, got.height], "per_channel": hist_stats(
        ImageChops.difference(got, ref)), "limit_mean": 2.0}
    tiles = {}
    for name, ox, oy, w, h, cx in TILES:
        sc = write_scene(os.path.join(hall, "scenes", "hall-%s.qml" % name), tree, name,
                         w, h, ox, oy, WORLD, **HALL_U)
        png = os.path.join(hall, "hall-%s.png" % name)
        res["pano_" + name] = render(sc, png, w, h)
        tiles[name] = png
    canvas = stitch(tiles, os.path.join(hall, "hall-stitch-6400.png"))
    pano = Image.open(os.path.join(s6r, "r-panorama.png")).convert("RGB")
    res["F4_pano_vs_r-panorama"] = {"size": [canvas.width, canvas.height],
                                    "per_channel": hist_stats(ImageChops.difference(canvas, pano))}
    d_s = {}
    for bx, label in ((1919, "1919|1920"), (4479, "4479|4480")):
        d_s[label] = {"ours_border_mean_abs": col_diff(canvas, bx, bx + 1),
                      "ref_border_mean_abs": col_diff(pano, bx, bx + 1)}
    ords_o = [col_diff(canvas, c, c + 1) for c in range(0, 6399, 5) if abs(c - 1919) > 2 and abs(c - 4479) > 2]
    res["F4_seam"] = {"borders": d_s, "ordinary_ours_median": median(ords_o),
                      "ordinary_ours_p99": p99(ords_o)}
    # per column difference to the reference: does the stitch differ from the reference at the seams?
    per_col = [col_pair(canvas, pano, c) for c in range(0, 6400, 5) if abs(c - 1919) > 2 and abs(c - 4479) > 2]
    res["F4_column_vs_ref"] = {"ordinary_median": median(per_col), "ordinary_p99": p99(per_col),
                               "border_cols_1918_1921": [col_pair(canvas, pano, c) for c in range(1918, 1922)],
                               "border_cols_4478_4481": [col_pair(canvas, pano, c) for c in range(4478, 4482)]}
    mask = ImageChops.difference(got, ref).convert("L").point(lambda v: 255 if v > 8 else 0)
    res["F4_dp2_pixels_over_8"] = {"count": mask.histogram()[255], "bbox": mask.getbbox()}
    res["F4_dp2_vs_r-bg-only_pass"] = res["F4_dp2_vs_r-bg-only"]["per_channel"][0]["mean"] < 2.0
    res["F4_dp2_tile_vs_r-bg-only"] = hist_stats(ImageChops.difference(
        Image.open(tiles["dp2"]).convert("RGB"), ref))
    with open(os.path.join(out, "summary-hall.json"), "w") as f:
        json.dump(res, f, indent=1, sort_keys=True)
    print(json.dumps(res, sort_keys=True))


def main():
    if len(sys.argv) < 4:
        sys.stderr.write(__doc__)
        return 64
    mode, live, out = sys.argv[1], os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3])
    if mode == "plain":
        mode_plain(live, out)
    elif mode == "hall" and len(sys.argv) == 6:
        mode_hall(live, out, os.path.abspath(sys.argv[4]), os.path.abspath(sys.argv[5]))
    else:
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main())
