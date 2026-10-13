# shellcheck shell=bash
# Shared helpers for the LOCAL-AI-LAB benchmark scripts.
#
# Machine rules (2026-10-12, Marcel):
#   R1  every test runs EXCLUSIVE on bench/.gpu.lock — bench.sh and ttft.sh
#       re-exec themselves under `flock -x` so no caller can forget it.
#   R2  a server-based test holds the lock for the whole session in ONE call:
#       start server -> wait /health -> measure -> kill it. ttft.sh --server-cmd
#       does this; a server started outside the lock cannot be rule-2 clean.
#   R3  builds/compiles take the lock SHARED: `flock -s bench/.gpu.lock <build>`.
#       (Docs only — nothing in bench/ builds anything.)
#   R4  downloads/installs need no lock.
#   R5  before a test, anything else running is reported, never killed — wait for
#       the lock instead. gate_check() does the reporting.
# The GPU is one B580 (Vulkan0). The game may be open: that is a WARNING that
# tags the row (game-open), not a refusal.

LOCK_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.gpu.lock"

game_running() { pgrep -f '^[A-Za-z]:\\.*PioneerGame\.exe' >/dev/null 2>&1; }  # argv starts with the Windows path, so shells that only mention the name don't match

# "game-open" | "clean" — written into the vram_note column.
game_state() { game_running && echo game-open || echo clean; }

# Prints a message and succeeds if the xe GPU reset this boot and nobody acked it since.
GPU_RESET_ACK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.gpu-reset-ack"
# GATE_KLOG=<file> replaces journalctl (fixture drill, research/45-memory-cache.md).
kernel_log() { if [ -n "${GATE_KLOG:-}" ]; then cat "$GATE_KLOG"; else journalctl -k -b -o short-unix --no-pager 2>/dev/null; fi; }

# memwatch (BRIEF-45): kswapd0 is the reclaim thread that died in the 13:17 oops. Without it
# nothing reclaims memory. Prints the reason and succeeds when it is missing.
kswapd_missing() {
    local c name
    for c in "${MEMWATCH_PROC:-/proc}"/[0-9]*/comm; do
        { read -r name < "$c"; } 2>/dev/null || continue   # a pid can exit mid-scan
        [ "$name" = kswapd0 ] && return 1
    done
    echo "kswapd0 missing: kernel reclaim is dead, reboot before GPU work"
}

gpu_reset_unacked() {
    local t
    t=$(kernel_log \
        | grep -E 'xe .*(GT0: Engine reset|device wedged|Timedout job)|BUG: kernel|Oops: ' | tail -1 | cut -d' ' -f1 | cut -d. -f1)
    [ -n "$t" ] || return 1
    [ -e "$GPU_RESET_ACK" ] && [ "$(stat -c %Y "$GPU_RESET_ACK")" -ge "$t" ] && return 1
    echo "GPU reset or kernel oops this boot at $(date -d @"$t" +%T): stop, report, ack with 'touch $GPU_RESET_ACK'"
}

# Usage: gate_check [--force] [allow_port]
#   allow_port — a llama-server already running on this port is allowed through
#                (ttft.sh measuring a server someone else started); any other
#                llama-server / llama-bench / benchmark_genai blocks.
gate_check() {
    local force=0 allow_port="" blockers="" pid cmdline argv hit tok b

    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1 ;;
            *)       allow_port="$1" ;;
        esac
        shift
    done

    [ "$force" = 1 ] && return 0

    # Marcel 2026-10-12: tests never run while he games (it lagged the game).
    if game_running; then
        blockers="${blockers}  - game running: PioneerGame.exe\n"
    fi

    # 2026-10-13: a GT0 engine reset at 10:43 was ignored, the next run wedged the
    # B580 at 10:48 and blacked out all 3 monitors. After any reset this boot, no
    # GPU job runs until a human acks it: touch bench/.gpu-reset-ack (or reboot).
    local r; if r=$(gpu_reset_unacked); then blockers="${blockers}  - $r\n"; fi
    local k; if k=$(kswapd_missing); then blockers="${blockers}  - $k\n"; fi

    # Match on an argv token that IS the binary path: pgrep -f alone also matches
    # innocent shells whose command line merely mentions "llama-server", and
    # misses shebang wrappers (whose argv[0] is /bin/bash). Tokens containing
    # whitespace are -c blobs and get skipped.
    for pid in $(pgrep -f 'llama-(server|bench)|benchmark_genai' 2>/dev/null || true); do
        [ "$pid" = "$$" ] && continue
        argv="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)"
        hit=""
        while IFS= read -r tok; do
            case "$tok" in *[[:space:]]*|'') continue ;; esac
            b="$(basename -- "$tok")"
            case "$b" in llama-server|llama-bench|benchmark_genai) hit="$b"; break ;; esac
        done <<< "$argv"
        [ -n "$hit" ] || continue

        case "$hit" in
            llama-server)
                cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
                if [ -n "$allow_port" ] && printf '%s' "$cmdline" | grep -qE -- "--port[ =]$allow_port( |$)"; then
                    continue
                fi
                blockers="${blockers}  - llama-server (pid $pid) holds VRAM — wait for it, or --force\n" ;;
            llama-bench)
                blockers="${blockers}  - llama-bench (pid $pid) is already testing — wait for it, or --force\n" ;;
            benchmark_genai)
                blockers="${blockers}  - openvino benchmark_genai (pid $pid) is testing — wait for it, or --force\n" ;;
        esac
    done

    if [ -n "$blockers" ]; then
        printf 'REFUSING TO RUN (nothing killed):\n%b\n' "$blockers" >&2
        return 1
    fi
    return 0
}

# Free VRAM on Vulkan0 (the B580; Vulkan1 is the Ryzen iGPU) in MiB.
# Usage: vram_free_mib <any binary in the build dir>   ->  "4861 12216"
# Source: "<bin>/llama-cli --list-devices" -> "Vulkan0: ... (12216 MiB, 4861 MiB free)"
vram_free_mib() {
    local dir; dir="$(dirname "$1")"
    [ -x "$dir/llama-cli" ] || return 1
    "$dir/llama-cli" --list-devices 2>/dev/null \
        | grep 'Vulkan0:' \
        | sed -n 's/.*(\([0-9]\+\) MiB, \([0-9]\+\) MiB free).*/\2 \1/p' | tail -1
}

# Lint: every flag we are about to hand llama-bench must appear in that build's
# own --help. Catches stock-vs-prism drift (e.g. -lzm only exists upstream).
lint_flags() {
    local bin="$1"; shift
    local help missing=""
    help="$("$bin" --help 2>&1 || true)"
    local tok
    for tok in "$@"; do
        case "$tok" in
            -*[!0-9]*) ;;
            *) continue ;;                       # value, not a flag
        esac
        grep -qE -- "(^|[[:space:],|])${tok}([[:space:],|=$]|$)" <<<"$help" \
            || missing="${missing} ${tok}"
    done
    if [ -n "$missing" ]; then
        printf 'FLAG MISMATCH — not in %s --help:%s\n' "$bin" "$missing" >&2
        return 1
    fi
    return 0
}

# ---- quiet-mode / memory-pressure instrumentation (Marcel 2026-10-13) --------
# The desktop freezes are MEMORY/IO stalls, not CPU: /proc/pressure/{memory,io} "full"
# (every task stalled = the frozen desktop) is the metric that tracks them. Every test
# records the delta of some/full totals across the run plus min MemAvailable.
# psi_now -> "mem_some_us mem_full_us io_some_us io_full_us memavail_kb"
psi_now() {
    local ms mf is if_ av
    ms="$(awk '/^some/{sub("total=","",$5); print $5}' /proc/pressure/memory)"
    mf="$(awk '/^full/{sub("total=","",$5); print $5}' /proc/pressure/memory)"
    is="$(awk '/^some/{sub("total=","",$5); print $5}' /proc/pressure/io)"
    if_="$(awk '/^full/{sub("total=","",$5); print $5}' /proc/pressure/io)"
    av="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    echo "${ms:-0} ${mf:-0} ${is:-0} ${if_:-0} ${av:-0}"
}

# psi_delta "before" "after" -> "psi_mem_some=+Xms psi_mem_full=+Yms psi_io_some=+Zms psi_io_full=+Wms"
psi_delta() {
    local -a a b; read -r -a a <<<"$1"; read -r -a b <<<"$2"
    printf 'psi_mem_some=+%dms psi_mem_full=+%dms psi_io_some=+%dms psi_io_full=+%dms' \
        $(( (b[0]-a[0]) / 1000 )) $(( (b[1]-a[1]) / 1000 )) \
        $(( (b[2]-a[2]) / 1000 )) $(( (b[3]-a[3]) / 1000 ))
}

# Pre-load memory guard: refuse to load when MemAvailable < (model bytes kept in RAM + 8 GiB).
# RAM bytes = GGUF size for -lm none/mmap (the whole file ends up resident in the page
# cache), or GGUF size - VRAM_EST_MIB for -lm dio (DirectIO keeps no page-cache copy).
# Usage: mem_guard <model_path> <load_mode> <vram_est_mib>  ->  "OK|REFUSE need_mib avail_mib"
mem_guard() {
    local model="$1" mode="${2:-auto}" vram="${3:-0}" avail size need
    avail="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)"
    size="$(( $(stat -c%s "$model" 2>/dev/null || echo 0) / 1048576 ))"
    need="$size"
    [ "$mode" = dio ] && need=$(( size - vram ))
    need=$(( need + 8192 ))
    if [ "$avail" -lt "$need" ]; then echo "REFUSE $need $avail"; else echo "OK $need $avail"; fi
}

# Pre-load disk guard: a download holds io full ~2-4%; a model load pushes it past the watchdog's
# 1.0 kill line within seconds. Wait up to 30 min for io full avg10 < 0.5. rc 0 = quiet, 1 = still busy.
io_full() { awk '/^full/{sub("avg10=","",$2); print $2}' /proc/pressure/io; }
io_quiet_wait() {
    local io w
    io=$(io_full)
    for w in $(seq 1 90); do
        awk -v a="$io" 'BEGIN{exit !(a<0.5)}' && return 0
        [ "$w" = 1 ] && echo "[gate] disk busy (io full avg10=$io): waiting for quiet disk" >&2
        sleep 20; io=$(io_full)
    done
    IO_BUSY="$io"; awk -v a="$io" 'BEGIN{exit !(a<0.5)}'
}
