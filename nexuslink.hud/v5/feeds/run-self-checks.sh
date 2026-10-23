#!/bin/sh
# Run every v5 feed self-check on this host and fail loudly if one fails.
#
#   sh nexuslink.hud/v5/feeds/run-self-checks.sh
#
# Each reader prints one PASS/FAIL line per assertion and a summary line; this
# runner prints the exit code it saw for each one. Exit 0 means all four passed.
set -u

here=$(cd "$(dirname "$0")" && pwd)
python=${PYTHON:-python3}
status=0

for reader in sessions link apps metrics; do
    echo "== ${reader}.py --self-check"
    "$python" "$here/${reader}.py" --self-check
    code=$?
    echo "-- ${reader}.py exit ${code}"
    [ "$code" -eq 0 ] || status=1
    echo
done

if [ "$status" -eq 0 ]; then
    echo "all feed self-checks passed"
else
    echo "at least one feed self-check FAILED"
fi
exit "$status"
