#!/usr/bin/env python3
"""bench_stt.py: whisper.cpp GT 1030 (CUDA) vs CPU, 3 English clips, WER + latency + VRAM.

Usage: python3 bench_stt.py [gpu|cpu|both]   (appends nothing; rewrites results.json)
Each run goes through run_one.sh -> flock -x bench/.gpu.lock -> bench/watchdog.sh.
Raw per-run outputs: logs-gt1030/bench/<mode>/<model>/<clip>-r<k>.{txt,err,rc,wall_ms,smi.csv}
"""
import json, os, re, statistics, subprocess, sys

LAB = os.path.expanduser("~/NEXUS_AI_CENTER/LOCAL-AI-LAB")
VOICE = os.path.join(LAB, "voice/gt1030-stt")
CLIPS = os.path.join(VOICE, "clips")
LOGS = os.path.join(LAB, "logs-gt1030/bench")
MODELS = ["ggml-small.en.bin", "ggml-medium.en-q5_0.bin", "ggml-large-v3-turbo-q5_0.bin"]
REPS = 3
GPU_TOTAL_MIB = 2048

NUMWORDS = {w: str(i) for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
    "fifteen sixteen seventeen eighteen nineteen twenty".split())}
NUMWORDS.update({"thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
                 "eighty": "80", "ninety": "90"})

def norm(text):
    # Scoring normalisation: "80%" == "eighty percent", "9" == "nine" (else WER counts format, not ASR)
    text = re.sub(r"[^a-z0-9' ]+", " ", text.lower().replace("\u2019", "'").replace("%", " percent "))
    return [NUMWORDS.get(t, t) for t in text.split() if t != "percent"]

def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev = cur
    return d[len(h)] / max(1, len(r))

def refs():
    out = {}
    for line in open(os.path.join(CLIPS, "refs.tsv")):
        cid, text = line.rstrip("\n").split("\t", 1)
        out[cid] = text
    return out

def parse_timings(err):
    def grab(name):
        m = re.search(name + r"\s*=\s*([\d.]+) ms", err)
        return float(m.group(1)) if m else None
    return {"load_ms": grab("load time"), "encode_ms": grab("encode time"),
            "decode_ms": grab("decode time"), "total_ms": grab("total time")}

def clip_seconds(path):
    import wave
    with wave.open(path) as w:
        return w.getnframes() / w.getframerate()

def run(mode, model, cid, rep):
    clip = os.path.join(CLIPS, cid + ".wav")
    out = os.path.join(LOGS, mode, model[:-4], f"{cid}-r{rep}")
    subprocess.run(["bash", os.path.join(VOICE, "run_one.sh"), mode,
                    os.path.join(LAB, "models/stt/whisper", model), clip, out],
                   capture_output=True, text=True, timeout=900)
    rc = int(open(out + ".rc").read().strip())
    txt = open(out + ".txt").read().strip()
    err = open(out + ".err").read()
    res = {"mode": mode, "model": model, "clip": cid, "rep": rep, "rc": rc,
           "hyp": txt, "wer": wer(refs()[cid], txt),
           "wall_ms": int(open(out + ".wall_ms").read()),
           "log": os.path.relpath(out + ".err", LAB)}
    res.update(parse_timings(err))
    if mode == "gpu" and os.path.exists(out + ".smi.csv"):
        used = [int(l.split(",")[0]) for l in open(out + ".smi.csv") if l.strip()]
        res["peak_vram_mib"] = max(used) if used else None
        res["smi_log"] = os.path.relpath(out + ".smi.csv", LAB)
    res["clip_s"] = clip_seconds(clip)
    if res.get("total_ms"):
        res["rtf"] = res["total_ms"] / 1000 / res["clip_s"]
    print(json.dumps({k: res[k] for k in ("mode", "model", "clip", "rep", "rc", "total_ms", "wer", "peak_vram_mib") if k in res}), flush=True)
    return res

def main():
    modes = ["gpu", "cpu"] if len(sys.argv) < 2 or sys.argv[1] == "both" else [sys.argv[1]]
    results = []
    for mode in modes:
        for model in MODELS:
            for cid in sorted(refs()):
                for rep in range(1, REPS + 1):
                    results.append(run(mode, model, cid, rep))
    with open(os.path.join(VOICE, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    print("DONE", len(results), "runs", flush=True)

if __name__ == "__main__":
    main()
