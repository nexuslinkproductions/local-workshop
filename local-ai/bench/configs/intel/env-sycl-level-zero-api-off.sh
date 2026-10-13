# INTEL knob S-level-zero-api-off: GGML_SYCL_USE_LEVEL_ZERO_API=0
# ggml-sycl.cpp:439 - use SYCL instead of direct L0 allocation
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_USE_LEVEL_ZERO_API=0
set -u
