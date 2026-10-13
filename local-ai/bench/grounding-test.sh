#!/usr/bin/env bash
# grounding-test.sh — real GUI-grounding score for one model+projector config.
#
# Builds a synthetic 1920x1080 "UI" with N labeled targets at KNOWN bounding boxes,
# asks the model for each target's centre, and scores a HIT only if the returned
# point falls INSIDE the target box. Both interpretations are accepted and recorded:
#   abs  = the value is treated as image pixels
#   norm = the value is treated as a 0-1000 grid (Qwen3-VL family convention)
# A JSON that merely parses is NOT a pass (that was the earlier false-positive).
#
#   grounding-test.sh --cfg configs/<name>.env [--max-tok 256]
#                     [--img F --targets F] [--crop none|topstrip|quadrant|both]
#                     [--min-img-tokens 1024]
#
# --crop (crop-and-zoom): send a SMALL region upscaled 2x instead of the full screen
# and map the predicted point back to full-screen coords before scoring. Two
# strategies, scored independently (one grounding-<strategy> row each):
#   topstrip = 1920x270 top strip, x2   (the top bar: clock, tab strip, window label)
#   quadrant = the 960x540 quadrant holding the target, x2
#   both     = run topstrip and quadrant
# --min-img-tokens N appends `--image-min-tokens N` (default 1024; the server warns
# Qwen-VL models need >=1024 for grounding). Skipped if the config's EXTRA sets it.
#
# Rule 2: the server is started, queried and killed inside ONE exclusive-lock call.
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

CFG=""; MAXTOK=256; IMG_OVR=""; TARGETS_OVR=""; CROP="none"; MINIMG=1024
while [ $# -gt 0 ]; do
    case "$1" in
        --cfg) CFG="$2"; shift ;;
        --max-tok) MAXTOK="$2"; shift ;;
        --img) IMG_OVR="$2"; shift ;;
        --targets) TARGETS_OVR="$2"; shift ;;
        --crop) CROP="$2"; shift ;;
        --min-img-tokens) MINIMG="$2"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$CFG" ] || { echo "--cfg required" >&2; exit 2; }
[ -f "$CFG" ] || CFG="$HERE/$CFG"
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 2; }

ENGINE=""; BINDIR=""; MODEL=""; QUANT=""; NGL=99; CTX=65536; KV="q8_0"; THREADS=16
CAP="26G"; NCMOE=0; NOTE=""; PORT=18090; NP=1; EXTRA=(); SERVER_EXTRA=(); MMPROJ=""
DEVICE_NAME=""; ENVSH=""
# shellcheck source=/dev/null
. "$CFG"
resolve() { [ -e "$1" ] && printf '%s' "$1" || printf '%s' "$LAB_ROOT/$1"; }
[ -n "$ENVSH" ] && { # shellcheck source=/dev/null
    . "$(resolve "$ENVSH")"; }
[ -n "$DEVICE_NAME" ] && DEVICE="$DEVICE_NAME"
BINDIR="$(resolve "$BINDIR")"; MODEL="$(resolve "$MODEL")"
[ -n "$MMPROJ" ] && MMPROJ="$(resolve "$MMPROJ")"
SRV="$BINDIR/llama-server"; CLI="$BINDIR/llama-cli"
SHA="$(git -C "$BINDIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --image-min-tokens: never below the Qwen-VL grounding floor unless the config
# already carries the flag (then the config wins, no duplicate).
if [ "${MINIMG:-0}" -gt 0 ] && ! printf ' %s ' "${EXTRA[@]:-}" | grep -q -- '--image-min-tokens'; then
    EXTRA+=("--image-min-tokens" "$MINIMG")
fi

waited=0
while game_running; do
    [ "$waited" -ge "${MAX_WAIT:-28800}" ] && { echo "game running — giving up" >&2; exit 3; }
    sleep 120; waited=$(( waited + 120 ))
done
gate_check || exit 3
healthy() { curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }
healthy && { echo "port $PORT already answers — refusing" >&2; exit 2; }

KVARR=(-fa on -ctk "$KV" -ctv "$KV")
NCMOEARR=(); [ "${NCMOE:-0}" -gt 0 ] && NCMOEARR=(-ncmoe "$NCMOE")
MMARG=(); [ -n "$MMPROJ" ] && MMARG=(--mmproj "$MMPROJ")
LOG="$SCRATCH/gt-$(basename "$CFG" .env)-$$"
IMG="$SCRATCH/gt-page-1920x1080.png"
TARGETS="$SCRATCH/gt-targets.tsv"

WPID=""; SRV_PID=""; POLL=""
cleanup() {
    [ -n "$POLL" ] && { kill "$POLL" 2>/dev/null || true; POLL=""; } || true
    pkill -TERM -f "llama-server.*--port ${PORT}( |\$)" 2>/dev/null || true
    [ -n "$WPID" ] && kill -TERM "$WPID" 2>/dev/null || true
    sleep 2
    pkill -KILL -f "llama-server.*--port ${PORT}( |\$)" 2>/dev/null || true
    [ -n "$WPID" ] && kill -KILL "$WPID" 2>/dev/null || true
    return 0
}
trap cleanup EXIT INT TERM

# ---- ground truth: 1920x1080 page, labeled targets at known boxes -----------
if [ -n "$IMG_OVR" ] && [ -n "$TARGETS_OVR" ]; then
    IMG="$IMG_OVR"; TARGETS="$TARGETS_OVR"
    [ -f "$IMG" ] && [ -f "$TARGETS" ] || { echo "img/targets not found" >&2; exit 2; }
    echo "[grounding] using supplied image $IMG + targets $TARGETS" >&2
else
    python3 "$HERE/grounding-gen.py" "$IMG" "$TARGETS"
fi

echo "[grounding] $ENGINE sha=$SHA model=$(basename "$MODEL") ncmoe=$NCMOE crop=$CROP port=$PORT start=$(date -Iseconds)" >&2
START_EPOCH="$(date +%s)"
CAP="$CAP" timeout --kill-after=30 3600 ionice $IOCLASS_ARGS "$JUNK" "$SRV" -m "$MODEL" -ngl "$NGL" "${NCMOEARR[@]}" \
    -c "$CTX" -np "$NP" -t "$THREADS" "${KVARR[@]}" --device "$DEVICE" \
    --host 127.0.0.1 --port "$PORT" "${MMARG[@]}" "${EXTRA[@]}" \
    --temp 0 --repeat-penalty 1.05 -fit off ${SERVER_EXTRA[@]+"${SERVER_EXTRA[@]}"} >"$LOG.server" 2>&1 &
WPID=$!
ok=""
for _ in $(seq 1 900); do
    kill -0 "$WPID" 2>/dev/null || { echo "server died — see $LOG.server" >&2; tail -15 "$LOG.server" >&2; exit 1; }
    healthy && { ok=1; break; }
    sleep 1
done
[ -n "$ok" ] || { echo "server not healthy in 900 s" >&2; exit 1; }
echo "[grounding] server healthy" >&2

MX_PORT="$PORT" MX_IMG="$IMG" MX_TARGETS="$TARGETS" MX_MAXTOK="$MAXTOK" MX_LOG="$LOG.server" \
MX_ENGINE="$ENGINE" MX_SHA="$SHA" MX_MODELNAME="$(basename "$MODEL" .gguf)" MX_QUANT="$QUANT" \
MX_PLACEMENT="ngl=$NGL/ncmoe=$NCMOE" MX_NCMOE="$NCMOE" MX_THREADS="$THREADS" MX_CTX="$CTX" \
MX_KV="$KV" MX_RESULTS="$RESULTS" MX_HERE="$HERE" MX_MMPROJ="$(basename "${MMPROJ:-none}")" \
MX_DEVICE="$DEVICE" MX_CROP="$CROP" MX_SCRATCH="$SCRATCH" \
MX_DUMP="$SCRATCH/gt-dump-$(basename "$CFG" .env)-$$.tsv" python3 - <<'PY'
import base64, json, os, re, subprocess, sys, time, urllib.request
sys.path.insert(0, os.environ["MX_HERE"])
from importlib import import_module
row = import_module("matrix-row")
gs = import_module("grounding-score")  # the ONE scorer; grounding-rescore.py uses the same code
env = os.environ
port = int(env["MX_PORT"]); max_tok = int(env["MX_MAXTOK"])
targets = gs.parse_targets(env["MX_TARGETS"])
strategies = [s for s in env.get("MX_CROP", "none").replace("both", "topstrip,quadrant").split(",") if s]
dump = []
gs.selftest()  # map-back, region and cover/hit invariants: a bug here scores wrong points silently
region_for = gs.region_for

_cache = {}
def prep(strategy, box):
    """Crop+upscale (or the full image for 'none'); -> (b64, rx, ry, rw, rh, scale, path)."""
    key = (strategy, box)
    if key in _cache:
        return _cache[key]
    rx, ry, rw, rh, scale = region_for(strategy, box)
    if strategy == "none":
        path = env["MX_IMG"]
    else:
        # The crop MUST be keyed by the SOURCE image too: the same region of a different
        # screenshot is a different image. Keying by region alone made a synthetic-page
        # run silently reuse crops of the real-desktop screenshot (harness bug, fixed).
        src = os.path.basename(env["MX_IMG"])
        path = os.path.join(env["MX_SCRATCH"], f"gtcrop-{src}-{strategy}-{rx}-{ry}-{rw}x{rh}.png")
        subprocess.run(["magick", env["MX_IMG"], "-crop", f"{rw}x{rh}+{rx}+{ry}",
                        "+repage", "-resize", f"{int(scale * 100)}%", "-depth", "8", path], check=True)
    b64 = base64.b64encode(open(path, "rb").read()).decode()
    _cache[key] = (b64, rx, ry, rw, rh, scale, path)
    return _cache[key]

LAST = {}  # per-request meta of the last ask(): finish_reason, completion tokens, reasoning chars
def ask(b64, prompt):
    body = {"model": env["MX_MODELNAME"], "temperature": 0, "max_tokens": max_tok,
            "messages": [{"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
                {"type": "text", "text": prompt}]}]}
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=1200) as r:
        d = json.loads(r.read().decode())
    dt = time.perf_counter() - t0
    ch = (d.get("choices") or [{}])[0]; msg = ch.get("message", {}) or {}
    txt = msg.get("content") or ""
    LAST.clear()
    LAST.update(finish=ch.get("finish_reason"), ctok=(d.get("usage") or {}).get("completion_tokens"),
                rchars=len(msg.get("reasoning_content") or ""))
    return txt, (d.get("timings") or {}), dt

def parse_point(txt):
    """Pull a point out of any common grounding answer shape:
    {"x":..,"y":..} | [{"point_2d":[x,y]}] | [{"bbox_2d":[x1,y1,x2,y2]}] | fenced JSON.
    Returns (x, y) or None. A parse failure is NOT a grounding miss."""
    t = re.sub(r"```(?:json)?", "", txt).replace("```", "").strip()
    dec = json.JSONDecoder()
    objs, i = [], 0
    while i < len(t):
        starts = [k for k in (t.find("{", i), t.find("[", i)) if k >= 0]
        if not starts:
            break
        j = min(starts)
        try:
            o, k = dec.raw_decode(t, j)
            objs.append(o)
            i = k
        except Exception:
            i = j + 1
    for o in objs:
        cands = []

        def walk(v):
            if isinstance(v, dict):
                if "x" in v and "y" in v:
                    try:
                        cands.append((int(v["x"]), int(v["y"])))
                    except Exception:
                        pass
                p = v.get("point_2d") or v.get("point")
                if isinstance(p, list) and len(p) >= 2:
                    try:
                        cands.append((int(p[0]), int(p[1])))
                    except Exception:
                        pass
                b = v.get("bbox_2d") or v.get("bbox")
                if isinstance(b, list) and len(b) >= 4:
                    try:
                        cands.append((int((b[0] + b[2]) / 2), int((b[1] + b[3]) / 2)))
                    except Exception:
                        pass
                for x in v.values():
                    walk(x)
            elif isinstance(v, list):
                for x in v:
                    walk(x)

        walk(o)
        if cands:
            return cands[0]
    return None


def score(strategy):
    """Ask for every target on this strategy's crop; hand the answers to gs.score() unchanged.
    -> (gs.score result, peak image tokens, peak prefill ms, dump rows)."""
    answers, rows, peak_tok, peak_pre, metas = {}, [], 0, 0.0, []
    for lab, box, cls in targets:
        b64, rx, ry, rw, rh, scale, cpath = prep(strategy, box)
        crop = f"{rx},{ry},{rw},{rh}"
        prompt = ("Return ONLY a JSON object {\"x\":int,\"y\":int} with the centre coordinates of the "
                  f"'{lab}' element in this screenshot, in the image's own pixel size.")
        try:
            txt, tim, _dt = ask(b64, prompt)
        except Exception as e:
            answers[lab] = (f"ERR {e!r}", None, repr(e)); metas.append({})
            rows.append((strategy, lab, cls, crop, scale, cpath, f"ERR {e!r}", "", "", ""))
            continue
        metas.append(dict(LAST))
        if tim:
            peak_tok = max(peak_tok, int(tim.get("prompt_n") or 0))
            peak_pre = max(peak_pre, float(tim.get("prompt_ms") or 0.0))
        pt = parse_point(txt)
        flat = txt[:200].replace("\t", " ").replace("\n", " ")
        answers[lab] = (flat, pt, None if pt else "nojson")
        if pt is None:
            rows.append((strategy, lab, cls, crop, scale, cpath, flat, "nojson", "", ""))
        else:
            ax, ay = gs.map_back(pt[0], pt[1], rx, ry, rw, rh, scale, "abs")
            nx, ny = gs.map_back(pt[0], pt[1], rx, ry, rw, rh, scale, "norm")
            rows.append((strategy, lab, cls, crop, scale, cpath, flat, f"{pt[0]},{pt[1]}",
                         f"{ax:.0f},{ay:.0f}", f"{nx:.0f},{ny:.0f}"))
    return gs.score(strategy, targets, answers), peak_tok, peak_pre, rows, metas

hit = lambda b: "HIT" if b else "miss"
for strategy in strategies:
    r, peak_tok, peak_pre, rows, metas = score(strategy)
    assert sum(v[0] for v in r["by_class"].values()) == r["n"] == len(targets), r
    assert sum(v[1] for v in r["by_class"].values()) == r["hits"] and r["hits"] <= r["covered"], r
    dump += [rw + (hit(p["abs"]), hit(p["norm"]), m.get("finish", ""), m.get("ctok", ""), m.get("rchars", ""))
             for rw, p, m in zip(rows, r["per"], metas)]
    tok_txt = f"img_tokens={peak_tok}" if peak_tok else "img_tokens=?"
    pre_txt = f"img_prefill={peak_pre/1000:.1f}s" if peak_pre else "img_prefill=?"
    extra = (f"{tok_txt} {pre_txt} img={os.path.basename(env['MX_IMG'])} projector={env['MX_MMPROJ']} "
             f"ncmoe={env['MX_NCMOE']} dev={env['MX_DEVICE']}")
    tool, note = gs.summary(strategy, r, extra=extra)
    print(f"[grounding:{strategy}] {note}")
    row.append(env["MX_RESULTS"], timestamp=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
               engine=env["MX_ENGINE"], git_sha=env["MX_SHA"], model=env["MX_MODELNAME"],
               quant=env["MX_QUANT"], placement=env["MX_PLACEMENT"], ctx=env["MX_CTX"],
               kv_type=env["MX_KV"], depth="", test=f"grounding-{strategy}", tps_mean="", tps_std="",
               ttft_ms="", tool_call_pass=tool, notes=note,
               start=time.strftime("%Y-%m-%dT%H:%M:%S%z"))

# full per-target audit trail (crop region + crop file + RAW model reply) so a reviewer
# can inspect exactly what was sent and what came back for every scored point.
_dp = env.get("MX_DUMP", "")
if _dp and dump:
    with open(_dp, "w") as f:
        f.write("strategy\tlabel\tclass\tcrop\tscale\tcrop_file\traw_reply\tparsed_xy\tabs_xy\tnorm_xy\tabs\tnorm\tfinish_reason\tcompletion_tokens\treasoning_chars\n")
        for r in dump:
            f.write("\t".join(str(x) for x in r) + "\n")
    print(f"[grounding] audit trail: {_dp} ({len(dump)} rows)")
PY

echo "[grounding] done $(date -Iseconds)" >&2
cleanup; trap - EXIT
sleep 2

# GPU-reset guard (hard stop): a device reset during a test invalidates it AND can take
# Marcel's monitors down. Record the config as GPU-RESET and never retry it.
if journalctl -k --since "@$START_EPOCH" 2>/dev/null | grep -qiE 'GT0: reset started|DEVICE_LOST|reset queued'; then
    python3 "$HERE/matrix-row.py" "$RESULTS" timestamp="$(date -Iseconds)" \
        engine="$ENGINE" git_sha="$SHA" model="$(basename "$MODEL" .gguf)" quant="$QUANT" \
        placement="ngl=$NGL/ncmoe=$NCMOE" ctx="$CTX" kv_type="$KV" test="GPU-RESET" \
        tps_mean="" notes="GPU-RESET during this config (xe GT0 reset / DEVICE_LOST) — do NOT retry this engine+arch" >/dev/null
    echo "[grounding] *** GPU RESET DETECTED — recorded GPU-RESET row, stopping ***" >&2
    exit 9
fi
exit 0
