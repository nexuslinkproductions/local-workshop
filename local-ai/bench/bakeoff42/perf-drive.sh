#!/usr/bin/env bash
# perf-drive.sh <reps> <spec-file> : interleaved ABAB reps. spec line: label|bin|backend|dev|envs|extra   (# = comment)
# Each run takes the GPU lock on its own. Stops at the first nonzero rc (5 = kernel log hit).
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB; cd "$LAB" || exit 2
reps=$1; spec=$2
for r in $(seq "$reps"); do
  grep -v '^#' "$spec" | while IFS='|' read -r label bin backend dev envs extra; do
    [ -n "$label" ] || continue
    echo "[$(date +%T)] rep $r $label"
    LABEL="${label}-r$r" BIN="$LAB/$bin" BACKEND=$backend DEV=$dev ENVS="$envs" EXTRA="$extra" DEPTHS="${DEPTHS:-0,8192,16384,30000,64000}" REPS="${PREPS:-3}" \
      flock -x -w 3600 bench/.gpu.lock bash bench/bakeoff42/perf-run.sh || { echo "STOP rc=$? at $label rep $r"; exit 1; }
  done || exit 1
done
