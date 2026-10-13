#!/usr/bin/env bash
# gate-run.sh — start a model server only when ARC Raiders is not running.
#
# llama-swap runs this as a model's `cmd`. It reuses bench/gate.sh's
# game_running() — the same rule the benchmark harness uses (Marcel 2026-10-12:
# "tests never run while he games", it lagged the game). If the game is up this
# REFUSES to load (exits non-zero) instead of waiting, so a stray request can
# never steal VRAM from the game; llama-swap reports the model as failed to start.
#
# Usage (from the llama-swap config):  gate-run.sh <llama-server> <args...>
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../bench/gate.sh
source "$here/../bench/gate.sh"

if game_running; then
    echo "gate-run: REFUSING to load a model — ARCRaiders (PioneerGame.exe) is running" >&2
    exit 1
fi
if r=$(gpu_reset_unacked); then echo "gate-run: REFUSING to load a model — $r" >&2; exit 1; fi
if k=$(kswapd_missing); then echo "gate-run: REFUSING to load a model - $k" >&2; exit 1; fi

exec "$@"
