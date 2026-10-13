# L35 lever: SYCL prelude + graph capture. GGML_SYCL_ENABLE_GRAPH defaults to 0
# (ggml/src/ggml-sycl/ggml-sycl.cpp:419); 1 turns graph capture on.
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_ENABLE_GRAPH=1
set -u
