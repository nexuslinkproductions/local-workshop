#!/usr/bin/env bash
# Render one QtQuick item offscreen to a PNG, at 2560x1440 by default.
#
#   tools/qml-shot.sh <file.qml> <out.png> [W H]
#
# The QML root must be an Item or a Window. An Item root is resized to W x H.
# The capture runs on QT_QPA_PLATFORM=offscreen, so no display, Xvfb or Wayland
# is needed. The grab harness (tools/harness) is compiled once per Qt version
# into tools/.build/ and reused afterwards.
#
# Environment:
#   QT_QPA_PLATFORM      default offscreen; override to try platform/display paths
#   QSG_RHI_BACKEND      metal | opengl | vulkan | null (Qt default if unset)
#   QT_QUICK_BACKEND     scenegraph adaptation; the harness sets rhi for its RHI
#                        mode if this is unset (software = no ShaderEffect)
#   QML_SHOT_MODE        auto | rhi | window (default auto: rhi, then window)
#   QML_SHOT_DELAY       ms of settle time before the grab (default 800)
#   QML_SHOT_TIMEOUT     ms extra wait for slow renders (default 15000)
#   QML_SHOT_BUILD_DIR   harness build cache (default tools/.build)
#   QML_SHOT_HARNESS     use an already built harness binary
#
# stdout is one machine-readable line:
#   qt=6.12.0 platform=offscreen api=metal frames=2 image=2560x1440 distinct=N ...
#
# Exit: 0 shot written, 1 grab/save failed, 2 QML load failed, 3 toolchain
# problem, 64 usage.

set -o pipefail

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/qt-env.sh
. "$TOOLS_DIR/lib/qt-env.sh"

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
if [ $# -lt 2 ]; then
    usage >&2
    exit 64
fi

src=$1
out=$2
width=${3:-2560}
height=${4:-1440}

if [ ! -f "$src" ]; then
    echo "qml-shot: no such file: $src" >&2
    exit 64
fi
case "$width$height" in
    *[!0-9]*) echo "qml-shot: width and height must be positive integers" >&2; exit 64 ;;
esac
if [ "$width" -le 0 ] || [ "$height" -le 0 ]; then
    echo "qml-shot: width and height must be positive integers" >&2
    exit 64
fi

mkdir -p -- "$(dirname -- "$out")" || exit 3
src=$(cd -- "$(dirname -- "$src")" && pwd -P)/$(basename -- "$src")
out=$(cd -- "$(dirname -- "$out")" && pwd -P)/$(basename -- "$out")

harness=${QML_SHOT_HARNESS:-}
if [ -z "$harness" ]; then
    prefix=$(hud_qt_prefix) || {
        echo "qml-shot: no Qt 6 found (set QML_QT_PREFIX or QT_PREFIX)" >&2
        exit 3
    }
    version=$(hud_qt_version "$prefix") || {
        echo "qml-shot: cannot read the Qt version under $prefix" >&2
        exit 3
    }
    build_root=${QML_SHOT_BUILD_DIR:-$TOOLS_DIR/.build}
    build_dir=$build_root/harness-$version
    harness=$build_dir/qml-shot-harness

    rebuild=0
    [ -x "$harness" ] || rebuild=1
    if [ -f "$TOOLS_DIR/harness/main.cpp" ] && [ "$TOOLS_DIR/harness/main.cpp" -nt "$harness" ]; then
        rebuild=1
    fi
    if [ -f "$TOOLS_DIR/harness/CMakeLists.txt" ] && [ "$TOOLS_DIR/harness/CMakeLists.txt" -nt "$harness" ]; then
        rebuild=1
    fi
    if [ "$rebuild" = 1 ]; then
        command -v cmake >/dev/null 2>&1 || {
            echo "qml-shot: cmake is needed once to build the grab harness" >&2
            exit 3
        }
        echo "qml-shot: building grab harness for Qt $version (once) ..." >&2
        cmake -S "$TOOLS_DIR/harness" -B "$build_dir" \
              -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$prefix" >&2 || exit 3
        cmake --build "$build_dir" --parallel 4 >&2 || exit 3
    fi
fi
if [ ! -x "$harness" ]; then
    echo "qml-shot: harness is not executable: $harness" >&2
    exit 3
fi

exec env QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}" \
    "$harness" "$src" "$out" "$width" "$height"
