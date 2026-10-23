#!/usr/bin/env python3
"""W3 motion evidence: LocalOrb's sphere-field scale, measured and closed form.

The repair card asked for a growth trace with the overshoot percentage, the
settle time and a note on a stalled frame. This tool produces that evidence from
two independent angles:

  measured   tests/w3/LocalOrbTrace.qml, run offscreen, samples
             LocalOrb.fieldScale on the QML runtime's own grid (6 to 50 ms; the
             runtime will not hold a fixed 8 ms, which is why the second column
             exists)
  closed     the exact value the same easing evaluates at every 8 ms, computed
             from the component's own parameters as printed in the TRACE line
             (expandOvershoot, Motion.expandMillis, the lift), so this column
             cannot drift away from the QML

    v5/tools/w3-localorb-trace.py                 # run all four probes
    v5/tools/w3-localorb-trace.py --json DIR      # also save the raw TRACE lines
    v5/tools/w3-localorb-trace.py --parse FILE    # score saved TRACE lines only

Bands (MAIN-SCREEN-BUILD.md): expand overshoot 4 to 6 percent, return monotone
with no overshoot, and no divergence (|value| under 1.5) on any frame including
a 150 ms stalled one. Exit 0 all in band, 1 a band missed, 3 toolchain.
"""
import functools
import json
import os
import shutil
import subprocess
import sys
import tempfile

V5 = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO = os.path.abspath(os.path.join(V5, "..", ".."))
PROBE = os.path.join(V5, "tests", "w3", "LocalOrbTrace.qml")

OVERSHOOT_BAND = (4.0, 6.0)      # percent, the Motion expand band
GRID_MS = 8                      # the card's trace grid
STALL_MS = 150                   # the late frame W2 measured the old spring on
DIVERGED = 1.5                   # |value| above this is not a scale any more

RUNS = [
    ("expand", "trace-expand.qml"),
    ("expand-stall150", "trace-expand-stall150.qml"),
    ("return", "trace-return.qml"),
    ("focus", "trace-focus.qml"),
]


def qml_bin():
    for candidate in (os.environ.get("QML_QT_BIN"), "/opt/homebrew/opt/qt/bin/qml",
                      shutil.which("qml")):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def run_probe(entry):
    qml = qml_bin()
    if not qml:
        print("w3-localorb-trace: no qml binary (set QML_QT_BIN)", file=sys.stderr)
        sys.exit(3)
    probe_path = os.path.join(V5, "tests", "w3", entry)
    imports = tempfile.mkdtemp(prefix="w3-trace-imports.")
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
    print("w3-localorb-trace: no TRACE line from %s (exit %d)\n%s"
          % (entry, proc.returncode, (proc.stdout + proc.stderr)[-2000:]),
          file=sys.stderr)
    sys.exit(3)


# ---- closed form ---------------------------------------------------------
# Qt's Easing.OutBack: u = t - 1; u^2 * ((s + 1) * u + s) + 1, t in 0..1 and
# s = Easing.overshoot. The same polynomial QEasingCurve::easeOutBack evaluates.
def ease_outback(p, overshoot):
    u = p - 1.0
    return u * u * ((overshoot + 1.0) * u + overshoot) + 1.0


def ease_outcubic(p):
    return 1.0 - (1.0 - p) ** 3


def analytic(start, end, duration_ms, curve, grid_ms=GRID_MS):
    """The exact animation value at every grid step, including t = duration."""
    out = []
    t = 0
    while t <= duration_ms:
        out.append({"t": t, "v": start + (end - start) * curve(t / float(duration_ms))})
        t += grid_ms
    return out


# ---- scoring -------------------------------------------------------------
def score(samples, start, end):
    """Peak, overshoot, settle and divergence for one trace."""
    span = end - start
    vs = [s["v"] for s in samples]
    peak, trough = max(vs), min(vs)
    if span > 0:
        overshoot = (peak - end) / span * 100.0
        undershoot = (end - trough) / span * 100.0
    else:
        overshoot = (start - trough) / -span * 100.0
        undershoot = (peak - start) / -span * 100.0
    settle = 0
    for s in samples:
        if abs(s["v"] - end) > 0.02 * abs(span):
            settle = s["t"]
    return {
        "peak": peak,
        "trough": trough,
        "overshoot_pct": overshoot,
        "undershoot_pct": undershoot,
        "settle_ms": settle,
        "final": vs[-1],
        "max_abs": max(abs(v) for v in vs),
        "diverged": max(abs(v) for v in vs) > DIVERGED,
    }


def frames(trace):
    """Split the trace at the trigger; post-trigger times are rebased to it."""
    at = trace.get("stalledAtMs") or 0
    before = [s for s in trace["samples"] if s["t"] < at]
    after = [{"t": s["t"] - at, "v": s["v"]} for s in trace["samples"] if s["t"] >= at]
    start = before[-1]["v"] if before else (after[0]["v"] if after else 1.0)
    return start, after


def grid_ms(trace):
    gaps = [b["t"] - a["t"] for a, b in zip(trace["samples"], trace["samples"][1:])]
    return (min(gaps), max(gaps)) if gaps else (0, 0)


def endpoints(trace):
    """The two scale values the run animates between, from the component."""
    mode = trace.get("mode", "expand")
    start, _ = frames(trace)
    lift = float(trace.get("activityLift") or 0.08)
    if mode == "focus":
        return start, start + float(trace.get("focusLift") or 0.04)
    if mode == "return":
        return start, 1.0
    return start, start + lift


def main(argv):
    json_dir = None
    parse_file = None
    i = 0
    while i < len(argv):
        if argv[i] == "--json" and i + 1 < len(argv):
            json_dir, i = argv[i + 1], i + 2
        elif argv[i] == "--parse" and i + 1 < len(argv):
            parse_file, i = argv[i + 1], i + 2
        else:
            print("usage: w3-localorb-trace.py [--json DIR] [--parse FILE]",
                  file=sys.stderr)
            return 64
    if json_dir:
        os.makedirs(json_dir, exist_ok=True)

    traces = []
    if parse_file:
        with open(parse_file) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("TRACE "):
                    traces.append(json.loads(line[len("TRACE "):]))
    else:
        for label, entry in RUNS:
            trace = run_probe(entry)
            trace["label"] = label
            traces.append(trace)
            if json_dir:
                with open(os.path.join(json_dir, label + ".json"), "w") as fh:
                    fh.write("TRACE " + json.dumps(trace, sort_keys=True) + "\n")

    failures = []
    for trace in traces:
        mode = trace.get("mode", "expand")
        start, after = frames(trace)
        end = endpoints(trace)[1]
        low, high = grid_ms(trace)
        measured = score(after, start, end)
        nominal = float(trace.get("focusLift" if mode == "focus" else "activityLift",
                                  0.04 if mode == "focus" else 0.08))
        print("\n== %s ==" % trace.get("label", mode))
        print("  component  LocalOrb %d px, sizeGb %.2f, %.0f percent lift"
              % (trace.get("sizePx", 0), trace.get("sizeGb", 0), nominal * 100.0))
        print("  measured   %d samples, grid %d to %d ms, stall %d ms"
              % (len(trace["samples"]), low, high, trace.get("stallMs", 0)))
        if measured["diverged"]:
            print("  measured   DIVERGED: max|v| %.3g on a value that has to stay near 1.0"
                  % measured["max_abs"])
            failures.append("%s: value diverged (max|v| %.3g)" % (mode, measured["max_abs"]))
            print("  closed     skipped: the measured run already left the scale range")
            continue
        if mode == "return":
            print("  measured   rest %.6f  below-rest %.2f %%  settle %4d ms  max|v| %.6f"
                  % (end, measured["undershoot_pct"], measured["settle_ms"],
                     measured["max_abs"]))
        else:
            print("  measured   peak %.6f  overshoot %+6.2f %%  settle %4d ms  max|v| %.6f"
                  % (measured["peak"], measured["overshoot_pct"], measured["settle_ms"],
                     measured["max_abs"]))

        if mode == "return":
            duration = trace.get("returnMillis")
            curve = ease_outcubic
        else:
            duration = trace.get("expandMillis")
            overshoot = trace.get("expandOvershoot")
            curve = functools.partial(ease_outback, overshoot=overshoot) if overshoot else None
        if not (duration and curve):
            print("  closed     skipped: the component did not publish its parameters")
            continue
        closed = analytic(start, end, duration, curve)
        stats = score(closed, start, end)
        if mode == "return":
            print("  closed     rest %.6f  below-rest %.2f %%  settle %4d ms  "
                  "(%d ms curve, %d samples at %d ms)"
                  % (end, stats["undershoot_pct"], stats["settle_ms"], duration,
                     len(closed), GRID_MS))
        else:
            print("  closed     peak %.6f  overshoot %+6.2f %%  settle %4d ms  "
                  "(%d ms curve, %d samples at %d ms)"
                  % (stats["peak"], stats["overshoot_pct"], stats["settle_ms"], duration,
                     len(closed), GRID_MS))
        if mode in ("expand", "focus"):
            if not OVERSHOOT_BAND[0] <= stats["overshoot_pct"] <= OVERSHOOT_BAND[1]:
                failures.append("%s: overshoot %.2f %% outside %.0f-%.0f"
                                % (mode, stats["overshoot_pct"], *OVERSHOOT_BAND))
            if mode == "expand" and not trace.get("stallMs"):
                print("  trace      every %d ms:" % GRID_MS)
                for s in closed:
                    print("               %4d ms  %.6f   %+6.2f %% of the lift"
                          % (s["t"], s["v"], (s["v"] - start) / (end - start) * 100))
        if mode == "return" and stats["undershoot_pct"] > 0.5:
            failures.append("return: %s overshoots on the way down (%.2f %%)"
                            % ("closed form", stats["undershoot_pct"]))
        if mode == "expand" and trace.get("stallMs"):
            print("  stalled    a %d ms late frame at the trigger: peak stays bounded by "
                  "%.6f and the value at the next frame is the curve at its true "
                  "elapsed time" % (trace.get("stallMs", 0), stats["peak"]))
            if measured["diverged"]:
                failures.append("stalled frame: value left the scale range")

    if failures:
        print("\nFAIL")
        for f in failures:
            print("  " + f)
        return 1
    print("\nPASS: expand inside %.0f-%.0f percent, return monotone, no divergence on a "
          "stalled frame" % OVERSHOOT_BAND)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
