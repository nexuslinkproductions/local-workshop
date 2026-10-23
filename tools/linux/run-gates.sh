#!/usr/bin/env bash
# Linux deck gates. Wraps the deck gate scripts WITHOUT editing them and
# prints one line per gate:
#   GATE <name> PASS|FAIL|SKIP exit=<n> <note>
# Exit 0 when no gate FAILs (a SKIP is printed, never counted as a pass),
# 1 when at least one gate FAILs. Re-runnable: each run rewrites its logs.
#
#   tools/linux/run-gates.sh [artifact-dir]
#     default artifact dir: ${TMPDIR:-/tmp}/hud-linux-gates
#     writes logs/<gate>.log and summary.tsv there
#
# Environment (optional):
#   QT_BIN_DIR    dir holding qml, qmllint and qsb (default: first of
#                 /usr/lib/qt6/bin, /usr/lib64/qt6/bin, /usr/bin that has qml)
#   GATE_TIMEOUT  seconds per gate, default and maximum 240
#   V5_RHI        RHI backend for render gates (default opengl)
set -u

TOOLS_LINUX=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd -- "$TOOLS_LINUX/../.." && pwd -P)
V5=$REPO/nexuslink.hud/v5
ART=${1:-${TMPDIR:-/tmp}/hud-linux-gates}
TMO=${GATE_TIMEOUT:-240}
case $TMO in ''|*[!0-9]*) TMO=240 ;; esac
[ "$TMO" -gt 240 ] && TMO=240

mkdir -p "$ART" || exit 3
ART=$(cd -- "$ART" && pwd -P)
rm -rf "$ART/logs" "$ART/base" "$ART/w7" "$ART/tools-tests"
mkdir -p "$ART/logs" || exit 3
SUMMARY=$ART/summary.tsv
: >"$SUMMARY"

# Private runtime dir. Nothing run here may reach a live Wayland session.
PRIV=$(mktemp -d "${TMPDIR:-/tmp}/gates-xdg.XXXXXX") || exit 3
chmod 700 "$PRIV"
trap 'rm -rf "$PRIV"' EXIT

QT_BIN_DIR=${QT_BIN_DIR:-}
if [ -z "$QT_BIN_DIR" ]; then
    for d in /usr/lib/qt6/bin /usr/lib64/qt6/bin /usr/bin; do
        if [ -x "$d/qml" ] && [ -x "$d/qmllint" ]; then
            QT_BIN_DIR=$d
            break
        fi
    done
fi

# Isolated Qt environment, as the Linux render notes require: no Wayland,
# no Hyprland, no X display, offscreen platform, private XDG_RUNTIME_DIR.
iso() {
    env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY \
        XDG_RUNTIME_DIR="$PRIV" QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=none \
        QSG_RHI_BACKEND="${V5_RHI:-opengl}" PATH="${QT_BIN_DIR:+$QT_BIN_DIR:}$PATH" \
        "$@"
}

# run NAME CMD...: run CMD isolated, at nice 19 / idle IO, bounded by the
# gate timeout. Sets LOG (the gate's log) and RC (its exit status).
run() {
    LOG=$ART/logs/$1.log
    shift
    iso timeout --kill-after=10 "$TMO" nice -n 19 ionice -c3 "$@" >"$LOG" 2>&1
    RC=$?
}

# line NAME STATUS RC NOTE: one GATE line plus one summary.tsv row.
PASSES=0
FAILS=0
SKIPS=0
line() {
    local note=${4//$'\t'/ }
    note=${note//$'\n'/ }
    printf 'GATE %s %s exit=%s %s\n' "$1" "$2" "$3" "$note"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$note" "${LOG:-none}" >>"$SUMMARY"
    case $2 in
        PASS) PASSES=$((PASSES + 1)) ;;
        FAIL) FAILS=$((FAILS + 1)) ;;
        *) SKIPS=$((SKIPS + 1)) ;;
    esac
}

# judge NAME: PASS on exit 0, else FAIL; the note is the log's last line.
judge() {
    local last
    last=$(tail -n 1 "$LOG" 2>/dev/null | tr -d '\r')
    if [ "$RC" -eq 0 ]; then
        line "$1" PASS 0 "exit 0: $last"
    else
        line "$1" FAIL "$RC" "rc=$RC: $last"
    fi
}

field() { printf '%s\n' "$1" | sed -n "s/.*$2=\([0-9]*\).*/\1/p"; }

# ---- 1. qmllint parity: worktree v5 QML against a base snapshot of HEAD.
mkdir -p "$ART/base" || exit 3
git -C "$REPO" archive HEAD nexuslink.hud/v5 | tar -x -C "$ART/base" || exit 3
mapfile -t WT_QML < <(find "$V5" -name '*.qml' | sort)
mapfile -t BASE_QML < <(find "$ART/base/nexuslink.hud/v5" -name '*.qml' | sort)
run qmllint-worktree "$REPO/tools/qml-lint.sh" "${WT_QML[@]}"
WT_RC=$RC
WT_LOG=$LOG
run qmllint-base "$REPO/tools/qml-lint.sh" "${BASE_QML[@]}"
BASE_RC=$RC
BASE_LOG=$LOG
wt_sum=$(grep '^LINT ' "$WT_LOG" | tail -n 1)
base_sum=$(grep '^LINT ' "$BASE_LOG" | tail -n 1)
LOG=$WT_LOG
if [ -z "$wt_sum" ] || [ -z "$base_sum" ]; then
    line qmllint-parity FAIL 1 "no LINT summary (worktree rc=$WT_RC, base rc=$BASE_RC)"
else
    wt_w=$(field "$wt_sum" warnings); wt_e=$(field "$wt_sum" errors)
    base_w=$(field "$base_sum" warnings); base_e=$(field "$base_sum" errors)
    wt_t=$((wt_w + wt_e)); base_t=$((base_w + base_e))
    if [ "$wt_t" -le "$base_t" ]; then rc=0; st=PASS; else rc=1; st=FAIL; fi
    line qmllint-parity "$st" "$rc" "worktree warnings=$wt_w errors=$wt_e (total $wt_t) vs base warnings=$base_w errors=$base_e (total $base_t); qml-lint rc wt=$WT_RC base=$BASE_RC"
fi

# ---- 2. Quickshell import rule: only DeckMain.qml may import Quickshell.
LOG=$ART/logs/quickshell-import.log
( cd "$REPO" && grep -rn "import Quickshell" nexuslink.hud/v5 ) >"$LOG" 2>&1
hits=$(cd "$REPO" && grep -rl "import Quickshell" nexuslink.hud/v5 2>/dev/null | sort | tr '\n' ' ')
if [ "$hits" = "nexuslink.hud/v5/DeckMain.qml " ]; then
    line quickshell-import PASS 0 "only nexuslink.hud/v5/DeckMain.qml imports Quickshell"
else
    line quickshell-import FAIL 1 "importers: ${hits:-none}"
fi

# ---- 3. deck-layout: needs macOS sips and a PNG still.
LOG=$ART/logs/deck-layout.log
if command -v sips >/dev/null 2>&1; then
    run deck-layout python3 "$V5/tools/deck-layout.py" "$V5/stills/i1-deck-rest.png"
    judge deck-layout
else
    printf 'deck-layout not run: sips is macOS-only; stills/ holds i1-deck-rest.jpg, no PNG\n' >"$LOG"
    line deck-layout SKIP 3 "LINUX-ENV: needs macOS sips (absent) and a PNG still; stills/ has only i1-deck-rest.jpg"
fi

# ---- 4. deck-audit: QML text probe through the qml binary.
run deck-audit env QML_QT_BIN="$QT_BIN_DIR/qml" python3 "$V5/tools/deck-audit.py" "$V5/tests/i1/audit-rest.qml"
judge deck-audit

# ---- 5. deck-trace: expand and idle motion probes through the qml binary.
run deck-trace env QML_QT_BIN="$QT_BIN_DIR/qml" python3 "$V5/tools/deck-trace.py"
judge deck-trace

# ---- 6. knot-iou: the s2 knot trace (pure Python, no render).
run knot-iou python3 "$REPO/tools/knot-iou.py" trace
if [ "$RC" -ne 0 ] && grep -q 'FileNotFoundError.*/Users/' "$LOG"; then
    line knot-iou SKIP "$RC" "LINUX-ENV: reference s2-rest.png is at a macOS-only absolute path outside the repo; trace mode cannot run here"
else
    judge knot-iou
fi

# ---- 7. w7 proofs. run.sh has no assertions of its own: PASS only when all
# 11 PNGs and the traces are written and no frame is flat (distinct < 32).
HARNESS=${QML_SHOT_HARNESS:-$TOOLS_LINUX/.build/qml-shot-harness}
if [ -x "$HARNESS" ]; then export QML_SHOT_HARNESS=$HARNESS; fi
W7=$ART/w7
mkdir -p "$W7"
run w7 env QT_BIN="$QT_BIN_DIR" bash "$V5/tests/w7/run.sh" "$W7"
pngs=$(find "$W7" -maxdepth 1 -name '*.png' | wc -l)
flat=$(sed -n 's/.*distinct=\([0-9]*\).*/\1/p' "$LOG" | awk '$1 < 32' | wc -l)
if [ "$RC" -eq 0 ] && [ "$pngs" -ge 11 ] && [ "$flat" -eq 0 ]; then
    line w7 PASS 0 "run.sh exit 0; $pngs PNG written; traces in $W7"
else
    line w7 FAIL "$RC" "rc=$RC; $pngs/11 PNG written; $flat flat frame(s); last: $(tail -n 1 "$LOG" | tr -d '\r')"
fi

# ---- 8. tools/tests/run-tests.sh: qsb, qmllint, offscreen render chain.
run tools-tests bash "$REPO/tools/tests/run-tests.sh" "$ART/tools-tests"
judge tools-tests

# ---- 9. feeds self-checks (Python readers, no render).
run feeds-self-checks env PYTHON=python3 sh "$V5/feeds/run-self-checks.sh"
judge feeds-self-checks

echo "GATES: $PASSES PASS, $FAILS FAIL, $SKIPS SKIP (logs: $ART/logs, summary: $SUMMARY)"
[ "$FAILS" -eq 0 ]
exit $?
