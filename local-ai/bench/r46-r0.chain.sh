#!/usr/bin/env bash
cd /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
for kv in q8_0 q4_0 f16; do
  bench/r46-depth.sh r0-$kv-ub512 -ctk $kv -ctv $kv -ub 512 -b 1024 -p 0 -n 64 -d 0,8192,32768,65536 -r 2 || { rc=$?; echo "chain stop rc=$rc"; [ $rc = 4 ] && exit 4; }
done
