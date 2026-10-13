# INTEL knob S-sparse-fa: GGML_SYCL_SPARSE_FA=1
# ggml-sycl.cpp:464 - sparse flash-attention ON
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_SPARSE_FA=1
set -u
