# INTEL knob S-dev2dev-l0: GGML_SYCL_DEV2DEV_MEMCPY=1
# ggml-sycl.cpp:443 - device-to-device copy via L0 API (faster; crash-prone)
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_DEV2DEV_MEMCPY=1
set -u
