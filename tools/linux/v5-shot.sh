#!/usr/bin/env bash
# Render one QtQuick item offscreen to a PNG on Linux, GPU path (Vulkan),
# so ShaderEffect items actually draw. Replacement for tools/qml-shot.sh,
# which only works on macOS because of its metal/GL assumptions.
#
#   tools/linux/v5-shot.sh <file.qml> <out.png> [W H]     (default 2560 1440)
#
# The root must be an Item or a Window. An Item root is resized to W x H.
# No surface is ever created: QQuickRenderControl draws into a QRhi texture
# and the pixels are read back, so nothing appears on any monitor.
#
# Environment:
#   V5_ALLOW_FLAT=1     accept a flat frame (distinct colours < 32)
#   V5_GPU=intel|nvidia|amd|default   Vulkan ICD to use (default intel)
#   V5_AUDIT=1          also print the text audit JSON line (see harness)
#   V5_TIMEOUT          seconds before the render is abandoned (default 120)
#   V5_BUILD_DIR        build cache (default tools/linux/.build)
#   V5_HARNESS          use an already built harness binary
#
# Exit: 0 shot written and non-flat, 1 flat frame or grab/save failed,
#       2 QML load failed, 3 toolchain problem, 64 usage, 124 timeout.
set -o pipefail

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LINUX_DIR=$TOOLS_DIR
REPO=$TOOLS_DIR/../..

usage() { sed -n '2,/^set -o/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d'; }

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
    echo "v5-shot: no such file: $src" >&2
    exit 64
fi
case "$width$height" in
    *[!0-9]*) echo "v5-shot: width and height must be positive integers" >&2; exit 64 ;;
esac
if [ "$width" -le 0 ] || [ "$height" -le 0 ]; then
    echo "v5-shot: width and height must be positive integers" >&2
    exit 64
fi

mkdir -p -- "$(dirname -- "$out")" || exit 3
src=$(cd -- "$(dirname -- "$src")" && pwd -P)/$(basename -- "$src")
out=$(cd -- "$(dirname -- "$out")" && pwd -P)/$(basename -- "$out")

harness=${V5_HARNESS:-}
if [ -z "$harness" ]; then
    build_dir=${V5_BUILD_DIR:-$LINUX_DIR/.build}
    harness=$build_dir/qml-shot-harness
    rebuild=0
    [ -x "$harness" ] || rebuild=1
    for f in "$LINUX_DIR/harness/main.cpp" "$LINUX_DIR/harness/CMakeLists.txt"; do
        [ -f "$f" ] && [ "$f" -nt "$harness" ] && rebuild=1
    done
    if [ "$rebuild" = 1 ]; then
        command -v cmake >/dev/null 2>&1 || {
            echo "v5-shot: cmake is needed once to build the harness" >&2
            exit 3
        }
        echo "v5-shot: building harness (once) into $build_dir ..." >&2
        nice -n 19 ionice -c3 cmake -S "$LINUX_DIR/harness" -B "$build_dir" \
            -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr >&2 || exit 3
        nice -n 19 ionice -c3 cmake --build "$build_dir" >&2 || exit 3
    fi
fi
if [ ! -x "$harness" ]; then
    echo "v5-shot: harness is not executable: $harness" >&2
    exit 3
fi

# Pick the Vulkan driver before Qt starts. VK_ICD_FILENAMES is the one knob
# every Mesa and NVIDIA loader honours; Qt has no device selection of its own.
icd_dir=${VK_ICD_DIR:-/usr/share/vulkan/icd.d}
case "${V5_GPU:-intel}" in
    intel)  icd=$icd_dir/intel_icd.json ;;
    nvidia) icd=$icd_dir/nvidia_icd.json ;;
    amd)    icd=$icd_dir/radeon_icd.json ;;
    *)      icd= ;;
esac
if [ -n "$icd" ] && [ -f "$icd" ]; then
    export VK_ICD_FILENAMES=$icd
elif [ -n "${V5_GPU:-}" ] && [ "${V5_GPU}" != default ]; then
    echo "v5-shot: no Vulkan ICD for V5_GPU=$V5_GPU, using the loader default" >&2
fi

timeout_s=${V5_TIMEOUT:-120}

# Callers (and the contract's own recipe) wrap this script in
# `flock /tmp/hudlive-render.lock ...`, so taking the lock again here would
# deadlock against the parent: flock is per open file description, the parent
# never releases while it waits for us. Skip our lock when an ancestor already
# holds the same file.
ancestor_holds_lock() {
    p=$PPID
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'hudlive-render.lock'; then
            return 0
        fi
        p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    done
    return 1
}

lock_prefix=""
if ! ancestor_holds_lock; then
    lock_prefix="flock /tmp/hudlive-render.lock"
fi

# QT_QPA_PLATFORMTHEME=none: the gtk3 platform theme plugin tries to open the
# (unset) display and kills the process before Qt ever starts.
line=$(env -u WAYLAND_DISPLAY \
    DISPLAY="${DISPLAY:-:0}" \
    QT_QPA_PLATFORM=offscreen \
    QT_QPA_PLATFORMTHEME=none \
    QT_QUICK_BACKEND=rhi \
    QSG_RHI_BACKEND="${V5_RHI:-opengl}" \
    timeout "$timeout_s" \
    $lock_prefix \
    nice -n 19 ionice -c3 \
    "$harness" "$src" "$out" "$width" "$height")
rc=$?
if [ -n "$line" ]; then
    printf '%s\n' "$line"
fi
if [ "$rc" -eq 0 ] && [ -f "$out" ] && [ "${V5_NO_FLIP:-0}" != 1 ]; then
    # OpenGL readback is bottom-up: flip so the PNG is upright.
    case "$line" in
        *api=opengl*) python3 "$LINUX_DIR/flip.py" "$out" "$out" >/dev/null || true ;;
    esac
fi
if [ "$rc" -eq 124 ]; then
    echo "v5-shot: timed out after ${timeout_s}s" >&2
    exit 124
fi
if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi

field() { printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
api=$(field api)
distinct=$(field distinct)
if [ -z "$api" ] || [ -z "$distinct" ]; then
    echo "v5-shot: harness printed no api=/distinct= field" >&2
    exit 1
fi
if [ "$api" = software ]; then
    echo "v5-shot: api=software, ShaderEffect was NOT drawn (Vulkan unavailable)" >&2
    exit 1
fi
if [ "${V5_ALLOW_FLAT:-0}" != 1 ] && [ "$distinct" -lt 32 ]; then
    echo "v5-shot: distinct=$distinct below 32, the frame is flat: nothing drew" \
         "(missing or unloadable .qsb, or the shader failed)" >&2
    exit 1
fi
exit 0
