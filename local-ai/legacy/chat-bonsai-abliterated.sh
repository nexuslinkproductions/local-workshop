#!/usr/bin/env bash
# ============================================================================
# chat-bonsai.sh — Ternary-Bonsai-2-27B ABLITERATED (PQ2_0) — uncensored reasoning model
#
# Starts llama-server from the PrismML fork build (llm/llama.cpp-prism) —
# PQ2_0 ternary weights only run on that build; stock llama.cpp cannot load
# this file at all.
#
#   Then open:  http://127.0.0.1:8082      (built-in web chat UI)
#   OpenAI API: http://127.0.0.1:8082/v1
#
# Requires: llm/setup-llm.sh to have built llm/llama.cpp-prism/build/bin.
#
# 6.7 GiB < 12 GB VRAM -> -ngl 99 fits FULLY on the B580.
# IMPORTANT: check the startup log — if you see a multi-GB "CPU model buffer
# size" while layers claim to be offloaded, that is the old Vulkan PQ2_0
# CPU-fallback bug (~2 tok/s). It is fixed in source (PrismML PR #238,
# 2026-09-21) — rebuild the prism branch; do NOT use prebuilt releases.
#
# Sampling defaults below are the model card's thinking-mode values (also
# baked into the GGUF metadata): temp 1.0 / top_p 0.95 / top_k 20 / min_p 0.05.
# This model THINKS by default (xhigh reasoning effort). For shorter answers
# pass "chat_template_kwargs": {"reasoning_effort": "medium"} per request, or
# add --chat-template-kwargs '{"reasoning_effort":"medium"}' below.
# ============================================================================
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$LAB_DIR/llm/llama.cpp-prism/build/bin/llama-server"
GGUF="$LAB_DIR/models/llm/bonsai-abliterated/Ternary-Bonsai-2-27B-Abliterated-PQ2_0.gguf"
MMPROJ="$LAB_DIR/models/llm/bonsai-abliterated/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"   # shared official projector
PORT=8083

[ -x "$BIN" ]  || { echo "ERROR: $BIN not built — run llm/setup-llm.sh first"; exit 1; }
[ -f "$GGUF" ] || { echo "ERROR: model not found: $GGUF"; exit 1; }

DEV_ARG="--device ${LLAMA_VK_DEVICE:-Vulkan0}"   # Vulkan0 = Arc B580 (iGPU is Vulkan1)

echo "Starting Ternary-Bonsai-2-27B-ABLITERATED on http://127.0.0.1:$PORT"
exec "$BIN" \
    -m "$GGUF" \
    ${MMPROJ:+--mmproj "$MMPROJ"} \
    -ngl 99 \
    -fa on \
    -c 32768 \
    --temp 1.0 \
    --top-p 0.95 \
    --top-k 20 \
    --min-p 0.05 \
    --jinja \
    $DEV_ARG \
    --host 127.0.0.1 \
    --port "$PORT"

# --- Optional tuning --------------------------------------------------------
#   --cache-type-k q8_0 --cache-type-v q8_0   # smaller KV for long contexts
#   --reasoning-format deepseek               # parse <think> into reasoning_content
