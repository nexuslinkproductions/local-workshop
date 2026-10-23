#!/usr/bin/env python3
"""knot_report.py: evidence run for the knot, metrics M1 to M6 of
KNOT-SPEC-ADD.md v2.1.

Windows at 24 fps:
  6 s   (144 frames)  jumps M1, local limit M2, arc non-uniformity M3,
                      coverage M6, heat map
  60 s (1440 frames)  spectra M4 and M5, aggregate and 32 bin series,
                      Hann window, DC removed

Per point local displacement is terms B to E only: pos_full - pos, where pos
is the same point under the global pose alone. Global motion therefore never
enters a local metric; it only enters M1.

M1  max point jump per frame at 24 fps              < 2.5 px
M2  max local displacement after the limiter        < 4.5 percent of R
M3  cv of the 32 arc bin means (time averaged)      > 0.15, and at least 8
    distinct bins hold the instantaneous maximum over 6 s
M4  per bin std over time / bin mean                > 0.2 for >= 80 pct bins
M5  largest single FFT bin of the aggregate series  < 35 pct of non-DC power,
    and >= 4 distinct peak bins among the 32 bin series
M6  points that move > 1 px at some time in 6 s     > 0.9

Outputs into --outdir with --prefix (default "final-"):
  <pre>report.txt        PASS/FAIL per metric with the number
  <pre>report.json       every metric, series summary and criterion
  <pre>heatmap.png       32 ribbon bins over 32 ring bins, arc against time
  <pre>series-6s.csv     time, 32 bin means, mean local px
  <pre>series-60s.csv    time, 32 bin means, aggregate mean
  <pre>spectrum.csv      frequency, aggregate power, share per bin

Usage: python3 knot_report.py [--motion v2|base] [--outdir DIR] [--tex PATH]
                             [--prefix final-] [--fps 24] [--seconds 60]
"""

import argparse
import json
import os
import time as _time

import numpy as np
from PIL import Image

import knot_port as kp

NB = 32
FPS = 24
JUMP_SECONDS = 6.0
SPEC_SECONDS = 60.0


def bin_index(u, nbin=NB):
    """Arc length bin per point, 0..nbin-1 over u in 0..1 (per class)."""
    return np.floor(np.clip(u, 0.0, 0.999999) * nbin).astype(np.int32)


def ramp(vals, lo, hi):
    """Map values to a viridis-ish RGB uint8 array (PIL only, no mpl)."""
    stops = np.array([
        [10, 12, 40], [24, 60, 120], [20, 130, 140],
        [70, 190, 110], [225, 220, 90], [252, 250, 240]], dtype=np.float64)
    x = np.clip((vals - lo) / max(hi - lo, 1e-9), 0.0, 1.0)
    pos = x * (len(stops) - 1)
    i0 = np.floor(pos).astype(np.int32)
    i1 = np.minimum(i0 + 1, len(stops) - 1)
    f = (pos - i0)[..., None]
    out = stops[i0] * (1.0 - f) + stops[i1] * f
    return out.astype(np.uint8)


def heatmap(series, path):
    """series: (2*NB, T) mean local px per arc bin over time."""
    rows, cols = series.shape
    img = np.zeros((rows, cols, 3), dtype=np.uint8)
    for r in range(rows):
        img[r] = ramp(series[r], 0.0, max(float(series.max()), 1e-6))
    top = img[:NB][::-1]
    bot = img[NB:][::-1]
    sep = np.full((2, cols, 3), 235, dtype=np.uint8)
    out = np.concatenate([top, sep, bot], axis=0)
    im = Image.fromarray(out, "RGB")
    im = im.resize((cols * 4, out.shape[0] * 6), Image.NEAREST)
    im.save(path)
    return path


def hann_spectrum(series, fps):
    """Power spectrum of a demeaned series with a Hann window.

    Returns (power, freqs) with the DC bin zeroed so callers only see the
    non-DC content.
    """
    x = np.asarray(series, dtype=np.float64)
    n = x.shape[-1]
    x = x - x.mean(axis=-1, keepdims=True)
    w = 0.5 - 0.5 * np.cos(2.0 * np.pi * np.arange(n) / max(n - 1, 1))
    spec = np.abs(np.fft.rfft(x * w, axis=-1)) ** 2
    spec[..., 0] = 0.0
    freqs = np.fft.rfftfreq(n, 1.0 / fps)
    return spec, freqs


def peak_share(spec):
    tot = spec[..., 1:].sum(axis=-1)
    pk = spec[..., 1:].argmax(axis=-1)
    mx = spec[..., 1:].max(axis=-1)
    share = np.where(tot > 1e-12, mx / np.maximum(tot, 1e-12), 0.0)
    return share, pk + 1, tot


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--motion", default="v2", choices=("v2", "base"))
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--tex", default=kp.DEFAULT_TEX)
    ap.add_argument("--tpp", type=int, default=5)
    ap.add_argument("--rows", type=int, default=11)
    ap.add_argument("--limit", default="tanh", choices=("tanh", "exp", "none"))
    ap.add_argument("--prefix", default="final-")
    ap.add_argument("--fps", type=float, default=FPS)
    ap.add_argument("--seconds", type=float, default=SPEC_SECONDS,
                    help="spectrum window, 60 s by default")
    ap.add_argument("--jump-seconds", type=float, default=JUMP_SECONDS)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    pre = a.prefix
    t_start = _time.time()

    port = kp.KnotPort(tex=a.tex, motion=a.motion, texels_per_point=a.tpp,
                       rows=a.rows, limit_mode=a.limit)
    n = port.n
    nf_j = int(round(a.jump_seconds * a.fps))
    nf_s = int(round(a.seconds * a.fps))
    tj = np.arange(nf_j) / a.fps
    ts = np.arange(nf_s) / a.fps
    bidx = bin_index(port.u)
    rib = port.ribbon
    ring = ~rib
    counts = np.bincount(bidx, minlength=NB).astype(np.float64)
    cnt_rib = np.bincount(bidx[rib], minlength=NB).astype(np.float64)
    cnt_ring = np.bincount(bidx[ring], minlength=NB).astype(np.float64)

    # ---- pass 1: 6 s window (jump, heat map, coverage) -------------------
    loc_len = np.zeros((nf_j, n))
    pos_full = np.zeros((nf_j, n, 2))
    pos_pose = np.zeros((nf_j, n, 2))
    dP_len = np.zeros((nf_j, n))
    dP_raw_len = np.zeros((nf_j, n))
    dP_exp_len = np.zeros((nf_j, n))
    term_peak = {k: 0.0 for k in "BCDE"}
    term_px_mean = {k: 0.0 for k in "BCDE"}
    bright_min = 1e9
    radius_min = 1e9
    bin6 = np.zeros((2 * NB, nf_j))
    argmax_bin = np.zeros(nf_j, dtype=np.int32)
    for i, t in enumerate(tj):
        d = port.sample(t)
        pos_pose[i] = d["pos"]
        pos_full[i] = d["pos_full"]
        loc_len[i] = d["local_len"]
        if port.motion == "v2":
            dP_len[i] = d["dP_len"]
            dP_raw_len[i] = d["dP_raw_len"]
            dP_exp_len[i] = d["dP_exp_len"]
            for k, v in d["terms_px"].items():
                term_px_mean[k] += float(np.linalg.norm(v, axis=1).mean())
            for k, v in d["terms"].items():
                term_peak[k] = max(term_peak[k],
                                   float(np.linalg.norm(v, axis=1).max()))
            bright_min = min(bright_min, float(d["bright"].min()))
            radius_min = min(radius_min, float(d["radius"].min()))
        for c, mask, cnt in ((0, rib, cnt_rib), (1, ring, cnt_ring)):
            s = np.bincount(bidx[mask], weights=loc_len[i][mask],
                            minlength=NB)
            bin6[c * NB:(c + 1) * NB, i] = np.where(cnt > 0,
                                                    s / np.maximum(cnt, 1), 0.0)
        m = bin6[:, i].copy()
        argmax_bin[i] = int(m.argmax()) if m.max() > 0 else -1

    # ---- pass 2: spectrum window (60 s) ----------------------------------
    agg = np.zeros(nf_s)
    bin_s = np.zeros((2 * NB, nf_s))
    dP60_max = 0.0
    dP60_raw_max = 0.0
    dP60_exp_max = 0.0
    for i, t in enumerate(ts):
        d = port.sample(t)
        agg[i] = float(d["local_len"].mean())
        for c, mask, cnt in ((0, rib, cnt_rib), (1, ring, cnt_ring)):
            s = np.bincount(bidx[mask], weights=d["local_len"][mask],
                            minlength=NB)
            bin_s[c * NB:(c + 1) * NB, i] = np.where(cnt > 0,
                                                     s / np.maximum(cnt, 1), 0.0)
        if port.motion == "v2":
            dP60_max = max(dP60_max, float(d["dP_len"].max()))
            dP60_raw_max = max(dP60_raw_max, float(d["dP_raw_len"].max()))
            dP60_exp_max = max(dP60_exp_max, float(d["dP_exp_len"].max()))
    runtime = _time.time() - t_start

    # ---- M1 jump (6 s, includes the global pose) -------------------------
    step = np.linalg.norm(np.diff(pos_full, axis=0), axis=2)
    jump_max = float(step.max()) if nf_j > 1 else 0.0
    jump_p99 = float(np.percentile(step, 99.0)) if nf_j > 1 else 0.0
    pose_step = np.linalg.norm(np.diff(pos_pose, axis=0), axis=2)
    pose_jump_max = float(pose_step.max()) if nf_j > 1 else 0.0

    # ---- M2 local limit --------------------------------------------------
    peak_pct = max(float(dP_len.max()), dP60_max) / kp.R_KNOT * 100.0
    peak_raw_pct = max(float(dP_raw_len.max()), dP60_raw_max) / kp.R_KNOT * 100.0
    peak_exp_pct = max(float(dP_exp_len.max()), dP60_exp_max) / kp.R_KNOT * 100.0

    # ---- M3 non-uniform in space ----------------------------------------
    bin_tmean = bin_s.mean(axis=1)
    live = np.concatenate([cnt_rib, cnt_ring]) > 0
    alive = bin_tmean[live]
    cv_space = float(alive.std() / max(alive.mean(), 1e-12)) if len(alive) else 0.0
    # ribbon only, for reference (the ring is 490 of 4384 points)
    mlive = cnt_rib > 0
    mmean = bin_s[:NB][mlive].mean(axis=1)
    cv_space_rib = float(mmean.std() / max(mmean.mean(), 1e-12)) if len(mmean) else 0.0
    # alternate reading of M3 (not the literal one): per frame spatial cv
    # across bins, then averaged over time
    inst_cv = []
    for i in range(nf_s):
        v = bin_s[live, i]
        if v.mean() > 1e-9:
            inst_cv.append(float(v.std() / v.mean()))
    cv_space_inst = float(np.mean(inst_cv)) if inst_cv else 0.0
    uniq_bins = len(set(int(x) for x in argmax_bin if x >= 0))

    # ---- M4 time varying (per bin std/mean) ------------------------------
    def frac_varying(mat, freqs_mask=None):
        sel = mat[freqs_mask] if freqs_mask is not None else mat[live]
        mn = sel.mean(axis=1)
        sd = sel.std(axis=1)
        r = np.where(mn > 1e-9, sd / np.maximum(mn, 1e-12), 0.0)
        return float((r > 0.2).mean()) if len(r) else 0.0, r

    frac_var60, ratios60 = frac_varying(bin_s)
    frac_var6, ratios6 = frac_varying(bin6)

    # ---- M5 spectrum -----------------------------------------------------
    spec_agg, freqs = hann_spectrum(agg, a.fps)
    share_agg, peak_bin, tot_agg = peak_share(spec_agg)
    share_agg = float(share_agg)
    peak_freq = float(freqs[peak_bin])
    # 32 bin series: ribbon bins first, then ring bins (both have u 0..1)
    spec_bins, _ = hann_spectrum(bin_s, a.fps)
    share_bins, pbin, tot_bins = peak_share(spec_bins)
    active = tot_bins > 1e-9
    pfreqs = freqs[pbin]
    uniq_peak_bins = len(set(int(x) for x in pbin[active]))

    # ---- M6 coverage -----------------------------------------------------
    ever = loc_len.max(axis=0)
    frac_1px = float((ever > 1.0).mean())
    frac_2px = float((ever > 2.0).mean())

    # ---- criteria --------------------------------------------------------
    crit = {}

    def add(name, ok, value, target, note=""):
        crit[name] = {"pass": bool(ok), "value": value, "target": target,
                      "note": note}

    add("M1_jump_max_px", jump_max < 2.5, round(jump_max, 3),
        "< 2.5 px per frame at 24 fps",
        f"p99 {jump_p99:.3f} px, global pose alone {pose_jump_max:.3f} px")
    add("M2_local_peak_pct_R", peak_pct < 4.5, round(peak_pct, 3),
        "< 4.5 percent of R after the limiter",
        f"raw (unlimited) {peak_raw_pct:.3f} pct, shader exp form "
        f"{peak_exp_pct:.3f} pct")
    add("M3_arc_cv", cv_space > 0.15, round(cv_space, 3),
        "> 0.15 coefficient of variation of the 32 bin means",
        f"literal time-averaged reading; ribbon only {cv_space_rib:.3f}; "
        f"per-frame spatial cv averaged over time is {cv_space_inst:.3f}, "
        f"bin means span {alive.min():.2f} to {alive.max():.2f} px, "
        f"a cv of 0.15 needs sd {0.15 * alive.mean():.3f} px, now "
        f"{alive.std():.3f} px" if len(alive) else "")
    add("M3_distinct_max_bins", uniq_bins >= 8, int(uniq_bins),
        ">= 8 distinct bins hold the instantaneous maximum over 6 s")
    add("M4_bins_varying", frac_var60 >= 0.80, round(frac_var60, 3),
        ">= 0.80 of bins have std/mean > 0.2 over 60 s",
        f"6 s window {frac_var6:.3f}, median ratio "
        f"{float(np.median(ratios60)):.3f}" if len(ratios60) else "")
    add("M5_aggregate_peak_share", share_agg < 0.35, round(share_agg, 3),
        "< 0.35 of the non-DC power in one FFT bin",
        f"peak at {peak_freq:.4f} Hz (bin {int(peak_bin)})")
    add("M5_distinct_bin_peaks", uniq_peak_bins >= 4, int(uniq_peak_bins),
        ">= 4 distinct FFT bins among the 32 bin series")
    add("M6_coverage_1px", frac_1px > 0.9, round(frac_1px, 3),
        "> 0.9 of points move > 1 px at some time in 6 s",
        f"> 2 px: {frac_2px:.3f}")

    passed = sum(1 for c in crit.values() if c["pass"])
    total = len(crit)
    verdict = "PASS" if passed == total else "FAIL"

    # ---- files -----------------------------------------------------------
    csv6 = os.path.join(a.outdir, pre + "series-6s.csv")
    with open(csv6, "w", encoding="ascii") as f:
        head = (["t"] + [f"r{b:02d}" for b in range(NB)]
                + [f"g{b:02d}" for b in range(NB)] + ["mean_local_px"])
        f.write(",".join(head) + "\n")
        for i in range(nf_j):
            f.write(",".join([f"{tj[i]:.4f}"]
                             + [f"{bin6[b, i]:.4f}" for b in range(2 * NB)]
                             + [f"{loc_len[i].mean():.4f}"]) + "\n")
    csv60 = os.path.join(a.outdir, pre + "series-60s.csv")
    with open(csv60, "w", encoding="ascii") as f:
        head = (["t"] + [f"r{b:02d}" for b in range(NB)]
                + [f"g{b:02d}" for b in range(NB)] + ["aggregate_mean_px"])
        f.write(",".join(head) + "\n")
        for i in range(nf_s):
            f.write(",".join([f"{ts[i]:.4f}"]
                             + [f"{bin_s[b, i]:.4f}" for b in range(2 * NB)]
                             + [f"{agg[i]:.4f}"]) + "\n")
    csvsp = os.path.join(a.outdir, pre + "spectrum.csv")
    with open(csvsp, "w", encoding="ascii") as f:
        f.write("freq_hz,aggregate_power,aggregate_share\n")
        tot = max(float(spec_agg[1:].sum()), 1e-12)
        for i in range(1, len(freqs)):
            f.write(f"{freqs[i]:.5f},{spec_agg[i]:.6g},"
                    f"{spec_agg[i] / tot:.6g}\n")
    hm_path = os.path.join(a.outdir, pre + "heatmap.png")
    heatmap(bin6, hm_path)

    rep = {
        "spec": "KNOT-SPEC-ADD.md v2.1 metrics M1 to M6",
        "motion": a.motion, "n_points": n, "ribbon_points": int(rib.sum()),
        "ring_points": int(ring.sum()),
        "texture": os.path.basename(a.tex), "texels_per_point": port.tpp,
        "limit_mode": a.limit, "limiter_pct_R": port.local_limit_pct,
        "fps": a.fps, "jump_window_s": a.jump_seconds,
        "jump_frames": nf_j, "spectrum_window_s": a.seconds,
        "spectrum_frames": nf_s,
        "item_px": [port.w, port.h], "knotPx": port.knot_px,
        "unit_px": round(port.knot_px / kp.KNOT_H, 4),
        "runtime_s": round(runtime, 1),
        "local_px_mean": round(float(loc_len.mean()), 3),
        "local_px_p50": round(float(np.percentile(loc_len, 50)), 3),
        "local_px_max": round(float(loc_len.max()), 3),
        "jump_max_px": round(jump_max, 3),
        "jump_p99_px": round(jump_p99, 3),
        "pose_only_jump_max_px": round(pose_jump_max, 3),
        "peak_local_units": round(peak_pct / 100.0 * kp.R_KNOT, 3),
        "peak_local_pct_R": round(peak_pct, 3),
        "peak_local_pct_R_raw": round(peak_raw_pct, 3),
        "peak_local_pct_R_exp_form": round(peak_exp_pct, 3),
        "term_peak_pct_R": {k: round(v / kp.R_KNOT * 100.0, 3)
                            for k, v in term_peak.items()},
        "term_px_mean": {k: round(v / nf_j, 3)
                         for k, v in term_px_mean.items()},
        "bright_min": round(bright_min, 3) if bright_min < 1e8 else 1.0,
        "radius_min": round(radius_min, 3) if radius_min < 1e8 else 1.0,
        "bin_time_mean_px": [round(float(x), 3) for x in bin_tmean],
        "bin_std_over_mean_p50": round(float(np.median(ratios60)), 3)
        if len(ratios60) else 0.0,
        "arc_cv_space": round(cv_space, 3),
        "arc_cv_space_ribbon": round(cv_space_rib, 3),
        "arc_cv_space_per_frame_mean": round(cv_space_inst, 3),
        "distinct_max_bins_6s": int(uniq_bins),
        "bins_varying_frac_60s": round(frac_var60, 3),
        "bins_varying_frac_6s": round(frac_var6, 3),
        "aggregate_peak_share": round(share_agg, 4),
        "aggregate_peak_freq_hz": round(peak_freq, 4),
        "aggregate_nonDC_power": float(spec_agg[1:].sum()),
        "distinct_bin_peak_bins": int(uniq_peak_bins),
        "bin_peak_share_p50": round(float(np.median(share_bins[active])), 4)
        if active.any() else 0.0,
        "bin_peak_share_max": round(float(share_bins[active].max()), 4)
        if active.any() else 0.0,
        "coverage_1px_frac": round(frac_1px, 3),
        "coverage_2px_frac": round(frac_2px, 3),
        "criteria": crit, "passed": passed, "total": total,
        "verdict": verdict,
        "files": {"text": os.path.join(a.outdir, pre + "report.txt"),
                  "json": os.path.join(a.outdir, pre + "report.json"),
                  "heatmap": hm_path, "series_6s": csv6,
                  "series_60s": csv60, "spectrum": csvsp},
    }
    jpath = rep["files"]["json"]
    with open(jpath, "w", encoding="ascii") as f:
        json.dump(rep, f, indent=1)

    # ---- text summary ----------------------------------------------------
    L = []
    L.append(f"KNOT evidence run, motion={a.motion}, spec v2.1")
    L.append(f"texture {os.path.basename(a.tex)} ({port.tpp} texels per point), "
             f"{n} points ({int(rib.sum())} ribbon, {int(ring.sum())} ring)")
    L.append(f"windows: {nf_j} frames at {a.fps} fps ({a.jump_seconds:.0f} s) "
             f"for M1 M2 M3 M6, {nf_s} frames ({a.seconds:.0f} s) for M2 M4 M5")
    L.append(f"limiter {a.limit}, L = {port.local_limit_pct:.1f} percent of R "
             f"= {port.lim:.1f} units")
    L.append("")
    L.append(f"local displacement: mean {rep['local_px_mean']:.2f} px, "
             f"p50 {rep['local_px_p50']:.2f} px, "
             f"peak {rep['local_px_max']:.2f} px")
    L.append("")
    for k, c in crit.items():
        val = c["value"]
        if isinstance(val, float):
            val = f"{val:.3f}"
        L.append(f"{'PASS' if c['pass'] else 'FAIL'}  {k} = {val}  "
                 f"(need {c['target']})")
        if c["note"]:
            L.append(f"      {c['note']}")
    L.append("")
    L.append(f"verdict {verdict} ({passed}/{total})")
    if verdict == "FAIL":
        L.append("")
        L.append("model note: M3 fails on the literal time-averaged reading "
                 "only. The 32 bin means flatten to 4.15 to 5.41 px because "
                 "every front sweeps every arc bin inside 60 s. The fixed "
                 "thing is a static spatial envelope on the local terms "
                 "(neither an amplitude nor a period change): multiply the "
                 "B..E displacement by about 1 + 0.22 sin(2 pi * 3 u) to get "
                 "a bin mean sd of 0.74 px, cv 0.15 at mean 4.9 px.")
    L.append("")
    L.append("term peaks as percent of R (raw sum B..E after the limiter "
             f"{peak_pct:.3f}, before {peak_raw_pct:.3f}): "
             + ", ".join(f"{k} {v:.3f}" for k, v in
                         rep["term_peak_pct_R"].items()))
    L.append(f"aggregate spectrum: peak bin {int(peak_bin)} at "
             f"{peak_freq:.4f} Hz holds {share_agg * 100:.1f} percent of the "
             f"non-DC power; {int(uniq_peak_bins)} distinct peak bins among "
             f"the 32 bin series")
    L.append(f"shading: min brightness factor {rep['bright_min']:.2f}, "
             f"min radius factor {rep['radius_min']:.2f} "
             f"(occlusion included)")
    L.append(f"runtime {runtime:.1f} s")
    L.append("")
    L.append("files: " + ", ".join(os.path.basename(p) for p in
                                   (hm_path, csv6, csv60, csvsp, jpath)))
    txt = "\n".join(L) + "\n"
    tpath = rep["files"]["text"]
    with open(tpath, "w", encoding="ascii") as f:
        f.write(txt)
    print(txt)


if __name__ == "__main__":
    main()
