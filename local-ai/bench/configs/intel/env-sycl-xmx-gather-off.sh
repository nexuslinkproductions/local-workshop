# INTEL knob S-xmx-gather-off: GGML_SYCL_XMX_GATHER_TYPES=0
# ggml-sycl.cpp:431 - XMX dequant-GEMM paths OFF (the 'tensor cores off' A/B)
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_XMX_GATHER_TYPES=0
set -u
