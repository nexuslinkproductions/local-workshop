# INTEL knob S-fa-onednn-off: GGML_SYCL_FA_ONEDNN=0
# ggml-sycl.cpp:421 - oneDNN fused SDPA OFF -> native SYCL FA kernel
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_FA_ONEDNN=0
set -u
