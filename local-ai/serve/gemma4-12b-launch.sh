#!/usr/bin/env bash
# gemma4-12b-launch.sh <port> — llama-swap cmd for gemma4-12b (via serve/gate-run.sh).
# Chain: gate-run (ARC Raiders check) -> this -> bench/watchdog.sh (PSI/RAM kill switch)
#        -> ionice -c 3 -> jobcap (memory cap + CCD pin + low CPU weight) -> llama-server.
# Thinking is NOT set here: llama-swap setParamsByID decides it per model id (config.yaml).
set -euo pipefail
LAB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PORT="$1"
CTX="${2:-65536}"   # Hermes refuses < 64K (agent/model_metadata.py MINIMUM_CONTEXT_LENGTH)
set +u; . "$LAB/bench/configs/sycl-env.sh"; set -u   # oneAPI + dnnl libs, same shell as the binary
export CAP=14G CPUS=6-11,18-23 CPUW=20 WATCH_IO_GRACE_S="${WATCH_IO_GRACE_S:-60}"
G="$LAB/engines/llama.cpp-sycl-tip/build/bin/llama-server"
M="$LAB/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf"
# MTP draft head (research/26 r26b2). 0 = off (default). 3 = measured best: 78 t/s vs 35 base,
# 5/6 greedy replies identical. OFF by default: at ctx 65536 it leaves 995 MiB VRAM free after load
# vs 1648 MiB without, under the 1.0 GiB stop line in research/RESUME-after-reboot-2.md. Set to 3 once Marcel OKs.
MTP_NMAX="${MTP_NMAX:-0}"
MTP="$LAB/models/llm/unsloth/gemma-4-12B-it-qat-GGUF/mtp-gemma-4-12B-it.gguf"
MTP_ARGS=()
if [ "$MTP_NMAX" -gt 0 ]; then MTP_ARGS=(-md "$MTP" -ngld 99 --spec-draft-device SYCL0 --spec-type draft-mtp --spec-draft-n-max "$MTP_NMAX"); fi
exec bash "$LAB/bench/watchdog.sh" gemma4-12b -- ionice -c 3 /home/nexuslink/.local/bin/jobcap \
    "$G" -m "$M/gemma-4-12b-it-qat-q4_0.gguf" --mmproj "$M/mmproj-gemma-4-12b-it-qat-q4_0.gguf" \
    --host 127.0.0.1 --port "$PORT" --device SYCL0 -ngl 99 -c "$CTX" -np 1 -t 16 \
    -fa on -ctk q8_0 -ctv q8_0 -b 1024 -ub 1024 -lm dio -fit off \
    ${MTP_ARGS[@]+"${MTP_ARGS[@]}"} \
    --jinja --temp 0 --repeat-penalty 1.05
