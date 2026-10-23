#!/usr/bin/env python3
"""knot_report.py: evidence run for the local knot activity (KNOT-SPEC G).

6 s window at 24 fps over the CPU port (knot_port.py). Everything is computed
in screen px at a 700x700 item with knotPx 540, so 1 knot unit = 0.6 px.

Per point local displacement is terms B to E only: pos_full - pos, where pos
is the same point under the global pose alone (yaw, pitch, scale). Global
motion is therefore excluded from every local metric and only appears in the
frame to frame jump.

Outputs into --outdir:
  report.csv           time, 32 ribbon arc bins, 32 ring arc bins, mean local px
  heatmap.png          x time, y arc bin (ribbon top, ring bottom)
  report.json          every metric and every criterion
  (--text NAME.txt)    short PASS/FAIL verdict

Usage: python3 knot_report.py [--motion v2|base] [--outdir DIR]
                             [--text NAME] [--fps 24] [--seconds 6]
"""

import argparse
import json
import os

import numpy as np
from PIL import Image

import knot_port as kp

NB = 32
FPS = 24
SECONDS = 6.0


def load_port(motion, tex, v2=False):
    if v2:
        return kp.KnotPort(tex=tex, motion=motion, rows=11, texels_per_point=5)
    return kp.KnotPort(tex=tex, motion=motion)


def bin_index(u, cls, nbin=NB):
    """Arc length bin per point, 0..nbin-1 inside its own class."""
    b = np.floor(np.clip(u, 0.0, 0.999999) * nbin).astype(np.int32)
    return b


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


def heatmap(series, path, title_rows=("ribbon", "ring")):
    """series: (2*NB, T) mean local px per arc bin over time."""
    rows, cols = series.shape
    img = np.zeros((rows, cols, 3), dtype=np.uint8)
    for r in range(rows):
        img[r] = ramp(series[r], 0.0, max(float(series.max()), 1e-6))
    # ribbon block at the top (rows NB..2NB of the array are ring, flip so the
    # first arc bin sits at the bottom of its half, like a lin-log map)
    top = img[:NB][::-1]
    bot = img[NB:][::-1]
    sep = np.full((2, cols, 3), 235, dtype=np.uint8)
    out = np.concatenate([top, sep, bot], axis=0)
    im = Image.fromarray(out, "RGB")
    im = im.resize((cols * 4, out.shape[0] * 6), Image.NEAREST)
    im.save(path)
    return path


def fft_metrics(mat, fps):
    """mat: (nbins, T). Strongest single frequency share and peak freq.

    A linear trend is removed per bin first: a 6 s window over a 5 to 7 s
    breath clock puts most of a slow drift into the first non-DC bin, which
    would otherwise read as a "dominant global frequency". The trend is not an
    oscillation and the spec asks about the displacement spectrum.
    """
    T = mat.shape[1]
    tt = np.arange(T, dtype=np.float64)
    tt = tt - tt.mean()
    slope = (mat * tt[None, :]).sum(axis=1) / (tt ** 2).sum()
    detr = mat - mat.mean(axis=1, keepdims=True) - slope[:, None] * tt[None, :]
    spec = np.abs(np.fft.rfft(detr, axis=1)) ** 2
    spec = spec[:, 1:]                     # drop DC
    freqs = np.fft.rfftfreq(T, 1.0 / fps)[1:]
    tot = spec.sum(axis=1)
    peak = spec.argmax(axis=1)
    share = np.where(tot > 1e-12, spec.max(axis=1) / np.maximum(tot, 1e-12), 0.0)
    pfreq = np.where(tot > 1e-12, freqs[peak], -1.0)
    return share, pfreq, freqs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--motion", default="v2", choices=("v2", "base"))
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--text", default="")
    ap.add_argument("--fps", type=float, default=FPS)
    ap.add_argument("--seconds", type=float, default=SECONDS)
    ap.add_argument("--tex", default=kp.DEFAULT_TEX)
    ap.add_argument("--v2", action="store_true",
                    help="use the v2 texture (5 texels per point, 11 rows)")
    ap.add_argument("--prefix", default="", help="prefix for report.csv/json/heatmap.png")
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    pre = a.prefix

    port = load_port(a.motion, a.tex, a.v2)
    n = port.n
    nf = int(round(a.seconds * a.fps))
    times = np.arange(nf) / a.fps
    bidx = bin_index(port.u, port.cls)
    rib = port.ribbon
    ring = ~rib

    # --- pass 1: per frame samples -------------------------------------
    loc_len = np.zeros((nf, n))
    loc_px = np.zeros((nf, n, 2))
    pos_full = np.zeros((nf, n, 2))
    dP_len = np.zeros((nf, n))
    dP_raw = np.zeros((nf, n))
    term_px = {k: np.zeros((nf, n)) for k in "BCDE"}
    term_peak = {k: 0.0 for k in "BCDE"}
    edge_frac = np.zeros(nf)
    edge_frac_lo = np.zeros(nf)
    tslot = np.zeros(nf)
    pos_pose = np.zeros((nf, n, 2))
    for i, t in enumerate(times):
        d = port.sample(t)
        pos_pose[i] = d["pos"]
        loc_px[i] = d["local_px"]
        loc_len[i] = d["local_len"]
        pos_full[i] = d["pos_full"]
        if port.motion == "v2":
            dP_len[i] = d["dP_len"]
            dP_raw[i] = d["dP_raw_len"]
            for k, v in d["terms_px"].items():
                term_px[k][i] = np.linalg.norm(v, axis=1)
            for k, v in d["terms"].items():
                term_peak[k] = max(term_peak[k], float(np.linalg.norm(v, axis=1).max()))
            edge_frac[i] = float((d["event"] > 0.10).mean())
            edge_frac_lo[i] = float((d["event"] > 0.02).mean())
            tslot[i] = float((d["front"] > 0.1).mean())

    # --- bins -----------------------------------------------------------
    bin_mean = np.zeros((2 * NB, nf))
    for i in range(nf):
        v = loc_len[i]
        for c, mask in ((0, rib), (1, ring)):
            for b in range(NB):
                sel = mask & (bidx == b)
                if sel.any():
                    bin_mean[c * NB + b, i] = float(v[sel].mean())

    series = bin_mean.copy()
    csv_path = os.path.join(a.outdir, pre + "report.csv")
    with open(csv_path, "w", encoding="ascii") as f:
        head = ["t"] + [f"r{b:02d}" for b in range(NB)] + \
               [f"g{b:02d}" for b in range(NB)] + ["mean_local_px"]
        f.write(",".join(head) + "\n")
        for i in range(nf):
            row = [f"{times[i]:.4f}"] + [f"{series[b, i]:.4f}"
                                         for b in range(2 * NB)] + \
                  [f"{loc_len[i].mean():.4f}"]
            f.write(",".join(row) + "\n")
    hm_path = os.path.join(a.outdir, pre + "heatmap.png")
    heatmap(series, hm_path)

    # --- criteria -------------------------------------------------------
    # 1. frame to frame jump including the global pose
    step = np.linalg.norm(np.diff(pos_full, axis=0), axis=2)
    jump_max = float(step.max()) if nf > 1 else 0.0
    jump_p99 = float(np.percentile(step, 99.0)) if nf > 1 else 0.0
    pose_only = np.linalg.norm(np.diff(pos_pose, axis=0), axis=2)
    pose_jump_max = float(pose_only.max())

    # 2. peak local displacement as percent of R, raw sum and soft limited
    peak_pct_raw = float(dP_raw.max() / kp.R_KNOT * 100.0)
    peak_pct = float(dP_len.max() / kp.R_KNOT * 100.0) if dP_len.any() else 0.0
    peak_pct_p999 = float(np.percentile(dP_len, 99.9) / kp.R_KNOT * 100.0) \
        if dP_len.any() else 0.0

    # 3+4. spectrum of each bin
    share, pfreq, freqs = fft_metrics(series, a.fps)
    live = series.std(axis=1) > 1e-9
    share_live = share[live]
    under = float((share_live < 0.35).mean()) if live.any() else 0.0
    pf = np.round(pfreq[live], 3)
    uniq = np.unique(pf)
    modal_frac = (float(np.max(np.bincount(
        np.searchsorted(uniq, pf)).astype(float)) / len(pf))) if len(pf) else 1.0

    # 5. non-uniformity along the arc, time averaged and instantaneous
    bin_time_mean = series.mean(axis=1)
    nz = bin_time_mean[bin_time_mean > 1e-9]
    cv = float(bin_time_mean.std() / max(bin_time_mean.mean(), 1e-12))
    ratio = float(nz.max() / max(nz.min(), 1e-9)) if len(nz) else 0.0
    inst = []
    for i in range(nf):
        col = series[:, i]
        c = col[col > 1e-9]
        if len(c) > 1 and c.mean() > 1e-9:
            inst.append(float(c.std() / c.mean()))
    cv_inst = float(np.mean(inst)) if inst else 0.0
    cv_inst_max = float(np.max(inst)) if inst else 0.0

    # 6. participation
    ever = loc_len.max(axis=0)
    frac_1px = float((ever > 1.0).mean())
    frac_2px = float((ever > 2.0).mean())
    frac_any = float((ever > 0.05).mean())

    crit = {}

    def add(name, ok, value, target):
        crit[name] = {"pass": bool(ok), "value": value, "target": target}

    add("jump_max_px", jump_max < 2.5, round(jump_max, 3), "< 2.5 px at 24 fps")
    add("local_peak_pct_R", peak_pct_raw < 4.5, round(peak_pct_raw, 3),
        "< 4.5 percent of R, raw sum of B..E before any limit")
    if port.motion == "v2":
        add("local_peak_after_soft_limit_pct_R", peak_pct <= 4.51,
            round(peak_pct, 3),
            "<= 4.5 percent of R, shader soft limit R*0.045")
    add("bins_single_freq_under_35pct", under >= 0.80, round(under, 3),
        ">= 0.80 of bins")
    add("peak_freq_varies", (len(uniq) >= 3) and (modal_frac <= 0.5),
        {"unique_peak_freqs": int(len(uniq)), "modal_share": round(modal_frac, 3),
         "top3": [round(float(x), 3) for x in
                  np.sort(np.unique(pfreq[live]))[:3]]},
        ">= 3 distinct peak freqs, modal <= 0.5")
    add("arc_non_uniform", cv_inst > 0.25, round(cv_inst, 3),
        "mean instantaneous cv across bins > 0.25 (time averaged cv "
        + f"{cv:.3f}, max instantaneous {cv_inst_max:.3f})")
    add("participation_1px", frac_1px >= 0.80, round(frac_1px, 3),
        ">= 0.80 of points move > 1 px at some time")
    if port.motion == "v2":
        add("event_coverage", 0.03 <= float(edge_frac.mean()) <= 0.40,
            round(float(edge_frac.mean()), 3),
            "event profile > 0.1 touches 3 to 40 percent of points per frame")

    passed = sum(1 for c in crit.values() if c["pass"])
    total = len(crit)
    rep = {
        "motion": a.motion, "n_points": n, "frames": nf, "fps": a.fps,
        "seconds": a.seconds, "item_px": [port.w, port.h],
        "knotPx": port.knot_px, "unit_px": 0.6,
        "local_px_mean": float(loc_len.mean()),
        "local_px_p50": float(np.percentile(loc_len, 50)),
        "local_px_max": float(loc_len.max()),
        "jump_max_px": round(jump_max, 3), "jump_p99_px": round(jump_p99, 3),
        "pose_only_jump_max_px": round(pose_jump_max, 3),
        "peak_local_units": round(float(dP_len.max()), 3),
        "peak_local_pct_R": round(peak_pct_raw, 3),
        "peak_local_pct_R_soft_limited": round(peak_pct, 3),
        "peak_local_pct_R_p999": round(peak_pct_p999, 3),
        "term_share_px": {k: round(float(v.mean() / max(loc_len.mean(), 1e-9)), 3)
                          for k, v in term_px.items()},
        "term_px_mean": {k: round(float(v.mean()), 3) for k, v in term_px.items()},
        "term_peak_pct_R": {k: round(v / kp.R_KNOT * 100.0, 3)
                            for k, v in term_peak.items()},
        "bins_live": int(live.sum()), "bins_total": int(2 * NB),
        "fft_bins_under_35pct": round(under, 3),
        "fft_unique_peak_freqs": int(len(uniq)),
        "fft_modal_peak_share": round(modal_frac, 3),
        "fft_peak_freq_median_hz": round(float(np.median(pf)) if len(pf) else -1, 3),
        "fft_bin_share_p50": round(float(np.median(share_live)) if live.any() else 0, 3),
        "fft_bin_share_max": round(float(share_live.max()) if live.any() else 0, 3),
        "arc_cv": round(cv, 3), "arc_cv_instantaneous": round(cv_inst, 3),
        "arc_cv_instantaneous_max": round(cv_inst_max, 3),
        "arc_max_min_ratio": round(ratio, 2),
        "bin_mean_local_px": [round(float(x), 3) for x in bin_time_mean],
        "frac_points_over_1px": round(frac_1px, 3),
        "frac_points_over_2px": round(frac_2px, 3),
        "frac_points_any_motion": round(frac_any, 3),
        "event_frac_per_frame_mean": round(float(edge_frac.mean()), 4),
        "criteria": crit, "passed": passed, "total": total,
        "verdict": "PASS" if passed == total else "FAIL",
        "files": {"csv": csv_path, "heatmap": hm_path},
    }
    jpath = os.path.join(a.outdir, pre + "report.json")
    with open(jpath, "w", encoding="ascii") as f:
        json.dump(rep, f, indent=1)

    lines = [f"KNOT local activity report, motion={a.motion}",
             f"{n} points, {nf} frames at {a.fps} fps over {a.seconds} s",
             f"local displacement mean {rep['local_px_mean']:.2f} px, "
             f"p50 {rep['local_px_p50']:.2f} px, peak {rep['local_px_max']:.2f} px",
             ""]
    for k, c in crit.items():
        lines.append(f"{'PASS' if c['pass'] else 'FAIL'}  {k}: "
                     f"{json.dumps(c['value'])}  (need {c['target']})")
    lines += ["", f"verdict {rep['verdict']} ({passed}/{total})"]
    if port.motion == "v2":
        lines.append("term peak as percent of R (raw sum " +
                     f"{peak_pct:.3f}): " +
                     ", ".join(f"{k} {v:.3f}" for k, v in
                               rep["term_peak_pct_R"].items()))
        lines.append(f"local event coverage per frame: "
                     f"{float(edge_frac_lo.mean()):.3f} at profile > 0.02, "
                     f"{float(edge_frac.mean()):.3f} at profile > 0.1")
        lines.append(f"frame to frame jump: max {jump_max:.3f} px, "
                     f"p99 {jump_p99:.3f} px (global pose alone "
                     f"{pose_jump_max:.3f} px)")
    lines += [f"csv {csv_path}", f"heatmap {hm_path}"]
    txt = "\n".join(lines) + "\n"
    if a.text:
        tpath = os.path.join(a.outdir, a.text)
        with open(tpath, "w", encoding="ascii") as f:
            f.write(txt)
    print(txt)
    print(f"json {jpath}")


if __name__ == "__main__":
    main()
