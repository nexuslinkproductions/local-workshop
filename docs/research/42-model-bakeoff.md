# 42 — Model bakeoff: Ornith-1.5-9B + Ministral-3-14B vs Gemma 4 12B (B580)

**STATUS: STOPPED MID-RUN on Marcel's 2026-10-13 ~13:37 order.** Kernel oops at **13:17:46**
(`xe_shrinker_scan` inside `kswapd0`; `kswapd0[192] exited with irqs disabled`), kswapd0 dead,
memory pressure full ~38%. `bench/gate.sh` now refuses every GPU job on it
(`gate_check` → "GPU reset or kernel oops this boot at 13:17:46"). A reboot is required.
**No model was ever loaded in this lane** — only downloads ran. Nothing here needs a retry decision;
it needs a reboot. **Do NOT `touch bench/.gpu-reset-ack` yourself** (human only).

Verdict: **PENDING** — the 42-item Chief suite never ran, so there is no score for any of the three
models. What IS settled (below, all cited): both archs load on our SYCL build; both GGUFs + mmprojs
exist; and Ministral-3-14B Q4_K_M **cannot fit 12 GB at any ctx ≥ 32768 with the requested q8_0 KV**.

---

## 1. Done vs not done

| step | state | evidence |
|---|---|---|
| arch support (SYCL) | **DONE** — Ornith `qwen35`, Ministral `mistral3`, both present | `engines/llama.cpp-sycl-tip/src/llama-arch.cpp:41,147` (git `358a420ec`) |
| download Ornith Q4_K_M + mmproj | **DONE**, sizes match HF | `models/llm/ornith-ai/Ornith-1.5-9B-GGUF/` (5780090816 + 921704672 B) |
| download Ministral Q4_K_M | **PARTIAL 63%** | `…/Ministral-3-14B-Instruct-2512-Q4_K_M.gguf.part` = 5181259776 / 8239593024 B |
| download Ministral mmproj | **NOT STARTED** | — |
| sha256 verify vs HF | **NOT DONE** (sizes verified; sha step never reached) | expected shas in §3 |
| llama-swap entries `ornith-9b`, `ministral3-14b` | **DONE + validated** (7 models) | `serve/config.yaml`, `llama-swap -config serve/config.yaml -validate` |
| direct smoke (load/Say-OK/decode/prefill/VRAM) | **NOT RUN** | `bench/bakeoff42/logs/orch.log` stops at the download line |
| llama-swap smoke (tool call + vision) | **NOT RUN** | — |
| 42-item Chief suite × 3 + `--compare` | **NOT RUN** | `evals/chief/results/` does not exist |

Wall time spent before the stop: ~13:29:54 → 13:37 (downloads only). Logs:
`bench/bakeoff42/logs/orch.log` (phase log) and `bench/bakeoff42/logs/locked-run.log` (full stdout).

---

## 2. Files created / modified

| path | what |
|---|---|
| `serve/config.yaml` | **modified** — appended `ornith-9b` + `ministral3-14b` (validated, 7 models) |
| `serve/config.yaml.bak-bakeoff42` | backup of the pre-edit config (restore with `cp` if wanted) |
| `serve/bakeoff-launch.sh` | new — llama-swap launch wrapper (gate-run → watchdog → ionice → jobcap → llama-server), args `<port> <ctx> <main> <mmproj> [kv] [--mmproj-cpu]` |
| `bench/bakeoff42/orch-locked.sh` | new — locked phase: gate → download → sha/size → pick ctx → direct smokes |
| `bench/bakeoff42/pick_ctx.py` | new — KV/ctx sizing from the GGUF header + measured VRAM ceiling |
| `bench/bakeoff42/smoke.py` | new — one direct llama-server smoke (load, Say OK, decode, 4K prefill, VRAM) |
| `bench/bakeoff42/swap-smoke.py` | new — llama-swap smoke (tool call + vision + VRAM) |
| `bench/bakeoff42/run-suites.sh` | new — suite phase (swap smoke + 42-item suite ×3 + compare + stop llama-swap) |
| `models/llm/ornith-ai/Ornith-1.5-9B-GGUF/` | downloaded (2 files) |
| `models/llm/mistralai/Ministral-3-14B-Instruct-2512-GGUF/` | partial `.part` |

Nothing else touched. No `--force`, no `bench/.gpu-reset-ack`, llama-swap is **not running** (:18080 free).

---

## 3. Verified facts (no GPU load needed)

**Architecture tags** — read from the GGUF headers (first 48 MiB via HTTP Range, parsed with
`bench/gguf-meta.py`). The scout's `qwen3_5` tag is **wrong**: Ornith's real tag is **`qwen35`**.

| model | `general.architecture` | in SYCL build? |
|---|---|---|
| Ornith-1.5-9B | `qwen35` | yes (`LLM_ARCH_QWEN35` → `"qwen35"`) |
| Ministral-3-14B-Instruct-2512 | `mistral3` | yes (`LLM_ARCH_MISTRAL3` → `"mistral3"`) |

**HF identity (sizes = `content-length`, sha = `X-Linked-Etag`)** — verify after download with
`sha256sum`:

| file | bytes | sha256 (HF) |
|---|---|---|
| `Ornith-1.5-9B-Q4_K_M.gguf` | 5780090816 | `70c112196e0b7023803c9762752e46d29e612a92c83f995bc3ba1ceb07e8fab6` |
| `mmproj-Ornith-1.5-9B-BF16.gguf` | 921704672 | `626f9f90627402a6bf4a999111d0fbd69b5fcca7aa8ba089d69e5f10e8858e1d` |
| `Ministral-3-14B-Instruct-2512-Q4_K_M.gguf` | 8239593024 | `824e0f3373e69b84f2cae46fdcb9bd1ebc6ab3bfc7acc125d818b7b8178cc613` |
| `Ministral-3-14B-Instruct-2512-BF16-mmproj.gguf` | 879258784 | `ab7616148b7081030fd38e410c9213ce8346a8b0588291c8ca279058e78cfae7` |

**KV sizing** (`bench/bakeoff42/pick_ctx.py`, q8_0 = 1.0625 B/elem, K+V):

| model | layers | head_kv | head_dim | q8_0 KV | q4_0 KV |
|---|---|---|---|---|---|
| Ornith-1.5-9B | 33 | 4 | 256 | **70 KiB/token** | 37 KiB/token |
| Ministral-3-14B | 40 | 8 | 128 | **85 KiB/token** | 45 KiB/token |

**VRAM ceiling is measured, not assumed.** The B580 is 11605 MiB total; the desktop uses 1354–1538
MiB, so idle free is **10067–10251 MiB** (`bench/arc-vram.py`). Independent corroboration: the other
lane's gemma@65536 q8_0 run recorded `vram_free_min=1364` MiB
(`bench/logs/chief256k/p-65k-q8-ub512.json`). **Consequence: the task's "≥1.5 GiB free" target is not
reachable even by the gemma baseline at ctx 65536** — the binding constraint is the ≥1.0 GiB stop line.

**Resulting ctx picks** (measured ceiling 10067–10251 MiB, ≥1.0 GiB floor):

| model | ctx | KV | mmproj | predicted free |
|---|---|---|---|---|
| gemma4-12b (baseline) | 65536 | q8_0 | GPU | ~1.36 GiB (measured, other lane) |
| **ornith-9b** | **32768** | q8_0 | GPU | ~1.1 GiB (65536 would need 4.4 GiB KV — does not fit) |
| **ministral3-14b** | **16384** | **q4_0** | **CPU** (`--no-mmproj-offload`) | ~1.2 GiB |

> Ministral-3-14B Q4_K_M (7.67 GiB) + mmproj (0.82 GiB) leaves ~2.4 GiB for KV+buffers; **q8_0 KV at
> ctx ≥ 32768 (2.7 GiB) cannot fit**. It runs at ctx 16384 with q4_0 KV and the projector on CPU. This
> is a real limitation, not a config choice — flag it in the verdict.

---

## 4. Two blockers the next runner must know

1. **`run_suite.py` refuses to run while the GPU lock is held** (`preflight`: `flock -n .gpu.lock`).
   So the suite phase CANNOT be "under the lock" as the brief said — it runs with the lock **free**
   (the runner's own one-test-at-a-time contract). `bench/bakeoff42/run-suites.sh` asserts the lock is
   free and `gate_check` passes, then runs. This is why the phase is split in two.
2. **Chief's home moved twice today.** `run_suite.py` now launches `hermes -p chief` with
   `cwd=/home/nexuslink/NEXUS_AI_CENTER` (line 180). Any **manual** `hermes -p chief` smoke must run
   from `/home/nexuslink/NEXUS_AI_CENTER`. No suite results existed before any of the cwd steers, so
   nothing needs deleting.

---

## 5. Exact resume commands (after reboot + human ack)

```bash
# 0. HUMAN ONLY, after reboot:
touch ~/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu-reset-ack

# 1. locked phase — resumes the partial download (curl -C -), verifies sizes+sha, picks ctx,
#    runs the 3 direct smokes. Waits up to 2h for the GPU lock.
cd ~/NEXUS_AI_CENTER/LOCAL-AI-LAB
nice -n 10 ionice -c 3 flock -x -w 7200 bench/.gpu.lock bash bench/bakeoff42/orch-locked.sh

# 2. suite phase — llama-swap smokes (tool call + vision) + the 42-item Chief suite for
#    gemma4-12b, ornith-9b, ministral3-14b + --compare; stops llama-swap at the end. Lock must be free.
bash bench/bakeoff42/run-suites.sh

# 3. report inputs
cat bench/bakeoff42/logs/orch.log bench/bakeoff42/logs/suites.log
cat bench/bakeoff42/logs/compare-gemma-ornith-9b.txt
cat bench/bakeoff42/logs/compare-gemma-ministral3-14b.txt
ls evals/chief/results/bakeoff42-*.json
```

Interim numbers (load, decode, 4K prefill, VRAM) land in
`bench/bakeoff42/logs/<id>-direct.json`; tool-call/vision in `bench/bakeoff42/logs/swap-<id>.json`.

---

## 6. Preliminary read (not a verdict)

- Both models are **architecturally supported** on our SYCL build and both ship mmprojs — the scout's
  `qwen3_5` concern is moot.
- **Ornith-1.5-9B** is the only one that fits the B580 like gemma does (32K ctx, q8_0 KV, projector on
  GPU, ~1.1 GiB free) — it is the one worth the full suite.
- **Ministral-3-14B** costs a 16K ctx, a 4-bit KV cache and a CPU projector to fit — a heavy tax that
  makes it unlikely to beat gemma as Chief's brain regardless of its published tool-calling reputation.
- The suite score (tool calling, workspace navigation, invoice items, safety) is the only thing that
  can actually decide this, and it did not run.

## 7. Status update, 2026-10-13 14:45 (bake-off NOT run)

- Ministral-3-14B Q4_K_M download is complete and sha256-verified (`824e0f33...`), so the download blocker is cleared.
- The gemma baseline is now the eval id `gemma4-12b-eval` (ctx 49152, min free 1663 MiB in smoke). Details: research/43 section 7.
- The suite phase still fails on the same IO watchdog kill (`psi_io_full > 1.0`, the cause in research/43 section 7). Ornith-9b and Ministral-3-14B were never loaded under the suite, so there is still no score for any model.
- `run-suites.sh` now runs under the lock (`flock -x ... env LC_LOCKED=1`) and uses the eval id. `orch-locked.sh` gemma canary is at ctx 49152.
- Verdict: still PENDING. Decision on the watchdog IO rule is needed first (research/43 section 7).
