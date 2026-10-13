#!/usr/bin/env python3
"""spec_req.py PORT PROMPTS.jsonl OUT.jsonl MAX_TOKENS

Sends each assistant prompt to a running llama-server (greedy, chat endpoint, thinking off)
and writes one JSON line per prompt: reply text, token counts, llama-server `timings`
(predicted_per_second, draft_n, draft_n_accepted when speculating) and wall time.
Then prints ONE summary JSON line to stdout (aggregate decode t/s, acceptance).
"""
import json
import sys
import time
import urllib.request

port, prompts_path, out_path, max_tok = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
prompts = [json.loads(l) for l in open(prompts_path) if l.strip()]
url = f"http://127.0.0.1:{port}/v1/chat/completions"
rows = []
with open(out_path, "w") as out:
    for p in prompts:
        body = {
            "model": "gemma",
            "messages": [
                {"role": "system", "content": "You are a helpful assistant. Answer in English."},
                {"role": "user", "content": p["text"]},
            ],
            "max_tokens": max_tok,
            "temperature": 0,
            "stream": False,
        }
        req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=900) as r:
            resp = json.loads(r.read())
        wall = time.time() - t0
        msg = resp["choices"][0]["message"]
        rec = {
            "id": p["id"],
            "content": msg.get("content") or "",
            "finish": resp["choices"][0].get("finish_reason"),
            "completion_tokens": resp.get("usage", {}).get("completion_tokens"),
            "timings": resp.get("timings", {}),
            "wall_s": round(wall, 2),
        }
        rows.append(rec)
        out.write(json.dumps(rec) + "\n")
        out.flush()

tim = [r["timings"] for r in rows if r["timings"]]
pred_n = sum(t.get("predicted_n", 0) for t in tim)
pred_ms = sum(t.get("predicted_ms", 0.0) for t in tim)
dn = sum(t.get("draft_n", 0) or 0 for t in tim)
dacc = sum(t.get("draft_n_accepted", 0) or 0 for t in tim)
per = sorted(t.get("predicted_per_second", 0.0) for t in tim)
summary = {
    "n": len(rows),
    "decode_tps_pooled": round(pred_n / (pred_ms / 1000.0), 2) if pred_ms else 0.0,
    "decode_tps_median": round(per[len(per) // 2], 2) if per else 0.0,
    "decode_tps_min": round(per[0], 2) if per else 0.0,
    "decode_tps_max": round(per[-1], 2) if per else 0.0,
    "pred_tokens": pred_n,
    "draft_n": dn,
    "draft_accepted": dacc,
    "accept_rate": round(dacc / dn, 3) if dn else None,
    "finish": [r["finish"] for r in rows],
}
print(json.dumps(summary))
