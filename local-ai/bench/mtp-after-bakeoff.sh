#!/usr/bin/env bash
# Wait for the quiet bake-off rerun to finish, then measure Gemma MTP at 64K with the image module on CPU
# (the earlier MTP run dipped to 916 MiB free with mmproj on GPU). Activation decision follows the result.
cd "$HOME/NEXUS_AI_CENTER/LOCAL-AI-LAB" || exit 1
while pgrep -f "bakeoff42/quiet-rerun.sh|bakeoff42/run-challengers.sh" >/dev/null; do sleep 30; done
TMPDIR=$HOME/.hermes/cache/scratch bash bench/r46-tiers.sh bench/logs/chief256k/mtp-activate.chain > bench/logs/mtp-activate.log 2>&1
echo "MTP-ACTIVATE rc=$? $(date +%T)" >> bench/logs/mtp-activate.log
