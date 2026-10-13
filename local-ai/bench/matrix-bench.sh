#!/usr/bin/env bash
# matrix-bench.sh — run ONE llama-bench config (or a llama-cli load probe) and
# append rows to bench/results-matrix.tsv.
#
#   matrix-bench.sh run   --cfg configs/<name>.env [--check]
#   matrix-bench.sh probe --cfg configs/<name>.env [--check]   # load-only, -c CTX
#
# Overrides from the environment (same spirit as bench.sh):
#   NGL_OVERRIDE CTX_OVERRIDE KV_OVERRIDE REPS_OVERRIDE DEPTHS_OVERRIDE
#   PROMPT_OVERRIDE GEN_OVERRIDE NCMOE_OVERRIDE PLACEMENT_OVERRIDE
#   CAP_OVERRIDE THREADS_OVERRIDE NOTE_OVERRIDE
#
# Locking: self-wraps in `flock -x bench/.gpu.lock` (bench/README rule 1).
# Game rule (Marcel): if a run is refused because ARCRaiders holds the GPU,
# sleep 120 s and re-check, up to MAX_WAIT s (default 28800 = 8 h). Never --force.
#
# ctx: llama-bench has no -c; it sets n_ctx = n_prompt + n_gen + n_depth, so a
# "ctx 65536" run is -d (65536 - prompt - gen). --ctx/CTX is translated here.
# Peak RSS comes from /proc/<pid>/status VmHWM (polled), peak VRAM from
# bench/arc-vram.py; both are recorded on every row.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(dirname "$HERE")"
RESULTS="${MATRIX_RESULTS:-$HERE/results-matrix.tsv}"
SCRATCH="${TMPDIR:-/tmp}"
DEVICE="${DEVICE:-Vulkan0}"
JUNK="/home/nexuslink/.local/bin/jobcap"
# idle I/O class: a model read never beats the desktop on BFQ (override: IOCLASS_ARGS="-c 2 -n 7")
IOCLASS_ARGS="${IOCLASS_ARGS:--c 3}"
. "$HERE/gate.sh"

case " ${*:-} " in *" --check "*) ;; *)
    if [ -z "${MATRIX_LOCKED:-}" ]; then
        export MATRIX_LOCKED=1
        exec flock -x -w 3600 "$LOCK_FILE" "$0" "$@"
    fi ;;
esac

MODE=""; CFG=""; CHECK=""
[ $# -gt 0 ] || { sed -n '2,10p' "${BASH_SOURCE[0]}" >&2; exit 2; }
MODE="$1"; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --cfg)   CFG="$2"; shift ;;
        --check) CHECK=1 ;;
        -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$MODE" in run|probe) ;; *) echo "mode must be run|probe" >&2; exit 2 ;; esac
[ -n "$CFG" ] || { echo "--cfg required" >&2; exit 2; }
[ -f "$CFG" ] || CFG="$HERE/$CFG"
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 2; }

# ---- config ---------------------------------------------------------------
ENGINE=""; BINDIR=""; MODEL=""; QUANT=""; NGL=99; CTX=65536; KV="q8_0"; FA="on"
THREADS=16; CAP="26G"; PROMPT=512; GEN=128; REPS=3; DEPTHS=""; PLACEMENT=""
NCMOE=0; NOTE=""; EXTRA=(); DEVICE_NAME=""; ENVSH=""
# shellcheck source=/dev/null
. "$CFG"
for k in NGL CTX KV FA REPS DEPTHS PROMPT GEN NCMOE PLACEMENT CAP THREADS NOTE; do
    o="${k}_OVERRIDE"; [ -n "${!o:-}" ] && printf -v "$k" '%s' "${!o}"
done

resolve() { [ -e "$1" ] && printf '%s' "$1" || printf '%s' "$LAB_ROOT/$1"; }
BINDIR="$(resolve "$BINDIR")"
MODEL="$(resolve "$MODEL")"
CLI="$BINDIR/llama-cli"; BENCH="$BINDIR/llama-bench"
[ -x "$BENCH" ] || { echo "not executable: $BENCH" >&2; exit 2; }
[ -x "$CLI" ]   || { echo "not executable: $CLI" >&2; exit 2; }
[ -f "$MODEL" ] || { echo "model not found: $MODEL" >&2; exit 2; }

# engine-specific environment (e.g. the oneAPI/SYCL prelude): sourced here so the
# launched binary inherits it. SYCL0 needs oneapi-env.sh + the oneDNN lib path.
[ -n "$ENVSH" ] && { # shellcheck source=/dev/null
    . "$(resolve "$ENVSH")"; }
[ -n "$DEVICE_NAME" ] && DEVICE="$DEVICE_NAME"
# free/total MiB for THIS device, from that build's own --list-devices
dev_free_mib() {
    "$CLI" --list-devices 2>/dev/null \
        | grep -E "^[[:space:]]*${DEVICE}:" | tail -1 \
        | sed -n 's/.*(\([0-9]\+\) MiB, \([0-9]\+\) MiB free).*/\2 \1/p'
}

SHA="$(git -C "$BINDIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ "$SHA" = unknown ]; then
    d="$BINDIR"; while [ "$d" != / ]; do [ -e "$d/.git" ] && { SHA="$(git -C "$d" rev-parse --short HEAD)"; break; }; d="$(dirname "$d")"; done
fi

# depth list: DEPTHS wins; else derive from CTX
if [ -z "${DEPTHS:-}" ]; then DEPTHS=$(( CTX - PROMPT - GEN )); [ "$DEPTHS" -lt 0 ] && DEPTHS=0; fi
[ -n "$PLACEMENT" ] || PLACEMENT="ngl=$NGL${NCMOE:+/ncmoe=$NCMOE}"

# ---- command --------------------------------------------------------------
KVARR=(-fa "$FA" -ctk "$KV" -ctv "$KV")
NCMOEARR=(); [ "${NCMOE:-0}" -gt 0 ] && NCMOEARR=(-ncmoe "$NCMOE")
# A depth >= 32768 costs one full re-prefill PER REP at the depth rate (~59 t/s on the
# dense baseline = ~9 min/rep), which is what blew the timeout on the first dense run.
# Force reps=1 there and give the run a bigger cap.
BIGDEPTH=""
for d in ${DEPTHS//,/ }; do [ "${d:-0}" -ge 32768 ] 2>/dev/null && BIGDEPTH="$d"; done
if [ -n "$BIGDEPTH" ] && [ "$REPS" -gt 1 ]; then
    REPS=1
    NOTE="${NOTE:+$NOTE | }depth>=32768: reps forced to 1 (each rep re-prefills the depth)"
fi
if [ "$MODE" = run ]; then
    CMD=("$BENCH" -m "$MODEL" -p "$PROMPT" -n "$GEN" -d "$DEPTHS" -ngl "$NGL"
         "${NCMOEARR[@]}" -r "$REPS" -o json -t "$THREADS" "${KVARR[@]}" --device "$DEVICE" "${EXTRA[@]}")
    TMO="${BENCH_TMO:-7200}"; [ -n "$BIGDEPTH" ] && TMO="${BENCH_TMO_BIG:-18000}"
else
    CMD=("$CLI" -m "$MODEL" -c "$CTX" -ngl "$NGL" "${NCMOEARR[@]}" -t "$THREADS"
         "${KVARR[@]}" --device "$DEVICE" -p "hi" -n 1 -st --no-warmup)
    TMO="${PROBE_TMO:-300}"
fi
if [ -n "$CHECK" ]; then printf 'CMD: %q ' "${CMD[@]}"; echo; echo "cap=$CAP depths=$DEPTHS reps=$REPS dev=$DEVICE"; exit 0; fi

# ---- gate: game -> sleep 120 and retry (never --force) --------------------
waited=0
while game_running; do
    if [ "$waited" -ge "${MAX_WAIT:-28800}" ]; then
        echo "game still running after ${waited}s — giving up" >&2; exit 3
    fi
    echo "game open — sleeping 120s (${waited}s of ${MAX_WAIT:-28800}s)" >&2
    sleep 120; waited=$(( waited + 120 ))
done
gate_check || exit 3

# ---- pre-load memory guard (Marcel 2026-10-13) -----------------------------
# The desktop freezes are memory/IO stalls, not CPU. Refuse to load rather than read a
# 20-37 GB GGUF through the page cache and swap the desktop into zram.
LOADMODE="${LOADMODE:-}"
if [ -z "$LOADMODE" ]; then
    for ((i = 0; i < ${#EXTRA[@]}; i++)); do
        case "${EXTRA[i]}" in -lm|--load-mode) LOADMODE="${EXTRA[i+1]:-auto}" ;; esac
    done
    [ -n "$LOADMODE" ] || LOADMODE="auto"
fi
GUARD="$(mem_guard "$MODEL" "$LOADMODE" "${VRAM_EST_MIB:-0}")"
read -r _verdict _need _avail <<<"$GUARD"
if [ "$_verdict" = REFUSE ]; then
    echo "REFUSING TO LOAD (memory): needs ${_need}MiB RAM+8G, MemAvailable ${_avail}MiB (load_mode=$LOADMODE)" >&2
    python3 "$HERE/matrix-row.py" "$RESULTS" timestamp="$(date -Iseconds)" engine="$ENGINE" \
        git_sha="$SHA" model="$(basename "$MODEL" .gguf)" quant="$QUANT" placement="$PLACEMENT" \
        ctx="$CTX" kv_type="$KV" test="SKIPPED-MEM" tps_mean="" \
        notes="SKIPPED-MEM: load refused, MemAvailable=${_avail}MiB < model-in-RAM+8GiB=${_need}MiB (load_mode=$LOADMODE)" >/dev/null
    exit 7
fi

# pre-load IO guard (gate.sh): a load into a busy disk trips the watchdog; wait or skip
if ! io_quiet_wait; then
    echo "SKIPPED-IO: disk still busy after 30 min (io full avg10=$IO_BUSY)" >&2
    python3 "$HERE/matrix-row.py" "$RESULTS" timestamp="$(date -Iseconds)" engine="$ENGINE" \
        git_sha="$SHA" model="$(basename "$MODEL" .gguf)" quant="$QUANT" placement="$PLACEMENT" \
        ctx="$CTX" kv_type="$KV" test="SKIPPED-IO" tps_mean="" \
        notes="SKIPPED-IO: io full avg10=$IO_BUSY (>=0.5) for 30 min, a download is running (watchdog would trip at 1.0)" >/dev/null
    exit 7
fi

VRAM_FREE="$(dev_free_mib || true)"
FREE="${VRAM_FREE%% *}"; TOTAL="${VRAM_FREE##* }"
[ -n "${FREE:-}" ] || FREE=?

# ---- run with peak RSS / VRAM polling ------------------------------------
# NB: the poller runs in a subshell, so it appends to a file — variables set in
# it would be lost (that bug silently recorded 0 for every row).
LOG="$SCRATCH/mx-$(basename "$CFG" .env)-$MODE-$$"
START="$(date -Iseconds)"
echo "[matrix] $MODE engine=$ENGINE sha=$SHA ngl=$NGL ncmoe=$NCMOE ctx=$CTX depth=$DEPTHS reps=$REPS kv=$KV free=${FREE}MiB gpu=$(game_state) start=$START" >&2

PEAKFILE="$LOG.peaks"; : > "$PEAKFILE"
poll() {
    local wpid="$1" child r=0 v
    while kill -0 "$wpid" 2>/dev/null; do
        r=0
        child="$(pgrep -P "$wpid" 2>/dev/null | head -1 || true)"
        if [ -n "$child" ] && [ -r "/proc/$child/status" ]; then
            v="$(awk '/^VmHWM:/{print $2}' "/proc/$child/status" 2>/dev/null || true)"
            [ -n "${v:-}" ] && r="$v"
        fi
        v="$(python3 "$HERE/arc-vram.py" 2>/dev/null | sed -n 's/.*used=\([0-9]*\).*/\1/p' | head -1 || true)"
        printf '%s %s %s\n' "$r" "${v:-0}" "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" >> "$PEAKFILE"
        sleep 1.5
    done
}

PSI0="$(psi_now)"
# every model run goes through the desktop watchdog (PSI full / MemAvailable kill switch)
CAP="$CAP" MATRIX_RESULTS="$RESULTS" bash "$HERE/watchdog.sh" "$(basename "$CFG" .env)-$MODE" -- \
    timeout --kill-after=30 "$TMO" ionice $IOCLASS_ARGS "$JUNK" "${CMD[@]}" >"$LOG.json" 2> "$LOG.err" &
WPID=$!
poll "$WPID" & POLL=$!
rc=0; wait "$WPID" || rc=$?
PSI1="$(psi_now)"
PSID="$(psi_delta "$PSI0" "$PSI1")"
sleep 1; kill "$POLL" 2>/dev/null || true; wait "$POLL" 2>/dev/null || true
END="$(date -Iseconds)"
PEAK_RSS_KIB="$(awk '{if($1>m)m=$1} END{print m+0}' "$PEAKFILE" 2>/dev/null || echo 0)"
PEAK_VRAM_MIB="$(awk '{if($2>m)m=$2} END{print m+0}' "$PEAKFILE" 2>/dev/null || echo 0)"
MEM_MIN_MIB="$(awk '$3>0{if(m==0||$3<m)m=$3} END{print int(m/1024)}' "$PEAKFILE" 2>/dev/null || echo 0)"

if [ "$MODE" = run ] && [ ! -s "$LOG.json" ]; then
    echo "no llama-bench JSON (rc=$rc) — did not fit / failed to load" >&2
    tail -20 "$LOG.err" >&2 || true
fi

MX_TS="$START" MX_END="$END" MX_ENGINE="$ENGINE" MX_SHA="$SHA" MX_MODEL="$PROMPT" \
MX_MODELNAME="$(basename "$MODEL" .gguf)" MX_QUANT="$QUANT" MX_PLACEMENT="$PLACEMENT" \
MX_KV="$KV" MX_PROMPT="$PROMPT" MX_GEN="$GEN" MX_REPS="$REPS" MX_RSS_KIB="$PEAK_RSS_KIB" \
MX_VRAM_MIB="$PEAK_VRAM_MIB" MX_TOTAL_MIB="$TOTAL" MX_FREE="$FREE" MX_GAME="$(game_state)" \
MX_THREADS="$THREADS" MX_NCMOE="$NCMOE" MX_NOTE="$NOTE" MX_MODE="$MODE" MX_RESULTS="$RESULTS" \
MX_HERE="$HERE" MX_RC="$rc" MX_DEPTHS="$DEPTHS" MX_CTX="$CTX" MX_LOG="$LOG" \
MX_PSI="$PSID" MX_MEM_MIN="$MEM_MIN_MIB" MX_LOADMODE="$LOADMODE" python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["MX_HERE"])
from importlib import import_module
row = import_module("matrix-row")

env = os.environ
base = dict(timestamp=env["MX_TS"], engine=env["MX_ENGINE"], git_sha=env["MX_SHA"],
            model=env["MX_MODELNAME"], quant=env["MX_QUANT"], placement=env["MX_PLACEMENT"],
            kv_type=env["MX_KV"], peak_rss_gib=f"{int(env['MX_RSS_KIB'])/1048576:.2f}",
            vram_used_mib=env["MX_VRAM_MIB"], start=env["MX_TS"], end=env["MX_END"])

# llama-cli writes its load log to STDOUT (mixed with the chat text), llama-bench
# to stderr — read both so the layer placement is captured either way.
blob = ""
for suffix in (".err", ".json"):
    try:
        blob += open(env["MX_LOG"] + suffix, errors="replace").read()
    except OSError:
        pass
dev = {}
for line in blob.splitlines():
    if "assigned to device" in line and line.strip().startswith("load_tensors:"):
        d = line.split("assigned to device", 1)[1].split(",")[0].strip()
        m = line.split("layer", 1)[1].strip().split()[0]
        if m.lstrip("-").isdigit():
            dev.setdefault(d, []).append(int(m))
ranges = []
for d, ls in sorted(dev.items(), key=lambda kv: min(kv[1])):
    ls = sorted(ls); out = []; a = b = ls[0]
    for x in ls[1:]:
        if x == b + 1: b = x
        else: out.append(f"{a}-{b}" if a != b else f"{a}"); a = b = x
    out.append(f"{a}-{b}" if a != b else f"{a}")
    ranges.append(f"{d}:{','.join(out)}")
offl = " ".join(l.strip() for l in blob.splitlines() if "load_tensors: offloading" in l)[:200]
headroom = int(env["MX_TOTAL_MIB"] or 0) - int(env["MX_VRAM_MIB"] or 0)
note_extra = (f" t={env['MX_THREADS']} ncmoe={env['MX_NCMOE']} free_before={env['MX_FREE']}MiB"
              f" headroom_peak={headroom}MiB gpu={env['MX_GAME']}"
              f" lm={env.get('MX_LOADMODE','?')} {env.get('MX_PSI','')} mem_min={env.get('MX_MEM_MIN','?')}MiB")
if ranges: note_extra += " layers={" + "; ".join(ranges) + "}"
if offl: note_extra += f" [{offl}]"
extra_note = (" " + env["MX_NOTE"]) if env["MX_NOTE"] else ""
tail = note_extra + extra_note

written = 0
if env["MX_MODE"] == "probe":
    # rc=0 alone is not proof of fitting: at -ngl 48 (64K KV) the xe driver let the
    # process over-commit past VRAM and wedge (killed by the timeout -> rc=124), so
    # the timeout is the wedge detector and the exit code is the load verdict.
    # PROBE_MIN_HEADROOM (MiB, default 0) additionally rejects over-commit: on this
    # card llama.cpp legitimately spills through GTT (ngl 40/42/44 all load), so the
    # default only demands "it runs", while MoE sweeps pass 600 MiB as Marcel asked.
    minh = int(os.environ.get("PROBE_MIN_HEADROOM", "0") or 0)
    ok = env["MX_RC"] == "0" and os.path.getsize(env["MX_LOG"] + ".json") > 0 and headroom >= minh
    why = ""
    if not ok:
        why = (f"load rc={env['MX_RC']}" if env["MX_RC"] != "0"
               else f"headroom_peak={headroom}MiB < {minh}MiB")
    elif headroom < 300:
        why = f"spills through GTT (headroom_peak={headroom}MiB)"
    row.append(env["MX_RESULTS"], ctx=env["MX_CTX"], depth=0,
               test="loadprobe" + ("" if ok else "-FAIL"), tps_mean="", tps_std="",
               tool_call_pass="", notes=(("load ok " + why) if ok else why) + tail, **base)
    written = 1
    if not ok:
        print(f"probe verdict: DOES NOT FIT at ngl={env.get('MX_NGL','?')} "
              f"ncmoe={env['MX_NCMOE']} ctx={env['MX_CTX']} ({why})", file=sys.stderr)
        sys.exit(4)
else:
    # llama-bench -o json writes one array; if the run was killed mid-array the file is
    # TRUNCATED, not malformed. Salvage every complete object and write those rows
    # (with a warning) instead of dying — a truncated 32K leg must not lose the legs
    # that did finish.
    txt = open(env["MX_LOG"] + ".json", errors="replace").read()
    data, truncated = [], False
    try:
        data = json.loads(txt)
    except Exception as e:
        print(f"WARNING: llama-bench JSON truncated/unparseable ({e}) — salvaging "
              f"complete objects", file=sys.stderr)
        dec = json.JSONDecoder(); i = 0
        while i < len(txt):
            while i < len(txt) and txt[i] in " \t\r\n[],":
                i += 1
            if i >= len(txt):
                break
            try:
                o, i = dec.raw_decode(txt, i)
            except Exception:
                truncated = True
                break
            data.append(o)
    if isinstance(data, dict):
        data = data.get("results", [])
    if not data:
        print("FATAL: no complete llama-bench result in the output", file=sys.stderr)
        sys.exit(1)
    if truncated:
        tail += " [WARNING: run was cut off — only the complete tests above were recorded]"
    for r in data:
        np_, ng = int(r.get("n_prompt", 0)), int(r.get("n_gen", 0))
        d = int(r.get("n_depth", 0))
        row.append(env["MX_RESULTS"], ctx=np_ + ng + d, depth=d,
                   test=f"pp{np_}" if np_ else f"tg{ng}",
                   tps_mean=f"{float(r['avg_ts']):.2f}", tps_std=f"{float(r.get('stddev_ts', 0.0)):.2f}",
                   tool_call_pass="", notes=tail, **base)
        written += 1
print(f"appended {written} row(s) to {env['MX_RESULTS']} | peak_rss={int(env['MX_RSS_KIB'])/1048576:.2f}GiB "
      f"peak_vram_used={env['MX_VRAM_MIB']}MiB headroom={headroom}MiB rc={env['MX_RC']}")
PY

echo "[matrix] done $END (start=$START rc=$rc) log=$LOG" >&2
[ "$rc" = 0 ] || exit "$rc"
