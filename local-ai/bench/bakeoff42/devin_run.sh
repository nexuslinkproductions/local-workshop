#!/usr/bin/env bash
# devin_run.sh: E02, then E01, then E08. Each one takes bench/.gpu.lock exclusively
# on its own (one at a time). Stops the chain on a kernel reset hit or budget abort (exit 3).
set -uo pipefail
cd /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB || exit 1
H=bench/bakeoff42/devin_harness.py
for e in E02 E01 E08; do
    echo "=== $e lock-wait-start $(date +%T)"
    flock -x -w 1800 bench/.gpu.lock python3 "$H" "$e"
    rc=$?
    echo "=== $e rc=$rc end $(date +%T)"
    pgrep -af '[b]uild/bin/llama-server|--port 18199' && echo "!! server left after $e"
    if [ "$rc" -eq 3 ]; then echo "ABORT: chain stopped"; break; fi
    hit=$(journalctl -k --since '2026-10-13 21:43:45' 2>/dev/null | grep -iE 'reset|timedout|wedged')
    if [ -n "$hit" ]; then echo "KLOG HIT after $e: $hit"; break; fi
done
echo "CHAIN DONE $(date +%T)"
