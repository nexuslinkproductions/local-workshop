#!/usr/bin/env bash
# fit-ngl.sh — find the highest -ngl a config can actually load right now.
#
#   ./fit-ngl.sh configs/bonsai-prism-q8kv.env 99 48 32 24 16 8 4
#
# Steps down the candidate list, each time running a tiny llama-bench load probe
# (no rows recorded), and prints the first value that loads. Free VRAM changes
# with whatever else holds the GPU, so re-run this rather than trusting a number.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg="${1:?usage: fit-ngl.sh <config.env> <ngl> [ngl...]}"; shift
[ $# -gt 0 ] || { echo "give at least one -ngl candidate" >&2; exit 2; }

for n in "$@"; do
    log="$(mktemp)"
    if NGL_OVERRIDE="$n" DEPTHS_OVERRIDE=0 PROMPT_OVERRIDE=8 GEN_OVERRIDE=8 REPS_OVERRIDE=1 \
            "$HERE/bench.sh" "$cfg" --probe --force >"$log" 2>&1; then
        grep -o 'free=[0-9?]*MiB/[0-9?]*MiB Vulkan0 [a-z-]*' "$log" | tail -1
        echo "$n fits"
        rm -f "$log"
        exit 0
    fi
    printf 'ngl %-3s no fit: %s\n' "$n" "$(tail -1 "$log")" >&2
    rm -f "$log"
done
echo "none of the candidates fit — free VRAM is too low" >&2
exit 1
