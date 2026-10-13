#!/usr/bin/env python3
"""thinking-toggle.py <port> <outdir> — per-request thinking switch probe (no restart).

Runs against an already-started llama-server WITHOUT the global --reasoning off flag.
Same hard-ish prompt for every variant; streams each request and records:
  reasoning_chars (reasoning_content present?), ttft (first content OR reasoning token),
  first_sentence (first '.', '!' or '?' in content), total, finish_reason, completion_tokens.
Variants: explicit bool/string enable_thinking, reasoning_effort none/high, budget, and no field.
Writes <outdir>/toggle-<name>.json (raw final stream chunks) and prints one TSV line per variant.
"""
import json
import sys
import time
import urllib.request

PORT, OUT = int(sys.argv[1]), sys.argv[2]
ONLY = set(sys.argv[3].split(",")) if len(sys.argv) > 3 and sys.argv[3] else None  # optional variant filter
PROMPT = ("Two trains leave the same station on the same track in the same direction. Train A leaves at "
          "14:20 at 84 km/h. Train B leaves at 14:50 at 112 km/h. At what clock time does B catch up with A? "
          "Give the clock time, then one short sentence explaining the reasoning.")

VARIANTS = [
    ("nofield", {}),
    ("ctk-bool-false", {"chat_template_kwargs": {"enable_thinking": False}}),
    ("ctk-bool-true", {"chat_template_kwargs": {"enable_thinking": True}}),
    ("ctk-str-false", {"chat_template_kwargs": {"enable_thinking": "false"}}),
    ("effort-none", {"reasoning_effort": "none"}),
    ("effort-high", {"reasoning_effort": "high"}),
    ("ctk-true-budget64", {"chat_template_kwargs": {"enable_thinking": True}, "thinking_budget_tokens": 64}),
]


def run(name, extra):
    body = {"model": "gemma", "temperature": 0, "max_tokens": 1024, "stream": True,
            "messages": [{"role": "user", "content": PROMPT}], **extra}
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                                 data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    ttft = None
    content, reasoning, finish, usage, timings, chunks = [], [], None, None, None, []
    first_sent = None
    with urllib.request.urlopen(req, timeout=900) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            ch = json.loads(line[6:])
            chunks.append(ch)
            for c in ch.get("choices") or []:
                d = c.get("delta") or {}
                if (d.get("content") or d.get("reasoning_content")) and ttft is None:
                    ttft = time.perf_counter() - t0
                if d.get("reasoning_content"):
                    reasoning.append(d["reasoning_content"])
                if d.get("content"):
                    content.append(d["content"])
                    if first_sent is None and any(p in "".join(content) for p in ".!?"):
                        first_sent = time.perf_counter() - t0
                if c.get("finish_reason"):
                    finish = c["finish_reason"]
            usage = ch.get("usage") or usage
            timings = ch.get("timings") or timings
    total = time.perf_counter() - t0
    txt = "".join(content).strip()
    rtxt = "".join(reasoning)
    with open(f"{OUT}/toggle-{name}.json", "w") as f:
        json.dump({"variant": name, "body_extra": extra, "chunks": chunks}, f)
    return {"variant": name, "reasoning_chars": len(rtxt), "ttft_s": ttft, "first_sentence_s": first_sent,
            "total_s": total, "finish": finish, "completion_tokens": (usage or {}).get("completion_tokens"),
            "predicted_tps": (timings or {}).get("predicted_per_second"), "answer": txt}


if __name__ == "__main__":
    for name, extra in VARIANTS:
        if ONLY and name not in ONLY:
            continue
        try:
            r = run(name, extra)
        except Exception as e:  # keep going: a rejected field is itself a result
            r = {"variant": name, "error": repr(e)}
        print(json.dumps(r, ensure_ascii=False), flush=True)
