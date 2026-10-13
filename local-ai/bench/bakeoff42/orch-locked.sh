#!/usr/bin/env bash
# bakeoff42 LOCKED phase: gate -> download -> sha/size verify -> direct smokes.
# MUST be run under:  flock -x -w 7200 bench/.gpu.lock  and with nice/ionice.
# Never --force. Never touches bench/.gpu-reset-ack.
set -uo pipefail
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
BO=$LAB/bench/bakeoff42
LOGD=$BO/logs; mkdir -p "$LOGD"
cd "$LAB" || exit 2
# shellcheck source=../gate.sh
source bench/gate.sh
set +u; . bench/configs/sycl-env.sh; set -u

log(){ echo "[$(date +%T)] $*" | tee -a "$LOGD/orch.log"; }

ORN=$LAB/models/llm/ornith-ai/Ornith-1.5-9B-GGUF
MIN=$LAB/models/llm/mistralai/Ministral-3-14B-Instruct-2512-GGUF
mkdir -p "$ORN" "$MIN"
ORN_M=$ORN/Ornith-1.5-9B-Q4_K_M.gguf
ORN_MM=$ORN/mmproj-Ornith-1.5-9B-BF16.gguf
MIN_M=$MIN/Ministral-3-14B-Instruct-2512-Q4_K_M.gguf
MIN_MM=$MIN/Ministral-3-14B-Instruct-2512-BF16-mmproj.gguf
ORN_M_SZ=5780090816; ORN_MM_SZ=921704672; MIN_M_SZ=8239593024; MIN_MM_SZ=879258784
GEMM=$LAB/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf
GEMM_M=$GEMM/gemma-4-12b-it-qat-q4_0.gguf
GEMM_MM=$GEMM/mmproj-gemma-4-12b-it-qat-q4_0.gguf

if ! gate_check; then log "GATE REFUSED (nothing killed)"; exit 3; fi
log "gate ok game=$(game_state)"
if ! io_quiet_wait; then log "IO BUSY, abort"; exit 3; fi
log "io quiet"

dl(){ # url dest expected_bytes
  local url="$1" dest="$2" exp="$3"
  if [ -f "$dest" ] && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" = "$exp" ]; then
    log "have $(basename "$dest") ($exp B)"; return 0; fi
  log "download $(basename "$dest")"
  if ! nice -n 10 ionice -c 3 curl -L --fail --retry 3 -C - -o "$dest.part" "$url"; then
    log "DL FAILED $url"; return 1; fi
  mv -f "$dest.part" "$dest"
  local sz; sz=$(stat -c%s "$dest")
  if [ "$sz" = "$exp" ]; then log "size ok $(basename "$dest") $sz B"; else
    log "SIZE MISMATCH $(basename "$dest") got=$sz exp=$exp"; return 1; fi
}

rc=0
dl "https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF/resolve/main/Ornith-1.5-9B-Q4_K_M.gguf" "$ORN_M" "$ORN_M_SZ" || rc=1
dl "https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF/resolve/main/mmproj-Ornith-1.5-9B-BF16.gguf" "$ORN_MM" "$ORN_MM_SZ" || rc=1
dl "https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/main/Ministral-3-14B-Instruct-2512-Q4_K_M.gguf" "$MIN_M" "$MIN_M_SZ" || rc=1
dl "https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/main/Ministral-3-14B-Instruct-2512-BF16-mmproj.gguf" "$MIN_MM" "$MIN_MM_SZ" || rc=1
[ "$rc" = 0 ] || { log "download phase FAILED"; exit 4; }

log "sha256 vs HF X-Linked-Etag:"
verify_sha(){ # file expected_sha256
  local f="$1" exp="$2" got
  got=$(sha256sum "$f" | awk '{print $1}')
  if [ "$got" = "$exp" ]; then log "  sha ok  $(basename "$f") $got"; else
    log "  SHA MISMATCH $(basename "$f") got=$got exp=$exp"; return 1; fi
}
verify_sha "$ORN_M"  70c112196e0b7023803c9762752e46d29e612a92c83f995bc3ba1ceb07e8fab6 || rc=1
verify_sha "$ORN_MM" 626f9f90627402a6bf4a999111d0fbd69b5fcca7aa8ba089d69e5f10e8858e1d || rc=1
verify_sha "$MIN_M"  824e0f3373e69b84f2cae46fdcb9bd1ebc6ab3bfc7acc125d818b7b8178cc613 || rc=1
verify_sha "$MIN_MM" ab7616148b7081030fd38e410c9213ce8346a8b0588291c8ca279058e78cfae7 || rc=1
[ "$rc" = 0 ] || { log "sha verify FAILED"; exit 4; }

# --- measured idle ceiling (desktop VRAM drifts; measure now, nothing else loaded) ---
IDLE_FREE=$(python3 bench/arc-vram.py 2>/dev/null | sed -n 's/.*free=\([0-9]*\).*/\1/p')
log "idle free VRAM (measured ceiling): ${IDLE_FREE:-?} MiB"
ORN_KV=q8_0; MIN_KV=q4_0
ORN_CTX=$(python3 "$BO/pick_ctx.py" "$ORN_M" "$ORN_MM_SZ" "$ORN_KV" "$IDLE_FREE" 2>&1 | tee -a "$LOGD/orch.log" | awk '/^PICK/{print $2}')
MIN_CTX=$(python3 "$BO/pick_ctx.py" "$MIN_M" 0 "$MIN_KV" "$IDLE_FREE" 2>&1 | tee -a "$LOGD/orch.log" | awk '/^PICK/{print $2}')
log "ctx chosen: ornith=$ORN_CTX ($ORN_KV, mmproj gpu) ministral=$MIN_CTX ($MIN_KV, mmproj cpu)"

if ! gate_check; then log "GATE REFUSED before gemma canary smoke"; exit 3; fi
log "smoke gemma4-12b-eval (direct canary, ctx 49152 = eval config)"
python3 "$BO/smoke.py" --id gemma4-12b-eval --model "$GEMM_M" --mmproj "$GEMM_MM" --ctx 49152 --kv q8_0 --port 18152 > "$LOGD/gemma4-12b-direct.out" 2>&1
log "gemma smoke rc=$? :: $(tail -c 600 "$LOGD/gemma4-12b-direct.out" | tr '\n' ' ')"

if ! io_quiet_wait; then log "IO BUSY before ornith"; exit 3; fi
if ! gate_check; then log "GATE REFUSED before ornith smoke"; exit 3; fi
log "smoke ornith (direct)"
python3 "$BO/smoke.py" --id ornith-9b --model "$ORN_M" --mmproj "$ORN_MM" --ctx "$ORN_CTX" --kv "$ORN_KV" --port 18150 > "$LOGD/ornith-9b-direct.out" 2>&1
log "ornith smoke rc=$? :: $(tail -c 500 "$LOGD/ornith-9b-direct.out" | tr '\n' ' ')"

if ! io_quiet_wait; then log "IO BUSY before ministral"; exit 3; fi
if ! gate_check; then log "GATE REFUSED before ministral smoke"; exit 3; fi
log "smoke ministral (direct)"
python3 "$BO/smoke.py" --id ministral3-14b --model "$MIN_M" --mmproj "$MIN_MM" --ctx "$MIN_CTX" --kv "$MIN_KV" --mmproj-cpu --port 18151 > "$LOGD/ministral3-14b-direct.out" 2>&1
log "ministral smoke rc=$? :: $(tail -c 500 "$LOGD/ministral3-14b-direct.out" | tr '\n' ' ')"

log "LOCKED PHASE DONE"
