#!/usr/bin/env python3
"""I1 deck motion evidence: overshoot, return, idle drift, breath period.

Reads the trace from nexuslink.hud/v5/tests/i1/DeckTrace.qml and prints the four
numbers motion.md has to carry, with the bands from the plan:

  expand overshoot   4 to 6 percent      (peak over the target, share of travel)
  return             monotone, no overshoot past the rest value
  idle drift         amplitude non-zero, both axes
  breath period      5 to 6 s

    v5/tools/deck-trace.py            # runs the probe
    v5/tools/deck-trace.py --json f   # parse a saved TRACE line

Exit 0 all four in band, 1 a band missed, 3 toolchain, 64 usage.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

V5 = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO = os.path.abspath(os.path.join(V5, "..", ".."))
PROBE = os.path.join(V5, "tests", "i1", "DeckTrace.qml")

REST = 1.0                     # CrewOrb.growth at rest
TARGET = 1.4                   # CrewOrb.growth expanded (expandScale)
OVERSHOOT_BAND = (4.0, 6.0)    # percent, MAIN-SCREEN-BUILD.md
BREATH_BAND = (5.0, 6.0)       # seconds


def qml_bin():
    for candidate in (os.environ.get("QML_QT_BIN"), "/opt/homebrew/opt/qt/bin/qml",
                      shutil.which("qml")):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def run_probe():
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
        proc = subprocess.run([qml, "-I", imports, PROBE], cwd=REPO, env=env,
                              capture_output=True, text=True, timeout=180)
    finally:
        shutil.rmtree(imports, ignore_errors=True)
    for line in (proc.stdout + proc.stderr).splitlines():
        idx = line.find("TRACE ")
        if idx >= 0:
            return json.loads(line[idx + len("TRACE "):])
    print("deck-trace: no TRACE line (exit %d)\n%s"
          % (proc.returncode, (proc.stdout + proc.stderr)[-2000:]), file=sys.stderr)
    sys.exit(3)


def expand_metrics(samples, start_t):
    """Peak overshoot and settle time, both measured from the expand start."""
    if not samples:
        return None
    travel = TARGET - REST
    peak = max(s["g"] for s in samples)
    overshoot = (peak - TARGET) / travel * 100.0
    # Settled: the last sample still outside 2 percent of the travel; the next
    # one is the first inside, and that gap is the settle time.
    settle_t = None
    for i in range(len(samples) - 1, -1, -1):
        if abs(samples[i]["g"] - TARGET) > 0.02 * travel:
            settle_t = samples[i + 1]["t"] - start_t if i + 1 < len(samples) else None
            break
    if settle_t is None:
        settle_t = samples[-1]["t"] - start_t
    return {"peak": peak, "overshoot_pct": overshoot, "settle_ms": settle_t,
            "first": samples[0]["g"], "last": samples[-1]["g"]}


def return_metrics(samples):
    """After the return starts: monotone down to REST, never below it."""
    if not samples:
        return None
    below = min(s["g"] for s in samples)
    rises = 0
    for i in range(1, len(samples)):
        if samples[i]["g"] > samples[i - 1]["g"] + 1e-6:
            rises += 1
    settle_t = None
    for s in samples:
        if abs(s["g"] - REST) <= 0.02:
            settle_t = s["t"] - samples[0]["t"]
            break
    return {"min": below, "rises": rises, "settle_ms": settle_t,
            "last": samples[-1]["g"]}


def breath_period(samples):
    """Seconds between the two rising crossings of the mid level."""
    if not samples:
        return None
    b = [s["b"] for s in samples]
    hi = max(b)
    lo = min(b)
    mid = (hi + lo) / 2.0
    crossings = []
    for i in range(1, len(samples)):
        if b[i - 1] < mid <= b[i]:
            f = (mid - b[i - 1]) / (b[i] - b[i - 1])
            t = samples[i - 1]["t"] + f * (samples[i]["t"] - samples[i - 1]["t"])
            crossings.append(t)
    if len(crossings) < 2:
        return {"period_s": None, "crossings": crossings, "min": lo, "max": hi}
    span = crossings[-1] - crossings[0]
    cycles = len(crossings) - 1
    return {"period_s": span / cycles / 1000.0, "crossings": crossings,
            "min": lo, "max": hi}


def main(argv):
    trace = None
    if len(argv) >= 3 and argv[1] == "--json":
        with open(argv[2]) as f:
            for line in f:
                idx = line.find("TRACE ")
                if idx >= 0:
                    trace = json.loads(line[idx + len("TRACE "):])
    else:
        trace = run_probe()
    if trace is None:
        print("deck-trace: no trace payload", file=sys.stderr)
        return 64

    exp = trace["expand"]
    split = 0
    for i, s in enumerate(exp):
        if s["g"] > REST + 0.02:
            split = i
            break
    expand_samples = [s for s in exp if s["t"] < 3200]
    return_samples = [s for s in exp if s["t"] >= 3200]
    up = expand_metrics(expand_samples, exp[split]["t"])
    ret = return_metrics(return_samples)

    drift = trace["drift"]
    dx = [abs(s["dx"]) for s in drift]
    dy = [abs(s["dy"]) for s in drift]
    drift_max = max(dx + dy)
    drift_range = (max(s["dx"] for s in drift) - min(s["dx"] for s in drift),
                   max(s["dy"] for s in drift) - min(s["dy"] for s in drift))

    breath = breath_period(trace["breath"])

    print("== deck motion trace (samples: %d expand/drift, %d breath)"
          % (len(exp), len(trace["breath"])))
    print("   expand   peak %.4f  overshoot %+.2f %%  settle %s ms  (last %.4f)"
          % (up["peak"], up["overshoot_pct"], up["settle_ms"], up["last"]))
    print("   return   min %.4f  rises %d  settle %s ms  (last %.4f)"
          % (ret["min"], ret["rises"], ret["settle_ms"], ret["last"]))
    print("   drift    max |d| %.3f px  x-range %.3f  y-range %.3f"
          % (drift_max, drift_range[0], drift_range[1]))
    print("   breath   period %s s  (%d crossings, b %.3f..%.3f)"
          % (("%.3f" % breath["period_s"]) if breath["period_s"] else "none",
             len(breath["crossings"]), breath["min"], breath["max"]))
    print("   tokens   breathPeriod %.2f s  expand %d ms  return %d ms"
          % (trace["breathPeriodToken"], trace["expandMillisToken"],
             trace["returnMillisToken"]))

    ok = True
    if not (OVERSHOOT_BAND[0] <= up["overshoot_pct"] <= OVERSHOOT_BAND[1]):
        print("   FAIL overshoot %.2f %% outside %s" % (up["overshoot_pct"], OVERSHOOT_BAND))
        ok = False
    if ret["min"] < REST - 0.002 or ret["rises"] > 0:
        print("   FAIL return is not monotone to rest (min %.4f, %d rises)"
              % (ret["min"], ret["rises"]))
        ok = False
    if drift_max <= 0.05:
        print("   FAIL idle drift is flat (max %.3f px)" % drift_max)
        ok = False
    if breath["period_s"] is None or not (
            BREATH_BAND[0] <= breath["period_s"] <= BREATH_BAND[1]):
        print("   FAIL breath period %s outside %s" % (breath["period_s"], BREATH_BAND))
        ok = False
    print("   %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
