#!/usr/bin/env bash
# Linux deck gates. Wraps the deck gate scripts WITHOUT editing them and
# prints one line per gate:
#   GATE <name> PASS|FAIL|SKIP exit=<n> <note>
# Exit 0 when no gate FAILs (a SKIP is printed, never counted as a pass),
# 1 when at least one gate FAILs. Re-runnable: each run rewrites its logs.
#
#   tools/linux/run-gates.sh [artifact-dir]
#     default artifact dir: ${TMPDIR:-/tmp}/hud-linux-gates
#     writes logs/<gate>.log, summary.tsv, qmllint-delta.tsv and render/ there
#
# Environment (optional):
#   QT_BIN_DIR    dir holding qml, qmllint, qmltestrunner and qsb (default: first
#                 of /usr/lib/qt6/bin, /usr/lib64/qt6/bin, /usr/bin that has qml)
#   GATE_TIMEOUT  seconds per gate, default and maximum 240
#   V5_RHI        RHI backend for render gates (default opengl)
#   KNOT_REF      s2 reference still for knot-iou (default: the comp-r1 path
#                 under $HOME/NEXUS_AI_CENTER)
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
rm -rf "$ART/logs" "$ART/base" "$ART/w7" "$ART/tools-tests" "$ART/render" "$ART/imports"
mkdir -p "$ART/logs" "$ART/render" || exit 3
SUMMARY=$ART/summary.tsv
: >"$SUMMARY"

# Our sips shim goes first, so deck-layout.py's `sips -s format bmp` resolves to it.
export PATH="$TOOLS_LINUX/shims:$PATH"
# Qt prints otherwise silent qml output (qml, qmltestrunner) when these are set.
export QT_FORCE_STDERR_LOGGING=1 QT_ASSUME_STDERR_HAS_CONSOLE=1

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

# Module mapping as tools/linux/deck-shot.sh builds it: NexusHud/V5 -> kit,
# NexusHud/fonts -> fonts. Used by the qmltestrunner suites.
IMPORTS=$ART/imports
mkdir -p "$IMPORTS/NexusHud" || exit 3
ln -sfn "$V5/kit" "$IMPORTS/NexusHud/V5"
ln -sfn "$V5/fonts" "$IMPORTS/NexusHud/fonts"

# Isolated Qt environment, as the Linux render notes require: no Wayland,
# no Hyprland, offscreen platform, private XDG_RUNTIME_DIR. No X display.
iso() {
    env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY \
        XDG_RUNTIME_DIR="$PRIV" QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=none \
        QSG_RHI_BACKEND="${V5_RHI:-opengl}" PATH="${QT_BIN_DIR:+$QT_BIN_DIR:}$PATH" \
        "$@"
}

# GL variant: same as tools/linux/deck-shot.sh (DISPLAY=:0, offscreen, opengl).
isogl() {
    env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        DISPLAY=":0" XDG_RUNTIME_DIR="$PRIV" QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=none \
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

# rungl NAME CMD...: as run, with the GL environment.
rungl() {
    LOG=$ART/logs/$1.log
    shift
    isogl timeout --kill-after=10 "$TMO" nice -n 19 ionice -c3 "$@" >"$LOG" 2>&1
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
git -C "$REPO" archive 818c541 nexuslink.hud/v5 | tar -x -C "$ART/base" || exit 3
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

# Per-file warning delta (worktree minus base), printed for the QML owners.
# qml-lint prints "<path> <n> warning(s)" per file; paths are cut to the
# part after nexuslink.hud/v5/ so both sides join on the same key.
perfile() {
    grep -E ' [0-9]+ warning' "$1" | grep 'nexuslink.hud/v5/' \
        | sed -E 's#^.*nexuslink\.hud/v5/##; s#^(.*) ([0-9]+) warning.*$#\1 \2#' | sort
}
perfile "$BASE_LOG" >"$ART/qmllint-base.tsv"
perfile "$WT_LOG" >"$ART/qmllint-wt.tsv"
awk 'NR==FNR { b[$1]=$2; next } { w[$1]=$2 }
     END { for (f in w) keys[f]=1; for (f in b) keys[f]=1;
           for (f in keys) { bb=(f in b)?b[f]:0; ww=(f in w)?w[f]:0;
                             printf "%s\t%d\t%d\t%+d\n", f, bb, ww, ww-bb } }' \
    "$ART/qmllint-base.tsv" "$ART/qmllint-wt.tsv" | sort >"$ART/qmllint-delta.tsv"
awk -F'\t' '$4 != 0' "$ART/qmllint-delta.tsv" >"$ART/qmllint-delta-nonzero.tsv"
echo "QMLLINT-DELTA file	base	worktree	delta (nonzero rows; full table in $ART/qmllint-delta.tsv)"
cat "$ART/qmllint-delta-nonzero.tsv"

# ---- 2. Quickshell import rule: only DeckMain.qml may import Quickshell.
LOG=$ART/logs/quickshell-import.log
( cd "$REPO" && grep -rn "import Quickshell" nexuslink.hud/v5 ) >"$LOG" 2>&1
hits=$(cd "$REPO" && grep -rl "import Quickshell" nexuslink.hud/v5 2>/dev/null | sort | tr '\n' ' ')
if [ "$hits" = "nexuslink.hud/v5/DeckMain.qml " ]; then
    line quickshell-import PASS 0 "only nexuslink.hud/v5/DeckMain.qml imports Quickshell"
else
    line quickshell-import FAIL 1 "importers: ${hits:-none}"
fi

# ---- 3. deck-layout: the rest still rendered on the GPU path to a PNG, then
# measured. sips is the Linux shim (tools/linux/shims/sips, PIL round trip).
LOG=$ART/logs/deck-layout-render.log
RENDER=$ART/render/i1-deck-rest.png
rungl deck-layout-render "$TOOLS_LINUX/deck-shot.sh" "$V5/stills/i1-deck-rest.qml" "$RENDER"
if [ "$RC" -ne 0 ] || [ ! -s "$RENDER" ]; then
    line deck-layout-render FAIL "$RC" "rc=$RC: $(tail -n 1 "$LOG" | tr -d '\r')"
else
    run deck-layout python3 "$V5/tools/deck-layout.py" "$RENDER"
    judge deck-layout
fi

# ---- 4. deck-audit: QML text probe through the qml binary (GL env, as deck-shot).
LOG=$ART/logs/deck-audit.log
rungl deck-audit env QML_QT_BIN="$QT_BIN_DIR/qml" python3 "$V5/tools/deck-audit.py" "$V5/tests/i1/audit-rest.qml"
judge deck-audit

# ---- 5. deck-trace: expand and idle motion probes through the qml binary.
rungl deck-trace env QML_QT_BIN="$QT_BIN_DIR/qml" python3 "$V5/tools/deck-trace.py"
judge deck-trace

# ---- 6. knot-iou: the s2 knot trace (PIL, no render). KNOT_REF overrides the
# Mac-only default reference path.
KREF=${KNOT_REF:-$HOME/NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/comp-r1/s2/s2-rest.png}
if [ ! -f "$KREF" ]; then
    LOG=$ART/logs/knot-iou.log
    printf 'knot-iou not run: reference still missing: %s\n' "$KREF" >"$LOG"
    line knot-iou SKIP 3 "LINUX-ENV: reference s2-rest.png not found at $KREF (set KNOT_REF)"
else
    run knot-iou env KNOT_REF="$KREF" python3 "$REPO/tools/knot-iou.py" trace
    judge knot-iou
fi

# ---- 7. w7 proofs. run.sh has no assertions of its own: PASS only when all
# 11 PNGs and the traces are written and no frame is flat (distinct < 32).
HARNESS=${QML_SHOT_HARNESS:-$TOOLS_LINUX/.build/qml-shot-harness}
if [ -x "$HARNESS" ]; then export QML_SHOT_HARNESS=$HARNESS; fi
W7=$ART/w7
mkdir -p "$W7"
rungl w7 env QT_BIN="$QT_BIN_DIR" bash "$V5/tests/w7/run.sh" "$W7"
pngs=$(find "$W7" -maxdepth 1 -name '*.png' | wc -l)
flat=$(sed -n 's/.*distinct=\([0-9]*\).*/\1/p' "$LOG" | awk '$1 < 32' | wc -l)
if [ "$RC" -eq 0 ] && [ "$pngs" -ge 11 ] && [ "$flat" -eq 0 ]; then
    line w7 PASS 0 "run.sh exit 0; $pngs PNG written; traces in $W7"
else
    line w7 FAIL "$RC" "rc=$RC; $pngs/11 PNG written; $flat flat frame(s); last: $(tail -n 1 "$LOG" | tr -d '\r')"
fi

# ---- 8. tools/tests/run-tests.sh: qsb, qmllint, offscreen render chain.
# EXPECT_GFX: run-tests.sh expects the Mac graphics API (metal); on Linux the RHI is opengl.
rungl tools-tests env EXPECT_GFX="${V5_RHI:-opengl}" bash "$REPO/tools/tests/run-tests.sh" "$ART/tools-tests"
judge tools-tests

# ---- 9. qmltestrunner suites (offscreen, isolated, no GL needed).
QTR=${QT_BIN_DIR:+$QT_BIN_DIR/}qmltestrunner
run qmltest-find "$QTR" -input "$V5/tests/find/tst_find.qml" -import "$IMPORTS"
judge qmltest-find
run qmltest-media "$QTR" -input "$V5/tests/media/tst_media.qml" -import "$IMPORTS"
judge qmltest-media
run qmltest-quick env QMLTESTRUNNER="$QTR" bash "$V5/tests/quick/run.sh"
judge qmltest-quick
run qmltest-stale env QMLTESTRUNNER="$QTR" bash "$V5/tests/stale/run.sh"
judge qmltest-stale
# tests/actions does not exist; the action table suite is tests/quick/tst_actions.qml.
if [ -d "$V5/tests/actions" ]; then
    run qmltest-actions "$QTR" -input "$V5/tests/actions" -import "$IMPORTS"
else
    run qmltest-actions "$QTR" -input "$V5/tests/quick/tst_actions.qml" -import "$IMPORTS"
fi
judge qmltest-actions

# ---- 10. feed self-checks: run-self-checks.sh (sessions, link, apps, metrics,
# find), then every other reader that has --self-check, one gate each.
run feeds-self-checks env PYTHON=python3 sh "$V5/feeds/run-self-checks.sh"
judge feeds-self-checks
for f in hudfix hudfix_crew hudfix_localai hudfix_maclink hudfix_network \
         hudfix_storage hudfix_system find supervisor usage recent fleet_pulse game_mode; do
    run "feed-$f" python3 "$V5/feeds/$f.py" --self-check
    judge "feed-$f"
done

echo "GATES: $PASSES PASS, $FAILS FAIL, $SKIPS SKIP (logs: $ART/logs, summary: $SUMMARY)"
[ "$FAILS" -eq 0 ]
exit $?
