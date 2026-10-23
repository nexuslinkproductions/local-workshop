#!/usr/bin/env bash
# run-measure.sh - pointer reactivity measurement for the v5 deck.
#
#   tools/linux/measure/run-measure.sh <label> <deckroot>
#
# <deckroot> is the directory that holds DeckView.qml, e.g.
#   .../work2/base/nexuslink.hud/v5/live
# Writes <out>/<label>.json (machine readable) and <out>/<label>.txt (full log).
# Out dir defaults to the M1 scratch; override with M1_OUT.
# Runs offscreen, software backend, low priority. No GPU, no lock needed.
set -o pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <label> <deckroot>" >&2
    exit 64
fi
label=$1
deckroot=$(cd -- "$2" 2>/dev/null && pwd -P)
if [ -z "$deckroot" ] || [ ! -f "$deckroot/DeckView.qml" ]; then
    echo "error: $2 does not hold DeckView.qml" >&2
    exit 2
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
out=${M1_OUT:-/home/nexuslink/.hermes/cache/scratch/hud-live/work2/M1}
mkdir -p "$out"
run=$out/_run_$label.qml

sed -e "s|^    readonly property string deckRoot: \"DECKROOT\"|    readonly property string deckRoot: \"$deckroot\"|" \
    -e "s|^    property string label: \"LABEL\"|    property string label: \"$label\"|" \
    "$here/hover.qml" > "$run"
grep -q "deckRoot: \"$deckroot\"" "$run" || { echo "error: DECKROOT marker not substituted" >&2; exit 3; }

log=$out/$label.txt
start=$(date +%s)
# shellcheck disable=SC2086
env QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QSG_RENDER_LOOP=basic \
    nice -n 19 ionice -c3 /usr/lib/qt6/bin/qmltestrunner -maxwarnings 0 -input "$run" \
    > "$log" 2>&1
rc=$?
end=$(date +%s)

# pull the JSON block out of the log; qmltestrunner prefixes every line with
# "QDEBUG : <case>() qml: ", so strip that prefix first
sed -n '/MEASURE_JSON_BEGIN$/,/MEASURE_JSON_END$/p' "$log" \
    | sed -e 's/.*qml: //' -e '/MEASURE_JSON_/d' > "$out/$label.json"
if [ ! -s "$out/$label.json" ]; then
    echo "error: no JSON emitted, see $log" >&2
    rm -f "$run"
    exit 4
fi
# strip the qml: debug prefix if the runner wrapped the line
sed -i 's/^qml: //' "$out/$label.json"
if command -v jq >/dev/null 2>&1; then
    jq -e . "$out/$label.json" >/dev/null 2>&1 \
        || echo "warn: $out/$label.json does not parse as JSON" >&2
fi
rm -f "$run"
grep -E "MEASURE_|PASS|FAIL|Totals" "$log" | sed 's/^.*qml: //' | cut -c1-200
echo "run-measure: label=$label deckroot=$deckroot exit=$rc seconds=$((end-start))"
echo "run-measure: $out/$label.json $log"
exit $rc
