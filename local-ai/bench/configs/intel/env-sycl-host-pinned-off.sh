# INTEL knob S-host-pinned-off: GGML_SYCL_ENABLE_HOST_PINNED_MEM=0
# ggml-sycl.cpp:457 - pinned host memory OFF (SYCL.md:804 says do this with -lm mlock)
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_ENABLE_HOST_PINNED_MEM=0
set -u
