# INTEL knob S-graph: GGML_SYCL_ENABLE_GRAPH=1
# ggml-sycl.cpp:419 - SYCL graph capture (default 0) - the CUDA-graphs analogue
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_ENABLE_GRAPH=1
set -u
