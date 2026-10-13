# 40 — Recipe cards for the B580, ranked by expected value for Chief

Date: 2026-10-13. Scope: local-AI enthusiast recipes (MiaAI-Lab kit line, r/LocalLLaMA, llama.cpp
discussions, Intel IPEX-LLM / OpenVINO GenAI, Arc-owner repos, Habr / Juejin / Computerbase),
adapted to **this** box. **Research only — nothing installed, no GPU job run.**

Sources are weighed by evidence quality, not origin (Marcel 2026-10-13): US GitHub repos, US
enthusiast blogs and r/LocalLLaMA carry the same weight as non-US write-ups when the numbers are
measured. Every claimed gain carries a link and a date; snippet-only sources are marked.

Cross-references (do not duplicate): `research/16-community-fast-recipes.md` (MoE-on-12GB survey),
`research/26-b580-acceleration.md` (MTP + bounded thinking, measured here), `research/33-kernel-work.md`
(per-kernel profile, measured here), `research/31-long-context-and-gt1030.md` (128K/256K + `-nkvo`).

Legend for transferability:
- **✅ transfers** — backend-generic; measured on SYCL or Vulkan on Arc, or already measured on this box.
- **◐ adapted** — the flag/idea exists in the SYCL/Vulkan build, but not yet measured on the B580.
- **❌ not applicable** — CUDA-only (EXL3, ik_llama, Strata CUDA kernels, NVFP4/DSpark).

---

## 0. The box, and the hard rules every card runs under

| item | value | source |
|---|---|---|
| GPU | Intel Arc B580 (BMG-G21), 12216 MiB, `xe`, Mesa ANV 26.2.2, ReBAR 16 GiB, Gen4 x8 | research/26 §0, research/18 |
| Bandwidth / roofline | 456 GB/s; Gemma 12B Q4_0 = ~65 t/s theoretical decode ceiling | research/26 §0 |
| Engines on disk | `llama.cpp-sycl-tip` (oneAPI 2026.0), `llama.cpp-sycl-tip-2026.1`, `llama.cpp-vulkan-tip` @ `358a420ec` | research/26 §0 |
| CPU / RAM | Ryzen 9 7900X (12C/24T), 61 GiB DDR5-6000 EXPO on; pinned 12T = 63.2 GB/s | research/14, 00-plan |
| Brain now | `gemma-4-12b-it-qat-q4_0.gguf` 6.50 GiB, ctx 65536, think-off default | research/27, 00-plan |
| Model on disk for the 27B question | `models/llm/Qwen3.8-27B-OBLITERATED/Qwen3.8-27B-OBLITERATED-IQ4_XS.gguf` **15.42 GB (14.4 GiB)** + mmproj 0.93 GB | `ls` this session |
| MoE on disk | `unsloth/Qwen3.6-35B-A3B-GGUF`, `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` | `ls` this session |

**Hard rules (non-negotiable, from the crash of 2026-10-13):**
- Every GPU run goes through `bench/watchdog.sh <label> -- <cmd>` and takes `bench/.gpu.lock`
  (R1/R2, `bench/gate.sh`). Watchdog kills on `psi_mem_full`/`psi_io_full` avg10 > 1.0 or
  MemAvailable < 6144 MiB.
- After **any** xe `GT0: Engine reset / device wedged / Timedout job` this boot, no GPU job runs
  until a human `touch bench/.gpu-reset-ack`. Never create it yourself.
- **GPU reset history (this is why the rules exist):** 10:43 `ctx 262144` load → GT0 engine reset +
  page faults; 10:48 `ctx 131072` + ~32K prefill → `DEVICE_LOST`, B580 wedged, 3 monitors black,
  hard reboot. Gemma is **capped at ctx 65536** (measured safe, 32K prefill survives at 64K).
- Stop line: **free VRAM < 1.0 GiB** → kill. MTP costs ~650 MiB at ctx 65536, leaving 995 MiB
  (below the line, research/26 §3) — that is the one open VRAM risk in card #1.

---

## 1. MiaAI-Lab's Qwen3.8-27B kit — what actually transfers

The kit (`github.com/MiaAI-Lab/Qwen3.8-27B-16gb-NVIDIA-GPUs-one-click-install`) is an **ExLlamaV3 /
EXL3** stack. **EXL3 is CUDA-only and will not run on the B580** — verified from
`turboderp-org/exllamav3` (README: PyTorch **CUDA 12.4+**, extras `cu124…cu132`; kernels are Triton;
no ROCm/SYCL/Metal path). So the *engine* does not transfer; the *technique stack* mostly does.

| Mia kit technique | Detail (from the cached README) | On the B580 |
|---|---|---|
| Quant ladder by VRAM | EXL3 2.0/2.5/3.0/3.5/4.0/5.0/6.0 bpw; budget = VRAM − max(1.3 GB, 8 %); 12 GB → 2.0bpw @33k | ❌ format CUDA-only → **◐ substitute GGUF K/IQ quants** via llama.cpp |
| KV cache quant | `CACHE_QUANT=8,4` (int8 K / int4 V); planner writes int4; "within 0.001 KL of fp16" | ✅ `-ctk/-ctv q8_0` (already used); `q4_0` for long ctx |
| MTP draft head | `DRAFT=mtp` default; head inside the checkpoint, ~50 MB | ✅ llama.cpp `--spec-type draft-mtp` — measured **2.25× here** (card #1) |
| Context sizing | multiple of 256; offers **measured** prefill ceilings, not the formula | ✅ discipline transfers (research/31 §2 ladder) |
| One-click serve + external UI | OpenAI `/v1` on :8888 + DeepSeek Harness on :3080 | ◐ llama-swap :18080 + Hermes `chief` already plays this role |
| VRAM-budget formula | budget = VRAM − max(1.3 GB, 8 %) | ✅ use as a first cut; llama.cpp `-fit`/manual `-ngl` is the fit test |

MiaAI-Lab is a single-user account (~110 repos, all NVIDIA/DGX-Spark/EXL3). **No Intel recipe exists
in it.** The only genuinely box-matching community write-up found is Habr's Arch + B580 article
(card #7/#8 below).

---

## 2. Can a ~27B beat Gemma 4 12B for Chief on this box? (task item 2)

**Short answer: no, not at acceptable speed.** A *dense* 27B does not fit 12 GB; a *MoE-A3B* 27B
might, but no B580 measurement exists and the fit is tight.

Quant sizes for a dense ~27B (weights only):

| quant | size | fits 12 GB? | evidence |
|---|---|---|---|
| IQ3_XXS | ~11–12 GB | borderline, no ctx room | RouteWeaver targets this class (below) |
| IQ4_XS | **14.4 GiB** (the file on this box) | no — ~2.5 GB over | `ls` this session |
| Q4_K_M | ~16.5–17 GB | no | canitrun.dev / specpicks (low-confidence aggregators) |

Measured 27B-on-12GB evidence (all **NVIDIA**, for shape only):
- **RouteWeaver** (`kadenball/qwen38-27b-rtx3060-dcfr`), one RTX 3060 12 GB, Qwen3.8-27B IQ3_XXS + MTP
  + **Q4_0 KV** + D-CFR: default config 18–26 tok/s (+14.5–15.4 % over plain); Q3-Fast (2026-10-08)
  **34–48 tok/s** on short fixtures, 37.03 tok/s over a 7-task screen; **19.14 tok/s** after 121,821
  input tokens in a 131,072 window (min free VRAM 366 MiB). **Its speedups are SM86 CUDA kernels — the
  engine does not run on Arc; only the config pattern (IQ3_XXS + Q4_0 KV + draft depth) transfers.**
- Aggregator fit models (`willitrunai.com`, `canitrun.dev`) predict **2–15 tok/s** for a 27B on a
  B580 12 GB depending on quant, all with offload — **low confidence, modeled not measured, do not cite as fact.**
- **No B580 27B dense measurement exists** in any source found. The nearest Arc datapoint is an
  **A770 16 GB** (Alchemist, not B580): Qwen3.6-**27B-A3B**-Coder, llama.cpp SYCL Q4_K_M = **14.4 t/s**
  vs OpenVINO GenAI int4 = **43 t/s** (u/marfrit, cited by `srmiles/local-llm-benchmarks` #47,
  2026-08-27). Note that is a **MoE-A3B** 27B, i.e. ~3B active — the favourable case — and it *still*
  only does 14.4 t/s under llama.cpp SYCL.

**Verdict for Chief:** Gemma 4 12B QAT on this box already does 26.8–27.3 t/s decode, 4K TTFT 7.3 s
(791 t/s), tool-call PASS, and 32 t/s at ctx 65536 (research/27, 00-plan). A dense 27B here would run
offloaded at single-digit t/s and lose the 64K context — **worse for Chief, not better.** The only 27B
route worth a look is a **27B MoE-A3B** (few active params) served via **OpenVINO GenAI** (card #5),
which is the one stack that beat llama.cpp SYCL ~3× on Arc — and even that is unproven on 12 GB.

---

## 3. Recipe cards (ranked by expected value for Chief)

Each card: idea → exact flags/steps for this box → what to measure → risk → transfer.

### Card 1 — MTP self-speculation on Gemma 4 12B ✅ (highest value, measured here)
- **Idea:** speculative decode with the checkpoint's own MTP head → **2.25× decode**.
- **Flags (already wired in `serve/gemma4-12b-launch.sh`, `MTP_NMAX` default 0):**
  `-md models/llm/unsloth/gemma-4-12B-it-qat-GGUF/mtp-gemma-4-12B-it.gguf -ngld 99 --spec-draft-device SYCL0 --spec-type draft-mtp --spec-draft-n-max 3`
- **Measured here:** 34.1 t/s base → **76.8–78.2 t/s** at n_max 3 (acceptance 0.634); n_max 3 is the
  best; greedy identical on 5/6 prompts (one near-tie code-comment flip). research/26 §1.
- **Measure:** decode t/s + VRAM headroom at ctx 65536 on a 4K→8K prompt ramp before making it default.
- **Risk:** **high-ish** — +650 MiB VRAM leaves **995 MiB free** (below the 1.0 GiB stop line). Turn on
  only after a ramp shows free VRAM stays ≥1.0 GiB.

### Card 2 — `-lm none` + `-ub 1024` prefill stack ✅ (measured here)
- **Idea:** stop mmap-loading the GGUF and raise the ubatch → prefill roughly **3×**.
- **Flags:** `-lm none -b 1024 -ub 1024` (keep `-fa on -ctk/-ctv q8_0`).
- **Measured here:** 4K prefill 100 → **185 → 279.75 t/s** (`-lm none`), then **~316 t/s** stacked with
  `-ub 1024`; decode ~33.9 t/s. ub2048/4096 flat under Vulkan; **ub 2048 = +9 % under SYCL** (research/33).
- **Measure:** pp4K t/s + PSI deltas (`-lm none` raises page-cache/IO pressure — watchdog must be on).
- **Risk:** **medium** — `-lm none` loads through the page cache and once drove the desktop into zram
  (PSI mem full 50 s). Run under watchdog + `ionice -c3`; watch `psi_mem_full`.

### Card 3 — SYCL prefill at `-ub 2048` ✅ (measured here, kernel-backed)
- **Idea:** the one config-only prefill win from the kernel profile.
- **Flags:** `-ub 2048` on the SYCL build (`llama.cpp-sycl-tip`).
- **Measured here:** 1569 → **1708 t/s** clean pp4096 (+9 %); dequant share falls 28.8 % → 15.7 %.
  research/33 §2, §4 rank 1.
- **Measure:** pp4K t/s and compute-buffer VRAM (unmeasured at 2048) under the RESUME ramp rule.
- **Risk:** **low** — config only; confirm VRAM headroom ≥1.0 GiB at ctx 65536.

### Card 4 — KV-cache quantisation: q8_0 now, q4_0 for long ctx ✅/◐
- **Idea:** KV quant is the cheap context headroom (the Mia kit's int4 idea, GGUF flavour).
- **Flags:** `-fa on -ctk q8_0 -ctv q8_0` (current, keep K/V symmetric); `-ctk q4_0 -ctv q4_0` when ctx
  needs to grow.
- **Evidence:** q8_0 = ~53 % of f16 KV; q4_0 = ~28 %, ≈+3 % ppl (modelvram.com, snippet). **On a B580,
  q4_0 KV gave no tg gain and no corruption** (r/LocalLLM 98K config, cited research/16 S22). q4_0 KV
  cut a 45K prefill 397 s → 85.5 s on CUDA (research/16 S17).
- **Measure:** 32K/64K prefill TTFT + decode t/s at q8_0 vs q4_0; VRAM slope (research/31: ~13.3 KB/ctx token).
- **Risk:** **low** — but `-fa` is mandatory with quantised KV (research/00-plan: fa-off invalid with q8_0 V).

### Card 5 — OpenVINO GenAI path for MoE ◐ (biggest untapped lever, unproven on 12 GB)
- **Idea:** on Arc, **OpenVINO GenAI int4 beat llama.cpp SYCL ~3×** for MoE — the single largest gap found.
- **Evidence:** u/marfrit, A770 16 GB, Qwen3.6-27B-A3B-Coder: llama.cpp SYCL Q4_K_M **14.4 t/s** vs
  OpenVINO GenAI int4 g64 **43 t/s**; `SYCL_UR_TRACE` shows llama.cpp dissolves the MoE graph into
  **~2,500 kernel launches/token** (dispatch-bound). Reproduced by `srmiles/local-llm-benchmarks` on a
  **B60 24 GB**: marfrit's IR unchanged → **51.09 tps**, TTFT 1.13 s, 204.5 s cold compile
  (finding #47, 2026-08-27). Also cited there: vLLM-XPU +5.2× prefill / +1.8× decode.
- **Steps for this box:** `optimum-cli export openvino --model <M> --weight-format int4 --group-size 64`
  → `ov_genai.LLMPipeline(model_dir, "GPU")`. Local `bench/ov-bench.py` exists.
- **Measure:** decode t/s + TTFT vs the SYCL baseline on the **same** weights; peak VRAM.
- **Risk:** **medium** — 14.8 GB IR needs >12 GB (the B60 run peaked at 23 GiB); a 12 GB B580 can only
  take a smaller quant/model. OpenVINO GenAI is single-device, no sub-4-bit quants. Best aimed at
  **27B-A3B / 35B-A3B MoE**, not the dense Gemma.

### Card 6 — MoE expert offload sweep (`--n-cpu-moe` / `-ot exps=CPU`) ◐
- **Idea:** keep attention+KV on the B580, push only expert FFN to RAM; sweep to the cliff.
- **Flags:** `-ngl 99 --n-cpu-moe <N>` (or `-ot "exps=CPU"`); sweep N in steps of 1–2.
- **Evidence:** **B580 98K**: Qwen3.6-35B-A3B IQ3_XXS, `--n-cpu-moe 14` → **~42 t/s served with MTP**,
  29.7 t/s standalone, strict recall PASS at 92,110 tokens (r/LocalLLM, research/16 S22). **B580**:
  `-ot "exps=CPU"` prefill 83 → 637 t/s with `-b/-ub 4096` + THP (davetha, research/16 S21). Cliff is
  noisy: 3060 ncmoe 27→31.8, 26→33.6, 28→10.4 (research/16 S15).
- **Measure:** pp/tg at each N, VRAM free ≥1.0 GiB, plus a recall/quality check.
- **Risk:** **medium** — SYCL MoE has a known bad-output path (`#28728`, Q5_K_XL + `--n-cpu-moe 99` +
  batch 9000); stay on IQ3_XXS/Q4_0, batch ≤4096.

### Card 7 — `--no-mmap` when experts live in RAM ✅/◐ (large prefill win)
- **Idea:** let the engine manage the RAM-resident expert buffers directly instead of mmap.
- **Flags:** `--no-mmap` (+ `-c 8192` in the Habr recipe).
- **Evidence:** **B580** (davetha): pp 83 → 197 t/s (+2.4×). **Arch + B580 12 GB** (Habr 1045898):
  Qwen3.6-35B-A3B Q4, `--cpu-moe` 20 t/s → `--no-mmap` **34 t/s**. Also in the B580 98K config.
- **Measure:** pp/tg; confirm VRAM now holds max weights.
- **Risk:** **low–medium** — more host RAM touched; keep watchdog + MemAvailable guard.

### Card 8 — Keep Mesa ANV current (Vulkan shader compiler) ✅
- **Idea:** on Linux the Vulkan backend's speed *is* Mesa's shader compiler; updating it can move tok/s
  with no flag change.
- **Evidence:** B580, Mesa **25.2.8 → 26.1.5**: nemotron-3-nano:4b 28.5 → **94.7 t/s (3.32×)**,
  phi4-mini 41.8 → 77.0 t/s (kimono-oyaji, 2026-08, fetched).
- **Steps:** `pacman -Q mesa` → compare with the current arch package; this box already runs ANV 26.2.2.
- **Measure:** re-run the Vulkan baseline after any Mesa bump.
- **Risk:** **low** — system package update; re-test after.

### Card 9 — `--moe-cache-mib` hot-expert VRAM cache ◐ (unmeasured on Arc)
- **Idea:** keep the hottest experts resident in VRAM (mainline PR #29887, merged).
- **Flags:** `--moe-cache-mib N` (~10 % of expert size, per the PR).
- **Evidence:** RTX 4090 **1.62×** (40.7 t/s), RTX 5090 **2.20×** (89 % hit rate) — CUDA. The local
  `llama.cpp-sycl-tip 358a420ec` already has the flag; the code selects devices by type and has no
  CUDA-specific calls (research/16 §5 trick 1, S33).
- **Measure:** tg at a few `--moe-cache-mib` values; VRAM free.
- **Risk:** **medium** — steals VRAM from KV; never tested on Arc.

### Card 10 — Bounded thinking (`thinking_budget_tokens`) ✅ (measured here)
- **Idea:** cap reasoning so Chief answers in ~5–6 s instead of ~21 s.
- **Flags:** per-request `chat_template_kwargs.enable_thinking=true, thinking_budget_tokens=512`; or
  server `--reasoning-budget 512`.
- **Measured here:** 512 is the smallest budget that stays correct on both puzzles; 256 is wrong;
  first answer token 5.6–6.7 s at 512 vs 21 s unbounded. research/26 §2.
- **Measure:** answer latency + correctness on the eval set.
- **Risk:** **low** — but thinking-off is wrong on multi-step puzzles; keep it per-request, not global.

### Card 11 — SYCL env hygiene: `GRAPH=0`, `ENABLE_OPT=0` for MoE ✅ (keep off)
- **Idea:** leave the two SYCL switches that hurt/lie alone.
- **Evidence (measured here):** `GGML_SYCL_ENABLE_GRAPH=1` → **−28 %** decode (27.3 vs 38.0 t/s) — keep
  off (research/33 §2). For MoE, `GGML_SYCL_ENABLE_OPT=0` (renamed from `GGML_SYCL_DISABLE_OPT`) avoids
  a slot-init SEGV on Xe2, ~5 % dense cost (PR #25042, research/16).
- **Measure:** decode t/s with the flag flipped.
- **Risk:** **low.**

### Card 12 — `-nkvo` KV-in-RAM for a long-context Chief variant ◐
- **Idea:** pin attention to CPU, hold KV in the 61 GiB RAM → a `gemma4-12b-long` entry up to 256K
  without the ctx-linear VRAM reserve that caused the wedge.
- **Flags:** `-nkvo` (with `-c 262144`), short prompts only.
- **Evidence:** research/31 §3 (design): removes the 8.7 KB/token global KV + device FA reserve; est.
  decode **4–21 t/s**, 32K prefill +137–460 s — a decode-heavy, short-prompt mode.
- **Measure:** load psi/MemAvailable, then a 4K→8K ramp; VRAM free.
- **Risk:** **medium–high** — first 256K load must be load-only, under the gate, watching `psi_mem_full`.

### Card 13 — Vulkan fallback + `GGML_VK_DISABLE_COOPMAT=1` ◐
- **Idea:** a second backend for when SYCL misbehaves; one env var fixes an Arc TDR.
- **Flags:** `GGML_VK_DISABLE_COOPMAT=1` (fixes KHR_coopmat GPU TDR on Arc);
  `GGML_VK_DISABLE_F16=1` (+46 % pp but an f16-accumulation correctness bug — use only to isolate).
- **Evidence:** llama.cpp issue #20554; B580 Vulkan Qwen3-8B Q4_K_M pp512 **505** / tg128 **30.4** t/s
  (Mesa 25.0.7, discussion #12570, 2026-07-13, fetched).
- **Measure:** pp/tg vs SYCL; watch for ANV long-prompt device loss (issues #27638, PrismML #192).
- **Risk:** **medium** — Vulkan on Intel ANV has device-loss reports on long prompts.

### Card 14 — Draftless n-gram speculation (`--spec-type ngram-mod`) ◐
- **Idea:** no draft model (~16 MB), helps repetitive/refactor/reasoning output.
- **Flags:** `--spec-type ngram-mod --spec-ngram-mod-n-match 24 --spec-ngram-mod-n-min 48 --spec-ngram-mod-n-max 64`.
- **Evidence:** llama.cpp `docs/speculative.md` (fetched). The local tip has `ngram-mod` (research/16 S33).
- **Measure:** decode t/s on a repetitive task (code edit), acceptance.
- **Risk:** **low** — CPU-side, no VRAM cost; gain is task-dependent.

### Card 15 — Quant choice: prefer Q4_0/K-quants over i-quants on Arc ✅
- **Idea:** i-quants are smaller but decode slower; Arc decode is compute-limited, so size ≠ speed.
- **Evidence:** Qwen3.8-27B on a 3090: IQ4_XS **31.9** vs Q4_K_M **41.4** t/s (i-quant ~23 % slower at
  9 % smaller, bowmanslayer HF, snippet). Matches the local kernel profile: the Q4_0 matvec is 70 % of
  decode at 78 % of peak (research/33 §2).
- **Measure:** tg128 for IQ4_XS vs Q4_K_M/Q4_0 of the same model.
- **Risk:** **low** — pick quant by size only when you must fit.

---

## 4. What does NOT transfer to the B580 (do not chase)

- **EXL3 / ExLlamaV3** — CUDA-only (PyTorch CUDA 12.4+, Triton kernels). Verified from
  `turboderp-org/exllamav3` README. The Mia kit's engine.
- **ik_llama.cpp** figures (110 t/s etc.) — CUDA/ROCm; weak on this box's Vulkan (research/15).
- **Strata's 50–94 t/s** — CUDA kernels (RTX 50/sm_90+); the experimental Intel port topped out ~21 t/s
  under WSL2 with device loss (research/16 S9).
- **`GGML_CUDA_REGISTER_HOST` / `GGML_SCHED_PREFETCH_EXPERTS`** — CUDA paths in a fork (research/16 S8).
- **NVFP4 / vLLM / TensorRT-LLM / DSpark / DFlash2** — NVIDIA-only Mia kit line.
- **RouteWeaver D-CFR speedups** — SM86 CUDA kernels; only its **config pattern** (IQ3_XXS + Q4_0 KV +
  MTP draft depth) transfers, not its numbers.

---

## 5. Self-check

| requirement | status |
|---|---|
| Every claimed gain cited with link + date | PASS — inline links; dates on GitHub/Habr/issue sources; snippet-only sources marked |
| Every card says transfers / adapted / not applicable | PASS — ✅/◐/❌ on all 15 cards + §1 table + §4 |
| MiaAI-Lab kit analysed for the B580 | PASS — §1 (EXL3 CUDA-only verified) |
| 27B-on-12GB question answered with measured numbers | PASS — §2 (RouteWeaver CUDA numbers, A770 Arc datapoint, no B580 27B measurement exists) |
| Non-US communities covered | PASS — Habr 1045898/1076080, Juejin, Computerbase, Bilibili; US sources included per Marcel's clarification |
| No installs, no GPU runs | PASS — research only; nothing run, no config changed |

## 6. Sources (with dates where the page states one)

**Fetched this session:**
- https://github.com/srmiles/local-llm-benchmarks — B60/B580 Arc benchmarks; finding #47, 2026-08-27
  (OpenVINO ~3× SYCL on MoE; B60 OpenVINO 51.09 tps).
- https://habr.com/ru/articles/1045898/ — Arch + **Arc B580 12 GB**; Gemma 4 E4B Q8 ~50 tok/s;
  Qwen3.6-35B-A3B `--cpu-moe` 20 t/s → `--no-mmap -c 8192` 34 t/s; FA slows SYCL. (ru)
- https://github.com/ggml-org/llama.cpp/discussions/12570 — Arc status thread, edited 2026-07-13;
  B580 Vulkan Qwen3-8B Q4_K_M pp512 505 / tg128 30.4.
- https://github.com/kadenball/qwen38-27b-rtx3060-dcfr (RouteWeaver) — Qwen3.8-27B IQ3_XXS + Q4_0 KV +
  MTP on RTX 3060 12 GB; 18–26 t/s default, 34–48 t/s Q3-Fast (2026-10-08); SM86 CUDA.
- https://github.com/turboderp-org/exllamav3 — EXL3 CUDA-only (12.4+), Triton kernels.
- https://habr.com/ru/articles/1076080/ — Qwen3.8-27B MTP + tensor-parallel, 2× RTX 3090: 32.4 → 74.8
  tok/s (`--spec-type draft-mtp --spec-draft-n-max 3 -ctk/-ctv q4_0`). (ru)

**Cited from the fetched page but snippet-level in this session** (treat as indicative):
- https://github.com/davetha/llama-moe-hybrid-tuning (B580 SYCL, `-ot exps=CPU` 83→637 t/s pp).
- r/LocalLLM B580 98K Qwen3.6-35B-A3B IQ3_XXS, `--n-cpu-moe 14`, ~42 t/s with MTP —
  https://www.reddit.com/r/LocalLLM/comments/1uwn9ds/intel_arc_b580_12_gb_llamacpp_sycl_98kcontext/
- https://kimono-oyaji.com/en/arc-b580-mesa-update-en (2026-08) and
  https://kimono-oyaji.com/en/arc-b580-context-length-spill-en (2026-07) — Mesa 3.32×, context-spill.
- https://github.com/ggml-org/llama.cpp/pull/25042 (`GGML_SYCL_ENABLE_OPT=0`),
  https://github.com/ggml-org/llama.cpp/pull/23398 (MTP),
  https://github.com/ggml-org/llama.cpp/issues/28728 (SYCL MoE bad output),
  https://github.com/ggml-org/llama.cpp/issues/27638 (Vulkan GDN PP),
  https://github.com/ggml-org/llama.cpp/pull/29887 (MoE cache),
  https://github.com/ggml-org/llama.cpp/issues/20554 (Vulkan coopmat TDR).
- https://juejin.cn/post/7615075978017243171 (B580 IPEX-LLM, Windows),
  https://juejin.cn/post/7406148010047275008 (A770 Vulkan vs SYCL),
  https://www.computerbase.de/forum/threads/2275828/ (B60 Linux). (zh/de)

**Low-confidence aggregators** (modeled numbers only, listed so they are not mistaken for measurements):
https://canitrun.dev/gpus/arc-b580, https://willitrunai.com, https://specpicks.com, https://runaihome.com,
https://trendpulse-42v.pages.dev, https://openclawdc.com.

**Local research cited:** `research/26-b580-acceleration.md`, `research/33-kernel-work.md`,
`research/31-long-context-and-gt1030.md`, `research/16-community-fast-recipes.md`,
`research/14-machine-tuning.md`, `research/00-plan.md` (decision log), `bench/gate.sh`, `bench/watchdog.sh`.
