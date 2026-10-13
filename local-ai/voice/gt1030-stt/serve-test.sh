#!/usr/bin/env bash
# serve-test.sh: start whisper-server on the GT 1030 under bench/.gpu.lock + watchdog,
# run one HTTP transcription, stop it. Leaves nothing running.
set -uo pipefail
LAB="$HOME/NEXUS_AI_CENTER/LOCAL-AI-LAB"
BIN="$LAB/voice/engines/whisper.cpp-cuda/bin/whisper-server"
MODEL="$LAB/models/stt/whisper/ggml-large-v3-turbo-q5_0.bin"
CLIP="$LAB/voice/gt1030-stt/clips/c2-battery.wav"
PORT=8178
LOG="$LAB/logs-gt1030/serve-test.log"
cd "$LAB"
flock -x bench/.gpu.lock bash -c '
  WATCH_IO_GRACE_S=20 bash bench/watchdog.sh gt1030-whisper-server -- \
    taskset -c 6-11 "$0" -m "$1" --host 127.0.0.1 --port "$2" -t 6 -l en > "$3" 2>&1 &
  WP=$!
  for i in $(seq 1 120); do
    curl -sf -o /dev/null "http://127.0.0.1:$2/" && break; sleep 0.5
  done
  echo "--- HTTP test:"
  curl -s "http://127.0.0.1:$2/inference" -F "file=@$4" -F response_format=json; echo
  echo "--- nvidia-smi while serving:"
  nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader
  kill -TERM $WP 2>/dev/null; wait $WP 2>/dev/null
  echo "server_rc=$?"
' "$BIN" "$MODEL" "$PORT" "$LOG" "$CLIP" 2>&1 | tee "$LAB/logs-gt1030/serve-test.out"
