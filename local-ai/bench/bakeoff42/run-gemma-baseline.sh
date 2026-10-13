#!/usr/bin/env bash
# run-gemma-baseline.sh — clean Gemma 4 12B baseline for the bakeoff42 bake-off (kakashi, 2026-10-13).
#
# Why: the v1/v2 prompt A/B and the first Ornith run were tainted (12 watchdog kills, 3 aux-model swaps:
# Chief's auxiliary tasks are pinned to "gemma4-12b" while the suite runs on "gemma4-12b-eval"). Gemma's 26/42
# is therefore not a clean baseline for Ornith. This script reruns the 42-item Chief suite on the eval config
# (ctx 49152, same weights and launch script as the "gemma4-12b-eval" entry of serve/config.yaml) through a
# DERIVED llama-swap config in which the aux id "gemma4-12b" is an alias of the eval entry, so nothing swaps.
#
#   bash bench/bakeoff42/run-gemma-baseline.sh --dry-run   # prints config, commands, lock/gate sequence; launches nothing
#   bash bench/bakeoff42/run-gemma-baseline.sh              # the real run (the orchestrator starts it, not the author)
#
# Sequence: wait for the challenger drivers to be gone -> 60 s of quiet (no retro/report bots, PSI full avg60 < 0.3)
#           -> flock -x -w 7200 bench/.gpu.lock -> gate_check (never --force) -> derived llama-swap -> alias proof
#           -> 42-item suite -> taint verdict.
# Untouched: serve/config.yaml, the Chief profile (SOUL.md stays v2), watchdog thresholds, gate.sh.
# Output   : results/bakeoff42-gemma-eval.json (+ .md). A tainted run is renamed *.TAINTED-<n>.* and exits 6.
# Exit     : 0 clean | 3 gate refused | 4 setup/server failure | 5 VRAM breach | 6 TAINTED | 7 suite produced no result
#            | 8 waiter timeout | 75 could not take the GPU lock in 7200 s
set -uo pipefail
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
BO=$LAB/bench/bakeoff42
LOGD=$BO/logs; mkdir -p "$LOGD"
ID=gemma4-12b-eval            # entry in serve/config.yaml that the suite runs on
AUX=gemma4-12b                # Chief profile's auxiliary id, aliased onto $ID in the derived config
CFG=$BO/config.suite-$ID.yaml
OUT=results/bakeoff42-gemma-eval.json
RUNLOG=$LOGD/gemma-baseline.log
SWAPLOG=$LOGD/llama-swap-$ID.log
SUITELOG=$LOGD/suite-$ID.out
VRAMCSV=$LOGD/vram-$ID-swap.csv
BREACH=$LOGD/BREACH-$ID
PIDF=$BO/llama-swap-$ID.pid   # own pid file: never touch the challenger driver's llama-swap.pid
DRIVER_PAT='bakeoff42/quiet-rerun.sh|bakeoff42/run-challengers.sh'
BOT_PAT='RETRO-1013|LAB-REPORT-1013|UNIFIED-REPO-PLAN'
QUIET_NEED=60                 # seconds of continuous quiet
PSI_MAX=0.5                   # PSI full avg60 ceiling, memory and io
WAIT_MAX_S=${WAIT_MAX_S:-21600}   # waiter cap so an orphan cannot sleep forever
DRY=0

log(){ echo "[$(date +%T)] $*" | tee -a "$RUNLOG"; }

# ---- helpers -------------------------------------------------------------------------------------------------
psi(){ awk -F'avg60=' '/^full/{split($2,a," "); print a[1]}' "/proc/pressure/$1"; }   # full avg60 of memory|io

ancestors(){  # " pid pid ... " of this shell and its parents: a launcher whose cmdline mentions a pattern is not a blocker
  local p=$$ out=" $$ $BASHPID "
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [ -n "$p" ] && out+="$p "; done
  echo "$out"
}
matching_pids(){  # pgrep -f "$1", minus this script's own ancestry
  local chain pid; chain=$(ancestors)
  for pid in $(pgrep -f "$1" 2>/dev/null); do
    case "$chain" in *" $pid "*) continue ;; esac
    echo "$pid"
  done
}
count_pids(){ matching_pids "$1" | wc -l; }

quiet_now(){  # echoes "drivers bots psi_mem psi_io" and succeeds when all four are quiet
  local d b m i
  d=$(count_pids "$DRIVER_PAT"); b=$(count_pids "$BOT_PAT"); m=$(psi memory); i=$(psi io)
  echo "drivers=$d bots=$b psi_mem60=$m psi_io60=$i"
  [ "$d" -eq 0 ] && [ "$b" -eq 0 ] && awk -v m="$m" -v i="$i" -v x="$PSI_MAX" 'BEGIN{exit !(m<x && i<x)}'
}

wait_quiet(){
  local t0 since="" quiet=0 state last=0 now
  t0=$(date +%s)
  log "waiter: until pgrep -f \"$DRIVER_PAT\" is empty, then ${QUIET_NEED}s quiet (no \"$BOT_PAT\" processes, PSI full avg60 < $PSI_MAX memory+io)"
  while :; do
    now=$(date +%s)
    if state=$(quiet_now); then [ -z "$since" ] && since=$now; quiet=$((now-since)); else since=""; quiet=0; fi
    if [ $((now-last)) -ge 60 ] || [ "$quiet" -ge "$QUIET_NEED" ]; then log "waiter: $state quiet=${quiet}s"; last=$now; fi
    [ "$quiet" -ge "$QUIET_NEED" ] && return 0
    [ $((now-t0)) -ge "$WAIT_MAX_S" ] && { log "waiter: gave up after ${WAIT_MAX_S}s ($state)"; return 8; }
    sleep 15
  done
}

# Derived llama-swap config: the serve/config.yaml entry "gemma4-12b-eval" copied verbatim (cmd = same weights, same
# launch script, ctx 49152), alone in the file, with $AUX added as an alias. Same pattern as run-challengers.sh.
make_suite_cfg(){  # $1 = output path
  python3 - "$LAB" "$ID" "$AUX" "$1" <<'PY'
import copy, sys, yaml
lab, mid, aux, dst = sys.argv[1:5]
src = yaml.safe_load(open(f"{lab}/serve/config.yaml"))
ent = copy.deepcopy(src["models"][mid])
ent["cmd"] = " ".join(str(ent["cmd"]).split())
import os
ctx = os.environ.get("GEMMA_CTX", "49152")  # 900 MiB floor: 49152 left 857 MiB with the 18:36 desktop load
ent["cmd"] = ent["cmd"].replace(" 49152", " " + ctx)
ent.setdefault("capabilities", {})["context"] = int(ctx)
ent["name"] = f"bakeoff42 gemma baseline: {mid} ctx 49152 (alias {aux})"
ent["aliases"] = list(ent.get("aliases", [])) + [aux]
ent.setdefault("filters", {}).setdefault("setParamsByID", {})[aux] = {"chat_template_kwargs": {"enable_thinking": False}}
cfg = {k: v for k, v in src.items() if k != "models"}
cfg["models"] = {mid: ent}
hdr = (f"# GENERATED by bench/bakeoff42/run-gemma-baseline.sh from serve/config.yaml entry \"{mid}\" (not edited by hand).\n"
       f"# Suite-only llama-swap config (one model). Alias {aux}: the Chief profile pins its auxiliary tasks to that id;\n"
       f"# routing it onto {mid} stops llama-swap from swapping the model mid-run. serve/config.yaml and the profile are untouched.\n")
open(dst, "w").write(hdr + yaml.safe_dump(cfg, sort_keys=False, width=100000, default_flow_style=False))
PY
}

stop_sampler(){ [ -n "${SAMP:-}" ] && { kill "$SAMP" 2>/dev/null; wait "$SAMP" 2>/dev/null; }; SAMP=""; }
stop_stack(){  # only the llama-swap this script started, then the llama-server children on its 181xx pool
  if [ -f "$PIDF" ]; then
    local P i; P=$(cat "$PIDF")
    kill -TERM "$P" 2>/dev/null
    for i in $(seq 1 20); do kill -0 "$P" 2>/dev/null || break; sleep 1; done
    kill -KILL "$P" 2>/dev/null; rm -f "$PIDF"
  fi
  pkill -TERM -f '[l]lama-server.*--port 181' 2>/dev/null; sleep 2
  pkill -KILL -f '[l]lama-server.*--port 181' 2>/dev/null
  return 0
}
cleanup(){ stop_sampler; stop_stack; }

gate_wait(){
  local i
  for i in $(seq 1 60); do gate_check && return 0; log "gate refused (nothing killed), waiting 60 s (attempt $i/60)"; sleep 60; done
  return 1
}

req_status(){  # model id -> http status of a tiny chat completion through llama-swap
  curl -sS -m 300 -o "${TMPDIR:-/tmp}/gemma-baseline-req.json" -w '%{http_code}' http://127.0.0.1:18080/v1/chat/completions \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word ok.\"}],\"max_tokens\":8,\"temperature\":0}"
}

# Taint verdict from three independent witnesses of "an upstream was killed or replaced during the run":
#   llama-swap log  : upstream starts (Health check passed) beyond the first, unexpected exits, premature exits,
#                     '[watchdog] ABORT-LAG' stderr lines (logToStdout: both), starts of any id other than $ID
#   results-matrix  : ABORT-LAG rows written since the run started (the watchdog label is hard-coded, so match by time)
# n = max over the witnesses (they describe the same event, so they are not summed). Prints "n details".
taint_verdict(){  # $1 = swap log, $2 = start ISO timestamp
  python3 - "$1" "$2" "$LAB/bench/results-matrix.tsv" "$ID" <<'PY'
import re, sys
swaplog, t0, matrix, mid = sys.argv[1:5]
txt = open(swaplog, errors="replace").read() if __import__("os").path.exists(swaplog) else ""
starts = re.findall(r"^\[INFO\] <([^>]+)> Health check passed", txt, re.M)
unexpected = len(re.findall(r"upstream process exited unexpectedly", txt))
premature = len(re.findall(r"upstream command exited prematurely", txt))
wd_stderr = len(re.findall(r"\[watchdog\] ABORT-LAG", txt))
recovered = len(re.findall(r"recovered from upstream disconnection", txt))   # info only: can be a client cancel
rows = 0
try:
    for line in open(matrix, errors="replace"):
        f = line.split("\t")
        if f and f[0] >= t0 and "ABORT-LAG" in line:
            rows += 1
except OSError:
    pass
foreign = sorted(set(starts) - {mid})
n = max(len(starts) - 1, 0, unexpected, premature, wd_stderr, rows)
print(n, f"upstream_starts={len(starts)} restarts_by_starts={max(len(starts)-1,0)} unexpected_exits={unexpected} "
         f"premature_exits={premature} watchdog_stderr={wd_stderr} matrix_abort_rows={rows} foreign_ids={foreign or 'none'} "
         f"recovered_info_only={recovered}")
PY
}

# ---- locked phase: runs only inside flock -x on bench/.gpu.lock ---------------------------------------------------
locked_phase(){
  cd "$LAB" || exit 4
  source bench/gate.sh
  set +u; . bench/configs/sycl-env.sh; set -u
  trap cleanup EXIT
  trap 'log "interrupted: stopping stack"; exit 4' INT TERM
  log "lock held: bench/.gpu.lock"

  gate_wait || { log "gate refused for 60 min: no run"; exit 3; }
  io_quiet_wait || { log "disk busy (io full avg10=${IO_BUSY:-?}): no run"; exit 3; }
  pgrep -f '[l]lama-server' >/dev/null && { log "a llama-server is running (not ours): no run"; exit 3; }
  curl -sf -m 2 http://127.0.0.1:18080/v1/models >/dev/null && { log ":18080 already answers (not ours): no run"; exit 3; }
  log "gate_check ok (never --force), idle free VRAM: $(python3 bench/arc-vram.py 2>/dev/null | sed -n 's/.*free=\([0-9]*\).*/\1 MiB/p')"

  # Launch environment: eval defaults only. No MTP, default watchdog thresholds.
  unset WATCH_PSI_FULL_MAX WATCH_MEM_MIN_MIB; export MTP_NMAX=0

  make_suite_cfg "$CFG" || { log "derived config: generation failed"; exit 4; }
  llama-swap -config "$CFG" -validate > "$LOGD/validate-$ID.out" 2>&1 || { log "derived config invalid: $(tail -1 "$LOGD/validate-$ID.out")"; exit 4; }
  log "derived config $CFG valid: $(tail -1 "$LOGD/validate-$ID.out")"

  [ -e "$OUT" ] && { mv -f "$OUT" "$OUT.prev-$(date +%H%M%S)"; [ -e "${OUT%.json}.md" ] && mv -f "${OUT%.json}.md" "${OUT%.json}.md.prev-$(date +%H%M%S)"; }
  rm -f "$BREACH" "$VRAMCSV"
  T0ISO=$(date -Iseconds)
  setsid nohup python3 "$BO/vram-sampler.py" "$VRAMCSV" "$BREACH" >/dev/null 2>&1 & SAMP=$!
  log "sampler: free VRAM every 2 s -> $VRAMCSV (breach below 900 MiB stops the run)"

  : > "$SWAPLOG"
  setsid llama-swap -config "$CFG" -listen 127.0.0.1:18080 > "$SWAPLOG" 2>&1 &
  echo $! > "$PIDF"
  local i; for i in $(seq 1 60); do curl -sf -m 2 http://127.0.0.1:18080/v1/models >/dev/null && break; sleep 1; done
  curl -sf -m 3 http://127.0.0.1:18080/v1/models >/dev/null || { log "llama-swap not answering"; exit 4; }

  # Alias proof: the aux id must be served by the already-loaded eval upstream, no second start.
  local c1 c2
  c1=$(req_status "$AUX"); c2=$(req_status "$ID")
  log "alias proof: $AUX -> HTTP $c1, $ID -> HTTP $c2, running: $(curl -s -m 3 http://127.0.0.1:18080/running | tr -d '\n ')"
  if [ "$c1" != 200 ] || [ "$c2" != 200 ]; then log "alias proof failed: no suite"; exit 4; fi

  log "suite: 42 items on $ID (ctx 49152, Chief SOUL v2) -> $OUT"
  LC_LOCKED=1 python3 evals/chief/run_suite.py --model "$ID" --out "$OUT" > "$SUITELOG" 2>&1
  local src=$?
  log "suite rc=$src"
  stop_sampler; stop_stack

  local mf; mf=$(python3 -c 'import sys
v=[int(l.split(",")[1]) for l in open(sys.argv[1]) if l[0].isdigit()]
print(min(v) if v else "NA", len(v))' "$VRAMCSV" 2>/dev/null)
  log "VRAM min free / samples: ${mf:-NA}"

  local tv n detail
  tv=$(taint_verdict "$SWAPLOG" "$T0ISO"); n=${tv%% *}; detail=${tv#* }
  log "TAINTED=$n restarts ($detail)"

  if [ "${n:-0}" -gt 0 ]; then
    for ext in json md; do [ -e "${OUT%.json}.$ext" ] && mv -f "${OUT%.json}.$ext" "${OUT%.json}.TAINTED-$n.$ext"; done
    log "run is NOT a clean baseline; result kept as ${OUT%.json}.TAINTED-$n.json"
    exit 6
  fi
  if [ -e "$BREACH" ]; then log "BREACH: $(cat "$BREACH")"; exit 5; fi
  case "$detail" in upstream_starts=0\ *) log "llama-swap log shows no upstream start: no valid run"; exit 7 ;; esac
  if [ "$src" != 0 ] || [ ! -s "$OUT" ]; then log "suite produced no result (rc=$src)"; exit 7; fi
  log "CLEAN: $OUT ($(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sum(i["verdict"]=="PASS" for i in d["items"]),"/",len(d["items"]),"PASS")' "$OUT" 2>/dev/null))"
  exit 0
}

# ---- dry run: print what would happen, launch nothing -------------------------------------------------------------
dry_run(){
  local tmp rc state gp grc
  tmp=$(mktemp "${TMPDIR:-/tmp}/config.suite-$ID.XXXXXX.yaml")
  make_suite_cfg "$tmp" || { echo "derived config generation FAILED"; exit 4; }
  echo "== DRY RUN: nothing is launched, no repo file is written =="
  echo
  echo "== 1. derived llama-swap config (would be written to $CFG) =="
  cat "$tmp"
  echo "-- llama-swap -config <derived> -validate:"
  llama-swap -config "$tmp" -validate 2>&1 | tail -1
  rm -f "$tmp"
  echo
  echo "== 2. waiter (read-only probe of the current box state) =="
  echo "driver wait : pgrep -f \"$DRIVER_PAT\" must be empty (this script's own ancestry is ignored)"
  echo "quiet wait  : ${QUIET_NEED}s continuous: no \"$BOT_PAT\" processes, PSI full avg60 < $PSI_MAX for memory and io (sampled every 15 s, any miss resets the clock)"
  echo "cap         : gives up with exit 8 after WAIT_MAX_S=${WAIT_MAX_S}s"
  state=$(quiet_now); rc=$?
  echo "now         : $state -> $([ $rc -eq 0 ] && echo 'quiet sample' || echo 'NOT quiet, would keep waiting')"
  echo "blocking drivers now: $(matching_pids "$DRIVER_PAT" | tr '\n' ' ')"
  echo
  echo "== 3. lock + gate sequence =="
  echo "flock -x -w 7200 -E 75 $LAB/bench/.gpu.lock env LC_LOCKED=1 bash $BO/run-gemma-baseline.sh --locked"
  echo "  in lock : source bench/gate.sh; gate_check (up to 60 x 60 s, NEVER --force); io_quiet_wait; no llama-server running; :18080 silent"
  gp=$( (source "$LAB/bench/gate.sh"; gate_check) 2>&1 ); grc=$?
  echo "  gate probe now (read-only gate_check, no --force): rc=$grc ${gp:+$(echo "$gp" | tr '\n' ' ')}"
  echo
  echo "== 4. exact commands inside the lock (env: MTP_NMAX=0, WATCH_PSI_FULL_MAX/WATCH_MEM_MIN_MIB unset = watchdog defaults) =="
  echo "python3 $BO/vram-sampler.py $VRAMCSV $BREACH        # free VRAM every 2 s, breach < 900 MiB stops the run"
  echo "setsid llama-swap -config $CFG -listen 127.0.0.1:18080 > $SWAPLOG 2>&1 &"
  echo "curl .../v1/chat/completions model=$AUX  (must be HTTP 200, served by the $ID upstream)   # alias proof"
  echo "curl .../v1/chat/completions model=$ID   (must be HTTP 200, no second upstream start)"
  echo "cd $LAB && LC_LOCKED=1 python3 evals/chief/run_suite.py --model $ID --out $OUT > $SUITELOG 2>&1"
  echo "stop: SIGTERM our llama-swap (pid file $PIDF), then pkill llama-server --port 181xx"
  echo
  echo "== 5. taint rule (exit 6 when n > 0; line TAINTED=<n> restarts is written to $RUNLOG) =="
  echo "n = max( upstream starts - 1 [Health check passed in $SWAPLOG], 'upstream process exited unexpectedly',"
  echo "         'upstream command exited prematurely', '[watchdog] ABORT-LAG' lines, results-matrix.tsv ABORT-LAG rows since start )"
  echo "tainted result is renamed ${OUT%.json}.TAINTED-<n>.json; clean result stays $OUT"
  echo "exit codes: 0 clean | 3 gate refused | 4 setup failure | 5 VRAM breach | 6 TAINTED | 7 no result | 8 waiter timeout | 75 lock timeout"
  exit 0
}

# ---- entry ------------------------------------------------------------------------------------------------------
case "${1:-}" in
  --dry-run) dry_run ;;
  --locked)  locked_phase ;;
  "")        ;;
  *)         echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

cd "$LAB" || exit 2
log "gemma baseline start pid $$ (id $ID, aux alias $AUX, out $OUT)"
wait_quiet; rc=$?
[ "$rc" -ne 0 ] && exit "$rc"
exec flock -x -w 7200 -E 75 bench/.gpu.lock env LC_LOCKED=1 bash "$BO/run-gemma-baseline.sh" --locked
