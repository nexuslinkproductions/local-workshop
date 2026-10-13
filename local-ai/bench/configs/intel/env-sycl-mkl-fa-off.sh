# INTEL knob S-mkl-fa-off: GGML_SYCL_ENABLE_MKL_FA=0
# ggml-sycl.cpp:423 - oneMKL XMX flash-attn prefill OFF -> TILE kernel
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_ENABLE_MKL_FA=0
set -u
