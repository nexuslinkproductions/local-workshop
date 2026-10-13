#!/usr/bin/env bash
# bench.sh — run llama-bench for ONE config, append rows to bench/results.tsv.
#
#   bench.sh configs/<name>.env            # run (serialized on bench/.gpu.lock)
#   bench.sh configs/<name>.env --check    # gate + flag lint only, no GPU use
#   bench.sh configs/<name>.env --probe    # tiny tests, record NO rows (fit checks)
#   bench.sh configs/<name>.env --force    # run even if a llama-server holds the GPU
#
# Config vars (see configs/*.env):
#   BIN     llama-bench path   (relative to LOCAL-AI-LAB, or absolute)
#   MODEL   GGUF path          (relative to LOCAL-AI-LAB, or absolute)
#   NGL     -ngl value
#   EXTRA   extra llama-bench flags          (optional)
#   NOTE    free-text VRAM note for results.tsv (optional)
#   DEPTHS 0,4096   PROMPT 512   GEN 128   REPS 5        (optional overrides)
# Any of NGL/DEPTHS/PROMPT/GEN/REPS can be overridden per run from the
# environment as <VAR>_OVERRIDE=<value> — that is how fit-ngl.sh probes.
#
# Build pinned to Vulkan0 (Arc B580). Vulkan1 is the Ryzen iGPU — never bench it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(dirname "$HERE")"
RESULTS="$HERE/results.tsv"
DEVICE="${DEVICE:-Vulkan0}"
. "$HERE/gate.sh"

# GPU mutex: every run serializes on one lock file, so other agents' runs and
# mine queue instead of fighting for VRAM. --check is lint-only, so it skips the
# lock and never waits behind a long run.
case " $* " in *" --check "*) ;; *)
    if [ -z "${BENCH_LOCKED:-}" ]; then
        export BENCH_LOCKED=1
        exec flock -x -w 3600 "$LOCK_FILE" "$0" "$@"
    fi ;;
esac

cfg="" probe="" force=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force) force=--force ;;
        --probe) probe=1 ;;
        --check) CHECK=1 ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) echo "unknown flag: $1" >&2; exit 2 ;;
        *)  cfg="$1" ;;
    esac
    shift
done
[ -n "$cfg" ] || { echo "usage: bench.sh configs/<name>.env [--check] [--probe] [--force]" >&2; exit 2; }
[ -f "$cfg" ] || cfg="$HERE/$cfg"
[ -f "$cfg" ] || { echo "config not found: $cfg" >&2; exit 2; }
CONFIG_NAME="$(basename "$cfg" .env)"

# ---- config ----------------------------------------------------------------
BIN=""; MODEL=""; NGL=""; EXTRA=""; NOTE=""
DEPTHS="0,4096"; PROMPT=512; GEN=128; REPS=5
# shellcheck source=/dev/null
. "$cfg"
for k in NGL DEPTHS PROMPT GEN REPS; do                      # <VAR>_OVERRIDE wins
    o="${k}_OVERRIDE"
    [ -n "${!o:-}" ] && printf -v "$k" '%s' "${!o}"
done

resolve() { [ -e "$1" ] && printf '%s' "$1" || printf '%s' "$LAB_ROOT/$1"; }
BIN="$(resolve "$BIN")"
MODEL="$(resolve "$MODEL")"
[ -x "$BIN" ]   || { echo "not executable: $BIN" >&2; exit 2; }
[ -f "$MODEL" ] || { echo "model not found: $MODEL" >&2; exit 2; }

# git sha of the build the binary came from (walk up to the repo root)
git_sha_of() {
    local d; d="$(dirname "$1")"
    while [ "$d" != "/" ]; do
        [ -d "$d/.git" ] && { git -C "$d" rev-parse --short HEAD 2>/dev/null; return; }
        d="$(dirname "$d")"
    done
    echo unknown
}
SHA="$(git_sha_of "$BIN")"

# ---- flags -----------------------------------------------------------------
# shellcheck disable=SC2206
EXTRA_ARR=($EXTRA)
CORE_FLAGS=(-m "$MODEL" -p "$PROMPT" -n "$GEN" -d "$DEPTHS" -ngl "$NGL"
            -r "$REPS" -o json --device "$DEVICE")
if [ -n "${CHECK:-}" ]; then
    lint_flags "$BIN" "${CORE_FLAGS[@]}" "${EXTRA_ARR[@]}" || exit 1
    echo "check ok: $CONFIG_NAME — every flag present in $BIN --help"
    echo "           depths=$DEPTHS prompt=$PROMPT gen=$GEN reps=$REPS ngl=$NGL device=$DEVICE extra='$EXTRA'"
    exit 0
fi

gate_check "$force" || exit 3

# ---- run -------------------------------------------------------------------
# Free VRAM + game state go into vram_note: a row taken with the game open is not
# comparable to a clean-GPU row, and the row has to say so.
VRAM="$(vram_free_mib "$BIN" || true)"
VRAM_NOTE="free=${VRAM%% *}MiB/${VRAM##* }MiB Vulkan0 $(game_state)"
[ -n "${VRAM%% *}" ] || VRAM_NOTE="free=?MiB unknown"
NOTE="${VRAM_NOTE} ngl=$NGL${NOTE:+ | $NOTE}"
[ -n "$probe" ] && NOTE="PROBE $NOTE"

ts="$(date -Iseconds)"
EPOCH="$(date +%s)"
echo "bench: $CONFIG_NAME  sha=$SHA  ngl=$NGL  depth=$DEPTHS  reps=$REPS  $NOTE" >&2
out="$("$BIN" "${CORE_FLAGS[@]}" "${EXTRA_ARR[@]}")" || rc=$?
[ -n "${out:-}" ] || { echo "llama-bench produced no output (rc=${rc:-0}) — did not fit / failed to load" >&2; exit 1; }

if [ -n "$probe" ]; then
    printf '%s' "$out" | python3 -c 'import json,sys; print("probe loaded:", len(json.load(sys.stdin)), "test(s)")'
    echo "end=$(date -Iseconds) (start=$ts, elapsed=$(( $(date +%s) - EPOCH ))s)" >&2
    exit "${rc:-0}"
fi

printf '%s' "$out" | BENCH_TS="$ts" BENCH_SHA="$SHA" BENCH_CFG="$CONFIG_NAME" \
BENCH_MODEL="$(basename "$MODEL")" BENCH_NOTE="$NOTE" BENCH_RESULTS="$RESULTS" \
python3 "$HERE/parse-bench.py"
echo "end=$(date -Iseconds) (start=$ts, elapsed=$(( $(date +%s) - EPOCH ))s)" >&2
[ "${rc:-0}" = 0 ] || { echo "note: llama-bench exited $rc (some tests failed, rows above are the ones that ran)" >&2; exit "$rc"; }
