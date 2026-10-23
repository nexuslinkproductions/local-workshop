#!/usr/bin/env bash
# tests/stale/run.sh - StaleMark and the DeckSurface stale readout rule, offscreen,
# through qmltestrunner. Same isolation and module mapping as tests/quick/run.sh.
#   nexuslink.hud/v5/tests/stale/run.sh
set -o pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
V5=$(cd -- "$HERE/../.." && pwd -P)
KEY=$(printf '%s' "$V5" | cksum | cut -d' ' -f1)
SCRATCH=${TMPDIR:-/tmp}
IMPORTS=${STALE_IMPORTS:-$SCRATCH/stale-imports-$KEY}
mkdir -p "$IMPORTS/NexusHud" || exit 3
ln -sfn "$V5/kit" "$IMPORTS/NexusHud/V5"
ln -sfn "$V5/fonts" "$IMPORTS/NexusHud/fonts"
RUNTIME=$(mktemp -d "$SCRATCH/stale-xdg-XXXXXX") || exit 3
chmod 700 "$RUNTIME"
QMLTEST=${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}
rc=0
env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY \
    XDG_RUNTIME_DIR="$RUNTIME" QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=none \
    QT_FORCE_STDERR_LOGGING=1 QT_ASSUME_STDERR_HAS_CONSOLE=1 \
    QML_IMPORT_PATH="$IMPORTS" QML2_IMPORT_PATH="$IMPORTS" \
    nice -n 19 ionice -c3 timeout 180 "$QMLTEST" -input "$HERE/tst_stale.qml" -import "$IMPORTS"
rc=$?
echo "EXIT tst_stale $rc"
rm -rf "$RUNTIME"
exit $rc
