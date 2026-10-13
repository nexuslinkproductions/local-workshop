# INTEL knob S-prioritize-dmmv: GGML_SYCL_PRIORITIZE_DMMV=1
# ggml-sycl.cpp:430 - prioritize dequant-mat-vec
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_PRIORITIZE_DMMV=1
set -u
