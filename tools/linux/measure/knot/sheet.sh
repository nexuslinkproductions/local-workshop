#!/usr/bin/env bash
# sheet.sh: render a time series of the knot and compose a contact sheet.
#
#   tools/linux/measure/knot/sheet.sh <scene.qml-template> <outdir> <t0> <t1> <step> <out.png> [cols] [rows]
#
# Renders t0, t0+step, ... up to and including t1 through render_times.sh (one
# v5-shot.sh process per frame), then calls contact_sheet.py with the frame time
# labelled under every cell. Default grid 5 x 4 (20 cells, 3 s step over 60 s),
# cell 340 px, so the sheet is about 1760 x 1514. Frames stay in <outdir> and
# are reused by anything else that reads frames.txt.
#
# Example (the two evidence sheets of KNOT-SPEC-R4 section 5):
#   sheet.sh scene.qml frames-a 0 57 3  sheet-0-57.png
#   sheet.sh scene.qml frames-b 60 117 3 sheet-60-117.png
set -euo pipefail

if [ $# -lt 6 ]; then
    sed -n '2,20p' "$0" | sed -e 's/^# \{0,1\}//'
    exit 64
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmpl=$1
outdir=$2
t0=$3
t1=$4
step=$5
out=$6
cols=${7:-5}
rows=${8:-4}

[ -f "$tmpl" ] || { echo "sheet: no such template: $tmpl" >&2; exit 64; }

# build the time list with awk so fractional steps work too
times=$(awk -v a="$t0" -v b="$t1" -v s="$step" 'BEGIN{
    n = 0;
    for (t = a; t <= b + 1e-9; t += s) { printf "%s%.4f", (n ? " " : ""), t; n++ }
    if (n == 0) { printf "%s", a }
    printf "\n";
}')

count=$(printf '%s\n' "$times" | wc -w)
cells=$(( cols * rows ))
if [ "$count" -ne "$cells" ]; then
    echo "sheet: warning: $count times for a ${cols}x${rows} grid ($cells cells)" >&2
fi

# shellcheck disable=SC2086
"$here/render_times.sh" "$tmpl" "$outdir" $times

mkdir -p -- "$(dirname -- "$out")"
SHEET_CELL=${SHEET_CELL:-340} python3 "$here/contact_sheet.py" \
    "$outdir/frames.txt" "$out" "$cols" "$rows"
