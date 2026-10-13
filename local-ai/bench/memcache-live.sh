#!/usr/bin/env bash
# memcache-live.sh <tag>: one Gemma 4 12B run for BRIEF-45 — cold load, then one 32K-token prefill,
# with memwatch logging the whole time. Runs under the GPU lock:
#   - waits up to WAIT_S (default 1800) for bench/.gpu.lock, never kills another lane's job
#   - gate_check() must pass (refuses on any llama-server, game, GPU reset or kswapd0 loss)
#   - stops llama-swap only; llama-server is torn down by llama-swap, and gate_check already proved
#     none existed before we started, so the cleanup pattern cannot touch another lane's server.
# Output: ~/.local/state/memwatch/runs/<tag>/ (summary.txt + raw replies). Sysctl is NOT touched.
set -uo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:?usage: memcache-live.sh <tag>}"
OUT="$HOME/.local/state/memwatch/runs/$TAG"; mkdir -p "$OUT"
GGUF_DIR="$LAB/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf"
SWAP="$HOME/.local/bin/llama-swap"

exec 9<"$LAB/bench/.gpu.lock"
flock -x -w "${WAIT_S:-1800}" 9 || { echo "lock still held by another job after ${WAIT_S:-1800}s: nothing started" | tee "$OUT/summary.txt"; exit 4; }
cd "$LAB"
source bench/gate.sh
if r=$(gate_check 2>&1); then :; else echo "GATE REFUSED: $r" | tee "$OUT/summary.txt"; exit 3; fi
echo "lock + gate ok $(date +%T)"

python3 - "$GGUF_DIR" <<'PY'
import glob, os, sys
for f in glob.glob(sys.argv[1] + "/*.gguf"):          # cold start: drop the model files from page cache
    fd = os.open(f, os.O_RDONLY); os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED); os.close(fd)
PY
python3 - "$OUT/prefill.txt" <<'PY'
import random, sys
random.seed(45)
w = "model cache memory kernel page reclaim window graphic driver queue prompt token layer shard disk desk quiet stall pressure buffer weight route sample trace signal".split()
s = "Reply with the word OK.\n"
while len(s) < 200_000:   # ~6 chars per token: 130 KB gave 21.3K tokens, 200 KB gives ~32K
    s += " ".join(random.choice(w) for _ in range(random.randint(8, 16))) + ". "
open(sys.argv[1], "w").write(s)
PY

T_START=$(date +%s); echo "$T_START" > "$OUT/t_start"
"$SWAP" --config serve/config.yaml --listen 127.0.0.1:18080 9>&- > "$OUT/llama-swap.log" 2>&1 &
SW=$!
for _ in $(seq 1 60); do curl -s -m 2 127.0.0.1:18080/v1/models | grep -q gemma4-12b && break; sleep 1; done
ask() {  # ask <body-file> <reply-file>
    curl -s -m 900 127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' --data-binary @"$1" > "$2"
}
printf '{"model":"gemma4-12b","messages":[{"role":"user","content":"Reply OK."}],"max_tokens":4,"stream":false}' > "$OUT/req-load.json"
t0=$(date +%s.%N); ask "$OUT/req-load.json" "$OUT/resp-load.json"; t1=$(date +%s.%N)
python3 -c 'import json,sys; print(json.dumps({"model":"gemma4-12b","max_tokens":4,"stream":False,
  "messages":[{"role":"user","content":open(sys.argv[1]).read()}]}))' "$OUT/prefill.txt" > "$OUT/req-prefill.json"
ask "$OUT/req-prefill.json" "$OUT/resp-prefill.json"; t2=$(date +%s.%N)
T_END=$(date +%s); echo "$T_END" > "$OUT/t_end"

kill -TERM "$SW" 2>/dev/null; sleep 5; pkill -TERM -f 'llama-server.*--port 18' 2>/dev/null; sleep 3
python3 - "$OUT" "$T_START" "$T_END" "$t0" "$t1" "$t2" <<'PY' | tee "$OUT/summary.txt"
import json, sys
out, t_start, t_end, t0, t1, t2 = sys.argv[1], *map(float, sys.argv[2:])
def reply(name):
    try:
        return json.load(open(f"{out}/{name}"))
    except Exception as e:
        return {"error": str(e)}
load, pre = reply("resp-load.json"), reply("resp-prefill.json")
print(f"load+first reply wall: {float(t1) - float(t0):.1f} s  reply={load.get('choices', [{}])[0].get('message', {}).get('content')!r} err={load.get('error')}")
print(f"32K prefill wall:      {float(t2) - float(t1):.1f} s  prompt_tokens={pre.get('usage', {}).get('prompt_tokens')} err={pre.get('error')}")
print(f"timings: {pre.get('timings')}")
rows = [l.split("\t") for l in open(f"{out}/../../memwatch.tsv").read().splitlines()[1:]]
rows = [r for r in rows if len(r) == 14 and float(r[0]) >= t_start - 30 and float(r[0]) <= t_end + 30]
if rows:
    col = lambda i: [float(r[i]) for r in rows]
    print(f"samples in window: {len(rows)} (memwatch 15 s cadence)")
    print(f"peak psi mem some10={max(col(7)):.2f} full10={max(col(8)):.2f}   peak psi io some10={max(col(9)):.2f} full10={max(col(10)):.2f}")
    print(f"MemAvailable floor={min(col(1)):.0f} MiB   MemFree floor={min(col(2)):.0f} MiB   Cached peak={max(col(3)):.0f} MiB")
    print(f"kswapd0 present in all samples: {all(int(r[11]) == 1 for r in rows)}   alerts fired: {[r[13] for r in rows if r[13] != '-'] or 'none'}")
PY
pgrep -fa 'llama-server.*--port 18' >/dev/null && echo "WARNING: llama-server still up" || echo "GPU released: no llama-server"
echo "done $(date +%T)"
