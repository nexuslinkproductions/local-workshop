#!/usr/bin/env python3
"""perf-probe.py <port> <depths-csv> <reps> [--prof SESSION] -> one JSON object on stdout.
Depth curve on ONE growing llama-server session (cache_prompt=true), research/62-perf-lead.md.
At each depth: fill request (prefill t/s), then <reps> identical greedy 256-token decodes (cache hit),
decode t/s = timings.predicted_per_second, plus sha12 of each output.
sha0 = the speed-push hash-table prompt (128 tok, cache off) -> compare with baseline 4159a18759fb.
--prof SESSION: unitrace session started paused; resume it only around the decode reps of each depth
(fill stays unprofiled), pause after. unitrace binary path in UT."""
import hashlib, json, statistics, subprocess, sys, urllib.request

port, depths, reps = sys.argv[1], [int(x) for x in sys.argv[2].split(",")], int(sys.argv[3])
prof = sys.argv[sys.argv.index("--prof") + 1] if "--prof" in sys.argv else None
UT = "/home/nexuslink/.hermes/cache/scratch/kprof/pti-gpu/tools/unitrace/build/unitrace"
base = f"http://127.0.0.1:{port}"
sha = lambda s: hashlib.sha256(s.encode()).hexdigest()[:12]


def post(path, body):
    req = urllib.request.Request(base + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1500) as r:
        return json.load(r)


def chat(text, n, cache):
    r = post("/v1/chat/completions", {"messages": [{"role": "user", "content": text}], "max_tokens": n, "temperature": 0,
                                      "cache_prompt": cache, "chat_template_kwargs": {"enable_thinking": False}})
    m = r["choices"][0]["message"]
    return (m.get("content") or "") + (m.get("reasoning_content") or ""), r["timings"]


ESSAY = "Write a detailed essay about the history of the printing press: its inventors, its spread across Europe and its social effects."
rec = lambda i: f"Record {i}: sensor {i*7919%10007} reported {i*104729%9973} units at node {i%97}.\n"
tpr = len(post("/tokenize", {"content": "".join(rec(i) for i in range(400))})["tokens"]) / 400
HDR = "Read the records below, then follow the final instruction.\n\n"
TAIL = "\nFinal instruction: ignore the records. " + ESSAY


def build(n):
    return HDR + "".join(rec(i) for i in range(n)) + TAIL


def prompt(depth):
    if depth == 0:
        return ESSAY
    n = int(depth / tpr)
    for _ in range(2):   # digits grow with i, so re-scale n against the server tokenizer
        got = len(post("/tokenize", {"content": build(n)})["tokens"])
        n = int(n * depth / got)
    return build(n)


out = {"tokens_per_record": round(tpr, 3), "depths": {}}
chat("Say OK", 8, False)
t, _ = chat("Explain step by step how a hash table handles collisions, with a short example.", 128, False)
out["sha0"] = sha(t)


def ctl(op):
    if prof:
        subprocess.run([UT, f"--{op}", prof], check=False, capture_output=True)


for d in depths:
    p = prompt(d)
    _, ft = chat(p, 1, True) if d else (None, {"prompt_n": 0, "cache_n": 0, "prompt_per_second": 0})
    row = {"fill_prompt_n": ft["prompt_n"], "fill_cache_n": ft["cache_n"], "prefill_tps": round(ft["prompt_per_second"], 1), "dec": [], "sha": [], "n": []}
    chat(p, 8, True)   # settle (cache hit, tiny decode); not measured
    ctl("resume")
    for _ in range(reps):
        t, tm = chat(p, 256, True)
        row["dec"].append(round(tm["predicted_per_second"], 2)); row["sha"].append(sha(t)); row["n"].append(tm["predicted_n"])
        row["depth_real"] = tm["prompt_n"] + tm["cache_n"]
    ctl("pause")
    row["median"] = statistics.median(row["dec"])
    out["depths"][str(d)] = row
    print(f"depth {d}: {row}", file=sys.stderr, flush=True)
print(json.dumps(out))
