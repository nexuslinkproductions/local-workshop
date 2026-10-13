#!/usr/bin/env bash
# speed-push.sh — decode speed sweep for the two 256K models (Ornith-1.5-9B, MiniCPM-V-4.7-35B-A3B) on the B580.
#   bash bench/bakeoff42/speed-push.sh --dry-run            # print every point's argv; touches nothing
#   bash bench/bakeoff42/speed-push.sh --selftest           # gate-rule asserts on a temp TSV; touches nothing
#   bash bench/bakeoff42/speed-push.sh [--only RE] [--skip RE]   # the real run (orchestrator starts it, not the author)
# ONE point at a time: each point = its own `flock -x bench/.gpu.lock` -> gate_check -> server -> VRAM sampler
# (breach < 900 MiB kills the server) -> probe -> stop -> one TSV row in logs/speed-push.tsv. Docs: SPEED-PUSH.md.
# Exit: 0 done | 3 gate refused | 5 kernel-log hit (stop, human acks) | 75 lock timeout.
set -uo pipefail
LAB=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
BO=$LAB/bench/bakeoff42
SELF=$BO/speed-push.sh
LOGD=$BO/logs
TSV=${SPEED_PUSH_TSV:-$LOGD/speed-push.tsv}
G=${SPEED_BIN:-$LAB/engines/llama.cpp-sycl-tip/build/bin/llama-server}   # SPEED_BIN: alternate engine build (e.g. sycl-mtp patch)
OD=$LAB/models/llm/ornith-ai/Ornith-1.5-9B-GGUF
MD=$LAB/models/llm/openbmb/MiniCPM-V-4.7-35B-A3B-gguf
PORT=18190              # must start with 18: vram-sampler.py's breach kill is `pkill -f llama-server.*--port 18`
CCD1=6-11,18-23         # production serving pins to this CCD (serve/bakeoff-launch.sh), so every point does
CTX=262144; KV=q4_0
FLOOR=750               # Marcel breach floor (MiB), 21:00 (was 900)
HDR=$'time\tmodel\tlabel\tflags\tload_s\tdecode_tps\tdecode_tps_after_30k\tprefill_tps\tmin_free_mib\tgreedy_output_sha\tstatus\tnote'
# shellcheck source=../gate.sh
source "$LAB/bench/gate.sh"

# model|label|gate|settings. gate "-" = always; "LBL:MIN[,LBL:MIN]" = run only if each referenced row is status ok with
# min_free >= MIN (the predicted-free rule: MIN = 1500 + the point's added VRAM; ornith uses 900 + added VRAM).
# settings (k=v): t tb ncmoe poll cache(moe-cache-mib) mtp(spec-draft-n-max) pin(0 = GGML_SYCL_NO_PINNED unset)
POINTS=(
  "ornith|or-base|-|"
  # draft ctx = target n_ctx (256K), 1 attn layer, 4 kv heads x 256 x 2 = 288 MiB at q4_0 (1 GiB at the f16 default) -> base needs >= 1200
  "ornith|or-mtp1|or-base:750|mtp=1"
  "ornith|or-mtp2|or-mtp1:750|mtp=2"
  "ornith|or-mtp3|or-mtp2:750|mtp=3"
  # MTP needs ~288 MiB more than base (954-987 free): retry with a smaller batch; 900 MiB sampler breach stays the safety net
  "ornith|or-ub256|-|ub=256"
  "ornith|or-mtp2-ub256|or-ub256:750|ub=256 mtp=2"
  "ornith|or-mtp3-ub256|or-ub256:750|ub=256 mtp=3"
  "ornith|or-t8|or-ub256:750|ub=256 t=8 tb=16"
  "ornith|or-t12|or-ub256:750|ub=256 t=12 tb=16"
  "ornith|or-poll0|or-ub256:750|ub=256 poll=0"
  # 20:55 single runs: ub256 50.9, t12 55.9, poll0 57.5 t/s -> stack them; MTP gates at the floor (sampler breach is the safety net, 750 MiB)
  "ornith|or-mtp2-dcpu|or-ub256:750|ub=256 mtp=2 dngl=0"
  "ornith|or-mtp1-dcpu|or-ub256:750|ub=256 mtp=1 dngl=0"
  "ornith|or-nkvo|-|nkvo=1"
  "ornith|or-nkvo-mtp2|or-nkvo:750|nkvo=1 mtp=2"
  "ornith|or-nkvo-mtp3|or-nkvo-mtp2:750|nkvo=1 mtp=3"
  "ornith|or-combo|or-ub256:750|ub=256 poll=0 t=12 tb=16"
  "ornith|or-combo-mtp2|or-combo:750|ub=256 poll=0 t=12 tb=16 mtp=2"
  "ornith|or-combo-mtp3|or-combo:750|ub=256 poll=0 t=12 tb=16 mtp=3"
  "minicpm|mc-base28|-|"
  "minicpm|mc-nc30|mc-base28:1500|ncmoe=30"
  "minicpm|mc-nc26|mc-base28:2500|ncmoe=26"
  "minicpm|mc-cache512|mc-nc30:2012|ncmoe=30 cache=512"
  "minicpm|mc-cache1024|mc-nc30:2524,mc-cache512:1500|ncmoe=30 cache=1024"
  "minicpm|mc-cache1536|mc-nc30:3036,mc-cache1024:1500|ncmoe=30 cache=1536"
  "minicpm|mc-t6|mc-base28:1500|t=6 tb=16"
  "minicpm|mc-t8|mc-base28:1500|t=8 tb=16"
  "minicpm|mc-t12|mc-base28:1500|t=12 tb=16"
  "minicpm|mc-pinned|mc-base28:1500|pin=0"
  "minicpm|mc-mtp1|mc-base28:2500|mtp=1"
)

# gate_ok "A:N,B:M": last TSV row per label must be ok with min_free >= N. Sets GATE_WHY on failure.
gate_ok() {
  local ref l n f
  [ "$1" = - ] && return 0
  for ref in ${1//,/ }; do
    l=${ref%%:*}; n=${ref##*:}
    f=$(awk -F'\t' -v l="$l" '$3==l{r=($11=="ok")?$9:""} END{print r}' "$TSV" 2>/dev/null)
    if ! { [[ $f =~ ^[0-9]+$ ]] && [ "$f" -ge "$n" ]; }; then GATE_WHY="$l min_free=${f:-none/not-ok} < $n"; return 1; fi
  done
}

# build <model> [k=v...] -> ARGV (llama-server), ENVW (env words), CMD (full launch), SETTINGS (TSV flags column), CAPG
build() {
  local model=$1; shift
  local t=16 tb="" ncmoe=28 poll="" cache="" mtp="" pin=1 ub="" dngl="" nkvo="" w b m mm cap
  for w in "$@"; do
    case $w in
      t=*) t=${w#t=};; tb=*) tb=${w#tb=};; ncmoe=*) ncmoe=${w#ncmoe=};; poll=*) poll=${w#poll=};;
      cache=*) cache=${w#cache=};; mtp=*) mtp=${w#mtp=};; pin=*) pin=${w#pin=};; ub=*) ub=${w#ub=};; dngl=*) dngl=${w#dngl=};; nkvo=*) nkvo=${w#nkvo=};;
      *) echo "bad setting '$w'" >&2; exit 2;;
    esac
  done
  if [ "$model" = ornith ]; then
    m=$OD/Ornith-1.5-9B-Q4_K_M.gguf; mm=$OD/mmproj-Ornith-1.5-9B-BF16.gguf; b=512; cap=14G; ncmoe=-
  else
    m=$MD/MiniCPM-V-4.7-35B-A3B-AD-Q4_K-IQ4_XS.gguf; mm=$MD/mmproj-model-f16.gguf; b=1024; cap=48G
  fi
  [ -n "$ub" ] && b=$ub   # smaller batch = smaller compute buffer = room for the MTP draft cache
  MODEL_FILE=$m
  ARGV=("$G" -m "$m" --mmproj "$mm" --no-mmproj-offload --host 127.0.0.1 --port "$PORT" --device SYCL0 -ngl 99)
  [ "$ncmoe" != - ] && ARGV+=(--n-cpu-moe "$ncmoe")
  ARGV+=(-c "$CTX" -np 1 -t "$t")
  [ -n "$tb" ] && ARGV+=(-tb "$tb")
  ARGV+=(-fa on -ctk "$KV" -ctv "$KV" -b "$b" -ub "$b" -lm dio -fit off --jinja --temp 0 --repeat-penalty 1.05)
  [ -n "$poll" ]  && ARGV+=(--poll "$poll")
  [ -n "$cache" ] && ARGV+=(--moe-cache-mib "$cache")
  # --draft-max is a removed alias in this build; the draft ctx KV defaults to f16 at n_ctx 256K, so force q4_0
  [ -n "$mtp" ]   && ARGV+=(--spec-type draft-mtp --spec-draft-n-max "$mtp" --spec-draft-type-k "$KV" --spec-draft-type-v "$KV")
  [ -n "$nkvo" ]  && ARGV+=(--no-kv-offload)   # KV cache deliberately in system RAM (controlled offload, Marcel 21:35)
  [ -n "$dngl" ]  && ARGV+=(--spec-draft-ngl "$dngl")   # MTP draft layers on CPU: draft ctx +~1.6 GB VRAM at 256K overcommitted (21:15)
  ENVW=(CAP="$cap" CPUS="$CCD1" CPUW=20 WATCH_IO_GRACE_S=60)
  # Ornith (all weights on GPU) runs pinned like its suite: NO_PINNED cost it ~250 MiB VRAM (or-base breach 706 MiB, 20:42)
  if [ "$pin" = 1 ] && [ "$model" != ornith ]; then ENVW+=(GGML_SYCL_NO_PINNED=1); else ENVW=(-u GGML_SYCL_NO_PINNED "${ENVW[@]}"); fi
  # same chain as smoke.py / serve/bakeoff-launch.sh: nice+ionice -> watchdog (PSI/RAM kill) -> ionice -> jobcap -> llama-server
  CMD=(env "${ENVW[@]}" setsid nice -n 10 ionice -c 3 bash "$LAB/bench/watchdog.sh" "speedpush-$LABEL" -- ionice -c 3 "$HOME/.local/bin/jobcap" "${ARGV[@]}")
  SETTINGS="t=$t tb=${tb:-def} ncmoe=$ncmoe b=$b poll=${poll:-def} cache=${cache:-0} mtp=${mtp:-0} pin=$pin cpus=$CCD1"
}

dry_run() {
  local i model label gate vars tok n=0 miss
  echo "== DRY RUN: no GPU, no lock, no server. ${#POINTS[@]} points, results -> $TSV =="
  [ -x "$G" ] && echo "binary ok: $G" || echo "BINARY MISSING: $G"
  for i in "${!POINTS[@]}"; do
    IFS='|' read -r model label gate vars <<<"${POINTS[$i]}"
    LABEL=$label
    # shellcheck disable=SC2086
    build "$model" $vars
    n=$((n+1)); miss=""
    for tok in "${ARGV[@]}"; do   # static flag lint against this tree's common/arg.cpp (the binary is not run)
      [[ $tok == -* ]] && ! grep -qF -- "\"$tok\"" "$LAB/engines/llama.cpp-sycl-tip/common/arg.cpp" && miss="$miss $tok"
    done
    [ -f "$MODEL_FILE" ] || miss="$miss MODEL-FILE-MISSING"
    printf '\n[%02d] %s (%s)\n  gate : %s\n  flags: %s\n  argv : %s\n  flag lint: %s\n' "$n" "$label" "$model" "$gate" "$SETTINGS" "${CMD[*]}" "${miss:-all flags found in common/arg.cpp}"
  done
  printf '\nper point: flock -x %s -> gate_check -> io_quiet_wait -> mem_guard -> sampler (breach < %s MiB) -> probe -> row\n' "$LOCK_FILE" "$FLOOR"
}

selftest() {
  TSV=$(mktemp "${TMPDIR:-/tmp}/sp-selftest.XXXXXX")
  printf 'x\tm\tA\tf\t1\t1\t1\t1\t3000\ts\tok\tn\nx\tm\tB\tf\t1\t1\t1\t1\t5000\ts\tfail\tn\nx\tm\tC\tf\t1\t1\t1\t1\t1400\ts\tok\tn\n' > "$TSV"
  gate_ok - && gate_ok A:2500 && gate_ok A:2500,C:1000 || { echo "FAIL: should pass"; return 1; }
  gate_ok A:3100 && { echo "FAIL: A<3100 passed"; return 1; }
  gate_ok B:1 && { echo "FAIL: failed row passed"; return 1; }
  gate_ok C:1500 && { echo "FAIL: C<1500 passed"; return 1; }
  gate_ok Z:1 && { echo "FAIL: missing row passed"; return 1; }
  rm -f "$TSV"; echo "selftest ok"
}

row() {  # <status> <note>; uses per-point globals
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$MODEL" "$LABEL" "${SETTINGS:--}" \
    "${LOAD_S:--}" "${DEC:--}" "${DEC30:--}" "${PF:--}" "${MINFREE:--}" "${SHA:--}" "$1" "$2" >> "$TSV"
}

stop_server() {
  [ -n "${SPID:-}" ] && kill -TERM -- "-$SPID" 2>/dev/null
  pkill -TERM -f "[l]lama-server.*--port $PORT" 2>/dev/null
  for _ in $(seq 30); do pgrep -f "[l]lama-server.*--port $PORT" >/dev/null || break; sleep 1; done
  pkill -KILL -f "[l]lama-server.*--port $PORT" 2>/dev/null; SPID=""
}
stop_sampler() { [ -n "${SAMP:-}" ] && { kill "$SAMP" 2>/dev/null; wait "$SAMP" 2>/dev/null; }; SAMP=""; }

# The probe: warm-up, 3x 256-token decode (median), fixed-prompt 128-token greedy sha, then ONE ~30K-token request whose
# timings give prefill t/s and the decode t/s right after it. Prints: decode \t decode30k \t prefill \t sha \t note
probe() {
  python3 - "$PORT" <<'PY'
import hashlib, json, statistics, sys, urllib.request
base = f"http://127.0.0.1:{sys.argv[1]}"
def post(path, body):
    req = urllib.request.Request(base + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1500) as r:
        return json.load(r)
def chat(text, n):
    r = post("/v1/chat/completions", {"messages": [{"role": "user", "content": text}], "max_tokens": n, "temperature": 0,
             "cache_prompt": False, "chat_template_kwargs": {"enable_thinking": False}})
    m = r["choices"][0]["message"]
    return (m.get("content") or "") + (m.get("reasoning_content") or ""), r.get("timings", {})
ESSAY = "Write a detailed essay about the history of the printing press: its inventors, its spread across Europe and its social effects."
note = []
chat("Say OK", 8)                                   # first request pays lazy init
runs = [chat(ESSAY, 256)[1] for _ in range(3)]
dec = statistics.median(t["predicted_per_second"] for t in runs)
if any(t.get("predicted_n") != 256 for t in runs): note.append("decode<256tok")
if runs[-1].get("draft_n"): note.append(f"accept={runs[-1].get('draft_n_accepted')}/{runs[-1]['draft_n']}")
text, _ = chat("Explain step by step how a hash table handles collisions, with a short example.", 128)
sha = hashlib.sha256(text.encode()).hexdigest()[:12]
rec = lambda i: f"Record {i}: sensor {i*7919%10007} reported {i*104729%9973} units at node {i%97}.\n"
n_tok = len(post("/tokenize", {"content": "".join(rec(i) for i in range(400))})["tokens"])   # calibrate with the server's tokenizer
n = int(400 * 29900 / n_tok)
_, t = chat("Read the records below, then follow the final instruction.\n\n" + "".join(rec(i) for i in range(n))
            + "\nFinal instruction: ignore the records. " + ESSAY, 128)
note.append(f"pp={t['prompt_n']}")
print("\t".join([f"{dec:.2f}", f"{t['predicted_per_second']:.2f}", f"{t['prompt_per_second']:.2f}", sha, ";".join(note)]))
PY
}

run_point() {  # <index>; runs inside flock
  local model gate vars t0 line csv brf k i hits
  IFS='|' read -r MODEL LABEL gate vars <<<"${POINTS[$1]}"
  DEC=""; DEC30=""; PF=""; SHA=""; MINFREE=""; LOAD_S=""; SETTINGS=""; SPID=""; SAMP=""
  # shellcheck disable=SC2086
  build "$MODEL" $vars
  mkdir -p "$LOGD"; [ -s "$TSV" ] || printf '%s\n' "$HDR" > "$TSV"
  csv=$LOGD/vram-speedpush-$LABEL.csv; brf=$LOGD/BREACH-speedpush-$LABEL; rm -f "$csv" "$brf"

  gate_ok "$gate" || { row skip "gate: $GATE_WHY"; return 0; }
  case " $vars" in *" mtp="*) head -c 16000000 "$MODEL_FILE" | grep -ac nextn >/dev/null ||   # -q exits early -> SIGPIPE on head -> pipefail = false "no nextn" (21:03 bug)
    { row skip "gguf has no nextn (MTP) head"; return 0; };; esac
  gate_check || { row fail "gate_check refused"; return 3; }
  io_quiet_wait || { row fail "disk busy io_full=${IO_BUSY:-?}"; return 3; }
  line=$(mem_guard "$MODEL_FILE" dio 0); [ "${line%% *}" = OK ] || { row fail "mem_guard $line"; return 3; }
  set +u; . "$LAB/bench/configs/sycl-env.sh"; set -u

  trap 'stop_server; stop_sampler' EXIT
  trap 'exit 4' INT TERM
  t0=$(date +%s)
  VRAM_FLOOR_MIB=$FLOOR setsid nohup python3 "$BO/vram-sampler.py" "$csv" "$brf" >/dev/null 2>&1 & SAMP=$!
  "${CMD[@]}" > "$LOGD/speedpush-$LABEL.server.log" 2>&1 & SPID=$!
  for i in $(seq 600); do
    curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null && break
    kill -0 "$SPID" 2>/dev/null || break
    [ -e "$brf" ] && break
    sleep 1
  done
  LOAD_S=$(( $(date +%s) - t0 ))
  if curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null && [ ! -e "$brf" ]; then
    k=$(timeout 1500 bash -c "$(declare -f probe); PORT=$PORT; probe" 2>"$LOGD/speedpush-$LABEL.probe.err")
    IFS=$'\t' read -r DEC DEC30 PF SHA NOTE <<<"$k"
    [ -n "$DEC" ] || NOTE="probe failed, see speedpush-$LABEL.probe.err"
  else
    NOTE="server never healthy (exited or breach)"
  fi
  stop_server; stop_sampler
  MINFREE=$(awk -F, 'NR>1 && $2!="" && (m==""||$2<m){m=$2} END{print m}' "$csv" 2>/dev/null)
  hits=$(journalctl -k --since "$(date -d @"$t0" '+%F %T')" --no-pager -o cat 2>/dev/null | grep -Ec 'ABORT|Engine reset|device wedged|Timedout job')

  local status=ok
  [ -n "$DEC" ] || status=fail
  [ -e "$brf" ] && { status=fail; NOTE="BREACH $(tr -d '\n' < "$brf") ${NOTE:-}"; }
  [ -n "$MINFREE" ] && [ "$MINFREE" -lt "$FLOOR" ] && status=fail
  [ "$hits" -gt 0 ] && { status=fail; NOTE="KLOG-HITS=$hits ${NOTE:-}"; }
  [ -n "$MINFREE" ] && [ "$MINFREE" -lt 1500 ] && NOTE="free<1500 ${NOTE:-}"
  row "$status" "${NOTE:-}"
  for i in $(seq 90); do   # wait for the VRAM to come back before the next load
    k=$(python3 "$LAB/bench/arc-vram.py" | sed -n 's/.*free=\([0-9]*\).*/\1/p'); [ "${k:-0}" -gt 8000 ] && break; sleep 1
  done
  [ "$hits" -gt 0 ] && return 5
  return 0
}

ONLY=.; SKIP=""; MODE=run; POINT=""
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) MODE=dry;; --selftest) MODE=self;; --point) MODE=point; POINT=$2; shift;;
    --only) ONLY=$2; shift;; --skip) SKIP=$2; shift;;
    *) echo "usage: $0 [--dry-run|--selftest] [--only RE] [--skip RE]" >&2; exit 2;;
  esac
  shift
done
case $MODE in
  dry)   dry_run; exit 0;;
  self)  selftest; exit $?;;
  point) cd "$LAB" && run_point "$POINT"; exit $?;;
esac
for i in "${!POINTS[@]}"; do
  IFS='|' read -r _ lbl _ <<<"${POINTS[$i]}"
  [[ $lbl =~ $ONLY ]] || continue
  [ -n "$SKIP" ] && [[ $lbl =~ $SKIP ]] && continue
  echo "[$(date +%T)] point $lbl"
  flock -x -w 7200 -E 75 "$LOCK_FILE" bash "$SELF" --point "$i"; rc=$?
  [ "$rc" -ne 0 ] && { echo "[$(date +%T)] stopped at $lbl rc=$rc (3 gate refused, 5 kernel-log hit: report and ack, 75 lock timeout)"; exit "$rc"; }
done
echo "done -> $TSV"
