# BRIEF-47: speed recipes from the best local-AI devs, applied to the winner (PARKED until bake-off results)

Trigger: start only after research/42 section 8 (Gemma 4 vs Ornith-1.5-9B vs Ministral-3-14B) has measured
tables. Marcel has high hopes for Ornith: if it wins or is close, Ornith is the primary target.

Do not redo research/40-recipes.md (15 cards, MiaAI kit, OpenVINO MoE finding) or research/46 (depth
measurements, sparse FA path). Extend them.

## Research (cite links and dates; US sources fine for technical topics)
- Who: the most followed local-inference builders and maintainers (llama.cpp maintainers and top
  contributors, ik_llama.cpp, unsloth, bartowski, turboderp, LocalLLaMA power posters, Intel Arc/IPEX-LLM
  and OpenVINO engineers, Chinese and European community authors). What they currently use for speed:
  speculative decoding (MTP heads, draft models, EAGLE-style), quant choice per tensor, KV tricks,
  graph/kernel flags, batching, prompt-cache reuse, context-shift, server flags.
- Model-specific: Ornith-1.5-9B arch qwen35 (Qwen3.5 family): does it ship MTP/draft heads, does any GGUF
  or recipe add speculative decoding, recommended sampling/templates, known llama.cpp SYCL/Vulkan issues.
  Same for the bake-off winner if it is not Ornith.
- Outsourcing: which recipes can be handed to Devin (SWE-2 / Fusion) as patches or scripts, and which
  need GPU time here.

## Output
research/47-speed-recipes.md: a ranked list (expected gain, evidence, effort, GPU risk, owner: us /
Devin), then a test plan in measured runs under the GPU lock (one at a time, gate.sh, watchdog strict,
>= 1 GiB VRAM free). Apply nothing without measurement.

## Added 2026-10-13 (orchestrator, from GGUF headers)
- Ornith-1.5-9B (qwen35): hybrid, full attention only every 4th of 33 layers (KV there only; the rest are
  SSM/gated-delta layers with constant state), head_count_kv 4, ctx 262144, nextn_predict_layers 1 (MTP
  head built in). Priority tests: (1) long-context ladder 32K/64K/128K/256K with VRAM floor and decode at
  depth vs Gemma (research/46 table), needle 5/5; (2) does llama.cpp SYCL use the nextn layer for
  speculative decoding on qwen35, and what speed-up; (3) KV type f16 vs q8_0 vs q4_0 at depth (research/46
  showed quantized KV is slower on Gemma).
- Qwen3.6-35B-A3B (qwen35moe, 256 experts / 8 active, same hybrid): OpenVINO GenAI int4 route (research/40
  card 5, ~3x over SYCL on Arc for MoE) with experts in RAM or at a size that fits; measure on the B580.
- Verified 17:45: our SYCL build loads qwen35 MTP (src/models/qwen35.cpp load_block_mtp), and the Ornith Q4_K_M
  GGUF contains the head (blk.32.nextn.{eh_proj,enorm,hnorm,shared_head_norm}). Ornith MTP needs only
  `--spec-type draft-mtp` (no separate -md file); bench/lc.py is Gemma-specific and needs a --model flag first.
- Ministral-3-14B (mistral3): no MTP head in the GGUF. Options: n-gram/prompt-lookup speculation (no extra
  model) or a small Ministral draft model (not on disk). Marcel (17:45): activate MTP wherever it measurably
  improves speed; rule = decode gain >= 15%, VRAM free >= 1 GiB, needles pass.
