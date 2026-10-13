#!/usr/bin/env bash
cd /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
U=$HOME/.hermes/cache/scratch/kprof/pti-gpu/tools/unitrace/build/unitrace
mkdir -p bench/logs/r46/prof
for kv in f16 q4_0; do
  for try in 1 2 3; do
    R46_WRAP="$U -d -o bench/logs/r46/prof/prof-$kv.unitrace" bench/r46-depth.sh prof-$kv -ctk $kv -ctv $kv -ub 512 -b 1024 -p 0 -n 24 -d 32768 -r 1 --no-warmup && break
    [ $? = 4 ] && exit 4; sleep 60
  done
done
