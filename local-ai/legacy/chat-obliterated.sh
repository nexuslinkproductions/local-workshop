#!/usr/bin/env bash
# ============================================================================
# chat-obliterated.sh — Qwen3.8-27B-OBLITERATED (IQ4_XS, 14.4 GiB)
#
# Starts llama-server (stock llama.cpp + Vulkan build) on the Intel Arc B580.
#   Then open:  http://127.0.0.1:8081      (built-in web chat UI)
#   OpenAI API: http://127.0.0.1:8081/v1   (/chat/completions, /completions)
#
# Requires the stock build from llm/setup-llm.sh:
#   llm/llama.cpp/build/bin/llama-server
#
# Model-author settings (OBLITERATUS card):
#   * temperature 0 (greedy)  +  repetition_penalty 1.15   <- REQUIRED for quality
#   * NO system prompt (system prompts can reintroduce refusals)
#   * thinking OFF — the chat template emits an empty <think></think> by default
#
# The model is ~14.4 GiB > 12 GB VRAM, so -ngl 99 partially offloads; the
# remainder stays in host RAM (mmap from disk). If the server dies with a
# Vulkan OOM error, lower -ngl (e.g. 48) below.
#
# If Vulkan sees >1 device (e.g. Ryzen iGPU via RADV), pick the B580 index
# from `llm/llama.cpp/build/bin/llama-cli --list-devices` and set:
#   export LLAMA_VK_DEVICE=Vulkan0     # or the correct index/name
# ============================================================================
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$LAB_DIR/llm/llama.cpp/build/bin/llama-server"
GGUF="$LAB_DIR/models/llm/Qwen3.8-27B-OBLITERATED/Qwen3.8-27B-OBLITERATED-IQ4_XS.gguf"
MMPROJ="$LAB_DIR/models/llm/Qwen3.8-27B-OBLITERATED/mmproj-model-bf16.gguf"   # vision projector
TEMPLATE="$LAB_DIR/models/llm/Qwen3.8-27B-OBLITERATED/chat_template.jinja"
PORT=8081
NGL=40          # verified max WITH vision loaded (~9.7 GiB free VRAM); 48 OOMs on compute buffers

[ -x "$BIN" ]  || { echo "ERROR: $BIN not built — run llm/setup-llm.sh first"; exit 1; }
[ -f "$GGUF" ] || { echo "ERROR: model not found: $GGUF"; exit 1; }

DEV_ARG="--device ${LLAMA_VK_DEVICE:-Vulkan0}"   # Vulkan0 = Arc B580 (iGPU is Vulkan1)

echo "Starting OBLITERATED 27B on http://127.0.0.1:$PORT  (-ngl $NGL $DEV_ARG)"
exec "$BIN" \
    -m "$GGUF" \
    ${MMPROJ:+--mmproj "$MMPROJ" --no-mmproj-offload} \   # bf16 projector won't fit VRAM alongside -ngl 48; CPU-hosted
    -ngl "$NGL" \
    -fa on \
    -c 16384 \
    --temp 0 \
    --repeat-penalty 1.15 \
    --jinja \
    --chat-template-file "$TEMPLATE" \
    --chat-template-kwargs '{"enable_thinking":false}' \
    $DEV_ARG \
    --host 127.0.0.1 \
    --port "$PORT"

# --- Optional tuning (append to the exec line if useful) -------------------
#   --cache-type-k q8_0 --cache-type-v q8_0   # quarter-size KV cache
#   -t 16                                    # CPU threads for spilled layers
#   --api-key mykey                          # require auth on the endpoint
