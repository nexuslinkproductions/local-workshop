#!/usr/bin/env bash
# spec-session.sh --backend sycl|vulkan --mode base|mtp [--n-max N] --tag TAG
#
# ONE locked llama-server session (bench/.gpu.lock held for start -> /health -> warm-up ->
# assistant prompts -> kill, research/26 rule). Gemma 4 12B QAT Q4_0 target; mode mtp adds the
# Gemma 4 MTP assistant head (unsloth mtp-gemma-4-12B-it.gguf, arch gemma4-assistant) as
# -md with --spec-type draft-mtp. Greedy, thinking off, English prompts from
# bench/accel-prompts-assistant.jsonl. Writes a row to bench/results-matrix.tsv and the
# per-prompt replies to $TMPDIR/accel-spec-<tag>.jsonl (for the lossless check).
# Runs under watchdog.sh (PSI/MemAvailable kill) + jobcap (14G cap) + ionice -c 3.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(dirname "$HERE")"
cd "$LAB" || exit 2
export TMPDIR=/home/nexuslink/.hermes/cache/scratch
BACK=sycl; MODE=base; NMAX=3; TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --backend) BACK="$2"; shift ;;
        --mode) MODE="$2"; shift ;;
        --n-max) NMAX="$2"; shift ;;
        --tag) TAG="$2"; shift ;;
        *) echo "unknown arg $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$TAG" ] || TAG="${BACK}-${MODE}-n${NMAX}"
PORT="${SPEC_PORT:-18099}"
MODEL="models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/gemma-4-12b-it-qat-q4_0.gguf"
MTP="models/llm/unsloth/gemma-4-12B-it-qat-GGUF/mtp-gemma-4-12B-it.gguf"
JOBCAP="/home/nexuslink/.local/bin/jobcap"
RESULTS="${MATRIX_RESULTS:-$HERE/results-matrix.tsv}"
OUT="$TMPDIR/accel-spec-$TAG.jsonl"

case "$BACK" in
    sycl)   BIN="engines/llama.cpp-sycl-tip/build/bin/llama-server"; ENVSRC="bench/configs/sycl-env.sh"; DEV="SYCL0"; ENGINE="llama.cpp-sycl-tip" ;;
    sycl2026.1) BIN="engines/llama.cpp-sycl-tip-2026.1/build/bin/llama-server"; ENVSRC="bench/configs/sycl-env-2026.1.sh"; DEV="SYCL0"; ENGINE="llama.cpp-sycl-tip-2026.1" ;;
    vulkan) BIN="engines/llama.cpp-vulkan-tip/build/bin/llama-server"; ENVSRC=""; DEV="Vulkan0"; ENGINE="llama.cpp-vulkan-tip" ;;
    *) echo "backend sycl|sycl2026.1|vulkan" >&2; exit 2 ;;
esac

# game rule: never load beside a running game (gate.sh), queue on quiet disk OUTSIDE the lock
. "$HERE/gate.sh"
if game_running; then echo "REFUSE: game running" >&2; exit 3; fi
w=0
until awk -v a="$(io_full)" 'BEGIN{exit !(a<0.5)}'; do
    [ "$w" -ge 14400 ] && { echo "SKIPPED-IO (no lock taken)" >&2; exit 7; }
    sleep 20; w=$((w + 20))
done

if [ -z "${SPEC_LOCKED:-}" ]; then
    export SPEC_LOCKED=1
    exec flock -x "$LAB/bench/.gpu.lock" "$0" "$@"
fi

[ -n "$ENVSRC" ] && { set +u; . "$ENVSRC" >/dev/null 2>&1; set -u; }
if pgrep -f "llama-server.*--port ${PORT}( |\$)" >/dev/null 2>&1; then echo "port $PORT busy" >&2; exit 4; fi

ARGS=(-m "$MODEL" -ngl 99 -c 8192 -np 1 --no-kv-unified -t 16 -fa on -ctk q8_0 -ctv q8_0
      --device "$DEV" -b 1024 -ub 1024 -lm dio --host 127.0.0.1 --port "$PORT"
      --jinja --temp 0 --repeat-penalty 1.05 --reasoning off)
if [ "$MODE" = mtp ]; then
    ARGS+=(-md "$MTP" -ngld 99 --spec-draft-device "$DEV" --spec-type draft-mtp --spec-draft-n-max "$NMAX")
fi

PSI0="$(psi_now)"; START="$(date -Iseconds)"; T_LAUNCH=$(date +%s.%N)
LOGF="$TMPDIR/accel-spec-$TAG.err"
CAP=14G WATCH_IO_GRACE_S=30 MATRIX_RESULTS="$RESULTS" bash "$HERE/watchdog.sh" "spec-$TAG" -- \
    timeout --kill-after=30 2400 ionice -c 3 "$JOBCAP" "$LAB/$BIN" "${ARGS[@]}" >"$LOGF.out" 2>"$LOGF" &
WD=$!
cleanup() {
    pkill -TERM -f "llama-server.*--port ${PORT}( |\$)" 2>/dev/null || true
    kill -TERM "$WD" 2>/dev/null || true
    sleep 3
    pkill -KILL -f "llama-server.*--port ${PORT}( |\$)" 2>/dev/null || true
}
trap cleanup EXIT

healthy=0
for i in $(seq 1 400); do
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then healthy=1; break; fi
    kill -0 "$WD" 2>/dev/null || { echo "server exited during load (see $LOGF)" >&2; break; }
    sleep 1
done
T_HEALTH=$(date +%s.%N)
COLD_MS=$(python3 -c "print(int(($T_HEALTH-$T_LAUNCH)*1000))")
if [ "$healthy" != 1 ]; then
    echo "FAILED to become healthy" >&2; tail -5 "$LOGF" >&2
    exit 5
fi

# warm-up (JIT / first-touch) — not measured
echo '{"id":"warm","text":"Say hello in one short sentence."}' > "$TMPDIR/accel-warm.jsonl"
python3 "$HERE/spec_req.py" "$PORT" "$TMPDIR/accel-warm.jsonl" "$TMPDIR/accel-warm-out.jsonl" 32 >/dev/null

SUM="$(python3 "$HERE/spec_req.py" "$PORT" "$HERE/accel-prompts-assistant.jsonl" "$OUT" 256)"
RC=$?
END="$(date -Iseconds)"
PSI1="$(psi_now)"; PSID="$(psi_delta "$PSI0" "$PSI1")"
VRAM_NOTE="$(python3 "$HERE/arc-vram.py" 2>/dev/null | head -1 || true)"
cleanup; trap - EXIT
hits="$(journalctl -k --since "$START" --no-pager 2>/dev/null | grep -cE 'GT0: reset|DEVICE_LOST|Timedout job' || true)"
left="$(pgrep -f "llama-server.*--port ${PORT}( |\$)" 2>/dev/null | wc -l || true)"

echo "SUMMARY tag=$TAG $SUM cold_ms=$COLD_MS kernel_reset_hits=$hits servers_left=$left $PSID"
[ "$RC" = 0 ] || exit "$RC"

python3 - "$RESULTS" "$SUM" "$ENGINE" "$START" "$END" "$TAG" "$MODE" "$NMAX" "$BACK" "$COLD_MS" "$hits" "$PSID" <<'PY'
import json, subprocess, sys
res, sumjs, engine, start, end, tag, mode, nmax, back, cold, hits, psid = sys.argv[1:13]
s = json.loads(sumjs)
sha = subprocess.run(["git", "-C", f"engines/{engine}", "rev-parse", "--short", "HEAD"],
                     capture_output=True, text=True).stdout.strip() or "unknown"
note = (f"spec-session {tag} backend={back} mode={mode} n_max={nmax if mode=='mtp' else '-'} "
        f"prompts={s['n']} pooled={s['decode_tps_pooled']} median={s['decode_tps_median']} "
        f"min={s['decode_tps_min']} max={s['decode_tps_max']} draft_n={s['draft_n']} "
        f"accepted={s['draft_accepted']} accept_rate={s['accept_rate']} finish={s['finish']} "
        f"cold_ms={cold} kernel_reset_hits={hits} {psid} greedy temp0 thinking-off ctx8192 kv=q8_0 -fa on lm=dio")
row = [
    ("timestamp", start), ("engine", engine), ("git_sha", sha),
    ("model", "gemma-4-12b-it-qat-q4_0"), ("quant", "QAT-Q4_0"),
    ("placement", f"ngl=99/{mode}" + (f"/nmax={nmax}" if mode == "mtp" else "")),
    ("ctx", "8192"), ("kv_type", "q8_0"), ("depth", "0"), ("test", f"spec-{mode}-n{nmax}" if mode == "mtp" else "spec-base"),
    ("tps_mean", f"{s['decode_tps_pooled']:.2f}"), ("tps_std", ""), ("ttft_ms", ""),
    ("start", start), ("end", end), ("notes", note),
]
args = [f"{k}={v}" for k, v in row]
subprocess.run([sys.executable, "bench/matrix-row.py", res] + args, check=True)
print("row appended:", tag)
PY
