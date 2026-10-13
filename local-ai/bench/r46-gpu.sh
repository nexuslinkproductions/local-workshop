#!/usr/bin/env bash
# r46-gpu.sh <timeout-s> <cmd...> — run ONE short GPU command under the shared GPU lock, with the same gates as
# r46-depth.sh (memwatch active, no game, no unacked reset, nothing else on the GPU, quiet disk), the PSI/RAM
# watchdog, jobcap and ionice. Stops with exit 4 if an xe reset/wedge line appears. For builders (devin) that
# need a few seconds of GPU: test-backend-ops perf, llama-bench d=0..65536. Never --force, never hold > timeout.
set -uo pipefail
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
T="$1"; shift
exec 9>"$LAB/bench/.gpu.lock"; flock -x -w 7200 9 || { echo "lock timeout"; exit 3; }
source "$LAB/bench/gate.sh"
systemctl --user is-active --quiet memwatch.timer || { echo "memwatch inactive"; exit 3; }
g="$( { game_running && echo GAME; gpu_reset_unacked; kswapd_missing; pgrep -ax 'llama-server|llama-bench|llama-perplexit|test-backend-ops'; } 2>&1)"
[ -z "$g" ] || { echo "gate refuses: $g"; exit 3; }
until awk -v a="$(io_full)" 'BEGIN{exit !(a<0.3)}'; do sleep 5; done
T0="$(date '+%F %T')"
set +u; . "$LAB/bench/configs/sycl-env.sh"; set -u
export CAP=14G CPUS=6-11,18-23 CPUW=20 WATCH_IO_GRACE_S=30 MATRIX_RESULTS=/dev/null
bash "$LAB/bench/watchdog.sh" r46-gpu -- timeout --kill-after=20 "$T" ionice -c 3 /home/nexuslink/.local/bin/jobcap "$@"
rc=$?
hits="$(journalctl -k --since "$T0" --no-pager 2>/dev/null | grep -cE 'GT0: (Engine )?reset|device wedged|Timedout job|DEVICE_LOST' || true)"
echo "r46-gpu rc=$rc faults=$hits"
[ "$hits" -gt 0 ] && exit 4
exit "$rc"
