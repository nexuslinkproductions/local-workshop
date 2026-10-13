# 26 — Every real speed lever on the B580 for Gemma 4 12B (decode first)

Status: IN PROGRESS (started 2026-10-13 ~10:30 CEST). This file is written incrementally;
the final verdict table is at the end once the queue finishes.

## 0. Setup (read-only facts, checked this session)

| item | value | source |
|---|---|---|
| GPU | Intel Arc B580 (BMG-G21), 12216 MiB, `xe` driver, Mesa ANV 26.2.2 | `--list-devices`, orchestrator read |
| clocks | act 2850 MHz = rp0, min 1200, power1_cap 200 W, throttle `none` | orchestrator read (no sysfs written) |
| target | `gemma-4-12b-it-qat-q4_0.gguf` 6.50 GiB (6.98 GB), 48 blocks, Q4_0 weights | `bench/configs/matrix-gemma4-12b-qat-*.env` |
| draft candidate | `unsloth/gemma-4-12B-it-qat-GGUF/mtp-gemma-4-12B-it.gguf` 242 MiB, arch `gemma4-assistant`, `nextn_predict_layers` present | `llama-gguf r` |
| engines | `llama.cpp-sycl-tip` (oneAPI 2026.0), `llama.cpp-sycl-tip-2026.1` (oneAPI 2026.1), `llama.cpp-vulkan-tip` — all at `358a420ec` | `git rev-parse` |
| roofline | 456 GB/s / 6.98 GB per token = ~65 t/s theoretical decode ceiling | arithmetic |

Corrections to the brief:
* The SYCL env var named `GGML_SYCL_DISABLE_OPT` does **not** exist in this source. The Q4_0
  reorder switch is `GGML_SYCL_ENABLE_OPT` (default 1, `ggml-sycl.cpp:418`). Tested as `=0`.
* `OpenVINO/gemma-4-12b*` **does not exist** on HF (OpenVINO org ships Gemma 4 E2B, E4B,
  26B-A4B and 31B only). See §6.

## 1. Method

* One variable per run. Every llama-bench run = `bench/accel-run.sh` → `bench/matrix-bench.sh run`
  (pp4096 / tg128, `-r 3`, depth 0, `-fa on`, q8_0 KV, `-b/-ub 1024`, `-lm dio`, `-t 16`), rows in
  `bench/results-matrix.tsv`. Exception: KV/FA/threads/ub variants via the same script's overrides.
* Locking: the run takes `bench/.gpu.lock` itself with **no timeout** (the stock `-w 3600` gives up
  after an hour when another agent parks the lock). Disk-quiet wait happens **before** the lock
  (a download keeps io full avg10 near 3 %, the stock in-lock wait would hold the GPU for 30 min).
* After each run: `journalctl -k` grep for `GT0: reset|DEVICE_LOST|Timedout job` since the start.
* Speculative decoding: `bench/spec-session.sh` = one locked llama-server session
  (start → /health → warm-up → 6 English assistant prompts at temp 0, thinking off, 256 tokens →
  kill). Acceptance from llama-server `timings.draft_n / draft_n_accepted`.
  Lossless check: greedy base vs MTP replies compared text-for-text (`bench/accel-spec-compare.py`).
* Watchdog: all loads run under `bench/watchdog.sh` (PSI full / MemAvailable kill), `jobcap` with
  `CAP=14G`, `ionice -c 3`. Quiet-mode CPU pinning is **not** used (research/10 §6 measured it as
  no benefit, and the GPU is the bottleneck for these runs).



## after reboot 3 (2026-10-13 11:55-12:15 CEST): MTP lossless check, draft length, bounded thinking

Setup: SYCL0, llama.cpp-sycl-tip 358a420ec, Gemma 4 12B QAT Q4_0 + mmproj, MTP head `mtp-gemma-4-12B-it.gguf`.
Every llama-server ran under bench/.gpu.lock (outer flock, MATRIX_LOCKED/SPEC_LOCKED/THINK_LOCKED=1) and watchdog.sh.
No GPU reset, DEVICE_LOST or Timedout line this boot (`journalctl -k -b`: 0). `bench/.gpu-reset-ack` not present, not created.

### 1. MTP: greedy identity and speed (6 prompts, temp 0, thinking off, 256 max tokens)

Logs: `~/.hermes/cache/scratch/accel-spec-r26b2-*.jsonl|.err`, rows in `bench/results-matrix.tsv` (tags r26b2-*).

| run | pooled decode t/s | median | draft acceptance | greedy identical to base |
|---|---|---|---|---|
| base (rep 1, r26b) | 34.11 | 33.97 | - | - |
| base (rep 2, r26b2) | 34.82 | 34.93 | - | reference (rep 2 == rep 1 on 6/6) |
| MTP n_max 2 | 70.76 | 74.73 | 0.707 (637/901) | 5/6 |
| MTP n_max 3 (rep 1, r26b) | 76.84 | 85.12 | 0.634 (712/1123) | 5/6 |
| MTP n_max 3 (rep 2, r26b2) | 78.18 | 83.99 | 0.634 (712/1123) | 5/6 (same as rep 1) |
| MTP n_max 4 | 76.31 | 85.47 | 0.555 (750/1352) | 5/6 |
| MTP n_max 6 (r26b) | 57.94 | 64.95 | 0.445 (791/1778) | 5/6 |

Per prompt (base vs MTP, all n_max): dhcp factual, order email, sqlite-pg bullets, landlord email, meeting summary: identical.
csv-top5 (Python code): NOT identical at any n_max. First difference at char 650 of 948, a code comment:
base `# Convert the target column to a float for proper numeric sorting` vs MTP `... for numeric sorting`.
Same divergence for n2, n3 (both reps), n4, n6, so it is one near-tie flip in batched verify, not a per-n bug.
Not measured: the logit gap at that token. Verdict: MTP is 2.2x faster but not bit-identical; 1 of 6 prompts diverges, semantically equal.
Best n_max = **3** (highest pooled speed, reproducible across reps). n_max 4 is close; 2 and 6 are worse.

### 2. Bounded thinking, MTP n3, ctx 65536 (1 request per cell; greedy)

Logs: `~/.hermes/cache/scratch/r26b/think2-budget-n3/` (think-results.jsonl, server.err, vram-*.txt), `think2-server512-n3/`.
Puzzles: train (correct 16:20), clock (correct 17:07). reasoning/content tokens counted with /tokenize. t_first_reason = first reasoning chunk, t_first_content = first answer chunk (s).

| puzzle | variant | correct? | reasoning tok | content tok | t first reason (s) | t first answer (s) | finish | empty |
|---|---|---|---|---|---|---|---|---|
| train | off | WRONG (16:00) | 0 | 43 | - | 0.93 | stop | False |
| train | unbounded | correct | 558 | 42 | 0.97 | 7.05 | stop | False |
| train | budget256 | WRONG (16:30) | 255 | 38 | 0.16 | 2.9 | stop | False |
| train | budget512 | correct | 511 | 38 | 0.12 | 5.57 | stop | False |
| train | budget1024 | correct | 562 | 40 | 0.13 | 6.15 | stop | False |
| train | alias512 | correct | 511 | 38 | 0.13 | 5.38 | stop | False |
| clock | off | WRONG (17:03) | 0 | 5 | - | 0.75 | stop | False |
| clock | unbounded | correct | 1672 | 5 | 0.82 | 21.33 | stop | False |
| clock | budget256 | WRONG (14:20) | 255 | 288 | 0.14 | 2.91 | stop | False |
| clock | budget512 | correct | 511 | 5 | 0.13 | 5.59 | stop | False |
| clock | budget1024 | correct | 573 | 5 | 0.12 | 6.34 | stop | False |
| clock | alias512 | correct | 511 | 5 | 0.13 | 5.65 | stop | False |
| train | server-budget | correct | 511 | 38 | 0.93 | 6.21 | stop | False |
| clock | server-budget | correct | 511 | 5 | 0.85 | 6.69 | stop | False |

Findings:
* Honoured per request: `chat_template_kwargs.enable_thinking` and `thinking_budget_tokens` (reasoning capped at N: 255, 511, 560-573 at 1024 when the model finishes earlier). `reasoning_budget_tokens` alias also honoured (511).
* Honoured per server: `--reasoning-budget 512` (per-request enable only) caps reasoning at 511 on both puzzles.
* 256 is too small: train 16:30 and clock 14:20 are wrong. 512 is the smallest budget that answers both correctly. 1024 is also correct, but no faster in practice here (6.2-6.3 s vs 5.6 s to first answer token).
* No empty answers in any bounded run. Budget 256 on the clock still returned 288 tokens of content, so a short budget can ramble, not go silent.
* Thinking off is wrong on both puzzles (16:00 and 17:03), so it stays the default for `gemma4-12b`.
* Streaming: with thinking on, the first reasoning token arrives in 0.12-0.17 s at budget 256-1024, and 0.8-1.0 s unbounded. The first answer token arrives 5.6-6.7 s into a budget-512 run, 21 s unbounded on the clock.
* Caveat: one request per cell. Greedy decoding is deterministic here (base rep1 == rep2), so repeats add little. Sample size is 2 puzzles.

### 3. VRAM at ctx 65536 (arc-vram.py, after health, before any request)

* no MTP: free 1648 MiB, used 9957 MiB (`think2-nomtp-c65536/`, killed by the watchdog on psi_io_full 1.01 during the clock puzzle, so the VRAM sample is the only usable output of that run)
* MTP n3: free 995 MiB, used 10610 MiB (`think2-budget-n3/vram-after-load.txt`), 891 MiB after the run.
* MTP costs ~650 MiB at ctx 65536. 995 MiB is below the 1.0 GiB stop line in RESUME-after-reboot-2.md. Large prompts are untested at this headroom.

### 4. Config written (backups: `~/.hermes/cache/scratch/r26b/*.bak-before-reboot3`)

`serve/gemma4-12b-launch.sh`: MTP draft flags added behind `MTP_NMAX` (default **0 = off**):
```
MTP_NMAX="${MTP_NMAX:-0}"
MTP=$LAB/models/llm/unsloth/gemma-4-12B-it-qat-GGUF/mtp-gemma-4-12B-it.gguf
if [ "$MTP_NMAX" -gt 0 ]; then MTP_ARGS=(-md "$MTP" -ngld 99 --spec-draft-device SYCL0 --spec-type draft-mtp --spec-draft-n-max "$MTP_NMAX"); fi
# llama-server line: ... ${MTP_ARGS[@]+"${MTP_ARGS[@]}"} --jinja ...
```
Set `MTP_NMAX=3` as the default to turn it on. Left off because of the 995 MiB VRAM headroom above; this needs Marcel's OK.

`serve/config.yaml` (gemma4-12b entry, same process and ctx, alias gemma4-12b-think kept):
```
setParamsByID:
  gemma4-12b: { chat_template_kwargs: { enable_thinking: false } }
  gemma4-12b-think: { chat_template_kwargs: { enable_thinking: true }, thinking_budget_tokens: 512 }
```

### 5. Smoke through llama-swap (`~/.hermes/cache/scratch/r26b/smoke.py`, port 18088, MTP off as shipped)
* `gemma4-12b` (thinking off): "Vienna", 2 tokens, 3.1 s.
* `gemma4-12b-think` (budget 512): "17:07", completion 521 tokens (512 reasoning + answer), 15.5 s, reasoning chars 1151.
* servers_left 0. The `/unload` endpoint answered 405 (GET is probably the route); the children died on pkill anyway.

### Open
* MTP_NMAX stays 0 until Marcel accepts ~1 GiB VRAM headroom at ctx 65536. Measure a 4K-8K prompt ramp with MTP on (per RESUME rules) before turning it on.
* csv-top5 is the one non-identical greedy reply. Judge whether semantically-equal divergence is acceptable for Chief.
* Hermes profile `chief` still uses the `gemma4-12b` id. Use `gemma4-12b-think` on the Chief side for bounded thinking. Not changed here.
