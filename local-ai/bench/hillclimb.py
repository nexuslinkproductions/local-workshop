#!/usr/bin/env python3
"""hillclimb.py — one-at-a-time lever hillclimb over a bench/configs matrix config.

Baseline is the starting point, not the result: measure, then try levers one at a
time; keep a lever only if pp or tg improves >= MIN_GAIN % (default 3) over the
current best, revert it otherwise. Every attempt is logged as a row in
results-matrix.tsv with notes="lever:<name> kept|reverted ...".

    hillclimb.py --cfg configs/matrix-istaiq3s.env --levers levers/hclimb-dense.json
                 [--reps 3] [--depths 0] [--min-gain 3]

Mechanics: each attempt writes a throwaway config (base cfg + EXTRA=(<lever flags>))
into $TMPDIR and runs matrix-bench.sh with MATRIX_RESULTS=<scratch>, so no harness
code is duplicated; the scratch row is then copied into the real results file with
its notes rewritten to carry the verdict. The whole climb runs inside ONE
exclusive lock (MATRIX_LOCKED=1 for the children), like a server session.

Lever file: [{"name": "...", "flags": ["-ncmoe", "24"], "cfg": {"BINDIR": "..."}}, ...]
  flags -> appended to the run's EXTRA; cfg -> per-lever config overrides (e.g. to
  switch BINDIR/ENVSH/DEVICE_NAME for a Vulkan-vs-SYCL lever).
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from importlib import import_module  # noqa: E402

row_mod = import_module("matrix-row")


def sh(cmd, env=None, timeout=7200):
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
    return p


def measure(cfg, scratch, lever_name, extra_flags, cfg_over, base_extra, args):
    """Run one attempt through matrix-bench.sh; return the scratch row (dict)."""
    text = open(cfg).read()
    text = text.replace("EXTRA=()", "")
    over = "".join(f"{k}={shlex.quote(str(v))}\n" for k, v in cfg_over.items())
    flags = " ".join(shlex.quote(f) for f in (list(base_extra) + list(extra_flags)))
    tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"hclimb-{os.getpid()}.env")
    with open(tmp, "w") as f:
        f.write(text + over + f"\nEXTRA=({flags})\nDEPTHS={shlex.quote(str(args.depths))}\n"
                                f"REPS={args.reps}\n"
                                f"NOTE=\"lever:{lever_name}\"\n")
    env = dict(os.environ, MATRIX_LOCKED="1", MATRIX_RESULTS=scratch)
    env.update({k: str(v) for k, v in cfg_over.items() if k.endswith("_OVERRIDE")})
    before_n = 0
    if os.path.exists(scratch):
        before_n = len([l for l in open(scratch).read().splitlines()[1:] if l.strip()])
    t0 = time.time()
    p = sh([os.path.join(HERE, "matrix-bench.sh"), "run", "--cfg", tmp], env=env)
    dt = time.time() - t0
    if p.returncode != 0:
        print(f"  !! matrix-bench rc={p.returncode}: {p.stderr[-400:]}", flush=True)
    try:
        lines = open(scratch).read().splitlines()
        new = [l for l in lines[1:] if l.strip() and len(l.split("\t")) == len(row_mod.COLS)]
    except OSError:
        new = []
    # only the rows THIS attempt appended — the scratch file accumulates across attempts,
    # so new[-2:] would return the previous attempt's rows and mislabel both the data and
    # the keep/revert verdict (that bug silently made every gain read as +0.0%).
    rows = [dict(zip(row_mod.COLS, l.split("\t"))) for l in new[before_n:]]
    err = "" if p.returncode == 0 else (p.stderr or "").strip().replace("\n", " ")[-300:]
    print(f"  [{dt:.0f}s] rc={p.returncode} rows={len(rows)}", flush=True)
    return rows, p.returncode, err


def pick(rows, want):
    for r in rows:
        if r["test"].startswith(want):
            return float(r["tps_mean"] or 0)
    return None


def fail_row(a, name, rc, err):
    """Log an explicit FAILED row (no measurement) so a dead run never reads as +0.0%."""
    row_mod.append(a.results, timestamp=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                   test="lever-failed", tps_mean="", tps_std="", ttft_ms="",
                   tool_call_pass="", notes=f"lever:{name} FAILED rc={rc} {err}"[:900])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cfg", required=True)
    ap.add_argument("--levers", required=True)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--depths", default="0")
    ap.add_argument("--min-gain", type=float, default=3.0)
    ap.add_argument("--results", default=os.path.join(HERE, "results-matrix.tsv"))
    ap.add_argument("--scratch", default=os.environ.get("TMPDIR", "/tmp") + "/hclimb-scratch.tsv")
    ap.add_argument("--state", default="")
    a = ap.parse_args()

    cfg = a.cfg if os.path.isabs(a.cfg) else os.path.join(HERE, a.cfg)
    levers = a.levers if os.path.isabs(a.levers) else os.path.join(HERE, a.levers)
    plan = json.load(open(levers))
    state_path = a.state or os.path.join(HERE, "hillclimb-" + os.path.basename(cfg).replace(".env", "") + ".json")
    if os.path.exists(state_path):
        state = json.load(open(state_path))
    else:
        state = {"best": None, "history": []}

    def record(rows, lever, verdict):
        for r in rows:
            r["notes"] = (f"lever:{lever} {verdict} " + r.get("notes", ""))[:900]
            row_mod.append(a.results, **{k: r.get(k, "") for k in row_mod.COLS})
        # keep the state file next to the harness so a resume can see the plan
        state["history"].append({"lever": lever, "verdict": verdict})
        json.dump(state, open(state_path, "w"), indent=1)

    # ---- baseline ---------------------------------------------------------
    print(f"== baseline {os.path.basename(cfg)} (reps={a.reps} depths={a.depths})", flush=True)
    base_rows, rc0, err0 = measure(cfg, a.scratch, "baseline", [], {}, [], a)
    pp0, tg0 = pick(base_rows, "pp"), pick(base_rows, "tg")
    if pp0 is None and tg0 is None:
        fail_row(a, "baseline", rc0, err0)
        sys.exit("baseline failed to run — nothing to climb")
    state["best"] = {"name": "baseline", "flags": [], "pp": pp0, "tg": tg0}
    record(base_rows, "baseline", "baseline")
    print(f"   baseline pp={pp0} tg={tg0}", flush=True)

    # ---- levers ----------------------------------------------------------
    for lev in plan:
        name = lev["name"]
        # a "reset" lever is measured on its own, not stacked on the current best:
        # flags like -b/-ub accumulate into a llama-bench PARAMETER SWEEP when repeated,
        # so stacking them measures a cross-product, not the lever.
        base_extra = [] if lev.get("reset") else state["best"]["flags"]
        rec, rc, err = measure(cfg, a.scratch, name + " attempt", lev.get("flags", []),
                               lev.get("cfg", {}), base_extra, a)
        pp, tg = pick(rec, "pp"), pick(rec, "tg")
        if pp is None and tg is None:
            # a run that produced no usable row is a FAILURE, not a neutral revert:
            # log it explicitly with the harness error tail so it cannot read as +0.0%.
            fail_row(a, name, rc, err)
            state["history"].append({"lever": name, "verdict": f"FAILED rc={rc}"})
            json.dump(state, open(state_path, "w"), indent=1)
            print(f"   {name}: FAILED rc={rc} {err[:160]}", flush=True)
            continue
        best = state["best"]
        gpp = (pp - best["pp"]) / best["pp"] * 100 if (pp and best["pp"]) else 0
        gtg = (tg - best["tg"]) / best["tg"] * 100 if (tg and best["tg"]) else 0
        if gpp >= a.min_gain or gtg >= a.min_gain:
            kept_flags = ([] if lev.get("reset") else best["flags"]) + lev.get("flags", [])
            state["best"] = {"name": name, "flags": kept_flags,
                             "pp": pp, "tg": tg, "cfg": {**best.get("cfg", {}), **lev.get("cfg", {})}}
            verdict = f"kept (pp {gpp:+.1f}% tg {gtg:+.1f}% vs {best['name']})"
        else:
            verdict = f"reverted (pp {gpp:+.1f}% tg {gtg:+.1f}% vs {best['name']})"
        record(rec, name, verdict)
        print(f"   {name}: {verdict}", flush=True)
        if lev.get("cfg"):
            print("   NOTE: this lever changed config keys; stacked levers after a "
                  "cfg-changing lever are measured against the new config", flush=True)

    b = state["best"]
    print(f"\nBEST: {b['name']} pp={b['pp']} tg={b['tg']}")
    print("flags: " + " ".join(b["flags"]) + " " + json.dumps(b.get("cfg", {})))


if __name__ == "__main__":
    main()
