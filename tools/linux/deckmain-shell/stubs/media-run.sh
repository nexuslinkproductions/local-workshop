#!/bin/sh
# media-run.sh STUB-LOG - run media-e2e on the CURRENT (private) session bus.
# Start stubs/mpris_stub.py, run deckmain-shell with the media-e2e scenario, then
# kill the stub if it is still alive. Run it as: dbus-run-session -- media-run.sh LOG
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(cd -- "$HERE/../../../.." && pwd -P)
LOG=$1
: > "$LOG.player"
/usr/bin/python3 "$HERE/mpris_stub.py" "$LOG.player" &
STUB=$!
sleep 1
cd "$ROOT" || exit 3
tools/linux/deckmain-shell.sh --scenario media-e2e --seconds 40 --stub-log "$LOG"
RC=$?
kill "$STUB" 2>/dev/null
wait "$STUB" 2>/dev/null
exit "$RC"
