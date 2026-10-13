#!/usr/bin/env bash
# ============================================================================
# setup-llm.sh — build & verify the LOCAL AI LAB llama.cpp stack
#
#   * stock llama.cpp (master) + Vulkan        -> llm/llama.cpp/build/bin
#   * PrismML-Eng fork, branch `prism` + Vulkan -> llm/llama.cpp-prism/build/bin
#     (required for Ternary-Bonsai PQ2_0 quants; stock builds cannot load them)
#
# Target GPU: Intel Arc B580 12GB (Xe2) via the Vulkan backend (ANV driver).
#
# Usage:
#   bash setup-llm.sh              # full pipeline: clone, build, verify, bench
#   bash setup-llm.sh --build-only # skip model-load tests
#   SKIP_BENCH=1 bash setup-llm.sh # skip llama-bench runs
#
# Output: BUILD-REPORT.txt next to this script; per-run logs in ./logs/.
# Re-runnable: existing clones/builds are reused (incremental).
# ============================================================================
set -uo pipefail   # NOTE: no -e; we want to continue and report failures

LLM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "$LLM_DIR")"
MODELS_DIR="$LAB_DIR/models/llm"
OBLIT_GGUF="$MODELS_DIR/Qwen3.8-27B-OBLITERATED/Qwen3.8-27B-OBLITERATED-IQ4_XS.gguf"
BONSAI_GGUF="$MODELS_DIR/bonsai/Ternary-Bonsai-2-27B-PQ2_0.gguf"
STOCK_DIR="$LLM_DIR/llama.cpp"
PRISM_DIR="$LLM_DIR/llama.cpp-prism"
LOG_DIR="$LLM_DIR/logs"
REPORT="$LLM_DIR/BUILD-REPORT.txt"
JOBS="$(nproc 2>/dev/null || echo 8)"

mkdir -p "$LOG_DIR"
: > "$REPORT"

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$REPORT"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
section() { log ""; log "=== $* ==="; }

# 0. dependency check
section "0. Dependencies"
MISSING=0
for t in git cmake ninja gcc g++ vulkaninfo curl; do
  if have "$t"; then log "  ok      $t ($(command -v "$t"))"; else log "  MISSING $t"; MISSING=1; fi
done
# python3 is optional (pretty-prints chat timings; raw JSON is dumped without it)
if have python3; then log "  ok      python3"; else log "  note: no python3 — chat timing parse will be skipped"; fi
# shaderc: glslc is needed to compile the Vulkan shaders at build time
if have glslc; then log "  ok      glslc ($(command -v glslc))"; else log "  MISSING glslc (pacman -S shaderc)"; MISSING=1; fi
if [ "$MISSING" -eq 1 ]; then log "FATAL: install missing tools first (no sudo allowed here)."; exit 1; fi

# Vulkan driver sanity — want to see the B580 as a physical device
section "0b. vulkaninfo --summary"
vulkaninfo --summary > "$LOG_DIR/vulkaninfo.txt" 2>&1 || true
grep -iE "deviceName|apiVersion|driver" "$LOG_DIR/vulkaninfo.txt" | head -20 | tee -a "$REPORT" || true
if grep -qi "B580" "$LOG_DIR/vulkaninfo.txt"; then
  log "  -> Arc B580 visible to Vulkan"
else
  log "  -> WARNING: 'B580' not found in vulkaninfo output — check intel-compute-runtime / vulkan-intel"
fi

# ---------------------------------------------------------------------------
clone_or_update() { # $1 url  $2 dir  $3 branch(optional)
  local url="$1" dir="$2" br="${3:-}"
  if [ -d "$dir/.git" ]; then
    log "  exists: $dir (leaving as-is; run 'git -C \"$dir\" pull' to update)"
  else
    log "  cloning $url ${br:+(-b $br) }-> $dir"
    if [ -n "$br" ]; then
      git clone -b "$br" "$url" "$dir" || { log "  FATAL: clone failed"; return 1; }
    else
      git clone "$url" "$dir" || { log "  FATAL: clone failed"; return 1; }
    fi
  fi
  git -C "$dir" config core.fileMode false 2>/dev/null || true   # NTFS: avoid chmod noise
  git -C "$dir" log -1 --format="  HEAD: %h %ad %s" --date=short 2>/dev/null | tee -a "$REPORT" || true
}

build_llama() { # $1 srcdir  $2 label
  local dir="$1" label="$2"
  section "Build: $label"
  cmake -S "$dir" -B "$dir/build" \
        -DGGML_VULKAN=ON -DGGML_NATIVE=ON \
        -DCMAKE_BUILD_TYPE=Release -G Ninja >> "$LOG_DIR/cmake-$label.log" 2>&1 \
      || { log "  FATAL: cmake configure failed — see logs/cmake-$label.log"; return 1; }
  cmake --build "$dir/build" -j "$JOBS" >> "$LOG_DIR/build-$label.log" 2>&1 \
      || { log "  FATAL: build failed — see logs/build-$label.log"; return 1; }
  local bin="$dir/build/bin"
  log "  binaries: $(ls "$bin" | tr '\n' ' ')"
  for b in llama-server llama-cli llama-bench; do
    [ -x "$bin/$b" ] || log "  WARNING: $bin/$b missing"
  done
  "$bin/llama-cli" --version 2>/dev/null | head -3 | tee -a "$REPORT" || true
}

# ---------------------------------------------------------------------------
section "1. Clone sources"
clone_or_update https://github.com/ggml-org/llama.cpp            "$STOCK_DIR"
clone_or_update https://github.com/PrismML-Eng/llama.cpp         "$PRISM_DIR" prism

build_llama "$STOCK_DIR" stock  || exit 1
build_llama "$PRISM_DIR" prism  || exit 1

STOCK_BIN="$STOCK_DIR/build/bin"
PRISM_BIN="$PRISM_DIR/build/bin"

# ---------------------------------------------------------------------------
section "2. Vulkan device discovery"
"$STOCK_BIN/llama-cli" --list-devices 2>&1 | tee "$LOG_DIR/devices-stock.txt" | tee -a "$REPORT"
if grep -qi "B580" "$LOG_DIR/devices-stock.txt"; then
  log "  -> stock build sees the B580"
else
  log "  -> WARNING: B580 not listed; check Vulkan ICD (intel_icd.json / ANV)"
fi

# If more than one Vulkan device appears (e.g. a Raphael iGPU via RADV), set
#   export LLAMA_VK_DEVICE=<index>   (as printed by --list-devices)
# before running this script or the chat-*.sh launchers.
DEV_ARG=""
if [ -n "${LLAMA_VK_DEVICE:-}" ]; then DEV_ARG="--device ${LLAMA_VK_DEVICE}"; fi

# ---------------------------------------------------------------------------
section "3. Flag support check (llama-server --help)"
"$STOCK_BIN/llama-server" --help > "$LOG_DIR/help-stock.txt" 2>&1 || true
for f in "--flash-attention" "-fa" "--cache-type-k" "--cache-type-v" "--jinja" \
         "--chat-template-file" "--chat-template-kwargs" "--repeat-penalty" \
         "--reasoning-format" "--override-tensor" "--min-p" "--temp" \
         "--device" "--list-devices" "-ngl" "--no-mmap"; do
  if grep -q -- "$f" "$LOG_DIR/help-stock.txt"; then
    log "  stock  ok      $f"
  else
    log "  stock  ABSENT  $f"
  fi
done

# ---------------------------------------------------------------------------
# test_serve <bin-dir> <gguf> <port> <label> <extra args...>
# Starts llama-server, waits for /health, dumps key log lines, runs one chat
# request, prints tok/s, then kills the server.
test_serve() {
  local bin="$1" gguf="$2" port="$3" label="$4"; shift 4
  local slog="$LOG_DIR/server-$label.log"
  section "4. Test-load: $label (port $port)"
  log "  cmd: $bin/llama-server -m <gguf> -ngl 99 -fa on -c 32768 $DEV_ARG $* --host 127.0.0.1 --port $port"
  "$bin/llama-server" -m "$gguf" -ngl 99 -fa on -c 32768 $DEV_ARG "$@" \
      --host 127.0.0.1 --port "$port" > "$slog" 2>&1 &
  local pid=$!
  local ok=0
  for i in $(seq 1 300); do           # up to 5 min for a 15GB mmap load over NTFS
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ok=1; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done

  if [ "$ok" -ne 1 ]; then
    log "  FAILED to reach /health — tail of log:"
    tail -30 "$slog" | tee -a "$REPORT"
    grep -iE "unknown (model )?architecture|not supported|failed to load|error" "$slog" | head -10 | tee -a "$REPORT" || true
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    if grep -qiE "unknown (model )?architecture|architecture.*not supported" "$slog"; then
      log "  -> ARCH UNSUPPORTED in this build — retry with lower -ngl would be pointless; skipping"
      return 2
    fi
    return 1
  fi

  log "  server UP — key lines:"
  grep -iE "ggml_vulkan|Vulkan[0-9]|offloaded|model buffer size|KV buffer size|model type|arch|llama_context|n_ctx|flash|chat template" "$slog" | head -40 | tee -a "$REPORT"

  # CPU-fallback heuristic: if weights claimed GPU-offloaded but a multi-GiB
  # CPU/CPU_Mapped *model* buffer exists, that's the PrismML Vulkan PQ2_0 bug
  # (#238). A small CPU buffer is normal with partial offload — warn >1 GiB.
  local cpu_mib
  cpu_mib=$(grep -oE "CPU[^=]*model buffer size[^=]*=[[:space:]]*[0-9.]+" "$slog" | grep -oE "[0-9.]+" | sort -rn | head -1)
  if [ -n "${cpu_mib:-}" ] && awk "BEGIN{exit !($cpu_mib > 1024)}" 2>/dev/null; then
    log "  !! CPU-side model buffer = ${cpu_mib} MiB. Partial offload (expected for the 15GB IQ4_XS)"
    log "     or the PQ2_0 Vulkan CPU-fallback bug (NOT expected for the 6.7GB Bonsai)."
    log "     For Bonsai: if this is multi-GB, rebuild the prism branch — do not trust prebuilt binaries."
  fi

  # web UI check
  if curl -s "http://127.0.0.1:$port/" | grep -qi "<html"; then
    log "  web UI: serving HTML at http://127.0.0.1:$port/"
  else
    log "  web UI: no HTML on / (older build?)"
  fi

  # one chat completion -> tok/s
  local resp
  resp=$(curl -s "http://127.0.0.1:$port/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":48,"temperature":0}' 2>/dev/null)
  echo "$resp" > "$LOG_DIR/chat-$label.json"
  echo "$resp" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  t=d.get("timings",{})
  print(f"  gen tok/s: {t.get(\"predicted_per_second\",\"?\")}   prompt t/s: {t.get(\"prompt_per_second\",\"?\")}   tokens: {t.get(\"predicted_n\",\"?\")}")
  print("  reply:", d["choices"][0]["message"]["content"][:200].replace("\n"," "))
except Exception as e:
  print("  could not parse response:", e)' 2>/dev/null | tee -a "$REPORT" || \
    { log "  raw response:"; head -c 500 "$LOG_DIR/chat-$label.json" | tee -a "$REPORT"; }

  grep -iE "eval time|tokens per second" "$slog" | tail -6 | tee -a "$REPORT" || true

  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 0
}

bench() { # $1 bin  $2 gguf  $3 label
  [ "${SKIP_BENCH:-0}" = "1" ] && return 0
  section "5. llama-bench: $3 (-p 128 -n 32)"
  "$1/llama-bench" -m "$2" $DEV_ARG -fa on -p 128 -n 32 -r 2 2>&1 \
      | tee "$LOG_DIR/bench-$3.log" | tee -a "$REPORT"
}

if [ "${1:-}" = "--build-only" ]; then
  log ""; log "Done (build-only). Binaries:"
  log "  stock: $STOCK_BIN"
  log "  prism: $PRISM_BIN"
  exit 0
fi

# --- model tests -----------------------------------------------------------
# OBLITERATED on the stock build. IQ4_XS 14.4GiB > 12GB VRAM -> -ngl 99 spills
# remainder to host RAM automatically. If load fails on memory, retry lower.
test_serve "$STOCK_BIN" "$OBLIT_GGUF" 8081 obliterated
rc=$?
# rc=2 means the arch itself is unsupported in this build — retrying is useless.
if [ "$rc" -eq 1 ]; then
  log "  retry with -ngl 48 (partial offload)"
  "$STOCK_BIN/llama-server" -m "$OBLIT_GGUF" -ngl 48 -fa on -c 16384 $DEV_ARG \
      --host 127.0.0.1 --port 8081 > "$LOG_DIR/server-obliterated-ngl48.log" 2>&1 &
  p=$!; ok=0
  for i in $(seq 1 120); do curl -sf http://127.0.0.1:8081/health >/dev/null 2>&1 && { ok=1; break; }; kill -0 $p 2>/dev/null || break; sleep 1; done
  [ "$ok" = 1 ] && log "  -ngl 48 works (partial offload)" || { log "  -ngl 48 also failed"; tail -20 "$LOG_DIR/server-obliterated-ngl48.log" | tee -a "$REPORT"; }
  kill $p 2>/dev/null; wait $p 2>/dev/null
fi

# Ternary-Bonsai PQ2_0 on the prism build. 7.2GB fits fully in 12GB VRAM.
# WATCH FOR: "CPU model buffer size" of several GB in the log = the old
# Vulkan PQ2_0 CPU-fallback bug (fixed in source by PrismML PR #238, 2026-09-21).
test_serve "$PRISM_BIN" "$BONSAI_GGUF" 8082 bonsai

bench "$STOCK_BIN" "$OBLIT_GGUF" obliterated
bench "$PRISM_BIN" "$BONSAI_GGUF" bonsai

section "DONE"
log "Report: $REPORT"
log "Logs:   $LOG_DIR"
log ""
log "Launchers: ../chat-obliterated.sh (port 8081)  ../chat-bonsai.sh (port 8082)"
