#!/bin/bash
# run-nested.sh - private compositor for measuring the REAL Quickshell HUD.
#
# usage: run-nested.sh start | stop | shot <png> | cpu <seconds> | status
#
# env: HUD_DIR       plugin dir to run (default the v5-live worktree)
#      NESTED_DIR   state dir (default ~/.hudlive-c, short path on purpose)
#      NESTED_SIZE  output size (default 2560x1440)
#
# SAFETY: everything here runs with WAYLAND_DISPLAY, DISPLAY and
# HYPRLAND_INSTANCE_SIGNATURE unset, under its own XDG_RUNTIME_DIR, so it can
# never attach to the live session. Nothing is stopped by pattern; PIDs only.
#
# STATUS OF THE HEADLESS BACKEND (2026-10-23, Hyprland 0.56.2, aquamarine 0.15.1):
# Hyprland aborts with "CBackend::create() failed!" before it creates a socket,
# both with AQ_BACKENDS=headless and with AQ_BACKENDS unset. AQ_BACKENDS with a
# bogus value produces the same error, so this aquamarine build does not read
# that variable at all. No other headless compositor is installed on this box
# (sway, weston, cage, labwc, wayfire, river, niri, kwin_wayland: all missing).
# So `start` currently reports the failure and exits 3; shot/cpu are written and
# tested against the expected socket so they start working the day a headless
# compositor works here.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
HUD_DIR=${HUD_DIR:-/home/nexuslink/hud-wt/v5-live/nexuslink.hud}
NESTED_DIR=${NESTED_DIR:-$HOME/.hudlive-c}
SIZE=${NESTED_SIZE:-2560x1440}
PIDFILE=$NESTED_DIR/pids
SOCKFILE=$NESTED_DIR/socket
CFG=$NESTED_DIR/cfg

mkdir -p "$NESTED_DIR"/{run,cfg,cache,logs}

clean_env() {
  env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    XDG_RUNTIME_DIR="$NESTED_DIR/run" \
    XDG_CONFIG_HOME="$CFG" \
    XDG_CACHE_HOME="$NESTED_DIR/cache" \
    "$@"
}

nested_socket() {
  # Hyprland names its socket wayland-N; pick the one inside our runtime dir.
  ls "$NESTED_DIR/run" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1
}

do_start() {
  local sock
  sock=$(nested_socket)
  if [ -n "$sock" ]; then
    echo "already running: WAYLAND_DISPLAY=$sock"
    exit 0
  fi
  : > "$PIDFILE"

  # Nested Hyprland needs a parent Wayland display. Refuse to use the live one.
  local hypr_pid
  clean_env AQ_BACKENDS=headless HYPRLAND_NO_CRASHREPORTER=1 \
    setsid Hyprland -c "$HERE/hyprland.lua" > "$NESTED_DIR/logs/hyprland.log" 2>&1 &
  hypr_pid=$!
  echo "$hypr_pid" >> "$PIDFILE"
  sleep 3

  if ! kill -0 "$hypr_pid" 2>/dev/null; then
    echo "FAILED: compositor exited. Last lines:" >&2
    tail -5 "$NESTED_DIR/logs/hyprland.log" >&2
    grep -q 'CBackend::create() failed' "$NESTED_DIR/logs/hyprland.log" \
      && echo "reason: no usable aquamarine backend (headless not supported in this build)" >&2
    rm -f "$PIDFILE"
    exit 3
  fi

  sock=$(nested_socket)
  if [ -z "$sock" ]; then
    echo "FAILED: compositor alive but no wayland socket in $NESTED_DIR/run" >&2
    kill "$hypr_pid" 2>/dev/null
    rm -f "$PIDFILE"
    exit 4
  fi
  echo "$sock" > "$SOCKFILE"

  # Size the headless output. Address only our own instance.
  local sig
  sig=$(basename "$(ls -d "$NESTED_DIR"/run/hypr/*/ 2>/dev/null | head -1)")
  if [ -n "$sig" ]; then
    HYPRLAND_INSTANCE_SIGNATURE=$sig XDG_RUNTIME_DIR="$NESTED_DIR/run" \
      hyprctl -i "$sig" output create headless >/dev/null 2>&1
    HYPRLAND_INSTANCE_SIGNATURE=$sig XDG_RUNTIME_DIR="$NESTED_DIR/run" \
      hyprctl -i "$sig" keyword monitor "HEADLESS-1,${SIZE}@60,0x0,1" >/dev/null 2>&1
    echo "$sig" >> "$PIDFILE"
  fi

  # The real shell, unpatched, on our socket only.
  local qs_pid
  env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    WAYLAND_DISPLAY="$sock" XDG_RUNTIME_DIR="$NESTED_DIR/run" \
    QT_QPA_PLATFORM=wayland \
    setsid quickshell -n -p "$HUD_DIR" > "$NESTED_DIR/logs/quickshell.log" 2>&1 &
  qs_pid=$!
  echo "$qs_pid" >> "$PIDFILE"

  echo "compositor pid=$hypr_pid wayland_display=$sock instance=$sig"
  echo "quickshell  pid=$qs_pid plugin=$HUD_DIR"
}

do_stop() {
  [ -f "$PIDFILE" ] || { echo "not running (no pidfile)"; exit 0; }
  local p
  for p in $(cat "$PIDFILE"); do
    case "$p" in ''|*[!0-9]*) continue;; esac
    if kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2>/dev/null || break; sleep 0.3; done
      kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
      echo "stopped $p"
    fi
  done
  rm -f "$PIDFILE" "$SOCKFILE"
}

do_status() {
  if [ ! -f "$PIDFILE" ]; then echo "stopped"; exit 0; fi
  local p alive=0
  for p in $(cat "$PIDFILE"); do
    case "$p" in ''|*[!0-9]*) continue;; esac
    if kill -0 "$p" 2>/dev/null; then
      printf '%s alive  %s\n' "$p" "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-90)"
      alive=1
    fi
  done
  [ "$alive" = 1 ] || { echo "stopped (stale pidfile)"; exit 0; }
  echo "socket: $(cat "$SOCKFILE" 2>/dev/null || echo none)"
}

do_shot() {
  local out=${1:?usage: run-nested.sh shot <png>}
  local sock; sock=$(cat "$SOCKFILE" 2>/dev/null)
  [ -n "$sock" ] || { echo "no nested socket (run start first)" >&2; exit 2; }
  local output=${NESTED_OUTPUT:-HEADLESS-1}
  nice -n 19 ionice -c3 env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    WAYLAND_DISPLAY="$sock" XDG_RUNTIME_DIR="$NESTED_DIR/run" \
    grim -o "$output" "$out" || {
      echo "grim -o $output failed; retrying full output capture" >&2
      nice -n 19 ionice -c3 env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
        WAYLAND_DISPLAY="$sock" XDG_RUNTIME_DIR="$NESTED_DIR/run" grim "$out" || exit 5
    }
  echo "$out"
}

do_cpu() {
  # usage: cpu <seconds>  - samples the quickshell PID only, 1 s apart
  local secs=${1:-60}
  local qs
  qs=$(sed -n '2p' "$PIDFILE" 2>/dev/null)
  [ -n "$qs" ] && kill -0 "$qs" 2>/dev/null || { echo "quickshell not running" >&2; exit 2; }
  local t0 a0 b0 t1 a1 b1 hz ticks
  hz=$(getconf CLK_TCK)
  read -r a0 b0 < <(awk '{print $14, $15}' /proc/$qs/stat)
  t0=$(date +%s.%N)
  sleep "$secs"
  read -r a1 b1 < <(awk '{print $14, $15}' /proc/$qs/stat)
  t1=$(date +%s.%N)
  ticks=$(( (a1 + b1) - (a0 + b0) ))
  awk -v ticks="$ticks" -v hz="$hz" -v t0="$t0" -v t1="$t1" \
    'BEGIN{cpu=ticks/hz/(t1-t0)*100; printf "quickshell pid %s: %.2f %% cpu over %.1f s (%d ticks @ %d Hz)\n", "'"$qs"'", cpu, t1-t0, ticks, hz}'
  awk '/^VmRSS/{printf "rss %.1f MB\n", $2/1024}' /proc/$qs/status
  echo "threads $(awk '/^Threads/{print $2}' /proc/$qs/status)"
}

case "${1:-}" in
  start)  do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
  shot)   shift; do_shot "$@" ;;
  cpu)    shift; do_cpu "$@" ;;
  *) echo "usage: $0 start|stop|shot <png>|cpu <seconds>|status" >&2; exit 64 ;;
esac
