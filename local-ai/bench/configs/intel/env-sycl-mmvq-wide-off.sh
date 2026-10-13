# INTEL knob S-mmvq-wide-off: GGML_SYCL_MMVQ_WIDE=0
# ggml-sycl.cpp:429 - narrow Q8_0 mat-vec loads
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_MMVQ_WIDE=0
set -u
