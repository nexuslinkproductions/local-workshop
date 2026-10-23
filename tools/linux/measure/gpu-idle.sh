#!/usr/bin/env bash
# GPU engine busy percent of one process from two DRM fdinfo samples.
#
#   tools/linux/measure/gpu-idle.sh <pid> <seconds> [warmup-seconds]
#
# Reads /proc/<pid>/fdinfo/* only (no root, no intel_gpu_top, no perf). Two
# counter families exist in the kernel:
#
#   drm-cycles-<eng> + drm-total-cycles-<eng>   busy and elapsed in ENGINE
#                                               CYCLES (i915, xe); the ratio is
#                                               the busy fraction, no clock rate
#                                               needed.
#   drm-engine-<eng>-ns                          busy in NANOSECONDS (amdgpu,
#                                               nouveau); the ratio is busy ns
#                                               over wall time.
#
# Fds of one client (same drm-client-id on one pdev) share one accounting
# record, so only the highest value per client and engine is used; adding all
# fds would multiply the client. Per engine:
#   busy percent = sum over clients of delta_busy / delta_elapsed * 100
# with delta_elapsed the largest delta-total across the clients of that pdev
# (total cycles is a device clock shared by every client).
#
# Output: one line per (pdev, engine), then RENDER (rcs or gfx) and COMPUTE
# (ccs) summary lines in percent of that engine.
# Exit 1 pid gone, 2 no accounted DRM fd, 3 no counter delta in the window.
set -o pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec python3 "$HERE/gpu-idle.py" "$@"
