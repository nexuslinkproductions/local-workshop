#!/usr/bin/env bash
# r46-tiers.sh <chainfile> — each line is one lc.py session under ITS OWN exclusive GPU lock (other leads share the card).
cd "$(dirname "$0")/.." || exit 2
n=0
while IFS= read -r line; do
  { [ -z "$line" ] || [ "${line:0:1}" = "#" ]; } && continue
  n=$((n+1)); one="$TMPDIR/r46-one-$$-$n.chain"; printf '%s\n' "$line" > "$one"
  flock -x -w 7200 bench/.gpu.lock env LC_LOCKED=1 bash bench/chief256k-chain.sh "$one"; rc=$?
  rm -f "$one"; [ "$rc" = 4 ] && { echo "HALT fault"; exit 4; }
done < "$1"
