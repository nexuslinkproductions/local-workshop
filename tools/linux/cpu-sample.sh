#!/usr/bin/env bash
# CPU sampler: percent of one core, thread count and RSS of one process.
#
#   tools/linux/cpu-sample.sh <pid> <seconds> [warmup]
#
# 100 percent means one core fully busy; a process pegged on two cores reads
# 200 percent. The logic lives in cpu-sample.py next to this script.
# Exit 1 when the process is gone.
set -o pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec python3 "$HERE/cpu-sample.py" "$@"
