#!/usr/bin/env python3
"""I1 deck motion evidence: overshoot, return, idle drift, breath period.

Two probes, each measured where it can be measured precisely (the reason is in
`nexuslink.hud/v5/docs/motion.md`):

  tests/i1/CrewExpandTrace.qml   expand + return: the same CrewOrb the deck
                                 composes, at the deck's size and tokens, in a
                                 scene small enough for the tool's best 25 ms grid
  tests/i1/DeckTrace.qml         idle drift and breath on the composed deck,
                                 whose periods are 5.8 s and 13 s, so the deck's
                                 ~100 ms grid is plenty there

    v5/tools/deck-trace.py              # runs both (3 expand attempts)
    v5/tools/deck-trace.py --json DIR   # parse saved TRACE lines from DIR

Bands: expand overshoot 4 to 6 percent, return monotone with none, drift
non-zero, breath 5 to 6 s. Exit 0 all in band, 1 a band missed, 3 toolchain.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

V5 = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO = os.path.abspath(os.path.join(V5, "..", ".."))
EXPAND_PROBE = os.path.join(V5, "tests", "i1", "CrewExpandTrace.qml")
DECK_PROBE = os.path.join(V5, "tests", "i1", "DeckTrace.qml")

REST = 1.0                     # CrewOrb.growth at rest
OVERSHOOT_BAND = (4.0, 6.0)    # percent, MAIN-SCREEN-BUILD.md
BREATH_BAND = (5.0, 6.0)       # seconds


def qml_bin():
    for candidate in (os.environ.get("QML_QT_BIN"), "/opt/homebrew/opt/qt/bin/qml",
                      shutil.which("qml")):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def run_probe(probe_path):
    qml = qml_bin()
    if not qml:
        print("deck-trace: no qml binary (set QML_QT_BIN)", file=sys.stderr)
        sys.exit(3)
    imports = tempfile.mkdtemp(prefix="deck-trace-imports.")
    try:
        os.makedirs(os.path.join(imports, "NexusHud"), exist_ok=True)
        os.symlink(os.path.join(V5, "kit"), os.path.join(imports, "NexusHud", "V5"))
        env = dict(os.environ)
        env["QT_QPA_PLATFORM"] = "offscreen"
        env["QML_IMPORT_PATH"] = imports
        proc = subprocess.run([qml, "-I", imports, probe_path], cwd=REPO, env=env,
                              capture_output=True, text=True, timeout=240)
    finally:
        shutil.rmtree(imports, ignore_errors=True)
    for line in (proc.stdout + proc.stderr).splitlines():
        idx = line.find("TRACE ")
        if idx >= 0:
            return json.loads(line[idx + len("TRACE "):])
    print("deck-trace: no TRACE line from %s (exit %d)\n%s"
          % (os.path.basename(probe_path), proc.returncode,
             (proc.stdout + proc.stderr)[-2000:]), file=sys.stderr)
    return None


def read_json_traces(directory):
    """Best (densest) expand trace and deck trace in a directory of TRACE files."""
    deck = expand = None
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(directory, name)) as f:
            for line in f:
                idx = line.find("TRACE ")
                if idx < 0:
                    continue
                payload = json.loads(line[idx + len("TRACE "):])
                if payload.get("label") == "crew-expand":
                    if expand is None or len(payload["samples"]) > len(expand["samples"]):
                        expand = payload
                elif deck is None or len(payload["expand"]) > len(deck["expand"]):
                    deck = payload
    return deck, expand


def expand_metrics(samples, target, t_off):
    """Expand peak / overshoot / settle, and the return's monotonicity.

    `t_off` is when the probe asked for the return, so the expand metrics only
    look at samples before it (a settle test run over the whole capture would see
    the return's departure from the target and report nonsense).
    """
    if not samples:
        return None, None
    travel = target - REST
    up_samples = [s for s in samples if s["t"] < t_off]
    down_samples = [s for s in samples if s["t"] >= t_off]
    if not up_samples:
        return None, None
    start_i = 0
    for i, s in enumerate(up_samples):
        if s["g"] > REST + 0.02:
            start_i = i
            break
    start_t = up_samples[start_i]["t"]
    peak = max(s["g"] for s in up_samples)
    peak_t = max(up_samples, key=lambda s: s["g"])["t"]
    overshoot = (peak - target) / travel * 100.0
    settle = None
    for i in range(len(up_samples) - 1, 0, -1):
        if abs(up_samples[i]["g"] - target) > 0.02 * travel:
            settle = up_samples[i + 1]["t"] - start_t if i + 1 < len(up_samples) else None
            break
    if settle is None:
        settle = up_samples[-1]["t"] - start_t
    up = {"peak": peak, "peak_t": peak_t - start_t, "overshoot_pct": overshoot,
          "settle_ms": settle, "last": up_samples[-1]["g"]}

    ret = None
    if down_samples:
        lower = min(s["g"] for s in down_samples)
        rises = sum(1 for i in range(1, len(down_samples))
                    if down_samples[i]["g"] > down_samples[i - 1]["g"] + 1e-6)
        rsettle = None
        for s in down_samples:
            if abs(s["g"] - REST) <= 0.02:
                rsettle = s["t"] - down_samples[0]["t"]
                break
        ret = {"min": lower, "rises": rises, "settle_ms": rsettle,
               "last": down_samples[-1]["g"]}
    return up, ret


def breath_period(samples):
    """Seconds per cycle, from the rising crossings of the mid level."""
    if not samples:
        return {"period_s": None, "crossings": [], "min": 0.0, "max": 0.0}
    b = [s["b"] for s in samples]
    hi, lo = max(b), min(b)
    mid = (hi + lo) / 2.0
    crossings = []
    for i in range(1, len(samples)):
        if b[i - 1] < mid <= b[i]:
            f = (mid - b[i - 1]) / (b[i] - b[i - 1])
            crossings.append(samples[i - 1]["t"] + f * (samples[i]["t"] - samples[i - 1]["t"]))
    if len(crossings) < 2:
        return {"period_s": None, "crossings": crossings, "min": lo, "max": hi}
    span = crossings[-1] - crossings[0]
    return {"period_s": span / (len(crossings) - 1) / 1000.0,
            "crossings": crossings, "min": lo, "max": hi}


def main(argv):
    deck = expand = None
    if len(argv) >= 3 and argv[1] == "--json":
        deck, expand = read_json_traces(argv[2])
    else:
        best = None
        for i in range(3):
            t = run_probe(EXPAND_PROBE)
            if t is None:
                continue
            print("   expand run %d/3  %d samples" % (i + 1, len(t["samples"])))
            if best is None or len(t["samples"]) > len(best["samples"]):
                best = t
        expand = best
        deck = run_probe(DECK_PROBE)
    if expand is None or deck is None:
        print("deck-trace: missing a trace", file=sys.stderr)
        return 3

    target = float(expand.get("expandScale", 1.4))
    up, ret = expand_metrics(expand["samples"], target, expand.get("returnAtMs", 1000))

    drift = deck["drift"]
    drift_max = max(max(abs(s["dx"]) for s in drift), max(abs(s["dy"]) for s in drift))
    drift_ranges = (max(s["dx"] for s in drift) - min(s["dx"] for s in drift),
                    max(s["dy"] for s in drift) - min(s["dy"] for s in drift))
    breath = breath_period(deck["breath"])

    n_exp = len(expand["samples"])
    grid_exp = (expand["samples"][-1]["t"] - expand["samples"][0]["t"]) / max(1, n_exp)
    grid_deck = (deck["breath"][-1]["t"] - deck["breath"][0]["t"]) / max(1, len(deck["breath"]))

    print("== expand/return  (%d samples, %.1f ms grid, target %.2f)"
          % (n_exp, grid_exp, target))
    print("   expand   peak %.4f at %d ms  overshoot %+.2f %%  settle %s ms"
          % (up["peak"], up["peak_t"], up["overshoot_pct"], up["settle_ms"]))
    print("   return   min %.4f  rises %d  settle %s ms  last %.4f"
          % (ret["min"], ret["rises"], ret["settle_ms"], ret["last"]))
    print("   tokens   expand %d ms  return %d ms  (%.0f percent analytic)"
          % (expand["expandMillisToken"], expand["returnMillisToken"],
             expand["expandOvershootToken"] * 100))
    print("== deck          (%d breath samples, %.1f ms grid)" % (len(deck["breath"]), grid_deck))
    print("   drift    max |d| %.3f px  x-range %.3f  y-range %.3f"
          % (drift_max, drift_ranges[0], drift_ranges[1]))
    print("   breath   period %s s  (%d crossings, b %.3f..%.3f)"
          % (("%.3f" % breath["period_s"]) if breath["period_s"] else "none",
             len(breath["crossings"]), breath["min"], breath["max"]))
    print("   tokens   breathPeriod %.2f s" % deck["breathPeriodToken"])

    ok = True
    if not (OVERSHOOT_BAND[0] <= up["overshoot_pct"] <= OVERSHOOT_BAND[1]):
        print("   FAIL overshoot %.2f %% outside %s" % (up["overshoot_pct"], OVERSHOOT_BAND))
        ok = False
    if ret["min"] < REST - 0.002 or ret["rises"] > 0:
        print("   FAIL return not monotone to rest (min %.4f, %d rises)"
              % (ret["min"], ret["rises"]))
        ok = False
    if drift_max <= 0.05:
        print("   FAIL idle drift flat (max %.3f px)" % drift_max)
        ok = False
    if breath["period_s"] is None or not (BREATH_BAND[0] <= breath["period_s"] <= BREATH_BAND[1]):
        print("   FAIL breath period %s outside %s" % (breath["period_s"], BREATH_BAND))
        ok = False
    print("   %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
