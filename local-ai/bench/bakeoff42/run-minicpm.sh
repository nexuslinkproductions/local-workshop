#!/usr/bin/env bash
# run-minicpm.sh — MiniCPM-V-4.7-35B-A3B Q8_0 for the bakeoff42 Chief bake-off (built 2026-10-13, NOT launched).
#
# Mirrors bench/bakeoff42/run-gemma-baseline.sh: waiter -> flock -x on bench/.gpu.lock -> gate_check (never --force)
# -> placement sweep -> 42-item Chief suite through a DERIVED llama-swap config that also answers gemma4-12b.
#
#   bash bench/bakeoff42/run-minicpm.sh --dry-run   # prints every command and derived config; launches nothing
#   bash bench/bakeoff42/run-minicpm.sh             # the real run (the orchestrator starts it, not the author)
#
# Backend: SYCL (engines/llama.cpp-sycl-tip, device SYCL0). Vulkan is not required: research/12 records no open
# Vulkan vision bug for qwen35 (the open ones are qwen4exp #29093), and the sibling-MoE placement numbers are SYCL
# numbers. Vulkan vision is untested here. serve/config.yaml (Vulkan placeholder) is not touched.
#
# Sequence: wait for the drivers to be gone -> 60 s of quiet -> flock -x -w 7200 bench/.gpu.lock -> gate_check
#   -> sweep (ctx 49152, KV q8_0, n-cpu-moe 41 36 32 28; mmproj f16 on GPU, CPU fallback if 41 does not fit)
#   -> derived llama-swap config for the chosen point (aliases minicpm-v47 + gemma4-12b) -> alias proof
#   -> 42-item suite -> taint verdict.
# Sweep stop rule: a point is accepted when its probe is OK, free VRAM never dropped below 1200 MiB and no breach
#   (< 900 MiB, the sampler stops the run). The first rejected point ends the sweep; the last accepted point is used.
# Output: logs/minicpm-sweep.json (every point, with decode t/s, 4K prefill t/s, load time, min free VRAM);
#         results/bakeoff42-minicpm-v47.json (+ .md). Tainted run: renamed *.TAINTED-<n>.*, exit 6.
# Exit  : 0 clean | 3 gate refused | 4 setup failure or no placement fits | 5 VRAM breach | 6 TAINTED
#         | 7 suite produced no result | 8 waiter timeout | 75 could not take the GPU lock in 7200 s
set -uo pipefail
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
BO=$LAB/bench/bakeoff42
SELF=$BO/run-minicpm.sh
LOGD=$BO/logs; mkdir -p "$LOGD"
ID=minicpm-v-4.7-35b-a3b      # upstream id (the key in the derived config, the name in the swap log)
AUX=minicpm-v47               # --model id for the Chief suite
AUX2=gemma4-12b               # Chief profile's auxiliary id, aliased onto $ID
CTX="${MINICPM_CTX:-262144}"   # Marcel 19:03: 256K directly, no small ctx
KV="${MINICPM_KV:-q4_0}"   # Marcel 19:12: 4-bit KV, no 8-bit
MD=$LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf
M="${MINICPM_GGUF:-$MD/MiniCPM-V-4.7-35B-A3B-AD-Q4_K-IQ4_XS.gguf}"   # Q8_0 (36.9 GB) stalled RAM on load
MM=$MD/mmproj-model-f16.gguf          # full projector (not the 4x one)
G=$LAB/engines/llama.cpp-sycl-tip/build/bin/llama-server
SWEEP_NCMOE="${MINICPM_NCMOE:-41 36 32 28}"
MIN_FREE=750   # Marcel 21:00 floor (was 900)
SWEEP=$LOGD/minicpm-sweep.json
CFG=$BO/config.suite-$ID.yaml
OUT=results/bakeoff42-minicpm-v47.json
RUNLOG=$LOGD/run-minicpm.log
SWAPLOG=$LOGD/llama-swap-$ID.log
SUITELOG=$LOGD/suite-$ID.out
VRAMCSV=$LOGD/vram-$ID-swap.csv
BREACH=$LOGD/BREACH-$ID
PIDF=$BO/llama-swap-$ID.pid           # own pid file: never touch the challenger driver's llama-swap.pid
DRIVER_PAT='bakeoff42/quiet-rerun.sh|bakeoff42/run-challengers.sh|bakeoff42/run-gemma-baseline.sh|bench/mtp-after-bakeoff.sh|bench/r46-tiers.sh'
BOT_PAT='RETRO-1013|LAB-REPORT-1013|UNIFIED-REPO-PLAN'
QUIET_NEED=60
PSI_MAX=0.5
WAIT_MAX_S=${WAIT_MAX_S:-21600}
BEST_N=""; BEST_MM=""; SAMP=""

log(){ echo "[$(date +%T)] $*" | tee -a "$RUNLOG"; }

# ---- helpers (same rules as run-gemma-baseline.sh) ----------------------------------------------------------------
psi(){ awk -F'avg60=' '/^full/{split($2,a," "); print a[1]}' "/proc/pressure/$1"; }

ancestors(){
  local p=$$ out=" $$ $BASHPID "
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [ -n "$p" ] && out+="$p "; done
  echo "$out"
}
matching_pids(){
  local chain pid; chain=$(ancestors)
  for pid in $(pgrep -f "$1" 2>/dev/null); do
    case "$chain" in *" $pid "*) continue ;; esac
    echo "$pid"
  done
}
count_pids(){ matching_pids "$1" | wc -l; }

quiet_now(){
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

# Derived llama-swap config. mode=sweep: one point, no aliases. mode=suite: aliases $AUX and $AUX2 added.
# cmd = gate-run.sh (ARC Raiders check) -> this script in --serve mode (watchdog -> ionice -> jobcap -> llama-server).
make_cfg(){  # $1 out  $2 n-cpu-moe  $3 gpu|cpu  $4 sweep|suite
  python3 - "$LAB" "$ID" "$1" "$2" "$3" "$4" "$SELF" "$CTX" "$AUX" "$AUX2" <<'PY'
import sys, yaml
lab, mid, dst, ncmoe, mm, mode, self_, ctx, aux, aux2 = sys.argv[1:11]
src = yaml.safe_load(open(f"{lab}/serve/config.yaml"))
def off(): return {"chat_template_kwargs": {"enable_thinking": False}}   # fresh dict per id: no YAML anchors
ids = {mid: off()} if mode == "sweep" else {mid: off(), aux: off(), aux2: off()}
ent = {
    "name": f"bakeoff42 MiniCPM-V-4.7 Q8_0 ({mode}): n-cpu-moe {ncmoe}, mmproj {mm}, ctx {ctx}",
    "cmd": f"{lab}/serve/gate-run.sh bash {self_} --serve ${{PORT}} {ctx} {ncmoe} {mm}",
    "ttl": 600,
    "filters": {"setParamsByID": ids},
    "capabilities": {"in": ["text", "image"], "out": ["text"], "tools": True, "context": int(ctx)},
}
if mode == "suite":
    ent["aliases"] = [aux, aux2]
cfg = {k: v for k, v in src.items() if k != "models"}
cfg["models"] = {mid: ent}
hdr = (f"# GENERATED by bench/bakeoff42/run-minicpm.sh ({mode}) from serve/config.yaml top-level keys (not edited by hand).\n"
       f"# One MiniCPM point: n-cpu-moe {ncmoe}, mmproj {mm}, ctx {ctx}. Suite mode aliases {aux} and {aux2} onto {mid},\n"
       f"# so the Chief profile's auxiliary tasks never swap the model. serve/config.yaml and the profile are untouched.\n")
open(dst, "w").write(hdr + yaml.safe_dump(cfg, sort_keys=False, width=100000, default_flow_style=False))
PY
}

# llama-server argv for one point (printed in dry-run; the same flags serve mode execs).
server_argv(){  # $1 port $2 n-cpu-moe $3 gpu|cpu
  local x=""; [ "$3" = cpu ] && x="--no-mmproj-offload "
  echo "$G -m $M --mmproj $MM ${x}--host 127.0.0.1 --port $1 --device SYCL0 -ngl 99 --n-cpu-moe $2 -c $CTX -np 1 -t 16 -fa on -ctk $KV -ctv $KV -b 1024 -ub 1024 -lm dio -fit off --jinja --temp 0 --repeat-penalty 1.05"
}

start_sampler(){ rm -f "$1"; setsid nohup python3 "$BO/vram-sampler.py" "$1" "$2" >/dev/null 2>&1 & SAMP=$!; }
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
  curl -sS -m 300 -o "${TMPDIR:-/tmp}/minicpm-req.json" -w '%{http_code}' http://127.0.0.1:18080/v1/chat/completions \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word ok.\"}],\"max_tokens\":8,\"temperature\":0}"
}

# Taint verdict: same three witnesses as run-gemma-baseline.sh (swap log, results-matrix ABORT-LAG rows since start).
taint_verdict(){  # $1 = swap log, $2 = start ISO timestamp
  python3 - "$1" "$2" "$LAB/bench/results-matrix.tsv" "$ID" <<'PY'
import re, sys, os
swaplog, t0, matrix, mid = sys.argv[1:5]
txt = open(swaplog, errors="replace").read() if os.path.exists(swaplog) else ""
starts = re.findall(r"^\[INFO\] <([^>]+)> Health check passed", txt, re.M)
unexpected = len(re.findall(r"upstream process exited unexpectedly", txt))
premature = len(re.findall(r"upstream command exited prematurely", txt))
wd_stderr = len(re.findall(r"\[watchdog\] ABORT-LAG", txt))
recovered = len(re.findall(r"recovered from upstream disconnection", txt))
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

# One sweep point: derived config -> llama-swap -> sampler -> probe -> stop. Prints the probe line.
probe(){  # $1 gpu|cpu  $2 n-cpu-moe  $3 csv  $4 breach flag  -> appends a row to $SWEEP, prints accepted=0|1 ...
  python3 - "$SWEEP" "$3" "$4" "$1" "$2" "$CTX" "$KV" "$MIN_FREE" "$ID" <<'PY'
import json, os, sys, time, urllib.request
sweep, csv, brf, mode, n, ctx, kv, minfree, mid = sys.argv[1:10]
EP = "http://127.0.0.1:18080/v1/chat/completions"
row = {"mmproj": mode, "n_cpu_moe": int(n), "ctx": int(ctx), "kv": kv, "time": time.strftime("%FT%T")}
def post(content, max_tokens):
    body = json.dumps({"model": mid, "messages": [{"role": "user", "content": content}],
                       "max_tokens": max_tokens, "temperature": 0}).encode()
    req = urllib.request.Request(EP, data=body, headers={"Content-Type": "application/json"})
    t = time.monotonic()
    with urllib.request.urlopen(req, timeout=1800) as r:
        return json.loads(r.read()), time.monotonic() - t
try:
    _, load = post("Say OK", 8)                        # first request pays the model load
    row["load_s_incl_first_reply"] = round(load, 1)
    r, _ = post("Count from 1 to 120, one number per line.", 128)
    tm = r.get("timings", {})
    row["decode_tps"] = tm.get("predicted_per_second"); row["decode_tokens"] = tm.get("predicted_n")
    filler = ("The quick brown fox jumps over the lazy dog near the riverbank at dawn. " * 240)[:17000]  # ~4K tokens
    r, _ = post("Read this text and reply with the single word DONE.\n\n" + filler, 1)
    tm = r.get("timings", {})
    row["prefill_4k_tps"] = tm.get("prompt_per_second"); row["prefill_tokens"] = tm.get("prompt_n")
    row["probe_ok"] = True
except Exception as e:
    row["probe_ok"] = False; row["error"] = repr(e)[:300]
free = []
try:
    for line in open(csv):
        f = line.strip().split(",")
        if len(f) == 2 and f[1].isdigit():
            free.append(int(f[1]))
except OSError:
    pass
row["min_free_mib"] = min(free) if free else None
row["samples"] = len(free)
row["breach"] = os.path.exists(brf)
row["accepted"] = bool(row["probe_ok"] and not row["breach"] and row["min_free_mib"] is not None
                       and row["min_free_mib"] >= int(minfree))
rows = json.load(open(sweep)) if os.path.exists(sweep) else []
rows.append(row); json.dump(rows, open(sweep, "w"), indent=2)
print(f"accepted={int(row['accepted'])} min_free={row['min_free_mib']} decode_tps={row.get('decode_tps')} "
      f"prefill_4k_tps={row.get('prefill_4k_tps')} load_s={row.get('load_s_incl_first_reply')} probe_ok={row['probe_ok']}")
PY
}

run_cfg(){  # $1 gpu|cpu  $2 n-cpu-moe
  local mm=$1 n=$2 tag="sweep-$1-$2"
  local cfg=$LOGD/config.$tag.yaml csv=$LOGD/vram-$tag.csv brf=$LOGD/BREACH-$tag line
  make_cfg "$cfg" "$n" "$mm" sweep || { echo "accepted=0 config generation failed"; return 0; }
  llama-swap -config "$cfg" -validate > "$LOGD/validate-$tag.out" 2>&1 || { echo "accepted=0 config invalid"; return 0; }
  rm -f "$brf"
  start_sampler "$csv" "$brf"
  setsid llama-swap -config "$cfg" -listen 127.0.0.1:18080 > "$LOGD/llama-swap-$tag.log" 2>&1 &
  echo $! > "$PIDF"
  local i; for i in $(seq 1 60); do curl -sf -m 2 http://127.0.0.1:18080/v1/models >/dev/null && break; sleep 1; done
  line=$(probe "$mm" "$n" "$csv" "$brf")
  stop_sampler; stop_stack
  echo "$line"
}

sweep_phase(){  # sets BEST_N / BEST_MM; returns 1 when no point is accepted in either mmproj mode
  local mm n line
  for mm in gpu cpu; do
    BEST_N=""; BEST_MM=""
    for n in $SWEEP_NCMOE; do
      line=$(run_cfg "$mm" "$n"); log "sweep mmproj=$mm n-cpu-moe=$n: $line"
      case "$line" in accepted=1*) BEST_N=$n; BEST_MM=$mm ;; *) break ;; esac
    done
    [ -n "$BEST_N" ] && return 0
    [ "$mm" = gpu ] && log "mmproj on GPU: no point accepted (first point does not fit with the projector): retry with projector on CPU"
  done
  return 1
}

# ---- locked phase: runs only inside flock -x on bench/.gpu.lock -----------------------------------------------------
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
  log "gate_check ok (never --force), idle free VRAM: $(python3 bench/arc-vram.py 2>/dev/null | sed -n 's/.*free=\([0-9]*\) MiB.*/\1 MiB/p')"

  [ -e "$SWEEP" ] && mv -f "$SWEEP" "$SWEEP.prev-$(date +%H%M%S)"
  log "sweep: ctx $CTX KV $KV, n-cpu-moe $SWEEP_NCMOE, accept if min free >= $MIN_FREE MiB -> $SWEEP"
  sweep_phase || { log "no placement accepted in either mmproj mode: no suite"; exit 4; }
  log "chosen: n-cpu-moe $BEST_N, mmproj $BEST_MM (last accepted point of the sweep)"
  python3 -c 'import json,sys
p, mm, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = json.load(open(p))
for r in rows: r["chosen"] = (r["mmproj"] == mm and r["n_cpu_moe"] == n)
json.dump(rows, open(p, "w"), indent=2)' "$SWEEP" "$BEST_MM" "$BEST_N"

  # ---- suite on the chosen point, through the derived config (aliases minicpm-v47, gemma4-12b) ----
  make_cfg "$CFG" "$BEST_N" "$BEST_MM" suite || { log "derived config: generation failed"; exit 4; }
  llama-swap -config "$CFG" -validate > "$LOGD/validate-$ID.out" 2>&1 || { log "derived config invalid: $(tail -1 "$LOGD/validate-$ID.out")"; exit 4; }
  log "derived config $CFG valid: $(tail -1 "$LOGD/validate-$ID.out")"

  [ -e "$OUT" ] && { mv -f "$OUT" "$OUT.prev-$(date +%H%M%S)"; [ -e "${OUT%.json}.md" ] && mv -f "${OUT%.json}.md" "${OUT%.json}.md.prev-$(date +%H%M%S)"; }
  rm -f "$BREACH" "$VRAMCSV"
  T0ISO=$(date -Iseconds)
  start_sampler "$VRAMCSV" "$BREACH"
  log "sampler: free VRAM every 2 s -> $VRAMCSV (breach below 750 MiB stops the run)"

  : > "$SWAPLOG"
  setsid llama-swap -config "$CFG" -listen 127.0.0.1:18080 > "$SWAPLOG" 2>&1 &
  echo $! > "$PIDF"
  local i; for i in $(seq 1 60); do curl -sf -m 2 http://127.0.0.1:18080/v1/models >/dev/null && break; sleep 1; done
  curl -sf -m 3 http://127.0.0.1:18080/v1/models >/dev/null || { log "llama-swap not answering"; exit 4; }

  # Alias proof: both aux ids must be served by the single $ID upstream, no second start.
  local c1 c2 c3
  c1=$(req_status "$AUX"); c2=$(req_status "$AUX2"); c3=$(req_status "$ID")
  log "alias proof: $AUX -> HTTP $c1, $AUX2 -> HTTP $c2, $ID -> HTTP $c3, running: $(curl -s -m 3 http://127.0.0.1:18080/running | tr -d '\n ')"
  if [ "$c1" != 200 ] || [ "$c2" != 200 ] || [ "$c3" != 200 ]; then log "alias proof failed: no suite"; exit 4; fi

  log "suite: 42 items on $AUX (= $ID, n-cpu-moe $BEST_N, mmproj $BEST_MM, ctx $CTX, Chief SOUL v2) -> $OUT"
  LC_LOCKED=1 python3 evals/chief/run_suite.py --model "$AUX" --out "$OUT" > "$SUITELOG" 2>&1
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

# ---- dry run: print what would happen, launch nothing ------------------------------------------------------------------
dry_run(){
  local tmp rc state gp grc n mm
  echo "== DRY RUN: nothing is launched, the GPU is not touched; only read-only probes and llama-swap -validate =="
  echo "backend: SYCL ($G)"
  echo
  echo "== 1. placement sweep (runs under the lock): every point, validated ==" 
  for mm in gpu cpu; do
    for n in $SWEEP_NCMOE; do
      tmp=$(mktemp "${TMPDIR:-/tmp}/config.sweep-$mm-$n.XXXXXX.yaml")
      make_cfg "$tmp" "$n" "$mm" sweep || { echo "derived config generation FAILED"; exit 4; }
      echo "[mmproj=$mm n-cpu-moe=$n] validate: $(llama-swap -config "$tmp" -validate 2>&1 | tail -1)"
      rm -f "$tmp"
    done
  done
  echo "stop rule: accept if probe OK, no breach and min free >= ${MIN_FREE} MiB; first rejected point ends the sweep"
  echo "llama-server argv for point (n-cpu-moe 41, mmproj gpu), port is the llama-swap \${PORT} pool (181xx):"
  echo "  $(server_argv 18100 41 gpu)"
  echo "  (wrapped as: bash $LAB/bench/watchdog.sh minicpm-<port> -- ionice -c 3 $HOME/.local/bin/jobcap <argv>; CAP=48G CPUS=6-11,18-23 CPUW=20 WATCH_IO_GRACE_S=60)"
  echo "  env (sycl-env.sh sourced): oneAPI + dnnl libs, same as bench/configs/sycl-env.sh"
  echo
  echo "== 2. derived sweep config (first point, mmproj gpu, n-cpu-moe 41), written to $LOGD/config.sweep-gpu-41.yaml at run time =="
  tmp=$(mktemp "${TMPDIR:-/tmp}/config.sweep-gpu-41.XXXXXX.yaml")
  make_cfg "$tmp" 41 gpu sweep
  cat "$tmp"
  rm -f "$tmp"
  echo
  echo "== 3. derived suite config (example: n-cpu-moe 41, mmproj gpu; the real run uses the sweep's chosen point) =="
  tmp=$(mktemp "${TMPDIR:-/tmp}/config.suite-$ID.XXXXXX.yaml")
  make_cfg "$tmp" 41 gpu suite
  cat "$tmp"
  echo "-- llama-swap -config <derived> -validate:"
  llama-swap -config "$tmp" -validate 2>&1 | tail -1
  rm -f "$tmp"
  echo
  echo "== 4. waiter (read-only probe of the current box state) =="
  echo "driver wait : pgrep -f \"$DRIVER_PAT\" must be empty (this script's own ancestry is ignored)"
  echo "quiet wait  : ${QUIET_NEED}s continuous: no \"$BOT_PAT\" processes, PSI full avg60 < $PSI_MAX for memory and io"
  echo "cap         : gives up with exit 8 after WAIT_MAX_S=${WAIT_MAX_S}s"
  state=$(quiet_now); rc=$?
  echo "now         : $state -> $([ $rc -eq 0 ] && echo 'quiet sample' || echo 'NOT quiet, would keep waiting')"
  echo "blocking drivers now: $(matching_pids "$DRIVER_PAT" | tr '\n' ' ')"
  echo
  echo "== 5. lock + gate sequence =="
  echo "flock -x -w 7200 -E 75 $LAB/bench/.gpu.lock env LC_LOCKED=1 bash $SELF --locked"
  echo "  in lock : source bench/gate.sh; gate_check (up to 60 x 60 s, NEVER --force); io_quiet_wait; no llama-server running; :18080 silent"
  gp=$( (source "$LAB/bench/gate.sh"; gate_check) 2>&1 ); grc=$?
  echo "  gate probe now (read-only gate_check, no --force): rc=$grc ${gp:+$(echo "$gp" | tr '\n' ' ')}"
  echo
  echo "== 6. exact commands inside the lock =="
  echo "python3 $BO/vram-sampler.py <csv> <breach>                    # per point and for the suite; breach < 900 MiB stops the run"
  echo "setsid llama-swap -config <derived> -listen 127.0.0.1:18080 > <log> 2>&1 &"
  echo "curl .../v1/chat/completions model=$AUX | $AUX2 | $ID  (each must be HTTP 200, one upstream start)   # alias proof"
  echo "cd $LAB && LC_LOCKED=1 python3 evals/chief/run_suite.py --model $AUX --out $OUT > $SUITELOG 2>&1"
  echo "stop: SIGTERM our llama-swap (pid file $PIDF), then pkill llama-server --port 181xx"
  echo
  echo "== 7. taint rule (exit 6 when n > 0; line TAINTED=<n> restarts is written to $RUNLOG) =="
  echo "n = max( upstream starts - 1 [Health check passed in $SWAPLOG], 'upstream process exited unexpectedly',"
  echo "         'upstream command exited prematurely', '[watchdog] ABORT-LAG' lines, results-matrix.tsv ABORT-LAG rows since start )"
  echo "exit codes: 0 clean | 3 gate refused | 4 setup or no placement fits | 5 VRAM breach | 6 TAINTED | 7 no result | 8 waiter timeout | 75 lock timeout"
  exit 0
}

# ---- llama-swap cmd entry: gate-run.sh has already run; this execs the watchdog/jobcap/llama-server chain ----------
serve(){  # --serve <port> <ctx> <n-cpu-moe> <gpu|cpu>
  local port=$1 ctx=$2 ncmoe=$3 mm=$4 extra=()
  [ "$mm" = cpu ] && extra=(--no-mmproj-offload)
  set +u; . "$LAB/bench/configs/sycl-env.sh"; set -u
  export CAP=48G CPUS=6-11,18-23 CPUW=20 WATCH_IO_GRACE_S="${WATCH_IO_GRACE_S:-60}"
  export GGML_SYCL_NO_PINNED="${GGML_SYCL_NO_PINNED-1}"   # 20:15 probe: pinned 19 GB expert buffer = mem stall peak 10-17%, load 18-21 s; unpinned 0.3-5%, 8-9 s
  exec bash "$LAB/bench/watchdog.sh" "minicpm-$port" -- ionice -c 3 /home/nexuslink/.local/bin/jobcap \
    "$G" -m "$M" --mmproj "$MM" ${extra[@]+"${extra[@]}"} \
    --host 127.0.0.1 --port "$port" --device SYCL0 -ngl 99 --n-cpu-moe "$ncmoe" \
    -c "$ctx" -np 1 -t 16 -fa on -ctk "$KV" -ctv "$KV" -b 1024 -ub 1024 -lm dio -fit off \
    --jinja --temp 0 --repeat-penalty 1.05
}

# ---- entry ------------------------------------------------------------------------------------------------------------
case "${1:-}" in
  --dry-run) dry_run ;;
  --locked)  locked_phase ;;
  --serve)   shift; serve "$@" ;;
  "")        ;;
  *)         echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

cd "$LAB" || exit 2
log "minicpm bake-off start pid $$ (id $ID, suite model $AUX, aux alias $AUX2, out $OUT)"
wait_quiet; rc=$?
[ "$rc" -ne 0 ] && exit "$rc"
exec flock -x -w 7200 -E 75 bench/.gpu.lock env LC_LOCKED=1 bash "$SELF" --locked
