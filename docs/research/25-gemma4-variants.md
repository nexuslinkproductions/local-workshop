# 25 - Gemma 4 variants: reasoning distills (brain) and GUI helper candidates

Updated 2026-10-13 10:50 CEST. Sizes and sha256 come from the HF API (`/api/models/<repo>?blobs=true`: `size`, `lfs.sha256`). GiB = bytes / 1073741824. Every number is tagged **vendor** (the model's own card or tech report) or **independent** (a third party measured it). No model was loaded and the GPU was not touched.

## Bottom line

- **Brain (Gemma 4 12B reasoning distills):** many exist, but none has independent evidence of a quality gain over base Gemma 4 12B. The only controlled test found (loktar, LoRA on 12B, MMLU 9-subject n=1,780, GSM8K n=1,319) shows no gain; the full-strength adapter stopped JSON from terminating (0/21 valid JSON, base 21/21). Treat every distill as a hypothesis to gate on Marcel's own probes.
- **Top 2 downloaded** (both yuxinlu1, base `google/gemma-4-12B-it`, Apache-2.0, Q4_K_M = 6.87 GiB, MTP draft Q8_0 = 0.43 GiB, vision projector from base = 0.16 GiB):
  1. `gemma4-v2-Q4_K_M` (coding + agentic v2). Best quantified evidence, **vendor-style self-run**: tau2 telecom 15% (base) to 55% (v2), 20 tasks, same harness, all Q8_0. Same card admits MMLU-Pro is slightly below base.
  2. `gemma4-opus48-Q4_K_M` (Claude Opus 4.6/4.8 general reasoning distill). Most general-purpose, **no quality eval published**; MTP speedup 1.2-1.3x is self-reported on an RTX 5090.
- **Helper (GUI grounding):** no Gemma 4 GUI-grounding model with released weights was found. No small (<= 9B) Qwen3.5/3.6 VL dense model was found on HF. Best helper by vendor and independent numbers: **UI-Venus-1.5-8B** (Qwen3-VL architecture). Downloaded Q8_0 + mmproj-Q8_0 = 8.81 GiB.

## Method

- Discovery: HF API search (`/api/models?search=gemma-4 ...`, sorted by downloads) for gemma-4 12B / E4B with distill, reasoning, thinking, Opus, Gemini, DeepSeek, agentic, and GUI terms; web search for model cards and papers; card and README reads for the top candidates.
- Fit rule: GGUF main + mmproj <= 9 GiB (download rule). Brain must fit 11.3 GiB VRAM with 16-32K context. Calibration point from research/21: Google QAT Q4_0 (6.50 GiB) + mmproj used 9.3 GiB at 16K.
- Vision check and thinking toggle are **not verified on box**; they are listed as the gates to run (see Next steps).

## Brain: reasoning distills (Gemma 4 12B first, then E4B)

Ranked by evidence quality, then fit, then vision/tooling. Sizes are GiB.

| rank | repo | base | Q4_K_M | Q5/Q8 | mmproj shipped | fits 11.3 GiB + 16K? (est.) | thinking | tool calling | evidence | license | verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF (`gemma4-v2`) | gemma-4-12B-it | 6.87 (+0.16 mmproj, +0.43 MTP) | Q6 9.11, Q8 11.80 | no (use base mmproj) | yes, est. ~9.5 GiB at 16K (6.87 + 0.16 + KV ~1.1 f16 + compute) | native channel, `enable_thinking=true` default; toggle per stock template | the card says native Gemma 4 tool protocol, needs llama.cpp `--jinja`; self-run tau2 telecom | **self-run**: tau2 telecom 15% to 55% (n=20, Q8, greedy, same harness); MMLU-Pro "a little below base" (no number) | Apache-2.0 | **DOWNLOADED** (Q4_K_M + MTP Q8) |
| 2 | yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF (`gemma4-opus48`) | gemma-4-12B-it | 6.87 (+0.16, +0.43 MTP) | Q6 9.11, Q8 11.80, f16 22.2 | no | yes, same as #1 | native channel, default on, toggle per stock template | not reported | **self-reported only**: MTP 1.3x greedy / 1.2x thinking on RTX 5090; trained on public angrygiraffe Opus 4.6/4.7 reasoning (8.7k) + curated Opus 4.8 samples; no quality eval | Apache-2.0 | **DOWNLOADED** (Q4_K_M + MTP Q8) |
| 3 | Ayodele01/Gemma-4-12B-Gemini-3.5-flash-Reasoning-Distill-GGUF | gemma-4-12B-it | 6.87 | Q5_K_M 7.96 | no | Q5 + mmproj 8.12 GiB, fits on paper | stock template (`<|turn>` format in card) | JSON-clean output claimed, no tool eval | **self-reported**: 25k Gemini 3.5 Flash traces, QLoRA 1 epoch; the card's base-vs-FT table shows token counts and speed only (7.3 tok/s, same for both), no accuracy | gemma | not downloaded; no accuracy evidence |
| 4 | gwejgteheg/gemma-4-12B-IT-QAT-Q4_K_M-DeepSeek-distill-GGUF | QAT-unquantized (Google QAT) | 6.87 | none | **yes** (BF16 mmproj 0.16) | yes, 7.04 GiB with mmproj | stock | not reported | none (card has no eval or data description) | not stated | not downloaded; QAT requant, unknown quality |
| 5 | arsovskidev/Gemma-4-E4B-Claude-4.6-Opus-Reasoning-Distilled | gemma-4-E4B-it | 4.97 (+0.92 BF16 mmproj = 5.89) | Q8 7.48 | **yes** | yes, small | `<think>` tags in the card (custom, not Gemma's native channel) | not reported | none; 2.3k CoT samples, QLoRA 4-bit | Apache-2.0 | candidate if E4B is wanted; tag format conflicts with native template |
| 6 | mradermacher/Gemma-4-E4B-it-Fable-Distill-GGUF (base armand0e) | gemma-4-E4B-it | 4.97 (+0.52 mmproj-Q8) | Q8 7.48 | **yes** | yes | stock | not reported | none in card | Apache-2.0 | alt E4B; no eval |
| 7 | talisma/Gemma-4-E4B-Reasoning | gemma-4-E4B-it | 4.97 (+0.92 mmproj-f16) | Q5 5.37, Q8 7.48 | **yes** | yes | not checked | not reported | none in card | Apache-2.0 | alt E4B; no eval |

Other finds, excluded:
- 26B-A4B and 31B distills (TeichAI, Abiray, mudler, mradermacher, ...). 26B-A4B is 14.4 GB at 4-bit per secondary sources, 31B is 17.5 GB. Both fail the full-VRAM rule.
- deadbydawn/ravenx-Gemma4-12B-MTP-...-deep-reasoning: only F16 (23.8 GB) on the repo. No quant, no download.
- yuxinlu1/gemma-4-12B-coder-fable5-composer2.5-v1-GGUF: coding-first, Q4_K_M 6.87 GiB, ~2.9k likes. Not reasoning-first; alt if coding dominates.
- unsloth/gemma-4-12B-it-qat-GGUF UD-Q4_K_XL: not a distill. Downloaded earlier as the QAT-fidelity candidate (6.26 GiB + mmproj-F16 + Q4_0 MTP draft). Unsloth reports byte-exact 99.96% against the BF16 QAT lattice for this file; the naive Q4_0 conversion was 24.8%.

### Independent evidence (counter-weight)

- **loktar/gemma-4-12b-distill-experiment-01** (LoRA r=64 on the 12B language tower, 3k rows of synthetic reasoning, not GGUF). Chat template applied, 5-shot, vLLM, identical config:

  | | base | full (alpha 64) | half (alpha 32) |
  |---|---|---|---|
  | MMLU 9-subject, n=1,780 | 82.75 | 80.67 | 82.98 |
  | GSM8K, n=1,319 | 86.66 | 85.67 | 87.64 |
  | JSON probes valid (n=21) | 21/21 | 0/21 | 19/21 |

  Paired McNemar on GSM8K: not significant either way (p = 0.35 full, p = 0.25 half). Result: no knowledge gain; full strength breaks structured-output termination. This is the closest thing to an independent test of a 12B reasoning distill that I found. Rated **independent** (third-party author, detailed protocol, but a single run).
- **Google vendor numbers for the base 12B** (for scale): GPQA Diamond 78.8, AIME 2026 no tools 77.5, MMLU-Pro 77.2, LiveCodeBench v6 72.0, tau2 avg 69.0 (vendor). **Independent** aggregator Artificial Analysis (via frontierlog) reports GPQA 75.3 for Gemma 4 12B (Reasoning). Use these as the base reference for any distill claim.

### Vision and thinking toggle

- **Vision:** none of the 12B distills ships a tested mmproj. The base-matched projector is `unsloth/gemma-4-12b-it-GGUF/mmproj-BF16.gguf` (sha 2e269f906eb1...), which I downloaded. The 12B has no encoder; its projector is linear, so the base projector is the likely pairing, but this is untested. Gate: one image sanity run on the box before use (local-gguf-serving rule 8, and some projectors emit garbage tokens).
- **Thinking toggle:** both yuxinlu1 cards keep the stock Gemma 4 template with the native thought channel (`enable_thinking=true` default). Stock toggle is `--chat-template-kwargs '{"enable_thinking":false}'` (Unsloth doc). Expect the same on both; verify on box.
- **Tool calling:** yuxinlu1 v2 reports leaked `<|tool_call>` markup when the front-end does not parse Gemma's native format, and asks for `--jinja`. Plan for `--jinja`.

## Helper candidates (GUI grounding / computer use)

Constraint from Marcel: Qwen model or an improved/modified Gemma 4; loaded on demand; up to ~10 GiB own use; vision required. Vendor numbers are tagged vendor; independent ones are tagged independent.

| rank | model | arch | size (main + mmproj) | ScreenSpot-Pro | OSWorld-G | other | fits <= 10 GiB? | status |
|---|---|---|---|---|---|---|---|---|
| 1 | inclusionAI/UI-Venus-1.5-8B (Apache-2.0) | Qwen3-VL (`Qwen3VLForConditionalGeneration`, 36 layers, 8 KV heads, head dim 128) | Q8_0 8.11 + mmproj-Q8_0 0.70 = **8.81 GiB** (mradermacher quant) | 68.4, zoom 73.9 (vendor) | 69.7, zoom 70.6 (vendor) | ScreenSpot-V2 95.9, UI-Vision 46.5, VenusBench-GD 72.3 (vendor) | yes at <= 4K ctx; ~10 GiB at 8K with f16 KV (my estimate: 147 KB/token KV) | **DOWNLOADED**. Fallback Q6_K 6.26 GiB + mmproj-Q8 if the on-box fit fails |
| 2 | Tongyi-MAI/MAI-UI-8B (Apache-2.0) | Qwen3-VL, 36 layers | Q8_0 8.11 + mmproj-Q8_0 0.70 = 8.81 GiB (mradermacher) | 65.8 (vendor, from UI-Venus table) | 60.1 (vendor, UI-Venus table) | VenusBench-GD 65.2, UI-Vision 40.7 (vendor); mobile-first (AndroidWorld, MobileWorld) | same as #1 | not downloaded (desktop grounding weaker than #1, mobile strength not needed for the helper's desktop job) |
| 3 | Step-GUI-8B (StepFun; Qwen3-VL-8B backbone) | Qwen3-VL | unknown | 62.6 (vendor; text also says 65) | 70.0 (vendor) | AndroidWorld 80.2, OSWorld 48.5 (vendor) | would fit | **weights not found** on HF under the probed names (stepfun-ai/Step-GUI-8B, Step-GUI, StepGUI-8B, Step-GUI-8B-preview, GUI-Step-8B all absent) |
| 4 | Qwen3-VL-8B-Instruct (Qwen, Apache-2.0, 2025-10) | Qwen3-VL | bf16 safetensors ~16.4 GB; GGUF needs a conversion | ConClick paper: 54.71 (**independent**); UI-MOPD paper Thinking variant 43.71 (**independent**) | ConClick: 63.33 (**independent**); UI-MOPD: 52.13 | ScreenSpot-V2 91.27 (UI-MOPD, **independent**) | with a Q8 GGUF yes | baseline for the 8B family; not downloaded |
| 5 | stepfun-ai/GELab-Zero-4B-preview | 4B vision | INT8 GGUF 4.28 GB + mmproj INT8 454 MB (its card) | not extracted | not extracted | OSWorld 31.9 in a table (vendor, UI-MOPD relays it) | yes easily | smaller alternative; vendor-only |

Excluded: Gelato-30B-A3B (SS-Pro 63.88, OSWorld-G 73.40, vendor; 30B MoE, too big), UI-Venus-1.5-30B-A3B (SS-Pro 69.6; already on disk at 17-19 GB quants, too big for the helper cap), Qwen3.6-27B (dense, too big), Qwen-UI-Agent (arXiv 2607.28227; claims SS-Pro 81.5, weights and size not verified).

What did not exist:
- **Gemma 4 GUI-grounding models with released weights:** none on HF in search. DeskForge (arXiv 2610.02320) LoRA-fine-tuned Gemma4-E4B-IT on 200K grounding examples and reports gains on five external benchmarks (independent paper; numbers not extracted). No weights found, so not a candidate.
- **Small Qwen3.5+/3.6 VL dense (<= 9B):** HF API probes of Qwen/Qwen3.6-8B, Qwen3.6-9B, Qwen3.6-4B, Qwen3.6-VL-8B, and unsloth/Qwen3.6-8B-GGUF and -9B-GGUF returned "not found". The Qwen3.6 dense sizes found on HF are 27B only (plus 35B-A3B MoE). So the helper must be a Qwen3-VL-8B derivative, which is older than Qwen3.5.

Helper decision: download **UI-Venus-1.5-8B Q8_0 + mmproj-Q8_0** (best vendor + independent-consistent numbers among the fitting candidates; Apache-2.0; 8.81 GiB <= 9 GiB with mmproj).

## Downloads this run (all under `models/llm/`)

| repo | file | bytes | GiB | sha256 check | local path |
|---|---|---|---|---|---|
| yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF | gemma4-v2-Q4_K_M.gguf | 7381381664 | 6.87 | PASS (0b9506cab36f...) | yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF/ |
| yuxinlu1/gemma-4-12B-agentic-... | MTP/gemma-4-12B-it-MTP-Q8_0.gguf | 465109248 | 0.43 | PASS (145db9094bc0...) | same dir, `gemma-4-12B-it-MTP-Q8_0.gguf` |
| yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF | gemma4-opus48-Q4_K_M.gguf | 7381381664 | 6.87 | PASS (5b599d5b1a62...) | yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF/ |
| yuxinlu1/gemma-4-12B-it-Claude-4.6-4.8-Opus-GGUF | MTP/gemma-4-12B-it-MTP-Q8_0.gguf | 465109248 | 0.43 | PASS (145db9094bc0...) | same dir |
| unsloth/gemma-4-12b-it-GGUF | mmproj-BF16.gguf | 175115840 | 0.16 | PASS (2e269f906eb1...) | unsloth/gemma-4-12b-it-GGUF/ |
| mradermacher/UI-Venus-1.5-8B-GGUF | UI-Venus-1.5-8B.Q8_0.gguf | 8709520128 | 8.11 | PASS (bea869625d42...) | mradermacher/UI-Venus-1.5-8B-GGUF/ |
| mradermacher/UI-Venus-1.5-8B-GGUF | UI-Venus-1.5-8B.mmproj-Q8_0.gguf | 752289984 | 0.70 | PASS (094afe9d1056...) | same dir |
| unsloth/gemma-4-12B-it-qat-GGUF (earlier pass) | gemma-4-12B-it-qat-UD-Q4_K_XL.gguf | 6716356800 | 6.26 | PASS (90fd44e29e0d...) | unsloth/gemma-4-12B-it-qat-GGUF/ |
| unsloth/gemma-4-12B-it-qat-GGUF (earlier) | mmproj-F16.gguf | 175115840 | 0.16 | PASS (ecc4e93128da...) | same dir |
| unsloth/gemma-4-12B-it-qat-GGUF (earlier) | mtp-gemma-4-12B-it.gguf | 253708800 | 0.24 | PASS (fcb35dea42c7...) | same dir |

Bundle totals for the two brain candidates: main 6.87 GiB + mmproj 0.16 GiB + MTP 0.43 GiB = 7.46 GiB each (mmproj alone = 7.03 GiB, under the 9 GiB rule). Helper: 8.81 GiB with mmproj.

Not downloaded (superseded): Coding-Monkey-Gemma Q4_K_M (TheOneWhoWill, tool-call 26.5% to 70.6%, self-eval n=102, no mmproj in repo). It stays a text-tool alternative if agentic evidence needs a second source.

## Self-check (step by step)

1. Discovery covered the required terms: PASS. HF API searches for gemma-4-12b, gemma-4-12B, gemma-4 distill, gemma-4-E4B distill, gemma4 reasoning, gemma-4 thinking distill, gemma-4-12b reasoning gguf. Results listed above.
2. Sizes and sha256 come from the HF API, not from cards: PASS. Card sizes (e.g. "6.87 GB", "~8.3 GB") were cross-checked with API bytes; they agree for the yuxinlu1 repos.
3. Every downloaded file: size equals HF API bytes, first 4 bytes are `GGUF`, sha256 equals `lfs.sha256`: PASS for all 10 files (table above; each run printed `"PASS": true`). The Opus MTP file was re-verified in a separate run after one timed-out call. The file was complete and the rerun passed.
4. Fit rule (main + mmproj <= 9 GiB) for downloaded items: PASS (7.03 GiB and 8.81 GiB).
5. Vision with the tuned weights: NOT VERIFIED. No candidate was loaded. Marked as a gate, not a claim.
6. Thinking toggle: NOT VERIFIED on box. Based on card text and the stock template. Marked as a gate.
7. Tool calling: NOT VERIFIED on box. Based on the vendor's self-run tau2 for #1 only.
8. MTP speculative decoding: NOT VERIFIED. Risk noted: yuxinlu1 reports that llama.cpp b9702/b9717 crash while loading the Gemma 4 draft ("invalid vector subscript"), and b9553 is the verified build. Our `engines/llama.cpp-sycl-tip` is at 358a420ec (2026-10-12), which is newer, so the draft load must be tested on a build that does not crash.
9. Independent evidence claims: each number tagged vendor or independent. PASS.
10. GPU, model loads, and bench lock: untouched. PASS.

## Open issues

- No independent quality eval exists for either downloaded distill. The gate is Marcel's own probe set: JSON termination (loktar's failure), tool-call format, English work answers, and a thinking on/off comparison on the same prompts vs `gemma-4-12b-it` QAT already on disk.
- UI-Venus Q8 + 8K context is at the 10 GiB cap by my estimate. If the on-box check shows less than 1.2 GiB free after a 4K prompt (local-gguf-serving rule 7), switch to Q6_K.
- Step-GUI-8B and Qwen-UI-Agent may be the strongest GUI models, but weights for Step-GUI were not found and Qwen-UI-Agent sizes were not checked.

## Next steps (on box, not done here)

1. Image sanity with each brain candidate plus `mmproj-BF16.gguf`, `--jinja`, `enable_thinking` on and off.
2. KV fit at 16K for the brain (target 9.3 GiB or less, as with the QAT baseline) and at 8K for the helper.
3. Helper grounding run on a fixed screenshot set (desktop plus synthetic targets), scored under one coordinate convention per model.
