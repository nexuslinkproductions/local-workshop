#!/usr/bin/env bash
# memwatch-drill.sh: fault drill for memwatch alerts and the gate refusal (BRIEF-45).
# Builds fake /proc and kernel-log fixtures under $TMPDIR, then checks that each alert
# fires once, that the cooldown holds, and that gate_check refuses on the faulty fixture.
# Usage: bench/memwatch-drill.sh   (rc 0 = all PASS)
set -uo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
MW="${MEMWATCH:-$HOME/.local/bin/memwatch}"
D="$(mktemp -d "${TMPDIR:-/tmp}/memwatch-drill.XXXXXX")"
NOW=$(date +%s)
FAIL=0

# mk_proc <dir> <MemAvailable kB> <psi mem some avg10> <kswapd0 present 1|0>
mk_proc() {
    mkdir -p "$1/pressure" "$1/1" "$1/193"
    printf 'MemTotal: 65000000 kB\nMemFree: 26000000 kB\nMemAvailable: %s kB\nCached: 25000000 kB\nBuffers: 1000 kB\nDirty: 1000 kB\nWriteback: 0 kB\nSwapFree: 63000000 kB\n' "$2" > "$1/meminfo"
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' "$3" > "$1/pressure/memory"
    cp "$1/pressure/memory" "$1/pressure/io"
    echo systemd > "$1/1/comm"
    if [ "$4" = 1 ]; then echo kswapd0 > "$1/193/comm"; else rm -rf "$1/193"; fi
}
mk_proc "$D/healthy" 40000000 0.00 1
mk_proc "$D/faulty" 3145728 12.50 0
printf '%s.647671 OmarchyLink kernel: BUG: kernel NULL pointer dereference, address: 0000000000000018\n%s.689017 OmarchyLink kernel: Oops: Oops: 0000 [#1] SMP NOPTI\n' "$NOW" "$NOW" > "$D/klog.faulty"
: > "$D/klog.clean"
printf '#!/bin/sh\necho "$@" >> %s/notify.log\n' "$D" > "$D/notify.sh"; chmod +x "$D/notify.sh"

# run_mw <proc> <klog> <cooldown_s> [hold_s]: one memwatch sample against the fixtures
run_mw() {
    MEMWATCH_PROC="$1" MEMWATCH_KLOG="$2" MEMWATCH_COOLDOWN_S="$3" MEMWATCH_HOLD_S="${4:-0}" \
        MEMWATCH_STATE="${STATE_DIR:-$D/state}" MEMWATCH_NOTIFY="$D/notify.sh" python3 "$MW"
}
notified() { wc -l < "$D/notify.log" 2>/dev/null || echo 0; }
expect() {  # <want total notifies> <label>
    local got; got=$(notified)
    if [ "$got" = "$1" ]; then echo "PASS $2: notify total=$got"
    else echo "FAIL $2: want $1 got $got"; FAIL=1; fi
}

run_mw "$D/faulty" "$D/klog.faulty" 1800; expect 4 "1 faulty sample: oops, kswapd0, psi, mem each once"
run_mw "$D/faulty" "$D/klog.faulty" 1800; expect 4 "2 same again inside cooldown: silent"
run_mw "$D/faulty" "$D/klog.faulty" 0;    expect 7 "3 cooldown expired: kswapd0, psi, mem again; oops NOT repeated"
run_mw "$D/healthy" "$D/klog.clean" 1800; expect 7 "4 healthy sample: silent"
# psi hold: a fresh state with the default 60 s hold must not fire psi on the first sample
rm -f "$D/notify.log"; mkdir -p "$D/hold"
STATE_DIR="$D/hold" run_mw "$D/faulty" "$D/klog.clean" 1800 60
got=$(notified)
if [ "$got" = 2 ] && ! grep -q 'memory pressure' "$D/notify.log"; then echo "PASS psi hold: first sample high for 0 s, psi silent (kswapd0 + mem only)"
else echo "FAIL psi hold: want 2 non-psi notifies, got $got"; FAIL=1; fi
echo "TSV last row (expect alerts column '-'):"; tail -1 "$D/state/memwatch.tsv" | awk -F'\t' '{print "  alerts=" $NF, " kswapd0=" $12}'
echo "TSV faulty row alerts:"; sed -n '2p' "$D/state/memwatch.tsv" | awk -F'\t' '{print "  alerts=" $NF}'

gate_out=$(MEMWATCH_PROC="$D/faulty" GATE_KLOG="$D/klog.faulty" LAB="$LAB" \
    bash -c 'source "$LAB/bench/gate.sh"; gate_check' 2>&1) && grc=0 || grc=$?
if [ "$grc" = 1 ] && grep -q 'kswapd0 missing' <<<"$gate_out" && grep -q 'GPU reset or kernel oops' <<<"$gate_out"; then
    echo "PASS gate refuses on faulty fixture (rc=1, both reasons)"
else echo "FAIL gate faulty: rc=$grc out=$gate_out"; FAIL=1; fi
gate_out=$(MEMWATCH_PROC="$D/healthy" GATE_KLOG="$D/klog.clean" LAB="$LAB" \
    bash -c 'source "$LAB/bench/gate.sh"; gate_check' 2>&1) && grc=0 || grc=$?
if [ "$grc" = 0 ]; then echo "PASS gate passes on healthy fixture (rc=0)"; else echo "FAIL gate healthy: rc=$grc out=$gate_out"; FAIL=1; fi

echo "fixtures and logs: $D"
[ "$FAIL" = 0 ] && echo "DRILL: ALL PASS" || echo "DRILL: FAILURES"
exit "$FAIL"
