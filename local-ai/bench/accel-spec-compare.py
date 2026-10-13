#!/usr/bin/env python3
"""accel-spec-compare.py BASE.jsonl MTP.jsonl

Lossless check for greedy speculative decoding: per prompt, do the base and the MTP run give the
same reply text? Prints one line per prompt and a summary. Exit 0 always (it is a report)."""
import json
import sys

def load(p):
    return {r["id"]: r for r in (json.loads(l) for l in open(p) if l.strip())}

base, spec = load(sys.argv[1]), load(sys.argv[2])
same = 0
for pid in base:
    b, s = base[pid], spec.get(pid)
    if s is None:
        print(f"{pid}: MISSING in spec run"); continue
    eq = b["content"] == s["content"]
    same += eq
    first_diff = next((i for i, (x, y) in enumerate(zip(b["content"], s["content"])) if x != y), None)
    print(f"{pid}: identical={eq} chars base={len(b['content'])} spec={len(s['content'])}"
          + ("" if eq or first_diff is None else f" first_diff_char={first_diff}"))
print(f"IDENTICAL {same}/{len(base)} prompts")
