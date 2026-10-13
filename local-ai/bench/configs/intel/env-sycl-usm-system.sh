# INTEL knob S-usm-system: GGML_SYCL_USM_SYSTEM=1
# ggml-sycl.cpp:456 - USM system allocations for large buffers (Xe2+/BMG, Linux, XE_GPUSVM)
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_USM_SYSTEM=1
set -u
