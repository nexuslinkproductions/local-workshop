#!/usr/bin/env bash
# run_one.sh <gpu|cpu> <model-file> <clip.wav> <outprefix>
# One whisper-cli run under bench/.gpu.lock (flock -x) and bench/watchdog.sh.
# gpu: CUDA build, sampled nvidia-smi memory during the run. cpu: CPU-only build.
# Both pinned to CCD cores 6-11 with 6 threads.
set -uo pipefail
LAB="$HOME/NEXUS_AI_CENTER/LOCAL-AI-LAB"
MODE="$1"; MODEL="$2"; CLIP="$3"; OUT="$4"
if [ "$MODE" = gpu ]; then BIN="$LAB/voice/engines/whisper.cpp-cuda/bin/whisper-cli"
else BIN="$LAB/voice/engines/whisper.cpp-cpu/bin/whisper-cli"; fi
mkdir -p "$(dirname "$OUT")"
cd "$LAB"
flock -x bench/.gpu.lock bash -c '
  if [ "$0" = gpu ]; then
    nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits -lms 100 > "$4.smi.csv" 2>/dev/null &
    echo $! > "$4.smi.pid"
  fi
  t0=$(date +%s%N)
  # model load reads ~0.5 GB at NVMe speed = a real io-full burst (watchdog.sh header);
  # skip only the io trip for the first 20 s, memory trips stay on.
  WATCH_IO_GRACE_S=20 bash bench/watchdog.sh "$0-$(basename "$2" .bin)" -- taskset -c 6-11 "$1" -m "$2" -f "$3" -t 6 -l en -nt > "$4.txt" 2> "$4.err"
  rc=$?
  t1=$(date +%s%N)
  if [ -f "$4.smi.pid" ]; then kill "$(cat "$4.smi.pid")" 2>/dev/null; rm -f "$4.smi.pid"; fi
  echo "$rc" > "$4.rc"
  echo $(( (t1 - t0) / 1000000 )) > "$4.wall_ms"
' "$MODE" "$BIN" "$MODEL" "$CLIP" "$OUT" 2>/dev/null
cat "$OUT.rc"
