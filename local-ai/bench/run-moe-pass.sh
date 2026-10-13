#!/usr/bin/env bash
# run-moe-pass.sh — the full measurement pass for one MoE matrix config, in order:
#   1. refine the --n-cpu-moe cliff (probe a list of values, high->low)
#   2. baseline llama-bench at the winner (depth 0, reps 3)
#   3. locked server session (cold/warm start, TTFT 4K/32K, vision, tool call)
#   4. server-side spec levers (--spec-type, --moe-cache-mib, --no-mmproj-offload)
#   5. llama-bench hillclimb (one lever at a time, keep if pp/tg +3%)
# Every step self-locks; the script just runs them in sequence and prints progress.
#
#   run-moe-pass.sh <cfg> [ncmoe-candidates...]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
CFG="${1:?usage: run-moe-pass.sh <cfg> [ncmoe...]}"; shift
CANDS=("$@"); [ ${#CANDS[@]} -gt 0 ] || CANDS=(24 22 20 18 16)

MODEL_TAG="$(basename "$CFG" .env)"
winner() {   # lowest ncmoe with a PASS loadprobe row for this config's model
    awk -F'\t' -v tag="$MODEL_TAG" '$10=="loadprobe" && $6 ~ /ncmoe=/ {match($6,/ncmoe=[0-9]+/); print substr($6,RSTART+6,RLENGTH-6)}' \
        results-matrix.tsv | sort -n | head -1
}

echo "=== [$MODEL_TAG] step 1: cliff probes ${CANDS[*]} $(date -Iseconds)"
for n in "${CANDS[@]}"; do
    echo "--- probe ncmoe=$n $(date -Iseconds)"
    if PROBE_MIN_HEADROOM=600 NCMOE_OVERRIDE="$n" PLACEMENT_OVERRIDE="ngl=99/ncmoe=$n" \
        PROBE_TMO=420 ./matrix-bench.sh probe --cfg "$CFG"; then
        echo "OK ncmoe=$n"
    else
        echo "STOP ncmoe=$n rc=$?"
        break
    fi
done
N="$(winner)"; echo "=== [$MODEL_TAG] winner ncmoe=$N $(date -Iseconds)"

echo "=== [$MODEL_TAG] step 2: baseline bench (depth 0, reps 3) $(date -Iseconds)"
NCMOE_OVERRIDE="$N" PLACEMENT_OVERRIDE="ngl=99/ncmoe=$N" DEPTHS_OVERRIDE=0 REPS_OVERRIDE=3 \
    ./matrix-bench.sh run --cfg "$CFG"

echo "=== [$MODEL_TAG] step 3: server session $(date -Iseconds)"
NCMOE_OVERRIDE="$N" PLACEMENT_OVERRIDE="ngl=99/ncmoe=$N" ./matrix-server.sh --cfg "$CFG"

echo "=== [$MODEL_TAG] step 4: spec levers $(date -Iseconds)"
NCMOE_OVERRIDE="$N" PLACEMENT_OVERRIDE="ngl=99/ncmoe=$N" ./spec-levers.sh --cfg "$CFG" --tokens 4096 --n-predict 256

echo "=== [$MODEL_TAG] step 5: hillclimb $(date -Iseconds)"
CLIFF=$(( N - 1 )); [ "$CLIFF" -lt 0 ] && CLIFF=0
SAFE=$(( N + 8 )); [ "$SAFE" -gt 40 ] && SAFE=40
python3 - "$CLIFF" "$SAFE" <<'PY'
import json, sys
cliff, safe = sys.argv[1], sys.argv[2]
plan = json.load(open("configs/levers/hclimb-moe.json"))
for lev in plan:
    lev["flags"] = [f.replace("CLIFF", cliff).replace("SAFE", safe) for f in lev["flags"]]
out = "configs/levers/hclimb-moe-resolved.json"
json.dump(plan, open(out, "w"), indent=1)
print("wrote", out, "cliff=", cliff, "safe=", safe)
PY
NCMOE_OVERRIDE="$N" PLACEMENT_OVERRIDE="ngl=99/ncmoe=$N" \
    python3 hillclimb.py --cfg "$CFG" --levers configs/levers/hclimb-moe-resolved.json --depths 0 --reps 3

echo "=== [$MODEL_TAG] PASS DONE $(date -Iseconds)"
