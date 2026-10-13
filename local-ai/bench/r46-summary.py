#!/usr/bin/env python3
"""r46-summary.py <label>... — one markdown row per needle step of bench/logs/chief256k/<label>.json.
Columns: session, prompt tokens, prefill t/s (server timing), decode t/s after that prompt, needle multi/single, min free VRAM, max ubatch gap."""
import json, sys
D = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/logs/chief256k"
print("| session | prompt tok | prefill t/s | decode t/s | cached-prefix turn: new tok / ms / decode t/s | needle 5 multi / single | min free MiB | max ubatch gap s |")
print("|---|---|---|---|---|---|---|---|")
for lab in sys.argv[1:]:
    try:
        j = json.load(open(f"{D}/{lab}.json"))
    except Exception as e:
        print(f"| {lab} | (no result: {e}) |"); continue
    if not j["steps"]:
        print(f"| {lab} | none | | | | | {j.get('vram_free_min_total')} | result={j.get('result')} {j.get('why')} |"); continue
    for s in j["steps"]:
        t = s.get("timings") or {}
        st = (s.get("single_timings") or [{}])[0] or {}
        sg = f"{st.get('prompt_n')}/{round(st.get('prompt_ms', 0))}/{round(st.get('predicted_per_second', 0), 1)}" if st else ""
        print(f"| {lab} | {s.get('prompt_tokens')} | {round(t.get('prompt_per_second', 0))} | {round(t.get('predicted_per_second', 0), 1)} | {sg} | {s.get('multi')} / {s.get('single')} | {s.get('vram_free_min')} | {s.get('max_ubatch_gap_s')} |")
