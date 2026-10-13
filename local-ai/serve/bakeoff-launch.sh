#!/usr/bin/env bash
# bakeoff-launch.sh <port> <ctx> <main.gguf> <mmproj.gguf> [kv_type] [--mmproj-cpu]
# llama-swap `cmd` for the bakeoff42 models (ornith-9b, ministral3-14b).
# Mirrors serve/gemma4-12b-launch.sh: gate-run (ARC Raiders) -> this ->
# bench/watchdog.sh (PSI/RAM kill switch) -> ionice -c 3 -> jobcap -> llama-server.
set -euo pipefail
LAB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PORT="$1"; CTX="$2"; M="$3"; MM="$4"; KV="${5:-q8_0}"; shift 5 2>/dev/null || shift $#
set +u; . "$LAB/bench/configs/sycl-env.sh"; set -u
export CAP=14G CPUS=6-11,18-23 CPUW=20 WATCH_IO_GRACE_S="${WATCH_IO_GRACE_S:-60}"
G="$LAB/engines/llama.cpp-sycl-tip/build/bin/llama-server"
EXTRA=()
for a in "$@"; do [ "$a" = "--mmproj-cpu" ] && EXTRA+=(--no-mmproj-offload); done
read -ra XTRA <<< "${BAKEOFF_EXTRA:-}"   # e.g. -ot blk.(0|1|2).ffn_.*=CPU: spill weights to system RAM
exec bash "$LAB/bench/watchdog.sh" "bakeoff-$PORT" -- ionice -c 3 /home/nexuslink/.local/bin/jobcap \
    "$G" -m "$M" --mmproj "$MM" "${EXTRA[@]}" \
    --host 127.0.0.1 --port "$PORT" --device SYCL0 -ngl 99 -c "$CTX" -np 1 -t 16 \
    -fa on -ctk "$KV" -ctv "$KV" -b 1024 -ub 1024 -lm dio -fit off \
    --jinja --temp 0 --repeat-penalty 1.05 "${XTRA[@]}"   # BAKEOFF_EXTRA last so its flags override
