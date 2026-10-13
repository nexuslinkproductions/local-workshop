#!/usr/bin/env python3
"""perf-agg.py <label-prefix-regex> [control-label] : table per label x depth from logs/perf62/<label>-r<N>-*.json.
decode = median over the run medians (one per interleaved rep), range = min..max of ALL individual decodes,
sha = output sha per depth vs control (same prompt, same depth); 'same'/'DIFF'."""
import glob, json, os, re, statistics, sys
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs/perf62")
pat = re.compile(sys.argv[1]); ctl = sys.argv[2] if len(sys.argv) > 2 else "tip"
runs = {}
for f in sorted(glob.glob(f"{D}/*-r[0-9]*-*.json")):
    m = re.match(r"(.+)-r(\d+)-\d+\.json", os.path.basename(f))
    if not m or not (pat.search(m[1]) or m[1] == ctl): continue
    try: j = json.load(open(f))
    except Exception: continue
    runs.setdefault(m[1], []).append((int(m[2]), j, f))
def shas(j, d): return set(j["depths"][d]["sha"])
base = {}
for r, j, f in runs.get(ctl, []):
    for d in j["depths"]: base.setdefault(d, set()).update(shas(j, d))
print("label\tdepth\truns\trun_medians\tmedian\tmin-max(all)\tprefill_tps(med)\tsha\tvs_" + ctl)
for lab in sorted(runs):
    ds = sorted({d for _, j, _ in runs[lab] for d in j["depths"]}, key=int)
    for d in ds:
        rr = [(r, j["depths"][d]) for r, j, _ in runs[lab] if d in j["depths"]]
        meds = [x["median"] for _, x in rr]; allv = [v for _, x in rr for v in x["dec"]]
        pf = [x["prefill_tps"] for _, x in rr if x["prefill_tps"]]
        sh = set().union(*[set(x["sha"]) for _, x in rr])
        same = "same" if (d in base and sh == base[d] and len(sh) == 1) else ("DIFF" if d in base else "?")
        print(f"{lab}\t{d}\t{len(rr)}\t{meds}\t{statistics.median(meds):.2f}\t{min(allv):.2f}-{max(allv):.2f}\t{statistics.median(pf) if pf else '-'}\t{','.join(sorted(sh))}\t{same}")
