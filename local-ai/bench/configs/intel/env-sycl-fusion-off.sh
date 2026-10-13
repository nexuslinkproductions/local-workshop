# INTEL knob S-fusion-off: GGML_SYCL_ENABLE_FUSION=0
# ggml-sycl.cpp:427 - SYCL fused-kernel dispatch OFF
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_ENABLE_FUSION=0
set -u
