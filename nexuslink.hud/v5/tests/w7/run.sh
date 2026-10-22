#!/usr/bin/env bash
# W7 ENVIRONMENT evidence runner.
#
#   nexuslink.hud/v5/tests/w7/run.sh [output-dir]
#
# Reproduces every claim in nexuslink.hud/v5/docs/w7-motion.md from the repo
# root of this worktree:
#   - the module import path transaction (symlink into a scratch import dir)
#   - qml-lint on Clock / Focus / IdleDrift (summary line)
#   - Clock no-jitter + tabular-figure numbers (ClockProof, real Text layout)
#   - Focus spring trace (FocusProof, real component, ~60 Hz sampling)
#   - IdleDrift drift / clean-stop / restart trace (IdleProof)
#   - dim, scrim, sharp-hole and desktop-safety pixels (three flat proofs)
#   - all stills at 2560x1440
#
# Stills are PNG here; the committed copies under docs/w7-stills/ are JPEG
# (quality 82, under 1 MB each) converted with sips.
set -o pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd -- "$HERE/../../../.." && pwd -P)
OUT=${1:-"$HERE/out"}
QT_BIN=${QT_BIN:-/opt/homebrew/opt/qt/bin}
SHOT="$REPO/tools/qml-shot.sh"
LINT="$REPO/tools/qml-lint.sh"

IMPORTS=$(mktemp -d "${TMPDIR:-/tmp}/w7-imports.XXXXXX")
trap 'rm -rf "$IMPORTS"' EXIT
mkdir -p "$IMPORTS/NexusHud"
ln -sfn "$REPO/nexuslink.hud/v5/kit" "$IMPORTS/NexusHud/V5"

mkdir -p "$OUT"
export QML2_IMPORT_PATH="$IMPORTS"
export QML_IMPORT_PATH="$IMPORTS"
export QT_QPA_PLATFORM=offscreen

echo "== lint"
"$LINT" "$REPO/nexuslink.hud/v5/kit/Clock.qml" \
        "$REPO/nexuslink.hud/v5/kit/Focus.qml" \
        "$REPO/nexuslink.hud/v5/kit/IdleDrift.qml" | tail -1

echo "== clock (no jitter, tabular figures)"
"$QT_BIN/qml" "$HERE/ClockProof.qml" 2>&1 | grep -E "CLOCK|TNUM" | tee "$OUT/clock-trace.txt"
echo "exit=$?"

echo "== focus (spring trace)"
"$QT_BIN/qml" "$HERE/FocusProof.qml" >"$OUT/focus-trace.txt" 2>&1
tail -1 "$OUT/focus-trace.txt"

echo "== idle (drift, clean stop, restart)"
"$QT_BIN/qml" "$HERE/IdleProof.qml" >"$OUT/idle-trace.txt" 2>&1
grep -E "IDLE (config|stop_begin|stop_done|restart|summary)" "$OUT/idle-trace.txt"

echo "== dim / scrim / desktop pixels"
for proof in dim-proof-active dim-proof-rest dim-proof-desktop; do
    printf '%-22s ' "$proof"
    "$SHOT" "$HERE/$proof.qml" "$OUT/$proof.png" 300 200 2>/dev/null \
        | sed -n 's/.*center=\(#[0-9a-f]*\) corner=\(#[0-9a-f]*\).*/center=\1 corner=\2/p'
done

echo "== stills 2560x1440"
for still in still-clock-0111 still-clock-1848 still-clock-seconds \
             still-focus-rest still-focus-preview still-focus-active \
             still-idle-a still-idle-b; do
    "$SHOT" "$HERE/$still.qml" "$OUT/$still.png" 2560 1440 2>/dev/null \
        | sed -n "s/.*distinct=\([0-9]*\).*saved=.*/$(printf '%-22s' "$still") distinct=\1/p"
done

echo "== written to $OUT"
