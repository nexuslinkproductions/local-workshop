#!/usr/bin/env bash
# Bake env.vert.qsb and env.frag.qsb (same qsb flags as bake.sh).
#   shaders/env-bake.sh              bake the plugin's env.vert and env.frag
#   FRAG=<file.frag> shaders/env-bake.sh   bake one other fragment shader to <file.frag>.qsb
#                                    (the converted s6 hall lives in scratch, never here)
set -euo pipefail
cd "$(dirname "$0")"
Q=${QSB:-/usr/lib/qt6/bin/qsb}
FLAGS=(--glsl "100 es,120,150,300 es,330" --hlsl 50 --msl 12)
if [ -n "${FRAG:-}" ]; then
  "$Q" "${FLAGS[@]}" -o "$FRAG.qsb" "$FRAG"
  exit 0
fi
"$Q" "${FLAGS[@]}" -o env.vert.qsb env.vert
"$Q" "${FLAGS[@]}" -o env.frag.qsb env.frag
