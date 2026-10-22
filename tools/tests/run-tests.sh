#!/usr/bin/env bash
# Self-check for the C0 toolchain: qsb -> qmllint -> offscreen render, then
# pixel assertions on the result. Exercises every tool in tools/ on the
# ShaderEffect test in this directory.
#
#   tools/tests/run-tests.sh [output dir]     (default: $TMPDIR/hud-c0-tests)
#
# Exit 0 when all checks pass, 1 on the first failed assertion.

set -o pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TOOLS_DIR=$(cd -- "$TESTS_DIR/.." && pwd -P)
OUT_DIR=${1:-${TMPDIR:-/tmp}/hud-c0-tests}
mkdir -p "$OUT_DIR" || exit 1
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)

QSB_OUT=$OUT_DIR/shadertest.frag.qsb
PNG_OUT=$OUT_DIR/shadertest-2560x1440.png
CONTROL_OUT=$OUT_DIR/shadertest-software-control.png

fail=0
step() {
    printf '\n== %s\n' "$1"
}
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s = %s\n' "$1" "$3"
    else
        printf 'FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
field() {
    # field <name> in the harness key=value line held in $LINE
    printf '%s\n' "$LINE" | tr ' ' '\n' | sed -n "s/^$1=//p"
}

# 1. Shader compiler.
step "qsb.sh: shadertest.frag -> shadertest.frag.qsb"
"$TOOLS_DIR/qsb.sh" "$TESTS_DIR/shadertest.frag" "$QSB_OUT"
qsb_rc=$?
check "qsb exit" 0 "$qsb_rc"
if [ -s "$QSB_OUT" ]; then
    printf 'ok   qsb pack bytes = %s\n' "$(wc -c <"$QSB_OUT" | tr -d ' ')"
else
    printf 'FAIL qsb pack missing\n'
    fail=1
fi

# 2. Linter with the stable summary line.
step "qml-lint.sh: tests directory"
"$TOOLS_DIR/qml-lint.sh" "$TESTS_DIR"
lint_rc=$?
check "qml-lint exit" 0 "$lint_rc"

# 3. Offscreen render of the ShaderEffect, default 2560x1440.
step "qml-shot.sh: shadertest.qml -> shadertest-2560x1440.png"
LINE=$("$TOOLS_DIR/qml-shot.sh" "$TESTS_DIR/shadertest.qml" "$PNG_OUT")
shot_rc=$?
check "qml-shot exit" 0 "$shot_rc"
printf 'harness: %s\n' "$LINE"
check "image size" "2560x1440" "$(field image)"
check "render mode" "rhi" "$(field mode)"
check "graphics api" "metal" "$(field api)"

distinct=$(field distinct)
if [ "${distinct:-0}" -ge 32 ]; then
    printf 'ok   distinct colors >= 32 (got %s)\n' "$distinct"
else
    printf 'FAIL distinct colors: got %s, a shader that did not run is a flat image\n' "${distinct:-0}"
    fail=1
fi
center=$(field center)
corner=$(field corner)
if [ -n "$center" ] && [ "$center" != "$corner" ]; then
    printf 'ok   center %s differs from corner %s\n' "$center" "$corner"
else
    printf 'FAIL center %s equals corner %s\n' "$center" "$corner"
    fail=1
fi
if [ -s "$PNG_OUT" ]; then
    printf 'ok   png bytes = %s\n' "$(wc -c <"$PNG_OUT" | tr -d ' ')"
else
    printf 'FAIL png missing: %s\n' "$PNG_OUT"
    fail=1
fi

# 4. Control case: the plain window path on the offscreen platform uses the
#    software scenegraph backend, which does not draw ShaderEffect items. The
#    capture is a flat black frame. This is the documented reason qml-shot
#    defaults to the RHI mode.
step "control: QML_SHOT_MODE=window (software backend, shader expected missing)"
LINE=$(QML_SHOT_MODE=window "$TOOLS_DIR/qml-shot.sh" "$TESTS_DIR/shadertest.qml" "$CONTROL_OUT")
control_rc=$?
check "control exit" 0 "$control_rc"
printf 'harness: %s\n' "$LINE"
check "control render mode" "window" "$(field mode)"
check "control graphics api" "software" "$(field api)"
check "control distinct colors (flat frame)" "1" "$(field distinct)"

printf '\nartifacts in %s\n' "$OUT_DIR"
if [ "$fail" = 0 ]; then
    printf 'C0 TOOLCHAIN TESTS PASS\n'
    exit 0
fi
printf 'C0 TOOLCHAIN TESTS FAIL\n'
exit 1
