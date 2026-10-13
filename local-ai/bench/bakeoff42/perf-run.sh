#!/usr/bin/env bash
# perf-run.sh: ONE GPU run for research/62-perf-lead.md. Call ONLY as:  flock -x -w 3600 bench/.gpu.lock bash perf-run.sh
# env in: LABEL BIN [ENVS="K=V ..."] [EXTRA="server flags"] [DEPTHS=0,8192,...] [REPS=3] [DEV=SYCL0] [BACKEND=sycl|vulkan] [PROF=1]
# Production flags = serve/bakeoff-launch.sh + BAKEOFF_EXTRA ('-ub 256 -b 256') + --mmproj-cpu. Never --force.
# Stops local-ai before, starts it after (always). VRAM sampler floor 750 MiB. Exit 5 = kernel-log hit (STOP everything).
# v2 (22:46): cleanup() waits until the server is really gone AND VRAM is back before the lock is released (orchestrator bug report).
set -uo pipefail
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB; BO=$LAB/bench/bakeoff42; LOGD=$BO/logs/perf62; mkdir -p "$LOGD"
: "${LABEL:?}" "${BIN:?}"; ENVS=${ENVS:-}; EXTRA=${EXTRA:-}; DEPTHS=${DEPTHS:-0,8192,16384,30000,64000}; REPS=${REPS:-3}
DEV=${DEV:-SYCL0}; BACKEND=${BACKEND:-sycl}; PROF=${PROF:-0}; PORT=18190; CCD1=6-11,18-23
OD=$LAB/models/llm/ornith-ai/Ornith-1.5-9B-GGUF
TS=$(date +%H%M%S); TAG=$LABEL-$TS
cd "$LAB" || exit 2
source "$LAB/bench/gate.sh"
SAMP=""
server_alive() { pgrep -f "[l]lama-server.*--port $PORT" >/dev/null; }
stop_server() {   # TERM, wait up to 60 s, then KILL and wait up to 30 s more
  server_alive || return 0
  pkill -TERM -f "[l]lama-server.*--port $PORT" 2>/dev/null
  for _ in $(seq 60); do server_alive || return 0; sleep 1; done
  pkill -KILL -f "[l]lama-server.*--port $PORT" 2>/dev/null
  for _ in $(seq 30); do server_alive || return 0; sleep 1; done
}
cleanup() {
  trap - EXIT
  stop_server
  [ -n "$SAMP" ] && { kill "$SAMP" 2>/dev/null; wait "$SAMP" 2>/dev/null; SAMP=""; }
  for _ in $(seq 90); do k=$(python3 "$LAB/bench/arc-vram.py" | sed -n 's/.*free=\([0-9]*\).*/\1/p'); [ "${k:-0}" -gt 8000 ] && break; sleep 1; done
  systemctl --user start local-ai
}
systemctl --user stop local-ai
trap cleanup EXIT
sleep 2
gate_check || { echo "gate refused" >&2; exit 3; }
io_quiet_wait || { echo "disk busy" >&2; exit 3; }
line=$(mem_guard "$OD/Ornith-1.5-9B-Q4_K_M.gguf" dio 0); [ "${line%% *}" = OK ] || { echo "mem_guard $line" >&2; exit 3; }
if [ "$BACKEND" = sycl ]; then set +u; . "$LAB/bench/configs/sycl-env.sh"; set -u; fi
ARGV=("$BIN" -m "$OD/Ornith-1.5-9B-Q4_K_M.gguf" --mmproj "$OD/mmproj-Ornith-1.5-9B-BF16.gguf" --no-mmproj-offload
      --host 127.0.0.1 --port $PORT --device "$DEV" -ngl 99 -c 262144 -np 1 -t 16 -fa on -ctk q4_0 -ctv q4_0
      -b 256 -ub 256 -lm dio -fit off --jinja --temp 0 --repeat-penalty 1.05)
read -ra XT <<< "$EXTRA"; ARGV+=("${XT[@]}")
read -ra EV <<< "$ENVS"
UT=$HOME/.hermes/cache/scratch/kprof/pti-gpu/tools/unitrace/build/unitrace
if [ "$PROF" = 1 ]; then ARGV=("$UT" -d --start-paused --session "p$TS" --teardown-on-signal 15 -o "$LOGD/$TAG.unitrace" "${ARGV[@]}"); fi
csv=$LOGD/vram-$TAG.csv; brf=$LOGD/BREACH-$TAG; rm -f "$csv" "$brf"
VRAM_FLOOR_MIB=750 setsid nohup python3 "$BO/vram-sampler.py" "$csv" "$brf" >/dev/null 2>&1 & SAMP=$!
t0=$(date +%s)
env CAP=14G CPUS=$CCD1 CPUW=20 WATCH_IO_GRACE_S=60 "${EV[@]}" setsid nice -n 10 ionice -c 3 bash "$LAB/bench/watchdog.sh" "perf62-$LABEL" -- \
  ionice -c 3 "$HOME/.local/bin/jobcap" "${ARGV[@]}" > "$LOGD/$TAG.server.log" 2>&1 &
for i in $(seq 900); do
  curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null && break
  [ -e "$brf" ] && break
  sleep 1
done
load_s=$(( $(date +%s) - t0 ))
if curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null && [ ! -e "$brf" ]; then
  PA=(); [ "$PROF" = 1 ] && PA=(--prof "p$TS")
  timeout 1500 python3 "$BO/perf-probe.py" $PORT "$DEPTHS" "$REPS" "${PA[@]}" > "$LOGD/$TAG.json" 2> "$LOGD/$TAG.probe.err"
  prc=$?
else prc=99; fi
stop_server
minfree=$(awk -F, 'NR>1 && $2!="" && (m==""||$2<m){m=$2} END{print m}' "$csv")
hits=$(journalctl -k --since "-15min" --no-pager -o cat 2>/dev/null | grep -ciE 'reset|timedout|wedged')
printf '%s\t%s\tload_s=%s\tprobe_rc=%s\tmin_free=%s\tbreach=%s\tklog_hits=%s\tjson=%s\n' "$(date -Iseconds)" "$LABEL" "$load_s" "$prc" "$minfree" "$([ -e "$brf" ] && echo 1 || echo 0)" "$hits" "$LOGD/$TAG.json" | tee -a "$LOGD/runs.tsv"
[ "$hits" -gt 0 ] && exit 5   # cleanup (EXIT trap) still waits for VRAM before the lock goes
exit 0
