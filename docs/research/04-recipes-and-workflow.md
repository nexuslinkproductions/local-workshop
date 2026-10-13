# 04: Recipes, workflow wiring, KV-cache sizing, fine-tuning (Arc B580, 12 GB)

Date: 2026-10-12. Box: Ryzen 9 7900X, 61 GiB RAM, Intel Arc B580 (Vulkan0, 12216 MiB), Arch Linux.
Scope: findings only. No GPU inference was run. KV and recurrent-state sizes were measured with CPU-only llama.cpp load probes (`--device none`), which allocate the same KV and recurrent buffers as the GPU path. Web sources are cited [n] (ledger below). Local files are cited by path.

## 0. Bottom line

- Both official configs give `num_key_value_heads` (head_count_kv) = 4 [1][2]. Only 16 of 64 layers store KV. That is 64 KiB per token at f16, 34 KiB at q8_0, 18 KiB at q4_0. llama.cpp allocates exactly these sizes (262,144 tokens at q4_0 = 4608 MiB).
- Bonsai (6.71 GiB) reaches 262K only with q4_0 K and V, `-np 1`, and an idle card. On paper that leaves about 0.17 GiB of headroom. 128K at q4_0 fits on an idle card.
- OBLITERATED (14.36 GiB) never fits on 12 GB. At 262K q4_0 about 31 of 65 layers run on GPU and about 7.4 GiB of weights stay in system RAM.
- The usable Arc recipes are forum and repo posts with self-reported numbers. Intel no longer maintains ipex-llm [30]. Use the llama.cpp SYCL/Vulkan builds.
- Claude Code should point straight at llama-server, which serves `/v1/messages` [18][39] (not tested here). Hermes refuses any agent window under 64,000 tokens, and that includes subagents (source, Section 2).
- A 27B LoRA/QLoRA is out of reach on this card (NF4 weights alone are about 14 GiB). Personalize with prompts, RAG and memory instead.

## 1. Recipe sources (what was read, Intel Arc coverage)

| Source | What it offers | Intel Arc coverage | Verdict |
|---|---|---|---|
| Level1Techs, Bonsai B580 thread [23] | Author's SYCL fork of PrismML: 128K on B580 at 80-90 t/s new code, 250-370 t/s on pasted edits, ~44 t/s at 115K history. Uses 4-bit KV and trimmed draft context. Linux steps link not in fetched text. | Yes, B580 and Xe2 fast path. One A770 owner got ~9 t/s on fallback kernels. Self-reported, undated in fetch. | Best Arc-specific source found. Reproduce before trusting. |
| Level1Techs B580 threads [24][25]; search [22] | Buyer and setup threads. [25] says ipex-llm is outdated and SYCL/Vulkan both used. | Yes, anecdotal | Context only |
| llama.cpp SYCL docs [17] | oneAPI build (icx/icpx, GGML_SYCL=ON). A device table lists Arc B580/Linux (build b5377). | Yes | Authoritative SYCL build |
| PrismML prism branch [31][32][33] | Bonsai runtime fork. README lists SYCL (Intel and Nvidia), Vulkan, OpenVINO (in progress). Commits 2026-10-08/09 add a Vulkan PTQ1_0 shader (#252) and SYCL release packages (#339). | Yes (SYCL) | Your build (adfffbe41, 2026-09-25) predates #339 |
| davetha/llama-moe-hybrid-tuning [29] | llama.cpp SYCL on B580, Qwen3.6-35B-A3B (MoE, ~20 GB Q4_K, 256K). Generation ~38 t/s flat. Prefill ~10x faster with --no-mmap and -ub/-b. | Yes, measured on B580 | Best method notes |
| AscalonSolutions 2xB580 repo [28] | Vulkan split of Qwen3.6-35B-A3B across two cards (Docker). ~39 t/s short chats, 15-19 t/s long docs, 10.8 GB worst case per card. Says tested on two Arc Pro B70. | Partial (B70 testing) | Recipe pattern; B580 numbers not direct |
| prismix.dev [5][6][7] | Aggregator mirroring r/LocalLLaMA posts. [7]: B580 llama-bench, Vulkan, Ling-3.0 MoE (1.3B active): pp16384 121 t/s, tg128 114 t/s, 128K q8_0 fits. [6]: 16 GB / 73K Qwen3.8-27B post, body not captured. | Yes ([7]) | Useful tables; check at source |
| runaihome.com [26] | B580 table: Llama 3.1 8B Q4_K_M 28.1 t/s (6.5 GB); Llama 3.2 13B Q4_K_M 17.2 t/s (10.5 GB). | Yes, but Windows driver 31.0.x and llama.cpp b3xxx (2024). Affiliate links. Recommends IPEX-LLM. | Stale; directional only |
| insiderllm.com [27] | Vulkan-first path, then SYCL path. | Yes | Uses `--gpu-backend vulkan`; absent from your build's --help (0 matches) |
| llama.cpp issue #26010 [19] | SYCL ~7 t/s vs Vulkan ~20 t/s on Gemma 4. | Arc iGPU (155U), not B580 | Shows SYCL can lag Vulkan on Arc |
| Unsloth docs [8][9][10] | Claude Code through Unsloth Studio (port 8888). Intel install extra. | Install path only; no Arc benchmarks | Not a llama-server recipe |
| Hugging Face docs [13][14][15] | Local apps; llama.cpp router-mode blog [15]. | No Arc content | Reference for router mode |
| LocalScore [11][12] | Results list, 555 lines scanned. | No Arc or B580 rows | Not useful for Arc |
| r/LocalLLaMA wiki [21] | Rules and FAQ. Recipes are flaired posts. | None | Index only |
| ai-muninn [4] | Qwen3.8-Flash-Next NVFP4 on DGX Spark (GB10), vLLM, 41.7 t/s. | None (NVFP4 and vLLM are NVIDIA-only) | Not applicable |
| llama.cpp discussion #4167 [16] | Device benchmark thread, first ~50K chars. | None in fetched text | Not useful here |
| ipex-llm [30] | Intel: "Patches to this project are no longer accepted." | Legacy | Do not base new setups on it |

Gaps: no non-US Arc-specific recipe source was read (the Chinese-language search returned English pages). The Hugging Face "Hardware compatibility" section is not on the docs pages read [13]; the local llama-cpp skill says it lives on model pages (`?local-app=llama.cpp`), which I did not check. The r/LocalLLaMA hardware megathread (Nov 2025) appeared in search only, not read.

## 2. Wiring a local endpoint into daily tools

The brief pointed the Claude Code item at the Hermes docs. I read the Hermes FAQ [43] for the Hermes side; the docs home [42] has no provider details. For Claude Code I used its gateway docs [39][40][41].

Server: installed llama.cpp is `llm/llama.cpp` a97cce86a (2026-09-27, Vulkan only). Bonsai needs `llm/llama.cpp-prism` adfffbe41 (2026-09-25, Vulkan only). Flags checked against `--help` and the server README [18]:
- `-c`, `-ctk`/`-ctv` (f16 default; q8_0, q4_0, ...), `-fa on`, `-np N` (default auto), `--jinja` (tool calls, required for `/v1/messages` tools), `--alias`, `--host 127.0.0.1 --port`, `--device Vulkan0`, `--device none` (CPU).
- `--fit` defaults to on, but it only adjusts unset arguments. With `-ngl` set it logs "failed to fit ... abort" (in your logs). It will not rescue an OOM.
- Endpoints: `/v1/chat/completions` and `/v1/messages` (Anthropic Messages) [18]. The web UI is on by default [18].

Per tool (base URL `http://127.0.0.1:<port>/v1`; no API key is set on the server, so any placeholder works):
- OpenCode: provider block with `"npm": "@ai-sdk/openai-compatible"` and `"options": {"baseURL": ...}` [34].
- Aider: `export OPENAI_API_BASE=...`, `OPENAI_API_KEY=...`, then `aider --model openai/<alias>` [35].
- Continue: `provider: llama.cpp`, `model: <id>`, `apiBase: http://localhost:8080` (no /v1 in the docs example) [36].
- Cline: API Provider "OpenAI Compatible", Base URL, Model ID [37].
- Open WebUI: Settings > Admin > Connections > Manage OpenAI API Connections [38].
- llama.cpp web UI: `http://127.0.0.1:<port>/` [18].
- Claude Code: the gateway formats are Anthropic Messages, Bedrock InvokeModel and Vertex rawPredict. No OpenAI Chat Completions row [40]. Point it at llama-server: `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>`, `ANTHROPIC_AUTH_TOKEN=local` (the docs' default when unsure [41]), `ANTHROPIC_MODEL=<alias>`. Not tested here.
- Hermes Agent: FAQ config [43]:

```yaml
model:
  default: <alias>            # must match llama-server --alias
  provider: custom
  base_url: http://127.0.0.1:8082/v1
  context_length: 65536       # must match -c; Hermes floor is 64000
delegation:
  model: <alias>              # subagents
  provider: custom
```

The 64K floor, verified in source: `MINIMUM_CONTEXT_LENGTH = 64_000` (`agent/model_metadata.py:272`), enforced by `_enforce_minimum_context` (`agent/agent_init.py:2042`). That runs from `init_agent` (`agent_init.py:2487`), which implements `AIAgent.__init__` (`agent_init.py:1`). Delegated children are built as `AIAgent(...)` (`tools/delegate_tool.py:274`). So every agent, subagents included, must report at least 64,000 tokens. The floor is 64,000, not 65,536.

Your chat scripts: `chat-bonsai.sh` uses `-c 32768` and `chat-obliterated.sh` uses `-c 16384`. Both are below the Hermes floor. Raise to `-c 65536`. Bonsai at q8_0 and 64K is 2.13 GiB (Section 3.4).

Hot-swap:
- llama.cpp router: `llama-server --models-dir DIR --models-max 1`. Default `--models-max` is 4 with LRU unload [15]. Caveat: the router runs one binary for every model. Bonsai needs the prism build. A CPU probe loaded the stock IQ4_XS file with the prism binary; the GPU path is untested. Test before relying on it.
- llama-swap [20] runs one `cmd:` per model, with `${PORT}` assigned by the proxy. Each model can use its own binary. This is the safer choice for Bonsai plus OBLITERATED.

systemd user unit (template, not installed; `systemd-analyze verify` exit 0 on a scratch copy):

```ini
[Unit]
Description=llama-server Ternary-Bonsai PQ2_0 on Arc B580

[Service]
ExecStart=/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/llm/llama.cpp-prism/build/bin/llama-server \
  -m /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/models/llm/bonsai/Ternary-Bonsai-2-27B-PQ2_0.gguf \
  --host 127.0.0.1 --port 8082 --device Vulkan0 -ngl 99 -fa on \
  -c 65536 -ctk q8_0 -ctv q8_0 -np 1 --jinja
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Install with `systemctl --user enable --now <name>.service`. Your user is not in the render or video groups. Confirm the unit opens Vulkan0 (log line "Vulkan0: Intel(R) Arc(tm) B580") before relying on it.

## 3. KV cache for the qwen35 hybrid

### 3.1 Architecture (verified)

| Field | Official HF config [1][2] (Qwen3.8-27B is on HF [3]) | Local GGUF metadata |
|---|---|---|
| layers | 64 | Bonsai 64. OBLITERATED 65: extra blk.64 (MTP/nextn), ignored by stock llama.cpp per your log |
| full-attention layers | 16 (indices 3, 7, ..., 63) | `full_attention_interval` = 4, so 16 |
| num_key_value_heads | 4 | `attention.head_count_kv` = 4 |
| head_dim (K and V) | 256 | key_length = 256, value_length = 256 |
| linear (Gated DeltaNet) layers | 48. 16 key heads, 48 value heads, 128 dims, conv kernel 4 | ssm.state_size 128, group 16, time_step_rank 48, inner 6144, conv 4 |
| native context | 262144 | 262144 |

Only the 16 full-attention layers store per-token KV. The 48 linear layers keep a fixed state per slot.

### 3.2 Bytes per token

Per full layer, K and V give 2 x 4 heads x 256 = 2048 values. Times 16 layers = 32,768 values per token.
- f16 (2 B/value): 65,536 B = 64 KiB/token
- q8_0 (34 B per 32 values = 1.0625 B/value): 34,816 B = 34 KiB/token
- q4_0 (18 B per 32 values = 0.5625 B/value): 18,432 B = 18 KiB/token
- Contrast: an all-attention 64-layer model at f16 would be 256 KiB/token, or 64 GiB at 262K.

### 3.3 Sizes (GiB) and llama.cpp measurements

| KV type | 32K | 64K | 128K | 262,144 | Measured (llama.cpp log) |
|---|---|---|---|---|---|
| f16 | 2.00 | 4.00 | 8.00 | 16.00 | 32K: 2048 MiB (K 1024 + V 1024) |
| q8_0 | 1.06 | 2.13 | 4.25 | 8.50 | 32K: 1088 MiB (OBLITERATED, prism binary) |
| q4_0 | 0.56 | 1.13 | 2.25 | 4.50 | 262K: 4608 MiB (K 2304 + V 2304), both models |

Check: 262,144 x 18 KiB = 4608 MiB. Measured at 262,144 (q4_0) and 32,768 (f16, q8_0), all with `-np 1` and flash attention on.

Recurrent state is fixed per slot, not per token. Measured 149.62 MiB at `-np 1` (R 5.62 MiB + S 144.00 MiB, f32). It is sized from `n_seq_max` (`llm/llama.cpp/src/llama-memory-hybrid.cpp:54-66`). Your GPU run logged `n_slots = 4` at default `-np` (`llm/logs/server-bonsai.log`), so expect about 0.58 GiB there. That 4-slot figure is not measured: a 4-slot probe failed to start with "no backends are loaded", and I did not chase it. Use `-np 1` on this card.

Compute buffers: 0.16-0.40 GiB on CPU runs. The GPU value is unknown; the budgets below assume 0.4 GiB.

### 3.4 What fits on the 12 GB card

Budgets (Vulkan0 reports 12216 MiB = 11.93 GiB total):
- A, idle card: 11.93 - 6.71 (Bonsai) - 0.15 (recurrent, `-np 1`) - 0.40 (compute, assumed) = 4.67 GiB for KV.
- B, your Sep-27 desktop load (9732 MiB free = 9.50 GiB): 9.50 - 6.71 - 0.15 - 0.40 = 2.25 GiB for KV.
- Snapshot, 2026-10-12 probe (4007 MiB free = 3.91 GiB): Bonsai (6.71 GiB) cannot load at all. About 8 GiB was held by something else. Not attributed. The Hermes desktop app (Electron, with a `/dev/dri` render node) was running; I did not confirm it holds VRAM. Measure with the desktop closed.

Bonsai PQ2_0 (6.71 GiB):

| KV | 32K | 64K | 128K | 262K |
|---|---|---|---|---|
| f16 | A yes, 2.00 | A yes, 4.00 (0.67 spare). B no | no | no |
| q8_0 | yes, 1.06 | A yes, 2.13. B yes, 2.13 (0.12 spare) | A yes, 4.25 (0.42 spare). B no | no (8.50) |
| q4_0 | yes, 0.56 | yes, 1.13 | A yes, 2.25. B no (short by 0.003) | A yes, 4.50 (0.17 spare). B no |

Answer to the plan's question 4: 262K on Bonsai is reachable only as q4_0 K and V, `-np 1`, with an idle card, and no room for a speculative-decoding draft. The Level1Techs author reports 128K at 4-bit KV with a trimmed draft context [23]. That is consistent with budget A.

OBLITERATED IQ4_XS (14.36 GiB file; 14.14 GiB of weights in memory). It cannot load fully. Estimated split under budget A, using about 0.218 GiB per layer (14.14 / 65, proportional; embeddings stay on CPU):

| KV | KV GiB | GPU room for weights | approx -ngl (of 65) | weights left in RAM |
|---|---|---|---|---|
| f16, 16K (your current) | 1.00 | 10.38 | ~47 (you run 48) | ~3.9 GiB |
| q4_0, 128K | 2.25 | 9.13 | ~41 | ~5.2 GiB |
| q4_0, 262K | 4.50 | 6.88 | ~31 | ~7.4 GiB |
| f16, 262K | 16.00 | negative | not on GPU | KV must live in system RAM |

The ~47 at 16K agrees with your running `-ngl 48` and its ~3 GB host spill [README]. Decode speed is order of magnitude only. Your measured ~7 t/s at 16K [README] should drop at 262K, where more weights stream from DDR5.

Bonsai decode ceiling: 6.71 GiB read per token over the B580's 456 GB/s [26] gives about 63 t/s theoretical. Your Sep run gave 26 t/s (plan baseline). The forum fork reports 80-90 t/s with speculative decoding [23]. Not verified here.

## 4. Fine-tuning feasibility

- Weights alone: 27B at NF4 (4-bit plus block scales, about 4.5 bits per parameter) is about 15.2 GB (14.1 GiB). The embedding and LM-head matrices are untied (`tie_word_embeddings` false [2]), two of 248,320 x 5,120 each. Left at 16-bit they add about 3.7 GB more, for a total near 19 GB. The card has 11.93 GiB. QLoRA's own paper fine-tunes a 65B model on a single 48 GB GPU [46].
- So LoRA or QLoRA on the 27B does not fit this card. Rule of thumb: NF4 body is about 0.56 GB per billion parameters. The practical ceiling is roughly 7-8B, but vocabulary size matters because the embeddings stay 16-bit. Estimate, not measured.
- XPU stack: bitsandbytes lists Intel GPU xpu for Linux and Windows on Arc A-series and B-series (Battlemage): LLM.int8 yes, QLoRA 4-bit yes, 8-bit optimizers yes [45]. PyTorch XPU lists Arc B-Series for Windows 11, Ubuntu 24.04/26.04 and WSL2 [44]. Arch Linux is not on that list. Install with `pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/xpu` [44].
- Unsloth: documents an Intel install with `pip install .[intel-gpu-torch290]`, whose extra name targets torch 2.9.0. Your ComfyUI venv runs torch 2.14+xpu (per plan), so use a separate venv. The page has a QLoRA example and a "Windows Only" runtime section. No GPU support matrix [10].
- Axolotl: the fetched docs contain no XPU or Intel mention [47]. The only Axolotl-on-Intel guide found is ipex-llm's, which is archived [30].
- Recommendation: personalize with a system prompt, RAG over the Obsidian vault (NEXUS AI CENTER), and Hermes memory (not re-read in this run). If training is still wanted later: a separate venv, QLoRA on 7-8B via Unsloth plus bnb-XPU, probed first.

## 5. Unverified or open

- No GPU inference was run. All B580 throughput numbers are third-party. The Level1Techs fork was not built.
- The prism branch has SYCL packages (#339, 2026-10-09) that your build (adfffbe41) predates. Rebuild with SYCL before judging the Intel fast path. The prism SYCL doc does not mention PQ2_0 or ternary kernels [32].
- The 4-slot recurrent figure (~0.58 GiB) is from source and your log, not measured here.
- `--gpu-backend` (insiderllm) is not in the installed build. Do not copy it.
- VRAM: 4007 MiB free at probe time versus 9732 MiB on Sep 27. Something else holds the rest. Not attributed.
- Non-US Arc sources and the HF hardware-compatibility section: not found or not checked.
- Hermes "provider: custom" wiring is from the FAQ. Not run end to end against the local server.

Files: this report. Probe logs and the citation ledger are in `~/.hermes/cache/scratch/research04/`.

## Sources

[1] https://huggingface.co/Qwen/Qwen3.5-27B/resolve/main/config.json
[2] https://huggingface.co/Qwen/Qwen3.8-27B/resolve/main/config.json
[3] https://huggingface.co/api/models?search=Qwen3.8&limit=15
[4] https://ai-muninn.com/en/blog/qwen38-flash-next-nvfp4-dgx-spark-vllm-recipe
[5] https://prismix.dev
[6] https://prismix.dev/news/d5d055cd5d3c
[7] https://prismix.dev/news/c95f97b0c55a
[8] https://unsloth.ai/docs
[9] https://unsloth.ai/docs/basics/claude-code
[10] https://unsloth.ai/docs/get-started/install/intel
[11] https://www.localscore.ai
[12] https://localscore.ai/latest
[13] https://huggingface.co/docs/hub/en/local-apps
[14] https://huggingface.co/docs/hub/gguf-llamacpp
[15] https://huggingface.co/blog/ggml-org/model-management-in-llamacpp
[16] https://github.com/ggml-org/llama.cpp/discussions/4167
[17] https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md
[18] https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
[19] https://github.com/ggml-org/llama.cpp/issues/26010
[20] https://github.com/mostlygeek/llama-swap
[21] https://www.reddit.com/r/LocalLLaMA/wiki/index
[22] https://forum.level1techs.com/search?q=B580%20llama
[23] https://forum.level1techs.com/t/bonsai-2-27b-ternary-on-a-12-gb-arc-b580-128k-context-80-90-t-s-looking-for-testers-on-other-arc-cards/257270
[24] https://forum.level1techs.com/t/arc-b580-for-running-local-models-on-older-hardware/247860/5
[25] https://forum.level1techs.com/t/first-linux-adventure-intel-arc-llm-stack-advice-needed/250340/2
[26] https://runaihome.com/blog/intel-arc-b580-local-ai-guide-2026
[27] https://insiderllm.com/guides/intel-arc-b580-local-llm
[28] https://github.com/AscalonSolutions/qwen3.6-35b-two-b580s
[29] https://github.com/davetha/llama-moe-hybrid-tuning
[30] https://github.com/intel/ipex-llm
[31] https://github.com/PrismML-Eng/llama.cpp
[32] https://github.com/PrismML-Eng/llama.cpp/blob/prism/docs/backend/SYCL.md
[33] https://api.github.com/repos/PrismML-Eng/llama.cpp/commits?sha=prism&per_page=12
[34] https://opencode.ai/docs/providers
[35] https://aider.chat/docs/llms/openai-compat.html
[36] https://docs.continue.dev/customize/model-providers/more/llamacpp
[37] https://docs.cline.bot/provider-config/openai-compatible
[38] https://docs.openwebui.com/getting-started/quick-start/connect-a-provider/starting-with-openai-compatible
[39] https://code.claude.com/docs/en/llm-gateway
[40] https://code.claude.com/docs/en/llm-gateway-protocol
[41] https://code.claude.com/docs/en/llm-gateway-connect
[42] https://hermes-agent.nousresearch.com/docs
[43] https://hermes-agent.nousresearch.com/docs/reference/faq?format=md
[44] https://docs.pytorch.org/docs/stable/notes/get_start_xpu.html
[45] https://github.com/bitsandbytes-foundation/bitsandbytes
[46] https://arxiv.org/abs/2305.14314
[47] https://docs.axolotl.ai
