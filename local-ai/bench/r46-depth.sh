#!/usr/bin/env bash
# r46-depth.sh <label> <llama-bench args...>  — BRIEF-46 decode/prefill at depth, ONE locked llama-bench run.
# Gates like lc.py (game, reset-ack, other GPU jobs, memwatch, kswapd0), watchdog.sh PSI/RAM kill switch,
# jobcap + ionice + CCD pin. Output: bench/logs/r46/<label>.{jsonl,err}. Stops (exit 4) on an xe fault line.
# Extra env: R46_WRAP (command prefix, e.g. unitrace -d -o f), R46_BIN (default build/bin, set to a patched build), plus any GGML_SYCL_* levers.
set -uo pipefail
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
LABEL="$1"; shift
OUT="$LAB/bench/logs/r46"; mkdir -p "$OUT"
BIN="${R46_BIN:-$LAB/engines/llama.cpp-sycl-tip/build/bin}/llama-bench"
M="$LAB/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/gemma-4-12b-it-qat-q4_0.gguf"
exec 9>"$LAB/bench/.gpu.lock"; flock -x -w 7200 9 || { echo "lock timeout"; exit 3; }
source "$LAB/bench/gate.sh"
systemctl --user is-active --quiet memwatch.timer || { echo "memwatch inactive"; exit 3; }
g="$( { game_running && echo GAME; gpu_reset_unacked; kswapd_missing; pgrep -ax 'llama-server|llama-bench|llama-perplexit'; } 2>&1)"
[ -z "$g" ] || { echo "gate refuses: $g"; exit 3; }
until awk -v a="$(io_full)" 'BEGIN{exit !(a<0.3)}'; do sleep 5; done
T0="$(date '+%F %T')"
set +u; . "$LAB/bench/configs/sycl-env.sh"; set -u
export CAP=14G CPUS=6-11,18-23 CPUW=20 WATCH_IO_GRACE_S=60 MATRIX_RESULTS="$OUT/watchdog-rows.tsv"
python3 "$LAB/bench/arc-vram.py" > "$OUT/$LABEL.vram0" 2>&1
( while sleep 2; do python3 "$LAB/bench/arc-vram.py"; done > "$OUT/$LABEL.vram" 2>&1 ) & VP=$!
bash "$LAB/bench/watchdog.sh" "r46-$LABEL" -- ionice -c 3 /home/nexuslink/.local/bin/jobcap \
    ${R46_WRAP:-} "$BIN" -m "$M" -dev SYCL0 -ngl 99 -t 16 -fa on -lm dio -o jsonl "$@" > "$OUT/$LABEL.jsonl" 2> "$OUT/$LABEL.err"
rc=$?
kill $VP 2>/dev/null
hits="$(journalctl -k --since "$T0" --no-pager 2>/dev/null | grep -cE 'GT0: (Engine )?reset|device wedged|Timedout job|DEVICE_LOST' || true)"
echo "R46 $LABEL rc=$rc faults=$hits lines=$(wc -l < "$OUT/$LABEL.jsonl")"
[ "$hits" -gt 0 ] && exit 4
exit "$rc"
