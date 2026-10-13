#!/usr/bin/env python3
"""results-openvino.py — append one row to bench/results-openvino.tsv.

Schema (this file owns it; both engine runners import it):

    timestamp  engine  version  model  quant  prompt_tokens  ttft_ms  decode_tps  free_vram_mib  gpu_state

`free_vram_mib` comes from arc-vram.py (DRM fdinfo sum, no GPU touch);
`gpu_state` is `game-open` when PioneerGame.exe is up, else `clean` — the SAME
tag vocabulary gate.sh uses, so rows can be filtered either way.

    from importlib import import_module
    row = import_module("results-openvino")
    row.append_row("openvino-genai", "2026.4.1", "Qwen3-4B-int4-ov", "int4", 512, 320.5, 42.1)
"""
import datetime
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results-openvino.tsv")
COLS = ["timestamp", "engine", "version", "model", "quant", "prompt_tokens",
        "ttft_ms", "decode_tps", "free_vram_mib", "gpu_state"]


def free_vram_mib():
    out = subprocess.run([sys.executable, os.path.join(HERE, "arc-vram.py")],
                         capture_output=True, text=True).stdout
    return int(out.split("free=")[1].split()[0])


def gpu_state():
    r = subprocess.run(["pgrep", "-f", r"PioneerGame\.exe"], capture_output=True, text=True)
    return "game-open" if r.stdout.strip() else "clean"


def append_row(engine, version, model, quant, prompt_tokens, ttft_ms, decode_tps):
    row = [datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           engine, version, model, quant, str(prompt_tokens),
           f"{ttft_ms:.1f}", f"{decode_tps:.2f}", str(free_vram_mib()), gpu_state()]
    new = not os.path.exists(RESULTS) or os.path.getsize(RESULTS) == 0
    with open(RESULTS, "a") as f:
        if new:
            f.write("\t".join(COLS) + "\n")
        f.write("\t".join(row) + "\n")
    return "\t".join(row)


if __name__ == "__main__":
    ap = sys.argv[1:]
    if "--selftest" in ap:
        d = {"engine": "t", "version": "v", "model": "m", "quant": "q",
             "prompt_tokens": "1", "ttft_ms": "2.0", "decode_tps": "3.0"}
        row = [d["engine"], d["version"], d["model"], d["quant"], d["prompt_tokens"],
               f"{float(d['ttft_ms']):.1f}", f"{float(d['decode_tps']):.2f}"]
        assert row == ["t", "v", "m", "q", "1", "2.0", "3.00"], row
        assert len(COLS) == 10
        print("selftest ok: row shape")
        sys.exit(0)
    # CLI: --engine --version --model --quant --prompt-tokens --ttft-ms --decode-tps
    kw = {}
    i = 0
    while i < len(ap):
        kw[ap[i].lstrip("-").replace("-", "_")] = ap[i + 1]
        i += 2
    print(append_row(kw["engine"], kw["version"], kw["model"], kw["quant"],
                     kw["prompt_tokens"], float(kw["ttft_ms"]), float(kw["decode_tps"])))
