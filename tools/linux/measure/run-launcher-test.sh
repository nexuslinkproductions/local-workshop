#!/usr/bin/env bash
# run-launcher-test.sh - symmetry test for the v5 launcher band.
#
#   tools/linux/measure/run-launcher-test.sh
#
# Runs the QtTest case in nexuslink.hud/v5/verify/tst_launcher_symmetry.qml
# offscreen (software backend, low priority, one render at a time under the
# shared HUD lock). Exit code is qmltestrunner's: 0 = all cases pass.
# Set HUD_VERIFY_DIR to point at another verify dir (scratch copies, mutation
# checks); it defaults to this worktree.
set -o pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
verify=${HUD_VERIFY_DIR:-$here/../../../nexuslink.hud/v5/verify}

if [ ! -f "$verify/tst_launcher_symmetry.qml" ]; then
    echo "error: no tst_launcher_symmetry.qml in $verify" >&2
    exit 2
fi

cd "$verify" || exit 2
# QML_XHR_ALLOW_FILE_READ lets the test read the real assets/apps.json over a
# file URL, so it always checks the shipped list instead of a copy.
flock /tmp/hudlive-render.lock env QML_XHR_ALLOW_FILE_READ=1 \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    nice -n 19 ionice -c3 /usr/lib/qt6/bin/qmltestrunner -input tst_launcher_symmetry.qml
