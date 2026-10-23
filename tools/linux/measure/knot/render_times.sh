#!/usr/bin/env bash
# render_times.sh: render an explicit list of times of the knot, one v5-shot.sh
# process per frame (no timers, no animation, the QML time is pinned by sed).
#
#   tools/linux/measure/knot/render_times.sh <scene.qml-template> <outdir> <t1> [t2 ...]
#
# The template must contain the literal TVALUE. Each frame is written as
# <outdir>/frame-<t>s.png (dots in the time kept, sign kept) and <outdir>/frames.txt
# gets one "t path" line per frame in the order given, which contact_sheet.py
# reads directly. Seconds per frame is printed per frame and as a summary.
#
# Environment: V5_SHOT (default ../../v5-shot.sh), RENDER_W / RENDER_H (700).
# v5-shot.sh takes the render lock and the nice/ionice prefix itself.
set -euo pipefail

if [ $# -lt 3 ]; then
    sed -n '2,12p' "$0" | sed -e 's/^# \{0,1\}//'
    exit 64
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
shot=${V5_SHOT:-$here/../../v5-shot.sh}
tmpl=$1
outdir=$2
shift 2
width=${RENDER_W:-700}
height=${RENDER_H:-700}

[ -f "$tmpl" ] || { echo "render_times: no such template: $tmpl" >&2; exit 64; }
grep -q TVALUE "$tmpl" || { echo "render_times: template has no TVALUE" >&2; exit 64; }
[ -x "$shot" ] || [ -f "$shot" ] || { echo "render_times: no such shot script: $shot" >&2; exit 64; }

mkdir -p -- "$outdir"
outdir=$(cd -- "$outdir" && pwd -P)
: > "$outdir/frames.txt"

# The scene imports "kit" and "live" relative to its own file, so the per frame
# scene copies need both next to them in outdir.
KIT=${KNOT_KIT:-/home/nexuslink/hud-wt/v5-live/nexuslink.hud/v5/kit}
LIVE=${KNOT_LIVE:-/home/nexuslink/hud-wt/v5-live/nexuslink.hud/v5/live}
for l in kit live; do
    case $l in kit) tgt=$KIT ;; live) tgt=$LIVE ;; esac
    if [ ! -e "$outdir/$l" ]; then ln -s "$tgt" "$outdir/$l"; fi
done

n=0
fail=0
t_all0=$(date +%s.%N)
for t in "$@"; do
    # sanitise the time for a file name: 12 -> 12, 12.5 -> 12.5, -3 -> m3
    name=$(printf '%s' "$t" | sed -e 's/^-/m/' -e 's/[^0-9A-Za-z.]/_/g')
    scene="$outdir/scene-$name.qml"
    png="$outdir/frame-$name.png"
    sed "s/TVALUE/$t/g" "$tmpl" > "$scene"
    printf '%s %s\n' "$t" "$png" >> "$outdir/frames.txt"
    t0=$(date +%s.%N)
    echo "render_times: t=$t -> $png" >&2
    if ! nice -n 19 "$shot" "$scene" "$png" "$width" "$height" 2>&1 | sed 's/^/  /' >&2; then
        echo "render_times: FAILED t=$t" >&2
        fail=$(( fail + 1 ))
        continue
    fi
    t1=$(date +%s.%N)
    dt=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    echo "render_times: t=$t took ${dt}s" >&2
    n=$(( n + 1 ))
done
t_all1=$(date +%s.%N)

awk -v n="$n" -v f="$fail" -v a="$t_all0" -v b="$t_all1" 'BEGIN{
    d = b - a;
    printf "render_times: %d frames ok, %d failed, wall %.1fs, %.2fs per frame\n", n, f, d, (n ? d / n : 0);
}'
[ "$fail" -eq 0 ]
