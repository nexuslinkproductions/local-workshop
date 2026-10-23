#!/usr/bin/env bash
# Render the composed v5 deck offscreen at 2560x1440.
#
#   v5/tools/deck-shot.sh <root.qml> <out.png>
#
# This is the created acceptance path for I1: it makes the NexusHud.V5 module
# import path (kit/ is the module root, so the path has to hold a NexusHud/V5
# symlink to it) and then calls tools/qml-shot.sh, which is the project's one
# offscreen renderer (QQuickRenderControl + RHI readback, because the plain
# offscreen window path draws ShaderEffect as a black frame on this Mac).
#
# Exit: whatever tools/qml-shot.sh returns (0 ok, 1 grab failed or too flat, 2
# QML load failed, 3 toolchain, 64 usage), plus 65 when the QML root is missing.
set -o pipefail

if [ $# -lt 2 ]; then
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 64
fi

root_qml=$1
out_png=$2

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)      # v5/tools
V5=$(cd -- "$HERE/.." && pwd -P)                                 # v5
REPO=$(cd -- "$V5/../.." && pwd -P)                              # repo root

if [ ! -f "$root_qml" ]; then
    echo "deck-shot: no such QML file: $root_qml" >&2
    exit 65
fi

imports=$(mktemp -d "${TMPDIR:-/tmp}/deck-imports.XXXXXX") || exit 3
trap 'rm -rf -- "$imports"' EXIT
mkdir -p "$imports/NexusHud" || exit 3
ln -sfn "$V5/kit" "$imports/NexusHud/V5" || exit 3
# Fonts. A component inside kit/ resolves its faces as ../fonts/Satoshi-*.ttf,
# which is v5/fonts on disk; loaded through this module symlink that URL becomes
# <imports>/NexusHud/fonts, so without this link every FontLoader in a kit
# component fails. The deck itself does not need it (DeckSurface.qml carries the
# four deck loaders, module-relative, so they land on v5/fonts either way - that
# is measured in docs/acceptance.md, section 1: linking or not changes 15 pixels
# at a channel delta of 1). This link is what makes a kit component resolve its
# own faces, so the error lines stop and a component rendered on its own is not
# composed in a fallback face.
ln -sfn "$V5/fonts" "$imports/NexusHud/fonts" || exit 3

mkdir -p -- "$(dirname -- "$out_png")" || exit 3

# QML_IMPORT_PATH is what the harness's QQmlEngine reads; QML2_IMPORT_PATH is
# kept for older Qt. MIN_DISTINCT turns a silently black frame into exit 1.
QML_IMPORT_PATH="$imports${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" \
QML2_IMPORT_PATH="$imports${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}" \
QML_SHOT_MIN_DISTINCT="${QML_SHOT_MIN_DISTINCT:-64}" \
    "$REPO/tools/qml-shot.sh" "$root_qml" "$out_png" 2560 1440
rc=$?
exit "$rc"
