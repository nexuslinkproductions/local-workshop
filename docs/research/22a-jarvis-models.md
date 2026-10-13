# 22a — Jarvis brain: model candidates on this box (brief question 1)

Date: 2026-10-13 (Europe/Vienna). Scope: question 1 of `BRIEF-22-jarvis.md` only. Owner: subagent 22a.
Method: HF API tree listings and config.json, GGUF header range reads, llama.cpp source at tip `358a420ec` (local clone `engines/llama.cpp-vulkan-tip`), GitHub issue/PR API, vendor cards, third-party German benchmark site, third-party tool-call bench.
Not done: no GPU, no model loads, no `bench/.gpu.lock` touched (per brief). **Every speed and VRAM number below is an estimate unless marked "measured on box".**

Units: GiB = 2^30 bytes, from the HF tree API. VRAM budget used throughout: ~9.5 GiB usable on the B580 (12 GB, also drives 3 monitors; see `12-best-moe-models.md` §header).

## 1. Bottom line

- **Pick: Gemma 4 12B "Unified" (dense 11.95 B, Apache-2.0) as the single resident brain**, Google's QAT Q4_0 GGUF (6.5 GiB) + its mmproj (0.16 GiB). It is the largest dense Gemma 4 that fits the 9.5 GiB VRAM budget with usable context, and it takes text + image + audio + video. Sources: §3, §4.
- **Gate before adopting it: a real-screenshot vision test on Vulkan.** llama.cpp master loads the 12B vision projector (`gemma4uv`), but the known image bugs (`<unused49>` output, F16 overflow) were closed as *stale*, and the fix PR was closed *unmerged*. Vision is unproven here. §5.
- **Gemma 4 E4B (4.6 GiB Q4_K_M, vision + audio) is the fallback** if the 12B fails the image gate or leaves too little VRAM headroom for the desktop. E4B vision works in llama.cpp (third-party report, §5).
- **Qwen3.6-35B-A3B stays as the heavy on-demand lane, not the always-on brain.** It is the only candidate measured on this box (decode 36–40 t/s, 10 s per screenshot, tool-call PASS), but it needs 20+ GB in RAM, which is what froze the desktop.
- **Ministral 3 14B (Mistral, France, Apache-2.0, vision)** is the European alternative to test. Its Q4_K_M does not fit VRAM with 8K+ context. German is untested by an independent source.
- **Rejected for the voice brain:** Gemma 4 31B dense (17 GiB, does not fit; ~3–4 t/s from RAM at best) and Gemma 4 26B-A4B (vision only, no audio, 13.6 GiB needs MoE expert offload, which crashed Arc Vulkan in #25777). Qwen3.5-9B fits, but its hybrid DeltaNet layers hit the open Intel-Vulkan prompt-processing collapse (#27638).
- **Speed is the open risk, not decode.** Speech needs ~4–5 tok/s. Prefill on an uncached multi-thousand-token prompt is what breaks voice latency, so prefix caching of the static prompt is mandatory. Measure prefill first (§7).

## 2. Requirements used (from brief Q1)

Hard gates, in order:
1. Fits the box: dense ≤ ~14 B fully in VRAM at Q4, or small-active MoE that does not force RAM-resident weights (desktop-never-freezes rule).
2. Vision on real screens, via a GGUF mmproj that **llama.cpp at tip 358a420ec loads and answers correctly**.
3. Native tool calling. Context ≥ 32K.
4. Licence permits personal + commercial use.

Scored (not gated): conversation quality, German, tool-call reliability, time-to-first-sentence, memory footprint.

## 3. Gemma 4 family: verified facts

| Size | Type / active | Context | Input modalities | Licence | Q4-class GGUF (file size) | Source |
|---|---|---|---|---|---|---|
| E2B | dense edge, 2.3 B effective (5.1 B with embeddings) | 128K | text, image, **audio**, video | Apache-2.0 | not sized here (not needed for the brain) | [E2B card](https://huggingface.co/google/gemma-4-E2B) |
| E4B | dense edge, 4.5 B effective (8 B w/ embeddings) | 128K | text, image, **audio**, video | Apache-2.0 | unsloth Q4_K_M 4.64 GiB; google QAT Q4_0 4.8 GiB; mmproj 0.92 GiB (Q8 0.52) | [E4B GGUF](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF), [google QAT](https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-gguf) |
| **12B Unified** | dense 11.95 B, encoder-free, 48 layers | 256K | text, image, **audio**, video | Apache-2.0 | google QAT Q4_0 6.5 GiB + mmproj 0.16 GiB; unsloth Q4_K_M 6.63 GiB | [12B card](https://huggingface.co/google/gemma-4-12B-it), [config](https://huggingface.co/google/gemma-4-12B-it/raw/main/config.json), [google QAT](https://huggingface.co/google/gemma-4-12B-it-qat-q4_0-gguf), [unsloth](https://huggingface.co/unsloth/gemma-4-12b-it-GGUF) |
| 26B-A4B | MoE, 25.2 B total / 3.8 B active, 30 layers | 256K | text, image (no audio) | Apache-2.0 | ggml-org Q4_0 13.61 GiB; mmproj Q8 0.75 / BF16 1.11 GiB | [26B card](https://huggingface.co/google/gemma-4-26B-A4B-it), [ggml-org](https://huggingface.co/ggml-org/gemma-4-26B-A4B-it-GGUF) |
| 31B | dense 30.7 B, 60 layers | 256K | text, image (no audio) | Apache-2.0 | unsloth Q4_K_M 17.07 GiB; Q3_K_M 13.72 GiB; mmproj 1.12 GiB | [E2B card table](https://huggingface.co/google/gemma-4-E2B), [unsloth](https://huggingface.co/unsloth/gemma-4-31B-it-GGUF) |

- Tech report (arXiv 2607.02770v2): 12B is "encoder-free", ingests raw image patches and audio waveforms through linear layers. https://arxiv.org/html/2607.02770v2
- Function calling: native in all sizes per third-party spec sheet https://gemmai4.com/specs (not the Google card) and in the 12B README ("Native support for structured tool use"). https://huggingface.co/google/gemma-4-12B-it
- Audio input: E2B, E4B and 12B only. The 26B and 31B accept no audio. Source: 26B card table (above).
- Release: E2B/E4B/26B/31B on 2026-04-02; 12B added 2026-06-03 (third-party date, https://llmwiki.hu/entities/gemma-4 ; the 12B card itself is dated June 2026).
- **Marcel's "Gemma 4 12B"** is this 12B Unified model. Its name in the HF repo is `google/gemma-4-12B-it` (not `gemma-4-12b`). The runtime he used for "good results" is unknown. Ask him.

12B architecture (config.json, verified): hidden 3840, 48 layers, 16 query heads, 8 KV heads, head_dim 256 (sliding) / global_head_dim 512, `attention_k_eq_v: true`, sliding window 1024, 5 sliding : 1 full attention (8 full layers), 262,144 max positions, vocab 262,144, final logit softcap 30.

## 4. Shortlist and evidence

### 4.1 Shortlist table

Ratings: ✅ good, ◐ partial or unverified, ❌ fails the gate. "Vendor" = model's own card. "Indep." = third party. The German column uses the DACH peerbench average (INCLUDE, GermEval, SB10K, ScaLA, MMLU-ProX, MMMLU, MuSR).

| # | Model | Fits VRAM at Q4 (est.) | Vision (mmproj in llama.cpp master) | Audio in | Tool calling | German (indep.) | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | **Gemma 4 12B Unified**, google QAT Q4_0 | ✅ 6.5 GiB + 0.16 mmproj; ctx ≤16K f16 KV (§4.5) | ◐ loads (`gemma4uv`); image output bugs reported, unfixed on master (§5) | ✅ (loads as `gemma4ua`, untested) | ✅ vendor 69.0 Tau2; indep. 14/14 text+tool (NobodyWho, Metal) | ✅ avg 72.7 (bf16, Google run 2026-06-11, #18/31); ≈ Qwen3.6-35B | **Primary, gated on image test** |
| 2 | Gemma 4 E4B, unsloth Q4_K_M | ✅ 4.64 GiB + 0.92 mmproj (≈5.6 total); big headroom | ✅ works (indep. report, NobodyWho; E2B/E4B image-decoding bug #28318 closed 2026-09-04, fix not read) | ✅ | ◐ indep. BFCL 65.3% (Ollama, small n=50/cat) | ◐ not found on the German board | **Fallback + vision/audio lane** |
| 3 | Qwen3.6-35B-A3B UD-Q4_K_XL (box daily driver) | ❌ MoE, needs RAM (`-ncmoe 32`); 22 GB file | ✅ measured on box (`qwen3vl_merger`) | ✗ | ✅ measured PASS on box; vendor TAU3 67.2 | ✅ avg 72.8 (fp8, Alibaba run) | Heavy on-demand lane only |
| 4 | Ministral 3 14B Instruct (Mistral, FR), Q4_K_M | ◐ 7.67 GiB weights; ≤8K ctx with f16 KV; IQ4_XS 6.9 GiB fits better | ◐ `pixtral` projector exists in master; untested here | ✗ | ✅ vendor: native function calling, JSON | ◐ German listed in languages; no independent score found | **Test as European alternative** |
| 5 | Qwen3.5-9B, unsloth Q4_K_M | ✅ 5.29 GiB + 0.86 mmproj | ✅ `qwen3vl_merger` (same as Qwen3.6) | ✗ | ◐ indep. BFCL 61.3% (Ollama) | ◐ not found | ❌ hybrid DeltaNet → #27638 Intel-Vulkan PP collapse risk |
| 6 | Gemma 4 26B-A4B, ggml-org Q4_0 | ❌ 13.6 GiB → MoE expert offload | ✅ `gemma4v` projector (header read) | ✗ (no audio) | ◐ indep. EDGE-KOPA pass@1 0.353 (vs Qwen3.5-27B 0.448) | ◐ avg 67.7 (provider run) | ❌ for voice (no audio, offload + Arc Vulkan crash class #25777) |
| 7 | Gemma 4 31B dense, unsloth Q4_K_M | ❌ 17.1 GiB; all weights per token from RAM | ✅ `gemma4v` projector (header read, 1.12 GiB) | ✗ | ✅ vendor Tau2 76.9 | ✅ avg 76.5 (bf16, #12/31) | ❌ too slow for voice (§4.6) |
| 8 | MiniCPM-V-4.7 / UI-Venus-1.5 / Holo2 | — | GUI/grounding specialists | — | — | — | Not a chat brain; keep as grounding lane (`10-test-matrix.md` §2.6) |

Deliberately not ranked: Qwen3-VL-30B-A3B, Kimi-VL-A3B, GLM-4.6V (not in brief; GLM-4.6V 107 B). Community prunes/abliterated variants (e.g. the uncensored Gemma-4 E4B in the CUA bench) — not the released model.

### 4.2 German

- **Gemma 4 12B** (bf16, Google run, 2026-06-11): avg 72.7 %, rank 18 of 31. GermEval 79.6, INCLUDE 69.1, MMLU-ProX 73.1, MuSR 81.6, SB10K 62.2, ScaLA 64.1. https://dach.peerbench.ai/models/google/gemma-4-12b-it (same data: https://german-llm-497016.web.app/models/google/gemma-4-12b-it)
- **Qwen3.6-35B-A3B** (fp8, Alibaba run 2026-06-09): avg 72.8 %, rank 17. MMLU-ProX 80.0, MMMLU 85.8, INCLUDE 68.3, GermEval 79.9, SB10K 58.4, ScaLA 64.2. https://dach.peerbench.ai/models/qwen/qwen3.6-35b-a3b
- **Gemma 4 26B-A4B** avg 67.7 (rank 24); **Gemma 4 31B** avg 76.5 (rank 12). https://dach.peerbench.ai/models/google/gemma-4-26b-a4b-it , https://dach.peerbench.ai/models/google/gemma-4-31b-it
- Read: the 12B is at parity with the Qwen3.6 35B on German (quant differs, bf16 vs fp8, and these are hosted-provider runs, not this box). It is weaker than Qwen on MMLU-ProX (73 vs 80) and about equal elsewhere.
- E4B and Ministral 3 14B: no independent German score found. Mark **unverified**. Test them on the same German prompts (§7).
- Vendor multilingual claim (12B card): "35+ languages, pre-trained on 140+". https://huggingface.co/google/gemma-4-12B-it

### 4.3 Vision on real screens

- Vendor (12B card, MMMU-Pro / OmniDocBench 1.5 edit distance, lower better): 12B 69.1 / 0.164; 26B-A4B 73.8 / 0.149; 31B 76.9 / 0.131; E4B 52.6 / 0.181; Gemma 3 27B 49.7 / 0.365. https://huggingface.co/google/gemma-4-12B-it . Vendor numbers only; no independent screen-grounding score for any Gemma 4 model was found.
- Input budget: Gemma 4 uses **70 / 140 / 280 (default) / 560 / 1120 image tokens per image**. The Qwen3.6 screenshot on this box was ≈2060 tokens at 1920×1080 (measured). A Gemma image at 280 tokens is ~7× fewer prefill tokens. Good for "what am I looking at"; likely too coarse for pointing at 26 px UI text (§4.3 of `10-test-matrix.md`: Qwen 0/4 real desktop, UI-Venus 2/4). Gemma is a describe/answer lane, not a click-grounding lane. Keep UI-Venus for grounding.
- MiniCPM-V-4.7 is out for grounding (6/16 synthetic, 0/4 real, measured on box).

### 4.4 Tool calling

- Gemma 4 12B: vendor Tau2 (avg of 3) 69.0 (26B-A4B 68.2, 31B 76.9, E4B 42.2). Source: 12B card. Tau2 is a retail/airline agent benchmark, vendor-run.
- Independent, small: NobodyWho (June 2026, macOS M4): Gemma 4 12B text+tool 14/14 (Q8_0 and Q4_K_M), E2B/E4B 14/14. Note: not Vulkan, not llama-server. https://github.com/nobodywho-ooo/nobodywho/issues/578
- Independent, BFCL (50 per category, Ollama): E4B 65.3 %, Gemma 3 12B 62.0 %, Qwen3.5-9B Q4_K_M 61–64 %, Bonsai-8B 73.3 %. Small n, format-only scoring. https://huggingface.co/Manojb/small-llm-tool-use-bench
- Independent, EDGE-KOPA (arXiv 2609.05395, live Korean APIs, multi-step): gemma-4-26B-A4B pass@1 0.353, Qwen3.5-27B 0.448, Qwen3.5-9B 0.328. The 12B was not in that run. https://github.com/dneirfi/EDGE-KOPA
- Read: tool calling is adequate on the 12B; reliability on multi-step tasks is not independently measured. Test it on Hermes' own tool schema (§7), not a generic bench.

### 4.5 Memory footprint (estimates, not measured)

Gemma 4 12B, google QAT Q4_0 + mmproj F16 (0.16 GiB):
- Weights 6.5 GiB; mmproj 0.16 GiB.
- Sliding-window KV (40 layers × 1024 window × 8 KV heads × head_dim 256 × K+V × f16 = 8 KiB/token/layer): ~0.32 GiB fixed.
- Global KV (8 full-attention layers, 8 KV heads × head_dim 512): 64 KiB/token if `attention_k_eq_v` stores K once, 128 KiB/token if V is stored separately. This is the open question. It is not confirmed from llama.cpp's allocator here.
- Context 16K: 1.0–2.0 GiB → total ~8.0–9.0 GiB before compute buffers. **At the 9.5 GiB budget this is the ceiling with f16 KV.**
- Context 32K: 2.0–4.0 GiB f16 → over budget. Needs `-ctk q8_0 -ctv q8_0` (halves the global part, est. 1.0–2.0 GiB) to fit.
- Context 256K (native): impossible in VRAM. Plan for 16K–32K context, with a rolling memory summary outside the model.

Other candidates, same method:
- E4B Q4_K_M + mmproj: ~5.6 GiB at 32K (KV shared across layers per the spec sheet: 18 of 42 KV-shared). Comfortable.
- Ministral 3 14B Q4_K_M: 7.67 + 0.82 mmproj + 160 KiB/token f16 KV (40 layers × 8 × 128 × K+V × 2 B) → 8K ctx = ~9.7 GiB, over. IQ4_XS (6.92) + 8K = ~9.0 GiB. Tight.
- Qwen3.5-9B Q4_K_M: 5.29 + 0.86 mmproj + small hybrid KV. Fits, but see the #27638 risk.
- 31B Q4_K_M: 17.1 GiB, does not fit. Q3_K_M (13.7 GiB) still does not fit VRAM.

### 4.6 Latency (estimates; the main unknown)

- Decode ceiling = bandwidth / bytes read per token. B580 = 456 GB/s (TechPowerUp, TechSpot). Dense 12B reads ~7 GB/token → ceiling ~65 tok/s; at a realistic 40–60 % of peak, **~25–40 tok/s est.** Speech needs ~4–5 tok/s, so decode is not the constraint.
- E4B: fewer effective weights per token → est. 50–70 tok/s.
- Qwen3.6 measured on box: 36–40 tok/s decode with part of the weights in RAM. Reference point only.
- Prefill is the real constraint. Qwen3.6 measured 481 t/s on 3 B-active on this box. Scaling by active parameters, the 12B dense is **est. ~100–150 t/s, not measured**. Uncached 2–4K token prompts then take 15–40 s. Voice latency only works with a cached static prefix (system prompt, tools, memory). Measure this first.
- Vision: a 280-token image at ~120 t/s est. ≈ 2–3 s. Qwen's 2060-token screenshot took ~10 s measured on box.
- Time to first sentence = STT end + TTFT (cached prefix + new tokens) + first-sentence tokens + TTS first chunk. Components 2–4 are unmeasured for every candidate.

## 5. llama.cpp status at tip 358a420ec (what master can run)

Read from the local clone `engines/llama.cpp-vulkan-tip` (HEAD 358a420ec, 2026-10-12). Source reads, not runs.

- Text: `LLM_ARCH_GEMMA4` = `"gemma4"` in `src/llama-arch.cpp:61`, model code in `src/models/gemma4.cpp`. The 12B's GGUF `general.architecture` is `gemma4` (verified in the google QAT GGUF header). Conversion: `Gemma4Model` in `convert_hf_to_gguf.py:632`.
- Projectors: `PROJECTOR_TYPE_GEMMA4V / GEMMA4A / GEMMA4UV / GEMMA4UA` in `tools/mtmd/clip-impl.h:462–465`, builders in `tools/mtmd/clip.cpp:973–979` and `:1103–1109`. The unsloth 12B mmproj header says `clip.vision.projector_type = gemma4uv` and has `mm.a.input_projection` (audio). So `--mmproj` loads on master.
- The 12B's non-causal vision decode: issue #28318 reports master decodes `gemma4uv` image chunks non-causally at all sizes. That matches the 12B's config flag (`use_bidirectional_attention = "vision"`), so the path is correct in principle. Not run.

**Image output is the open problem.**

- #24146 "Gemma 4 12B vision outputs `<unused49>` tokens": two causes reported (resize never fills the soft-token budget; F16 accumulation overflow in `patch_embeddings_0`, fixed by F32 accumulation). Closed **2026-07-23 by a stale-bot**, not by a merged fix. https://github.com/ggml-org/llama.cpp/issues/24146
- PR #26488 "rebase Gemma 4 unified-vision fixes onto master": **closed, not merged** (API: `merged_at: null`). https://github.com/ggml-org/llama.cpp/pull/26488
- Local `tools/mtmd/models/gemma4uv.cpp` (lines 17–21) computes `patch_embeddings_0` with a plain `ggml_mul_mat` and no explicit F32 accumulation, and the resize path was not read. **Inference: the reported overflow path is probably still on master. Not run.**
- PR #24118 "Fix Gemma 4 Unified conversion" merged 2026-06-04, which fixed the `gemma4uv` load failure in #24120. https://github.com/ggml-org/llama.cpp/pull/24118
- #24251 (gemma4uv NaN logits with `use_gpu=true`) and #29686 (dist sampler aborts on NaN): closed; fix status not read.
- Community anecdote (issue #24146 comments): a Metal user reports correct OCR on a real screenshot on master 308f61c with Q4_K_M + BF16 mmproj (no `<unused>` output). A later user needed a local patch to keep vision compiling on a newer release. Anecdotes, not tests. https://github.com/ggml-org/llama.cpp/issues/24146
- Independent, other runtime: NobodyWho (June 2026) loaded the 12B vision only after bumping its bundled llama.cpp past #24118; the 12B text + tool calling worked. https://github.com/nobodywho-ooo/nobodywho/issues/578

**Intel-specific.**

- Gemma 4 on Arc: SYCL ~7 t/s vs Vulkan ~20 t/s on an Arc iGPU (#26010, not the B580). Use **Vulkan** for Gemma 4 on this box.
- Vulkan `--n-cpu-moe` + Gemma 4 26B-A4B crashed or corrupted output on Arc A770 (#25777). Another reason to skip the 26B-A4B for the voice brain. Dense 12B avoids `--n-cpu-moe` entirely.
- Gated DeltaNet on Intel Vulkan (#27638, open): Qwen3.5 and Qwen3.6 hit it. Gemma 4 has no DeltaNet layers. Qwen3.5-9B does have `linear_attention` layers (config: `layer_types` = full + linear), so it inherits the risk.
- Qwen-VL mtmd embeddings differ from HF (#29251, open). Not an issue for Gemma.

**Net:** the 12B is loadable and text/tool-capable on master, and its vision is **unverified and carries a known open bug class**. The E4B (vision + audio, non-causal fix closed 2026-09-04) is the lower-risk vision option.

## 6. Recommendation (Q1 answer)

**Default resident brain: Gemma 4 12B Unified, Vulkan, one resident model at a time.**

- Model: `google/gemma-4-12B-it-qat-q4_0-gguf` → `gemma-4-12b-it-qat-q4_0.gguf` (6.5 GiB) + `mmproj-gemma-4-12b-it-qat-q4_0.gguf` (0.16 GiB). Alt if VRAM is short: `unsloth/gemma-4-12B-it-qat-GGUF` → `gemma-4-12B-it-qat-UD-Q4_K_XL.gguf` (6.26 GiB) + `mmproj-F16.gguf`.
- Launch shape (to test, not run): `llama-server -m gemma-4-12b-it-qat-q4_0.gguf --mmproj mmproj-gemma-4-12b-it-qat-q4_0.gguf --device Vulkan0 -ngl 99 -c 16384 -fa on -np 1 --jinja`. Add `-ctk q8_0 -ctv q8_0` only to reach 32K, and re-measure. Do not copy the Qwen `--image-min-tokens` flag blindly; check the image token count in the log during gate 1.
- Context: 16K f16 KV is the VRAM ceiling; 32K needs q8_0 KV.

**Gates before it becomes the default (in order; each one a row in `bench/results-matrix.tsv`):**
1. Image test on Vulkan: describe 3 real screenshots (German UI, English UI, dense text). Pass = correct content, no `<unused…>` / empty output. Fail → E4B lane.
2. VRAM headroom: ≥1.2 GiB free after a 4K prompt (the rule used for Qwen), with the monitors on. Fail → E4B.
3. Prefill and TTFT: 1K new tokens, with a 2K cached prefix. Pass = TTFT ≤ 2 s. This is the voice-latency gate.
4. German: 20 German prompts (explain, rewrite, prompt-craft). Score against Qwen3.6 on the same prompts.
5. Tool calling: Hermes' own tool schema, 20 calls, valid JSON and right tool ≥ 18/20.

**Fallback resident brain: Gemma 4 E4B (unsloth Q4_K_M 4.64 GiB + mmproj-F16 0.92 GiB, or ggml-org Q8 mmproj 0.52 GiB).** Vision + audio, ~5.6 GiB total, lots of headroom. Use if the 12B fails gate 1 or 2.

**Heavy on-demand lane: Qwen3.6-35B-A3B** (existing daily-driver command, `10-test-matrix.md` §3). Only under `bench/watchdog.sh` + `jobcap` and never as the always-on brain. It is the best measured tool-caller on the box, and the best German per the German board (72.8, tied with the 12B).

**Grounding lane (not a brain): UI-Venus-1.5 Vulkan** (`10-test-matrix.md` §3). Never SYCL.

**Test-only candidate: Ministral 3 14B** (`unsloth/Ministral-3-14B-Instruct-2512-GGUF`, Q4_K_M 7.67 GiB or IQ4_XS 6.92 GiB, mmproj-BF16 0.82 GiB). Run only if you want a European-origin alternative. Needs ≤8K ctx on the box. Run it on gates 3 and 4.

Not recommended for the brain: 31B dense, 26B-A4B, Qwen3.5-9B (DeltaNet), MiniCPM-V-4.7, E2B (too weak for conversation, though it does vision + audio).

## 7. Test plan for Q1 (for the GPU owner; nothing run here)

1. Download only (no load): the 12B QAT GGUF + mmproj, E4B Q4_K_M + mmproj-F16, Ministral 3 14B IQ4_XS + mmproj. Verify sha256 vs the HF `lfs.oid`. Use the same download gate as `21-small-quants.md`.
2. Under `bench/watchdog.sh` + `jobcap`, one model at a time, `flock -x bench/.gpu.lock`, `gate.sh` first. After each run grep `journalctl -k` for `GT0: reset` / `DEVICE_LOST`. Stop at any hit.
3. Per model: MemAvailable min, PSI memory/io deltas, pp4096 and tg128 (`llama-bench`), TTFT with a 2K cached prefix, screenshot prefill time at the 280-token budget, the gate list in §6.
4. Record each run as a row in `bench/results-matrix.tsv`. Do not edit the existing rows.

## 8. Open risks and unknowns

- **12B vision on master** (§5): the biggest risk. The gate is a real test, not a source reading.
- **Global KV size** for `attention_k_eq_v` (§4.5): 64 vs 128 KiB/token decides whether 32K fits at f16. Read it from the llama.cpp log, not the estimate.
- **Prefill speed** (§4.6): unmeasured on this box for any Gemma 4 model. The voice loop depends on it.
- **VRAM shared with the monitors:** ~9.5 GiB is the budget assumed in the brief. A 12B at 16K leaves little room; a compositor spike could push it into RAM.
- **German quality** is third-party for the 12B and Qwen3.6, and absent for E4B and Ministral. Marcel's German test is the real decider.
- **Tool-call reliability on Hermes' schema** is untested. The benches above are small-n or format-only.
- **Who ran Marcel's "Gemma 4 12B good results"** and on which runtime is unknown. Ask him; it may be a hosted or Mac run.
- **Licence:** all Gemma 4 sizes, Ministral 3 and Qwen3.5/3.6 are Apache-2.0 per their cards. Gemma 4 licence text is from the HF card, not a lawyer read.

## 9. Sources (all read 2026-10-13)

Vendor / primary:
- https://huggingface.co/google/gemma-4-12B-it (card, benchmark table, languages, function calling)
- https://huggingface.co/google/gemma-4-12B-it/raw/main/config.json (architecture)
- https://huggingface.co/google/gemma-4-26B-A4B-it (family table, 26B specs, Apache-2.0)
- https://huggingface.co/google/gemma-4-E2B (family table, audio, video)
- https://huggingface.co/blog/gemma4 (family overview)
- https://arxiv.org/html/2607.02770v2 (Gemma 4 technical report, encoder-free 12B)
- https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512 (Apache-2.0, vision, German in languages, vendor numbers)
- https://huggingface.co/Qwen/Qwen3.5-9B/raw/main/config.json (layer types)

GGUF files (HF tree API sizes):
- https://huggingface.co/google/gemma-4-12B-it-qat-q4_0-gguf
- https://huggingface.co/unsloth/gemma-4-12b-it-GGUF , https://huggingface.co/unsloth/gemma-4-12B-it-qat-GGUF
- https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF , https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF , https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-gguf
- https://huggingface.co/ggml-org/gemma-4-26B-A4B-it-GGUF , https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf
- https://huggingface.co/unsloth/gemma-4-31B-it-GGUF
- https://huggingface.co/unsloth/Ministral-3-14B-Instruct-2512-GGUF , https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF
- https://huggingface.co/unsloth/Qwen3.5-9B-GGUF

German (independent, DACH):
- https://dach.peerbench.ai/models/google/gemma-4-12b-it
- https://dach.peerbench.ai/models/google/gemma-4-26b-a4b-it
- https://dach.peerbench.ai/models/google/gemma-4-31b-it
- https://dach.peerbench.ai/models/qwen/qwen3.6-35b-a3b
- https://dach.peerbench.ai/overview (leaderboard context)
- Mirror: https://german-llm-497016.web.app/models/google/gemma-4-12b-it

Tool calling (independent, small):
- https://huggingface.co/Manojb/small-llm-tool-use-bench (BFCL, 50 per category, Ollama)
- https://github.com/nobodywho-ooo/nobodywho/issues/578 (12B text+tool 14/14, vision bug)
- https://github.com/dneirfi/EDGE-KOPA (arXiv 2609.05395; multi-step live APIs)

llama.cpp (upstream and local tip 358a420ec):
- https://github.com/ggml-org/llama.cpp/issues/24146 (closed stale 2026-07-23)
- https://github.com/ggml-org/llama.cpp/issues/24120 , https://github.com/ggml-org/llama.cpp/pull/24118 (merged 2026-06-04)
- https://github.com/ggml-org/llama.cpp/pull/26488 (closed, not merged)
- https://github.com/ggml-org/llama.cpp/issues/28318 (E2B/E4B causal decoding, closed 2026-09-04)
- https://github.com/ggml-org/llama.cpp/issues/27638 (Intel Vulkan DeltaNet PP collapse, open)
- https://github.com/ggml-org/llama.cpp/issues/26010 (Gemma 4 SYCL vs Vulkan on Arc iGPU)
- https://github.com/ggml-org/llama.cpp/issues/25777 (Vulkan n-cpu-moe + Gemma 4 26B on Arc A770; cited via `research/15-alt-engines.md`)
- Local: `engines/llama.cpp-vulkan-tip/src/llama-arch.cpp`, `tools/mtmd/clip-impl.h`, `tools/mtmd/clip.cpp`, `tools/mtmd/models/gemma4uv.cpp`, `convert_hf_to_gguf.py`

Hardware:
- https://www.techpowerup.com/gpu-specs/arc-b580.c4244 (456 GB/s, 192-bit GDDR6)
- https://www.techspot.com/specs/gpu/302088-intel-arc-b580.html (456 GB/s)

Community, not used for ranking:
- https://gemmai4.com/specs (third-party spec sheet: KV sharing, QAT sizes, function-calling flag; cross-checked against the card where possible)
- https://llmwiki.hu/entities/gemma-4 (third-party release dates)

Box measurements (not new; from this lab's research files):
- `research/10-test-matrix.md` §2.4–2.6, §3 (Qwen3.6 speed, screenshot cost, grounding, tool-call PASS)
- `research/12-best-moe-models.md` (Qwen3.5/3.6, UI-Venus, KV and fit rule)
- `research/21-small-quants.md` (download gate, sizes)

## Self-check

Checked against the brief's Q1 criteria and the source rule before writing this section (re-check on disk below).

- Gemma 4 family covered (E2B, E4B, 12B, 26B-A4B, 31B) — PASS for facts with citations; E2B not sized (not needed for the brain).
- Model shortlist table with all criteria columns — PASS.
- Vision, audio, tool calling, context, licence, llama.cpp support, GGUF availability for every Gemma 4 size — PASS (llama.cpp support from source reads and header reads; **image output on the 12B is not verified by a run**, flagged).
- Qwen3.6-35B-A3B, MiniCPM-V-4.7, and newer dense ≤14B candidates — PASS (Qwen3.5-9B, Ministral 3 14B added).
- Independent benchmarks used where they exist; vendor-only numbers marked — PASS (German and BFCL independent; Tau2, MMMU-Pro, OmniDocBench, Arena-style numbers marked vendor).
- Latency and memory: estimates marked as estimates; the one measured number per candidate is from this box — PASS.
- Non-US sources led where they exist (DACH German board, Mistral/France, Qwen (Alibaba) and UI-Venus (inclusionAI) data via the box notes) — PASS, with the limit that Gemma itself is Google (US).
- No GPU, no model loads, no `bench/.gpu.lock` touched — PASS (only HF/GitHub API, range GET of GGUF headers, and source reads).

