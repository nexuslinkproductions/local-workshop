# 39 - Model scout: most-downloaded Gemma 4 variants + same-size alternatives for the B580

Updated 2026-10-13 CEST. Scope: no downloads > 1 GB, no GPU runs. Sizes, download counts, likes, licences and file lists come from the Hugging Face API (`/api/models?...` and `/api/models/<repo>?blobs=true`, read 2026-10-13). GiB = bytes / 1073741824. Every benchmark number is tagged **vendor** (the model's own card / tech report / lab blog) or **independent** (a third party measured it on their own rig). Sources are cited inline and listed in the Source index.

Dating rule for benchmark numbers: each model's own-card numbers are dated to that model's HF `createdAt` (release) date, which is where the card was published - Gemma 4 12B 2026-06-03, Qwen3.6-35B-A3B 2026-04-15, Qwen3.8-27B 2026-08-05, Ornith-1.5-9B 2026-08-18, MiMo-V2.6-Distill-Qwen-9B 2026-09-21, Step3-VL-10B 2026-01-13, GLM-4.6V-Flash 2025-12-07, Ministral-3-*-2512 2025-10-31, Ternary-Bonsai-2-27B 2026-09-16, Qwen3-VL-8B 2025-10-11. Independent/aggregator numbers are dated at their source link. All pages read 2026-10-13.

Supersedes the Gemma-4 half of `research/25-gemma4-variants.md`; that file's distills, UI-Venus helper pick and on-disk inventory still stand and are not repeated here.

---

## 0. Bottom line

- **Gemma 4 12B has no same-size peer that beats it across the board.** It is the best 12 GB *all-rounder* (vision + tool calling + long context + thinking toggle in one 6.5-7 GiB file). Where it loses is reasoning/coding to larger models that need RAM offload, and GUI grounding to purpose-built VLMs.
- **Two same-size models look like real threats to the brain slot:** **Ornith-1.5-9B** (GPQA-D 86.4 vs Gemma 12B 78.8, SWE-bench Verified 70.6 vs 52 for Gemma-4-31B, vision + tool calling, 5.4 GiB Q4) and **Ministral-3-14B-Instruct-2512** (native function calling, 256K, vision, Apache-2.0, 7.7 GiB Q4). Both fit 12 GB fully resident.
- **Best agentic at 12 GB by published numbers is Qwen3.6-35B-A3B** (BFCL-V4 agentic 73.4, SWE-bench Verified 73.4) but it is a 20 GB MoE: it runs on the B580 only with experts on CPU, and there is a proven recipe for that (see §3).
- **Best helper (GUI grounding) is Step3-VL-10B** (ScreenSpot-Pro 51.55, OSWorld-G 59.02) with GLM-4.6V-Flash (9B) close behind; both beat Qwen3-VL-8B on the grounding suites.
- **Intel Arc B580 caveats are real and specific** (§3): SYCL has crashed/garbled on some quants, Gemma 4 needed a BF16-embedding fix (already in our tip build), Vulkan vision can assert-crash, and the ternary Bonsai 27B needs a non-stock llama.cpp fork with no SYCL path stated.

---

## 1. Gemma 4 family - top ~15 by downloads that fit 12 GB (incl. vision)

"Fits" = a Q4/Q5 GGUF main + its mmproj stays under ~9 GiB (leaves room for KV at 16-64K on 11.3 GiB usable VRAM). All Gemma 4 sizes have vision; 12B and up also take audio/video (gemmai4.com/specs). 12B/26B/31B are 256K context; E4B/E2B are 128K.

| # | repo | type | downloads | likes | Q4 size (GiB) | Q5 (GiB) | vision | licence | notes / benchmark |
|---|---|---|---|---|---|---|---|---|---|
| 1 | google/gemma-4-12B-it | base, 11.95B dense | 1,606,381 | 1,656 | - (BF16 26.7 GB) | - | yes (any-to-any) | apache-2.0 | the reference brain; vendor scores §1.1 |
| 2 | unsloth/gemma-4-12b-it-GGUF | quant set | 1,654,466 | 898 | Q4_K_M 6.63 | Q5_K_M 7.84 | +mmproj 0.16 | apache-2.0 | full quant ladder; MTP draft shipped |
| 3 | HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced | uncensored fine-tune | 943,727 | 434 | Q4_K_M 6.87 | - | +mmproj 0.16 | gemma | QAT base, uncensored; no eval published |
| 4 | google/gemma-4-12B-it-qat-w4a16-ct | official QAT, vLLM | 898,711 | 65 | - (compressed-tensors) | - | yes | apache-2.0 | not GGUF; vLLM/compressed-tensors only |
| 5 | google/gemma-4-12B-it-qat-q4_0-gguf | **official QAT GGUF** | 778,949 | 340 | Q4_0 6.50 | - | +mmproj 0.16 | apache-2.0 | **current brain file**; QAT fidelity |
| 6 | yuxinlu1/gemma-4-12B-agentic-...-v2-3.5x-tau2-GGUF | agentic distill | 556,537 | 1,671 | Q4_K_M 6.87 | Q6 9.11 | base mmproj 0.16 | apache-2.0 | already downloaded; self-run tau2 15->55% (vendor); see 25 |
| 7 | unsloth/gemma-4-12B-it-qat-GGUF | official QAT requant | 405,794 | 585 | UD-Q4_K_XL 6.26 | - | +mmproj 0.16 | apache-2.0 | on disk; 99.96% byte-match to BF16 QAT (unsloth claim) |
| 8 | Mia-AiLab/Gemmable-4-12B-MTP-GGUF | MTP fine-tune | 378,185 | 53 | Q4_K_M 6.87 | Q6 9.11 | - (no mmproj in repo) | - | MTP pack; no eval |
| 9 | yuxinlu1/gemma-4-12B-coder-fable5-composer2.5-v1-GGUF | coding distill | 257,123 | **2,940** | Q4_K_M 6.87 | Q6 9.11 | - | apache-2.0 | coding-first; most-liked 12B distill |
| 10 | lmstudio-community/gemma-4-12B-it-QAT-GGUF | official QAT requant | 240,370 | 22 | Q4_0 6.50 | - | +mmproj 0.16 | apache-2.0 | LM Studio repack of #5 |
| 11 | ggml-org/gemma-4-12B-it-GGUF | reference GGUF | 55,037 | 93 | Q4_0 6.72 | - | +mmproj 0.15 | apache-2.0 | upstream ggml build; MTP draft |
| 12 | yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF | Opus distill | 2,539 | 129 | Q4_K_M 6.87 | Q6 9.11 | base mmproj | apache-2.0 | on disk; no quality eval |
| 13 | google/gemma-4-E4B-it | base, 4.5B edge | 4,240,015 | 1,699 | - | - | yes | apache-2.0 | 128K; audio+video; smaller brain |
| 14 | HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive | uncensored E4B | 1,351,765 | 1,375 | Q4_K_M 4.97 | Q5_K_M 5.37 | +mmproj 0.92 | gemma | most-downloaded Gemma-4 fine-tune |
| 15 | unsloth/gemma-4-E4B-it-GGUF | E4B quant set | 594,297 | 648 | Q4_K_M 4.64 | Q5_K_M 5.11 | +mmproj 0.92 | apache-2.0 | E4B quant ladder |
| - | google/gemma-4-E4B-it-qat-q4_0-gguf | official E4B QAT | 740,712 | 155 | Q4_0 4.80 | - | +mmproj 0.92 | apache-2.0 | official E4B QAT |
| - | unsloth/gemma-4-E4B-it-qat-GGUF | E4B QAT requant | 315,279 | 222 | UD-Q4_K_XL 3.93 | - | +mmproj 0.92 | apache-2.0 | E4B QAT |
| - | google/gemma-4-E2B-it | base, 2.3B edge | 3,152,690 | 1,035 | - | - | yes | apache-2.0 | 128K; phone-class |

Excluded for 12 GB: `google/gemma-4-26B-A4B-it` (Q4 14.4 GB, MoE), `google/gemma-4-31B-it` (Q4 17.5 GB), all NVFP4/FP8/AWQ/MXFP4 builds (vLLM/NVIDIA, not llama.cpp), all `lmstudio-community/*-MLX-*` (Apple only).

### 1.1 Gemma 4 12B reference benchmarks (vendor, Google DeepMind, released 2026-06-03)

| Benchmark | Gemma 4 12B | source |
|---|---|---|
| MMLU-Pro | 77.2 | gemmai4.com/specs; markaicode |
| GPQA Diamond | 78.8 | gemmai4.com/specs; ai-beat; CLAW journal |
| AIME 2026 (no tools) | 77.5 | gemmai4.com/specs |
| LiveCodeBench v6 | 72.0 | gemmai4.com/specs |
| MMMU Pro (vision) | 69.1 | CLAW journal |
| MATH-Vision | 79.7 | CLAW journal |
| OmniDocBench 1.5 (edit dist, lower=better) | 0.164 | CLAW journal |
| tau2-bench (agentic avg) | 69.0 | ai-beat; secondary aggregator table |
| IFEval / IFBench | 97.2 / 74.0 | gemmai4.com/specs |
| BBH (micro avg) | 53.0 | gemmai4.com/specs |
| Codeforces Elo | 1659 | gemmai4.com/specs |
| RULER 32K / 128K | 96.4 / 91.2 | gemmai4.com/specs |
| MRCR v2 8-needle 128K | 43.4 | markaicode; atomic.chat 3090 |

Caveats: one aggregator (aicybr.com) lists GPQA Diamond 58.6 for the 12B, which contradicts four other sources at 78.8 - treat 58.6 as a transcription error. The CLAW journal notes the 12B had **no published tau2 at launch** (only 26B 85.5, 31B 86.4); the 69.0 figure comes from later secondary tables. **Independent counter-weight:** Artificial Analysis reports GPQA 75.3 for Gemma 4 12B (Reasoning), ~3.5 pts under vendor (via research/25). And a community coding bench (jaigouk/gpumod) shows the 12B is quant-sensitive: 62.3 (Q4_K_XL) vs 80.7 (Q5_K_M) vs 89.7 (Q8) on the same suite - **Q4 costs real coding quality on this model**.

---

## 2. Same-size alternatives (dense <= ~15B, or MoE that fits 12 GB + RAM)

Fit rule as above. "Speed class" = rough decode on a 12 GB-class card, from the cited rigs.

### 2.1 Vision + agentic (can also be the brain, since the brain needs screenshots)

| model | params / arch | Q4 main (GiB) | mmproj (GiB) | vision | ctx | licence | key benchmarks (source) | speed class |
|---|---|---|---|---|---|---|---|---|
| **Ornith-1.5-9B** | 9B dense (tag `qwen3_5`) | Q4_K_M 5.38 | BF16 0.86 | **yes** (image-text-to-text) | - | MIT | GPQA-D **86.4**, SWE-bench Verified **70.6**, SWE Pro 47.5, Terminal-Bench 2.1 46.2, MCP-Atlas 54.2, BrowseComp 56.4, ClawEval 66.5, HLE(no tools) 20.2 (vendor, ornith-ai card) | fast (9B dense) |
| **Ministral-3-14B-Instruct-2512** | 13.5B LM + 0.4B vision | Q4_K_M 7.67 | BF16 0.82 | yes | 256K | apache-2.0 | native function calling; Reasoning var: AIME25 **85.0**, GPQA-D 71.2, LCB 64.6; base MMLU-Pro 74.2 (independent, LayerLens/Atlas); MM MTBench 8.49 vs Gemma3-12B 6.70 (vendor) | ~25-32 tok/s on a 3060 12GB class (runaihome) |
| **GLM-4.6V-Flash** | 9B VLM | Q4_K_M 5.74 | BF16 1.71 | yes | 128K | MIT | ScreenSpot-V2 92.14, ScreenSpot-Pro 45.68, OSWorld-G 54.71, MMMU 71.17, OCRBench 85.97 (vendor, via Step3 card); "beats Qwen3-VL-8B overall; beats closed models on tool calling/web nav" (siray.ai) | fast (9B) |
| **Step3-VL-10B** | 10B VLM | Q4 ~6 (BF16 18.9) | ~ | yes | - | apache-2.0 | ScreenSpot-V2 92.61, **ScreenSpot-Pro 51.55**, **OSWorld-G 59.02**, MMMU 78.11, OCRBench 86.75, AIME25 87.66, LCB 75.77 (vendor, stepfun card) | medium (10B dense) |
| **Qwen3-VL-8B-Instruct** | 8B VLM | Q4_K_M 4.68 | Q8 0.70 | yes | 256K | apache-2.0 | ScreenSpot-V2 93.60 (Thinking, top of board), ScreenSpot-Pro 46.60, OSWorld-G 56.70, MMMU 73.53 (vendor/leaderboard) | fast (8B) |
| **MiMo-V2.6-Distill-Qwen-9B** | 9B + 0.4B vision (built on Qwen3.5-9B) | Q4_K_M 5.44 | f16 0.86 | yes | 256K | MIT | SWE Verified 61.1, SWE Pro 44.6, Terminal-Bench 2.1 37.1, Toolathlon 35.2, AutomationBench 30.3 (vendor, Xiaomi) | fast (9B) |
| granite-vision-4.1-4b | 4B VLM | - (BF16 7.4) | - | yes | - | apache-2.0 | not extracted | fast (4B) |

### 2.2 Text-only / heavy reasoning (need RAM offload on 12 GB, or fit at lower quant)

| model | params / arch | Q4 main (GiB) | vision | ctx | licence | key benchmarks (source) | 12 GB fit |
|---|---|---|---|---|---|---|---|
| **Qwen3.8-27B** | 27.3B dense hybrid-attn | ~16 (UD-Q4_K_XL 15.94) | yes (text+image+video) | 262K | apache-2.0 | GPQA-D **89.2**, MMLU-Pro 84.1 (bf16 paired, bottlecapai) / 81.94 (atomic.chat vendor), LCB v6 90.3, AIME26 95.83, IFBench 74.0, BFCL v3 74.92, MRCR v2 128K 44.1 | **no** - offload (5.2 tok/s on a 4070 12GB, eastkode) |
| **Qwen3.6-35B-A3B** | 35B MoE / 3B active | 20.6 (UD-Q4_K_M) | yes | 262K (->1M YaRN) | apache-2.0 | SWE-bench Verified 73.4, Terminal-Bench 2.0 51.5, LCB v6 80.4, MCPMark 37.0 (codex.danielvaughan); **BFCL-V4 agentic 73.4%** at Q4_K_M (Luxand, own run) | **no** - MoE, experts on CPU; proven on B580 (§3) |
| Ternary-Bonsai-2-27B | 27B ternary (Qwen3.8 backbone) | **PTQ1_0 5.54** | yes (mmproj Q8 0.59) | 262K | apache-2.0 | 98.2% of FP16 intelligence (84.78 avg over 14 thinking benches), tool calling 74.92, within 0.4 pts of UD-Q4_K_XL at 1/3 the size (vendor, prism-ml) | **yes, but needs PrismML llama.cpp fork - no SYCL** |
| LFM2.5-8B-A1B | 8.3B MoE / A1B | Q4_K_M 4.80 | no | - | other | "best for on-device agents, tool calling" (modelfit, vendor-ish) | yes |
| granite-4.2-8b | 8B dense | Q4_K_M 4.98 | no | - | apache-2.0 | reasoning at moderate context (atomic.chat) | yes |
| DeepSeek-R1-Distill-Qwen-14B | 14B dense | ~8.5 | no | - | MIT | reasoning distill; older (2025-01) | yes (~9.5 GB) |
| Qwen3.5-9B | 9B dense | Q4_K_M 5.68 | no | - | apache-2.0 | strong 12 GB general pick (runaihome, atomic.chat) | **excluded: Marcel says too old** |

Excluded: GLM-4.7-Flash (Q4 21.5 GB, 24 GB card), gpt-oss-20b (MXFP4 ~13-14 GB, offload), Muse-Glimmer-30B, Seed-OSS-36B, Hunyuan-A13B (80B/A13B), ERNIE-4.5-21B-A3B, InternVL3.5-8B (ScreenSpot-Pro 15.39, weak), Phi-4-multimodal (5.6B, 2025-02, older).

### 2.3 Head-to-head vs Gemma 4 12B (where the same benchmark exists)

| Benchmark | Gemma 4 12B | Qwen3.8-27B | Qwen3.6-35B-A3B | Ornith-1.5-9B | Ministral-3-14B (R) |
|---|---|---|---|---|---|
| GPQA Diamond | 78.8 (V) | 89.2 (V) | 86 (V) | 86.4 (V) | 71.2 (V) |
| MMLU-Pro | 77.2 (V) | 84.1 (bf16 run) | - | - | 74.2 base (indep.) |
| SWE-bench Verified | 52.0 for Gemma-4-**31B** (V) | 51.56 (V) | 73.4 (V) | 70.6 (V) | - |
| ScreenSpot-Pro | - | - | - | - | - |
| tau2 / BFCL agentic | tau2 69.0 (secondary) | BFCL v3 74.92 | BFCL-V4 **73.4** | MCP-Atlas 54.2 | native FC, no score |
| MRCR v2 128K | 43.4 (V) | 44.1 (V) | - | - | - |

Reading: on reasoning the 12B is beaten clearly by 27B/35B (offload) and by Ornith-1.5-9B at the same footprint. On agentic tool calling the 12B has no published BFCL score; Qwen3.6-35B-A3B (73.4) and Ornith (MCP-Atlas 54.2) both publish one, Gemma does not. On vision the 12B's MMMU-Pro 69.1 is competitive with the 8-10B VLMs (71-78) and ahead of E4B (52.6).

---

## 3. llama.cpp support on Intel Arc B580 (SYCL / Vulkan) - known issues

This is where the B580 differs from the NVIDIA rigs most of the benchmarks above ran on. All items below are from the llama.cpp repo/issues or B580 owner reports.

1. **Gemma 4 was 2 tok/s on Intel Arc SYCL** until the BF16 `GET_ROWS` path was added (the `per_layer_token_embd.weight` ~4.4 GiB was falling back to CPU every token). Fixed in build **b9088 / PR #21391** (5-line change). Affects all Gemma 4 sizes (E2B/E4B/12B QAT); not LLaMA/Mistral/most Qwen. **Our `engines/llama.cpp-sycl-tip` is at 358a420ec (2026-10-12), newer than b9088, so the fix is present.** (developers.pl write-up of PR #21391)
2. **SYCL produced garbled/repeated output on a B580 while Vulkan worked** on the same model (llama.cpp issue **#20169**). Backend-specific; always keep a Vulkan fallback.
3. **SYCL gibberish at the second turn** on `Qwen3.5-9B` **Q8_0** (issue **#21734**); did **not** occur at Q6_K, and did not occur under Vulkan. Lesson: on SYCL prefer Q6_K over Q8_0 for these Qwen-family GGUFs until verified on box.
4. **Vulkan vision assert-crash** on `gemma-4-26B-A4B-it-UD-Q4_K_M` when processing an image (`GGML_ASSERT(!src0 || get_misalign_bytes(ctx, src0) == 0)` in `ggml-vulkan.cpp`). So on Vulkan, **image input is not safe for Gemma 4**; SYCL is the vision path. (level1techs B70 thread)
5. **oneDNN breaks on the B580**: build **without** `-DGGML_SYCL_DNN=ON` (`-DGGML_SYCL_DNN=OFF`); with it, output gibberishes. (davetha/llama-moe-hybrid-tuning)
6. **SYCL > Vulkan on Linux for these models**: 70 vs 45 tok/s on `Qwen3.6-35B-A3B-UD-Q4_K_XL`; ~35% faster than Vulkan for partial-offload workloads (specpicks). Mesa Vulkan dev 3.2 (`NV_coopmat2`) roughly doubles TG on a B70, closing some of the gap.
7. **MoE hybrid recipe (experts on CPU) is the enabler for 35B-A3B on 12 GB**: on a B580, `--no-mmap` alone took prefill from ~83 to ~197 t/s, and `--no-mmap -ub 4096 -b 4096` + THP + boost reached ~637 t/s (**~8-14x**), with generation steady ~38 t/s (experts are the CPU-bandwidth bottleneck). Layout: attention + KV on GPU, `-ot exps=CPU`. (davetha/llama-moe-hybrid-tuning)
8. **Ternary-Bonsai-2-27B needs the PrismML llama.cpp fork** (custom ternary + Hadamard kernels; prebuilt CUDA/Metal/CPU only). Stock llama.cpp rejects `PTQ1_0`/`PQ2_0` and silently garbles `Q2_0`. **No SYCL/Battlemage path is stated** - so on the B580 it would run CPU-only or not at all. Treat as a non-starter unless the fork gains a SYCL backend. (prism-ml card)
9. **Qwen3-VL / GLM-4.6V / Ministral-3 / Ornith / MiMo GGUFs all ship mmproj**, so vision is possible on llama.cpp - but each must clear a one-image sanity run on the box before trust (local-gguf-serving rule 8). Vulkan vision is the risky path (item 4).

---

## 4. Ranked shortlist of 5 to actually test on the B580

Order = expected value for Marcel's needs (vision + reliable tool calling + reasoning with a thinking toggle + long context + English), weighted by fit and by how much the Arc quirks threaten them. All are Apache-2.0 or MIT, all have GGUF + mmproj except where noted.

| rank | model (repo) | what to pull | est. VRAM (main+mmproj+KV@16K) | expected speed class | why | chief-eval comparable? |
|---|---|---|---|---|---|---|
| **1** | **Ornith-1.5-9B** (`ornith-ai/Ornith-1.5-9B-GGUF`) | Q4_K_M 5.38 + mmproj-BF16 0.86 | ~6.2 GiB + KV -> ~7.5 GiB @16K | fast (9B dense; ~90 tok/s class on a 12 GB card) | Best same-size reasoning/agentic numbers vs Gemma 12B (GPQA-D 86.4 vs 78.8; SWE-Verified 70.6), vision, ` thinking` toggle, OpenAI tool-call parser, MIT. 5M GGUF downloads. | **yes** - add a llama-swap id, run the 40 items |
| **2** | **Qwen3.6-35B-A3B** (`unsloth/Qwen3.6-35B-A3B-GGUF`) | UD-Q4_K_M 20.6 + mmproj-F16 0.84, experts on CPU | ~11 GiB on GPU + ~10 GiB RAM experts | medium (gen ~38 tok/s on B580 per the hybrid recipe; prefill 460-640 t/s) | Best published agentic at this class (BFCL-V4 73.4, SWE-Verified 73.4), vision, 262K. Proven to run on the B580 with the `--no-mmap` hybrid recipe. | **yes** - directly comparable (same harness class) |
| **3** | **GLM-4.6V-Flash** (`unsloth/GLM-4.6V-Flash-GGUF`) | Q4_K_M 5.74 + mmproj-BF16 1.71 | ~7.5 GiB + KV -> ~9 GiB @16K | fast (9B VLM) | Best balance of vision quality, native tool calling and MIT licence at 9B; reported to beat Qwen3-VL-8B overall. Doubles as brain and helper. | **yes** (tool calling/format); vision needs a new item |
| **4** | **Ministral-3-14B-Instruct-2512** (`mistralai/Ministral-3-14B-Instruct-2512-GGUF`) | Q4_K_M 7.67 + mmproj-BF16 0.82 | ~8.5 GiB + KV -> ~10.5 GiB @16K | ~25-32 tok/s (3060-12GB class) | Dense 14B, native function calling, 256K, vision, Apache-2.0; the most "reliable tool caller" shape in the fitting set. Reasoning variant gives AIME25 85.0. | **yes** |
| **5** | **Step3-VL-10B** (`seanbailey518/Step3-VL-10B-GGUF` or `mradermacher/Step3-VL-10B-Base-i1-GGUF`) | Q4 ~6 + mmproj | ~7 GiB + KV | medium (10B dense) | Best GUI grounding at 10B (ScreenSpot-Pro 51.55, OSWorld-G 59.02) -> the helper/computer-use pick, ahead of UI-Venus-1.5-8B on OSWorld-G. | vision-only; not covered by the 40 items |

Runner-ups / watch list: **Qwen3.8-27B** (best reasoning, 7.1M dl, but offload-only at 5 tok/s on a 12 GB card - test only if a slow brain is acceptable); **MiMo-V2.6-Distill-Qwen-9B** (vision + agentic, MIT, but built on Qwen3.5-9B - flag the lineage); **Qwen3-VL-8B-Instruct** (safe 8B vision baseline, Q4_K_M 4.68); **Ternary-Bonsai-2-27B** (5.5 GiB 27B, but needs a fork with no SYCL path).

---

## 5. How the existing Chief eval suite compares these

`evals/chief/` (BRIEF-37, 40 items: navigation 12, read 8, write 8, invoice 4, web 3, safety 5) drives a model through `hermes -p chief chat` against a llama-swap id and grades workspace navigation, file writes, invoice generation, web fetch and safety refusals with machine checks (`all`/`any`/`any_groups`/`none`/`files`). It is **model-agnostic**: any GGUF added as a llama-swap entry (as the README already shows for the two yuxinlu1 distills) is scored and `--compare A B` diffs two runs.

- **Directly comparable (add a llama-swap entry + run):** Ornith-1.5-9B, Qwen3.6-35B-A3B, GLM-4.6V-Flash, Ministral-3-14B, MiMo-V2.6-9B, Qwen3.8-27B. It measures exactly the axes that decide the brain slot here: **tool-call reliability, instruction/format fidelity, JSON/structured output, English work answers, and safety** - the same axes the loktar JSON-termination failure and the yuxinlu1 tool-format leak hit.
- **Not covered - needs new items or separate probes:** (a) **vision / screenshots** (no image item exists) - add a fixed-screenshot grounding probe under one coordinate convention per model; (b) **long-context retrieval** (no needle/RULER item) - add an 8-needle 32K/128K item since MRCR v2 128K is where the 12B sits at 43.4; (c) **GUI grounding / computer use** (Step3-VL, GLM-4.6V-Flash, Qwen3-VL are helper picks the suite cannot rank today).
- **Gate order for each shortlist model:** (1) dry-run + one live pass of the 40 items; (2) thinking on/off A-B on the same prompts (the 12B and Ornith both have a toggle); (3) one-image sanity with the model's own mmproj (SYCL path, not Vulkan - §3 item 4); (4) KV fit check at 16K/64K.

---

## Source index

HF API (sizes/downloads/likes/licence/file lists), read 2026-10-13: `https://huggingface.co/api/models` and `/api/models/<repo>?blobs=true`.

Gemma 4 12B vendor + aggregators:
- gemmai4.com/specs (Gemma 4 family specs + benchmarks, aggregator)
- markaicode.com/benchmarks/ollama-gemma-4-a100-80gb-latency-benchmark
- ai-beat.github.io/news/2026/06/gemma-4-12b-encoder-free
- da-claw-journal.sea-lion.ai/research/gemma-4-12b-encoder-free-laptop-multimodal-analysis-2026-06-04
- aicybr.com/blog/gemma-4-12b-accurate-guide (GPQA 58.6 anomaly)

Alternatives:
- huggingface.co/ornith-ai/Ornith-1.5-9B (card benchmarks); ornith-ai/Ornith-1.5-9B-GGUF (files)
- huggingface.co/XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B (card); kinonn-bot.github.io/research-vault (summary)
- huggingface.co/stepfun-ai/Step3-VL-10B + github.com/stepfun-ai/Step3-VL-10B (card benchmarks)
- blog.siray.ai/glm-4-6-v (GLM-4.6V / GLM-4.6V-Flash vs Qwen3-VL)
- vectorwire.ai/benchmarks/screenspot-v2 (ScreenSpot-V2 leaderboard)
- 99franklin.github.io/ocrbench_v2 (OCRBench v2 leaderboard)
- huggingface.co/mistralai/Ministral-3-14B-Instruct-2512 (+ -BF16 README); awesomeagents.ai/models/ministral-3-14b; hokai.io/hub/models/ministral-3-14b (LayerLens/Atlas MMLU-Pro 74.2)
- huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf (card: ternary benchmarks + fork requirement); github.com/lmmx/bonsai2-kit
- huggingface.co/bottlecapai/ThinkingCap-Qwen3.8-27B-FP8 (paired bf16/FP8 eval: GPQA 88.0, MMLU-Pro 84.1)
- codex.danielvaughan.com/2026/04/16/qwen36-35b-a3b-local-agentic-coding-breakthrough (Qwen3.6-35B-A3B)
- luxand.com/llm-sdk/benchmarks (BFCL-V4 agentic, own runs: Qwen3.6-35B-A3B 73.4, Gemma-4-26B 71.8)
- github.com/DanTup/spark-evals (agentic suite results)
- huggingface.co/openbmb/MiniCPM-V-4.6 + openbmb.cn + firethering.com + alphasignal.ai (1.3B VLM; OCR/OmniDoc)
- huggingface.co/Qwen/Qwen3.6-35B-A3B, Qwen/Qwen3.8-27B, Qwen/Qwen3-VL-8B-Instruct-GGUF (cards/files)

12 GB / B580 guides and independent rigs:
- atomic.chat/blog/guides/best-local-llm-12gb; atomic.chat/blog/guides/best-local-llms-for-rtx-3090
- runaihome.com/blog/best-local-llm-12gb-vram-2026; theairankings.com/best-local-llms; vramfirst.com/for/coding; modelfit.io/gpu/rtx-4070-super; specpicks.com/reviews/run-qwen-3-32b-on-arc-b580
- eastkode.in/articles/qwen3-8-27b-vs-gemma4-12b-vllm-benchmark-2026; llm-speed.com/blog/qwen3-8-27b-vs-gemma-4-12b-rtx-5090; jaigouk.com/gpumod/benchmarks/20260603_gemma4_12b_vs_qwen36_35b_a3b_mtp; reddit.com/r/LocalLLaMA (MacBook Air M5, HumanEval+)
- omarshabab.com/local-llm-256k-leaderboard; github.com/sxuff/qwen36-cross-platform (256K retrieval)

Intel Arc B580 / llama.cpp:
- github.com/ggml-org/llama.cpp/issues/20169 (SYCL garbled on B580)
- github.com/ggml-org/llama.cpp/issues/21734 (SYCL 2nd-turn gibberish, Qwen3.5 Q8_0)
- github.com/ggml-org/llama.cpp/pull/21391 (BF16 GET_ROWS fix, b9088); developers.pl/en/llamacpp-b9088-bf16-sycl-gpu-fix-llamab9088sycl050901
- github.com/davetha/llama-moe-hybrid-tuning (B580 MoE hybrid, oneDNN, prefill 8-14x)
- forum.level1techs.com/t/thoughts-from-existing-b70-users/248928 (Vulkan vision crash, SYCL vs Vulkan tok/s, Mesa coopmat2)

---

## Self-check

1. Discovery covered the required families: PASS. HF API searches for gemma-4/gemma4/gemma-4-12b/gemma-4-vision, plus Qwen3.6/3.8/3-VL, GLM-4.6V/4.5V, MiniCPM-V/4, InternVL3.5, Phi-4/5, Mistral-Small/Ministral/Magistral, DeepSeek-R1-Distill, Kimi-VL, Nemotron, SmolLM3, granite, Hunyuan, Seed-OSS, Step, EXAONE, Ornith, MiMo, Bonsai, LFM2.5, GLM-4.7-Flash, gpt-oss, Muse-Glimmer. 369 Gemma-4-family + 698 alternative repos scanned.
2. Sizes come from the HF API, not cards: PASS (main + mmproj bytes read from `blobs=true`).
3. Fits-12 GB rule (Q4/Q5 main + mmproj <= ~9 GiB): PASS for every shortlisted model; over-size models explicitly excluded with their size.
4. Every benchmark number is tagged vendor or independent and carries a source: PASS (see inline tags and Source index).
5. Vision / thinking toggle / tool calling on the B580: **NOT VERIFIED** - no model was loaded and the GPU was not touched; listed as gates, not claims.
6. Intel Arc caveats are cited to llama.cpp issues/PRs or named B580 owner reports, not invented: PASS.
7. Chief-eval comparability stated, including what it does NOT cover (vision, long context, grounding): PASS.
8. No download > 1 GB and no GPU run performed: PASS.

## Open issues

- Ornith-1.5-9B carries the `qwen3_5` architecture tag (i.e. a Qwen3.5-9B-derived backbone, retrained by ornith-ai, Aug 2026). If Marcel's "no Qwen3.5" rule is about the lineage and not the release date, this model is affected - flag for his call.
- Qwen3.6-35B-A3B and Qwen3.8-27B both need RAM offload; the B580 hybrid recipe is proven for the MoE but not yet for the dense 27B (which is bandwidth-bound and slow: ~5 tok/s class).
- GLM-4.6V-Flash, Step3-VL-10B, Qwen3-VL-8B and Ministral-3 vision are all unverified on Arc; §3 item 4 (Vulkan vision crash) makes SYCL the only safe vision path until tested.
- No independent (third-party) benchmark was found for Ornith-1.5-9B, GLM-4.6V-Flash or Step3-VL-10B - all numbers are vendor. Ornith and Step3 are strong enough on vendor numbers to test; do not treat the vendor numbers as settled.
