#!/usr/bin/env python3
"""W3 gauge motion evidence: the four gauges' focus / selection motion, measured.

PulseRing, DotArc, DotBar and IconTile handed Qt 6.12's SpringAnimation the
analytic pair (spring = expandOmega^2 = 278.89, damping = 2 * expandZeta * omega
= 23.05). Qt 6.12 clamps `damping` to [0, 1] and applies the spring term without
a dt factor, so the pair is not the 5.00 percent / 347 ms Motion states, it is a
barely damped explicit Euler spring. This tool measures each component from three
angles:

  measured   tests/w3/GaugeSpringTrace.qml, run offscreen, samples the component's
             own animated value on the QML runtime's clock. That clock is coarse:
             on this Mac the offscreen qml runtime fires a 4 ms Timer every 20 to
             150 ms (worst right at the trigger, where the animation driver takes
             over), so a 347 ms curve is resolved to about 30 ms. Fine for
             divergence and for reaching the target, too coarse to read a 4.87
             percent peak exactly.
  closed     the exact value the curve evaluates at every 8 ms, computed from the
             parameters the component printed in its TRACE line
             (expandBackOvershoot, Motion.expandMillis, the lift), so this column
             cannot drift away from the QML that ran.
  agreement  the measured samples scored against that closed form at the same
             timestamps over the best-fit phase offset. This is what ties the
             runtime to the curve: a green closed form cannot hide a component
             that animates something else.

    v5/tools/w3-gauge-spring-trace.py                  # every run
    v5/tools/w3-gauge-spring-trace.py --json DIR       # also save the raw TRACE lines
    v5/tools/w3-gauge-spring-trace.py --parse FILE     # score saved TRACE lines only
    v5/tools/w3-gauge-spring-trace.py --only dotarc    # one component

Bands (MAIN-SCREEN-BUILD.md): a scale lift expands with 4 to 6 percent overshoot,
every return is monotone with no overshoot, and no run leaves the scale range
(|value| under 1.5) on any frame, including a 150 ms stalled one. The tile's dim
channel is a fade, not a lift: monotone with no overshoot in both directions (the
kit's return spec is critically damped).

Exit: 0 all in band, 1 a band missed, 3 toolchain.
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
PROBE = os.path.join(V5, "tests", "w3", "GaugeSpringTrace.qml")

OVERSHOOT_BAND = (4.0, 6.0)      # percent of the travel, the Motion expand band
MONOTONE_TOL = 0.5               # percent of the travel: below this is sampler noise
AGREE_TOL = 4.0                  # percent of the travel: measured vs closed form
AGREE_SHIFT_MS = 80              # the animation starts on the frame after the trigger
GRID_MS = 8                      # the card's trace grid
STALL_MS = 150                   # the late frame W2 measured the old spring on
DIVERGED = 1.5                   # |value| above this is not a scale any more
REACHED_TOL = 2.0                # percent of the travel: settled at the target

COMPONENTS = ["pulsering", "dotarc", "dotbar", "icontile"]

# (channel, mode, stall, band)
#   band "lift"  the component expands on the measured curve: 4 to 6 percent
#   band "fade"  a fade/dim: monotone both ways, no overshoot
RUNS = []
for _c in COMPONENTS:
    RUNS.append((_c, "scale", "expand", 0, "lift"))
    RUNS.append((_c, "scale", "expand", STALL_MS, "lift"))
    RUNS.append((_c, "scale", "return", 0, "lift"))
# IconTile's second channel: focusLevel drives its own opacity down to 0.30.
RUNS.append(("icontile", "dim", "expand", 0, "fade"))
RUNS.append(("icontile", "dim", "expand", STALL_MS, "fade"))
RUNS.append(("icontile", "dim", "return", 0, "fade"))


def qml_bin():
    for candidate in (os.environ.get("QML_QT_BIN"), "/opt/homebrew/opt/qt/bin/qml",
                      shutil.which("qml")):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def run_probe(component, channel, mode, stall, band):
    qml = qml_bin()
    if not qml:
        print("w3-gauge-spring-trace: no qml binary (set QML_QT_BIN)", file=sys.stderr)
        sys.exit(3)
    imports = tempfile.mkdtemp(prefix="w3-gauge-imports.")
    try:
        os.makedirs(os.path.join(imports, "NexusHud"), exist_ok=True)
        os.symlink(os.path.join(V5, "kit"), os.path.join(imports, "NexusHud", "V5"))
        env = dict(os.environ)
        env["QT_QPA_PLATFORM"] = "offscreen"
        env["QML_IMPORT_PATH"] = imports
        args = [qml, "-I", imports, PROBE, "--",
                "--component=" + component, "--channel=" + channel,
                "--mode=" + mode, "--stall=%d" % stall]
        proc = subprocess.run(args, cwd=REPO, env=env, capture_output=True,
                              text=True, timeout=240)
    finally:
        shutil.rmtree(imports, ignore_errors=True)
    for line in (proc.stdout + proc.stderr).splitlines():
        idx = line.find("TRACE ")
        if idx >= 0:
            trace = json.loads(line[idx + len("TRACE "):])
            trace["band"] = band
            return trace
    print("w3-gauge-spring-trace: no TRACE line from %s/%s/%s (exit %d)\n%s"
          % (component, channel, mode, proc.returncode,
             (proc.stdout + proc.stderr)[-2000:]), file=sys.stderr)
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
    """Peak, overshoot, settle and divergence for one trace.

    Both directions are scored the same way: `overshoot_pct` is how far the value
    goes PAST the target as a share of the travel, `backlash_pct` is how far it
    recoils past the value it started from. A monotone run scores 0 on both.
    """
    span = end - start
    mag = abs(span) if span else 1.0
    vs = [s["v"] for s in samples]
    peak, trough = max(vs), min(vs)
    if span >= 0:
        overshoot = (peak - end) / mag * 100.0
        backlash = (start - trough) / mag * 100.0
    else:
        overshoot = (end - trough) / mag * 100.0
        backlash = (peak - start) / mag * 100.0
    settle = 0
    for s in samples:
        if abs(s["v"] - end) > 0.02 * mag:
            settle = s["t"]
    return {
        "peak": peak,
        "trough": trough,
        "overshoot_pct": overshoot,
        "backlash_pct": backlash,
        "settle_ms": settle,
        "final": vs[-1] if vs else float("nan"),
        "max_abs": max(abs(v) for v in vs) if vs else 0.0,
        "diverged": (max(abs(v) for v in vs) > DIVERGED) if vs else False,
    }


def agreement(samples, start, end, duration, curve, max_shift=AGREE_SHIFT_MS):
    """How far the measured samples sit from the closed form, best phase offset.

    Two things shift the curve against the sample clock and both are fitted out
    rather than assumed: the animation starts on the frame after the trigger
    (a few ms), and a stalled frame jumps the animation clock by the whole stall
    (the driver advances by elapsed wall time on its next tick), so a 150 ms
    stall shows up as a +150 ms offset. Returns (shift_ms, max deviation in
    percent of the travel, samples used).
    """
    span = abs(end - start) or 1.0
    best = (0, None, 0)
    for shift in range(-max_shift, max_shift + 1, 4):
        dev = 0.0
        used = 0
        for s in samples:
            t = s["t"] - shift
            if t < 0 or t > duration:
                continue
            expect = start + (end - start) * curve(t / float(duration))
            dev = max(dev, abs(s["v"] - expect))
            used += 1
        if used and (best[1] is None or dev < best[1]):
            best = (shift, dev, used)
    if best[1] is None:
        return (0, None, 0)
    return (best[0], best[1] / span * 100.0, best[2])


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


def main(argv):
    json_dir = None
    parse_file = None
    only = None
    i = 0
    while i < len(argv):
        if argv[i] == "--json" and i + 1 < len(argv):
            json_dir, i = argv[i + 1], i + 2
        elif argv[i] == "--parse" and i + 1 < len(argv):
            parse_file, i = argv[i + 1], i + 2
        elif argv[i] == "--only" and i + 1 < len(argv):
            only, i = argv[i + 1], i + 2
        else:
            print("usage: w3-gauge-spring-trace.py [--json DIR] [--parse FILE] [--only NAME]",
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
        for component, channel, mode, stall, band in RUNS:
            if only and component != only:
                continue
            trace = run_probe(component, channel, mode, stall, band)
            traces.append(trace)
            if json_dir:
                name = "%s-%s-%s%s" % (component, channel, mode,
                                       "-stall%d" % stall if stall else "")
                with open(os.path.join(json_dir, name + ".json"), "w") as fh:
                    fh.write("TRACE " + json.dumps(trace, sort_keys=True) + "\n")

    failures = []
    rows = []
    for trace in traces:
        component = trace.get("component", "?")
        channel = trace.get("channel", "scale")
        mode = trace.get("mode", "expand")
        band = trace.get("band", "lift")
        start, after = frames(trace)
        end = float(trace.get("toValue", 1.0))
        low, high = grid_ms(trace)
        measured = score(after, start, end)
        span = abs(end - start) or 1.0

        if channel == "dim":
            detail = "dim to %.2f" % float(trace.get("focusDimMax") or 0)
        else:
            detail = "focus lift %.0f percent" % (float(trace.get("focusLift") or 0) * 100)

        print("\n== %s ==" % trace.get("label", "%s/%s/%s" % (component, channel, mode)))
        print("  component  %s %d px, %s channel, %s"
              % (component, trace.get("sizePx", 0), channel, detail))
        print("  run        %s -> %s over %s, %d samples, grid %d to %d ms, stall %d ms"
              % (("%.6f" % start), ("%.6f" % end), mode, len(trace["samples"]), low, high,
                 trace.get("stallMs", 0)))

        if measured["diverged"]:
            print("  measured   DIVERGED: max|v| %.3g on a scale that has to stay near 1.0"
                  % measured["max_abs"])
            print("  closed     skipped: the measured run already left the scale range")
            print("  verdict    fail: divergence, no late frame needed")
            failures.append("%s/%s/%s: value diverged (max|v| %.3g)"
                            % (component, channel, mode, measured["max_abs"]))
            rows.append((component, channel, mode, trace.get("stallMs", 0),
                         "DIVERGED", "DIVERGED", "%.3g" % measured["max_abs"],
                         "n/a", "fail"))
            continue

        print("  measured   peak %.6f  trough %.6f  target %+6.2f %%  start %+6.2f %%  "
              "settle %4d ms  max|v| %.6f"
              % (measured["peak"], measured["trough"], measured["overshoot_pct"],
                 measured["backlash_pct"], measured["settle_ms"], measured["max_abs"]))

        # ---- closed form from the parameters the component printed ----------
        back = float(trace.get("expandBackOvershoot") or 0)
        if mode == "expand" and band == "lift" and back:
            duration = trace.get("expandMillis")
            curve = functools.partial(ease_outback, overshoot=back)
            curve_name = "OutBack %.2f" % back
        elif mode == "return" or band == "fade":
            duration = trace.get("returnMillis")
            curve = ease_outcubic
            curve_name = "OutCubic"
        else:
            duration = None
            curve = None
            curve_name = ""

        if not (duration and curve):
            print("  closed     skipped: the component published no motion parameters")
            print("  verdict    fail: no parameters, nothing to compare")
            failures.append("%s/%s/%s: component published no motion parameters"
                            % (component, channel, mode))
            rows.append((component, channel, mode, trace.get("stallMs", 0),
                         "n/a", "n/a", "%.6f" % measured["max_abs"], "n/a", "fail"))
            continue

        closed = analytic(start, end, duration, curve)
        stats = score(closed, start, end)
        print("  closed     peak %.6f  trough %.6f  target %+6.2f %%  start %+6.2f %%  "
              "settle %4d ms  (%s over %d ms, %d samples at %d ms)"
              % (stats["peak"], stats["trough"], stats["overshoot_pct"],
                 stats["backlash_pct"], stats["settle_ms"], curve_name, duration,
                 len(closed), GRID_MS))
        agree = agreement(after, start, end, duration, curve,
                          AGREE_SHIFT_MS + int(trace.get("stallMs") or 0))
        if agree[1] is None:
            print("  agreement  no measured sample landed inside the curve window")
        else:
            print("  agreement  measured vs closed max deviation %.2f %% of the travel "
                  "at a %+d ms phase offset (%d samples)"
                  % (agree[1], agree[0], agree[2]))

        # ---- verdict -------------------------------------------------------
        problems = []
        if band == "lift" and mode == "expand":
            if not OVERSHOOT_BAND[0] <= stats["overshoot_pct"] <= OVERSHOOT_BAND[1]:
                problems.append("closed overshoot %.2f %% outside %.0f-%.0f"
                                % (stats["overshoot_pct"], *OVERSHOOT_BAND))
        else:
            past = max(stats["overshoot_pct"], stats["backlash_pct"])
            if past > MONOTONE_TOL:
                problems.append("%s %.2f %% past the target (band %.1f)"
                                % (curve_name, past, MONOTONE_TOL))
        if agree[1] is None:
            problems.append("no sample inside the %d ms curve" % duration)
        elif agree[1] > AGREE_TOL:
            problems.append("measured deviates %.2f %% from the closed form (band %.1f)"
                            % (agree[1], AGREE_TOL))
        if abs(measured["final"] - end) > REACHED_TOL / 100.0 * span:
            problems.append("settled at %.6f, not the target %.6f"
                            % (measured["final"], end))

        if problems:
            print("  verdict    fail: " + "; ".join(problems))
            failures.extend("%s/%s/%s: %s" % (component, channel, mode, p)
                            for p in problems)
            verdict = "FAIL"
        else:
            if band == "lift" and mode == "expand":
                print("  verdict    ok: %.2f %% peak overshoot in the %.0f-%.0f band"
                      % (stats["overshoot_pct"], *OVERSHOOT_BAND))
            elif mode == "return":
                print("  verdict    ok: monotone return to %.6f, nothing past the target"
                      % end)
            else:
                print("  verdict    ok: monotone fade to %.6f, nothing past the target"
                      % end)
            verdict = "ok"
            if trace.get("stallMs"):
                print("  stalled    a %d ms late frame at the trigger: peak bounded by "
                      "%.6f, the next value is the curve at its true elapsed time"
                      % (trace.get("stallMs", 0), stats["peak"]))
        rows.append((component, channel, mode, trace.get("stallMs", 0),
                     "%+.2f" % stats["overshoot_pct"], "%+.2f" % stats["backlash_pct"],
                     "%.6f" % measured["max_abs"],
                     "%.2f" % agree[1] if agree[1] is not None else "n/a", verdict))

    print("\n== summary ==")
    print("  %-10s %-6s %-7s %5s %8s %8s %10s %7s  %s"
          % ("component", "chan", "mode", "stall", "target+", "start+", "max|v|",
             "dev %", "verdict"))
    for r in rows:
        print("  %-10s %-6s %-7s %5d %8s %8s %10s %7s  %s" % r)
    if failures:
        print("\nFAIL")
        for f in failures:
            print("  " + f)
        return 1
    print("\nPASS: lift expand inside %.0f-%.0f percent, every return and fade monotone, "
          "measured inside %.0f percent of the closed form, no divergence on a stalled frame"
          % (OVERSHOOT_BAND + (AGREE_TOL,)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
