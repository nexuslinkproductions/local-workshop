#!/usr/bin/env bash
# tests/quick/check-commands.sh - every process argv[0] in the quick-action table
# must resolve on PATH. Reads the table from actions.js (the ARGV rows that are
# arrays) and checks each name with command -v. It never runs the commands.
set -o pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ACTIONS="$HERE/../../actions.js"
rows=$(sed -n 's/^ *"\([a-z-]*\)": \["\([^"]*\)".*/\1 \2/p' "$ACTIONS")
n=0
bad=0
while read -r id cmd; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    if p=$(command -v "$cmd" 2>/dev/null); then
        echo "OK      $id $cmd $p"
    else
        echo "MISSING $id $cmd"
        bad=$((bad + 1))
    fi
done <<< "$rows"
echo "table rows with argv $n, missing $bad"
[ "$n" -eq 3 ] && [ "$bad" -eq 0 ]
