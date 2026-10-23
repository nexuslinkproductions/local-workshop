#!/usr/bin/env python3
"""knot_report.py: numeric gates R1..R8 of KNOT-SPEC-R4 section 4.

Every gate prints the band the code really tests, taken from the same
expression the code evaluates (no hand written target that drifts from it).
The round 3 M gates are withdrawn: see README.md in this directory.

  R1  yaw equivalent angle (atan of the measured centroid x span over the
      270 px knot radius) at most atan(2.0 / 270) deg; pitch and roll peak
      to peak <= 4 deg each over 240 s; global scale peak to peak <= 0.8
      percent with a period in 6 to 8 s
  R1c centroid drift from the port positions: x span of the centroid of
      all dots over the hold windows (t in [0,33) and [60,93)) <= 2.0 px,
      y span over those windows <= 3.0 px, x span over 0..120 s <= 3.0 px
  R2  max per frame displacement of ANY dot, 24 fps, t = 0..120 s with the
      morph running, at knotPx 540 < 1.6 px
  R3  local activity in the HOLD windows only (morph weight 0 or 1):
      peak |local| in [7, 10.8] px, mean in [2.0, 5.0] px,
      99th percentile <= 9 px
  R4  max change of the per frame displacement vector between consecutive
      frames (acceleration) over 0..120 s at 24 fps < 0.35 px per frame^2
  R5  morph present: at x = 1 the mean screen displacement from the hold
      form >= 20 px (form 1) and >= 35 px (form 2); nominal triquetra hold
      fraction from the schedule constants (HOLD_A / CYC) in
      [0.50, 0.60]; per point morph weight monotone per leg
  R6  the three lobe thickness signals (the port lobe term lb per lobe,
      8 Hz, 0..120 s): max pairwise |Pearson r| < 0.6, FFT peak period of
      each within 10 percent of 9, 11 and 13 s and distinct by >= 1 s
  R7  wave loops in 9 to 16 s (fronts and ring fronts) and ripple spacing
      in 8 to 14 s, read from the port constants
  R8  render based (acid share of bright pixels < 2 percent, lobe luminance
      ratios <= 1.4, clipped pixels about 0): SKIPPED_RENDER in this run,
      the render worker fills it with render_metrics.py and lobe_lum.py

Usage: python3 knot_report.py [--outdir DIR] [--prefix r4-] [--fps 24]
                              [--seconds 120] [--tex PATH]
"""

import argparse
import json
import math
import os
import time as _time

import numpy as np

import knot_port as kp

FPS = 24.0
SECONDS = 120.0
R_PX = kp.R_KNOT * 0.6          # 270 px at knotPx 540
# bands, mirrored in the target strings below (one place each)
R2_MAX_PX = 1.6
R3_PEAK_PX = (7.0, 10.8)
R3_MEAN_PX = (2.0, 5.0)
R3_P99_PX = 9.0
R4_MAX_ACC = 0.35
R5_FORM1_PX = 20.0
R5_FORM2_PX = 35.0
R5_HOLD = (0.50, 0.60)
R6_MAX_CORR = 0.6
R6_T = (9.0, 11.0, 13.0)
R6_TOL_REL = 0.10
R6_MIN_SEP = 1.0
R1C_X_HOLD_PX = 2.0
R1C_Y_HOLD_PX = 3.0
R1C_X_FULL_PX = 3.0
R1C_R_PX = 270.0               # knot radius at knotPx 540


def lobe_signals(lobe_all, wlobe):
    """Port lobe term lb per lobe, 8 Hz, averaged over that lobe's strand.

    lobe_all is the per frame lb from the 24 fps run; every third frame is
    exactly an 8 Hz sample, so no extra port sampling is needed.
    """
    dom = np.argmax(wlobe, axis=0)
    sub = lobe_all[::3]
    out = np.zeros((3, sub.shape[0]))
    for k in range(3):
        out[k] = sub[:, dom == k].mean(axis=1)
    return out


def fft_period(y, fps):
    """Dominant period in seconds, Hann window, 4x zero pad, parabolic peak."""
    y = np.asarray(y, dtype=np.float64)
    y = (y - y.mean()) * np.hanning(len(y))
    n = len(y)
    sp = np.abs(np.fft.rfft(y, 4 * n))
    fr = np.fft.rfftfreq(4 * n, 1.0 / fps)
    lo = max(1, int(np.searchsorted(fr, 1.0 / 40.0)))
    hi = int(np.searchsorted(fr, 1.0 / 4.0))
    k = lo + int(np.argmax(sp[lo:hi]))
    y0, y1, y2 = (math.log(sp[k - 1] + 1e-12), math.log(sp[k] + 1e-12),
                  math.log(sp[k + 1] + 1e-12))
    den = y0 - 2.0 * y1 + y2
    dk = 0.5 * (y0 - y2) / den if abs(den) > 1e-12 else 0.0
    return 1.0 / (fr[k] + dk * (fr[1] - fr[0]))


def ramp(vals, lo, hi):
    stops = np.array([[10, 12, 40], [24, 60, 120], [20, 130, 140],
                      [70, 190, 110], [225, 220, 90], [252, 250, 240]],
                     dtype=np.float64)
    x = np.clip((vals - lo) / max(hi - lo, 1e-9), 0.0, 1.0)
    pos = x * (len(stops) - 1)
    i0 = np.floor(pos).astype(np.int32)
    i1 = np.minimum(i0 + 1, len(stops) - 1)
    f = (pos - i0)[..., None]
    return (stops[i0] * (1.0 - f) + stops[i1] * f).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--prefix", default="r4-")
    ap.add_argument("--tex", default=kp.DEFAULT_TEX)
    ap.add_argument("--tpp", type=int, default=11)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--limit", default="exp", choices=("tanh", "exp", "none"))
    ap.add_argument("--fps", type=float, default=FPS)
    ap.add_argument("--seconds", type=float, default=SECONDS)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    pre = a.prefix
    t0 = _time.time()

    port = kp.KnotPort(tex=a.tex, texels_per_point=a.tpp, rows=a.rows,
                       limit_mode=a.limit)
    n = port.n
    nf = int(round(a.seconds * a.fps))
    ts = np.arange(nf) / a.fps

    pos_full = np.zeros((nf, n, 2), dtype=np.float32)
    loc_len = np.zeros((nf, n), dtype=np.float32)
    morph_s = np.zeros((nf, n), dtype=np.float32)
    morph_px = np.zeros((nf, n), dtype=np.float32)
    lobe_all = np.zeros((nf, n), dtype=np.float32)
    hold = np.zeros(nf, dtype=bool)

    for i, t in enumerate(ts):
        d = port.sample(t)
        pos_full[i] = d["pos_full"]
        loc_len[i] = d["local_len"]
        morph_s[i] = d["morph_s"]
        morph_px[i] = np.linalg.norm(d["morph_px"], axis=1)
        lobe_all[i] = d["lobe"]
        hold[i] = kp.morph_x(t) in (0.0, 1.0)
    runtime = _time.time() - t0

    # ---- R1: pose ------------------------------------------------------
    tp = np.arange(0.0, 240.0, 0.25)
    pitch = np.array([math.degrees(port.pose(t)[1]) for t in tp])
    roll = np.array([math.degrees(port.pose(t)[2]) for t in tp])
    # R1c: the centroid of all dots, from the port positions, screen px
    cen = pos_full.astype(np.float64).mean(axis=1)
    hold_win = ((ts >= 0.0) & (ts < kp.HOLD_A)) | \
               ((ts >= kp.CYC) & (ts < kp.CYC + kp.HOLD_A))
    c_x_hold = float(np.ptp(cen[hold_win, 0]))
    c_y_hold = float(np.ptp(cen[hold_win, 1]))
    c_x_full = float(np.ptp(cen[:, 0]))
    r1c_ok = (c_x_hold <= R1C_X_HOLD_PX + 1e-9
              and c_y_hold <= R1C_Y_HOLD_PX + 1e-9
              and c_x_full <= R1C_X_FULL_PX + 1e-9)
    # the shader has no yaw term by construction, so yaw is read off the
    # measured centroid drift: a horizontal sweep of s px on a 270 px radius
    # is atan(s / 270) of equivalent yaw
    yaw_equiv_deg = math.degrees(math.atan(c_x_hold / R1C_R_PX))
    yaw_band_deg = math.degrees(math.atan(R1C_X_HOLD_PX / R1C_R_PX))
    yaw_full_deg = math.degrees(math.atan(c_x_full / R1C_R_PX))
    r1_yaw = yaw_equiv_deg <= yaw_band_deg + 1e-12
    r1_pitch = float(pitch.max() - pitch.min()) <= 4.0
    r1_roll = float(roll.max() - roll.min()) <= 4.0
    scale_pp_pct = port.SCALE_AMP * 100.0
    r1_scale = scale_pp_pct <= 0.8 + 1e-9 and 6.0 <= port.SCALE_T <= 8.0

    # ---- R2: max per frame displacement --------------------------------
    step = np.linalg.norm(np.diff(pos_full.astype(np.float64), axis=0), axis=2)
    r2_max = float(step.max())

    # ---- R3: local activity in the hold windows ------------------------
    loc_hold = loc_len[hold]
    r3_peak = float(loc_hold.max()) if loc_hold.size else 0.0
    r3_mean = float(loc_hold.mean()) if loc_hold.size else 0.0
    r3_p99 = float(np.percentile(loc_hold, 99.0)) if loc_hold.size else 0.0
    r3_ok = (R3_PEAK_PX[0] <= r3_peak <= R3_PEAK_PX[1]
             and R3_MEAN_PX[0] <= r3_mean <= R3_MEAN_PX[1]
             and r3_p99 <= R3_P99_PX)

    # ---- R4: acceleration ----------------------------------------------
    acc = np.linalg.norm(np.diff(pos_full.astype(np.float64), n=2, axis=0), axis=2)
    r4_max = float(acc.max())

    # ---- R5: morph ------------------------------------------------------
    idx1 = int(np.argmin(np.abs(ts - (kp.HOLD_A + kp.LEG + 1.0))))
    idx2 = int(np.argmin(np.abs(ts - (kp.CYC + kp.HOLD_A + kp.LEG + 1.0))))
    m1 = float(morph_px[idx1].mean())
    m2 = float(morph_px[idx2].mean())
    hold_frac_nominal = kp.HOLD_A / kp.CYC     # triquetra hold, gate value
    # the frame grid and the 0.25 s grid are INFO only (see below)
    tg = (np.arange(int(round(a.seconds / 0.25))) + 0.5) * 0.25
    hold_frac_grid = float(np.mean([kp.morph_x(t) in (0.0, 1.0) for t in tg]))
    hold_frac_point = float(hold.mean())
    # monotone per leg: every per point weight non decreasing on the way out
    mono = True
    for c in range(0, 2):
        i0 = int(round((c * kp.CYC + kp.HOLD_A) * a.fps))
        i1 = int(round((c * kp.CYC + kp.HOLD_A + kp.LEG) * a.fps))
        if i1 <= i0:
            continue
        dif = np.diff(morph_s[i0:i1], axis=0)
        if dif.size and float(dif.min()) < -1e-9:
            mono = False
    r5_ok = (m1 >= R5_FORM1_PX and m2 >= R5_FORM2_PX and mono
             and R5_HOLD[0] <= hold_frac_nominal <= R5_HOLD[1])

    # ---- R6: lobe phase, from the port's own lb per lobe ----------------
    sig = lobe_signals(lobe_all, port.wlobe)      # 8 Hz over 0..120 s
    fps8 = a.fps / 3.0
    corr = {}
    for i, j in ((0, 1), (0, 2), (1, 2)):
        corr["%d_%d" % (i, j)] = round(
            float(np.corrcoef(sig[i], sig[j])[0, 1]), 4)
    max_abs_corr = max(abs(v) for v in corr.values())
    periods = [round(float(fft_period(sig[k], fps8)), 3) for k in range(3)]
    t_err = [abs(periods[k] - R6_T[k]) / R6_T[k] for k in range(3)]
    sep = min(abs(periods[i] - periods[j])
              for i, j in ((0, 1), (0, 2), (1, 2)))
    r6_ok = (max_abs_corr < R6_MAX_CORR and max(t_err) <= R6_TOL_REL
             and sep >= R6_MIN_SEP)

    # ---- R7: constants --------------------------------------------------
    loops = list(kp.KnotPort.C_T) + list(kp.KnotPort.CR_T)
    ripple = list(kp.KnotPort.E_L)
    r7_ok = (all(9.0 <= p <= 16.0 for p in loops)
             and all(8.0 <= L <= 14.0 for L in ripple))

    # ---- criteria table -------------------------------------------------
    crit = []

    def add(name, ok, value, target, note=""):
        crit.append({"name": name, "pass": (None if ok is None else bool(ok)),
                     "status": ("SKIPPED_RENDER" if ok is None
                                else ("PASS" if ok else "FAIL")),
                     "value": value, "target": target, "note": note})

    def add_info(name, value, note=""):
        crit.append({"name": name, "pass": None, "status": "INFO",
                     "value": value, "target": "informational, not gated",
                     "note": note})

    add("R1_yaw_equivalent_deg", r1_yaw, round(yaw_equiv_deg, 4),
        "<= %.4f deg = atan(%.1f px / %.0f px), equivalent yaw from the "
        "centroid x span in the hold windows"
        % (yaw_band_deg, R1C_X_HOLD_PX, R1C_R_PX),
        "knot.vert has no yaw term by construction; this gate measures the "
        "result. x span in the hold windows %.3f px, over 0..%.0f s %.3f px "
        "(%.4f deg)" % (c_x_hold, a.seconds, c_x_full, yaw_full_deg))
    add("R1c_centroid_x_hold_px", c_x_hold <= R1C_X_HOLD_PX + 1e-9,
        round(c_x_hold, 4),
        "<= %.1f px peak to peak, centroid of all %d dots, hold windows "
        "t in [0,%.0f) and [%.0f,%.0f) at %.0f fps"
        % (R1C_X_HOLD_PX, n, kp.HOLD_A, kp.CYC, kp.CYC + kp.HOLD_A, a.fps),
        "%d hold frames" % int(hold_win.sum()))
    add("R1c_centroid_y_hold_px", c_y_hold <= R1C_Y_HOLD_PX + 1e-9,
        round(c_y_hold, 4),
        "<= %.1f px peak to peak over the same hold windows"
        % R1C_Y_HOLD_PX)
    add("R1c_centroid_x_full_px", c_x_full <= R1C_X_FULL_PX + 1e-9,
        round(c_x_full, 4),
        "<= %.1f px peak to peak over 0..%.0f s (morph included)"
        % (R1C_X_FULL_PX, a.seconds))
    add("R1_pitch_pp_deg", r1_pitch, round(float(pitch.max() - pitch.min()), 3),
        "<= 4.0 deg peak to peak over 240 s")
    add("R1_roll_pp_deg", r1_roll, round(float(roll.max() - roll.min()), 3),
        "<= 4.0 deg peak to peak over 240 s (no yaw, roll of the projected x,y)")
    add("R1_scale_pp_pct", r1_scale, round(scale_pp_pct, 4),
        "<= 0.8 percent peak to peak and period in 6 to 8 s",
        "period %.1f s" % port.SCALE_T)
    add("R2_max_step_px", r2_max < R2_MAX_PX, round(r2_max, 4),
        "< %.1f px per frame at %.0f fps, any dot, 0..%.0f s, morph running"
        % (R2_MAX_PX, a.fps, a.seconds),
        "at knotPx %.0f, 1 unit = %.2f px" % (port.knot_px, port.knot_px / kp.KNOT_H))
    add("R3_peak_local_px", r3_ok, round(r3_peak, 3),
        "peak in [%.1f, %.1f] px, mean in [%.1f, %.1f] px, p99 <= %.1f px, "
        "hold windows only (%d of %d frames)"
        % (R3_PEAK_PX[0], R3_PEAK_PX[1], R3_MEAN_PX[0], R3_MEAN_PX[1],
           R3_P99_PX, int(hold.sum()), nf),
        "mean %.3f px, p99 %.3f px" % (r3_mean, r3_p99))
    add("R4_max_accel_px", r4_max < R4_MAX_ACC, round(r4_max, 4),
        "< %.2f px per frame squared, 0..%.0f s at %.0f fps"
        % (R4_MAX_ACC, a.seconds, a.fps))
    add("R5_morph_form1_px", m1 >= R5_FORM1_PX, round(m1, 3),
        ">= %.0f px mean screen displacement at x = 1, form 1" % R5_FORM1_PX,
        "mean |pos - hold| over all %d dots at t = %.1f s"
        % (n, ts[idx1]))
    add("R5_morph_form2_px", m2 >= R5_FORM2_PX, round(m2, 3),
        ">= %.0f px mean screen displacement at x = 1, form 2" % R5_FORM2_PX,
        "t = %.1f s" % ts[idx2])
    add("R5_hold_fraction", R5_HOLD[0] <= hold_frac_nominal <= R5_HOLD[1],
        round(hold_frac_nominal, 4),
        "nominal triquetra hold = HOLD_A %.1f s / CYC %.1f s = %.4f in "
        "[%.2f, %.2f], from the schedule constants"
        % (kp.HOLD_A, kp.CYC, hold_frac_nominal, R5_HOLD[0], R5_HOLD[1]),
        "the schedule constants are the gate; sampled grids are INFO")
    add_info("R5_hold_fraction_frame_grid", round(hold_frac_point, 4),
             "INFO only: frames with every point at a hold = %d of %d = "
             "%.4f; 0.25 s grid = %.4f (eased leg edges, not gated)"
             % (int(hold.sum()), nf, hold_frac_point, hold_frac_grid))
    add("R5_weights_monotone", mono, bool(mono),
        "per point weight non decreasing along every out leg")
    add("R6_lobe_phase_corr", r6_ok,
        "r %.2f / %.2f / %.2f" % (corr["0_1"], corr["0_2"], corr["1_2"]),
        "max pairwise |Pearson r| < %.1f; FFT peak period within %.0f "
        "percent of %.1f, %.1f, %.1f s and separated by >= %.1f s "
        "(port lobe lb per lobe, 8 Hz, 0..%.0f s)"
        % (R6_MAX_CORR, R6_TOL_REL * 100.0, R6_T[0], R6_T[1], R6_T[2],
           R6_MIN_SEP, a.seconds),
        "periods %s s (errors %.2f / %.2f / %.2f percent), min separation "
        "%.2f s, corr 0_1 %.3f 0_2 %.3f 1_2 %.3f"
        % (periods, t_err[0] * 100.0, t_err[1] * 100.0, t_err[2] * 100.0,
           sep, corr["0_1"], corr["0_2"], corr["1_2"]))
    add("R7_loop_periods_s", r7_ok,
        [round(x, 1) for x in loops],
        "every wave loop in 9 to 16 s",
        "ripple slots %s s, need 8 to 14" % (list(ripple),))
    add("R8_acid_share_pct", None, None,
        "< 2 percent of bright pixels are acid (render_metrics.py)",
        "RENDER")
    add("R8_lobe_luminance_ratio", None, None,
        "every lobe ratio <= 1.4 (lobe_lum.py)", "RENDER")
    add("R8_clipped_px", None, None,
        "clipped pixels about 0", "RENDER")

    npass = sum(1 for c in crit if c["status"] == "PASS")
    nfail = sum(1 for c in crit if c["status"] == "FAIL")
    nskip = sum(1 for c in crit if c["status"] == "SKIPPED_RENDER")
    ninfo = sum(1 for c in crit if c["status"] == "INFO")
    verdict = "PASS" if nfail == 0 else "FAIL"
    if nskip:
        verdict += " (%d render gate(s) SKIPPED_RENDER)" % nskip

    rep = {"spec": "KNOT-SPEC-R4 section 4, gates R1..R8",
           "texture": os.path.basename(a.tex), "n_points": n,
           "texels_per_point": port.tpp, "rows": port.rows,
           "fps": a.fps, "seconds": a.seconds, "frames": nf,
           "knotPx": port.knot_px, "limit_mode": a.limit,
           "limiter_pct_R": port.local_limit_pct,
           "runtime_s": round(runtime, 1),
           "morph": {"cycle_s": kp.CYC, "hold_a_s": kp.HOLD_A,
                     "leg_s": kp.LEG, "hold_b_s": kp.HOLD_B,
                     "stagger": kp.STAGGER,
                     "max_target_units": {
                         "form1": round(float(np.linalg.norm(port.P1 - port.P, axis=1).max()), 2),
                         "form2": round(float(np.linalg.norm(port.P2 - port.P, axis=1).max()), 2)},
                     "mean_target_units": {
                         "form1": round(float(np.linalg.norm(port.P1 - port.P, axis=1).mean()), 2),
                         "form2": round(float(np.linalg.norm(port.P2 - port.P, axis=1).mean()), 2)},
                     "p95_target_units": {
                         "form1": round(float(np.percentile(np.linalg.norm(port.P1 - port.P, axis=1), 95.0)), 2),
                         "form2": round(float(np.percentile(np.linalg.norm(port.P2 - port.P, axis=1), 95.0)), 2)},
                     "max_target_px": {
                         "form1": round(float(np.linalg.norm(port.P1 - port.P, axis=1).max()) * port.knot_px / kp.KNOT_H, 2),
                         "form2": round(float(np.linalg.norm(port.P2 - port.P, axis=1).max()) * port.knot_px / kp.KNOT_H, 2)}},
           "criteria": crit, "passed": npass, "failed": nfail,
           "skipped_render": nskip, "info": ninfo, "verdict": verdict}

    # heat map of the local activity in time (arc bins x time)
    nb = 32
    bi = np.floor(np.clip(port.u, 0.0, 0.999999) * nb).astype(np.int32)
    grid = np.zeros((nb, nf))
    for b in range(nb):
        m = bi == b
        if m.any():
            grid[b] = loc_len[:, m].mean(axis=1)
    img = ramp(grid, 0.0, max(float(grid.max()), 1e-6))
    from PIL import Image
    Image.fromarray(img[::-1], "RGB").resize((nf * 2, nb * 6), Image.NEAREST).save(
        os.path.join(a.outdir, pre + "heatmap.png"))

    jpath = os.path.join(a.outdir, pre + "report.json")
    with open(jpath, "w", encoding="ascii") as f:
        json.dump(rep, f, indent=1)

    L = []
    L.append("KNOT round 4 numeric report, gates R1..R8 of KNOT-SPEC-R4")
    L.append("texture %s (%d texels per point, %d rows), %d points, "
             "knotPx %.0f, 1 unit = %.2f px"
             % (os.path.basename(a.tex), port.tpp, port.rows, n, port.knot_px,
                port.knot_px / kp.KNOT_H))
    L.append("window %.0f s at %.0f fps (%d frames), limiter %s at %.1f pct of R"
             % (a.seconds, a.fps, nf, a.limit, port.local_limit_pct))
    L.append("morph target distance: form 1 max %.1f units (%.1f px), "
             "form 2 max %.1f units (%.1f px)"
             % (rep["morph"]["max_target_units"]["form1"],
                rep["morph"]["max_target_px"]["form1"],
                rep["morph"]["max_target_units"]["form2"],
                rep["morph"]["max_target_px"]["form2"]))
    L.append("")
    for c in crit:
        val = c["value"]
        if isinstance(val, float):
            val = "%.4f" % val
        L.append("%-16s %-28s = %s   (need %s)"
                 % (c["status"], c["name"], val, c["target"]))
        if c["note"]:
            L.append("                 %s" % c["note"])
    L.append("")
    L.append("verdict %s: %d pass, %d fail, %d SKIPPED_RENDER, %d INFO"
             % (verdict, npass, nfail, nskip, ninfo))
    L.append("local activity: mean %.2f px, p99 %.2f px, peak %.2f px in the "
             "hold windows" % (r3_mean, r3_p99, r3_peak))
    L.append("max per frame displacement %.3f px, max acceleration %.4f px/frame^2"
             % (r2_max, r4_max))
    L.append("centroid drift: x hold %.3f px, y hold %.3f px, x 0..%.0f s "
             "%.3f px; equivalent yaw %.4f deg (band %.4f deg)"
             % (c_x_hold, c_y_hold, a.seconds, c_x_full, yaw_equiv_deg,
                yaw_band_deg))
    L.append("runtime %.1f s" % runtime)
    txt = "\n".join(L) + "\n"
    with open(os.path.join(a.outdir, pre + "report.txt"), "w",
              encoding="ascii") as f:
        f.write(txt)
    print(txt)


if __name__ == "__main__":
    main()
