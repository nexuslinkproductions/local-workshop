#!/usr/bin/env bash
# tests/quick/run.sh - quick-action tests, offscreen, through qmltestrunner.
#   tests/quick/run.sh
# Module mapping is the one tools/linux/deck-shot.sh builds:
#   <imports>/NexusHud/V5 -> nexuslink.hud/v5/kit, <imports>/NexusHud/fonts -> v5/fonts.
# The environment is isolated from any live Wayland or X session.
set -o pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
V5=$(cd -- "$HERE/../.." && pwd -P)
KEY=$(printf '%s' "$V5" | cksum | cut -d' ' -f1)
SCRATCH=${TMPDIR:-/tmp}
IMPORTS=${QUICK_IMPORTS:-$SCRATCH/quick-imports-$KEY}
mkdir -p "$IMPORTS/NexusHud" || exit 3
ln -sfn "$V5/kit" "$IMPORTS/NexusHud/V5"
ln -sfn "$V5/fonts" "$IMPORTS/NexusHud/fonts"
RUNTIME=$(mktemp -d "$SCRATCH/quick-xdg-XXXXXX") || exit 3
chmod 700 "$RUNTIME"
QMLTEST=${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}
rc=0
for t in tst_quick tst_actions; do
    env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY \
        XDG_RUNTIME_DIR="$RUNTIME" QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=none \
        QML_IMPORT_PATH="$IMPORTS" QML2_IMPORT_PATH="$IMPORTS" \
        nice -n 19 ionice -c3 timeout 180 "$QMLTEST" -input "$HERE/$t.qml" -import "$IMPORTS"
    r=$?
    echo "EXIT $t $r"
    [ "$r" -eq 0 ] || rc=1
done
rm -rf "$RUNTIME"
exit $rc
