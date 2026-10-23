#!/usr/bin/env bash
# deck-shot.sh <scene.qml> <out.png> [W H]   (default 2560 1440)
#
# Renders one deck B scene on Linux through the Qt RHI OpenGL path (v5-shot.sh).
# It builds the NexusHud module view the kit needs, in a per-worktree imports
# directory under $TMPDIR, so no file inside the repo is touched:
#
#   <imports>/NexusHud/V5    -> nexuslink.hud/v5/kit
#   <imports>/NexusHud/fonts -> nexuslink.hud/v5/fonts   (kit FontLoaders resolve ../fonts)
#
# Same environment knobs as v5-shot.sh (V5_ALLOW_FLAT, V5_TIMEOUT, V5_HARNESS ...).
# The render runs under flock /tmp/hudlive-render.lock, nice -n 19 and ionice -c3.
#
# Example (a still shipped with the deck):
#   tools/linux/deck-shot.sh nexuslink.hud/v5/stills/i1-deck-rest.qml /tmp/rest.png
set -o pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$HERE/../.." && pwd -P)
V5=$ROOT/nexuslink.hud/v5
KEY=$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)
IMPORTS=${V5_IMPORTS:-${TMPDIR:-/tmp}/deckb-imports-$KEY}
mkdir -p "$IMPORTS/NexusHud" || exit 3
ln -sfn "$V5/kit" "$IMPORTS/NexusHud/V5"
ln -sfn "$V5/fonts" "$IMPORTS/NexusHud/fonts"
export QML_IMPORT_PATH=$IMPORTS QML2_IMPORT_PATH=$IMPORTS
exec "$HERE/v5-shot.sh" "$@"
