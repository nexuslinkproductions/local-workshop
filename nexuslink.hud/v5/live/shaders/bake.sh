#!/usr/bin/env bash
# Rebake knot.vert.qsb and knot.frag.qsb (flags from KNOT-SPEC).
set -euo pipefail
cd "$(dirname "$0")"
Q=${QSB:-/usr/lib/qt6/bin/qsb}
for s in vert frag; do
  "$Q" --glsl "100 es,120,150,300 es,330" --hlsl 50 --msl 12 -o knot.$s.qsb knot.$s
done
