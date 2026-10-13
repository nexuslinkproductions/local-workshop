#!/usr/bin/env python3
"""screen_locate.py "<target>" [--monitor DP-1] [--model gemma4-12b] [--endpoint URL] [--selftest]

Two-stage crop-and-zoom locate on one monitor (BRIEF-27). Reads the screen, NEVER clicks.
  stage 1: full screenshot  -> which quadrant holds the target
  stage 2: that quadrant x2 -> target centre, mapped back to monitor pixels
Prints one JSON line {"x","y","monitor","confidence","ms"}; x/y are null when not found.
confidence is a structural check (both stages parsed, point inside the chosen quadrant),
not a calibrated accuracy number. Exit 0 found, 1 not found, 2 capture/endpoint error.
"""
import argparse, base64, importlib.util, json, os, re, shutil, struct, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("grounding_score", LAB / "bench" / "grounding-score.py")
gs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gs)  # the one crop/map-back implementation; bench/ scores with the same code

# ponytail: fixed convention. Gemma 4 12B answers on a 0-1000 grid over the crop (live grounding run
# 2026-10-13: conv=norm wins). If a different model answers in pixels, flip this (or pick by majority).
CONV = "norm"
PROMPT_Q = ('This is a screenshot of a computer screen. In which quadrant is the following? "{t}". '
            "Answer with exactly one of: top-left, top-right, bottom-left, bottom-right.")
PROMPT_P = ('Return ONLY a JSON object {{"x":int,"y":int}} with the centre coordinates of the '
            '"{t}" element in this screenshot, in the image\'s own pixel size.')


def parse_quadrant(txt):
    m = re.search(r"(top|bottom)[\s-]*(left|right)", txt.lower())
    return f"{m.group(1)}-{m.group(2)}" if m else None


def parse_point(txt):
    mx = re.search(r'\bx"?\s*[:=]\s*(-?\d+)', txt)
    my = re.search(r'\by"?\s*[:=]\s*(-?\d+)', txt)
    return (int(mx.group(1)), int(my.group(1))) if mx and my else None


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("grim output is not a PNG")
    return struct.unpack(">II", head[16:24])


def monitor(name):
    mons = json.loads(subprocess.run(["hyprctl", "monitors", "-j"], check=True,
                                     capture_output=True, text=True).stdout)
    for m in mons:
        if m["name"] == name:
            return m
    raise RuntimeError(f"monitor {name} not found: {[m['name'] for m in mons]}")


def ask(endpoint, model, png, prompt):
    b64 = base64.b64encode(open(png, "rb").read()).decode()
    body = {"model": model, "temperature": 0, "max_tokens": 48,
            "messages": [{"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
                {"type": "text", "text": prompt}]}]}
    req = urllib.request.Request(endpoint.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.loads(r.read())
    return ((d.get("choices") or [{}])[0].get("message") or {}).get("content") or ""


def locate(target, mon_name, model, endpoint, work):
    mon = monitor(mon_name)
    shot = os.path.join(work, "screen.png")
    subprocess.run(["grim", "-o", mon_name, shot], check=True)
    W, H = png_size(shot)
    out = {"x": None, "y": None, "monitor": mon_name, "confidence": 0.0}

    # stage 1: quadrant
    q = parse_quadrant(ask(endpoint, model, shot, PROMPT_Q.format(t=target)))
    if q is None:
        return out
    cx = W // 4 if q.endswith("left") else 3 * W // 4
    cy = H // 4 if q.startswith("top") else 3 * H // 4
    rx, ry, rw, rh, scale = gs.region_for("quadrant", (cx, cy, cx, cy), W, H)

    # stage 2: zoom into the quadrant, locate inside it
    crop = os.path.join(work, "quad.png")
    subprocess.run(["magick", shot, "-crop", f"{rw}x{rh}+{rx}+{ry}", "+repage",
                    "-resize", f"{int(scale * 100)}%", "-depth", "8", crop], check=True)
    pt = parse_point(ask(endpoint, model, crop, PROMPT_P.format(t=target)))
    if pt is None:
        return out
    ax, ay = gs.map_back(pt[0], pt[1], rx, ry, rw, rh, scale, CONV)  # monitor px in the screenshot
    if not (rx <= ax < rx + rw and ry <= ay < ry + rh):
        return out
    out.update(x=int(mon["x"] + round(ax / mon["scale"])), y=int(mon["y"] + round(ay / mon["scale"])),
               confidence=1.0, quadrant=q)
    return out


def selftest():
    # mapping + parsers only; no GPU, no screenshot
    assert parse_quadrant("Top Right") == "top-right" and parse_quadrant("bottom-left.") == "bottom-left"
    assert parse_quadrant("no idea") is None
    assert parse_point('{"x": 1204, "y": 6}') == (1204, 6) and parse_point("x=5, y=7") == (5, 7)
    assert parse_point('{"max": 3}') is None
    # 2560x1440 top-right quadrant: region (1280,0,1280,720) x2; norm point (500,500) = its centre
    rx, ry, rw, rh, s = gs.region_for("quadrant", (2400, 10, 2400, 10), 2560, 1440)
    assert (rx, ry, rw, rh) == (1280, 0, 1280, 720), (rx, ry, rw, rh)
    ax, ay = gs.map_back(500, 500, rx, ry, rw, rh, s, CONV)
    assert (ax, ay) == (1280 + 640, 360), (ax, ay)
    print("screen_locate selftest ok")


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("target")
    ap.add_argument("--monitor", default="DP-1")
    ap.add_argument("--model", default="gemma4-12b")
    ap.add_argument("--endpoint", default="http://127.0.0.1:18080/v1")
    a = ap.parse_args()
    t0 = time.perf_counter()
    work = tempfile.mkdtemp(prefix="screen-locate-", dir=os.environ.get("TMPDIR") or None)
    try:
        res = locate(a.target, a.monitor, a.model, a.endpoint, work)
        code = 0 if res["confidence"] > 0 else 1
    except Exception as e:  # capture or endpoint failure: report, don't guess
        res = {"x": None, "y": None, "monitor": a.monitor, "confidence": 0.0, "error": repr(e)}
        code = 2
    finally:
        shutil.rmtree(work, ignore_errors=True)
    res["ms"] = int((time.perf_counter() - t0) * 1000)
    print(json.dumps(res))
    sys.exit(code)


if __name__ == "__main__":
    main()
