# SYCL prelude for engines/llama.cpp-sycl-tip-2026.1 (source, do not exec).
# Same as sycl-env.sh but oneAPI 2026.1 (side-by-side root-free install). setvars.sh
# in 2026.1 already prepends its own dnnl/2026.0/lib, so the manual append is a
# harmless belt-and-braces (research/19 §4). Device name is SYCL0.
set +u
# shellcheck disable=SC1091
. /home/nexuslink/intel/oneapi-2026.1-env.sh >/dev/null 2>&1
export LD_LIBRARY_PATH="/home/nexuslink/intel/oneapi-2026.1/dnnl/2026.0/lib:${LD_LIBRARY_PATH:-}"
set -u
