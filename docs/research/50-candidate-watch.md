# 50 - Candidate watch: new/overlooked local models for Chief (B580 12 GB)

Scout run 2026-10-13 CEST. Window: releases and updates from ~2026-09-01 to 2026-10-13, plus
overlooked older models that fit the two target classes. Method: Hugging Face API
(`/api/models`, `/api/models/<repo>`, `/tree/main?recursive=true`), raw model cards, GGUF header
range reads over HTTP, the llama.cpp master arch list (`src/llama-arch.cpp`) and projector list
(`tools/mtmd/clip-impl.h`), and community sources (r/LocalLLaMA, vendor blogs). No model file was
downloaded, no GPU was touched; the benchmark owns the box.

Box recap: Intel Arc B580 12 GB (~9.5 GiB usable, ~456 GB/s), Ryzen 9 7900X, ~60 GB DDR5
(~60-70 GB/s), llama.cpp SYCL/Vulkan tip 358a420ec (2026-10-12). Marcel's rules: quants >= 3-bit,
vision required, no dense 27B+, no Qwen3.5 base models except Ornith. Already known/tested (not
re-reported): Gemma 4 12B QAT, Ornith-1.5-9B, Ministral-3-14B, Qwen3.6-35B-A3B,
MiniCPM-V-4.7-35B-A3B (queued), Qwen3.8-Flash-Next, UI-Venus-1.5-30B-A3B, Step3-VL-10B,
GLM-4.6V-Flash. Prior scouts: `research/39-model-scout.md`, `research/12-best-moe-models.md`.

Speed estimates below are reasoned, not measured: dense model fully in VRAM, t/s ~ decode
bandwidth / resident bytes; MoE with experts on CPU is bounded by CPU RAM bandwidth and lands near
the measured Qwen3.6-35B-A3B hybrid number (~38-40 t/s on this box).

---

## 0. Bottom line

- **Nothing in the last 6 weeks clearly beats Ornith-1.5-9B on the Ornith axis (9B dense, vision,
  tool calling).** The single best *free* win is a **draft head for the model you already run**:
  `ornith-ai/Ornith-1.5-9B-DFlash` (2026-09-20) ships a 2.41 GiB DFlash speculative draft for
  Ornith-1.5-9B. If llama.cpp can drive it, that is 1.5-2x decode on the current champion with zero
  quality change. Verify the DFlash path first.
- **The strongest new full model is MiniCPM-V-4.7-35B-A3B** (Class B): first MoE in the MiniCPM-V
  line, A3B, vision, Apache-2.0, official GGUF now up, a 14.44 GiB 3-bit imatrix mix, a DSpark draft
  and LES expert scheduling. Vendor claims a higher overall score in less time than
  Qwen3.6-35B-A3B. It is the closest thing to a step up on the brain slot.
- **Two genuinely new small vision models**: `openbmb/MiniCPM-V-4.7-1B` (1.3B, Apache-2.0,
  llama.cpp b11551 merged support 2026-10-11) and the Qwen3-VL-4B class (overlooked, fastest good
  VLM in the June r/LocalLLaMA bench). Good fast screen-readers, weak tool callers.
- **Overlooked Class B**: `nvidia/Nemotron-3-Nano-Omni-30B-A3B` (A3B, vision+audio, official
  ggml-org GGUF) was never in the prior scouts. April 2026 release, not new, but it fits the box and
  covers GUI/OCR/speech in one model.
- **New category to ignore for the brain: "decision models"** (SystemOne / JevBench / Decision
  Index): Cloudflare clef/clef-flash/clef-omni, LiquidAI d1-3B/d1-omni-600M, h2oai/h2o-lightning-4B,
  vllm-sr/d3, autotrust/JEV-*, OmniJev/OneJev-*. They return calibrated typed answers in one forward
  pass and **generate no text**, so they cannot be Chief. Possible future use: a tiny local
  router/guardrail. llama.cpp even has an arch for them (`vllm-decision2`, `/v1/systemone` endpoint,
  v0.6.0).

---

## 1. Top 5 to test next (ranked)

| # | model | class | exact files to fetch | size | why this rank |
|---|---|---|---|---|---|
| 1 | **Ornith-1.5-9B + DFlash draft** (`ornith-ai/Ornith-1.5-9B-DFlash`) | A (speedup) | `model.safetensors` (2.41 GiB); target already on disk | +2.41 GiB | Free 1.5-2x decode on the current best small model, no quality change. Cheapest possible win. **Gate: confirm llama.cpp can consume a DFlash draft (card says SGLang; llama.cpp added D-Flash2 spec decoding, unverified for this file).** |
| 2 | **MiniCPM-V-4.7-35B-A3B** (`openbmb/MiniCPM-V-4.7-35B-A3B-gguf`) | B | `MiniCPM-V-4_7-35B-A3B-mix_q3gud_im.gguf` (14.44 GiB) + `mmproj-model-f16.gguf` (1.04 GiB) | 15.5 GiB | First MoE in the MiniCPM-V line; A3B, vision, Apache-2.0, official 3-bit imatrix mix (meets >= 3-bit), DSpark draft + LES. Vendor: higher overall score in less time than Qwen3.6-35B-A3B. Est. 45-65 t/s with draft, experts on CPU. |
| 3 | **MiniCPM-V-4.7-1B** (`openbmb/MiniCPM-V-4.7-1B-gguf`) | A | `MiniCPM-V-4_7-1B-Q4_K_M.gguf` (~0.63 GiB) + `mmproj-model-f16-4x.gguf` (0.84 GiB) | 1.5 GiB | Newest small VLM (2026-10-06), Apache-2.0, llama.cpp b11551 merged support, tiny. Best fast screenshot reader/OCR helper. Weak tool calling on its own. Est. 120-200 t/s. |
| 4 | **Qwen3-VL-4B-Instruct** (`Qwen/Qwen3-VL-4B-Instruct-GGUF`) | A | `Qwen3VL-4B-Instruct-Q4_K_M.gguf` (2.33 GiB) + `mmproj-Qwen3VL-4B-Instruct-F16.gguf` (0.78 GiB) | 3.1 GiB | Overlooked: fastest model in the June r/LocalLLaMA VLM bench (61 tok/s, near-8B quality), 256K, GUI grounding + tool calling, Apache-2.0. Strong fast vision+tools candidate the prior scouts skipped (they only had 8B). Est. 80-120 t/s. |
| 5 | **NVIDIA Nemotron-3-Nano-Omni-30B-A3B** (`ggml-org/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-GGUF`) | B | `NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Q4_K_M.gguf` (20.88 GiB) + `mmproj-...-Q8_0.gguf` (1.62 GiB) | 22.5 GiB | Overlooked A3B omni: vision + audio + video, GUI, OCR, speech in one model; official ggml-org GGUF, llama.cpp arch `nemotron_h_moe`. NVIDIA Open Model License (commercial OK, not OSI). Est. 35-45 t/s, experts on CPU. |

Runner-up for a 6th slot: **LiquidAI/LFM2.5-VL-3B** (`LiquidAI/LFM2.5-VL-3B-GGUF`,
`LFM2.5-VL-3B-Q4_K_M.gguf` 1.56 GiB + `mmproj-LFM2.5-VL-3B-F16.gguf` 0.80 GiB) - 3B hybrid VL with
tool calls and bounding boxes, arch `lfm2` + LFM2 projector, ~150-200 t/s. Blocked by the LFM1.0
("other") license if the license matters for Chief.

---

## 2. Full table

Fit = resident weights + mmproj + KV + compute under ~54 GiB (45 RAM + 9 VRAM), quants >= 3-bit.
Sizes are GiB from the HF tree API. "dl" = HF downloads at read time.

### Class A - dense/hybrid <= ~14B, vision, tool calling

| model (base repo / GGUF repo) | released | params / arch | llama.cpp | vision | draft/MTP | licence | dl | best evidence (quality) | est. t/s on B580 |
|---|---|---|---|---|---|---|---|---|---|
| **MiniCPM-V-4.7-1B** (`openbmb/MiniCPM-V-4.7-1B` / `openbmb/MiniCPM-V-4.7-1B-gguf`) | 2026-10-06 | 1.3B dense, arch `qwen35` (Qwen3.5 backbone) | **yes** (merged b11551 2026-10-11; tip 358a420ec is newer) | yes (mmproj, `MINICPMV4_7` projector) | DSpark draft repo exists | apache-2.0 | 263 / 2064 | vendor: beats Qwen3.5-0.8B overall and in efficiency; day-0 Intel/AMD chip support (vendor card) | 120-200 |
| **LiquidAI/LFM2.5-VL-3B** (`LiquidAI/LFM2.5-VL-3B` / `LiquidAI/LFM2.5-VL-3B-GGUF`) | 2026-08-11 | 3.1B hybrid (GQA + short conv), arch `lfm2` | yes (arch `lfm2`, projector `LFM2`/`LFM2A`) | yes | no (DSpark draft repo exists) | LFM1.0 ("other") | 27668 / 25139 | vendor: 228 tok/s M5 Max, 116 tok/s Ryzen AI Max+ 395, <3.3 GB; WebGPU demo does tool calls + boxes | 150-200 |
| **Qwen3-VL-4B-Instruct** (`Qwen/Qwen3-VL-4B-Instruct` / `Qwen/Qwen3-VL-4B-Instruct-GGUF`) | 2025-10 (overlooked) | 4B dense, arch `qwen3vl` | yes | yes | no | apache-2.0 | n/a (see unsloth/bartowski GGUFs) | **independent** (r/LocalLLaMA June bench): 61 tok/s, near-8B quality, GUI grounding; MMMU 67.4, DocVQA 95.3 (leaderboard) | 80-120 |
| **microsoft/AesCode-8B** (`microsoft/AesCode-8B` / `prithivMLmods/microsoft-AesCode-8B-GGUF`, `bartowski/AesCode-8B-GGUF`) | 2026-09-29 | 8B dense, base Qwen3-VL-8B, arch `qwen3vl` | yes | yes (Qwen3-VL projector) | no | apache-2.0 | 261 / 3542 | vendor (MS paper): decoupled cross-modal rewards; 300-infographic eval (Text/Bound/Chart + Content/Layout/Style). Specialised for HTML/CSS artifacts, not general tool calling | 55-75 |
| **Jackrong/Qwopus3.5-9B-Coder** (`Jackrong/Qwopus3.5-9B-Coder-GGUF`) | 2026-05-15 (older) | 9B dense, Qwen3.5-9B base | yes | yes (mmproj-F32 in repo) | no | apache-2.0 | 11139 | community (r/LocalLLaMA, 95 upvotes): agentic coding + tool calling. **Flag: Qwen3.5 base -> Marcel's rule** | 50-70 |

Excluded Class A: `microsoft/FrogNano-4B-2609` (coding agent, vision inherited but not post-trained,
text-only claim), `openbmb/Trident-Qwen3VL-2B` (multimodal *embedding* model, not an assistant),
`ewin-reg/MiniCPM5-1B-Agentic-Tooluse` (text-only, LlamaForCausalLM), `ginigen-ai/Edge-4B-TELL`
(Gemma-4-E4B calibration wrapper, not a new model).

### Class B - MoE ~2-6B active, vision

| model (base repo / GGUF repo) | released | active / total, arch | llama.cpp | vision | draft/MTP | licence | dl | best evidence | est. t/s on B580 |
|---|---|---|---|---|---|---|---|---|---|
| **MiniCPM-V-4.7-35B-A3B** (`openbmb/MiniCPM-V-4.7-35B-A3B` / `openbmb/MiniCPM-V-4.7-35B-A3B-gguf`) | 2026-10-06 | 3B / 35B, arch `qwen35moe` | yes (b11551) | yes | **DSpark draft + LES** | apache-2.0 | 630 / 10080 | vendor: higher overall score in less time than Qwen3.6-35B-A3B; 13+ t/s on iPhone 17 Pro Max; day-0 Intel chip support | 45-65 (with draft) |
| **NVIDIA Nemotron-3-Nano-Omni-30B-A3B** (`nvidia/...-Reasoning-BF16` / `ggml-org/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-GGUF`) | 2026-04-20 (overlooked) | 3B / 30B, arch `nemotron_h_moe` | yes | yes (+audio/video) | not published | NVIDIA Nemotron Open Model License | 352666 / 1993 | vendor: GUI, OCR, speech transcription, document intelligence; "improved using Qwen3-VL" | 35-45 |
| **TheDrummer/Orion-26B-A4B-v1.1** (`TheDrummer/Orion-26B-A4B-v1.1` / `bartowski/TheDrummer_Orion-26B-A4B-v1.1-GGUF`) | 2026-09-13 | 4B / 26B, base Gemma-4-26B-A4B, arch `gemma4` | yes | yes (inherits Gemma 4) | no | (inherits Gemma) | 3064 / 40707 | none published; creator targets creative/RP, not tool loops. Q4_K_M 16.73 GiB | 30-40 |
| **inclusionAI/Ling-3.0-flash-VL** (`inclusionAI/Ling-3.0-flash-VL`) | 2026-09-04 | MoE, arch `bailing_moe_v3_vl` | **NO** - arch absent from master (`bailingmoe3` exists, VL tag does not) | yes | no | MIT | 15103 | vendor (Ling3.0-VL TDS PDF); likely too large (64 shards) | not runnable on stock master |
| **chenyumo/moziAI-35B-A3B-MOE-MTP** (community, Ornith-1.5-35B-A3B base) | 2026-09-01 | 3B / 35B | yes | yes | yes (MTP) | MIT + Apache-2.0 (mixed) | n/a | vendor: finance vertical, 256K, 140+ tok/s on R9700 (their rig), 15.9 GB Q4. Vertical/uncensored, treat as experiment | 45-60 |

Excluded Class B: Ling-3.0-flash-VL (arch), `VladHong/K2-Horizon-MoVA-36B-A4B` (text-generation,
no vision in the repo tree), GLM-5.3-Flash (320B), DeepSeek-V4.1-Flash / V4-Flash-Vision-Exp
(284B class), Kimi-K3/K2.7 (1T), Qwen3-Omni-30B-A3B (A3B vision+audio, llama.cpp has no
`qwen3_omni_moe` arch -> use Nemotron Omni instead).

---

## 3. Watch list (announced / not yet usable on this box)

- **Ornith-1.5-35B-A3B-DFlash** (`ornith-ai/Ornith-1.5-35B-A3B-DFlash`, 2026-09-20, 0.72 GiB
  draft). Draft for the 35B-A3B Ornith; same DFlash question as the 9B.
- **MiniCPM-V-4.7-1B-DSpark / 35B-A3B-DSpark** (2026-10-08). DSpark speculative-sampling
  companions; small repos, wiring unverified in llama.cpp.
- **openbmb/Trident-Qwen3VL-2B** (2026-10-12). Multimodal retrieval embedder (MIT). Not an
  assistant, but a possible memory/RAG component.
- **inclusionAI/Realtime-Venus** (2026-09-16, Apache-2.0). Full-duplex audio-visual 9B
  (`Realtime-Venus-Omni`), ONNX; voice + video assistant. No GGUF, no tool-calling path stated.
- **Cloudflare clef-omni** (2026-10-09). Qwen3-Omni-30B-A3B post-train; a decision model, not a
  generator.
- **RedHatAI/diffusiongemma-26B-A4B-it** (2026-09-28). Diffusion Gemma MoE; generation pipeline, no
  llama.cpp path.
- **sensenova/SenseNova-U1.5-8B-MoT** (2026-08-19). 8B native-multimodal MoT (image gen + edit);
  arch `neo_chat` absent from master.
- **DeepSeek-V4-Flash-Vision-Exp** (2026-08-31, 577k dl). Vision variant of the V4 Flash line; too
  large for 12 GB + 45 GB at >= 3-bit.
- **Llama.cpp side to watch**: b11540 "sycl: accelerate MXFP4 MoE" (Intel Arc relevance) and
  b11551 MiniCPM-V 4.7 support are both already in the box's tip; v0.6.0 added `/v1/systemone` and
  3.4x Metal spec decode.

---

## 4. How to re-run this scout (weekly)

Everything is read-only over HTTP; ~10 minutes. Save raw output to the workspace, aggregate in
Python, never in your head.

1. **Recent sweep** (HF API):
   `GET https://huggingface.co/api/models?filter=image-text-to-text&sort=createdAt&direction=-1&limit=500&full=true`
   Repeat with `filter=text-generation`, `any-to-any`, `text-to-text`. Keep `createdAt >= <today-42d>`,
   drop quantizer/fine-tune repos by name (`GGUF`, `AWQ`, `GPTQ`, `NVFP4`, `EXL3`, `MLX`, `heretic`,
   `abliterated`, `-i1-`, `-Q4`...), sort by `downloads`.
2. **Trending** (catches big launches the date filter buries):
   `?sort=trendingScore&direction=-1&limit=200&full=true` and the same with
   `filter=image-text-to-text`.
3. **By org**: `?author=<org>&sort=createdAt&direction=-1&limit=20&full=true` for nvidia, microsoft,
   google, mistralai, Qwen, openbmb, inclusionAI, LiquidAI, LightOn, Aleph-Alpha, zai-org,
   moonshotai, ibm-granite, Ornith. Catches first-party releases.
4. **Card + files**: `/api/models/<repo>` (tags, createdAt, downloads) and
   `/api/models/<repo>/tree/main?recursive=true` (sizes); `/raw/main/README.md` for benchmarks.
5. **llama.cpp support** (the decisive filter):
   `curl -s https://raw.githubusercontent.com/ggml-org/llama.cpp/master/src/llama-arch.cpp`
   -> regex `\{\s*LLM_ARCH_[A-Z0-9_]+,\s*"([^"]+)"\s*\}` for the arch string; and
   `.../master/tools/mtmd/clip-impl.h` -> `PROJECTOR_TYPE_*` for the vision projector. A GGUF that
   names an arch not in this list will not load on the box.
6. **GGUF header** (cheap, no download): HTTP range read the first ~120 KB and parse the KV block for
   `general.architecture` and `clip.projector_type`. Confirms what the file really is.
7. **Community cross-check**: r/LocalLLaMA ("best local VLM" / "12 GB VRAM" threads), ModelScope
   trending, vendor blogs. Tag every number vendor vs independent.
8. Append this run's table to the file, keep the top 5 current, and move anything that became usable
   out of the watch list.

---

## Source index (read 2026-10-13)

- HF API: `/api/models` (searches, org listings, trending), `/api/models/<repo>`,
  `/api/models/<repo>/tree/main?recursive=true`, `/raw/main/README.md`, GGUF header range reads.
- llama.cpp master: `src/llama-arch.cpp` (158 arch strings; `qwen35`, `qwen35moe`, `qwen3vl`,
  `qwen3vlmoe`, `nemotron_h_moe`, `gemma4`, `lfm2`, `mimo2`, `vllm-decision2`, `deepseek4`,
  `glm5-next`; absent: `minicpmv4_7` as an LLM arch, `bailing_moe_v3_vl`, `qwen3_omni_moe`,
  `neo_chat`, `lfm2_vl`); `tools/mtmd/clip-impl.h` (`PROJECTOR_TYPE_MINICPMV4_7`, `LFM2`, `LFM2A`,
  `LING3VL`, `NEMOTRON_V2_VL`, `MUSE_GLIMMER`, ...).
- Cards: openbmb/MiniCPM-V-4.7-1B, openbmb/MiniCPM-V-4.7-35B-A3B (+ `-gguf`), LiquidAI/LFM2.5-VL-3B
  (+ `-GGUF`), microsoft/AesCode-8B, microsoft/FrogNano-4B-2609, openbmb/Trident-Qwen3VL-2B,
  nvidia Nemotron-3-Nano-Omni (unsloth GGUF card), inclusionAI/Realtime-Venus, sensenova/SenseNova-
  U1.5-8B-MoT, inclusionAI/Ling-3.0-flash-VL, LiquidAI/d1-3B, Cloudflare/clef-flash, h2oai/
  h2o-lightning-4B, vllm-sr/d3, autotrust/JEV-27B-VL, JetBrains/Mellum2.1-12B-A2.5B-Thinking.
- Community/vendor: r/LocalLLaMA "Best models for a 12gb VRAM card?" and "Which is the best local
  VLM? Benchmark results June 2026" (independent rig numbers), mindstudio.ai MiniCPM-V-4.7 local
  test, note.com TensorSharp/Intern-Decision roundup, logeshwaran.org Underdog-Saluki writeup,
  byteiota.com llama.cpp v0.6.0 (decision models + `/v1/systemone`), rohitai.com OpenVINO 2026.4.1,
  tinyweights.dev "Best Local VLMs 2026", localaimaster.com Ollama vision VRAM table,
  chenyumo/moziAI model card, github.com/stevenko2002/agents-radar 2026-10-11 (llama.cpp b11551
  MiniCPM-V 4.7, b11540 SYCL MXFP4 MoE).

---

## Self-check

1. Two classes covered, vision + tool calling required for Class A, vision for Class B: PASS.
2. New (>= 2026-09-01) and overlooked older candidates both labelled with dates: PASS.
3. Every candidate carries HF base + GGUF repo ids, arch tag, llama.cpp support verdict, draft/MTP
   yes/no, licence, download count, evidence tag: PASS.
4. llama.cpp support verified against master `llama-arch.cpp` / `clip-impl.h`, not assumed: PASS
   (three models ruled out on missing arch).
5. Sizes from the HF tree API / GGUF header, not cards: PASS.
6. No model downloaded, no GPU run: PASS (header range reads only).
7. Speed figures are reasoned from bandwidth/active-params, not measured, and labelled as such: PASS.
8. Marcel's rules applied and violations flagged (Qwen3.5 lineage on MiniCPM-V 4.7 and Qwopus):
   PASS. The 3-bit imatrix mix for MiniCPM-V-4.7-35B-A3B satisfies ">= 3-bit".
