#!/usr/bin/env python3
"""aggregate_stt.py: rebuild results.json from the raw per-run files on disk and print the table.
Reads logs-gt1030/bench/<mode>/<model>/<clip>-r<k>.* (written by run_one.sh) — no re-running.
"""
import glob, json, os, statistics as st, sys, collections
sys.path.insert(0, os.path.dirname(__file__))
import bench_stt as B

R = []
for out in sorted(glob.glob(os.path.join(B.LOGS, "*", "*", "*.rc"))):
    base = out[:-3]
    mode = base.split(os.sep)[-3]
    model = os.path.basename(os.path.dirname(base)) + ".bin"
    if mode == "gpu":
        model = model.replace(".bin.bin", ".bin")
    name = os.path.basename(base)
    cid, rep = name.rsplit("-r", 1)
    rc = int(open(base + ".rc").read().strip())
    txt = open(base + ".txt").read().strip()
    err = open(base + ".err").read()
    r = {"mode": mode, "model": model, "clip": cid, "rep": int(rep), "rc": rc, "hyp": txt,
         "wer": B.wer(B.refs()[cid], txt), "wall_ms": int(open(base + ".wall_ms").read()),
         "log": os.path.relpath(base + ".err", B.LAB)}
    r.update(B.parse_timings(err))
    if mode == "gpu" and os.path.exists(base + ".smi.csv"):
        used = [int(l.split(",")[0]) for l in open(base + ".smi.csv") if l.strip()]
        r["peak_vram_mib"] = max(used) if used else None
    r["clip_s"] = B.clip_seconds(os.path.join(B.CLIPS, cid + ".wav"))
    if r.get("total_ms"):
        r["rtf"] = r["total_ms"] / 1000 / r["clip_s"]
    R.append(r)

R.sort(key=lambda r: (r["mode"], r["model"], r["clip"], r["rep"]))
with open(os.path.join(B.VOICE, "results.json"), "w") as f:
    json.dump(R, f, indent=1)

bad = [r for r in R if r["rc"] != 0 or not r.get("total_ms")]
print("runs:", len(R), "bad:", len(bad))
for r in bad:
    print("  BAD", r["mode"], r["model"], r["clip"], r["rep"], "rc", r["rc"])
g = collections.defaultdict(list)
for r in R:
    g[(r["mode"], r["model"])].append(r)
print("%-4s %-30s %3s %9s %9s %9s %7s %7s %8s" % ("mode", "model", "n", "total_ms", "wall_ms", "load_ms", "RTF", "WER", "peakMiB"))
for (mode, model), rs in sorted(g.items()):
    pv = [r["peak_vram_mib"] for r in rs if r.get("peak_vram_mib")]
    print("%-4s %-30s %3d %9.0f %9.0f %9.0f %7.3f %7.3f %8s" % (
        mode, model, len(rs), st.median(r["total_ms"] for r in rs), st.median(r["wall_ms"] for r in rs),
        st.median(r["load_ms"] for r in rs), st.median(r["rtf"] for r in rs),
        st.mean(r["wer"] for r in rs), max(pv) if pv else "-"))
