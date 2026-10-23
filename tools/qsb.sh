#!/usr/bin/env bash
# Compile one Qt shader to a .qsb shader pack for Qt Quick ShaderEffect.
#
#   tools/qsb.sh <in.frag|in.vert|...> <out.qsb> [--glsl]
#
# The stage comes from the file extension (.vert, .frag, .comp, .geom, .tesc,
# .tese), which is qsb's own rule. By default the full Qt 6 target set is
# baked: GLSL 100 es, 120, 150 plus HLSL 5.0 plus MSL 1.2 (qsb --qt6), so the
# same pack renders on Linux/GL, Windows and Metal.
#
#   --glsl    GLSL targets only (smaller pack, Linux verification path)
#
# Extra arguments after `--` go straight to qsb, e.g.
#   tools/qsb.sh x.frag x.qsb -- --define FOO=1
#   tools/qsb.sh x.vert x.qsb -- --batchable
#
# Exit: 0 pack written, 1 qsb failed, 3 toolchain problem, 64 usage.

set -o pipefail

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/qt-env.sh
. "$TOOLS_DIR/lib/qt-env.sh"

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

glsl_only=0
extra=()
positional=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --glsl) glsl_only=1; shift ;;
        --) shift; while [ $# -gt 0 ]; do extra[${#extra[@]}]="$1"; shift; done ;;
        -*) echo "qsb: unknown option: $1 (pass qsb flags after --)" >&2; exit 64 ;;
        *) positional[${#positional[@]}]="$1"; shift ;;
    esac
done

if [ ${#positional[@]} -ne 2 ]; then
    usage >&2
    exit 64
fi

src=${positional[0]}
out=${positional[1]}
if [ ! -f "$src" ]; then
    echo "qsb: no such file: $src" >&2
    exit 64
fi
mkdir -p -- "$(dirname -- "$out")" || exit 3

qsb=$(hud_find_qt_tool qsb qsb6) || {
    echo "qsb: shader baker not found (set QML_QT_PREFIX or QT_PREFIX)" >&2
    exit 3
}

if [ "$glsl_only" = 1 ]; then
    targets=(--glsl "100 es,120,150")
else
    targets=(--qt6)
fi

"$qsb" "${targets[@]}" "${extra[@]}" -o "$out" "$src"
rc=$?
if [ $rc -ne 0 ]; then
    echo "qsb: failed (exit $rc) for $src" >&2
    exit 1
fi
if [ ! -s "$out" ]; then
    echo "qsb: $out is missing or empty" >&2
    exit 1
fi

if [ "$glsl_only" = 1 ]; then
    target_label="glsl:100es,120,150"
else
    target_label="glsl:100es,120,150+hlsl:50+msl:12"
fi
printf 'QSB in=%s out=%s bytes=%s qt=%s targets=%s\n' \
    "$src" "$out" "$(wc -c <"$out" | tr -d ' ')" \
    "$(hud_qt_version 2>/dev/null || echo unknown)" "$target_label"
