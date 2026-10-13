#!/usr/bin/env bash
# After the MiniCPM chain (pid $1): Ornith 256K, variant A = FFN of layers 0-2 in system RAM, else B = smaller batch (-ub 512).
while kill -0 "$1" 2>/dev/null; do sleep 20; done
cd ~/NEXUS_AI_CENTER/LOCAL-AI-LAB
for X in "-ot blk.(0|1|2).ffn_.*=CPU --no-op-offload" "-ub 512 -b 512"; do
  echo "ORNITH-256K variant: $X $(date +%T)"
  ORNITH_EXTRA="$X" CHALLENGERS=ornith-9b bash bench/bakeoff42/run-challengers.sh
  grep -q "phase swap ornith-9b rc=0" <(tail -5 bench/bakeoff42/logs/challengers.log) && { echo "ORNITH-256K OK with: $X"; break; }
done
