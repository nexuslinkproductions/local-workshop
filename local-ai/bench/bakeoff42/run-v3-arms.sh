#!/usr/bin/env bash
# run-v3-arms.sh: Chief v3 A/B arms on suite v2 (research/60-chief-v3-build.md). Sequential, one GPU job at a time.
#   bash bench/bakeoff42/run-v3-arms.sh --dry-plan            # print the arm matrix, run nothing, touch nothing
#   bash bench/bakeoff42/run-v3-arms.sh --prepare             # build arm profiles + derived configs and validate them, no GPU
#   bash bench/bakeoff42/run-v3-arms.sh                       # all arms: A0 T1 T2 T3 T4 T5
#   ARMS="A0 T2" bash bench/bakeoff42/run-v3-arms.sh          # a subset (also: --arms "A0 T2")
# Conventions copied from run-challengers.sh: every arm is a locked phase (flock -x bench/.gpu.lock env LC_LOCKED=1),
# gate_check + io_quiet_wait first, our own llama-swap on :18080 with a DERIVED one-model config (never serve/config.yaml,
# never the stack of another driver), VRAM sampled every 2 s with the 750 MiB floor (breach = model stopped, whole driver stops),
# results/v3-arms/<arm>.json + one summary TSV. local-ai.service is stopped before the first arm and started again on exit.
# This script never edits ~/.hermes/profiles/chief or serve/config.yaml. Arm profiles chief-v3-t1..t5 are rebuilt from
# ~/.hermes/profiles/chief-v3/config.yaml (tag lines) on every run; their state.db/sessions are kept.
set -uo pipefail
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
BO=$LAB/bench/bakeoff42
LOGD=$BO/logs
OUT=$LAB/results/v3-arms
V3=$HOME/.hermes/profiles/chief-v3
SUITE=${CHIEF_SUITE:-suite.yaml}           # suite v2; suite.v1.yaml is frozen
MIN_FREE=750                               # Marcel 21:00 floor, same as run-challengers.sh

# ---- arm matrix (single source of truth; --dry-plan prints it) --------------------------------------------------------
ALL_ARMS="A0 T1 T2 T3 T4 T5"          # default run list
KNOWN_ARMS="A0 A0b T1 T2 T3 T4 T5"    # A0b = optional repeat of A0 for run-to-run noise (ARMS="A0b"), never in the default list
declare -A PROFILE MODEL SAMPLING ADDS
PROFILE[A0]=chief-a0       MODEL[A0]=ornith-chief     SAMPLING[A0]=old ADDS[A0]="clone of live Chief (chief-a0, no state) so eval sessions and memory writes never touch the live profile"
PROFILE[A0b]=chief-a0      MODEL[A0b]=ornith-chief    SAMPLING[A0b]=old ADDS[A0b]="optional repeat of A0 (58b: 42 items give +-2 of run noise); not in the default list"
PROFILE[T1]=chief-v3-t1    MODEL[T1]=ornith-chief-v3  SAMPLING[T1]=old ADDS[T1]="chief-v3 text and config only: SOUL v3, AGENTS.md 169 tok, route cards, calc/think helpers, coding_context off, guidance off, platform hint, cwd (58a, 58b T1+T2, 58f #1 #5)"
PROFILE[T2]=chief-v3-t2    MODEL[T2]=ornith-chief-v3  SAMPLING[T2]=new ADDS[T2]="T1 + vendor sampler via setParamsByID (58c): temp 1.0, top_p 0.95, top_k 20, min_p 0, presence 1.5, repeat 1.0"
PROFILE[T3]=chief-v3-t3    MODEL[T3]=ornith-chief-v3  SAMPLING[T3]=new ADDS[T3]="T2 + chief-context plugin: compact tool schemas (10 -> 9 tools) and tool-result clip (58b T3)"
PROFILE[T4]=chief-v3-t4    MODEL[T4]=ornith-chief-v3  SAMPLING[T4]=new ADDS[T4]="T3 + compaction: threshold_tokens 98304, proactive_prune_tokens 40000 (58b T4, 58f #3)"
PROFILE[T5]=chief-v3-t5    MODEL[T5]=ornith-chief-v3  SAMPLING[T5]=new ADDS[T5]="T4 + 58f scaffolding: pre_verify gate + max_verify_nudges 1, bin/invcheck (named in the nudge), pre_tool_call approve gate on live invoice-system writes, fallback_providers -> ornith-chief-v3-think (58f #2 #4 #6 #7)"

dry_plan(){
  echo "Chief v3 arms: sequential, each under flock -x bench/.gpu.lock, suite=$SUITE (v2), 42 items, out=results/v3-arms/<arm>.json"
  printf '%-4s %-13s %-16s %-9s %s\n' ARM PROFILE MODEL-ID SAMPLING WHAT-IT-ADDS
  local a; for a in ${1:-$ALL_ARMS}; do
    printf '%-4s %-13s %-16s %-9s %s\n' "$a" "${PROFILE[$a]}" "${MODEL[$a]}" "${SAMPLING[$a]}" "${ADDS[$a]}"
  done
  echo
  echo "sampling old = CLI baked in bakeoff-launch.sh (--temp 0 --repeat-penalty 1.05); new = vendor set (temp 1.0 top_p 0.95 top_k 20 min_p 0 presence 1.5 repeat 1.0)"
  echo "per arm: gate_check, io_quiet_wait, systemctl --user stop local-ai.service, derived config bench/bakeoff42/config.v3arm-<arm>.yaml + llama-swap -validate,"
  echo "         vram-sampler (floor ${MIN_FREE} MiB), own llama-swap :18080, sampler check via verbose, then"
  echo "         CHIEF_PROFILE=<profile> CHIEF_SUITE=$SUITE LC_LOCKED=1 python3 evals/chief/run_suite.py --model <model-id> --out results/v3-arms/<arm>.json"
  echo "after:   results/v3-arms/summary.tsv (pass per category, total, total without invoice, seconds, min free VRAM); systemctl --user start local-ai.service"
  echo "not run: nothing was started, locked, stopped or written by --dry-plan."
}

ARMS_SEL=${ARMS:-$ALL_ARMS}
PHASE=""; PREPARE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-plan) dry_plan "$ARMS_SEL"; exit 0 ;;
    --arms) ARMS_SEL="$2"; shift ;;
    --phase) PHASE="$2"; shift ;;
    --prepare) PREPARE=1 ;;   # build arm profiles + derived configs + llama-swap -validate, no GPU, nothing started
    *) echo "unknown arg $1 (use --dry-plan, --arms \"A0 T2\")" >&2; exit 2 ;;
  esac
  shift
done
for a in $ARMS_SEL $PHASE; do [ -n "${PROFILE[$a]:-}" ] || { echo "unknown arm $a (have: $KNOWN_ARMS)" >&2; exit 2; }; done

mkdir -p "$LOGD" "$OUT"
cd "$LAB" || exit 2
source bench/gate.sh
set +u; . bench/configs/sycl-env.sh; set -u
log(){ echo "[$(date +%T)] $*" | tee -a "$LOGD/v3-arms.log"; }

stop_stack(){  # only the llama-swap this driver started (pid file), then llama-server children on the 181xx pool
  if [ -f "$BO/llama-swap-v3.pid" ]; then
    local P; P=$(cat "$BO/llama-swap-v3.pid")
    kill -TERM "$P" 2>/dev/null; sleep 3; kill -KILL "$P" 2>/dev/null; rm -f "$BO/llama-swap-v3.pid"
  fi
  pkill -TERM -f '[l]lama-server.*--port 18' 2>/dev/null; sleep 2
  pkill -KILL -f '[l]lama-server.*--port 18' 2>/dev/null
}
start_sampler(){ rm -f "$2"; VRAM_FLOOR_MIB=$MIN_FREE setsid nohup python3 "$BO/vram-sampler.py" "$1" "$2" >/dev/null 2>&1 & SAMP=$!; }
stop_sampler(){ kill "$SAMP" 2>/dev/null; wait "$SAMP" 2>/dev/null; SAMP=""; }
min_free(){ python3 -c 'import sys
v=[int(l.split(",")[1]) for l in open(sys.argv[1]) if l[0].isdigit()]
print(min(v) if v else "NA")' "$1"; }
gate_wait(){ local i; for i in $(seq 1 60); do gate_check && return 0; log "gate refused, waiting 60 s (attempt $i)"; sleep 60; done; return 1; }

# ---- arm profile: chief-v3/config.yaml with the tag lines resolved for this arm ----------------------------------------
build_profile(){  # arm
  local arm="$1" prof="${PROFILE[$1]}"
  case "$arm" in A0|A0b) return 0 ;; esac   # live profile, untouched
  python3 - "$arm" "$prof" "$V3" <<'PY' || return 1
import re, shutil, sys, yaml
from pathlib import Path
arm, prof, v3 = sys.argv[1], sys.argv[2], Path(sys.argv[3])
n = int(arm[1:])
dst = v3.parent / prof
dst.mkdir(parents=True, exist_ok=True)
out = []
for line in (v3 / "config.yaml").read_text().splitlines():
    m = re.match(r"#ALT \[<T(\d)\] ?(.*)$", line)
    if m:                                    # replacement line for arms before Tk
        if n < int(m.group(1)): out.append(m.group(2))
        continue
    m = re.search(r"\[>=T(\d)\]", line)
    if m and n < int(m.group(1)): continue   # line exists only from Tk on
    out.append(line)
cfg = "\n".join(out) + "\n"
c = yaml.safe_load(cfg)
want = {"plugins": n >= 3, "compression.proactive_prune_tokens": n >= 4, "hooks": n >= 5}
assert ("plugins" in c) == want["plugins"], "plugins tag"
assert ("proactive_prune_tokens" in c["compression"]) == want["compression.proactive_prune_tokens"], "prune tag"
assert ("hooks" in c) == want["hooks"] and ("max_verify_nudges" in c["agent"]) == want["hooks"], "hooks tag"
assert c["compression"]["threshold_tokens"] == (98304 if n >= 4 else 32768)
assert c["fallback_providers"] == ([{"provider": "local-ai", "model": "ornith-chief-v3-think"}] if n >= 5 else [])
(dst / "config.yaml").write_text(cfg)
for f in ("SOUL.md", ".env", "auth.json", "profile.yaml", ".no-bundled-skills"):
    if (v3 / f).exists(): shutil.copy2(v3 / f, dst / f)
if not (dst / "skills").exists(): shutil.copytree(v3 / "skills", dst / "skills")
for d in ("memories", "sessions", "logs", "home", "plans", "cron", "skins"): (dst / d).mkdir(exist_ok=True)
pl = dst / "plugins"
if pl.exists(): shutil.rmtree(pl)
if n >= 3: shutil.copytree(v3 / "plugins", pl, ignore=shutil.ignore_patterns("__pycache__"))
print(f"profile {prof} built for {arm}: plugin={n>=3} prune={n>=4} hooks+fallback={n>=5}")
PY
}

# ---- derived llama-swap config: ONE model, id = the arm's model id, aliases = its think id ----------------------------------
make_cfg(){  # arm
  local arm="$1" cfg="$BO/config.v3arm-$1.yaml"
  python3 - "$LAB" "${MODEL[$arm]}" "${SAMPLING[$arm]}" "$arm" "$cfg" <<'PY' || return 1
import copy, sys, yaml
lab, mid, sampling, arm, out = sys.argv[1:6]
src = yaml.safe_load(open(f"{lab}/serve/config.yaml"))["models"][mid]   # same launch line as the shelf entry
m = copy.deepcopy(src); m["cmd"] = " ".join(m["cmd"].split())
m["name"] = f"v3 arms {arm}: {mid} ({sampling} sampling)"
if sampling == "old":     # keep only thinking switches: sampling then comes from the CLI line (--temp 0 --repeat-penalty 1.05)
    keep = ("chat_template_kwargs", "thinking_budget_tokens")
    m["filters"]["setParamsByID"] = {k: {a: b for a, b in v.items() if a in keep} for k, v in m["filters"]["setParamsByID"].items()}
cfg = {"healthCheckTimeout": 900, "logLevel": "info", "logToStdout": "both", "globalTTL": 600, "unloadTimeout": 10,
       "startPort": 18100, "models": {mid: m}}
open(out, "w").write(f"# GENERATED by bench/bakeoff42/run-v3-arms.sh for arm {arm}; derived from serve/config.yaml entry {mid}. Not for serving.\n"
                     + yaml.safe_dump(cfg, sort_keys=False, width=100000))
PY
  llama-swap -config "$cfg" -validate 2>&1 | tail -1 | tee -a "$LOGD/v3-arms.log" | grep -q "config is valid"
}

sampler_check(){  # arm: ask the loaded model what sampler it really got (58c T1); abort the arm on a wrong label
  local arm="$1" mid="${MODEL[$1]}"
  curl -s -m 600 http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' \
    -d "{\"model\":\"$mid\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8,\"verbose\":true}" > "$OUT/$arm.sampler-raw.json"
  python3 - "$arm" "${SAMPLING[$arm]}" "$OUT" <<'PY'
import json, sys
arm, sampling, out = sys.argv[1:4]
def find(o, k):
    if isinstance(o, dict):
        if k in o and not isinstance(o[k], (dict, list)): return o[k]
        for v in o.values():
            r = find(v, k)
            if r is not None: return r
    elif isinstance(o, list):
        for v in o:
            r = find(v, k)
            if r is not None: return r
try: d = json.load(open(f"{out}/{arm}.sampler-raw.json"))
except Exception as e: print(f"SAMPLER-CHECK unreadable ({e}), continuing"); sys.exit(0)
g = (d.get("__verbose") or d)
got = {k: find(g.get("generation_settings", g), k) for k in ("temperature", "top_p", "top_k", "min_p", "presence_penalty", "repeat_penalty")}
json.dump(got, open(f"{out}/{arm}.sampler.json", "w"))
print("applied sampler:", got)
if got["temperature"] is None: print("SAMPLER-CHECK: temperature not in the verbose reply, continuing"); sys.exit(0)
ok = (abs(got["temperature"]) < 1e-6) if sampling == "old" else (abs(got["temperature"] - 1.0) < 1e-6 and got["presence_penalty"] in (1.5, None))
sys.exit(0 if ok else 9)
PY
}

summarise(){  # rebuild results/v3-arms/summary.tsv from whatever arm JSONs exist
  python3 - "$OUT" "$KNOWN_ARMS" <<'PY'
import json, sys
from pathlib import Path
out, arms = Path(sys.argv[1]), sys.argv[2].split()
cats = ["navigation", "read", "write", "invoice", "web", "safety"]
rows = ["\t".join(["arm", "profile", "model", "pass", "total", "pass_excl_invoice", "total_excl_invoice"] + cats + ["seconds", "min_free_mib", "run_at"])]
for a in arms:
    f = out / f"{a}.json"
    if not f.exists(): continue
    d = json.loads(f.read_text()); it = d["items"]
    p = lambda xs: sum(x["verdict"] == "PASS" for x in xs)
    ex = [x for x in it if x["category"] != "invoice"]
    meta = json.loads((out / f"{a}.meta.json").read_text()) if (out / f"{a}.meta.json").exists() else {}
    bycat = [f"{p([x for x in it if x['category'] == c])}/{sum(x['category'] == c for x in it)}" for c in cats]
    rows.append("\t".join([a, d["profile"], d["model"], str(p(it)), str(len(it)), str(p(ex)), str(len(ex))] + bycat +
                          [str(round(sum(x["seconds"] for x in it))), str(meta.get("min_free_mib", "NA")), d["run_at"]]))
(out / "summary.tsv").write_text("\n".join(rows) + "\n")
print("\n".join(rows))
PY
}

# ---- one locked arm phase ---------------------------------------------------------------------------------------------------
phase_arm(){
  local arm="$1" mid="${MODEL[$1]}" prof="${PROFILE[$1]}" t0; t0=$(date +%s)
  gate_wait || { log "$arm: GATE REFUSED 60 min, skip"; return 3; }
  io_quiet_wait || { log "$arm: IO busy, skip"; return 3; }
  systemctl --user stop local-ai.service 2>/dev/null; sleep 3
  # a previous lock holder's server may still be exiting after its kill; wait for it instead of skipping
  for _ in $(seq 60); do pgrep -f '[l]lama-server' >/dev/null || break; sleep 2; done
  pgrep -f '[l]lama-server' >/dev/null && { log "$arm: llama-server still running after 120 s, skip"; return 3; }
  sleep 5   # let the driver return the freed VRAM before the sampler starts
  if curl -sf -m 2 http://127.0.0.1:18080/v1/models >/dev/null; then log "$arm: :18080 already answers (not ours), skip"; return 3; fi
  build_profile "$arm" || { log "$arm: profile build failed"; return 4; }
  make_cfg "$arm" || { log "$arm: derived config invalid"; return 4; }
  rm -f "$LOGD/BREACH-v3-$arm"
  start_sampler "$LOGD/vram-v3-$arm.csv" "$LOGD/BREACH-v3-$arm"
  log "$arm: llama-swap ($mid, ${SAMPLING[$arm]} sampling), profile $prof, suite $SUITE"
  setsid llama-swap -config "$BO/config.v3arm-$arm.yaml" -listen 127.0.0.1:18080 > "$LOGD/llama-swap-v3-$arm.log" 2>&1 &
  echo $! > "$BO/llama-swap-v3.pid"
  local i; for i in $(seq 1 60); do curl -sf -m 2 http://127.0.0.1:18080/v1/models >/dev/null && break; sleep 1; done
  if ! curl -sf -m 3 http://127.0.0.1:18080/v1/models >/dev/null; then log "$arm: llama-swap not answering"; stop_sampler; stop_stack; return 4; fi
  if [ ! -e "$LOGD/BREACH-v3-$arm" ]; then
    sampler_check "$arm" >> "$LOGD/v3-arms.log" 2>&1; local src=$?
    if [ "$src" = 0 ]; then
      log "$arm: suite 42 items"
      CHIEF_PROFILE="$prof" CHIEF_SUITE="$SUITE" LC_LOCKED=1 python3 evals/chief/run_suite.py --model "$mid" --out "$OUT/$arm.json" > "$LOGD/v3-suite-$arm.out" 2>&1
      log "$arm: suite rc=$?"
    else
      log "$arm: SAMPLER MISMATCH (see $OUT/$arm.sampler.json), arm skipped"
    fi
  fi
  stop_sampler; stop_stack
  local mf; mf=$(min_free "$LOGD/vram-v3-$arm.csv")
  printf '{"arm":"%s","profile":"%s","model":"%s","sampling":"%s","suite":"%s","min_free_mib":"%s","seconds":%s}\n' \
    "$arm" "$prof" "$mid" "${SAMPLING[$arm]}" "$SUITE" "$mf" "$(( $(date +%s) - t0 ))" > "$OUT/$arm.meta.json"
  log "$arm: min_free=$mf MiB"
  if [ -e "$LOGD/BREACH-v3-$arm" ]; then log "$arm: BREACH $(cat "$LOGD/BREACH-v3-$arm") -- stopped, reported"; return 5; fi
  return 0
}

if [ "$PREPARE" = 1 ]; then
  for arm in $ARMS_SEL; do build_profile "$arm" && make_cfg "$arm" && echo "$arm: profile + derived config ok" || { echo "$arm: FAILED"; exit 1; }; done
  exit 0
fi
if [ -n "$PHASE" ]; then phase_arm "$PHASE"; exit $?; fi

# ---- driver (not locked itself; each arm takes the lock) ---------------------------------------------------------------------
log "v3 arms driver pid $$: $ARMS_SEL (suite $SUITE)"
trap 'systemctl --user start local-ai.service 2>/dev/null; log "local-ai.service started again"' EXIT
systemctl --user stop local-ai.service 2>/dev/null
for arm in $ARMS_SEL; do
  rc=1
  for try in 1 2 3 4 5 6; do
    flock -x -w 3600 bench/.gpu.lock env LC_LOCKED=1 bash "$0" --phase "$arm"; rc=$?
    [ "$rc" = 1 ] || break
    log "lock wait timed out ($arm), retry $try"
  done
  log "phase $arm rc=$rc"
  summarise >/dev/null
  [ "$rc" = 5 ] && { log "VRAM breach: remaining arms NOT run"; break; }
done
for arm in $ARMS_SEL; do
  [ "$arm" != A0 ] && [ "$arm" != A0b ] && [ -f "$OUT/A0.json" ] && [ -f "$OUT/$arm.json" ] && \
    python3 evals/chief/run_suite.py --compare "$OUT/A0.json" "$OUT/$arm.json" > "$OUT/compare-A0-$arm.txt" 2>&1
done
summarise
log "V3 ARMS DONE"
