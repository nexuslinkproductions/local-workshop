#!/usr/bin/env python3
"""I1 deck motion evidence: overshoot, return, idle drift, breath period.

Two probes, each measured where it can be measured precisely (the reasoning and
the numbers are in `nexuslink.hud/v5/docs/motion.md`):

  tests/i1/CrewExpandTrace.qml   expand + return. The deck's own CrewOrb at the
                                 deck's size (224) and tokens, sampled on the
                                 probe's timer; the SAME easing read live off
                                 `CrewOrb.transitions[0].animations[0]` and
                                 re-run by the probe over 10x the duration; and
                                 the closed form of that curve evaluated in
                                 0.05 ms steps. The overshoot is reported from
                                 the stretched run and the closed form, because
                                 the offscreen frame clock here is 25 to 100 ms:
                                 a frame-only read of a 347 ms curve with a
                                 ~10 ms vertex under-reads by 0 to 3 points.
  tests/i1/DeckTrace.qml         idle drift and breath on the composed deck,
                                 whose periods are 5.8 s and 13 s, so the deck's
                                 ~100 ms grid is plenty there

    v5/tools/deck-trace.py              # 5 expand runs + the deck trace
    v5/tools/deck-trace.py --json DIR   # parse saved TRACE lines from DIR

Bands, checked on every run: expand overshoot 4 to 6 percent, return monotone
with no overshoot, idle drift non-zero, breath 5 to 6 s.

Exit status. The expand band is gated on the closed form only: the same OutBack
easing, read live off CrewOrb's running transition, evaluated analytically. The
offscreen frame clock on this Mac ticks every 25 to 100 ms, so a frame sample can
land 25 to 50 ms off a ~10 ms vertex and read low through no fault of the deck;
that is why the frame-sampled peak is reported as a two-sided bound (highest
sample to highest sample plus the vertex-miss allowance, with its sample count
and grid) instead of being a gate. The stretched read is reported the same way.
Exit 0 the closed-form gate passes on every run and the deck signals are in band,
1 a gate failed, 3 toolchain.
"""
import json
import os
import shutil
import statistics
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
RUNS = 5                       # expand attempts; every run is reported
FRAME_TOLERANCE_PP = 0.05      # slack on the frame bound, antialiasing/layout noise


def median(values):
    return statistics.median(values) if values else None


def outback(t, c):
    """Qt's QEasingCurve OutBack, the curve CrewOrb expands on."""
    u = t - 1.0
    return 1.0 + (c + 1.0) * u ** 3 + c * u ** 2


def outback_vertex(c):
    """t (0..1 of the duration) where OutBack peaks."""
    return 1.0 - 2.0 * c / (3.0 * (c + 1.0))


def outback_peak(c):
    return outback(outback_vertex(c), c)


def vertex_loss_pp(c, ms, duration):
    """Percent of travel a sample loses if it misses the vertex by `ms`."""
    t_v = outback_vertex(c)
    t = t_v + ms / float(duration)
    if t > 1.0:
        t = t_v - ms / float(duration)
    return (outback_peak(c) - outback(t, c)) * 100.0


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
        # kit components resolve their faces as ../fonts; through the module
        # symlink that is <imports>/NexusHud/fonts, so mirror v5/fonts there and
        # the probes measure the deck's real face, not a fallback one.
        os.symlink(os.path.join(V5, "fonts"), os.path.join(imports, "NexusHud", "fonts"))
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


def expand_metrics(trace):
    """Everything one expand run carries: frame read, stretched read, closed form.

    The frame samples are the real component at deck speed, but the offscreen
    frame clock is coarse, so their peak is a LOWER BOUND on the curve's peak.
    The stretched run samples the identical easing (read live off the running
    transition) over 10x the duration, which leaves every value where it was and
    multiplies every sample time by 10: an easing curve's peak does not depend on
    its duration. The closed form of the same curve at 0.05 ms steps is the
    clock-free third read, and it is what the band check runs on.
    """
    samples = trace["samples"]
    rest = float(trace.get("restGrowth", REST))
    target = float(trace["expandScale"])
    travel = target - rest
    t_off = trace.get("returnAtMs", 1000)
    anim = trace.get("animation") or {}
    qml_analytic = trace.get("analytic") or {}
    stretch_factor = int(trace.get("stretchFactor", 1) or 1)

    up = [s for s in samples if s["t"] < t_off]
    down = [s for s in samples if s["t"] >= t_off]
    m = {"rest": rest, "target": target, "travel": travel, "animation": anim,
         "qml_analytic": qml_analytic,
         "stretch_setup": trace.get("stretchSetup") or {},
         "frame_n": len(up), "return_n": len(down),
         "stretch_factor": stretch_factor,
         "expand_millis_token": trace.get("expandMillisToken"),
         "return_millis_token": trace.get("returnMillisToken"),
         "expand_overshoot_token": trace.get("expandOvershootToken", 0.0)}

    # ---- frame read (deck speed, clock-bound) -----------------------------
    if up:
        gaps = [b["t"] - a["t"] for a, b in zip(up, up[1:])]
        ticks = [b["t"] - a["t"] for a, b in zip(up, up[1:])
                 if abs(b["g"] - a["g"]) > 1e-12]
        peak_sample = max(up, key=lambda s: s["g"])
        start_i = 0
        for i, s in enumerate(up):
            if s["g"] > rest + 0.02 * travel:
                start_i = i
                break
        start_t = up[start_i]["t"]
        m["frame_grid_ms"] = (up[-1]["t"] - up[0]["t"]) / max(1, len(up))
        m["frame_tick_median_ms"] = median(ticks)
        m["frame_gap_max_ms"] = max(gaps) if gaps else None
        m["frame_peak"] = peak_sample["g"]
        m["frame_peak_frac"] = (peak_sample["g"] - rest) / travel
        m["frame_peak_pct"] = (m["frame_peak_frac"] - 1.0) * 100.0
        m["frame_peak_t_ms"] = peak_sample["t"] - start_t
        settle = None
        for i in range(len(up) - 1, 0, -1):
            if abs(up[i]["g"] - target) > 0.02 * travel:
                settle = up[i + 1]["t"] - start_t if i + 1 < len(up) else None
                break
        if settle is None:
            settle = up[-1]["t"] - start_t
        m["expand_settle_ms"] = settle
        m["expand_last"] = up[-1]["g"]

    # ---- stretched read (same easing, 10x the duration) --------------------
    stretch_at = trace.get("stretchAtMs", 0)
    st = [s for s in samples if s["t"] >= stretch_at and "s" in s]
    if st:
        best = max(st, key=lambda s: s["s"])
        spacing = [b["t"] - a["t"] for a, b in zip(st, st[1:])
                   if abs(b["s"] - a["s"]) > 1e-12]
        m["dense_n"] = len(st)
        m["dense_tick_median_ms"] = median(spacing)
        m["dense_grid_ms"] = (st[-1]["t"] - st[0]["t"]) / max(1, len(st))
        m["dense_equiv_ms"] = (m["dense_tick_median_ms"] / stretch_factor
                               if m["dense_tick_median_ms"] else None)
        m["dense_peak"] = best["s"]
        m["dense_peak_frac"] = (best["s"] - rest) / travel
        m["dense_peak_pct"] = (m["dense_peak_frac"] - 1.0) * 100.0
        m["dense_peak_t_ms"] = best["t"] - st[0]["t"]
        m["dense_end"] = st[-1]["s"]

    # ---- closed form of the same curve ------------------------------------
    c = float(anim.get("overshoot", 0.0))
    m["curve_c"] = c
    m["curve_peak_frac"] = outback_peak(c)
    m["curve_peak_pct"] = (outback_peak(c) - 1.0) * 100.0
    m["curve_peak_growth"] = rest + travel * outback_peak(c)
    m["curve_vertex_ms"] = outback_vertex(c) * float(anim.get("duration", 0) or 0)

    # ---- frame samples, as a two-sided bound on that peak ------------------
    # The highest frame sample is a floor on the peak (a sample cannot sit above
    # the curve's maximum), and the nearest frame can miss the vertex by at most
    # half the largest gap between distinct frames, which the closed form turns
    # into the most the sample could be under-reading. That interval is the
    # frame column of the report; it is evidence, not a gate, because its width
    # is the offscreen clock's, not the deck's.
    if "frame_peak_pct" in m:
        half_gap = (m.get("frame_gap_max_ms") or 0.0) / 2.0
        m["frame_half_gap_ms"] = half_gap
        m["frame_bound_pp"] = vertex_loss_pp(c, half_gap, float(anim.get("duration", 0) or 0))
        m["frame_lower_pct"] = m["frame_peak_pct"]
        m["frame_upper_pct"] = (m["frame_peak_pct"] + m["frame_bound_pp"]
                                + FRAME_TOLERANCE_PP)
        m["closed_form_in_frame_bound"] = (
            m["frame_lower_pct"] - 1e-9 <= m["curve_peak_pct"] <= m["frame_upper_pct"] + 1e-9)

    # ---- return leg (frame samples) ---------------------------------------
    if down:
        m["return_min"] = min(s["g"] for s in down)
        m["return_rises"] = sum(1 for a, b in zip(down, down[1:])
                                if b["g"] > a["g"] + 1e-6)
        rsettle = None
        for s in down:
            if abs(s["g"] - rest) <= 0.02:
                rsettle = s["t"] - down[0]["t"]
                break
        m["return_settle_ms"] = rsettle
        m["return_last"] = down[-1]["g"]
    return m


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


def run_checks(m):
    """The gate: everything here is clock-free. Returns a list of failure strings.

    What is *not* here, on purpose: the frame-sampled peak and the stretched read.
    Both are real samples of the deck's curve, but both are read through the
    offscreen frame clock (25 to 100 ms ticks here), so a low reading means the
    frame landed off the vertex, not that the deck changed. They are printed per
    run as a two-sided bound with their sample counts. A curve that actually
    moved is caught here anyway: the closed form is built from the easing object
    read live off the running transition, so its type is gated directly, its
    parameter through the peak landing inside the band, and the band itself.
    The one frame-side check that IS a gate is the impossible direction: a frame
    sample cannot sit above the curve's maximum, so a lower bound above the
    closed-form peak means the analytic model understates the deck.
    """
    fails = []
    setup = m["stretch_setup"]
    anim = m["animation"]
    if anim.get("error"):
        fails.append("live transition read failed: %s" % anim["error"])
    if anim.get("easingName") != "OutBack":
        fails.append("transition easing is %s, not OutBack" % anim.get("easingName"))
    if not setup.get("ok"):
        fails.append("stretched copy does not carry the live parameters: %r" % (setup,))
    qml_pct = (m["qml_analytic"] or {}).get("overshootPct")
    if qml_pct is None:
        fails.append("probe carried no closed-form peak: %r"
                     % ((m["qml_analytic"] or {}).get("error"),))
    elif abs(qml_pct - m["curve_peak_pct"]) > 1e-6:
        fails.append("probe closed form %.6f %% and this tool's %.6f %% disagree"
                     % (qml_pct, m["curve_peak_pct"]))
    if not (OVERSHOOT_BAND[0] <= m["curve_peak_pct"] <= OVERSHOOT_BAND[1]):
        fails.append("closed-form overshoot %+.3f %% outside %s"
                     % (m["curve_peak_pct"], OVERSHOOT_BAND))
    # Presence, not timing: a probe that produced no stretched samples has not
    # read the live transition at all.
    if "dense_peak_pct" not in m:
        fails.append("no stretched samples (the same easing over 10x the duration)")
    # The return leg is sampled on the frame clock too, but its property is
    # monotonicity towards rest, which a coarse clock cannot fake: a sample above
    # rest or a rise between samples is the deck, not the sampler.
    if m.get("return_rises", 1) > 0 or m.get("return_min", 0.0) < m["rest"] - 0.002:
        fails.append("return not monotone to rest (min %.4f, %d rises)"
                     % (m.get("return_min", -1), m.get("return_rises", -1)))
    # The only frame-side direction that is a gate: a sample can sit at or below
    # the curve's maximum but never above it, so a lower bound above the closed
    # form means the analytic model is wrong, not the clock. A late frame cannot
    # trip this, so it does not bring the round-2 failure mode back.
    if ("frame_lower_pct" in m
            and m["frame_lower_pct"] > m["curve_peak_pct"] + FRAME_TOLERANCE_PP):
        fails.append("a frame sample reads %+.3f %%, above the closed-form peak"
                     " %+.3f %%: the curve understates the deck"
                     % (m["frame_lower_pct"], m["curve_peak_pct"]))
    return fails


def bound_note(m):
    """The frame column, as evidence: a two-sided bound, never a pass/fail."""
    if "frame_lower_pct" not in m:
        return "frame none"
    inside = m.get("closed_form_in_frame_bound")
    return ("frame bound [%+.3f %%, %+.3f %%] from %d samples over a %.1f ms grid"
            " (max gap %.1f ms, vertex-miss allowance %.3f pp); closed form inside: %s"
            % (m["frame_lower_pct"], m["frame_upper_pct"], m["frame_n"],
               m["frame_grid_ms"], m["frame_gap_max_ms"] or 0.0, m["frame_bound_pp"],
               "yes" if inside else "no (frame samples contradict the curve)"))


def dense_note(m):
    if "dense_peak_pct" not in m:
        return "stretched none"
    return ("stretched read %+.3f %% (%d samples, %.1f ms grid = %.1f ms on the deck's"
            " %.0f ms timeline)"
            % (m["dense_peak_pct"], m["dense_n"], m["dense_tick_median_ms"],
               m["dense_equiv_ms"], m["animation"].get("duration", 0)))


def print_run(index, total, m, fails):
    print("   run %d/%d  closed form %+.3f %%  peak %.7f at %d ms  %s"
          % (index, total, m["curve_peak_pct"], m["curve_peak_growth"],
             round(m["curve_vertex_ms"]),
             "in band" if not fails else "GATE FAILED: " + "; ".join(fails)))
    print("            %s" % dense_note(m))
    print("            %s" % bound_note(m))


def main(argv):
    deck = expand = None
    if len(argv) >= 3 and argv[1] == "--json":
        deck, expand = read_json_traces(argv[2])
        if expand is None or deck is None:
            print("deck-trace: missing a trace in %s" % argv[2], file=sys.stderr)
            return 3
        metrics = [expand_metrics(expand)]
    else:
        metrics = []
        for i in range(RUNS):
            trace = run_probe(EXPAND_PROBE)
            if trace is None:
                continue
            metrics.append(expand_metrics(trace))
        deck = run_probe(DECK_PROBE)

    if not metrics or deck is None:
        print("deck-trace: missing a trace", file=sys.stderr)
        return 3

    ok = True
    first = metrics[0]
    print("== expand/return  (%d runs; curve read live off %s: %s %s over %d ms,"
          " rest %.1f -> %.1f)"
          % (len(metrics), first["animation"].get("source", "the component"),
             first["animation"].get("easingName", "?"),
             first["animation"].get("overshoot", "?"),
             first["animation"].get("duration", 0), first["rest"], first["target"]))
    per_run_fails = []
    for i, m in enumerate(metrics, 1):
        fails = run_checks(m)
        per_run_fails.append(fails)
        print_run(i, len(metrics), m, fails)
        if fails:
            ok = False
    # The gate, one line the repro can grep: clock-free, so it does not move
    # between runs and cannot fail on where the offscreen frame clock landed.
    print("   closed-form gate, every run: %s  (band %.0f to %.0f %%)"
          % (" ".join("%+.3f %%" % m["curve_peak_pct"] for m in metrics),
             OVERSHOOT_BAND[0], OVERSHOOT_BAND[1]))
    frames = [m["frame_lower_pct"] for m in metrics if "frame_lower_pct" in m]
    print("   frame evidence, not a gate: %d runs, lower bound %s, %d to %d samples"
          " per run, %s closed-form readings inside their own frame bound"
          % (len(frames),
             "%.3f to %.3f %%" % (min(frames), max(frames)) if frames else "none",
             min((m["frame_n"] for m in metrics), default=0),
             max((m["frame_n"] for m in metrics), default=0),
             "%d of %d" % (sum(1 for m in metrics if m.get("closed_form_in_frame_bound")),
                           len(frames))))

    dense = max((m for m in metrics if "dense_peak_pct" in m),
                key=lambda m: m.get("dense_n", 0), default=first)
    print("   expand   peak %.7f at %d ms  overshoot %+.3f %%  settle %s ms"
          % (dense["curve_peak_growth"], round(dense["curve_vertex_ms"]),
             dense["curve_peak_pct"], dense.get("expand_settle_ms")))
    print("   return   min %.4f  rises %d  settle %s ms  last %.4f  (frame samples)"
          % (dense.get("return_min", float("nan")), dense.get("return_rises", -1),
             dense.get("return_settle_ms"), dense.get("return_last", float("nan"))))
    print("   tokens   expand %d ms  return %d ms  (Motion.expandOvershoot %.2f %% is the"
          " spring band; the curve the deck runs is OutBack %s = %+.3f %% peak)"
          % (dense["animation"].get("duration", 0),
             dense.get("return_millis_token", 0),
             dense.get("expand_overshoot_token", 0.0) * 100.0,
             dense["animation"].get("overshoot", "?"), dense["curve_peak_pct"]))

    drift = deck["drift"]
    drift_max = max(max(abs(s["dx"]) for s in drift), max(abs(s["dy"]) for s in drift))
    drift_ranges = (max(s["dx"] for s in drift) - min(s["dx"] for s in drift),
                    max(s["dy"] for s in drift) - min(s["dy"] for s in drift))
    breath = breath_period(deck["breath"])
    grid_deck = (deck["breath"][-1]["t"] - deck["breath"][0]["t"]) / max(1, len(deck["breath"]))

    print("== deck          (%d breath samples, %.1f ms grid)" % (len(deck["breath"]), grid_deck))
    print("   drift    max |d| %.3f px  x-range %.3f  y-range %.3f"
          % (drift_max, drift_ranges[0], drift_ranges[1]))
    print("   breath   period %s s  (%d crossings, b %.3f..%.3f)"
          % (("%.3f" % breath["period_s"]) if breath["period_s"] else "none",
             len(breath["crossings"]), breath["min"], breath["max"]))
    print("   tokens   breathPeriod %.2f s" % deck["breathPeriodToken"])

    if drift_max <= 0.05:
        print("   FAIL idle drift flat (max %.3f px)" % drift_max)
        ok = False
    if breath["period_s"] is None or not (BREATH_BAND[0] <= breath["period_s"] <= BREATH_BAND[1]):
        print("   FAIL breath period %s outside %s" % (breath["period_s"], BREATH_BAND))
        ok = False
    print("   %s  (gate: closed form in band, live OutBack identity, monotone return;"
          " deck drift and breath in band)" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
