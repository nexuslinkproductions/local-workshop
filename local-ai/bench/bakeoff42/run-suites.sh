#!/usr/bin/env bash
# bakeoff42 SUITE phase: llama-swap smokes + the 42-item Chief suite per model + --compare.
# run_suite.py REFUSES to start while the GPU lock is held, so this phase runs with the lock
# FREE — that is the runner's own one-test-at-a-time contract. Stops llama-swap at the end.
set -uo pipefail
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
BO=$LAB/bench/bakeoff42
LOGD=$BO/logs; mkdir -p "$LOGD" "$LAB/results"
cd "$LAB" || exit 2
log(){ echo "[$(date +%T)] $*" | tee -a "$LOGD/suites.log"; }

if [ "${LC_LOCKED:-}" != 1 ] && ! flock -n bench/.gpu.lock true; then log "LOCK HELD by another agent — refusing suite phase"; exit 3; fi
# 2026-10-13: run as  flock -x -w 28800 bench/.gpu.lock env LC_LOCKED=1 bash run-suites.sh  (whole phase under the lock)
if ! bash -c 'source bench/gate.sh; gate_check'; then log "GATE REFUSED"; exit 3; fi

IMG="$HOME/.hermes/cache/scratch/gt-live-2026-10-13.png"

if ! curl -sf -m 3 http://127.0.0.1:18080/v1/models >/dev/null; then
  log "starting llama-swap on :18080"
  setsid llama-swap -config serve/config.yaml -listen 127.0.0.1:18080 > "$LOGD/llama-swap.log" 2>&1 &
  echo $! > "$BO/llama-swap.pid"
  for i in $(seq 1 30); do curl -sf -m 2 http://127.0.0.1:18080/v1/models >/dev/null && break; sleep 1; done
fi
if ! curl -sf -m 3 http://127.0.0.1:18080/v1/models >/dev/null; then log "llama-swap not answering"; exit 4; fi
log "llama-swap up: $(curl -s http://127.0.0.1:18080/v1/models | tr -d '\n ' | head -c 500)"

for m in gemma4-12b-eval ornith-9b ministral3-14b; do
  log "swap-smoke $m"
  python3 "$BO/swap-smoke.py" --model "$m" --image "$IMG" --out "$LOGD/swap-$m.json" > "$LOGD/swap-$m.out" 2>&1
  log "swap-smoke $m rc=$? :: $(tail -c 400 "$LOGD/swap-$m.out" | tr '\n' ' ')"
  log "suite $m"
  python3 evals/chief/run_suite.py --model "$m" --out "results/bakeoff42-$m.json" > "$LOGD/suite-$m.out" 2>&1
  log "suite $m rc=$? :: $(tail -c 400 "$LOGD/suite-$m.out" | tr '\n' ' ')"
done

for other in ornith-9b ministral3-14b; do
  log "compare gemma4-12b vs $other"
  python3 evals/chief/run_suite.py --compare "results/bakeoff42-gemma4-12b-eval.json" "results/bakeoff42-$other.json" > "$LOGD/compare-gemma-$other.txt" 2>&1
  cat "$LOGD/compare-gemma-$other.txt" >> "$LOGD/suites.log"
done

log "stopping llama-swap"
pkill -TERM -f 'llama-swap -config serve/config.yaml' 2>/dev/null
sleep 3
pkill -KILL -f 'llama-swap -config serve/config.yaml' 2>/dev/null
pkill -TERM -f 'llama-server.*--port 181' 2>/dev/null
log "SUITE PHASE DONE"
