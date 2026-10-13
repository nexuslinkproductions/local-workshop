#!/usr/bin/env bash
# vulkan-tip-bench.sh — run llama-bench for ONE (engine, model, ngl) config and
# append rows to bench/results-vulkan-tip.tsv.
#
#   vulkan-tip-bench.sh ENGINE BIN MODEL NGL GPU_STATE [DEPTHS] [PROMPT] [GEN] [REPS]
#   vulkan-tip-bench.sh --probe ENGINE BIN MODEL NGL GPU_STATE   # load-only check
#
# ENGINE is a free-text lane label (e.g. stock-tip / stock-old / prism-tip).
# GPU_STATE is game-open|clean, recorded verbatim next to every row.
#
# HARD RULE (Marcel): only ONE test at a time. This script self-wraps in
# `flock -x bench/.gpu.lock`, so the free-VRAM read and the llama-bench run are
# one exclusive unit. Builds hold the same lock shared, so a test waits for them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$HERE/.gpu.lock"
RESULTS="$HERE/results-vulkan-tip.tsv"
DEVICE="${DEVICE:-Vulkan0}"

# ---- self-wrap in the exclusive lock (once) ---------------------------------
if [ -z "${VT_LOCKED:-}" ]; then
    export VT_LOCKED=1
    exec flock -x "$LOCK" "$0" "$@"
fi

PROBE=0
if [ "${1:-}" = "--probe" ]; then PROBE=1; shift; fi

ENGINE="$1"; BIN="$2"; MODEL="$3"; NGL="$4"; GPU_STATE="$5"
DEPTHS="${6:-0,4096}"; PROMPT="${7:-512}"; GEN="${8:-128}"; REPS="${9:-5}"
CLI="$(dirname "$BIN")/llama-cli"

[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 2; }
[ -f "$MODEL" ] || { echo "model not found: $MODEL" >&2; exit 2; }

# ---- who else is on the GPU? (informational; must be something I started) ---
OTHERS="$(pgrep -af 'llama-(bench|server)|benchmark_genai' 2>/dev/null | grep -v "$$" || true)"
[ -n "$OTHERS" ] && echo "NOTE: other llama procs visible at test start:" >&2 && echo "$OTHERS" >&2

# ---- free VRAM snapshot from this build's own device list -------------------
free_mib() {
    "$CLI" --list-devices 2>&1 | sed -n 's/.*Vulkan0:.*(\([0-9]\+\) MiB, \([0-9]\+\) MiB free).*/\2/p' | head -1
}
FREE="$(free_mib || true)"; [ -n "$FREE" ] || FREE="na"

SHA="$(git -C "$(dirname "$BIN")" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# walk up to repo root if the binary dir is not itself in a work tree
if [ "$SHA" = unknown ]; then
    d="$(dirname "$BIN")"
    while [ "$d" != / ]; do [ -e "$d/.git" ] && { SHA="$(git -C "$d" rev-parse --short HEAD)"; break; }; d="$(dirname "$d")"; done
fi

START="$(date -Iseconds)"
echo "[bench] engine=$ENGINE sha=$SHA ngl=$NGL depths=$DEPTHS free_vram=${FREE}MiB gpu=$GPU_STATE start=$START" >&2

if [ "$PROBE" = 1 ]; then
    # load-only: tiny work, -r 1; succeeds iff the model fits at this -ngl
    if "$BIN" -m "$MODEL" -p 4 -n 4 -d 0 -ngl "$NGL" -r 1 -o json --device "$DEVICE" -fa 1 >/tmp/vt-probe.json 2>/tmp/vt-probe.err; then
        echo "PROBE OK ngl=$NGL engine=$ENGINE"; tail -3 /tmp/vt-probe.err >&2
    else
        echo "PROBE FAIL ngl=$NGL engine=$ENGINE"; grep -iE 'oom|out of|error|fail' /tmp/vt-probe.err | head -3 >&2; exit 1
    fi
    exit 0
fi

OUT="$("$BIN" -m "$MODEL" -p "$PROMPT" -n "$GEN" -d "$DEPTHS" -ngl "$NGL" -r "$REPS" -o json --device "$DEVICE" -fa 1)" || true
[ -n "$OUT" ] || { echo "no output from llama-bench" >&2; exit 1; }

TS="$START" ENGINE_ENV="$ENGINE" SHA_ENV="$SHA" NGL_ENV="$NGL" \
FREE_ENV="$FREE" GPU_ENV="$GPU_STATE" MODEL_ENV="$(basename "$MODEL")" RESULTS_ENV="$RESULTS" \
python3 - "$OUT" <<'PY'
import json, os, sys
data = json.loads(sys.argv[1])
if isinstance(data, dict): data = data.get("results", [])
path = os.environ["RESULTS_ENV"]
first = not os.path.exists(path) or os.path.getsize(path) == 0
rows = []
for r in data:
    np_, ng = r.get("n_prompt", 0), r.get("n_gen", 0)
    rows.append([os.environ["TS"], os.environ["ENGINE_ENV"], os.environ["SHA_ENV"],
                 os.environ["MODEL_ENV"], os.environ["NGL_ENV"], str(r.get("n_depth", 0)),
                 f"pp{np_}" if np_ else f"tg{ng}",
                 f"{float(r['avg_ts']):.2f}", f"{float(r.get('stddev_ts', 0.0)):.2f}",
                 os.environ["FREE_ENV"], os.environ["GPU_ENV"]])
with open(path, "a") as f:
    if first:
        f.write("timestamp\tengine\tgit_sha\tmodel_file\tngl\tdepth\ttest\ttps_mean\ttps_std\tfree_vram_mib\tgpu_state\n")
    for row in rows:
        f.write("\t".join(row) + "\n")
print(f"appended {len(rows)} rows to {path}")
PY

echo "[bench] done $(date -Iseconds)" >&2
