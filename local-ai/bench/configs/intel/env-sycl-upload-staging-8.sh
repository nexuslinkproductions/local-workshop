# INTEL knob S-upload-staging-8: GGML_SYCL_UPLOAD_STAGING_SLOTS=8
# ggml-sycl.cpp:462 - 8 pinned 8MiB staging slots (default 4)
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export GGML_SYCL_UPLOAD_STAGING_SLOTS=8
set -u
