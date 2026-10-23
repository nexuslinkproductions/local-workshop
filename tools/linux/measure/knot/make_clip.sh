#!/usr/bin/env bash
# make_clip.sh: render one 6 s knot clip frame by frame and encode it with ffmpeg.
#
#   tools/linux/measure/knot/make_clip.sh <scene.qml-template> <t0> <outdir> <out.mp4> [fps]
#
# 144 frames at 24 fps (fps argument overrides; CLIP_FRAMES overrides the
# count), frame i is t = t0 + i / fps. Every frame is its own v5-shot.sh
# process with the time pinned by sed (no timers, no animation). Frames land in
# <outdir>/clip-<t0>/ and are hardlinked to f-%04d.png for the encoder.
# libx264, yuv420p, crf 20, 700 x 700. Seconds per frame is printed.
#
#   make_clip.sh scene.qml 10 /tmp/b3 clip-calm-t10.mp4
set -euo pipefail

if [ $# -lt 4 ]; then
    sed -n '2,15p' "$0" | sed -e 's/^# \{0,1\}//'
    exit 64
fi

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmpl=$1
t0=$2
outdir=$3
out=$4
fps=${5:-${CLIP_FPS:-24}}
nframes=${CLIP_FRAMES:-$(( 6 * fps ))}

[ -f "$tmpl" ] || { echo "make_clip: no such template: $tmpl" >&2; exit 64; }

ff=${FFMPEG:-}
if [ -z "$ff" ]; then
    if [ -x /home/nexuslink/.hermes/tools/ffmpeg-9.0.1-linux-x64/bin/ffmpeg ]; then
        ff=/home/nexuslink/.hermes/tools/ffmpeg-9.0.1-linux-x64/bin/ffmpeg
    else
        ff=$(command -v ffmpeg) || { echo "make_clip: no ffmpeg" >&2; exit 69; }
    fi
fi

# time list: t0 + i / fps, 4 decimals
times=$(awk -v a="$t0" -v f="$fps" -v n="$nframes" 'BEGIN{
    for (i = 0; i < n; i++) printf "%s%.4f", (i ? " " : ""), a + i / f;
    printf "\n";
}')

clipdir="$outdir/clip-$t0"
# shellcheck disable=SC2086
"$here/render_times.sh" "$tmpl" "$clipdir" $times

# A second renderer writing the same outdir interleaves frames.txt (seen once:
# 184 lines for 144 frames, and a 7.7 s clip labelled 6 s). Refuse to encode.
got=$(wc -l < "$clipdir/frames.txt")
if [ "$got" -ne "$nframes" ]; then
    echo "make_clip: frames.txt has $got lines, expected $nframes: another writer" >&2
    echo "make_clip: shared $clipdir, refusing to encode" >&2
    exit 65
fi

# hardlink the frames to a contiguous pattern for the image2 demuxer
rm -f -- "$clipdir"/f-*.png
i=0
while read -r t p; do
    ln -f -- "$p" "$clipdir/$(printf 'f-%04d.png' "$i")"
    i=$(( i + 1 ))
done < "$clipdir/frames.txt"
echo "make_clip: $i frames linked for the encoder, fps $fps, t0 $t0" >&2

mkdir -p -- "$(dirname -- "$out")"
"$ff" -y -hide_banner -loglevel error -stats \
    -framerate "$fps" -i "$clipdir/f-%04d.png" \
    -c:v libx264 -pix_fmt yuv420p -crf 20 -preset veryfast \
    -movflags +faststart "$out"

dur=$("$ff" -hide_banner -i "$out" 2>&1 | sed -n 's/.*Duration: \([0-9:.]*\).*/\1/p' | head -1)
echo "make_clip: wrote $out (duration $dur, $i frames at $fps fps, t0=$t0)"
