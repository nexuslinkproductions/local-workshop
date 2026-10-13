# Best open-weight MoE models for on-demand computer use (as of 2026-10-12)

Re-ranked after Marcel's clarification: a desktop utility that takes screenshots and returns mouse/keyboard tool calls. Vision required. Order of criteria: (1) vision via GGUF mmproj, (2) GUI grounding and computer-use evals plus tool-call reliability, (3) long context, (4) speed. Coding is low priority.

Box and rules: Intel Arc B580 12 GB (about 9.5 GiB usable VRAM), Ryzen 9 7900X, 64 GB RAM (45 GiB budget). Stock llama.cpp master 358a420ec (2026-10-12). The local clone at `LOCAL-AI-LAB/llm/llama.cpp` is a97cce86a (2026-09-27), two weeks behind, so rebuild before testing. Quants >= 3 bpw, standard ggml types only. Fit rule: resident weights + mmproj + KV + compute <= 54 GiB (45 RAM + 9 VRAM). GB = 10^9 bytes (HF tree API), GiB = 2^30.

Abbreviations: SP = ScreenSpot-Pro. SS-v2 = ScreenSpot-v2. OSW-V = OSWorld-Verified (agentic). OSW-G = OSWorld-G (grounding only; not comparable to OSW-V). AW = AndroidWorld. "vendor" = numbers from the model's own card or paper.

## Bottom line

- **Flash-Next is confirmed as Marcel's qwen3.8-flash card.** Qwen/Qwen3.8-Flash-Next README: "Causal Language Model with Vision Encoder", 125B total, 6B active, 51B n-gram embedding, 4B MTP. Its vendor table lists AndroidWorld 84.5 in the Flash-Next column. I did not check that the hosted API serves the same checkpoint.
- **Its vision tower ships and loads, but its Vulkan image path is reported broken** (issue #29093, open). Not reproduced by a maintainer.
- **Recommendation: Qwen3.5-35B-A3B Q8_0 + mmproj-F16** (section 5). It is the only open MoE here at 3B active with published GUI and tool numbers, and it has no open Vulkan vision bug on record.
- **All GUI and tool-call scores are vendor-reported.** No independent run found. The OSWorld leaderboard (os-world.github.io) and the ScreenSpot-Pro leaderboard (gui-agent.github.io/grounding-leaderboard) list none of these models. The BFCL data URLs returned 404.

## 1. Ranking (computer-use criteria)

1. **Qwen3.5-35B-A3B** (qwen35moe, 3B active / 34.7B, Apache-2.0). Vendor, from the Qwen3.5-122B-A10B card table (6th column, Qwen3.5-35B-A3B): SP 68.6, OSW-V 54.5, AW 71.1, BFCL-V4 67.3, TAU2 81.2. Stock vision (mmproj qwen3vl_merger, 857.6 MiB). 262,144 native context. Caveat: 30 of 40 layers are Gated DeltaNet, so prompt processing may degrade on Intel Vulkan (#27638).
2. **UI-Venus-1.5-30B-A3B** (qwen3vl_moe, 3B active, Apache-2.0; inclusionAI, China). GUI specialist, vendor README: SP 69.6, AW 77.6, OSW-G 70.6. Full attention (no DeltaNet layers), so the #27638 path does not apply. No tool-call numbers published. KV is heavy at 96 KiB/token.
3. **Qwen3.5-122B-A10B** (qwen35moe, 10B active, Apache-2.0). Vendor: BFCL-V4 72.2 (best published here), TAU2 79.5, SP 70.4, OSW-V 58.0, AW 66.4. Fits only as UD-IQ3_S (3.05 bpw). About 3x the per-token compute of the 3B models, and not better than #1 on GUI, so ranked below it.
4. **Qwen3.8-Flash-Next** (qwen4exp, 6B active, 262,144 native, Qwen community licence). Vendor: AW 84.5 (highest published here), OSWorld 2.0 19.4 binary / 52.3 partial, Toolathlon 73.5. No SP, BFCL or tau rows in its card. Vision on Vulkan reported broken (#29093), and MTP plus image aborts (#30307). Moves to #1 once an image test passes on Vulkan.
5. **Holo2-30B-A3B** (qwen3vl_moe, 3B active, cc-by-nc-4.0: non-commercial only; H Company, France). Vendor grounding table: SP 66.1, OSW-G 76.1, SS-v2 94.9. No AW or tool-call numbers.

Next tier: **Kimi-VL-A3B-Thinking-2506** (MIT, 16.4B / 3B active; SP 52.8, SS-v2 91.4, OSW-G 52.5; fastest fallback). Qwen3-VL-30B-A3B is superseded by #2 and #5, which share its architecture.

## 2. Flash-Next: Marcel's questions

- **Vision tower ships in open weights?** Yes. config vision_config: depth 27, hidden 1152, patch 16, spatial merge 2, out 2560. Safetensors index: 333 `model.visual.*` tensors out of 1658.
- **mmproj GGUF:** unsloth/Qwen3.8-Flash-Next-GGUF `mmproj-F16.gguf` 862 MiB (`mmproj-BF16.gguf` 866 MiB). AesSedai `mmproj-Qwen3.8-Flash-Next-Q8_0.gguf` 588 MiB. ISTA-DASLab `mmproj-Qwen3.8-Flash-Next-BF16.gguf` 866 MiB. GGUF header of the unsloth F16 and AesSedai F16 files: `clip.projector_type = qwen3vl_merger`, which master's `tools/mtmd/clip-impl.h` lists. So `--mmproj` loads.
- **Vision on Vulkan:** reported broken and still open. #29093 (updated 2026-10-07): the Vulkan build cannot see an image, while the reporter says CPU-only works. The reporter's bisect points to 41abbfd5 "qwen4exp: enable rms_norm + mul fusion" (#28896). Another user reports `-fa off` fixes it (2026-09-22). Maintainer 0cc4m could not reproduce (2026-10-07). #27886 (CUDA, vision "significantly worse" than the 27B) closed 2026-10-12; its follow-up PR #27941 merged 2026-09-01. Not tested here.
- **KV and attention layout (config.json, verified):**
  - 48 layers: 36 `linear_attention` (Gated DeltaNet) + 12 `full_attention` at layers 3, 7, 11, ..., 47.
  - Full-attention KV: 2 KV heads x head_dim 256 x (K+V) x 12 layers x 2 bytes = **24 KiB/token (f16)**. At 262,144 tokens: 6.0 GiB f16, 3.2 GiB q8_0, 1.7 GiB q4_0.
  - DSA-style indexer on the 12 full-attention layers (1 KV head x 128, `indexer_top_k`). llama-kv-cache.cpp handles it; its bytes are not measured (about +3 KiB/token f16, +0.75 GiB at 262K).
  - Recurrent state, fixed per sequence: 48 value heads x 128 x 128 f32 x 36 layers = about 0.11 GiB.
  - Native context: 262,144 (max_position_embeddings).
- **Full-context memory on this box (IQ3_XXS):** trunk 43.8 GiB + mmproj 0.84 + recurrent 0.11 + compute about 1 = 45.8 GiB before KV. With q8_0 KV at 262K (3.2 GiB): about 49 GiB. With f16 KV (6.0 GiB): about 52 GiB. Both are under the 54 GiB budget, but tight. The 26.8 GiB n-gram table is read lazily from SSD (`-lm mmap --lazy-mode on`).

## 3. Full table (vision-capable MoE; sizes from HF tree API)

| # | Model (repo) | Active / total | mmproj | GUI (vendor) | Tool (vendor) | Ctx / KV f16 per token | Files that fit (>= 3 bpw) | Licence |
|---|---|---|---|---|---|---|---|---|
| 1 | Qwen3.5-35B-A3B (unsloth/Qwen3.5-35B-A3B-GGUF) | 3B / 34.7B | mmproj-F16 857.6 MiB | SP 68.6, OSW-V 54.5, AW 71.1 | BFCL-V4 67.3, TAU2 81.2, TAU3 68.9 | 262,144 / 20 KiB | Q8_0 36.90 GB; UD-Q6_K_XL 32.07; Q6_K 28.85; UD-Q4_K_XL 22.24 | Apache-2.0 |
| 2 | UI-Venus-1.5-30B-A3B (mradermacher/UI-Venus-1.5-30B-A3B-GGUF; base inclusionAI) | 3B / 30.5B | mmproj-f16 1033 MiB | SP 69.6, AW 77.6, OSW-G 70.6 | not published | 262,144 / 96 KiB | Q8_0 32.48; Q6_K 25.1; Q5_K_M 21.7; Q4_K_M 18.6 | Apache-2.0 |
| 3 | Qwen3.5-122B-A10B (unsloth/Qwen3.5-122B-A10B-GGUF) | 10B / 122.1B | mmproj-F16 867 MiB | SP 70.4, OSW-V 58.0, AW 66.4 | BFCL-V4 72.2, TAU2 79.5 | 262,144 / 24 KiB | UD-IQ3_S 46.6 (3.05 bpw) | Apache-2.0 |
| 4 | Qwen3.8-Flash-Next (ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF, IQ3_XXS) | 6B / 125B + 51B n-gram | mmproj-F16 862 MiB (unsloth) | AW 84.5; OSWorld 2.0 19.4 bin / 52.3 partial | Toolathlon 73.5; no BFCL/TAU | 262,144 / 24 KiB + indexer | IQ3_XXS 47.04 trunk + 28.80 table (lazy) | Qwen community (base); ISTA repo tags Apache-2.0 |
| 5 | Holo2-30B-A3B (mradermacher/Holo2-30B-A3B-GGUF; base Hcompany) | 3B / 30.5B | mmproj-f16 1033 MiB | SP 66.1, OSW-G 76.1, SS-v2 94.9 | not published | 262,144 / 96 KiB | Q8_0 32.5; Q6_K 25.1; Q5_K_M 21.7; Q4_K_M 18.6 | CC-BY-NC-4.0 |
| 6 | Qwen3.6-35B-A3B (unsloth/Qwen3.6-35B-A3B-GGUF; queued UD-Q4_K_XL) | 3B / 34.7B | mmproj-F16 858 MiB | none in card | TAU3 67.2 (3.5: 68.9); Claw-Eval 50.0 | 262,144 / 20 KiB | UD-Q4_K_XL 22.4; Q8_0 36.9 | Apache-2.0 |
| 7 | Qwen3-VL-30B-A3B (Qwen/Qwen3-VL-30B-A3B-Instruct-GGUF; unsloth) | 3B / 30.5B | mmproj-F16 1033 MiB | none in README; H's run of Thinking: SP 49.9, OSW-G 65.8, SS-v2 91.8 | none | 262,144 / 96 KiB | not sized here | not checked |
| 8 | Kimi-VL-A3B-Thinking-2506 (mradermacher/Kimi-VL-A3B-Thinking-2506-GGUF) | 3B / 16.4B | Instruct repo mmproj-f16 863 MiB (Thinking repo not checked) | SP 52.8, SS-v2 91.4, OSW-G 52.5 (bold column of card table; presumed this model) | none | not checked | not sized here | MIT |
| 9 | GLM-4.6V (unsloth/GLM-4.6V-GGUF) | ~12B (per name) / 106.9B | mmproj-F16 1640 MiB | none in README | none in README | 131,072 / 184 KiB | UD-IQ3_XXS 49.7; UD-Q3_K_XL 52.7 | not checked |
| 10 | MiniCPM-V-4.7-35B-A3B (openbmb/MiniCPM-V-4.7-35B-A3B-gguf, 2026-10-06) | 3B (per name) / 35.2B | mmproj-model-f16 1068 MiB | none in README | none | 262,144 / ~20 KiB | Q8_0 36.9; Q4_K_M 21.2 | not checked |
| 11 | Mistral-Small-4-119B-2603 (bartowski/mistralai_Mistral-Small-4-119B-2603-GGUF) | not checked / 119B | mmproj-f16 817 MiB | not checked | not checked | 1,048,576 (GGUF meta) | IQ3_XXS 49.9 (3.35 bpw) | Apache-2.0 |
| 12 | Gemma-4-26B-A4B-it (unsloth/gemma-4-26B-A4B-it-GGUF) | 4B / 25.2B | mmproj-F16 1138 MiB | not checked | not checked | 262,144 | UD-IQ3_S 11.3 (3.58 bpw) | Apache-2.0 |

- **Text-only (repo tree has no mmproj; verified):** Nemotron-3-Super-120B-A12B (unsloth, UD-IQ3_S 56.6 GB), Nemotron-3.5-Lightning-30B-A3B (unsloth), Laguna-S-2.1 (poolside, 117.6B), Qwen3-Coder-Next (unsloth, 79.7B), Ling-3.0-flash (bloomer010, 127.5B).
- **Over budget at >= 3 bpw:** GLM-5.3-Flash (320.8B), MiniMax-M2.7 (228.7B), Step-3.7-Flash (197.0B), DeepSeek-V4-Flash (284B per the Flash-Next card), Qwen3.5-397B-A17B, Qwen3-VL-235B-A22B, Holo2-235B-A22B, gpt-oss-120b (MXFP4 63.4 GB, text).
- **Not on stock master** (arch absent from master `src/llama-arch.cpp`): sarvam_moe (Sarvam-30B), minimax_h3, longcat-flash, solar-open2, deepseek41, bailingmoe2.5, gptoss.
- Community REAP and abliterated prunes are not ranked: they are not the released model.

## 4. Engine facts for this box (master 358a420ec)

- **Vulkan only.** SYCL gives bad output on Qwen3.6-35B-A3B (#28728, open). Avoid SYCL for these models.
- **Gated DeltaNet on Intel ANV Vulkan:** prompt processing collapses near-quadratically with context, with device loss (#27638, open, updated 2026-10-12). Hits Qwen3.5, Qwen3.6 and Flash-Next. The full-attention Qwen3-VL family (Holo2, UI-Venus) is not affected. Measure PP at 32K before trusting any DeltaNet model.
- **Intel Vulkan recurrent-state test is flaky** (#30199, open 2026-10-09). A correctness signal for DeltaNet on Intel Vulkan.
- **No MoE expert GPU cache in master.** PR #30059 still open; refactor #29943 merged 2026-10-06.
- **Qwen3-VL-family mtmd embeddings differ from HF** (#29251, open). Expect slightly lower grounding accuracy than the HF-run numbers.
- **`--no-mmproj-offload` exists** in master `common/arg.cpp` and keeps the projector on CPU. A workaround to try if images are ignored; not tested here.

## 5. Recommendation: one lane, exact files

- **Model:** unsloth/Qwen3.5-35B-A3B-GGUF, file `Qwen3.5-35B-A3B-Q8_0.gguf` (36.90 GB = 34.4 GiB; 733 tensors: Q8_0 432, F32 301, all standard; checked from the GGUF header).
- **Projector:** `mmproj-F16.gguf` (857.6 MiB; `clip.projector_type = qwen3vl_merger`; image_size 768).
- **Memory:** 34.4 GiB weights + 0.84 projector + KV 2.5 GiB at `-c 131072` f16 (5.0 GiB at 262K) + compute: about 39 GiB. Fits the 54 GiB budget.
- **Test command (flags not yet run):** `llama-server -m Qwen3.5-35B-A3B-Q8_0.gguf --mmproj mmproj-F16.gguf --device Vulkan0 -ngl 99 -c 131072 -fa on -np 1 --jinja --alias qwen35-gui`. Probe one screenshot before wiring. If images are ignored, retry with `-fa off` (the reported #29093 workaround) and `--no-mmproj-offload`.
- **If decode is too slow:** `Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf` (22.24 GB, 5.13 bpw), same mmproj.
- **Second lane for grounding-heavy steps:** mradermacher/UI-Venus-1.5-30B-A3B-GGUF, `UI-Venus-1.5-30B-A3B.Q8_0.gguf` (32.48 GB; header census Q8_0 338, F32 241) + `UI-Venus-1.5-30B-A3B.mmproj-f16.gguf` (1033 MiB). No DeltaNet, so no #27638 exposure.
- **Queued Qwen3.6 UD-Q4_K_XL:** keep it if you want 3.6. Its card has no GUI rows, and its TAU3 is 67.2 against 68.9 for 3.5 in the same table.
- **Upgrade path:** Flash-Next IQ3_XXS from ISTA (`IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf` 47.04 GB + `-00002-of-00002.gguf` 28.80 GB, plus `mmproj-Qwen3.8-Flash-Next-BF16.gguf` 866 MiB). Switch once a Vulkan image test passes. Use q8_0 KV at 262K.

## 6. Not verified

- Every GUI and tool score is vendor-reported. Harnesses differ (Qwen, H Company, Ant), so SP values across rows are not like-for-like.
- Speed is not measured on this box. Tiers use active params only: 3B, 6B, 10B, 12B.
- Not checked: Gemma-4 and Mistral-Small-4 GUI rows; the Kimi-VL Thinking mmproj; MiniCPM-V-4.7 and Qwen3-VL licences; exact indexer KV bytes; any Vulkan image test on master.
- The #29093 bisect and the `-fa off` workaround are the reporters' claims, not mine.

## 7. Sources read (2026-10-12)

- HF READMEs (raw): Qwen/Qwen3.8-Flash-Next (README, config.json, model.safetensors.index.json); Qwen/Qwen3.5-122B-A10B; Qwen/Qwen3.6-35B-A3B; Hcompany/Holo2-30B-A3B; inclusionAI/UI-Venus-1.5-30B-A3B; moonshotai/Kimi-VL-A3B-Thinking-2506; Qwen/Qwen3-VL-30B-A3B-Instruct; zai-org/GLM-4.6V; openbmb/MiniCPM-V-4.7-35B-A3B.
- HF trees and GGUF header range reads: ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF (IQ3_XXS shards); unsloth/Qwen3.8-Flash-Next-GGUF; AesSedai/Qwen3.8-Flash-Next-GGUF; unsloth/Qwen3.5-35B-A3B-GGUF; unsloth/Qwen3.6-35B-A3B-GGUF; unsloth/Qwen3.5-122B-A10B-GGUF; mradermacher/Holo2-30B-A3B-GGUF; mradermacher/UI-Venus-1.5-30B-A3B-GGUF; tree listings for section 3.
- llama.cpp raw at 358a420ec: `tools/mtmd/clip-impl.h`; `src/llama-kv-cache.cpp`; `src/models/qwen4exp.cpp`; `common/arg.cpp`; `ggml/include/ggml.h` (GGML_TYPE_Q2_0 = 42); `ggml/src/ggml-vulkan/vulkan-shaders/dequant_q2_0.comp`.
- GitHub (ggml-org/llama.cpp): issues #29093 (+3 comments), #30307, #27886, #28728, #27638, #30199, #29251, #30059, #29943, #27941, #29887. The GitHub API hit its rate limit during the run; states come from the API before the limit and from the issue pages after.
- Leaderboards: https://os-world.github.io/ and https://gui-agent.github.io/grounding-leaderboard/ (no entries for these models). BFCL data: 404 at the GitHub path and at the HF dataset path.
