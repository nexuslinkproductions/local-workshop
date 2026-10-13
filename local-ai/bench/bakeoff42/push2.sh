#!/usr/bin/env bash
# Round 2 at the 750 MiB floor: Ornith (base, MTP, stacked combo), then MiniCPM points that the 900 floor blocked.
cd ~/NEXUS_AI_CENTER/LOCAL-AI-LAB
S=bench/bakeoff42/speed-push.sh
bash $S --only '^or-(ub256|poll0|combo|combo-mtp2|combo-mtp3|mtp2-ub256|mtp3-ub256|base|mtp1|mtp2|mtp3)$'
bash $S --only '^mc-(base28|t6|nc30|cache512|cache1024|cache1536)$'
echo "PUSH2 done $(date +%T)"
