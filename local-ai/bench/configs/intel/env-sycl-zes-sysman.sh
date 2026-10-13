# INTEL knob S-zes-sysman: ZES_ENABLE_SYSMAN=1
# SYCL.md:828 - enable free-VRAM query (needed for -ngl/--split-mode layer placement)
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export ZES_ENABLE_SYSMAN=1
set -u
