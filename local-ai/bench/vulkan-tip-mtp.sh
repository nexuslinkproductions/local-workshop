#!/usr/bin/env bash
# vulkan-tip-mtp.sh — measure llama-server decode tps WITH and WITHOUT the model's
# own MTP/NextN head (self-speculative decoding, --spec-type draft-mtp).
#
#   vulkan-tip-mtp.sh ENGINE BIN MODEL NGL GPU_STATE NTOKENS {on|off} [PORT]
#
# HARD RULE (Marcel): the whole session — start server, wait /health, generate,
# kill — holds the EXCLUSIVE lock bench/.gpu.lock in ONE call.
# Rows go to bench/results-vulkan-tip.tsv with test = tg<NTOK>-mtp | tg<NTOK>-nomtp.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$HERE/.gpu.lock"
RESULTS="$HERE/results-vulkan-tip.tsv"

if [ -z "${VT_LOCKED:-}" ]; then
    export VT_LOCKED=1
    exec flock -x "$LOCK" "$0" "$@"
fi

ENGINE="$1"; BIN="$2"; MODEL="$3"; NGL="$4"; GPU_STATE="$5"
NTOK="${6:-512}"; MTP="${7:-off}"; PORT="${8:-18311}"
CLI="$(dirname "$BIN")/llama-cli"

[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 2; }

FREE="$("$CLI" --list-devices 2>&1 | sed -n 's/.*Vulkan0:.*, \([0-9]\+\) MiB free).*/\1/p' | head -1)"
[ -n "$FREE" ] || FREE="na"
SHA="$(git -C "$(dirname "$BIN")" rev-parse --short HEAD 2>/dev/null || echo unknown)"

SPEC=(); TAG="nomtp"
[ "$MTP" = on ] && { SPEC=(--spec-type draft-mtp); TAG="mtp"; }

LOG="$(mktemp /home/nexuslink/.hermes/cache/scratch/mtp-XXXX.log)"
START="$(date -Iseconds)"
echo "[mtp] engine=$ENGINE sha=$SHA ngl=$NGL mtp=$MTP ntokens=$NTOK free=${FREE}MiB gpu=$GPU_STATE start=$START" >&2

"$BIN" -m "$MODEL" -ngl "$NGL" -c 4096 -fa on --device Vulkan0 \
       --host 127.0.0.1 --port "$PORT" "${SPEC[@]}" >"$LOG" 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; }
trap cleanup EXIT

ok=""
for _ in $(seq 1 180); do
    kill -0 "$SRV" 2>/dev/null || { echo "server died during load — see $LOG" >&2; tail -5 "$LOG" >&2; exit 1; }
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ok=1; break; }
    sleep 1
done
[ -n "$ok" ] || { echo "server never became healthy — see $LOG" >&2; tail -5 "$LOG" >&2; exit 1; }

# what did the server say about speculative decoding?
echo "--- server spec lines ---" >&2
grep -iE 'speculat|draft|mtp|nextn|prompt lookup' "$LOG" | head -8 >&2 || true

RESP="$(curl -s "http://127.0.0.1:$PORT/completion" -H 'Content-Type: application/json' \
    -d "{\"prompt\":\"Write a detailed explanation of how transformers work.\",\"n_predict\":$NTOK,\"temperature\":0,\"ignore_eos\":true,\"cache_prompt\":false,\"n_keep\":0}")"

END="$(date -Iseconds)"
cleanup; trap - EXIT

TS="$START" ENGINE_ENV="$ENGINE" SHA_ENV="$SHA" NGL_ENV="$NGL" FREE_ENV="$FREE" \
GPU_ENV="$GPU_STATE" MODEL_ENV="$(basename "$MODEL")" RESULTS_ENV="$RESULTS" TAG_ENV="$TAG" \
NTOK_ENV="$NTOK" END_ENV="$END" python3 - "$RESP" <<'PY'
import json, os, sys
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    sys.stderr.write(f"bad response: {e}\n{sys.argv[1][:300]}\n"); sys.exit(1)
t = d.get("timings", {})
ps = t.get("predicted_per_second")
if ps is None:
    sys.stderr.write(f"no timings in response: {str(d)[:300]}\n"); sys.exit(1)
path = os.environ["RESULTS_ENV"]
first = not os.path.exists(path) or os.path.getsize(path) == 0
row = [os.environ["TS"], os.environ["ENGINE_ENV"], os.environ["SHA_ENV"], os.environ["MODEL_ENV"],
       os.environ["NGL_ENV"], "0", f"tg{os.environ['NTOK_ENV']}-{os.environ['TAG_ENV']}",
       f"{float(ps):.2f}", "0.00", os.environ["FREE_ENV"], os.environ["GPU_ENV"]]
with open(path, "a") as f:
    if first:
        f.write("timestamp\tengine\tgit_sha\tmodel_file\tngl\tdepth\ttest\ttps_mean\ttps_std\tfree_vram_mib\tgpu_state\n")
    f.write("\t".join(row) + "\n")
print(f"predicted_per_second={ps:.2f} predicted_n={t.get('predicted_n')} "
      f"prompt_per_second={t.get('prompt_per_second'):.2f} end={os.environ['END_ENV']}")
PY
