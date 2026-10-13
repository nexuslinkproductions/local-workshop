# Qwen3.8 Flash-Next and Qwen3.8-27B: files, engine support, fit on Arc B580 (12 GB) + 64 GB RAM

Date: 2026-10-12. Research only: no model downloaded or run. Sizes are exact byte counts from the Hugging Face tree API (GB = 10^9, GiB = 2^30). Box facts from `research/00-plan.md` and `llm/BUILD-REPORT.txt`. Source labels in brackets are listed in section 10.

## Bottom line

- **Flash-Next is supported in stock llama.cpp** (not yet run on this box). PR #27742 merged 2026-08-27 (merge `6c84c7d5`). The local stock build (`b11222`, `a97cce86a`) contains it. The video's "still a fork" claim is out of date.
- **Realistic Flash-Next files here:** ISTA-DASLab Q2_0 (66.4 GB total, 37.6 GB trunk) and IQ2_XS (68.0 GB, 39.2 GB trunk). IQ3_XXS fits only on the 45 GB budget. IQ3_S needs a nearly idle 64 GB box. Unsloth UD-Q3 and larger need SSD-streamed experts.
- **Speed on this card is unmeasured.** "50-62 tok/s on 12 GB + 64 GB" is Strata's RTX 5070 (CUDA) result. The only Arc B580 datapoint is Strata's community WSL2 run: IQ2_XS about 21 tok/s, Coder about 15 tok/s, with device loss.
- **Dense 27B:** ISTA IQ2_XS (8.42 GB / 7.84 GiB) is the one Qwen3.8-27B quant I expect to run fully in VRAM with usable context. ISTA IQ3_S (11.77 GB) does not.
- **Small MoE:** Qwen3.6-35B-A3B (unsloth) runs VRAM+RAM from UD-IQ2_XXS up to Q8_0. Other 13-20 GiB MoE GGUFs (empero, MiniCPM-V, Gemma-4) also run VRAM+RAM with `--n-cpu-moe`. No 35B-class file fits VRAM-only.
- **Two corrections to the brief:** (1) the 2026-09-27 build probe showed the B580 at 9,732 MiB free of 12,216 MiB, so plan on about 9.5 GiB. (2) 61 GiB usable minus 25 GiB used is 36 GiB, about 38.7 GB, not 45 GB. Both budgets are used below.

## 1. Video claims checked

| Claim | Verdict | Evidence |
|---|---|---|
| About 125B MoE, 6B active per token, 51B n-gram table, 4B MTP | Confirmed | [QWEN-FN] README, [QWEN-FN-CFG] |
| 4-bit files 94-124 GB | Roughly: unsloth UD-Q4_K_XL 111.3 GB, bartowski Q4_K_M 119.6 GB, ggml-org IQ4_NL 102.0 GB | tree APIs |
| 3-bit runs in Strata at 50-62 tok/s on 12 GB + 64 GB | Measured on RTX 5070 (CUDA), not Arc: IQ3_XXS 62, IQ3_S 53 tok/s (short chat) | [STRATA-MODELS] |
| 3-bit keeps 99.4% of the full model | ISTA's own eval (vendor-run): IQ3_XXS 92.57 vs BF16 93.12 task average | [ISTA-FN] |
| llama.cpp support "still in a fork", PR 27742 "not in mainline" (video dated 2026-09-02) | Outdated: merged 2026-08-27 | [PR27742] |
| 27B GSQ-RCO 11.8 GB "task-lossless"; KV 64 KB/token | Consistent: ISTA 27B IQ3_S 11.77 GB; 27B KV is 64 KiB/token (section 2) | [ISTA-27B], [QWEN-27B-CFG] |

## 2. Official model facts

| | Qwen3.8-Flash-Next | Qwen3.8-27B (dense) |
|---|---|---|
| Weights | [QWEN-FN] safetensors, 360.0 GB (335.3 GiB) BF16 | [QWEN-27B] safetensors, 27.78B params |
| Architecture (config.json) | `qwen4_exp`; 48 layers: 12 full-attention (QSA) + 36 Gated DeltaNet | `qwen3_5`; 64 layers: 16 full-attention + 48 linear-attention |
| Experts | 512 per layer; 10 routed + 1 shared; expert FFN 640 | dense FFN |
| Lookup table | 51B n-gram embedding (`per_layer_token_embd`), injected at layer 2 (official README) | none |
| Active params | 6B | 27B |
| KV per token, f16 (computed) | 24 KiB = 12 layers x 2 KV heads x 256 x (K+V) x 2 B | 64 KiB = 16 layers x 4 KV heads x 256 x (K+V) x 2 B |
| Native context | 262,144 (extensible to 1,000,000) | 262,144 |
| License | qwen-community-1.0 (`license: other`) | Apache-2.0 |
| Offload note | "more amenable to offloading than Mixture-of-Experts (MoE)" (README) | n/a |
| Official runtimes | Transformers, vLLM, SGLang, TokenSpeed (README; llama.cpp not mentioned) | n/a |

## 3. Engine support on this box

| Path | Flash-Next | Dense 27B (`qwen35`) | 35B-A3B (`qwen35moe`) | Status |
|---|---|---|---|---|
| Stock llama.cpp, Vulkan (`llm/llama.cpp`, b11222) | Yes: arch merged (#27742). Q2_0 Vulkan kernels present. Flags present: `-ncmoe`, `-ot`, `--fit`, `-lm mmap`, `--lazy-mode`. Vulkan loads the model where HIP livelocks (#29149). | Yes (arch present) | Yes (arch present) | Recommended. Not run here yet. |
| Stock llama.cpp, SYCL | Q2_0 convert/copy paths exist. Open: TP on SYCL (#28100), slow SYCL MTP (#27373) | Arch present | Bad output on B580 (#28728, open) | Avoid for now. |
| Strata 0.1.39+ (third-party, MIT, Intel SYCL port) | Runs the ISTA and Unsloth GGUFs. Experimental; build from source (oneAPI 2026.1.1 or Docker). | n/a | n/a | Only Arc datapoint (below). |
| vLLM, SGLang, NVFP4, MLX, exl3 | No path on this box | n/a | n/a | Excluded. |
| Forks (PrismML, TonyMFJ WinVulkan, apetersson shared-ngram, DominikBucko 3090 vLLM) | Custom loaders | n/a | n/a | Excluded. |

Details behind the stock row (checked in the local source):
- **Quant types:** `GGML_TYPE_Q2_0 = 42` is in the local `ggml.h`. ISTA and Unsloth files use only standard types, so they should load. Not run.
- **Expert offload:** the override regex is `\.ffn_(up|down|gate|gate_up)_(ch|)exps` (`common/common.h:1150`). It matches the fused `ffn_gate_up_exps` that qwen4exp builds, and the experts go through the standard `build_moe_ffn`. Code-level check only.
- **Lookup table:** `per_layer_token_embd` is created with `TENSOR_READ_LAZY` (`src/models/qwen4exp.cpp:188`). `--lazy-mode on` reads its rows from disk on demand and requires mmap. ISTA's command is `-lm mmap --lazy-mode on`. ISTA's "plan for shard 1 in VRAM" assumes a much larger GPU than ours.
- **Arc datapoints** (Strata INTEL_ARC.md, community or maintainer-run): B580 12 GB, WSL2: IQ2_XS about 21 tok/s, Coder about 15 tok/s, "device loss also seen". Two B60 24 GB cards with all experts in VRAM: IQ2_XS 58.6-61.3 tok/s decode. B70 32 GB (maintainers): IQ3_S with 11.5k of 24.6k experts resident, 30-41 tok/s.

## 4. Flash-Next GGUF files: fit on 12 GB VRAM + RAM

**Fit rule.** Mainline splits experts by layer (`--n-cpu-moe`). I assume the GPU holds the dense trunk plus about 4 GB of experts, and the rest of the trunk sits in RAM. The lookup table (28.8 GB at IQ4_NL) stays on SSD and is read lazily. My estimate is **RAM ≈ trunk - 5 GB (±3)**. Strata's own rule (all experts in RAM, plus about 10 GB overhead) is stricter: Q2_0 44, IQ2_XS 45.5, IQ3_XXS 53, IQ3_S 60 GB.
- Budget A = 45 GB (from the brief). Budget B = 38.7 GB (61 GiB - 25 GiB).

| Source | Quant | File(s) | Total GB / GiB | Trunk GB | Est. RAM | Fits A / B | Stock b11222 (types/arch present, not run) |
|---|---|---|---|---|---|---|---|
| [ISTA](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF) | Q2_0 (2.40 bpw) | `Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-0000{1,2}-of-00002.gguf` | 66.42 / 61.86 | 37.62 | ~33 | yes / yes | Q2_0 type present |
| ISTA | IQ2_XS (2.50) | `IQ2_XS/…-IQ2_XS-0000{1,2}-of-00002.gguf` | 68.03 / 63.35 | 39.23 | ~34 | yes / yes (tight) | yes |
| ISTA | IQ3_XXS (3.00) | `IQ3_XXS/…-IQ3_XXS-0000{1,2}-of-00002.gguf` | 75.84 / 70.63 | 47.04 | ~42 | yes (tight) / no | yes |
| ISTA | IQ3_S (3.50) | `IQ3_S/…-IQ3_S-0000{1,2}-of-00002.gguf` | 83.62 / 77.88 | 54.82 | ~50 | no / no | yes |
| ISTA | Coder IQ1_M (256 of 512 experts; code-only) | 2 shards | 58.4 / 54.4 (ISTA text) | 29.6 (Strata) | ~25 | yes / yes | yes |
| [UkisAI Swift-1.5](https://huggingface.co/ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF) (fine-tune) | Q2_0 / IQ2_XS | `Swift-Qwen3.8-Flash-Next-GSQ-RCO-{Q2_0,IQ2_XS}.gguf` | 66.55 / 61.98; 68.15 / 63.47 | ~37.8; ~39.4 | ~33; ~34 | yes / yes | same types; own license |
| [REAP-320](https://huggingface.co/AnonimousA/Qwen3.8-Flash-Next-REAP-320-GGUF) (community prune to 320 experts) | UD-Q2_K_XL | `Q2/Qwen3.8-Flash-Next-UD-Q2_K_XL-reap320.gguf` (2 shards) | 61.49 / 57.27 | ~32.7 | ~28 | yes / yes | standard types (unverified) |
| REAP-320 | UD-Q3_K_XL | `Qwen3.8-Flash-Next-UD-Q3_K_XL-reap320.gguf` (2 shards) | 68.96 / 64.22 | ~40.2 | ~35 | yes / tight | standard types (unverified) |
| [Unsloth](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF) | UD-IQ1_S | `UD-IQ1_S/…` (3 shards) | 72.55 / 67.56 | ~43.8 | ~39 | yes (tight) / no | yes |
| Unsloth | UD-IQ1_M | `UD-IQ1_M/…` (3 shards) | 74.54 / 69.42 | ~45.7 | ~41 | yes (tight) / no | yes |
| Unsloth | UD-Q2_K_XL | `UD-Q2_K_XL/…` (3 shards) | 78.87 / 73.45 | ~50.1 | ~45 | no / no | yes |
| Unsloth | UD-IQ3_XXS | `UD-IQ3_XXS/…` (3 shards) | 81.96 / 76.33 | ~53.2 | ~48 | no / no | yes |
| Unsloth | UD-IQ4_XS | `UD-IQ4_XS/…` (3 shards) | 93.68 / 87.25 | 64.88 | ~60 | no (SSD streaming) | yes |
| Unsloth | UD-Q3_K_XL | `UD-Q3_K_XL/…` (3 shards) | 89.99 / 83.81 | ~61.2 | ~56 | no | yes |
| Unsloth | UD-Q4_K_XL | `UD-Q4_K_XL/…` (4 shards) | 111.33 / 103.69 | ~82.5 | n/a | no (Strata: 7-8.5 tok/s on 64 GB + 12 GB NVIDIA) | yes |
| [Cyronius](https://huggingface.co/Cyronius/Qwen3.8-Flash-Next-131B-A6B-GGUF) (community; 2 of 16 n-gram heads kept) | Q3_K_XL | `qwen38-keep1-Q3KXL.gguf` | 64.79 / 60.34 | ~61.2 | ~56 | no | standard (unverified) |
| [bartowski](https://huggingface.co/bartowski/Qwen3.8-Flash-Next-GGUF) | IQ2_XS / Q2_K / Q4_K_M | `Qwen3.8-Flash-Next-<quant>/…` | 77.74 / 72.40; 80.93 / 75.37; 119.60 / 111.39 | n/a | n/a | no | yes |
| [ggml-org](https://huggingface.co/ggml-org/Qwen3.8-Flash-Next-GGUF) | IQ4_NL / Q8_0 | `…-IQ4_NL-0000{1,2}-of-00002.gguf`; `…-Q8_0-…` | 102.05 / 95.04; 162.62 / 151.46 | n/a | n/a | no | yes |

Notes:
- **Trunk** = everything except the n-gram table. The table is 28.80 GB at IQ4_NL: confirmed for ISTA. For Unsloth it is assumed from discussion #45 (Q4 shard 2, IQ4_NL, 28.8 GB) and checked two ways: UD-IQ4_XS minus 28.80 = 64.88 GB, matching apetersson's trunk of 60.43 GiB; UD-Q3_K_XL minus 28.80 = 61.2 GB, consistent with Cyronius keep1 (trunk + 6.4B-param table = 64.8 GB). Per-tensor table types for UD-IQ1_S/IQ1_M were not checked.
- Pruned repos (REAP, Cyronius) are community work. Quality claims are the authors'; not verified.
- **Not stock:** apetersson `…-BF16-Ngrams` (their card says stock llama.cpp does not resolve the shared table; search snippet only). pfeifferj `ngram-embeddings*.gguf` sidecars (29.5 GB Q4_0 / 103.7 GB BF16; loader unverified). TonyMFJ `--model-ple` (fork).
- Strata-labelled uploads are repacks (e.g. jimmy31chen RVN IQ3_S-merged, 88.88 GB, uncensored). I found no separate "Strata format".
- MTP drafts for speculative decoding: unsloth `MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf` 2.60 GiB; ggml-org `mtp-Qwen3.8-Flash-Next-Q4_0.gguf` 2.05 GiB. Vision projectors are 0.85-0.9 GiB.
- **Non-US pick:** ISTA-DASLab, Institute of Science and Technology Austria (per the video transcript). Apache-2.0.

## 5. Dense Qwen3.8-27B GGUF files: fit on about 9.5 GiB free VRAM

| Source | Quant | File | GB / GiB | Fits | Quality (vendor-run unless noted) |
|---|---|---|---|---|---|
| [ISTA-27B](https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF) (Apache-2.0) | IQ2_XS (2.50) | `Qwen3.8-27B-GSQ-RCO-IQ2_XS.gguf` | 8.42 / 7.84 | VRAM-only; ~1.2 GiB for KV: ~16K f16 or ~32K q8_0 KV (est.) | ZS 74.54 (100.3% of BF16 74.34); AIME25 96.67; LCB v6 76.57 |
| ISTA-27B | IQ2_S (2.75) | `…-IQ2_S.gguf` | 9.26 / 8.62 | VRAM-only, tight (~6K f16, est.) | ZS 75.70 (101.8%) |
| ISTA-27B | IQ3_XXS (3.00) | `…-IQ3_XXS.gguf` | 10.09 / 9.40 | no; partial offload, ~1-2 GiB in RAM | ZS 74.81 (100.6%) |
| ISTA-27B | IQ3_S (3.50) | `…-IQ3_S.gguf` | 11.77 / 10.96 | no; partial offload, ~2.5 GiB in RAM | ZS 74.47; AIME25 100; LCB 85.71 (ISTA: "task-lossless") |
| [Unsloth-27B](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) | UD-IQ2_XXS | `Qwen3.8-27B-UD-IQ2_XXS.gguf` | 7.27 / 6.77 | VRAM-only, ~2.2 GiB for KV (~32K f16, est.) | not checked |
| Unsloth-27B | UD-IQ3_XXS / UD-IQ3_S | `…-UD-IQ3_XXS.gguf` / `…-UD-IQ3_S.gguf` | 10.93 / 10.18; 12.04 / 11.21 | no (partial) | not checked |
| Unsloth-27B | UD-Q4_K_M | `Qwen3.8-27B-UD-Q4_K_M.gguf` | 16.46 / 15.33 | no | n/a |
| [byteshape](https://huggingface.co/byteshape/Qwen3.8-27B-GGUF) | IQ2_XXS 2.56 bpw | `Qwen3.8-27B-IQ2_XXS-2.56bpw.gguf` | 8.84 / 8.24 | VRAM-only, tight (~12K f16, est.) | not checked |
| [ggml-org-27B](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF) | Q4_K_M / Q8_0 | `Qwen3.8-27B-Q4_K_M.gguf` / `…-Q8_0.gguf` | 18.97 / 17.67; 28.60 / 26.63 | no | n/a |
| Local `models/llm/` | Ternary-Bonsai-2-27B PQ2_0 (PrismML) | `Ternary-Bonsai-2-27B-PQ2_0.gguf` | 7.21 / 6.71 | VRAM-only | 26 tok/s measured (LOCAL-AI-LAB README); prism fork |
| Local `models/llm/` | Qwen3.8-27B-OBLITERATED IQ4_XS | `Qwen3.8-27B-OBLITERATED-IQ4_XS.gguf` | 15.42 / 14.36 | no (40 of 65 layers on GPU) | ~7 tok/s measured |

- Official `Qwen/Qwen3.8-27B` has safetensors only. The official-org GGUF is `ggml-org/Qwen3.8-27B-GGUF`.
- Every ISTA quant has an `-mtp` variant (+0.35 GB) carrying the MTP head for `--spec-type draft-mtp`.
- Non-US pick: ISTA-27B (see section 4).

## 6. Small-MoE and other candidates (VRAM+RAM with `--n-cpu-moe`)

RAM estimate: file minus about 8.5 GiB (dense weights plus expert share on GPU). Estimate only.

| Model (source) | Quant | File | GB / GiB | Fits | Est. RAM | Stock b11222 (arch present, not run) |
|---|---|---|---|---|---|---|
| [Qwen3.6-35B-A3B](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF) (unsloth, 2026-04-16) | UD-IQ2_XXS | `Qwen3.6-35B-A3B-UD-IQ2_XXS.gguf` | 10.76 / 10.02 | VRAM+RAM (just over 9.5 GiB) | ~1.5 GiB | arch present (qwen35moe) |
| same | UD-IQ3_S | `…-UD-IQ3_S.gguf` | 13.68 / 12.74 | VRAM+RAM | ~4 GiB | yes |
| same | UD-Q4_K_M | `…-UD-Q4_K_M.gguf` | 22.13 / 20.61 | VRAM+RAM | ~12 GiB | yes |
| same | UD-Q5_K_M | `…-UD-Q5_K_M.gguf` | 26.46 / 24.64 | VRAM+RAM | ~16 GiB | yes |
| same | Q8_0 | `Qwen3.6-35B-A3B-Q8_0.gguf` | 36.90 / 34.37 | VRAM+RAM, fits A | ~26 GiB | yes |
| [empero-ai "Qwen3.8-35B-A3B-Distill"](https://huggingface.co/empero-ai/Qwen3.8-35B-A3B-Distill-GGUF) (community; upstream not stated) | IQ3_M / IQ4_XS / Q4_K_M | `Qwen3.8-35B-A3B-{IQ3_M,IQ4_XS,Q4_K_M}.gguf` | 16.34/15.22; 19.63/18.28; 21.71/20.22 | VRAM+RAM | ~7 / ~10 / ~12 GiB | unknown (arch not checked) |
| [MiniCPM-V-4.7-35B-A3B](https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-gguf) (OpenBMB, China; vision MoE, 2026-10-06) | mix_q3gud_im / Q4_K_M | `MiniCPM-V-4_7-35B-A3B-{mix_q3gud_im,Q4_K_M}.gguf` | 15.50/14.44; 21.17/19.71 | VRAM+RAM | ~6 / ~11 GiB | `minicpmv` arch present; 4.7 unverified |
| [Gemma-4-26B-A4B QAT](https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf) (Google) | Q4_0 | `gemma-4-26B_q4_0-it.gguf` | 14.44 / 13.45 | VRAM+RAM | ~5 GiB | `gemma4` arch present |
| [GLM-5.3-Flash](https://huggingface.co/unsloth/GLM-5.3-Flash-GGUF) (unsloth) | UD-IQ1_S | `UD-IQ1_S/…` (3 shards) | 93.09 / 86.69 | no (too big) | n/a | n/a |

- No official `Qwen/Qwen3.8-35B-A3B` repo: the HF API returned 401.
- MoE speeds are unknown on this box. Use Vulkan for Qwen3.6-35B-A3B (SYCL bad-output bug #28728).

## 7. Open upstream issues that touch this box

- **#27638** (open, updated 2026-10-12): on Intel ANV/Vulkan (B580 reported), prompt processing collapses near-quadratically with context in `GGML_OP_GATED_DELTA_NET` (KDA mode), with "device lost on Vulkan0". The reporter's model is Ling-3.0-tiny. Flash-Next has 36 GDN layers and may hit the same path: measure PP at 32K before trusting it.
- **#29093** (open): Vulkan qwen4exp image input broken. Skip the mmproj on Vulkan.
- **MTP:** #29811 (open) startup assert with `--spec-draft-model … --spec-type draft-mtp`; #30368 (open) draft-mtp fails with `--kv-unified` and `--parallel >1`; #30397 (open PR) image embeds for MTP. Use `-np 1` and no kv-unified.
- **#28160** (closed): `--lazy-mode auto` halved pp512 on Vulkan (AMD iGPU). Set `--lazy-mode on` explicitly. Whether b11222 includes the fix is not verified.
- **#29932** (open): PLE table CPU-pinned on the RPC path (50.7 GiB for Q8). Avoid RPC.
- **#28933** (open): host RSS grows during chat (DGX Spark). Watch RAM in long sessions.
- **Feature gap:** no GPU-resident expert cache in mainline (#29949, open; #30060, open). This is the main difference from Strata.
- **#28100** (open): Flash-Next tensor-parallel on SYCL.

## 8. Suggested first tests (proposal; none run)

1. Update the local clone first. `b11222` is from 2026-09-27; master has moved (#30368 and #30397 are from today).
2. Flash-Next Q2_0, stock Vulkan, pinned to the B580: `llama-server -m Q2_0/…-00001-of-00002.gguf --device Vulkan0 -ngl 99 --n-cpu-moe 44 -lm mmap --lazy-mode on -fa on -np 1 -c 16384 --cache-type-k q8_0 --cache-type-v q8_0`. Lower `--n-cpu-moe` until VRAM is full. Record RAM, VRAM, TTFT and decode at 4K and 32K.
3. Same with IQ2_XS, to compare quality against Q2_0 speed.
4. Dense 27B ISTA IQ2_XS fully in VRAM (`-ngl 99`, no mmproj) against the Bonsai baseline (26 tok/s).
5. Qwen3.6-35B-A3B UD-Q4_K_M with `--n-cpu-moe` for decode speed.

## 9. Not verified

- Nothing downloaded or run. Load behavior, B580 tok/s and RAM figures are estimates.
- Unsloth per-quant table types are assumed (section 4 notes).
- Community quant quality (REAP, Cyronius, empero, MiniCPM) not checked.
- Strata's Intel port not built or run.
- `--n-cpu-moe` on Flash-Next: the regex and tensor naming match in source, but no run.

## 10. Sources read

Video and secondary:
- [V1] Kai, "The End of VRAM-Bottlenecked LLMs: Qwen3.8-Flash-Next" (2026-09-02): https://youtu.be/MPrQA-M4Zn4 (web_extract)
- [V2] Kai, "Is 16GB All You Need for Serious Local LLM?" (2026-10-07): https://youtu.be/i9mRnbdDYxk (web_extract)
- [V0] Kai, "Every Ways to Get 128GB VRAM for Local AI at Full Context" (2026-10-10): local transcript `/home/nexuslink/.hermes/cache/web/www.youtube.com-d3f8066cf4.md`

Strata:
- [STRATA] https://github.com/Niko1221/Strata (web_extract)
- [STRATA-MODELS] https://raw.githubusercontent.com/Niko1221/Strata/main/docs/MODELS.md
- [STRATA-INTEL] https://raw.githubusercontent.com/Niko1221/Strata/main/docs/INTEL_ARC.md

Official Qwen:
- [QWEN-FN] https://huggingface.co/Qwen/Qwen3.8-Flash-Next (README raw; `/raw/main/config.json` as [QWEN-FN-CFG]; `https://huggingface.co/api/models/Qwen/Qwen3.8-Flash-Next`)
- [QWEN-27B] https://huggingface.co/Qwen/Qwen3.8-27B (`/raw/main/config.json` as [QWEN-27B-CFG]; `https://huggingface.co/api/models/Qwen/Qwen3.8-27B`)
- https://huggingface.co/api/models/Qwen/Qwen3.8-35B-A3B (401; no such repo)

GGUF and quant repos (tree API `https://huggingface.co/api/models/<repo>/tree/main?recursive=true` unless noted):
- [ISTA-FN] https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF (README raw read)
- [ISTA-27B] https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF (README raw read)
- [UNS-FN] https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF (README raw read)
- https://huggingface.co/unsloth/Qwen3.8-27B-GGUF ; https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF ; https://huggingface.co/unsloth/GLM-5.3-Flash-GGUF
- [BART-FN] https://huggingface.co/bartowski/Qwen3.8-Flash-Next-GGUF
- [GGML-FN] https://huggingface.co/ggml-org/Qwen3.8-Flash-Next-GGUF ; [GGML-27B] https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF
- [BYTE-27B] https://huggingface.co/byteshape/Qwen3.8-27B-GGUF
- [CYR-FN] https://huggingface.co/Cyronius/Qwen3.8-Flash-Next-131B-A6B-GGUF (tree; card text from search snippet only)
- [REAP-320] https://huggingface.co/AnonimousA/Qwen3.8-Flash-Next-REAP-320-GGUF (tree; card from search snippet only)
- https://huggingface.co/apetersson/Qwen3.8-Flash-Next-GGUF (tree; card from search snippet only)
- https://huggingface.co/pfeifferj/Qwen3.8-Flash-Next-GSQ-RCO-GGUF
- [SWIFT] https://huggingface.co/ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF
- https://huggingface.co/jimmy31chen/RVN-Qwen3.8-Flash-Next-Abliterated-Uncensored-IQ3_S-Strata
- [EMP-35B] https://huggingface.co/empero-ai/Qwen3.8-35B-A3B-Distill-GGUF (README raw read)
- [MINICPM] https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B-gguf
- [GEMMA4] https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf
- Discovery: https://huggingface.co/api/models?search=Flash-Next&limit=100 ; `…/api/models?filter=gguf&sort=downloads&direction=-1&search=Qwen3.8-27B` ; `…?search=A3B` ; `…?search=gemma-4`

GitHub (ggml-org/llama.cpp):
- [PR27742] https://github.com/ggml-org/llama.cpp/pull/27742 (API read; merged 2026-08-27)
- Issues and PRs read via API or search: https://github.com/ggml-org/llama.cpp/issues/27638 , /29932 , /29093 , /28728 , /29811 , /30368 , /30397 , /28699 , /29245 , /28933 , /28160 , /30060 , /29949 , /29963 , /28100 , /27373 , /29149 , /28355 , /30307 (titles and bodies to varying depth)

Local (LOCAL-AI-LAB):
- `llm/llama.cpp` (tag b11222, `a97cce86a`): `build/bin/libllama.so` strings; `src/models/qwen4exp.cpp:176-200`; `common/common.h:1150-1160`; `ggml/include/ggml.h:432`; `ggml/src/ggml-vulkan/vulkan-shaders/dequant_q2_0.comp`; `ggml/src/ggml-sycl/convert.cpp`
- `llm/BUILD-REPORT.txt` (B580 12,216 MiB, 9,732 MiB free)
- `README.md` (measured speeds), `research/00-plan.md`
- `models/llm/` file sizes (Bonsai PQ2_0 7,206,168,928 B; OBLITERATED IQ4_XS 15,420,450,080 B)
