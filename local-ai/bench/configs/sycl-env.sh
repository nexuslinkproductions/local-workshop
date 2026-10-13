# SYCL prelude for engines/llama.cpp-sycl-tip (source, do not exec).
# oneAPI env + oneDNN lib path must be in the same shell as the binary, and the
# device name is SYCL0. set +u first: oneapi-env.sh touches unset variables.
set +u
# shellcheck disable=SC1091
. /home/nexuslink/intel/oneapi-env.sh >/dev/null 2>&1
export LD_LIBRARY_PATH="/home/nexuslink/intel/oneapi/dnnl/2026.0/lib:${LD_LIBRARY_PATH:-}"
set -u
