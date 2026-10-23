#!/usr/bin/env bash
# deckmain-shell.sh - run the DeckMain.qml test copy in a private offscreen shell.
#
#   tools/linux/deckmain-shell.sh [--scenario FILE.qml] [--seconds N] [--stub-log FILE]
#
# 1. gen_testshell.py builds a mirror of nexuslink.hud/v5 under $TMPDIR, with a
#    test copy of DeckMain.qml made from the CURRENT file.
# 2. quickshell runs that mirror with a fully isolated environment (README.md),
#    the stub bin dir first on PATH, and NEXUSLINK_HUD_V5=1.
# 3. Output: only SCENARIO, WARN, ERROR, RangeError, TypeError, ReferenceError
#    and "Binding loop" lines. The raw log is $TMPDIR/deckmain-shell-<key>.last.log.
#
# Exit: 0 clean. 1 when an error line appears, a scenario did not quit within
# --seconds, quickshell crashed, or a process was left behind (census).
# 2 bad usage. 3 generator failed.
set -o pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -- "$HERE/../.." && pwd -P)
TOOLDIR=$HERE/deckmain-shell
GEN=$TOOLDIR/gen_testshell.py
STUBS=$TOOLDIR/stubs
SCEN=$TOOLDIR/scenarios

usage() {
    echo "usage: deckmain-shell.sh [--scenario FILE.qml] [--seconds N] [--stub-log FILE]" >&2
    exit 2
}

SCENARIO=""
SECS=20
STUB_LOG=""
while [ $# -gt 0 ]; do
    case $1 in
        --scenario) [ $# -ge 2 ] || usage; SCENARIO=$2; shift 2 ;;
        --seconds)  [ $# -ge 2 ] || usage; SECS=$2; shift 2 ;;
        --stub-log) [ $# -ge 2 ] || usage; STUB_LOG=$2; shift 2 ;;
        -h|--help)  usage ;;
        *)          usage ;;
    esac
done
case $SECS in ''|*[!0-9]*) usage ;; esac

if [ -n "$SCENARIO" ]; then
    if [ -f "$SCENARIO" ]; then :
    elif [ -f "$SCEN/$SCENARIO" ]; then SCENARIO=$SCEN/$SCENARIO
    elif [ -f "$SCEN/$SCENARIO.qml" ]; then SCENARIO=$SCEN/$SCENARIO.qml
    else echo "ERROR no such scenario: $SCENARIO"; exit 2
    fi
    SCENARIO=$(cd -- "$(dirname -- "$SCENARIO")" && pwd -P)/$(basename -- "$SCENARIO")
fi

BASE=${TMPDIR:-/tmp}
KEY=$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)
MIRROR=$BASE/deckmain-shell-$KEY
LAST_LOG=$BASE/deckmain-shell-$KEY.last.log
[ -n "$STUB_LOG" ] || STUB_LOG=$BASE/deckmain-shell-$KEY.stub.log
PRIV=$(mktemp -d "$BASE/dms-run.XXXXXX") || { echo "ERROR cannot create the private run dir"; exit 3; }
chmod 700 "$PRIV"
mkdir -p "$PRIV/bin" "$PRIV/cache" "$PRIV/state"
: > "$STUB_LOG"
NERR=0

cleanup() {
    rm -rf -- "$PRIV"
}
trap cleanup EXIT

# Census: every process whose command line names this run's mirror.
census() {
    ps -eo pid,args | grep -F -- "$MIRROR" | grep -v grep
}

# 1. Stub bin dir: each command name is a symlink to stubs/_stub.
link_stub() { ln -sfn "$STUBS/_stub" "$PRIV/bin/$1"; }
for n in xdg-open yuri playerctl ssh; do link_stub "$n"; done
while IFS= read -r n; do
    case $n in ''|'#'*) continue ;; esac
    link_stub "$n"
done < "$STUBS/NAMES"
if [ -d /usr/share/omarchy/bin ]; then
    for f in /usr/share/omarchy/bin/omarchy-*; do
        [ -e "$f" ] || continue
        link_stub "$(basename -- "$f")"
    done
fi

# 2. Test copy and mirror, from the current DeckMain.qml.
GEN_ERR=$PRIV/gen.err
python3 "$GEN" --worktree "$ROOT" --mirror "$MIRROR" --width 2560 --height 1440 \
    >"$PRIV/gen.out" 2>"$GEN_ERR"
GEN_RC=$?
grep -E 'WARN|ERROR' "$GEN_ERR"
if [ "$GEN_RC" -ne 0 ]; then
    echo "ERROR generator failed (rc=$GEN_RC)"
    exit 3
fi

# 3. Run quickshell. Own process group (set -m) so the whole tree can be killed.
set -m
env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY \
    XDG_RUNTIME_DIR="$PRIV" XDG_CACHE_HOME="$PRIV/cache" XDG_STATE_HOME="$PRIV/state" \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=none \
    NEXUSLINK_HUD_V5=1 DECKMAIN_STUB_LOG="$STUB_LOG" DECKMAIN_SCENARIO="$SCENARIO" \
    PATH="$PRIV/bin:$PATH" \
    QML_IMPORT_PATH="$MIRROR/imports" QML2_IMPORT_PATH="$MIRROR/imports" \
    nice -n 19 ionice -c3 timeout -k 3 -s TERM "$SECS" \
    quickshell -n -p "$MIRROR" >"$LAST_LOG" 2>&1 </dev/null &
QPID=$!
set +m
wait "$QPID"
RC=$?

# 4. Kill the group (quickshell and any Process children), then census.
kill -TERM -- "-$QPID" 2>/dev/null
sleep 1
kill -KILL -- "-$QPID" 2>/dev/null

# 5. Output: the lines that matter.
grep -E 'SCENARIO|WARN|ERROR|RangeError|TypeError|ReferenceError|Binding loop' "$LAST_LOG" \
    | grep -v "Module path contains invalid characters" \
    | sed -E 's/^.*(SCENARIO )/\1/'
NERR=$(grep -E 'ERROR|RangeError|TypeError|ReferenceError|Binding loop' "$LAST_LOG" | grep -vc 'SCENARIO')
NERR=${NERR:-0}
if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then
    if [ -n "$SCENARIO" ]; then
        echo "ERROR scenario did not quit within ${SECS}s (timeout killed quickshell)"
        NERR=$((NERR + 1))
    fi
elif [ "$RC" -ne 0 ]; then
    echo "ERROR quickshell exited with rc=$RC"
    NERR=$((NERR + 1))
fi

LEFT=$(census | wc -l)
if [ "$LEFT" -gt 0 ]; then
    echo "ERROR census: $LEFT process(es) still running from $MIRROR, killing"
    NERR=$((NERR + 1))
    census | cut -c1-200 | sed 's/^/census: /' >&2
    census | awk '{print $1}' | xargs -r kill -KILL
    sleep 0.5
fi
LEFT2=$(census | wc -l)

echo "deckmain-shell: rc=$RC errors=$NERR census_left=$LEFT2 stub_log=$STUB_LOG raw_log=$LAST_LOG" >&2
[ "$NERR" -eq 0 ] && [ "$LEFT2" -eq 0 ]
