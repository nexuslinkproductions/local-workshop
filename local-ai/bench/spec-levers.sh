#!/usr/bin/env bash
# spec-levers.sh — server-side speed levers for one matrix config, ONE locked call.
#
#   spec-levers.sh --cfg configs/<name>.env [--tokens 4096] [--n-predict 256]
#
# Some levers a bench loop cannot express: --spec-type (draft-mtp / ngram-*),
# --moe-cache-mib (hot-expert VRAM cache), prompt-lookup. They are launch flags of
# llama-server, so each one costs a restart. For every entry of LEVERS the script
# starts the server with SERVER_EXTRA + that lever, measures decode tok/s on a
# FIXED prompt (PROMPT_SOURCE text, temperature 0, greedy), kills the server, and
# appends a row with notes="lever:<name> <kept|reverted> ..." against the first
# entry (the reference). Kept if decode t/s improves >= KEEP_PCT (default 3).
#
# LEVERS config var: entries separated by '|', "<name>:<flags>", first is reference
#   LEVERS="none:|mtp:--spec-type draft-mtp|ngram:--spec-type ngram-mod"
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

CFG=""; TOKENS_OVR=""; NBP_OVR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cfg) CFG="$2"; shift ;;
        --tokens) TOKENS_OVR="$2"; shift ;;
        --n-predict) NBP_OVR="$2"; shift ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$CFG" ] || { echo "--cfg required" >&2; exit 2; }
[ -f "$CFG" ] || CFG="$HERE/$CFG"
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 2; }

ENGINE=""; BINDIR=""; MODEL=""; QUANT=""; NGL=99; CTX=65536; KV="q8_0"; THREADS=16
CAP="26G"; PLACEMENT=""; NCMOE=0; NOTE=""; PORT=18086; NP=1
EXTRA=(); SERVER_EXTRA=(); LEVERS="none:|mtp:--spec-type draft-mtp|ngram:--spec-type ngram-mod"
PROMPT_SOURCE=""; TOKENS=4096; N_PREDICT=256; KEEP_PCT=3; DEVICE_NAME=""; ENVSH=""
# shellcheck source=/dev/null
. "$CFG"
# <VAR>_OVERRIDE wins over the config, same contract as matrix-bench.sh / matrix-server.sh
# (without this, a lever run silently used the config's placeholder --n-cpu-moe).
for k in NGL CTX KV NCMOE PLACEMENT CAP THREADS PORT NP PROMPT_SOURCE TOKENS N_PREDICT LEVERS REQ_TIMEOUT; do
    o="${k}_OVERRIDE"; [ -n "${!o:-}" ] && printf -v "$k" '%s' "${!o}"
done

resolve() { [ -e "$1" ] && printf '%s' "$1" || printf '%s' "$LAB_ROOT/$1"; }
[ -n "$ENVSH" ] && { # shellcheck source=/dev/null
    . "$(resolve "$ENVSH")"; }
[ -n "$DEVICE_NAME" ] && DEVICE="$DEVICE_NAME"
BINDIR="$(resolve "$BINDIR")"; MODEL="$(resolve "$MODEL")"
SRV="$BINDIR/llama-server"; CLI="$BINDIR/llama-cli"
[ -x "$SRV" ] || { echo "not executable: $SRV" >&2; exit 2; }
SHA="$(git -C "$BINDIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$TOKENS_OVR" ] && TOKENS="$TOKENS_OVR"
[ -n "$NBP_OVR" ] && N_PREDICT="$NBP_OVR"

waited=0
while game_running; do
    if [ "$waited" -ge "${MAX_WAIT:-28800}" ]; then echo "game still running after ${waited}s — giving up" >&2; exit 3; fi
    echo "game open — sleeping 120s (${waited}s)" >&2
    sleep 120; waited=$(( waited + 120 ))
done
gate_check || exit 3
healthy() { curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }
healthy && { echo "port $PORT already answers — refusing to start a second server" >&2; exit 2; }

KVARR=(-fa on -ctk "$KV" -ctv "$KV")
NCMOEARR=(); [ "${NCMOE:-0}" -gt 0 ] && NCMOEARR=(-ncmoe "$NCMOE")
REF=""; REF_TS=""

fail_row() {   # $1 name, $2 reason
    python3 "$HERE/matrix-row.py" "$RESULTS" timestamp="$(date -Iseconds)" \
        engine="$ENGINE" git_sha="$SHA" model="$(basename "$MODEL" .gguf)" quant="$QUANT" \
        placement="$PLACEMENT" ctx="$CTX" kv_type="$KV" depth="$TOKENS" test="decode-lever" \
        tps_mean="0" notes="lever:$1 failed: $2" >/dev/null
}

measure() {   # $1 name, rest = extra server flags
    local name="$1"; shift
    local log="$SCRATCH/mxlever-$(basename "$CFG" .env)-$name-$$.log" srv t0 ms ok=""
    CAP="$CAP" timeout --kill-after=30 3600 ionice $IOCLASS_ARGS "$JUNK" "$SRV" -m "$MODEL" -ngl "$NGL" "${NCMOEARR[@]}" \
        -c "$CTX" -np "$NP" -t "$THREADS" "${KVARR[@]}" --device "$DEVICE" \
        --host 127.0.0.1 --port "$PORT" "${EXTRA[@]}" "${SERVER_EXTRA[@]}" "$@" >"$log" 2>&1 &
    local wpid=$!
    t0="$(date +%s%N)"
    for _ in $(seq 1 600); do
        kill -0 "$wpid" 2>/dev/null || { echo "server died for lever $name (see $log)" >&2; tail -5 "$log" >&2
            fail_row "$name" "server died at launch: $(grep -iE 'error|unsupported|unknown' "$log" | head -1 | cut -c1-120)"
            cleanup_one "$wpid"; return 1; }
        healthy && { ok=1; break; }
        sleep 1
    done
    [ -n "$ok" ] || { echo "lever $name: server never healthy" >&2
        fail_row "$name" "server not healthy in 600s: $(grep -iE 'error|unsupported|unknown' "$log" | head -1 | cut -c1-120)"
        cleanup_one "$wpid"; return 1; }
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    # Placement comes from the EFFECTIVE argv of the server we launched, not from the
    # config: a lever that sets --n-cpu-moe itself must not be labelled with the config's
    # placeholder value (that mislabelled every decode-lever row once).
    local srvpid argv eff_ngl eff_ncmoe eff_kv
    srvpid="$(pgrep -P "$wpid" 2>/dev/null | head -1 || true)"
    argv="$(tr '\0' ' ' < "/proc/${srvpid:-0}/cmdline" 2>/dev/null || true)"
    eff_ngl="$(printf '%s' "$argv" | grep -oE -- '(-ngl|--n-gpu-layers) [0-9]+' | grep -oE '[0-9]+' | head -1)"
    eff_ncmoe="$(printf '%s' "$argv" | grep -oE -- '(-ncmoe|--n-cpu-moe) [0-9]+' | grep -oE '[0-9]+' | head -1)"
    eff_kv="$(printf '%s' "$argv" | grep -oE -- '(-ctk|--cache-type-k) [a-z0-9_]+' | awk '{print $2}' | head -1)"
    MX_PLACEMENT_EFF="ngl=${eff_ngl:-?}/ncmoe=${eff_ncmoe:-0} (argv)"
    MX_KV_EFF="${eff_kv:-$KV}"
    MX_NAME="$name" MX_LOG="$log" MX_MS="$ms" MX_PORT="$PORT" MX_TOKENS="$TOKENS" \
    MX_NPRED="$N_PREDICT" MX_SRC="$PROMPT_SOURCE" MX_ENGINE="$ENGINE" MX_SHA="$SHA" \
    MX_MODELNAME="$(basename "$MODEL" .gguf)" MX_QUANT="$QUANT" MX_PLACEMENT="$PLACEMENT" \
    MX_KV="$KV" MX_CTX="$CTX" MX_NCMOE="$NCMOE" MX_THREADS="$THREADS" MX_RESULTS="$RESULTS" \
    MX_HERE="$HERE" MX_REF="$REF" MX_REFTS="$REF_TS" MX_KEEP="$KEEP_PCT" MX_DEV="$DEVICE" \
    MX_EXTRA="$*" python3 - <<'PY'
import json, os, sys, time, urllib.request
sys.path.insert(0, os.environ["MX_HERE"])
from importlib import import_module
row = import_module("matrix-row")
env = os.environ
port = int(env["MX_PORT"]); n = int(env["MX_TOKENS"])
src = env.get("MX_SRC", "")
text = open(src, errors="replace").read() if src and os.path.exists(src) else \
    ("Benchmark filler sentence number %d with a few extra words. " * 20) % 0
prompt = (text * (n * 4 // len(text) + 1))[: n * 4]
body = {"prompt": prompt, "n_predict": int(env["MX_NPRED"]), "temperature": 0,
        "ignore_eos": True, "cache_prompt": False, "n_keep": 0}
try:
    req = urllib.request.Request(f"http://127.0.0.1:{port}/completion",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    d = json.loads(urllib.request.urlopen(req, timeout=int(os.environ.get("REQ_TIMEOUT", "900"))).read().decode())
    t = d.get("timings", {})
    dec = float(t.get("predicted_per_second", 0) or 0)
    pps = float(t.get("prompt_per_second", 0) or 0)
    got = 1
except Exception as e:
    dec = pps = 0.0; got = 0
    print(f"lever {env['MX_NAME']}: measurement failed {e!r}", flush=True)

verdict = "reference"
if env["MX_REFTS"] and dec:
    gain = (dec - float(env["MX_REFTS"])) / float(env["MX_REFTS"]) * 100
    verdict = f"{'kept' if gain >= float(env['MX_KEEP']) else 'reverted'} ({gain:+.1f}% decode vs {env['MX_REF']})"
print(f"lever {env['MX_NAME']}: {dec:.2f} tok/s prompt={pps:.0f} tok/s load={int(env['MX_MS'])/1000:.0f}s {verdict}", flush=True)
notes = (f"lever:{env['MX_NAME']} {verdict} startup_{int(env['MX_MS'])/1000:.1f}s extra='{env['MX_EXTRA']}' "
         f"prompt={n}tok/{env['MX_NPRED']}gen prompt_src={os.path.basename(src or 'synthetic')} "
         f"placement={env['MX_PLACEMENT']} kv={env['MX_KV']} dev={env['MX_DEV']}")
row.append(env["MX_RESULTS"], engine=env["MX_ENGINE"], git_sha=env["MX_SHA"], model=env["MX_MODELNAME"],
           quant=env["MX_QUANT"], placement=env.get("MX_PLACEMENT_EFF") or env["MX_PLACEMENT"],
           ctx=env["MX_CTX"], kv_type=env.get("MX_KV_EFF") or env["MX_KV"],
           depth=n, test="decode-lever", tps_mean=f"{dec:.2f}", tps_std="", ttft_ms="",
           tool_call_pass="", timestamp=time.strftime("%Y-%m-%dT%H:%M:%S%z"), start=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
           notes=notes)
with open(os.environ["MX_HERE"] + "/.lever-ts", "w") as f:
    f.write(f"{env['MX_NAME']}\t{dec}\n")
PY
    local ts; ts="$(awk -F'\t' -v n="$name" '$1==n{print $2}' "$HERE/.lever-ts" 2>/dev/null || true)"
    if [ -z "$REF_TS" ] && [ -n "$ts" ]; then REF="$name"; REF_TS="$ts"; fi
    cleanup_one "$wpid"
}

cleanup_one() {
    kill -TERM "$1" 2>/dev/null || true
    sleep 2
    kill -KILL "$1" 2>/dev/null || true
}

echo "[spec-levers] $ENGINE sha=$SHA model=$(basename "$MODEL") ctx=$CTX kv=$KV ncmoe=$NCMOE ref=$REF tokens=$TOKENS npredict=$N_PREDICT" >&2
IFS='|' read -r -a entries <<< "$LEVERS"
for e in "${entries[@]}"; do
    name="${e%%:*}"; flags="${e#*:}"
    # shellcheck disable=SC2086
    measure "$name" $flags
done
sleep 2
if pgrep -f "llama-serve[r].*--port $PORT( |$)" >/dev/null 2>&1; then
    echo "WARNING: something still answers for --port $PORT — check by hand" >&2
fi
exit 0
