#!/usr/bin/env bash
# Build swarm-bench once, then time every option at 540 and 1080.
#
#   spike/timing/run-bench.sh [frames]
#
# One process per case so a runaway shader cannot poison the next measurement.
# Prints JSON lines; redirect to spike/timing/results.json.

set -o pipefail

frames=${1:-300}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$HERE/../../../.." && pwd -P)
PREFIX=${QML_QT_PREFIX:-${QT_PREFIX:-/opt/homebrew/opt/qt}}
SPIKE=$ROOT/nexuslink.hud/v5/spike
BUILD=$HERE/.build

if [ ! -x "$BUILD/swarm-bench" ] || [ "$HERE/swarm-bench.cpp" -nt "$BUILD/swarm-bench" ]; then
    cmake -S "$HERE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_PREFIX_PATH="$PREFIX" >&2 || exit 3
    cmake --build "$BUILD" --parallel 4 >&2 || exit 3
fi

for size in 540 1080; do
    for opt in a b c; do
        name="${opt}-knot-${size}"
        line=$(QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
               "$BUILD/swarm-bench" "$SPIKE/options/${opt}_knot.qml" "$size" "$size" "$frames") || {
            printf '{"case":"%s","error":true}\n' "$name"
            continue
        }
        printf '{"case":"%s",%s}\n' "$name" \
            "$(printf '%s' "$line" | tr ' ' '\n' | sed -E 's/^([a-zA-Z0-9_]+)=(.*)$/"\1":"\2"/' | paste -sd, -)"
    done
done
exit 0
