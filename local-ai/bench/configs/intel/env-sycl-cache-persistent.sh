# INTEL knob S-cache-persistent: SYCL_CACHE_PERSISTENT=1 SYCL_CACHE_DIR=/home/nexuslink/.cache/libsycl_cache_intel
# SYCL.md:922-934 - STARTUP lever: persistent JIT kernel cache. llama.cpp WARNS against it (stale-cache crashes)
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export SYCL_CACHE_PERSISTENT=1
export SYCL_CACHE_DIR=/home/nexuslink/.cache/libsycl_cache_intel
set -u
