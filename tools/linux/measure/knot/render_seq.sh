#!/usr/bin/env bash
# render_seq.sh: render a 6 s knot sequence frame by frame through v5-shot.sh.
#
#   tools/linux/measure/knot/render_seq.sh <scene.qml-template> <outdir> [stride]
#
# The template must contain the literal TVALUE where the time in seconds goes;
# every frame is a sed-substituted copy of the template, so one process per
# frame, no animation and no timer involved. 6 s at 24 fps = 144 frames,
# frame i is t = i / 24. stride 12 renders 12 frames (t = 0, 0.5, ... 5.5),
# stride 1 renders all 144. A copy of the scene per frame is left in outdir
# (scene-<mmmm>.qml) plus frames.txt, one "t path" line per frame.
#
# v5-shot.sh takes the render lock and the nice/ionice prefix itself.
set -euo pipefail

if [ $# -lt 2 ]; then
    sed -n '2,12p' "$0" | sed -e 's/^# \{0,1\}//'
    exit 64
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
shot=${V5_SHOT:-$here/../../v5-shot.sh}
tmpl=$1
outdir=$2
stride=${3:-12}
fps=${SEQ_FPS:-24}
seconds=${SEQ_SECONDS:-6}
width=${SEQ_W:-700}
height=${SEQ_H:-700}

[ -f "$tmpl" ] || { echo "render_seq: no such template: $tmpl" >&2; exit 64; }
grep -q TVALUE "$tmpl" || { echo "render_seq: template has no TVALUE" >&2; exit 64; }
case "$stride" in ''|*[!0-9]*) echo "render_seq: stride must be a positive integer" >&2; exit 64 ;; esac
[ "$stride" -ge 1 ] || { echo "render_seq: stride must be >= 1" >&2; exit 64; }

mkdir -p -- "$outdir"
outdir=$(cd -- "$outdir" && pwd -P)
: > "$outdir/frames.txt"

total=$(( seconds * fps ))
count=0
for (( i = 0; i < total; i += stride )); do
    name=$(awk -v i="$i" 'BEGIN{printf "%04d", i}')
    t=$(awk -v i="$i" -v f="$fps" 'BEGIN{printf "%.4f", i / f}')
    scene="$outdir/scene-$name.qml"
    png="$outdir/frame-$name.png"
    sed "s/TVALUE/$t/g" "$tmpl" > "$scene"
    printf '%s %s\n' "$t" "$png" >> "$outdir/frames.txt"
    echo "render_seq: frame $name t=$t" >&2
    nice -n 19 "$shot" "$scene" "$png" "$width" "$height" 2>&1 | sed "s/^/  /" >&2
    count=$(( count + 1 ))
done

echo "render_seq: $count frames in $outdir (stride $stride, ${width}x${height})"
