# INTEL knob S-dynamic-precision-bf16: GGML_SYCL_DYNAMIC_PRECISION=BF16
# ggml-sycl.cpp:433 - XMX operand type BF16 (default F16 with GGML_SYCL_F16=ON)
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_DYNAMIC_PRECISION=BF16
set -u
