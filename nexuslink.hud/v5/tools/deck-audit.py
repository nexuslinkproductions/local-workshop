#!/usr/bin/env python3
"""I1 deck text audit: word count, smallest type size, zero overlaps.

Runs the QML probe (nexuslink.hud/v5/tests/i1/DeckAudit.qml through one of the
audit-*.qml wrappers), which walks the live item tree and prints every visible
Text with its pixel size and its box in deck coordinates. This script turns that
into the three numbers acceptance asks for and fails non-zero if any of them is
out of bounds.

    v5/tools/deck-audit.py nexuslink.hud/v5/tests/i1/audit-rest.qml

Exit 0 all checks pass, 1 a check failed, 3 toolchain problem, 64 usage.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
V5 = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MAX_WORDS = 40
MIN_PX = 16
# Two boxes may touch by a hair through antialiasing; anything under this is not
# an overlap on screen.
OVERLAP_EPS = 0.0


def qml_bin():
    for candidate in (
        os.environ.get("QML_QT_BIN"),
        "/opt/homebrew/opt/qt/bin/qml",
        shutil.which("qml"),
    ):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def run_probe(qml, wrapper, imports):
    env = dict(os.environ)
    env["QT_QPA_PLATFORM"] = "offscreen"
    env["QML_IMPORT_PATH"] = imports + (":" + env["QML_IMPORT_PATH"] if env.get("QML_IMPORT_PATH") else "")
    env["QT_LOGGING_RULES"] = "qt.qpa.fonts.warning=false"
    proc = subprocess.run(
        [qml, "-I", imports, wrapper],
        cwd=REPO, env=env, capture_output=True, text=True, timeout=180,
    )
    payload = None
    for line in (proc.stdout + proc.stderr).splitlines():
        # The qml tool prefixes console.log output with "qml: ", so take the
        # payload from the marker instead of the line start.
        idx = line.find("AUDIT ")
        if idx >= 0:
            payload = json.loads(line[idx + len("AUDIT "):])
    if payload is None:
        raise RuntimeError("no AUDIT line (exit %d)\n%s" % (proc.returncode, (proc.stdout + proc.stderr)[-3000:]))
    return payload


def words_of(texts):
    """Whitespace words, with a run of single glyph cells counted as one word.

    Clock.qml paints one Text per glyph so the digits can be tabular, so "00:18"
    arrives as five items. Cells that are one character and sit end to end on the
    same baseline are one word; everything else splits on whitespace.
    """
    # Group by a 12 px row band first: the clock's colon rises about 6 px above
    # the digits, and it still belongs to the same word.
    cells = sorted(texts, key=lambda t: (round(t["y"] / 12.0), t["x"]))
    merged = []
    for t in cells:
        s = t["t"]
        if len(s) == 1 and not s.isspace() and merged:
            prev = merged[-1]
            # Clock cells: the colon rises 0.06 em (about 6 px at 96 px), so the
            # baseline test has to allow a few px of vertical offset.
            if (len(prev["t"]) >= 1 and abs(prev["y"] - t["y"]) < 8.0
                    and abs((prev["x"] + prev["w"]) - t["x"]) < 1.0
                    and prev["t"][-1:] != " "):
                prev["t"] += s
                prev["w"] = t["x"] + t["w"] - prev["x"]
                continue
        merged.append({"t": s, "x": t["x"], "y": t["y"], "w": t["w"]})
    count = 0
    for m in merged:
        count += len([w for w in m["t"].split() if w])
    return count, merged


def overlaps(texts):
    bad = []
    for i in range(len(texts)):
        a = texts[i]
        for j in range(i + 1, len(texts)):
            b = texts[j]
            x = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
            y = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
            if x > OVERLAP_EPS and y > OVERLAP_EPS:
                bad.append((a["t"], b["t"], round(x * y, 1)))
    return bad


def font_check(payload, texts):
    """Is the deck painted in Satoshi, or silently in the fallback face?

    Each Text arrives with three advances measured in the same engine: the live
    item's own contentWidth, a twin requesting family "Satoshi", and a twin
    requesting a family that cannot exist (the fallback). A text whose Satoshi
    and fallback advances differ is decisive: if the live advance is the
    Satoshi one, the painted glyphs are Satoshi. Texts where the two advances
    are identical cannot discriminate and are counted but not required.
    """
    fam = bool(payload.get("fontFamiliesHasSatoshi"))
    eps = 0.01
    elided = [t for t in texts if t.get("advConstrained")]
    candidates = [t for t in texts if not t.get("advConstrained")]
    decisive = [t for t in candidates
                if abs(t.get("advSatoshi", 0) - t.get("advFallback", 0)) >= eps]
    sat = [t for t in decisive if abs(t["adv"] - t["advSatoshi"]) < eps]
    fb = [t for t in decisive if abs(t["adv"] - t["advFallback"]) < eps]
    return fam, decisive, sat, fb, elided


def audit(qml, wrapper):
    imports = tempfile.mkdtemp(prefix="deck-audit-imports.")
    try:
        os.makedirs(os.path.join(imports, "NexusHud"), exist_ok=True)
        link = os.path.join(imports, "NexusHud", "V5")
        if not os.path.exists(link):
            os.symlink(os.path.join(V5, "kit"), link)
        # kit components resolve their faces as ../fonts; through the module
        # symlink that is <imports>/NexusHud/fonts, so mirror v5/fonts there.
        fonts = os.path.join(imports, "NexusHud", "fonts")
        if not os.path.exists(fonts):
            os.symlink(os.path.join(V5, "fonts"), fonts)
        payload = run_probe(qml, wrapper, imports)
    finally:
        shutil.rmtree(imports, ignore_errors=True)

    if "error" in payload:
        print("FAIL %s: %s" % (payload.get("label"), payload["error"]))
        return False

    texts = payload["texts"]
    label = payload.get("label", os.path.basename(wrapper))
    words, merged = words_of(texts)
    min_px = min(t["px"] for t in texts) if texts else 0
    bad = overlaps(texts)

    print("== %s" % label)
    print("   texts  %d items, %d words after merging glyph cells" % (len(texts), words))
    for m in merged:
        print("   %-22r x=%7.1f y=%7.1f w=%6.1f" % (m["t"], m["x"], m["y"], m["w"]))
    print("   min px %.0f   overlaps %d" % (min_px, len(bad)))
    fam, decisive, sat, fb, elided = font_check(payload, texts)
    print("   fonts  Qt.fontFamilies() has Satoshi: %s   %d of %d decisive texts painted"
          " in the Satoshi advance, %d in the fallback face%s"
          % (fam, len(sat), len(decisive), len(fb),
             ("; %d elided text not decisive" % len(elided)) if elided else ""))

    ok = True
    if words > MAX_WORDS:
        print("   FAIL words %d > %d" % (words, MAX_WORDS))
        ok = False
    if min_px < MIN_PX:
        print("   FAIL smallest type %.0f px < %d" % (min_px, MIN_PX))
        ok = False
    if bad:
        for a, b, area in bad:
            print("   FAIL overlap %.1f px2: %r / %r" % (area, a, b))
        ok = False
    if not fam:
        print("   FAIL Satoshi is not in Qt.fontFamilies(): every advance above"
              " belongs to the fallback face")
        ok = False
    if decisive and (len(sat) != len(decisive) or fb):
        for t in decisive:
            if abs(t["adv"] - t["advSatoshi"]) >= 0.01:
                print("   FAIL %r painted at advance %.3f, Satoshi gives %.3f"
                      " (fallback %.3f)" % (t["t"], t["adv"], t["advSatoshi"], t["advFallback"]))
        ok = False
    print("   %s" % ("PASS" if ok else "FAIL"))
    return ok


def main(argv):
    if len(argv) < 2:
        print("usage: deck-audit.py <audit-wrapper.qml> [more wrappers...]", file=sys.stderr)
        return 64
    qml = qml_bin()
    if not qml:
        print("deck-audit: no qml binary (set QML_QT_BIN)", file=sys.stderr)
        return 3
    ok = True
    for wrapper in argv[1:]:
        if not os.path.isfile(wrapper):
            print("deck-audit: no such file: %s" % wrapper, file=sys.stderr)
            return 64
        ok = audit(qml, os.path.abspath(wrapper)) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
