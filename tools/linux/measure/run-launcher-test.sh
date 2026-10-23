#!/usr/bin/env bash
# run-launcher-test.sh - mirror symmetry test for any launcher band.
#
#   tools/linux/measure/run-launcher-test.sh
#
# Runs the QtTest case in nexuslink.hud/v5/verify/tst_launcher_symmetry.qml
# offscreen (software backend, low priority, one render at a time under the
# shared HUD lock). Exit code is qmltestrunner's: 0 = all cases pass.
#
# Environment (all optional, nothing is hard wired to one deck):
#   HUD_LAUNCHER_ADAPTER  adapter QML file the test drives through the contract
#                         (tools/linux/porting/launcher-test.md).
#                         Default: <verify>/launcher/AdapterDeckA.qml
#   HUD_LAUNCHER_IMPORT   extra QML import dir for an adapter's own imports
#                         (for example a module root holding NexusHud/V5).
#   HUD_VERIFY_DIR        verify dir to run (scratch copies, mutation checks).
#                         Default: nexuslink.hud/v5/verify of this worktree.
# Paths come from this script's own location; no absolute home path is used.
set -o pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$here/../../.." && pwd -P)
verify=${HUD_VERIFY_DIR:-$root/nexuslink.hud/v5/verify}
adapter=${HUD_LAUNCHER_ADAPTER:-$verify/launcher/AdapterDeckA.qml}
extra=${HUD_LAUNCHER_IMPORT:-}

if [ ! -f "$verify/tst_launcher_symmetry.qml" ]; then
    echo "error: no tst_launcher_symmetry.qml in $verify" >&2
    exit 2
fi
if [ ! -f "$adapter" ]; then
    echo "error: adapter not found: $adapter" >&2
    exit 2
fi

# Absolute adapter path, its directory and its type name (file base name).
adapter_dir=$(cd -- "$(dirname -- "$adapter")" && pwd -P) || exit 2
adapter_file=$adapter_dir/$(basename -- "$adapter")
adapter_type=$(basename -- "$adapter" .qml)

# Per run, outside the tree: a module HudLauncherSut whose LauncherSut type is
# the selected adapter. The test imports that module, so it never names a deck.
gen=$(mktemp -d "${TMPDIR:-/tmp}/hud-launcher-sut.XXXXXX") || exit 2
trap 'rm -rf -- "$gen"' EXIT
mkdir -p "$gen/HudLauncherSut" || exit 2
printf 'module HudLauncherSut\nLauncherSut 1.0 LauncherSut.qml\n' > "$gen/HudLauncherSut/qmldir"
printf 'import "file://%s"\n%s {\n}\n' "$adapter_dir" "$adapter_type" > "$gen/HudLauncherSut/LauncherSut.qml"

imports=(-import "$gen")
if [ -n "$extra" ]; then
    imports+=(-import "$extra")
fi

cd "$verify" || exit 2
# QML_XHR_ALLOW_FILE_READ lets the test read the real assets/apps.json over a
# file URL, so it always checks the shipped list instead of a copy.
echo "launcher-test: adapter=$adapter_file verify=$verify"
flock /tmp/hudlive-render.lock env QML_XHR_ALLOW_FILE_READ=1 \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    nice -n 19 ionice -c3 /usr/lib/qt6/bin/qmltestrunner "${imports[@]}" \
    -input tst_launcher_symmetry.qml
