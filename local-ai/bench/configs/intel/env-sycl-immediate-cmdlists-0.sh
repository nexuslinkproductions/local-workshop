# INTEL knob S-immediate-cmdlists-0: SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=0
# Intel L0 immediate-command-lists guide - force regular cmd lists; B580 = L0 V2 adapter = immediate-only, expect a no-op/refusal
# oneAPI prelude must be in the same shell as the binary:
set +u
# shellcheck disable=SC1091
. /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh
export SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=0
set -u
