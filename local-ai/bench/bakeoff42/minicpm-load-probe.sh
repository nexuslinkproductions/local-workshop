#!/usr/bin/env bash
# Diagnose the MiniCPM load stall: one load (ncmoe 41, vision on CPU, 256K, q4_0), sample psi + vmstat every second.
LAB=~/NEXUS_AI_CENTER/LOCAL-AI-LAB; cd $LAB
set +u; . bench/configs/sycl-env.sh; set -u
MD=$LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf
OUT=bench/bakeoff42/logs/minicpm-load-probe${NOPIN:+-nopin}-$(date +%H%M%S).tsv; : > $OUT
[ -n "${NOPIN:-}" ] && export GGML_SYCL_NO_PINNED=1
v(){ awk '/^(compact_stall|pswpin|pswpout|allocstall_movable|thp_fault_alloc|pgmajfault) /{printf "%s ",$2}' /proc/vmstat; }
CAP=48G CPUS=6-11,18-23 CPUW=20 WATCH_PSI_FULL_MAX=20 WATCH_IO_GRACE_S=60 setsid bash bench/watchdog.sh probe -- ionice -c 3 ~/.local/bin/jobcap \
  $LAB/engines/llama.cpp-sycl-tip/build/bin/llama-server -m $MD/MiniCPM-V-4.7-35B-A3B-AD-Q4_K-IQ4_XS.gguf --mmproj $MD/mmproj-model-f16.gguf \
  --no-mmproj-offload --host 127.0.0.1 --port 18199 --device SYCL0 -ngl 99 --n-cpu-moe 41 -c 262144 -np 1 -t 16 -fa on -ctk q4_0 -ctv q4_0 \
  -b 1024 -ub 1024 -lm dio -fit off > bench/bakeoff42/logs/minicpm-load-probe.server.log 2>&1 &
P=$!
echo -e "t\tmem_full10\tio_full10\tfree_mb\tcompact_stall pswpin pswpout allocstall thp pgmaj" >> $OUT
for i in $(seq 1 45); do
  echo -e "$i\t$(awk '/^full/{print $2}' /proc/pressure/memory)\t$(awk '/^full/{print $2}' /proc/pressure/io)\t$(awk '/MemFree/{print int($2/1024)}' /proc/meminfo)\t$(v)" >> $OUT
  curl -sf -m 1 http://127.0.0.1:18199/health >/dev/null && { echo "HEALTHY at $i s" >> $OUT; break; }
  kill -0 $P 2>/dev/null || { echo "DIED at $i s" >> $OUT; break; }
  sleep 1
done
kill -TERM -$P 2>/dev/null; sleep 2; kill -KILL -$P 2>/dev/null; pkill -f "[l]lama-server.*--port 18199"
