#!/usr/bin/env bash
# Load gate for the nexuslink.hud plugin.
#
#   tools/linux/load-gate.sh [path/to/nexuslink.hud] [wait_seconds=12]   offscreen run
#   tools/linux/load-gate.sh --live [wait_seconds=8]                     live journal check
#
# Offscreen mode runs the real entry (Hud.qml, which Loader-loads v4/HudV4.qml)
# in a throwaway quickshell on a COPY of the tree: QT_QPA_PLATFORM=offscreen, no
# Wayland connection, private XDG dirs, so nothing is shown and the live config
# and state dirs are not written. Limit found by measurement: without a Wayland
# session quickshell has no PanelWindow backend, and HudV4 (a PanelWindow root)
# cannot finish loading, so offscreen can FAIL on a seen error but never PASS.
# That is reported as INCONCLUSIVE. The pass gate is --live, run after install.
#
# Live mode waits, then greps the user journal for the shell's last 60 s.
# A hit means the install is broken: roll back at once (see INSTALL-1023.md).
#
# Exit: 0 PASS, 1 FAIL (error line matched, listed on stdout),
#       2 INCONCLUSIVE (offscreen only: no error seen, but HudV4 could not load),
#      64 usage.
set -u

PAT='load failed|Cannot assign|Property value|is not a type|Binding loop|TypeError|ReferenceError|module .* is not installed'

if [ "${1:-}" = "--live" ]; then
    WAIT=${2:-8}
    case "$WAIT" in *[!0-9]*|'') echo "load-gate: wait must be seconds" >&2; exit 64 ;; esac
    sleep "$WAIT"
    hits=$(journalctl --user --since '-60s' --no-pager 2>/dev/null \
        | grep -E 'omarchy-shell|quickshell|nexuslink' | grep -E -- "$PAT" || true)
    if [ -n "$hits" ]; then
        echo "load-gate --live: FAIL, error lines in the last 60 s:"
        printf '%s\n' "$hits" | head -40
        exit 1
    fi
    echo "load-gate --live: PASS, no error line in the last 60 s"
    exit 0
fi

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
SRC=${1:-$REPO/nexuslink.hud}
WAIT=${2:-12}
case "$WAIT" in *[!0-9]*|'') echo "load-gate: wait must be a number of seconds" >&2; exit 64 ;; esac
[ -f "$SRC/Hud.qml" ] || { echo "load-gate: no Hud.qml in $SRC" >&2; exit 64; }
command -v qs >/dev/null 2>&1 || { echo "load-gate: qs not on PATH" >&2; exit 2; }

SCRATCH=${HUD_GATE_SCRATCH:-$HOME/.hermes/cache/scratch/hud-gate}
mkdir -p -- "$SCRATCH" || exit 2
W=$(mktemp -d -- "$SCRATCH/run.XXXXXX") || exit 2
mkdir -p -- "$W/cfg" "$W/xdg/config" "$W/xdg/state" "$W/xdg/cache"
cp -a -- "$SRC/." "$W/cfg/" || exit 2
cp -- "$W/cfg/Hud.qml" "$W/cfg/shell.qml" || exit 2

env -u WAYLAND_DISPLAY -u DISPLAY \
    QT_QPA_PLATFORM=offscreen \
    XDG_CONFIG_HOME="$W/xdg/config" XDG_STATE_HOME="$W/xdg/state" XDG_CACHE_HOME="$W/xdg/cache" \
    setsid qs -p "$W/cfg" >"$W/qs.log" 2>&1 &
pid=$!
sleep "$WAIT"
kill -TERM -- "-$pid" 2>/dev/null
sleep 2
kill -KILL -- "-$pid" 2>/dev/null
# sweep anything the HUD spawned from this copy, by PID
for p in $(ps -eo pid,args | grep -F -- "$W" | grep -v grep | awk '{print $1}'); do
    kill -KILL "$p" 2>/dev/null
done

echo "load-gate: tree=$SRC wait=${WAIT}s log=$W/qs.log"
hits=$(grep -E -- "$PAT" "$W/qs.log" || true)
if grep -q 'No PanelWindow backend loaded' "$W/qs.log"; then
    # The Loader's "v4 load failed" is the echo of the missing backend, not a code error.
    hits=$(printf '%s\n' "$hits" | grep -v 'nexuslink.hud: v4 load failed' || true)
    if [ -z "$hits" ]; then
        echo "load-gate: INCONCLUSIVE, offscreen has no PanelWindow backend, so HudV4 cannot finish loading here. Run --live after install."
        exit 2
    fi
fi
if [ -n "$hits" ]; then
    echo "load-gate: FAIL, error lines:"
    printf '%s\n' "$hits" | head -40
    exit 1
fi
echo "load-gate: PASS (offscreen), no error line"
exit 0
