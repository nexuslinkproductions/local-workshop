#!/usr/bin/env bash
# accel-run.sh <label> <cfg.env> [VAR=value ...]
#
# One llama-bench pp4096 / tg128 (-r 3, depth 0) run through matrix-bench.sh, which takes
# bench/.gpu.lock itself (queues behind any other tester). Extra VAR=value pairs are
# exported into the run (SYCL/Vulkan env levers). Afterwards: kernel-log reset check
# (xe GT0 reset / DEVICE_LOST since the run start) and the env actually seen by the binary.
# Rows land in bench/results-matrix.tsv via matrix-bench.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(dirname "$HERE")"
cd "$LAB" || exit 2
export TMPDIR=/home/nexuslink/.hermes/cache/scratch
LABEL="$1"; CFG="$2"; shift 2
# Wait for a quiet disk BEFORE taking the GPU lock (a download keeps io full avg10 at ~3%,
# so matrix-bench's own in-lock wait would hold the lock for 30 min and then SKIP).
. "$HERE/gate.sh"
w=0
until awk -v a="$(io_full)" 'BEGIN{exit !(a<0.5)}'; do
    [ "$w" -ge 14400 ] && { echo "SKIPPED-IO (no lock taken): disk busy 4 h"; exit 7; }
    [ $((w % 300)) -eq 0 ] && echo "[accel-run] $LABEL waiting for quiet disk (io full avg10=$(io_full), ${w}s)" >&2
    sleep 20; w=$((w + 20))
done
ST="$(date '+%Y-%m-%d %H:%M:%S')"
# Lock taken here WITHOUT a timeout (matrix-bench's own flock gives up after 1 h, and another
# agent parks the lock for hours). MATRIX_LOCKED=1 makes matrix-bench skip its own flock.
LOCKCMD=(flock -x "$LAB/bench/.gpu.lock")
[ -n "${ACCEL_LOCK_HELD:-}" ] && LOCKCMD=()   # caller already holds bench/.gpu.lock (outer flock); a nested flock would deadlock
"${LOCKCMD[@]}" env MATRIX_LOCKED=1 "$@" WATCH_IO_GRACE_S=30 PROMPT_OVERRIDE=4096 \
    GEN_OVERRIDE=128 REPS_OVERRIDE=3 DEPTHS_OVERRIDE=0 NOTE_OVERRIDE="$LABEL" \
    bench/matrix-bench.sh run --cfg "$CFG"
rc=$?
echo "RUN rc=$rc label=$LABEL start=$ST end=$(date '+%F %T')"
hits="$(journalctl -k --since "$ST" --no-pager 2>/dev/null | grep -cE 'GT0: reset|DEVICE_LOST|Timedout job' || true)"
echo "KERNEL-RESET-HITS=$hits"
ERR="$(ls -t "$TMPDIR"/mx-*-run-*.err 2>/dev/null | head -1)"
echo "LOG=$ERR"
[ -n "$ERR" ] && grep -E 'GGML_SYCL_(ENABLE_GRAPH|ENABLE_OPT|XMX_GATHER_TYPES|ENABLE_DNN|ENABLE_MKL_FA):|Environment|SYCL0|Vulkan0' "$ERR" | head -8
exit "$rc"
