#!/usr/bin/env bash
# NEXUS System HUD — stats collector for the nexuslink.hud omarchy-shell plugin.
#
# Usage:
#   collect.sh probe              static-ish info: host, kernel, gpu_kind, gpu_name
#   collect.sh poll <gpu_kind>    dynamic stats; gpu_kind = nvidia|amd|intel|none|auto
#
# Output: one "key<TAB>value" line per stat, parsed by Hud.qml.
# Everything here is read-only and fork-light: a couple of /proc reads plus
# df/awk, and nvidia-smi only when the probe actually found an NVIDIA GPU.

set -u

# Prefer the Rust collector (persistent stream mode, in-daemon deltas) when
# deploy.sh installed it next to this script.
_self="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "$_self/hud-collect" ]]; then
  exec "$_self/hud-collect" "$@"
fi

out() { printf '%s\t%s\n' "$1" "${2:-}"; }

mode="${1:-poll}"
gpu_kind="${2:-auto}"

# bash fallback for `stream`: poll on a loop with a batch sentinel.
# The sentinel carries a running count, like hud-collect's `batch\t<n>`: the
# HUD parses it as an integer, and a non-numeric value leaves its frame
# counter (status, selftest) pinned at 0.
if [[ $mode == "stream" ]]; then
  _batch=0
  while :; do
    bash "$_self/collect.sh" poll "$gpu_kind"
    _batch=$((_batch + 1))
    printf 'batch\t%d\n' "$_batch"
    sleep 1.5
  done
fi

# ---------------------------------------------------------------- GPU detect
if [[ $gpu_kind == "auto" ]]; then
  gpu_kind=none
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    gpu_kind=nvidia
  else
    for d in /sys/class/drm/card[0-9]/device; do
      [[ -r $d/vendor ]] || continue
      case $(<"$d/vendor") in
        0x1002|0x1022) gpu_kind=amd;   break ;;
        0x8086)        gpu_kind=intel; break ;;
      esac
    done
  fi
fi

# -------------------------------------------------------------------- probe
if [[ $mode == "probe" ]]; then
  out host "$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname 2>/dev/null)"
  out kernel "$(uname -r 2>/dev/null)"
  out gpu_kind "$gpu_kind"
  if [[ $gpu_kind == nvidia ]]; then
    out gpu_name "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  fi
  exit 0
fi

# ------------------------------------------------------------- uptime / load
read -r up_s _ < /proc/uptime
out uptime_s "${up_s%.*}"
read -r l1 l5 l15 _ < /proc/loadavg
out load1 "$l1"
out load5 "$l5"
out load15 "$l15"

# ---------------------------------------------------------------------- cpu
read -r _ u n s idle iow irq sirq steal _ < /proc/stat
out cpu_idle $((idle + iow))
out cpu_total $((u + n + s + idle + iow + irq + sirq + steal))
out cpu_count "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null)"

cpu_temp=""
for h in /sys/class/hwmon/hwmon*; do
  [[ -r $h/name ]] || continue
  case $(<"$h/name") in
    k10temp|coretemp|zenpower|cpu_thermal|acpitz|peci)
      if [[ -r $h/temp1_input ]]; then
        cpu_temp=$(( $(<"$h/temp1_input") / 1000 ))
        break
      fi
      ;;
  esac
done
if [[ -z $cpu_temp ]]; then
  for z in /sys/class/thermal/thermal_zone*; do
    [[ -r $z/temp ]] || continue
    cpu_temp=$(( $(<"$z/temp") / 1000 ))
    break
  done
fi
out cpu_temp "$cpu_temp"

# ------------------------------------------------------------------- memory
awk '
  /^MemTotal:/     { t  = $2 }
  /^MemAvailable:/ { a  = $2 }
  /^SwapTotal:/    { st = $2 }
  /^SwapFree:/     { sf = $2 }
  END {
    printf "mem_total_kb\t%d\nmem_avail_kb\t%d\nswap_total_kb\t%d\nswap_free_kb\t%d\n", t, a, st, sf
  }
' /proc/meminfo

# ------------------------------------------------------------------ network
awk '
  /:/ {
    iface = $1
    sub(/:.*/, "", iface)
    if (iface == "lo") next
    rx += $2; tx += $10
  }
  END { printf "net_rx\t%d\nnet_tx\t%d\n", rx, tx }
' /proc/net/dev

# ------------------------------------------------------------------ storage
emit_fs() { # $1 = path, $2 = tag
  local line u s p t
  line=$(df -B1 --output=used,size,pcent,target "$1" 2>/dev/null | tail -1)
  [[ -n $line ]] || return 0
  read -r u s p t <<<"$line"
  out "fs_${2}_used"   "$u"
  out "fs_${2}_size"   "$s"
  out "fs_${2}_pct"    "${p%\%}"
  out "fs_${2}_target" "$t"
}
emit_fs / root
emit_fs "${HOME:-/home}" home

# ---------------------------------------------------------------------- gpu
case $gpu_kind in
  nvidia)
    gpu_line=$(nvidia-smi \
      --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
      --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [[ -n $gpu_line ]]; then
      IFS=',' read -r gu gum gut gt <<<"$gpu_line"
      out gpu_util       "${gu//[[:space:]]/}"
      out gpu_vram_used  "${gum//[[:space:]]/}"
      out gpu_vram_total "${gut//[[:space:]]/}"
      out gpu_temp       "${gt//[[:space:]]/}"
    fi
    ;;
  amd)
    for d in /sys/class/drm/card[0-9]/device; do
      [[ -r $d/vendor ]] || continue
      [[ $(<"$d/vendor") =~ ^0x(1002|1022)$ ]] || continue
      [[ -r $d/gpu_busy_percent ]]    && out gpu_util "$(<"$d/gpu_busy_percent")"
      [[ -r $d/mem_info_vram_used ]]  && out gpu_vram_used  $(( $(<"$d/mem_info_vram_used") / 1048576 ))
      [[ -r $d/mem_info_vram_total ]] && out gpu_vram_total $(( $(<"$d/mem_info_vram_total") / 1048576 ))
      for h in "$d"/hwmon/hwmon*; do
        [[ -r $h/temp1_input ]] && { out gpu_temp $(( $(<"$h/temp1_input") / 1000 )); break; }
      done
      break
    done
    ;;
  intel)
    for d in /sys/class/drm/card[0-9]/device; do
      [[ -r $d/vendor && $(<"$d/vendor") == "0x8086" ]] || continue
      for h in "$d"/hwmon/hwmon*; do
        [[ -r $h/temp1_input ]] && { out gpu_temp $(( $(<"$h/temp1_input") / 1000 )); break; }
      done
      break
    done
    ;;
esac

# -------------------------------------------------------------------- agents
tmux_n=0
if command -v tmux >/dev/null 2>&1; then
  tmux_n=$(tmux ls 2>/dev/null | wc -l)
fi
out agents_tmux "$tmux_n"

# -x matches comm exactly so the regex can't match this script's own bash.
out agents_procs "$(pgrep -xc 'claude|codex|opencode|aider|gemini|crush|devin|openclaw|hermes' 2>/dev/null || echo 0)"

exit 0
