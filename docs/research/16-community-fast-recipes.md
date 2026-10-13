# 16 — Community fast recipes: Flash-Next and MoE on 12 GB GPU + 64 GB RAM, and Intel Arc

Date: 2026-10-13. Scope: Sep–Oct 2026 preferred. Several sources are May–Jul 2026 or undated; section 9 gives dates where the page states one.
Method: sources fetched and read; numbers copied from the fetched text; flags verbatim from the fetched text. Search snippets without a fetch are excluded (section 9).
Nothing was run on this box. The B580 is held by ARC Raiders (00-plan decision log), so every figure here is someone else's measurement.
Tags [S#] point to the source list in section 9.

## 1. Verdict on the owner's claim

- **Partly true.** Flash-Next on NVIDIA 12 GB + 64 GB does reach far past stock llama.cpp, but the fastest numbers come from **Strata**, a separate engine, not from llama.cpp.
  - Strata, RTX 5070 12 GB + 64 GB DDR5: Q2_0 at 87.3 tok/s (1K context) and 76.2 (64K) [S2]. README: 94 tok/s writing answers [S1].
  - llama.cpp-based, RTX 4070 12 GB + 64 GB DDR5: 20.5–22.1 tok/s on a patched master stack [S4]. A 3060 laptop (12 GB modded) + 48 GB DDR4-3200: "10+" tok/s on UD-Q2_K_XL, "5 tok/s" on UD-Q4_K_XL [S5].
- **Qwen3.6-35B-A3B on 12 GB:** llama.cpp with `--n-cpu-moe` reaches 38.9 tok/s on a 3060 with 32 GB [S14] and 64.0 tok/s on a 4070 SUPER with 32 GB at 32K context (build label inconsistent) [S17]. On 12 GB cards, reported MTP and expert-cache gains run ~20–80% [S8][S16], and S8 is a fork; mainline PR #29887 reports 1.6–2.2× on 24–32 GB cards [S7].
- **Intel Arc:** no Arc 12 GB Flash-Next run above ~21 tok/s is in the sources [S9]. The best B580 result for Qwen3.6-35B-A3B is ~42 tok/s served with MTP at 98K context on mainline SYCL [S22]. That is the same band as the 3060 numbers, but at longer context and not like-for-like. No direct comparison exists.
- Our own measured baseline on this box: none yet.

## 2. Flash-Next (125B-A6B) on 12 GB GPU + 64 GB RAM

| Hardware | Engine | Quant · ctx | Decode tok/s | Prefill tok/s | What produced it | Src |
|---|---|---|---|---|---|---|
| RTX 5070 12 GB + 64 GB DDR5-5200 | Strata 0.1.26 | Q2_0 · 1K / 64K / 128K | 87.3 / 76.2 / 73.7 | 2,171 at 32K | VRAM expert cache, all experts pinned in RAM, SSD n-gram table, MTP | [S2] |
| same | Strata 0.1.26 | IQ3_XXS · 1K / 64K / 128K | 61.9 / 57.2 / 49.0 | 1,745 at 32K | same | [S2] |
| RTX 5070 12 GB + 64 GB | Strata (README) | Q2_0 | 94 (writes answers) | 2,650 (32K prompt) | same; engine 0.1.36 | [S1] |
| RTX 4070 12 GB + 64 GB DDR5 | upstream master b11241 + 5 PRs (not stock) | AD-4.27bpw-Q4_K_M-M64 · 96K | 20.5–22.1 (Gold); 25.3–27.1 (MTP tier) | 180–385 at 96K | `--fit on --fit-target 512`, `-ctk q8_0 -ctv q8_0`, `--lazy-mode on`, `--spec-type ngram-mod` | [S4] |
| RTX 4070 12 GB + 32 GB DDR4 | Strata, modified build (9ec3806, not upstream) | IQ2_XS · 100K | 48.2 median (accepted decode) | not reported | adaptive expert cache `--adapt-every 4 --adapt-swaps 24`, `--spec 6` | [S3] |
| 3060 laptop, 12 GB modded + 48 GB DDR4-3200 | llama.cpp master (build not stated) | UD-Q2_K_XL · 256K | "10+" (UD-Q4_K_XL: 5) | "40+" | `-cmoe -cram 2048 -ctk q8_0 -fit off`; codacus cache +25% | [S5] |
| RTX 4060 Ti 16 GB + 94 GB RAM (Xeon E5-2673 v3) | NInfer fork, custom CUDA | routed experts 4.58 bpw | 10.0 (0 GPU experts) → 19.2–24.1 (expert cache) → 21.7–25.5 (+1 MTP draft) | not reported | GPU expert cache per layer; MTP | [S6] |

Context: the llama.cpp-based runs above (S4 patched master, S5 master) sit at ~10–22 tok/s on 12 GB + 48–64 GB. Strata's 50–94 tok/s comes from a different engine with a different memory layout; a Japanese write-up says it is "built on llama.cpp / ggml components" [S10].

## 3. Qwen3.6-35B-A3B and similar MoE on 12–16 GB GPU

| Hardware | Stack | Quant · ctx | Decode tok/s | Prefill tok/s | Key flags (verbatim) | Src |
|---|---|---|---|---|---|---|
| RTX 4070 SUPER 12 GB + 32 GB DDR4 | "ik_llama.cpp b5095" per guide (label inconsistent) | APEX-I-Compact 17 GB · 32K→258K | 64.0 (32K, ncmoe 16) → 50.9 (258K, ncmoe 22) | 45K input 397 s (q8 KV) → 85.5 s (q4_0 KV) | `-ngl 99 --n-cpu-moe 22 -c 262144 --cache-type-k q4_0 --cache-type-v q4_0 --no-mmap --mlock` | [S17] |
| RTX 3060 12 GB + 32 GB DDR4-2133 | llama.cpp b10088 (67b9b0e) | UD-Q4_K_M 20.6 GB · 8K | 38.9 (empty), 38.2 (8K); ncmoe 20 → 42.6 but OOM with context | 413 | `-ngl 99 --n-cpu-moe 24 -fa on -c 8192` | [S14] |
| RTX 3060 12 GB + 16 GB RAM | llama.cpp b9850 (4f31eed), MTP | UD-Q4_K_XL 22 GB · 4K | 33.6 (ncmoe 26); 17.9 at ncmoe 24; 10.4 at 28 | 50–58 | `--spec-type draft-mtp --spec-draft-n-max 2 -ngl 99 --n-cpu-moe 26 -c 4096 -ctk q8_0 -ctv q8_0` (MTP acceptance 91%) | [S15] |
| RTX 3060 12 GB + 32 GB DDR4 | author-built (stack not stated) | APEX-MTP-Compact 17 GB Q4_K | 62 (ncmoe 16) → 75 avg, 87.5 peak with MTP | not reported | `-ngl 99 --n-cpu-moe 16 --spec-type draft-mtp --spec-draft-n-max 3`; self-labelled "Verified" | [S16] |
| RTX 4070 Super 12 GB + 48 GB DDR5-6000 | ik_llama.cpp (author) vs mainline mtp-bench | byteshape IQ4_XS 4.19 bpw | 110.2 average (ik); mainline 79.8–97.0 per task | not reported | `--spec-type draft-mtp` | [S20] |
| RTX 5070 Ti 16 GB + 32 GB DDR5 | llama.cpp b8829 | UD-Q4_K_M 22.1 GB · 128K | 51.2 (`--cpu-moe`) → 78.7 (`--n-cpu-moe 20`) → 79.3 (`-np 1`, 128K) | 87.9 → 100.6 → 135.8 | `--n-cpu-moe 20 -ngl 99 -np 1 -fa on -ctk q8_0 -ctv q8_0 -c 131072` | [S19] |
| RTX 5060 Ti 16 GB + DDR4 ~38 GB/s | ik_llama.cpp (author "VERIFIED July 2026") | UD-Q4_K_M 19.7 GB · 64K | 43 (`--n-cpu-moe 20`); author says mainline ~5–6 at same context | not reported | `--n-cpu-moe 20` | [S18] |
| RTX 4060 Ti 16 GB + 94 GB RAM | ik_llama.cpp, same host as S6 | UD-Q4_K_M | 43.8–44.4 | not reported | — | [S6] |

## 4. Intel Arc (B580 12 GB; B70/B60/B390 for reference)

| Card · host | Engine | Model · quant · ctx | Decode tok/s | Prefill tok/s | Note | Src |
|---|---|---|---|---|---|---|
| B580 12 GB + EPYC 74F3, 512 GB DDR4-2933 | llama.cpp SYCL | Qwen3.6-35B-A3B Q4_K ~20 GB · 256K | ~38, flat | 83 → 197 (`--no-mmap`) → 527 (`-b/-ub 2048`) → 637 (`-b/-ub 4096` + THP + boost) | `-ngl 999 -ot "exps=CPU"`; 8× prefill, decode unchanged | [S21] |
| B580 12 GB + i9-10850K, 24 GiB RAM (LXC, 12 vCPU) | llama.cpp b9982 (99f3dc322) SYCL, oneAPI 2026.1.0 | Qwen3.6-35B-A3B UD-IQ3_XXS 14.07 GB · 98K | ~42 served with MTP (acceptance 0.76 shallow, 0.92 deep recall); standalone tg128 29.7 (no MTP) | 210 cold at 92K; pp512 401 (standalone) | `--n-cpu-moe 14`; ncmoe 12 and 10 gave "failed to fit"; strict recall PASS at 92,110 tokens | [S22] |
| B580 12 GB + i7-14700, 32 GB DDR5 | llama.cpp SYCL (Docker) | Qwen3.6-35B-A3B UD-Q3_K_M 16.6 GB · 8K | ~39 | not reported | `--cpu-moe -ngl 99 -c 8192`; baseline is "Vulkan backend in LM Studio" (16.4), not a llama.cpp Vulkan run | [S24] |
| B580 12 GB, WSL2 (community, via Strata) | Strata Intel port (experimental) | Flash-Next IQ2_XS | ~21 (Coder ~15); device loss seen | not reported | local copy of Strata docs | [S9] |
| B70 32 GB (maintainer test machine) | Strata Intel port | Flash-Next IQ3_S, 11.5k of 24.6k experts resident | 30 (prose) – 41 (code) | 980–1,000 at 4K | same | [S9] |
| 2× B60 24 GB (community) | Strata Intel port | Flash-Next IQ2_XS, all experts in VRAM | 58.6–61.3 | 436 | same | [S9] |
| B70 32 GB (Level1Techs thread) | llama.cpp SYCL vs Vulkan | Qwen3.6-35B-A3B Q4_K_M 20.8 GiB, fully resident | SYCL 71.9 vs Vulkan 81.1 (llama-bench tg128) | SYCL 606.5 vs Vulkan 1,370.9 | the thread's own tables; poster's text says "70 … SYCL vs 45 … VULKAN" | [S28] |
| 2× B70 (tested on B70, not B580) | llama.cpp Vulkan, layer split | Qwen3.6-35B-A3B 19.7 GB · 64K | ~39 short chats; 15–19 long documents | not reported | author: "nobody has yet confirmed it on actual B580 cards" | [S25] |
| Arc B390 iGPU, 30 GiB unified | llama.cpp Vulkan | Qwen3.6-35B-A3B Q4_K_M 21.1 GiB · 32K | 32.5 (all on GPU) vs 14.7 (all experts on CPU) | 686 vs 293 | `--no-kv-offload`: 2.85 tok/s; `--batch-size 2048 --ubatch-size 2048` | [S26] |
| Arc B390 iGPU (Panther Lake) | llama.cpp Vulkan vs SYCL (llama-bench) | Qwen3.6-35B-A3B Q4_K_M 22 GiB | Vulkan 32.75 vs SYCL 30.62 | Vulkan 624.5 vs SYCL 609.4 | Vulkan ahead on this iGPU | [S27] |

Arc pitfalls, all from fetched reports:
- SYCL bad output: #28728 — `--n-cpu-moe 99`, `--batch-size 9000 --ubatch-size 9000`, Q5_K_XL, on a B580 [S29]. The local 02 note treats SYCL as "avoid" for Qwen3.6; that rule is too broad (see section 7).
- Vulkan on Intel ANV: flash-attention SCALAR fallback causes O(N²) prompt-processing degradation and device loss (B580, Ling-3.0-tiny) [S30].
- Vulkan PTQ1_0 kernel: device lost on prompts of ~1,900+ tokens on B580 (xe timeout) [S31].
- oneDNN: davetha's B580 output was wrong with `-DGGML_SYCL_DNN=ON`; "Building without oneDNN gives correct output" [S21].
- xe driver: an allocation past VRAM pushes buffers to RAM until the box stalls; leave ~1.5 GB free [S9]. "The fit estimator is not a fit test" [S21].

## 5. Top 10 tricks, roughly ordered by reported gain, with Arc transfer

Arc column: ✅ measured on SYCL or Vulkan; ◐ code is backend-generic but not measured on Arc; ❌ CUDA-only or not available on Arc.

1. **Hot-expert VRAM cache.** llama.cpp PR #29887 (merged; `--moe-cache-mib N`): Flash-Next Q4_0, RTX 4090 1.62× (40.7 tok/s), RTX 5090 2.20× (67.8, 89% hit rate) [S7]. Fork on a 3060 12 GB, Qwen3.6: 42.3 → 51.3 tok/s (+21%); +66% with MTP; +78% with async CPU splits [S8]. ◐ The local tip has the flag; code selects devices by type `GPU`/`IGPU` and has no CUDA-specific calls [S33]. Not measured on Arc.
2. **Keep experts on the GPU when they fit.** Arc B390 iGPU: 14.7 → 32.5 tok/s when no expert is left on CPU [S26]. ✅ on UMA; a discrete card only gains this when the model fits.
3. **Sweep `--n-cpu-moe` to the cliff, not `--cpu-moe`.** RTX 5070 Ti: 51.2 → 78.7 tok/s (+54%) [S19]. RTX 3060: all experts on CPU (`-ncmoe 40`) 28.1 → `-ncmoe 24` 38.9 (+38%) [S14]. The cliff is noisy: on a 3060, ncmoe 27 gave 31.8, 26 gave 33.6, 28 gave 10.4 [S15]. ✅ (B580 at 98K landed on 14 [S22]).
4. **MTP self-speculation** (`--spec-type draft-mtp --spec-draft-n-max 2–3`). Strix Halo APU: 25.5–26.2 → 32.9–33.1 greedy (+27%, 64% acceptance) [S12]. 3060 12 GB: 62 → 75 avg (+21%) [S16]. B200: 83.2 → 138.8 greedy (1.67×) [S11]. B580: ~42 served vs 29.7 standalone (~+40%, not like-for-like) [S22]. Negative: an Arc B390 user found n=5 worse than n=2 (acceptance ~0.4) [S26]; default temperature costs 10–15% vs greedy [S12]; "no meaningful improvements" with heavy CPU offload [S5]. ✅ (runs on SYCL [S22]).
5. **Larger `-b`/`-ub` for prefill.** B580: 527 → 637 pp (`-b/-ub` 2048 → 4096, plus THP and boost) [S21]. B390: batch 512 → 2048 gave 130 → 144 tok/s at 30K [S26]. ✅ The opposite claim exists for CUDA/Windows: "`fa on` and large `-b 4096` batches are *negative* optimizations under VRAM offload" [S17].
6. **`--no-mmap` when experts live in RAM.** B580: 83 → 197 pp (2.4×) [S21]. The same flag appears in the B580 98K config [S22] and the 4070 SUPER config [S17]. ✅
7. **Tiered Strata cache** (VRAM hot experts, all experts pinned in RAM, SSD n-gram table, prompt-lookup). RTX 5070: 87–94 tok/s [S1][S2]. 48 tok/s on a 4070 with 32 GB (modified build) [S3]. ❌ on Arc for now: the Intel port is experimental and the best B580 number is ~21 tok/s under WSL2 [S9].
8. **Pinned host memory + expert prefetch.** `GGML_CUDA_REGISTER_HOST=1 GGML_SCHED_PREFETCH_EXPERTS=1` on a 3060 12 GB: prefill 1,143 → 1,880 tok/s (+64%) at `--n-cpu-moe 26` [S8]. ❌ CUDA-only (both env vars are CUDA paths in the fork README).
9. **Checkpoint reuse for Gated-DeltaNet hybrids.** Turn-2 re-prefill held at ~4K tokens: ~12× at 50K, ~24× at 100K context on a B580 [S21]. ◐ It ran in davetha's own build (oneDNN off); verify on mainline before relying on it.
10. **q4_0 KV for long prompts.** 45K-token prefill: 397 s → 85.5 s (4.6×) on CUDA/Windows [S17]. B580: q4_0 KV gave no tg gain (q4/q4 40.5 vs q8/q8 ~42 tok/s) and no structured-output corruption [S22]. ◐ Prefill effect on Arc not measured.

Also seen, lower confidence: ngram-mod lookup ("~6x on multi-turn coding" is a second-hand claim, dense 27B [S18]); THP plus CPU boost (part of 83 → 637 [S21]).

## 6. Which tricks carry over to Intel Arc

- **Carry over (llama.cpp generic, measured on SYCL or Vulkan):** `--n-cpu-moe` / `-ot exps=CPU`, `--no-mmap`, `-b`/`-ub` bumps, `--spec-type draft-mtp`, full GPU residency when it fits, host-side THP/boost.
- **Plausible, not measured on Arc:** `--moe-cache-mib` (trick 1), `--spec-type ngram-mod`, q4_0 KV for long-prompt prefill, checkpoint reuse (only in davetha's build).
- **CUDA-only, do not expect on Arc:** `GGML_CUDA_REGISTER_HOST`, `GGML_SCHED_PREFETCH_EXPERTS`, the fork's CUDA cache kernels, Strata's CUDA kernels (RTX 50 / sm_90+ cluster paths, per its docs [S2]), and every ik_llama.cpp figure in this file (all CUDA or ROCm).
- **Intel-specific:** build without oneDNN on B580 [S21]; don't overcommit VRAM on xe (keep ~1.5 GB free) [S9]; Vulkan's ANV long-prompt device loss [S30][S31].

## 7. Contradictions and traps

- Big batches: helpful on SYCL (B580 [S21]); called negative on CUDA/Windows [S17]. Measure on the target card.
- SYCL vs Vulkan on the same B70 thread: the poster's text says 70 vs 45 tok/s for SYCL vs Vulkan, but the llama-bench tables in the same thread show Vulkan 81.1 vs SYCL 71.9 [S28]. On the Panther Lake iGPU, Vulkan leads SYCL by ~7% decode [S27]. The "2.4×" B580 SYCL claim [S24] compares against LM Studio's Vulkan, not a llama.cpp Vulkan build.
- Strata's 94 tok/s is "writes answers" on engine 0.1.36 [S1]; the 87.3 at 1K on 0.1.26 [S2] is the same machine, older engine.
- A PR-number claim is wrong: one README says the build "includes PR #25545 3x CPU-offload speedup" [S18]. The PR page is titled "cuda : CUDA GGML_OP_LIGHTNING_INDEXER implementation" and has no offload content [S32]. Do not cite it for offload.
- The 48 tok/s and 110 tok/s figures are from modified or author-built stacks (S3, S20). Treat them as best-case numbers for those stacks, not as stock llama.cpp results.
- The MoE placement cliff is not monotonic (trick 3). Sweep in steps of 1–2 layers before trusting a setting.
- Model calculators (ossmodeldb: "~97 tokens/sec (modeled, ±37%)" for B580) are estimates, not measurements, and are excluded.
- The local 02 note marks stock SYCL "Avoid for now"; that row covers Flash-Next and 35B-A3B. #28728 (bad output) was Q5_K_XL with `--n-cpu-moe 99` and batch 9000 [S29]; a B580 SYCL run at IQ3_XXS, `--n-cpu-moe 14`, passed strict recall at 92K [S22]. Narrow the rule to that config.

## 8. Next local tests (when the B580 is free and the bench gate passes)

1. Check the build first. `llama.cpp-sycl-tip` (358a420ec) already has `--moe-cache-mib`, `--spec-type draft-mtp` and `ngram-mod` [S33]. Build without oneDNN [S21].
2. Qwen3.6-35B-A3B UD-IQ3_XXS at 98K (the S22 profile): sweep `--n-cpu-moe` 12–16, then add `--no-mmap`, `-b/-ub 2048` vs 4096, `--spec-type draft-mtp`, and `--moe-cache-mib` at ~10% of the expert size (the PR's own guidance [S7]). Record pp and tg in the format of research/10-test-matrix.md.
3. Flash-Next on SYCL: no community number above ~21 tok/s exists for B580. First run should be IQ2_XS or IQ3_XXS with the placement sweep, with the device-loss risk in mind [S9].

## 9. Sources

Read (fetched, full text or the sections quoted):
- [S1] Strata README — https://github.com/Niko1221/Strata — origin not stated
- [S2] Strata docs/DETAILS.md — https://github.com/Niko1221/Strata/blob/main/docs/DETAILS.md
- [S3] Strata bench, RTX 4070 IQ2_XS (2026-10-08) — https://github.com/Niko1221/Strata/blob/main/bench/results/2026-10-08-community-rtx4070-iq2-xs/README.md
- [S4] carteakey.dev, Flash-Next 12 GB — https://carteakey.dev/blog/local-inference/running-qwen3-8-flash-next-locally — origin not stated
- [S5] unsloth HF discussion #48 — https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/discussions/48
- [S6] ninfer-offload (EN/ZH README) — https://github.com/1872183316/ninfer-offload — non-US leads, origin not stated
- [S7] llama.cpp PR #29887 (merged; page dated 2026-10-07) — https://github.com/ggml-org/llama.cpp/pull/29887 — US project
- [S8] thecodacus/llama.cpp perf README — https://github.com/thecodacus/llama.cpp/blob/perf/README.md — fork
- [S9] Strata INTEL_ARC.md — local copy: /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/engines/strata/docs/INTEL_ARC.md
- [S10] oflight.co.jp, Strata/Flash-Next — https://oflight.co.jp/en/columns/strata-qwen3-8-flash-next-rtx-4090-local-2026 — Japanese publisher, English edition (non-US; "Oct 2026")
- [S11] unsloth Flash-Next MTP README — https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/blob/main/MTP/README.md
- [S12] bert7800 flash-next-windows-mtp — https://github.com/bert7800/flash-next-windows-mtp — Strix Halo APU
- [S13] YouTube, Strata on a 12 GB card (transcript) — https://youtube.com/watch?v=6WLBmP-tZ0Q — claims only; transcript line "Strata does about 900 on the same test" is the only number I checked
- [S14] insiderllm, RTX 3060 — https://insiderllm.com/guides/run-35b-model-rtx-3060-12gb — origin not stated
- [S15] llmlab, RTX 3060 MTP report — https://github.com/githabideri/llmlab/blob/main/reports/2026-06-30-qwen3.6-35b-a3b-mtp-single-3060.md
- [S16] tanhaien/qwen-moe-benchmark — https://github.com/tanhaien/qwen-moe-benchmark
- [S17] shiqikuangsan31, 4070 SUPER guide — https://github.com/shiqikuangsan31/Qwen3.6-35B-12GB-VRAM-Guide
- [S18] petermuidev, 5060 Ti benchmarks — https://github.com/petermuidev/qwen3.6-local-lm-benchmarks
- [S19] Reddit r/LocalLLaMA, 5070 Ti 79 t/s — https://reddit.com/r/LocalLLaMA/comments/1sor55y/rtx_5070_ti_9800x3d_running_qwen3635ba3b_at_79_ts — US platform, poster origin unknown
- [S20] Reddit r/LocalLLaMA, 4070 Super 110 t/s (ik) — https://www.reddit.com/r/LocalLLaMA/comments/1tjh7az/110_toks_with_12gb_vram_on_qwen36_35b_a3b_and_ik/
- [S21] davetha/llama-moe-hybrid-tuning (B580 SYCL) — https://github.com/davetha/llama-moe-hybrid-tuning
- [S22] Reddit r/LocalLLM, B580 98K — https://www.reddit.com/r/LocalLLM/comments/1uwn9ds/intel_arc_b580_12_gb_llamacpp_sycl_98kcontext/
- [S23] Discourse companion to S22 (config only, no speeds) — https://hub.bitwiki.org/t/intel-arc-b580-12-gb-llama-cpp-sycl-98k-context-qwen3-6-35b-a3b-coding-setup-quant-kv-sweep-and-reproducible-results/127523 — origin not verified; Discourse post dated Jul 14, 2026
- [S24] Medium (B580 SYCL, "2.4x") — https://medium.rebeauty-writing.com/tag/focus?action=show&id=5c3c357d3411 — mirror, author origin unknown
- [S25] AscalonSolutions, 2× Arc B70 split — https://github.com/AscalonSolutions/qwen3.6-35b-two-b580s
- [S26] grigio.org, Arc B390 iGPU — https://grigio.org/how-i-got-2-2x-more-tokens-per-second-from-llama-cpp-on-intel-arc/
- [S27] grigio.org, Panther Lake Vulkan vs SYCL — https://grigio.org/benchmarking-llama-cpp-backends-on-intel-panther-lake-vulkan-vs-sycl-vs-openvino-vs-cpu
- [S28] Level1Techs forum, B70 thread — https://forum.level1techs.com/t/thoughts-from-existing-b70-users/248928/27 — US forum
- [S29] llama.cpp issue #28728 — https://github.com/ggml-org/llama.cpp/issues/28728
- [S30] llama.cpp issue #27638 — https://github.com/ggml-org/llama.cpp/issues/27638
- [S31] PrismML PR #192 — https://github.com/PrismML-Eng/llama.cpp/pull/192
- [S32] llama.cpp PR #25545 (checked to refute a secondary attribution) — https://github.com/ggml-org/llama.cpp/pull/25545
- [S33] local tip source, llama.cpp-sycl-tip 358a420ec: `src/llama-moe-cache.cpp`, `common/arg.cpp`, `common/speculative.cpp`

Excluded, and why:
- Search snippets never fetched: prismix Ling-3.0 on B580 (114 tok/s), flowtivity Strata (53.2 tok/s), mad-lab TQ3 ("should achieve 20+ t/s", a projection), NVIDIA NVFP4 MTP discussion.
- Aggregators with no primary read: smeltcore and openclawdc (80.8 tok/s on a 4070; "51–53" on a 3060); kblip; lftw.
- Zhihu 2029188132206035598 (MTP-on-MoE sentence): the fetched text did not contain the sentence, so not cited.
- ossmodeldb B580 calculator (modeled, not measured).
- Strata bench runs on 2× Titan RTX, RTX 5090 and 2× MI50: not 12 GB class.

Non-US coverage: the only non-US sources with measured numbers I could read were [S6] (bilingual EN/ZH) and [S10] (Japanese publisher). My Zhihu queries and one German and one French query returned no measured 12 GB MoE numbers. I did not search Bilibili, V2EX, Linux.do, heise, c't or Golem individually. The one Zhihu article I fetched (a 3080 20 GB card write-up) did not contain the quoted MTP line.
