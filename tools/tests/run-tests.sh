#!/usr/bin/env bash
# Self-check for the C0 toolchain: qsb -> qmllint -> offscreen render, then
# pixel assertions on the result. Exercises every tool in tools/ on the
# ShaderEffect test in this directory.
#
# Self-contained by design: a clean checkout has no compiled pack, and the test
# QML loads "shadertest.frag.qsb" relative to its own directory, so this script
# bakes the pack and installs it next to the QML (tools/.gitignore already
# ignores it) as well as keeping a copy in the output directory.
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
# Where shadertest.qml actually resolves its fragmentShader URL.
QSB_LOCAL=$TESTS_DIR/shadertest.frag.qsb
PNG_OUT=$OUT_DIR/shadertest-2560x1440.png
CONTROL_OUT=$OUT_DIR/shadertest-software-control.png
WINDOW_OUT=$OUT_DIR/windowroot-320x180.png
WARN_QML=$OUT_DIR/lint-warn.qml
SYNTAX_QML=$OUT_DIR/lint-syntax.qml
WINDOW_QML=$OUT_DIR/windowroot.qml

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
check_ge() {
    if [ "${3:-0}" -ge "$2" ]; then
        printf 'ok   %s >= %s (got %s)\n' "$1" "$2" "$3"
    else
        printf 'FAIL %s: expected >= %s, got %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
field() {
    # field <name> in the harness key=value line held in $LINE
    printf '%s\n' "$LINE" | tr ' ' '\n' | sed -n "s/^$1=//p"
}
lint_field() {
    # lint_field <name> in the qml-lint summary line held in $LINT_LINE
    printf '%s\n' "$LINT_LINE" | sed -n "s/^LINT .*$1=\([0-9]*\).*/\1/p"
}

# 1. Shader compiler. Bake into the output directory as evidence, then install
#    the pack where the QML looks for it.
step "qsb.sh: shadertest.frag -> shadertest.frag.qsb"
"$TOOLS_DIR/qsb.sh" "$TESTS_DIR/shadertest.frag" "$QSB_OUT"
qsb_rc=$?
check "qsb exit" 0 "$qsb_rc"
if [ -s "$QSB_OUT" ]; then
    printf 'ok   qsb pack bytes = %s\n' "$(wc -c <"$QSB_OUT" | tr -d ' ')"
    cp "$QSB_OUT" "$QSB_LOCAL"
    cp_rc=$?
    check "install pack next to the QML" 0 "$cp_rc"
else
    printf 'FAIL qsb pack missing: %s\n' "$QSB_OUT"
    fail=1
fi
if [ -s "$QSB_LOCAL" ]; then
    printf 'ok   pack in place for the QML = %s (%s bytes)\n' \
        "$QSB_LOCAL" "$(wc -c <"$QSB_LOCAL" | tr -d ' ')"
else
    printf 'FAIL pack not installed at %s; the render would load no shader\n' "$QSB_LOCAL"
    fail=1
fi

# 2. Linter with the stable summary line.
step "qml-lint.sh: tests directory"
"$TOOLS_DIR/qml-lint.sh" "$TESTS_DIR"
lint_rc=$?
check "qml-lint exit" 0 "$lint_rc"

# 2a. A warnings-only file must still pass the gate.
step "qml-lint.sh: warnings only (exit 0, errors=0)"
printf 'import QtQuick\nItem { color: "red" }\n' >"$WARN_QML"
LINT_LINE=$("$TOOLS_DIR/qml-lint.sh" "$WARN_QML" 2>&1)
warn_rc=$?
printf '%s\n' "$LINT_LINE"
check "warnings-only exit" 0 "$warn_rc"
check_ge "warnings-only warnings" 1 "$(lint_field warnings)"
check "warnings-only errors" 0 "$(lint_field errors)"

# 2b. A file that does not parse must fail with errors>=1.
step "qml-lint.sh: syntax error (exit 1, errors>=1)"
printf 'import QtQuick\nItem {\n  Rectangle { width: 10\n}\n' >"$SYNTAX_QML"
LINT_LINE=$("$TOOLS_DIR/qml-lint.sh" "$SYNTAX_QML" 2>&1)
syntax_rc=$?
printf '%s\n' "$LINT_LINE"
check "syntax-error exit" 1 "$syntax_rc"
check_ge "syntax-error errors" 1 "$(lint_field errors)"

# 2c. --strict still turns warnings into a failure.
step "qml-lint.sh --strict: warnings only (exit 1)"
"$TOOLS_DIR/qml-lint.sh" --strict "$WARN_QML" >/dev/null 2>&1
strict_rc=$?
check "strict exit" 1 "$strict_rc"

# 3. Offscreen render of the ShaderEffect, default 2560x1440. The distinct
#    gate inside qml-shot fails the step when the pack did not run.
step "qml-shot.sh: shadertest.qml -> shadertest-2560x1440.png"
LINE=$(QML_SHOT_MIN_DISTINCT=32 "$TOOLS_DIR/qml-shot.sh" "$TESTS_DIR/shadertest.qml" "$PNG_OUT")
shot_rc=$?
check "qml-shot exit" 0 "$shot_rc"
printf 'harness: %s\n' "$LINE"
check "image size" "2560x1440" "$(field image)"
check "render mode" "rhi" "$(field mode)"
check "graphics api" "metal" "$(field api)"
check "root kind" "item" "$(field root)"

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

# 4. A QML Window root must render its content, not a black frame. The
#    regression looked like distinct=1 with corner=#000000 and exit 0.
step "qml-shot.sh: Window root renders its content"
printf 'import QtQuick\nWindow { visible: false; width: 200; height: 100; Rectangle { anchors.fill: parent; color: "#f0a000" } }\n' >"$WINDOW_QML"
LINE=$("$TOOLS_DIR/qml-shot.sh" "$WINDOW_QML" "$WINDOW_OUT" 320 180)
window_rc=$?
check "window-root exit" 0 "$window_rc"
printf 'harness: %s\n' "$LINE"
check "window-root kind" "window" "$(field root)"
check "window-root corner color" "#f0a000" "$(field corner)"
check "window-root center color" "#f0a000" "$(field center)"

# 5. Control case: the plain window path on the offscreen platform uses the
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

# 6. The distinct gate has to reject that same flat frame on demand.
step "control: QML_SHOT_MIN_DISTINCT rejects a flat frame"
QML_SHOT_MODE=window QML_SHOT_MIN_DISTINCT=2 \
    "$TOOLS_DIR/qml-shot.sh" "$TESTS_DIR/shadertest.qml" "$CONTROL_OUT" >/dev/null 2>&1
gate_rc=$?
check "min-distinct gate exit" 1 "$gate_rc"

printf '\nartifacts in %s\n' "$OUT_DIR"
if [ "$fail" = 0 ]; then
    printf 'C0 TOOLCHAIN TESTS PASS\n'
    exit 0
fi
printf 'C0 TOOLCHAIN TESTS FAIL\n'
exit 1
