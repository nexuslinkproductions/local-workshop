#!/usr/bin/env bash
# quiet-run.sh <tag> <threads> [CPUS] [CPUW]
#
# Run one matrix-bench pass (Qwen3.6 SYCL daily-driver recipe, pp4096/tg128, r6) and
# measure how much it steals from the DESKTOP's CPUs: bench/lag-probe.py pinned to
# CCD0 (taskset -c 0-5) for 60 s while the bench runs. CPUS/CPUW are the jobcap quiet
# knobs (CPUS = taskset pin, CPUW = cgroup CPUWeight). Empty CPUS = current behaviour.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="$1"; THREADS="$2"; CPUS="${3:-}"; CPUW="${4:-100}"
CFG="${CFG:-configs/matrix-qwen36-sycl20260.env}"   # any model config (e.g. the -lm dio one)
LOG="${TMPDIR:-/tmp}/quiet-$TAG.log"
export NCMOE_OVERRIDE=30 THREADS_OVERRIDE="$THREADS" REPS_OVERRIDE=6 DEPTHS_OVERRIDE=0
export NOTE_OVERRIDE="quiet-$TAG t=$THREADS ${CPUS:+cpus=$CPUS }cpuw=$CPUW"
[ -n "$CPUS" ] && export CPUS CPUW
bench/matrix-bench.sh run --cfg "$CFG" >"$LOG" 2>&1 &
BPID=$!
# probe only while llama-bench is actually running (the bench may wait for a quiet disk first)
for _ in $(seq 1 1800); do pgrep -x llama-bench >/dev/null && break; kill -0 "$BPID" 2>/dev/null || break; sleep 1; done
sleep 3
echo "=== QUIET-$TAG probe (during bench) ==="
taskset -c 0-5 python3 bench/lag-probe.py 60
wait "$BPID" || true
echo "=== bench tail ==="
tail -4 "$LOG"
