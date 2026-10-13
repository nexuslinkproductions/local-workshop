#!/usr/bin/env bash
# watchdog.sh <label> -- <command...>
#
# Marcel's hard requirement (2026-10-13): a local model must NEVER disturb his desktop.
# This wraps a bench/server run and kills it the moment the machine is in danger:
#   * /proc/pressure/memory "full avg10" > WATCH_PSI_FULL_MAX (default 1.0), or
#   * /proc/pressure/io     "full avg10" > WATCH_PSI_FULL_MAX, or
#   * MemAvailable < WATCH_MEM_MIN_MIB (default 6144 MiB)
# On a trip it kills the child's whole process group, then writes an ABORT-LAG row to
# results-matrix.tsv carrying the config label, the metric and the offending value.
#
# Thresholds are env-tunable so the trip path can be proven with a FAKE load (a plain
# RAM allocator) instead of a real model — see the dry-run in research/10 §6.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${MATRIX_RESULTS:-$HERE/results-matrix.tsv}"
# Marcel 18:55: 1.0 single-sample tripped on harmless load bursts (io full 1.41 measured with lag p99 <=0.7 ms).
# Now: avg10 above 5.0 (5% of time fully stalled) for STRIKES consecutive seconds. mem_available stays a hard trip.
PSI_MAX="${WATCH_PSI_FULL_MAX:-5.0}"
STRIKES="${WATCH_PSI_STRIKES:-5}"
hits=0
MEM_MIN="${WATCH_MEM_MIN_MIB:-6144}"

LABEL="${1:-job}"; shift || true
[ "${1:-}" = "--" ] && shift || true
[ $# -gt 0 ] || { echo "usage: watchdog.sh <label> -- <command...>" >&2; exit 2; }

row() {  # $1 test, $2 notes
    python3 "$HERE/matrix-row.py" "$RESULTS" timestamp="$(date -Iseconds)" test="$1" \
        tps_mean="" notes="$2" >/dev/null 2>&1 || true
}

setsid "$@" &
CHILD=$!
PGID="$CHILD"   # setsid makes the child a process-group leader, so PGID == its pid
kill_tree() {
    kill -TERM "-$PGID" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null || true
    sleep 2
    kill -KILL "-$PGID" 2>/dev/null || true
}
trap 'kill_tree' INT TERM

trip=""
# IO-load grace (opt-in, default 0 = off): a model read at NVMe speed is itself an IO-full
# burst (proven 2026-10-13: 6.5 GB direct read -> io full avg10 1.41, lag-probe p99 <=0.7 ms).
# For the first WATCH_IO_GRACE_S seconds only the io-full trip is skipped; memory trips stay on.
IO_GRACE="${WATCH_IO_GRACE_S:-0}"
T0="$(date +%s)"
while kill -0 "$CHILD" 2>/dev/null; do
    mfull="$(awk '/^full/{sub("avg10=","",$2); print $2}' /proc/pressure/memory 2>/dev/null)"
    ifull="$(awk '/^full/{sub("avg10=","",$2); print $2}' /proc/pressure/io 2>/dev/null)"
    avail="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    mfull="${mfull:-0}"; ifull="${ifull:-0}"; avail="${avail:-0}"
    psi=""
    if awk -v a="$mfull" -v b="$PSI_MAX" 'BEGIN{exit !(a>b)}'; then
        psi="psi_mem_full avg10=${mfull} > ${PSI_MAX} for ${STRIKES}s"
    elif [ $(( $(date +%s) - T0 )) -ge "$IO_GRACE" ] && awk -v a="$ifull" -v b="$PSI_MAX" 'BEGIN{exit !(a>b)}'; then
        psi="psi_io_full avg10=${ifull} > ${PSI_MAX} for ${STRIKES}s"
    fi
    if [ -n "$psi" ]; then hits=$((hits+1)); else hits=0; fi
    if [ "$hits" -ge "$STRIKES" ]; then
        trip="$psi"
    elif [ "$avail" -lt "$MEM_MIN" ]; then
        trip="mem_available ${avail}MiB < ${MEM_MIN}MiB"
    fi
    [ -n "$trip" ] && break
    sleep 1
done

if [ -n "$trip" ]; then
    echo "[watchdog] ABORT-LAG ($LABEL): $trip — killing job" >&2
    kill_tree
    row "ABORT-LAG" "ABORT-LAG config=$LABEL metric=${trip%% *} value=${trip#* } (thresholds psi_full<=${PSI_MAX} mem>=${MEM_MIN}MiB)"
    exit 9
fi
wait "$CHILD"; rc=$?
exit "$rc"
