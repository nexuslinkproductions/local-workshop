# 0xSero (GitHub 0xSero / Sybil Solutions) and Intel Arc local inference

Researched 2026-10-13 from GitHub API (gh), repo READMEs, registry JSON, his blog repo, and X posts.
He = 0xSero, GitHub account created 2020-08-13, bio "Orchestrator", company Sybil Solutions,
site sybilsolutions.io, X @0xSero, ~2132 followers, 125 public repos (gh api users/0xSero). He
publishes validated local-inference recipes ("one answer per machine") and coding-agent harness
tooling. His Intel work is entirely Arc Pro B70 (BMG-G31 32GB) and Arc Pro B60 (24GB); I found no
B580, OpenVINO, or IPEX-LLM work by him. [H] = he measured it, [R] = he curates, [other] = another author.

## 1. Who he is, repos that matter

Source: gh repo list 0xSero (stars/last update as of 2026-10-13).

| repo | purpose | stars | last update |
|---|---|---|---|
| litter | Rust, no description (biggest by stars) | 2530 | 2026-10-13 |
| turboquant | KV-cache quantization (3-bit K, 2-bit V), Triton + vLLM, RTX 3090/5090 | 1798 | 2026-10-13 |
| orchestra | TypeScript agent orchestration | 281 | 2026-09-28 |
| pi-brain | Pi harness brain | 183 | 2026-09-29 |
| moe-compress | MoE compression automation (REAP/quant/bench) | 182 | 2026-10-06 |
| parcels | Ship a repo + live agent session over Tailscale, resume in tmux | 175 | 2026-09-26 |
| reap-expert-swap | "How much experts do we need to serve a model" | 152 | 2026-10-06 |
| omarchy-local-ai | One-button Omarchy bar widget: serve a validated model, open any coding agent on it | 121 | 2026-10-13 |
| harness-bridge | Point any coding harness at any OpenAI/Anthropic/Responses endpoint | 91 | 2026-09-27 |
| DeepSeek-V4.1-Flash-Two-Sparks | 2x DGX Spark recipe, 262k ctx, EXL3, vision, MTP | 91 | 2026-10-11 |
| exl3xpu | EXL3 trellis inference on Arc Battlemage as a vLLM XPU plugin | 38 | 2026-09-26 (archived, folded into trellis-serve) |
| qwen38-b70 | One-command Qwen3.8-27B server on 2x Arc Pro B70, llama.cpp SYCL TP2 | 22 | 2026-09-01 |
| local-ai-registry | Hardware->validated-recipe registry with pinned images and evidence | n/a | 2026-10-12 |
| trellis-serve | EXL3 in stock SGLang/vLLM on RTX 3090 and Arc B70 (xpu/ = exl3xpu) | n/a | 2026-10-12 |

github.com/0xSero/qwen38-b70, github.com/0xSero/exl3xpu, github.com/0xSero/trellis-serve,
github.com/0xSero/local-ai-registry, github.com/sybil-solutions/omarchy-local-ai, github.com/0xSero/harness-bridge.

## 2. Harnesses he uses with local models, vs Hermes

His harness list (omarchy-local-ai README): pi, Claude Code, Codex, OpenCode, omp, Crush, Grok,
Copilot, and Hermes. [H] The plugin launches the chosen agent in a terminal pointed at a local
gateway on 127.0.0.1, "nothing in their own config is touched". github.com/sybil-solutions/omarchy-local-ai

harness-bridge (github.com/0xSero/harness-bridge) is the mechanism: it injects endpoint, key and
model through the launch environment per dialect (chat vs messages vs responses) instead of editing
~/.claude.json or ~/.codex/config.toml. [H] It probes /chat/completions, /messages, /responses to
discover dialects and reads the model's real context window from /models so nothing assumes 128k.
Hermes reaches a local endpoint through the generic chat path (OPENAI_BASE_URL, OPENAI_BASE_API,
OPENAI_MODEL) and is not special-cased. [H]

Compared to Hermes: our setup configures providers in Hermes and routes via llama-swap. His is
launch-env injection with zero config rewrite, plus a bar UI. Same idea, different plumbing. He treats
Hermes as one harness among many, not the hub, and prefers omp for agent replay testing. [H]
He frames harnesses as the real gap: "A model can reason. But without a harness it cannot act."
https://github.com/0xSero/blog/blob/HEAD/data/blog/browser-harnesses-for-llms.mdx (2026-02-16, draft)

## 3. Intel GPU findings (exact flags, versions, speeds)

His test machines: 2x RTX 3090 + 2x Arc Pro B70 (BMG-G31, 32GB), plus registry records for Arc Pro
B60 24GB. [H]

- SYCL build path (qwen38-b70, [H]): source is mndodd/llama.cpp @4302fb5 + steveseguin
  b70-optimization-lab TP2 stack. Build = SYCL JIT via Intel oneAPI DPC++ 2025.3.3. AOT bmg_g31
  builds work under oneAPI 2026.1.1 but "that runtime's UR level-zero adapter does not enumerate
  devices on any publicly available GPU userspace today; JIT is the verified-working path".
  https://github.com/0xSero/qwen38-b70
- Container GPU visibility ([H]): "/dev/dri/by-path must be mounted ... --device /dev/dri alone
  leaves the GPUs invisible" for the Intel level-zero driver.
- llama.cpp SYCL Q4_K_M, f16 KV, 1x B70 ([H]): decode 33.3 t/s at 2.5k, 27.5 t/s at 128k, max ctx
  131072; prefill 1164 t/s at 2.5k, 426 t/s at 128k. 2x B70 TP2: decode 51.1 t/s, ctx 262144,
  prefill 955 at 2.5k down to 275 at 245k. Single-GPU prefill beats TP2 at every length.
- MTP speculative decode via llama.cpp ([H]): --spec-type draft-mtp --model-draft ... ; 1x B70 at 64k
  = 61.7 t/s easy / 28.2 t/s hard, acceptance 97.2% / 29.6%. Draft + 131k ctx exceeds VRAM
  (UR_RESULT_ERROR_DEVICE_LOST); 65536 is the validated MTP context on one card.
- Quality guards he sets ([H], on the lab-patched build): GGML_SYCL_FATTN_MMA=0 (joint_matrix
  unavailable under oneAPI 2025.3 JIT), and Q4K reorder-family kernels OFF because they "expect the
  lab AOT build's reordered layout, produces corrupted output on stock ggml-org weights under JIT".
- vLLM XPU, 2x B70 ([H]): TP2 + MTP5 fp16 = 140.8 t/s aggregate over 4 streams; 1x B70 PIECEWISE
  MTP5 = 90.1 t/s hard. Image intel/llm-scaler-vllm:0.21.0-b3. Also uses Intel's own AutoRound INT4
  checkpoints (Intel/gemma-4-12B-it-int4-AutoRound, Intel/Qwen3.5-27B-int4-AutoRound) on vLLM XPU. [H]
- SGLang XPU is not viable for hybrid GDN models ([H]): sglang 0.5.13 XPU loads and prefills but the
  GDN decode kernel produces NaN after ~4 tokens (SSM state drift in
  fused_sigmoid_gating_delta_rule_update_kernel) -> all-"!!!" output at 0.44 t/s. Also "SGLang cannot
  run quantized models on XPU": GPTQ/AutoRound and AWQ-INT4 use CUDA-only kernels, FP8 block has TP2
  shape mismatches. llama.cpp SYCL is unaffected because GGML_OP_GATED_DELTA_NET forces fp32.
- exl3xpu, 1x B70, EXL3 4.00bpw Qwen3.8-27B, vLLM 0.26.1 XPU ([H]): C1 91.2 prose / 66.1 code t/s,
  C8 357 agg, C16 365 agg. Cold prefill with int8 linears + oneDNN fused attention: 2421 (4K),
  2259 (32K), 1415 (128K), 911 (254K) t/s. Env: EXL3_INT8_PREFILL=1, EXL3_ONEDNN_ATTN=1. int8
  prefill = 1.89x on XMX at +0.17% NLL; oneDNN attention +7 to +18% over FA2.
  Versions: host kernel 7.1.8 (xe), compute-runtime 26.31.39395.13, IGC 2.40.13, L0 loader 1.32.0.
  Same card tuned llama.cpp SYCL Q4_K_M for comparison: C1 25.0, C8 56.8, prefill 4K 999, 32K 629.
  https://github.com/0xSero/exl3xpu
- Registry verdict ([R]): Intel Arc Pro B70 32GB validated on Qwen3.8-27B via vLLM, 256K, 75 t/s.
  https://github.com/0xSero/local-ai-registry/blob/main/supported/README.md
- Vulkan: his only Vulkan repo, turboquant-vulkan (Apr 2026), patches llama.cpp with tq3_0/tq4_0 KV
  types, measured on Apple M1 Max CPU and a Halo box, not an Intel GPU. [H]
  https://github.com/0xSero/turboquant-vulkan

B580-specific numbers are NOT his. The llama.cpp SYCL discussion lists Arc B580 llama-2-7b Q4_0 at
73.8 t/s decode / 2064 t/s prefill (2026-05-27), Arc Pro B60 84.4 t/s, Arc Pro B70 109.7 t/s. [other]
https://github.com/ggml-org/llama.cpp/discussions/23313 (via vorluxai.com roundup)

## 4. What to try on the B580, ranked by expected value

Our build facts: engines/llama.cpp-sycl-tip, GGML_SYCL=ON, GGML_SYCL_F16=ON, GGML_SYCL_DNN=ON,
GGML_SYCL_GRAPH=ON, GGML_SYCL_DEVICE_ARCH=bmg, oneAPI at ~/intel/oneapi (compiler 2026.0).
The binary currently fails to start: "libsvml.so: cannot open shared object file".

1. Source oneAPI before every SYCL run (prerequisite, currently broken): our binary needs libsvml.so
   and libirng.so from ~/intel/oneapi/compiler/2026.0, so run `source ~/intel/oneapi/setvars.sh
   --force` first. His container does the same in its entrypoint. [H]
   https://github.com/0xSero/qwen38-b70/blob/HEAD/entrypoint.sh
2. Do NOT move to oneAPI 2026.1.x. He reports 2026.1.1's UR level-zero adapter fails to enumerate
   devices; we are on 2026.0 which builds and is a "bmg" (JIT) target like his verified path. Pin it.
3. Turn on the oneDNN XMX flash-attention path for prefill (our build already has GGML_SYCL_DNN=ON):
   set `GGML_SYCL_FA_ONEDNN=1` with F16 KV, since the oneDNN SDPA kernel only fires on native F16.
   Prefill is where our 49K+ prompt times hurt. [H for DNN attention on B70] + [other]
   https://github.com/snailium/llama.cpp-sycl-intel-b70
4. Mirror his server flags for long-context runs (llama.cpp SYCL, [H]): `--gpu-layers 99
   --flash-attn on --batch-size 8192 --ubatch-size 8192 --cache-type-k f16 --cache-type-v f16
   --cache-ram 0 --ctx-checkpoints 0 --fit off --reasoning off --poll 50`.
5. Add MTP speculative decode where a draft exists, with a VRAM guard:
   `--spec-type draft-mtp --model-draft <draft.gguf> --spec-draft-n-max 8 --spec-draft-ngl 0
   --spec-draft-device SYCL0`. He measured 61.7 t/s (easy) vs 33.3 baseline on one B70; on 12GB
   watch for UR_RESULT_ERROR_DEVICE_LOST when draft + context overshoot VRAM. [H]
6. Keep Ornith on llama.cpp SYCL, not SGLang XPU: it is a qwen35 hybrid (linear attention on 3 of 4
   layers), the class where his SGLang XPU run went NaN. GGML_OP_GATED_DELTA_NET forces fp32. [H]
7. Do not enable Q4K reorder-family kernels on our stock build
   (`GGML_SYCL_MMQ_Q4K_REORDER=0`). He keeps them off because they assume the lab AOT reordered
   layout and corrupt output on stock ggml-org weights under JIT. [H]
8. Only if we add a vLLM XPU stack later: his 3.6x to 6.5x llama.cpp-vs-vLLM-XPU gap on B70 needs
   INT4 (AutoRound/GPTQ) or EXL3 weights and Docker with /dev/dri and /dev/dri/by-path mounted. [H]

## 5. What contradicts our current approach

- Our llama.cpp-first plan understates vLLM XPU: on B70 the same 27B is 25.0 t/s C1 on llama.cpp vs
  91.2 t/s C1 on vLLM XPU (EXL3 4bpw), 3.6x (6.5x at C16). [H] Our 12GB card still favors llama.cpp,
  but "llama.cpp is the only sane path" is not what he found on Xe2.
- SGLang XPU is a dead end for hybrid/linear-attention models and for quantized weights on XPU. If
  anything in our plan leaned on SGLang XPU for Ornith or a MoE, drop it. [H]
- f16 KV is his llama.cpp default; our 256K goal needs quantized KV, which he only does on vLLM XPU
  (fp8 KV). On llama.cpp, q8_0-K + q4_1-V is a community B70 recipe from another author. [other]
  https://sergiiob.dev/posts/intel-arc-pro-b70-full-recipe-llama-cpp-sycl
- His Intel facts are BMG-G31 (B70 32GB, 608 GB/s) and BMG-G20 (B60 24GB). B580 is BMG-G21, 12GB,
  456 GB/s: same Xe2/SYCL stack, ~a third of the bandwidth, so expect scaled-down, not matched. [H]
- No OpenVINO and no IPEX-LLM anywhere in his work. He did not validate those on Arc, so our
  OpenVINO install is unproven against his evidence and should not be treated as a supported path.

## Bottom line

His transferable Intel value is not a B580 recipe (he has none) but a validated set of Xe2 rules:
oneAPI 2025.3/2026.0 JIT works, 2026.1.1 breaks device enumeration, mount /dev/dri/by-path, F16+DNN
build, f16 KV, 8192 prefill batch, MTP draft with a VRAM guard, and oneDNN/XMX attention. Immediate
win here: fix the libsvml/setvars gap and enable the oneDNN attention path.
