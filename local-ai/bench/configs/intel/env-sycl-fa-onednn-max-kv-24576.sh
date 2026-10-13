# INTEL knob S-fa-onednn-max-kv-24576: GGML_SYCL_FA_ONEDNN_MAX_KV=24576
# ggml-sycl.cpp:422 - cap oneDNN SDPA KV length (DEVICE_LOST mitigation)
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_FA_ONEDNN_MAX_KV=24576
set -u
