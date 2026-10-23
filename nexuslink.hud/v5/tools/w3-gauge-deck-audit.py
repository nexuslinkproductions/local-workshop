#!/usr/bin/env python3
"""W3 gauge deck audit: are the gauges really in the composed deck, at rest?

The still proves the deck's pixels did not move; this proves the components are
actually in the item tree of each deep view (visible, at the deck's size, art
scale snapped to its resting target, dots present) instead of an empty box that
renders the same colour as the field.

    v5/tools/w3-gauge-deck-audit.py            # mac, storage, launcher
    v5/tools/w3-gauge-deck-audit.py --json DIR # also save the raw AUDIT lines

Per deep view it requires:
  * the deck's focusId equals the requested one and focusRect is non-empty
  * the gauges that view composes are visible (mac: PulseRing + DotArc,
    storage: DotBar + DotArc, launcher: none, the launcher draws LauncherArc)
  * every visible gauge draws at its resting scale: artScale == size /
    referenceSize to 2e-3. Anything else means a motion animation was still
    running when the view opened, i.e. the startup artifact the motionReady
    guard exists to prevent.
  * every visible gauge paints at least one dot

Exit: 0 all checks pass, 1 a check failed, 3 toolchain, 64 usage.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

V5 = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO = os.path.abspath(os.path.join(V5, "..", ".."))
PROBE = os.path.join(V5, "tests", "w3", "GaugeDeepAudit.qml")

REST_TOL = 2e-3

VIEWS = [
    ("mac", ["PulseRing", "DotArc"]),
    ("storage", ["DotBar", "DotArc"]),
    ("launcher", []),
]


def qml_bin():
    for candidate in (os.environ.get("QML_QT_BIN"), "/opt/homebrew/opt/qt/bin/qml",
                      shutil.which("qml")):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def run_audit(focus):
    qml = qml_bin()
    if not qml:
        print("w3-gauge-deck-audit: no qml binary (set QML_QT_BIN)", file=sys.stderr)
        sys.exit(3)
    imports = tempfile.mkdtemp(prefix="w3-audit-imports.")
    try:
        os.makedirs(os.path.join(imports, "NexusHud"), exist_ok=True)
        os.symlink(os.path.join(V5, "kit"), os.path.join(imports, "NexusHud", "V5"))
        env = dict(os.environ)
        env["QT_QPA_PLATFORM"] = "offscreen"
        env["QML_IMPORT_PATH"] = imports
        proc = subprocess.run([qml, "-I", imports, PROBE, "--", "--focus=" + focus],
                              cwd=REPO, env=env, capture_output=True, text=True,
                              timeout=240)
    finally:
        shutil.rmtree(imports, ignore_errors=True)
    for line in (proc.stdout + proc.stderr).splitlines():
        idx = line.find("AUDIT ")
        if idx >= 0:
            return json.loads(line[idx + len("AUDIT "):])
    print("w3-gauge-deck-audit: no AUDIT line for %s (exit %d)\n%s"
          % (focus, proc.returncode, (proc.stdout + proc.stderr)[-2000:]),
          file=sys.stderr)
    sys.exit(3)


def main(argv):
    json_dir = None
    i = 0
    while i < len(argv):
        if argv[i] == "--json" and i + 1 < len(argv):
            json_dir, i = argv[i + 1], i + 2
        else:
            print("usage: w3-gauge-deck-audit.py [--json DIR]", file=sys.stderr)
            return 64
    if json_dir:
        os.makedirs(json_dir, exist_ok=True)

    failures = []
    for focus, required in VIEWS:
        audit = run_audit(focus)
        if json_dir:
            with open(os.path.join(json_dir, "deck-%s.json" % focus), "w") as fh:
                fh.write("AUDIT " + json.dumps(audit, sort_keys=True) + "\n")

        print("\n== deck, %s deep view ==" % focus)
        print("  focus      focusId %r, focusRect %s"
              % (audit.get("focusId"), audit.get("focusRect")))
        print("  gauges     %d in tree, %d visible"
              % (audit.get("gaugesInTree", 0), audit.get("gaugesVisible", 0)))

        if audit.get("focusId") != focus:
            failures.append("%s: deck focusId is %r" % (focus, audit.get("focusId")))
        rect = audit.get("focusRect") or [0, 0, 0, 0]
        if rect[2] <= 0 or rect[3] <= 0:
            failures.append("%s: empty focusRect" % focus)

        visible = audit.get("visible") or []
        types = [v["type"] for v in visible]
        for want in required:
            if want not in types:
                failures.append("%s: %s is not visible in this deep view" % (focus, want))

        for v in visible:
            print("  %-9s %6.2f x %-6.2f at (%7.2f, %6.2f)  artScale %.6f  "
                  "dots %3d  opacity %.3f"
                  % (v["type"], v["width"], v["height"], v["x"], v["y"],
                     v["artScale"], v["dots"], v["opacity"]))
            if v["dots"] < 1:
                failures.append("%s: %s paints no dots" % (focus, v["type"]))
            if abs(v["artScale"] - v["targetScale"]) > REST_TOL:
                failures.append("%s: %s draws at %.6f, its resting target is %.6f "
                                "(a motion animation is in flight)"
                                % (focus, v["type"], v["artScale"], v["targetScale"]))
            if v.get("targetOpacity", -1) >= 0 and abs(v["opacity"] - v["targetOpacity"]) > REST_TOL:
                failures.append("%s: %s opacity %.6f, its resting target is %.6f"
                                % (focus, v["type"], v["opacity"], v["targetOpacity"]))

    if failures:
        print("\nFAIL")
        for f in failures:
            print("  " + f)
        return 1
    print("\nPASS: every deep view opens on the gauges it composes, each at its "
          "resting scale with its dots drawn")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
