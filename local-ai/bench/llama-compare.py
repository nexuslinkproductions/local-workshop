#!/usr/bin/env python3
"""llama-compare.py — llama.cpp Vulkan rows for the OpenVINO head-to-head.

Runs the command the bake-off pins, once with fresh context and once with -d 4096,
and folds each depth's pp + tg result into ONE row matching the OpenVINO shape:

    llama-bench -m <gguf> -dev Vulkan0 -ngl 99 -fa 1 -p 512 -n 128 -r 3 -d 0,4096

llama-bench reports prefill tok/s, not TTFT, so TTFT is derived as
`prompt_tokens / prefill_tps * 1000` (prefill-only; flagged in the report).
Rows go to bench/results-openvino.tsv via results-openvino.py.

    flock -x bench/.gpu.lock python3 bench/llama-compare.py \\
        --model models/llm/compare/Qwen3-4B-Q4_K_M.gguf
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module  # noqa: E402

row = import_module("results-openvino")

BIN = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/llm/llama.cpp/build/bin/llama-bench"
CLI = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/llm/llama.cpp/build/bin/llama-cli"


def vulkan_free():
    """llama-cli's own Vulkan heap report: 'free total' MiB, or '' if unavailable."""
    try:
        out = subprocess.run([CLI, "--list-devices"], capture_output=True, text=True).stdout
        line = [l for l in out.splitlines() if "Vulkan0:" in l][-1]
        inside = line.rsplit("(", 1)[1]
        free, total = inside.split("MiB,")[0].strip(), inside.split("MiB,")[1].split("MiB")[0].strip()
        return f"{free}/{total} MiB (llama Vulkan)"
    except Exception:
        return "n/a"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--depths", default="0,4096")
    ap.add_argument("--p", type=int, default=512)
    ap.add_argument("--n", type=int, default=128)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--quant", default="Q4_K_M")
    a = ap.parse_args()

    ver = subprocess.run([BIN, "--version"], capture_output=True, text=True)
    ver = (ver.stdout + ver.stderr).strip().splitlines()[-1][:60] if (ver.stdout or ver.stderr) else "?"
    print("# llama.cpp", ver, "| Vulkan free:", vulkan_free())

    cmd = [BIN, "-m", a.model, "-dev", "Vulkan0", "-ngl", "99", "-fa", "1",
           "-p", str(a.p), "-n", str(a.n), "-r", str(a.reps), "-o", "json",
           "-d", a.depths]
    print("# " + " ".join(cmd), flush=True)
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr[-3000:], file=sys.stderr)
        sys.exit(out.returncode)
    data = json.loads(out.stdout)
    if isinstance(data, dict):
        data = data.get("results", [])

    depths = {}
    for e in data:
        d = int(e.get("n_depth", 0))
        tps, sd = float(e["avg_ts"]), float(e.get("stddev_ts", 0.0))
        if e.get("n_prompt", 0):                       # prefill test -> ttft
            depths.setdefault(d, {})["pp"] = (tps, sd, int(e["n_prompt"]))
        else:                                          # decode test -> decode tok/s
            depths.setdefault(d, {})["tg"] = (tps, sd, int(e["n_gen"]))

    model_name = os.path.basename(a.model)
    for d in sorted(depths):
        pp, tg = depths[d].get("pp"), depths[d].get("tg")
        if not pp or not tg:
            print(f"  depth={d}: incomplete (pp={pp} tg={tg})", file=sys.stderr)
            continue
        prompt_tokens = pp[2] if d == 0 else d        # depth is context before the prompt
        ttft_ms = pp[2] / pp[0] * 1000.0
        print(f"  depth={d} prefill={pp[0]:.1f}tok/s (ttft~{ttft_ms:.0f}ms) "
              f"decode={tg[0]:.2f}tok/s ±{tg[1]:.2f}")
        print("  row:", row.append_row("llama.cpp-vulkan", ver, model_name, a.quant,
                                       prompt_tokens, ttft_ms, tg[0]))


if __name__ == "__main__":
    main()
