#!/usr/bin/env bash
# render-states.sh [outdir]
# Generates the deck B scenes (tools/linux/scenes/gen-scenes.py), renders the
# rest state and the six focus states through tools/linux/deck-shot.sh as
# B-<state>-2560x1440.png, prints each harness evidence line, and exits non-zero
# if a render fails or the harness does not report api=opengl.
set -u
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
OUT=${1:-$HOME/.hermes/cache/scratch/hud-live/main/render}
SCENES=${TMPDIR:-/tmp}/deckb-scenes
mkdir -p "$OUT" || exit 3
nice -n 19 ionice -c3 python3 "$HERE/scenes/gen-scenes.py" "$SCENES" || {
  echo "render-states: generator failed" >&2
  exit 1
}
rc=0
for s in rest crew find launcher mac storage local; do
  png="$OUT/B-$s-2560x1440.png"
  log=$(nice -n 19 ionice -c3 "$HERE/deck-shot.sh" "$SCENES/scene-$s.qml" "$png" 2560 1440 2>&1)
  code=$?
  ev=$(printf '%s\n' "$log" | grep -iE 'qt=|api=|distinct=')
  printf '%s\n' "$ev" | sed "s/^/[$s] /"
  if [ "$code" -ne 0 ] || [ ! -s "$png" ]; then
    echo "[$s] FAIL render exit=$code"
    rc=1
  elif ! printf '%s' "$ev" | grep -qi 'api=opengl'; then
    echo "[$s] FAIL api is not opengl"
    rc=1
  else
    echo "[$s] OK exit=$code $png"
  fi
done
exit $rc
