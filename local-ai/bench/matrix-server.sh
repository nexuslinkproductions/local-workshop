#!/usr/bin/env bash
# matrix-server.sh — ONE locked llama-server session for bench/results-matrix.tsv:
#   cold start -> /health, kill, warm start -> /health     (two startup rows)
#   -> TTFT + decode on 4K and 32K filler prompts          (two ttft rows)
#   -> vision: grim screenshot, (1) describe, (2) named-element pixel coords as JSON
#   -> ONE tool-call smoke test
#   -> peak RSS + peak VRAM + VRAM after load, then kill only what it started.
#
#   matrix-server.sh --cfg configs/<name>.env [--check]
#
# RULE 2 (bench/README): start, measure and kill happen inside ONE exclusive-lock
# call, so no other test can run while this server holds VRAM.
# Game rule (Marcel): if the game holds the GPU, sleep 120 s and re-check, up to
# MAX_WAIT s (default 28800 = 8 h). Never --force.
#
# Rows: test=startup (ttft_ms = ms from launch to /health; notes=cold|warm)
#       test=ttft (depth=prompt tokens, ttft_ms=TTFT, tps_mean=decode tok/s)
#       test=vision-describe | vision-coords (tool_call_pass=coords JSON parsed)
#       test=toolcall (tool_call_pass=1/0)
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

CFG=""; CHECK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cfg) CFG="$2"; shift ;;
        --check) CHECK=1 ;;
        -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$CFG" ] || { echo "--cfg required" >&2; exit 2; }
[ -f "$CFG" ] || CFG="$HERE/$CFG"
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 2; }

ENGINE=""; BINDIR=""; MODEL=""; QUANT=""; NGL=99; CTX=65536; KV="q8_0"; THREADS=16
CAP="26G"; PLACEMENT=""; NCMOE=0; NOTE=""; PORT=18081; NP=1; MAXTOK=4096
PROMPT_TOKENS="4096 32768"; EXTRA=(); SERVER_EXTRA=(); MMPROJ=""; VISION_ELEMENT=""
PROMPT_SOURCE=""; GRIM_ARGS=()
DEVICE_NAME=""; ENVSH=""
# shellcheck source=/dev/null
. "$CFG"
for k in NGL CTX KV NCMOE PLACEMENT CAP THREADS NOTE PORT NP MAXTOK PROMPT_TOKENS MMPROJ VISION_ELEMENT PROMPT_SOURCE ENGINE BINDIR MODEL QUANT; do
    o="${k}_OVERRIDE"; [ -n "${!o:-}" ] && printf -v "$k" '%s' "${!o}"
done

resolve() { [ -e "$1" ] && printf '%s' "$1" || printf '%s' "$LAB_ROOT/$1"; }
BINDIR="$(resolve "$BINDIR")"; MODEL="$(resolve "$MODEL")"
SRV="$BINDIR/llama-server"; CLI="$BINDIR/llama-cli"
[ -x "$SRV" ] || { echo "not executable: $SRV" >&2; exit 2; }
[ -f "$MODEL" ] || { echo "model not found: $MODEL" >&2; exit 2; }
# engine-specific environment (SYCL: oneAPI prelude + oneDNN path, device SYCL0)
[ -n "$ENVSH" ] && { # shellcheck source=/dev/null
    . "$(resolve "$ENVSH")"; }
[ -n "$DEVICE_NAME" ] && DEVICE="$DEVICE_NAME"
dev_free_mib() {
    "$CLI" --list-devices 2>/dev/null \
        | grep -E "^[[:space:]]*${DEVICE}:" | tail -1 \
        | sed -n 's/.*(\([0-9]\+\) MiB, \([0-9]\+\) MiB free).*/\2 \1/p'
}
MMARG=()
[ -n "$MMPROJ" ] && { MMPROJ="$(resolve "$MMPROJ")"
    [ -f "$MMPROJ" ] || { echo "mmproj not found: $MMPROJ" >&2; exit 2; }
    MMARG=(--mmproj "$MMPROJ"); }

SHA="$(git -C "$BINDIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$PLACEMENT" ] || PLACEMENT="ngl=$NGL${NCMOE:+/ncmoe=$NCMOE}"

KVARR=(-fa on -ctk "$KV" -ctv "$KV")
NCMOEARR=(); [ "${NCMOE:-0}" -gt 0 ] && NCMOEARR=(-ncmoe "$NCMOE")
CMD=("$SRV" -m "$MODEL" -ngl "$NGL" "${NCMOEARR[@]}" -c "$CTX" -np "$NP" -t "$THREADS"
     "${KVARR[@]}" --device "$DEVICE" --host 127.0.0.1 --port "$PORT" "${MMARG[@]}"
     "${EXTRA[@]}" "${SERVER_EXTRA[@]}")
if [ -n "$CHECK" ]; then printf 'CMD: %q ' "${CMD[@]}"; echo; exit 0; fi

waited=0
while game_running; do
    if [ "$waited" -ge "${MAX_WAIT:-28800}" ]; then echo "game still running after ${waited}s — giving up" >&2; exit 3; fi
    echo "game open — sleeping 120s (${waited}s)" >&2
    sleep 120; waited=$(( waited + 120 ))
done
gate_check || exit 3
# pre-load guards (gate.sh): RAM (refuse) and disk (wait, else skip) — same rules as matrix-bench
LOADMODE=""; for ((i = 0; i < ${#EXTRA[@]}; i++)); do case "${EXTRA[i]}" in -lm|--load-mode) LOADMODE="${EXTRA[i+1]:-auto}" ;; esac; done
GUARD="$(mem_guard "$MODEL" "${LOADMODE:-auto}" "${VRAM_EST_MIB:-0}")"
read -r _verdict _need _avail <<<"$GUARD"
if [ "$_verdict" = REFUSE ]; then
    echo "REFUSING TO LOAD (memory): needs ${_need}MiB, MemAvailable ${_avail}MiB" >&2; exit 7
fi
if ! io_quiet_wait; then
    echo "SKIPPED-IO: disk still busy after 30 min (io full avg10=$IO_BUSY)" >&2
    python3 "$HERE/matrix-row.py" "$RESULTS" timestamp="$(date -Iseconds)" engine="$ENGINE" \
        git_sha="$SHA" model="$(basename "$MODEL" .gguf)" quant="$QUANT" placement="$PLACEMENT" \
        ctx="$CTX" kv_type="$KV" test="SKIPPED-IO" tps_mean="" \
        notes="SKIPPED-IO: io full avg10=$IO_BUSY (>=0.5) for 30 min (download running)" >/dev/null
    exit 7
fi

# ---- pre-load memory guard (Marcel 2026-10-13) -----------------------------
# Refuse to load rather than read a 20-37 GB GGUF through the page cache and swap the
# desktop into zram (that is what freezes the compositor, not CPU contention).
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

healthy() { curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }
healthy && { echo "port $PORT already answers — refusing to start a second server" >&2; exit 2; }

LOG="$SCRATCH/mxsrv-$(basename "$CFG" .env)-$$"
START="$(date -Iseconds)"
DEVLINE="$(dev_free_mib || true)"
FREE="${DEVLINE%% *}"; TOTAL="${DEVLINE##* }"
[ -n "${FREE:-}" ] || FREE=?
[ -n "${TOTAL:-}" ] || TOTAL=0
echo "[matrix-srv] engine=$ENGINE sha=$SHA ngl=$NGL ncmoe=$NCMOE ctx=$CTX kv=$KV cap=$CAP free=${FREE}MiB gpu=$(game_state) start=$START" >&2

WPID=""; POLL=""; SRV_PID=""
cleanup() {
    [ -n "$POLL" ] && { kill "$POLL" 2>/dev/null || true; POLL=""; } || true
    [ -n "$SRV_PID" ] && kill -TERM "$SRV_PID" 2>/dev/null || true
    [ -n "$WPID" ] && kill -TERM "$WPID" 2>/dev/null || true
    # belt-and-braces: the launched tree is timeout -> jobcap (systemd-run scope) ->
    # llama-server, so the server is NOT a child of WPID; also kill whatever still
    # listens on our port so no failure path can orphan a server holding VRAM.
    pkill -TERM -f "llama-server.*--port ${PORT}( |\$)" 2>/dev/null || true
    sleep 2
    [ -n "$SRV_PID" ] && kill -KILL "$SRV_PID" 2>/dev/null || true
    [ -n "$WPID" ] && kill -KILL "$WPID" 2>/dev/null || true
    pkill -KILL -f "llama-server.*--port ${PORT}( |\$)" 2>/dev/null || true
    return 0
}
trap cleanup EXIT INT TERM

srv_vram() { python3 "$HERE/arc-vram.py" 2>/dev/null | sed -n 's/.*used=\([0-9]*\).*/\1/p' | head -1; }

launch_and_wait() {   # $1 tag: cold|warm -> prints ms from launch to /health
    local tag="$1" t0 t1 ok=""
    # Wait for the port to be FREE (not merely unhealthy): the previous server can stop
    # answering /health while still holding the listening socket, and then this launch dies
    # with "couldn't bind HTTP server socket" and /health is answered by the OLD server —
    # which produced a bogus 7/15 ms "warm start" AND made the vision/tool rows look like
    # the model failed when it had never been asked. ss is the ground truth here.
    for _ in $(seq 1 90); do
        ss -ltn 2>/dev/null | grep -q ":$PORT " || break
        sleep 1
    done
    : > "$LOG.$tag.server"
    CAP="$CAP" MATRIX_RESULTS="$RESULTS" bash "$HERE/watchdog.sh" "$(basename "$CFG" .env)-srv-$tag" -- \
        timeout --kill-after=30 10800 ionice $IOCLASS_ARGS "$JUNK" "${CMD[@]}" >>"$LOG.$tag.server" 2>&1 &
    WPID=$!
    t0="$(date +%s%N)"
    for _ in $(seq 1 900); do
        kill -0 "$WPID" 2>/dev/null || { echo "server died during load — see $LOG.$tag.server" >&2; tail -20 "$LOG.$tag.server" >&2; return 1; }
        healthy && { ok=1; break; }
        sleep 1
    done
    t1="$(date +%s%N)"
    [ -n "$ok" ] || { echo "server not healthy after 900 s — see $LOG.$tag.server" >&2; tail -20 "$LOG.$tag.server" >&2; return 1; }
    echo "$(( (t1 - t0) / 1000000 ))"
}

PSI0="$(psi_now)"
cold_ms="$(launch_and_wait cold)" || exit 1
echo "[matrix-srv] cold start: ${cold_ms} ms" >&2
sleep 2; VRAM_COLD="$(srv_vram || echo 0)"
cleanup; WPID=""; SRV_PID=""; sleep 3

warm_ms="$(launch_and_wait warm)" || exit 1
echo "[matrix-srv] warm start: ${warm_ms} ms  vram_after_load=${VRAM_COLD}MiB" >&2
SRV_PID="$(pgrep -P "$WPID" 2>/dev/null | head -1 || true)"
# The launched tree is timeout -> jobcap (systemd-run scope) -> llama-server, so the
# server is NOT a direct child of WPID: pgrep -P returns nothing. Fall back to the
# process that listens on our port, and never read /proc for a bogus pid.
if [ -z "${SRV_PID:-}" ]; then
    SRV_PID="$(pgrep -nf "llama-server.*--port ${PORT}( |\$)" 2>/dev/null || true)"
fi
sleep 2; VRAM_WARM="$(srv_vram || echo 0)"
# The placement column must reflect the argv the server ACTUALLY ran with, not the
# config's placeholder — a lever or an env override can change -ngl/--n-cpu-moe.
ARGV=""
if [ -n "${SRV_PID:-}" ] && [ -r "/proc/$SRV_PID/cmdline" ]; then
    ARGV="$(tr '\0' ' ' < "/proc/$SRV_PID/cmdline" 2>/dev/null || true)"
fi
EFF_NGL="$(printf '%s' "$ARGV" | grep -oE -- '(-ngl|--n-gpu-layers) [0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
EFF_NCMOE="$(printf '%s' "$ARGV" | grep -oE -- '(-ncmoe|--n-cpu-moe) [0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
if [ -n "$EFF_NGL" ]; then PLACEMENT="ngl=${EFF_NGL}/ncmoe=${EFF_NCMOE:-0} (argv)"; fi

PEAKFILE="$LOG.peaks"; : > "$PEAKFILE"
poll() {
    local v r
    while kill -0 "$WPID" 2>/dev/null; do
        r=0
        v="$(pgrep -P "$WPID" 2>/dev/null | head -1 || true)"
        [ -n "$v" ] && [ -r "/proc/$v/status" ] && r="$(awk '/^VmHWM:/{print $2}' "/proc/$v/status" 2>/dev/null || echo 0)"
        printf '%s %s %s\n' "${r:-0}" "$(srv_vram || echo 0)" "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" >> "$PEAKFILE"
        sleep 1.5
    done
}

grep -iE 'offloading|assigned to device|n_ctx|kv cache|mmproj|speculat' "$LOG.warm.server" | head -14 >&2 || true

# ---- screenshot (inside the lock, taken before the vision requests) ---------
SHOT="$SCRATCH/mx-shot-$$.png"; SHOT_NOTE=""
if [ -n "$MMPROJ" ]; then
    if command -v grim >/dev/null 2>&1; then
        if timeout 30 grim "${GRIM_ARGS[@]}" "$SHOT" 2>"$SHOT.err" && [ -s "$SHOT" ]; then
            SHOT_NOTE="shot=$(stat -c%s "$SHOT")B $(file -b "$SHOT" 2>/dev/null | cut -c1-40)"
        else
            SHOT_NOTE="grim failed: $(head -c 120 "$SHOT.err" 2>/dev/null | tr '\n' ' ')"; SHOT=""
        fi
    else
        SHOT_NOTE="grim not installed"; SHOT=""
    fi
    echo "[matrix-srv] screenshot: $SHOT_NOTE" >&2
fi

poll & POLL=$!

MX_PORT="$PORT" MX_TOKENS="$PROMPT_TOKENS" MX_MAXTOK="$MAXTOK" MX_CTX="$CTX" MX_KV="$KV" \
MX_ENGINE="$ENGINE" MX_SHA="$SHA" MX_MODELNAME="$(basename "$MODEL" .gguf)" MX_QUANT="$QUANT" \
MX_PLACEMENT="$PLACEMENT" MX_NCMOE="$NCMOE" MX_THREADS="$THREADS" MX_FREE="$FREE" \
MX_TOTAL="$TOTAL" MX_VRAM_COLD="${VRAM_COLD:-0}" MX_VRAM_WARM="${VRAM_WARM:-0}" \
MX_NOTE="$NOTE" MX_RESULTS="$RESULTS" MX_HERE="$HERE" MX_START="$START" MX_SRCLOG="$LOG.warm.server" \
MX_COLD_MS="$cold_ms" MX_WARM_MS="$warm_ms" MX_SHOT="${SHOT:-}" MX_SHOT_NOTE="$SHOT_NOTE" \
MX_ELEMENT="${VISION_ELEMENT:-the clock in the top bar}" MX_NP="$NP" MX_MMPROJ="${MMPROJ:-}" \
MX_PROMPT_SRC="$PROMPT_SOURCE" MX_GAME="$(game_state)" MX_LOADMODE="$LOADMODE" python3 - <<'PY'
import base64, json, os, sys, time, urllib.request
sys.path.insert(0, os.environ["MX_HERE"])
from importlib import import_module
row = import_module("matrix-row")

env = os.environ
port = int(env["MX_PORT"])
srvlog = ""
try:
    srvlog = open(env["MX_SRCLOG"], errors="replace").read()
except OSError:
    pass
offl = " | ".join(dict.fromkeys(l.strip() for l in srvlog.splitlines()
                                if "offloading" in l and l.strip().startswith("load_tensors:")))[:240]
tail = (f" ncmoe={env['MX_NCMOE']} t={env['MX_THREADS']} np={env['MX_NP']} lm={env.get('MX_LOADMODE','?')} "
        f"prompt_src={os.path.basename(env.get('MX_PROMPT_SRC', '') or 'synthetic-filler')} "
        f"free_before={env['MX_FREE']}MiB vram_after_load={env['MX_VRAM_WARM']}MiB "
        f"headroom={int(env['MX_TOTAL'] or 0) - int(env['MX_VRAM_WARM'] or 0)}MiB gpu={env['MX_GAME']}"
        + (f" [{offl}]" if offl else "") + ((" " + env["MX_NOTE"]) if env["MX_NOTE"] else ""))
base = dict(timestamp=env["MX_START"], engine=env["MX_ENGINE"], git_sha=env["MX_SHA"],
            model=env["MX_MODELNAME"], quant=env["MX_QUANT"], placement=env["MX_PLACEMENT"],
            ctx=env["MX_CTX"], kv_type=env["MX_KV"], start=env["MX_START"],
            vram_used_mib=env["MX_VRAM_WARM"])

row.append(env["MX_RESULTS"], depth="", test="startup", tps_mean="", tps_std="",
           ttft_ms=env["MX_COLD_MS"], tool_call_pass="",
           notes=f"cold (first load) {int(env['MX_COLD_MS'])/1000:.1f}s vram_after_load={env['MX_VRAM_COLD']}MiB" + tail,
           **base)
row.append(env["MX_RESULTS"], depth="", test="startup", tps_mean="", tps_std="",
           ttft_ms=env["MX_WARM_MS"], tool_call_pass="",
           notes=f"warm (second load) {int(env['MX_WARM_MS'])/1000:.1f}s vram_after_load={env['MX_VRAM_WARM']}MiB" + tail,
           **base)


def post(body, timeout=3600):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


def stream(body):
    """-> (ttft_s, prompt_ms, prompt_tps, decode_tps, text) or None"""
    t0 = time.perf_counter(); ttft_s = None; timings = None; text = []
    with post(dict(body, stream=True)) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            ch = json.loads(line[6:])
            if ttft_s is None and ch.get("choices"):
                d = ch["choices"][0].get("delta", {}) or {}
                if d.get("content") or d.get("reasoning_content"):
                    ttft_s = time.perf_counter() - t0
            for c in (ch.get("choices") or []):
                t = (c.get("delta") or {}).get("content")
                if t:
                    text.append(t)
            if ch.get("timings"):
                timings = ch["timings"]
    if ttft_s is None or not timings:
        return None
    return (ttft_s, timings.get("prompt_ms", 0.0), timings.get("prompt_per_second", 0.0),
            timings.get("predicted_per_second", 0.0), "".join(text).strip())


# ---- TTFT + decode on filler prompts ---------------------------------------
# PROMPT_SOURCE: use real text (a local document) instead of the synthetic filler.
# The synthetic filler is one sentence repeated, which flatters n-gram/MTP
# speculation; realistic text is the honest prompt for the speed-lever rows.
_src = env.get("MX_PROMPT_SRC", "")
_real = None
if _src and os.path.exists(_src):
    try:
        _real = open(_src, errors="replace").read()
        print(f"prompt source: {_src} ({len(_real)} chars)", flush=True)
    except OSError:
        _real = None


def make_prompt(n):
    if _real:
        return (_real * (n * 4 // len(_real) + 1))[: n * 4]
    filler = ("Benchmark filler sentence number %d with a few extra words. " * 20) % 0
    return (filler * (n * 4 // len(filler) + 1))[: n * 4]


for n in [int(x) for x in env["MX_TOKENS"].split()]:
    prompt = make_prompt(n)
    got = None
    try:
        got = stream({"model": env["MX_MODELNAME"], "temperature": 0, "max_tokens": 128,
                      "messages": [{"role": "user", "content": prompt + "\nReply with one short sentence."}]})
    except Exception as e:
        print(f"ttft {n}: FAILED {e!r}", flush=True)
    if not got:
        row.append(env["MX_RESULTS"], depth=n, test="ttft", tps_mean="", tps_std="", ttft_ms="",
                   tool_call_pass="", notes=f"ttft@{n} FAILED (no stream/timings)" + tail, **base)
        continue
    ttft_s, pms, ptps, dtps, _ = got
    print(f"ttft {n}: {ttft_s:.3f}s prompt={ptps:.1f}tok/s decode={dtps:.2f}tok/s", flush=True)
    row.append(env["MX_RESULTS"], depth=n, test="ttft", tps_mean=f"{dtps:.2f}", tps_std="",
               ttft_ms=f"{ttft_s*1000:.1f}", tool_call_pass="",
               notes=f"prompt_tps={ptps:.2f} prompt_ms={pms:.0f}" + tail, **base)

# ---- vision: describe + pixel coordinates ----------------------------------
shot = env.get("MX_SHOT", "")
if shot and os.path.exists(shot):
    b64 = base64.b64encode(open(shot, "rb").read()).decode()
    img = {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}
    vtail = tail + f" shot={os.path.basename(shot)}"
    asks = (("vision-describe", "Describe everything you can see on this screen in two sentences."),
            ("vision-coords", "Return ONLY a JSON object {\"x\":int,\"y\":int} with the pixel coordinates of "
                              f"the center of {env['MX_ELEMENT']} in this screenshot, in the image's own pixel size."))
    for tag, ask in asks:
        got = None
        try:
            got = stream({"model": env["MX_MODELNAME"], "temperature": 0, "max_tokens": int(env["MX_MAXTOK"]),
                          "messages": [{"role": "user", "content": [img, {"type": "text", "text": ask}]}]})
        except Exception as e:
            print(f"{tag}: FAILED {e!r}", flush=True)
        if not got:
            row.append(env["MX_RESULTS"], depth="", test=tag, tps_mean="", tps_std="", ttft_ms="",
                       tool_call_pass="0", notes=f"{tag} FAILED" + vtail, **base)
            continue
        ttft_s, pms, ptps, dtps, full = got
        ok = ""; note = f"describe={full[:200]!r}"
        if tag == "vision-coords":
            ok = "0"; note = f"raw={full[:120]!r}"
            s, e = full.find("{"), full.rfind("}")
            if s >= 0 and e > s:
                try:
                    d = json.loads(full[s:e + 1])
                    if isinstance(d, dict) and all(k in d for k in ("x", "y")) and \
                       all(isinstance(d[k], (int, float)) for k in ("x", "y")):
                        ok = "1"; note = f"json={d}"
                except Exception as ex:
                    note = f"json parse failed: {ex}: {full[s:e+1][:80]!r}"
            print(f"{tag}: json_pass={ok} {note}", flush=True)
        else:
            print(f"{tag}: {full[:160]!r}", flush=True)
        row.append(env["MX_RESULTS"], depth="", test=tag, tps_mean=f"{dtps:.2f}", tps_std="",
                   ttft_ms=f"{ttft_s*1000:.1f}", tool_call_pass=ok,
                   notes=f"image_prompt_ms={pms:.0f} image_prompt_tps={ptps:.2f} {note}" + vtail, **base)
elif env.get("MX_MMPROJ"):
    row.append(env["MX_RESULTS"], depth="", test="vision-describe", tps_mean="", tps_std="",
               ttft_ms="", tool_call_pass="0",
               notes="vision skipped: " + (env.get("MX_SHOT_NOTE") or "no screenshot") + tail, **base)

# ---- ONE tool-call smoke test ----------------------------------------------
tools = [{"type": "function", "function": {
    "name": "get_weather", "description": "Get the current weather for a city",
    "parameters": {"type": "object", "properties": {"city": {"type": "string",
                 "description": "City name, e.g. Vienna"}}, "required": ["city"]}}}]
passed = 0; detail = ""
try:
    with post({"model": env["MX_MODELNAME"], "temperature": 0, "max_tokens": int(env["MX_MAXTOK"]),
               "messages": [{"role": "user", "content": "What is the weather in Vienna right now?"}],
               "tools": tools, "tool_choice": "auto"}) as r:
        resp = json.loads(r.read().decode())
    msg = (resp.get("choices") or [{}])[0].get("message", {}) or {}
    tcs = msg.get("tool_calls") or []
    if not tcs:
        detail = "no tool_calls in response; content=" + repr((msg.get("content") or "")[:160])
    else:
        fn = tcs[0].get("function", {}); args_raw = fn.get("arguments", "")
        try:
            args = json.loads(args_raw) if isinstance(args_raw, str) else args_raw
        except Exception as e:
            args = None; detail = f"arguments not valid JSON: {e}: {str(args_raw)[:120]!r}"
        if args is not None:
            city = str(args.get("city", ""))
            if fn.get("name") == "get_weather" and "vienna" in city.lower():
                passed = 1; detail = f"{fn.get('name')}({args})"
            else:
                detail = f"wrong tool/args: name={fn.get('name')!r} args={args}"
except Exception as e:
    detail = f"request failed: {e!r}"
print(f"toolcall pass={passed} {detail}", flush=True)
row.append(env["MX_RESULTS"], depth="", test="toolcall", tps_mean="", tps_std="", ttft_ms="",
           tool_call_pass=str(passed), notes=detail[:300] + tail, **base)
print("appended session rows to " + env["MX_RESULTS"])
PY

# ---- assistant block (ASSIST=1): describe + 2x EN answers + latency + PSI, same server, same lock ----
if [ "${ASSIST:-0}" = 1 ]; then
    hyprctl clients -j > "$SCRATCH/mx-titles-$$.json" 2>/dev/null || echo '[]' > "$SCRATCH/mx-titles-$$.json"
    MX_PORT="$PORT" MX_MODELNAME="$(basename "$MODEL" .gguf)" MX_SHOT="${SHOT:-}" \
    MX_TITLES="$SCRATCH/mx-titles-$$.json" MX_RESULTS="$RESULTS" MX_SCRATCH="$SCRATCH" \
    MX_TAG="$(basename "$MODEL" .gguf)-$ENGINE" MX_ENGINE="$ENGINE" MX_SHA="$SHA" MX_QUANT="$QUANT" \
    MX_PLACEMENT="$PLACEMENT" MX_CTX="$CTX" MX_KV="$KV" \
        python3 "$HERE/assistant-score.py" >&2 || echo "[matrix-srv] assistant-score FAILED (rc=$?)" >&2
fi

END="$(date -Iseconds)"
PSI1="$(psi_now)"
PSID="$(psi_delta "$PSI0" "$PSI1")"
sleep 1; kill "$POLL" 2>/dev/null || true; wait "$POLL" 2>/dev/null || true; POLL=""
PEAK_RSS_KIB="$(awk '{if($1>m)m=$1} END{print m+0}' "$PEAKFILE" 2>/dev/null || echo 0)"
PEAK_VRAM_MIB="$(awk '{if($2>m)m=$2} END{print m+0}' "$PEAKFILE" 2>/dev/null || echo 0)"
MEM_MIN_MIB="$(awk '$3>0{if(m==0||$3<m)m=$3} END{print int(m/1024)}' "$PEAKFILE" 2>/dev/null || echo 0)"
# one row for the whole session's memory/IO pressure (the metric that tracks the freezes)
python3 "$HERE/matrix-row.py" "$RESULTS" timestamp="$START" engine="$ENGINE" git_sha="$SHA" \
    model="$(basename "$MODEL" .gguf)" quant="$QUANT" placement="$PLACEMENT" ctx="$CTX" kv_type="$KV" \
    test="psi-session" tps_mean="" peak_rss_gib="$(awk -v k="$PEAK_RSS_KIB" 'BEGIN{printf "%.2f", k/1048576}')" \
    vram_used_mib="$PEAK_VRAM_MIB" start="$START" end="$END" \
    notes="lm=$LOADMODE $PSID mem_min=${MEM_MIN_MIB}MiB peak_vram=${PEAK_VRAM_MIB}MiB ncmoe=$NCMOE np=$NP prompt_src=$(basename "${PROMPT_SOURCE:-synthetic}")" >/dev/null
echo "[matrix-srv] peak_rss=$(( PEAK_RSS_KIB / 1048576 ))GiB peak_vram_used=${PEAK_VRAM_MIB}MiB mem_min=${MEM_MIN_MIB}MiB $PSID end=$END" >&2
cleanup; trap - EXIT
sleep 2
if pgrep -f "llama-serve[r].*--port $PORT( |$)" >/dev/null 2>&1; then
    echo "WARNING: something still answers for --port $PORT — check by hand" >&2
fi
exit 0
