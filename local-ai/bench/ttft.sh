#!/usr/bin/env bash
# ttft.sh — measure time-to-first-token and decode speed with a llama-server.
#
#   ttft.sh --port 8082 --server-cmd "./chat-bonsai.sh"    # RULE-2 COMPLIANT
#   ttft.sh --port 8082 --tokens 16384 --server-cmd "..."  # longer prompt
#
#       Exclusive-locks bench/.gpu.lock, launches the server itself, waits for
#       /health, measures, kills ONLY the server it started. This is the form to
#       use: nothing else on the box is running while the numbers are taken.
#
#   ttft.sh --port 8082                                    # measure a server
#       someone else started. Holds the lock for the measurement only, and warns:
#       that server was started outside the lock, so the row is not rule-2 clean.
#
# Sends one long prompt to /v1/chat/completions with "stream": true and reports
#   TTFT          seconds from request sent to first content chunk received
#   decode tok/s  from the server's own `timings` block in the final SSE chunk
# A row is appended to results.tsv with test=ttft and depth=<prompt tokens>.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(dirname "$HERE")"
RESULTS="$HERE/results.tsv"
. "$HERE/gate.sh"

# RULE 1: every timing run is exclusive. Held for the whole session, so a server
# we start stays inside the lock until it is dead (see cleanup below).
if [ -z "${BENCH_LOCKED:-}" ]; then
    export BENCH_LOCKED=1
    exec flock -x -w 3600 "$LOCK_FILE" "$0" "$@"
fi

PORT=""; TOKENS=4096; FORCE=""; MODEL_NAME="local"; SERVER_CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --port)       PORT="$2"; shift ;;
        --tokens)     TOKENS="$2"; shift ;;
        --model)      MODEL_NAME="$2"; shift ;;
        --server-cmd) SERVER_CMD="$2"; shift ;;
        --force)      FORCE=--force ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$PORT" ] || { echo "usage: ttft.sh --port <port> [--server-cmd CMD] [--tokens N] [--force]" >&2; exit 2; }

# ---- server lifecycle (rule 2: start, measure and kill inside one locked call) ----
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
healthy() { curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }

if [ -n "$SERVER_CMD" ]; then
    # we start and own the server, so no server may be on the port
    gate_check "$FORCE" || exit 3
    healthy && { echo "port $PORT already answers — refusing to start a second server" >&2; exit 2; }
    echo "start=$(date -Iseconds) launch: $SERVER_CMD" >&2
    bash -c "$SERVER_CMD" & SRV_PID=$!
    for _ in $(seq 1 300); do
        healthy && break
        kill -0 "$SRV_PID" 2>/dev/null \
            || { echo "server (pid $SRV_PID) died before /health was ok — nothing killed, it is already gone" >&2; exit 1; }
        sleep 2
    done
    healthy || { echo "server not healthy after 600 s" >&2; exit 1; }
    echo "healthy=$(date -Iseconds) pid=$SRV_PID" >&2
else
    # measuring someone else's server: allowed through on this port, but say so
    gate_check "$FORCE" "$PORT" || exit 3
    healthy || { echo "no llama-server answering on 127.0.0.1:$PORT/health — start one first" >&2; exit 2; }
    echo "WARNING: this server was started outside the lock — rule 2 wants" \
         "--server-cmd so start/measure/kill happen in one locked call." >&2
fi

# ---- measure ----
T0="$(date -Iseconds)"
BENCH_TS="$T0" BENCH_CFG="ttft-port$PORT" BENCH_MODEL="$MODEL_NAME" \
BENCH_RESULTS="$RESULTS" PORT="$PORT" TOKENS="$TOKENS" \
BENCH_VRAMNOTE="free=$(vram_free_mib "${LLAMA_CLI:-$LAB_ROOT/llm/llama.cpp/build/bin/llama-cli}" | cut -d' ' -f1)MiB Vulkan0 $(game_state)" \
python3 - <<'PY'
import json, os, time, urllib.request

port = int(os.environ["PORT"])
n_tok = int(os.environ["TOKENS"])
# ~4 chars per token, deterministic filler text.
prompt = ("Benchmark filler sentence number %d with a few extra words. " * 20) % 0
prompt = (prompt * (n_tok * 4 // len(prompt) + 1))[: n_tok * 4]

body = json.dumps({
    "model": os.environ["BENCH_MODEL"],
    "messages": [{"role": "user", "content": prompt + "\nReply with one short sentence."}],
    "max_tokens": 128, "temperature": 0, "stream": True,
}).encode()
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/v1/chat/completions", data=body,
    headers={"Content-Type": "application/json"})

ttft = None
timings = None
t0 = time.perf_counter()
with urllib.request.urlopen(req, timeout=1800) as r:
    for raw in r:
        line = raw.decode().strip()
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        chunk = json.loads(line[6:])
        if ttft is None and chunk.get("choices"):
            d = chunk["choices"][0].get("delta", {})
            if d.get("content") or d.get("reasoning_content"):
                ttft = time.perf_counter() - t0
        if chunk.get("timings"):
            timings = chunk["timings"]

if ttft is None:
    raise SystemExit("no content chunk seen — server never started streaming")
if not timings:
    raise SystemExit("server sent no `timings` block (was it built with --no-timings?)")

dec = timings.get("predicted_per_second", 0.0)
std = ""
print(f"TTFT        {ttft:.3f} s  ({n_tok} prompt tokens)")
print(f"prompt      {timings.get('prompt_per_second', 0.0):.2f} tok/s "
      f"({timings.get('prompt_ms', 0.0):.0f} ms)")
print(f"decode      {dec:.2f} tok/s ({timings.get('predicted_n', 0)} tok)")

path = os.environ["BENCH_RESULTS"]
new = not os.path.exists(path) or os.path.getsize(path) == 0
with open(path, "a") as f:
    if new:
        f.write("timestamp\tgit_sha\tconfig\tmodel\tdepth\ttest\ttps_mean\ttps_std\tvram_note\n")
    f.write("\t".join([
        os.environ["BENCH_TS"], "n/a", os.environ["BENCH_CFG"], os.environ["BENCH_MODEL"],
        str(n_tok), "ttft",
        f"{dec:.2f}", std,
        f"{os.environ['BENCH_VRAMNOTE']} ttft={ttft:.3f}s "
        f"prompt_tps={timings.get('prompt_per_second', 0.0):.2f}",
    ]) + "\n")
print(f"appended 1 row to {path}")
PY
echo "end=$(date -Iseconds) (start=$T0)" >&2
