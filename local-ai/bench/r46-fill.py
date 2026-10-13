#!/usr/bin/env python3
"""r46-fill.py — run only the (kv, depth) cells that have no result yet, retrying watchdog aborts (rc 9).
Usage: r46-fill.py <prefix> <ub> <kv,kv,...> <depth,depth,...> [extra llama-bench args...]
Reads every bench/logs/r46/<prefix>-*.jsonl, so partial results of an aborted run count.
Stops at once on rc 4 (GPU fault). Max 5 attempts per kv. ponytail: serial, no backoff beyond a 60 s sleep."""
import glob, json, subprocess, sys, time
LAB = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB"
pre, ub, kvs, depths, extra = sys.argv[1], sys.argv[2], sys.argv[3].split(","), [int(x) for x in sys.argv[4].split(",")], sys.argv[5:]

def done(kv):
    d = set()
    for f in glob.glob(f"{LAB}/bench/logs/r46/{pre}-{kv}-*.jsonl"):
        for l in open(f):
            try:
                j = json.loads(l)
            except ValueError:
                continue
            d.add(j["n_depth"])
    return d

for kv in kvs:
    for att in range(5):
        todo = [x for x in depths if x not in done(kv)]
        if not todo:
            break
        lab = f"{pre}-{kv}-a{int(time.time())}"
        r = subprocess.run([f"{LAB}/bench/r46-depth.sh", lab, "-ctk", kv, "-ctv", kv, "-ub", ub, "-b", "1024", "-p", "0", "-n", "64",
                            "-d", ",".join(map(str, todo)), "-r", "2", *extra])
        print(f"[fill] {kv} attempt {att} todo={todo} rc={r.returncode}", flush=True)
        if r.returncode == 4:
            sys.exit(4)
        if r.returncode != 0:
            time.sleep(60)
print("[fill] done", {kv: sorted(done(kv)) for kv in kvs})
