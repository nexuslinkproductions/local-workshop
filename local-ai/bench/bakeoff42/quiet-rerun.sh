#!/usr/bin/env bash
# Re-run the Ornith/Ministral bake-off only when the box is quiet:
# no Hermes bot runs (retro/report/repo-plan) and memory+IO pressure low for 60 s.
# Reason: run at 17:17 got 12 watchdog restarts from bots starting during it (logs/INVALID-1736-memprs).
cd "$HOME/NEXUS_AI_CENTER/LOCAL-AI-LAB" || exit 1
L=bench/bakeoff42/logs/quiet-rerun.log
psi() { awk -F'avg60=' '/^full/{split($2,a," "); print a[1]}' /proc/pressure/$1; }
quiet=0
while :; do
  bots=$(pgrep -fc "RETRO-1013|LAB-REPORT-1013|UNIFIED-REPO-PLAN")
  m=$(psi memory); i=$(psi io)
  if [ "$bots" -eq 0 ] && awk -v m="$m" -v i="$i" 'BEGIN{exit !(m<0.3 && i<0.3)}'; then quiet=$((quiet+15)); else quiet=0; fi
  echo "$(date +%T) bots=$bots psi_mem60=$m psi_io60=$i quiet=${quiet}s" >> "$L"
  [ "$quiet" -ge 60 ] && break
  sleep 15
done
echo "$(date +%T) QUIET -> starting driver" >> "$L"
CHALLENGERS=ornith-9b bash bench/bakeoff42/run-challengers.sh >> bench/bakeoff42/logs/challengers.out 2>&1
echo "$(date +%T) DRIVER rc=$?" >> "$L"
