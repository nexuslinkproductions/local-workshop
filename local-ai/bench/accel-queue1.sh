#!/usr/bin/env bash
# accel-queue1.sh — llama-bench one-variable levers for Gemma 4 12B QAT Q4_0 (pp4096/tg128 r3).
# Each line = one accel-run.sh call (takes bench/.gpu.lock itself; runs serialize).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/accel-run.sh"
C="configs/accel"
S="configs/matrix-gemma4-12b-qat-sycl-nothink.env"
V="configs/matrix-gemma4-12b-qat-vulkan-nothink.env"
"$R" "accel-sycl2026.0-base"            "$S"
"$R" "accel-sycl2026.0-GRAPH1"          "$S"            GGML_SYCL_ENABLE_GRAPH=1
"$R" "accel-sycl2026.0-OPT0-noreorder"  "$S"            GGML_SYCL_ENABLE_OPT=0
"$R" "accel-sycl2026.0-XMX-off"         "$S"            GGML_SYCL_XMX_GATHER_TYPES=0
"$R" "accel-sycl2026.0-MKLFA-off"       "$S"            GGML_SYCL_ENABLE_MKL_FA=0
"$R" "accel-sycl2026.0-KVf16-FAon"      "$S"            KV_OVERRIDE=f16
"$R" "accel-sycl2026.0-FAoff-KVf16"     "$S"            FA_OVERRIDE=off KV_OVERRIDE=f16
"$R" "accel-sycl2026.0-threads8"        "$S"            THREADS_OVERRIDE=8
"$R" "accel-sycl2026.0-ub512-prefill"   "$C/sycl-ub512.env"
"$R" "accel-sycl2026.0-b2048-prefill"   "$C/sycl-b2048.env"
"$R" "accel-sycl2026.1-base"            "$C/sycl2026.1.env"
"$R" "accel-sycl2026.1-GRAPH1"          "$C/sycl2026.1.env" GGML_SYCL_ENABLE_GRAPH=1
"$R" "accel-vulkan-base"                "$C/vulkan-base.env"
"$R" "accel-vulkan-coopmat2-off"        "$C/vulkan-base.env" GGML_VK_DISABLE_COOPMAT2=1
"$R" "accel-vulkan-coopmat-off"         "$C/vulkan-base.env" GGML_VK_DISABLE_COOPMAT=1
"$R" "accel-vulkan-mmvq-off-control"    "$C/vulkan-base.env" GGML_VK_DISABLE_MMVQ=1
"$R" "accel-vulkan-forcemmvq"           "$C/vulkan-base.env" GGML_VK_FORCE_MMVQ=1
echo "QUEUE1 DONE $(date -Iseconds)"
