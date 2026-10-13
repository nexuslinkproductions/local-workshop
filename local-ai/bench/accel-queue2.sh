#!/usr/bin/env bash
# accel-queue2.sh — speculative-decoding sessions (MTP assistant head), run after queue1.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 2
while pgrep -f '[a]ccel-queue1.sh' >/dev/null 2>&1; do sleep 30; done
S="bench/spec-session.sh"
"$S" --backend sycl --mode base --tag sycl-base
"$S" --backend sycl --mode mtp --n-max 3 --tag sycl-mtp-n3
"$S" --backend sycl --mode mtp --n-max 6 --tag sycl-mtp-n6
"$S" --backend vulkan --mode base --tag vulkan-base
"$S" --backend vulkan --mode mtp --n-max 3 --tag vulkan-mtp-n3
echo "QUEUE2 DONE $(date -Iseconds)"
