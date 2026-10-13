#!/usr/bin/env bash
# chief256k-chain.sh <chainfile> — run lc.py sessions listed one per line (args of lc.py), in order.
# Under the GPU lock (caller). Stops the whole chain on exit 4 (GPU fault); other failures continue.
cd "$(dirname "$0")/.." || exit 2
while IFS= read -r line; do
  { [ -z "$line" ] || [ "${line:0:1}" = "#" ]; } && continue
  echo "=== $(date +%T) lc.py $line"
  eval "python3 bench/lc.py $line"; rc=$?
  if [ "$rc" = 5 ]; then echo "(watchdog IO/mem abort, retrying on a quiet disk)"; for try in 1 2 3 4 5; do sleep 20; eval "python3 bench/lc.py $line"; rc=$?; [ "$rc" = 5 ] || break; done; fi
  echo "--- rc=$rc kernel:"; journalctl -k -b --no-pager | grep -E 'GT0|wedged|DEVICE_LOST|Timedout' | tail -3
  if [ "$rc" = 4 ]; then echo "HALT: GPU fault, chain stopped"; exit 4; fi
  if pgrep -f 'llama-server.*--port 18095' >/dev/null; then echo "server left running!"; pkill -KILL -f 'llama-server.*--port 18095'; fi
  sleep 5
done < "$1"
