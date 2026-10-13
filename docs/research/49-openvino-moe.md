# 49 - OpenVINO route for MoE models on the 12 GB Arc B580

Written 2026-10-13 (research and read-only checks only: no download over 100 MB, no conversion, no GPU use, no pip install; an Ornith benchmark owns the box).
Evidence tags: [A] maintainer or vendor number on comparable hardware, [B] third-party measurement on other Arc hardware, [C] single anecdote, [D] my own extrapolation (no measurement exists).

## Verdict

**PARTIAL.** OpenVINO runs the target architecture today and ready-made int4 IRs exist, but a 35B-A3B does not fit in 12 GB and OpenVINO's only fix is `OFFLOAD_RATIO`, which on a discrete card streams experts over PCIe. The one dGPU measurement of that (B60) is 5x slower than resident. My extrapolation for Qwen3.6-35B-A3B on the B580 is 6-15 t/s, below the 40 t/s llama.cpp baseline. A fully resident OpenVINO MoE on this card is real only for small MoE (LFM2.5-8B-A1B, gpt-oss-20b borderline).

Best path (cheap, in order): (1) smoke the OpenVINO already installed here with the local 4B; (2) test the small MoE that fit (LFM2.5-8B-A1B, then gpt-oss-20b with a low offload ratio); (3) one decisive test of the official Qwen3.6-35B-A3B IR with `OFFLOAD_RATIO` 60-70 plus MTP; (4) adopt OpenVINO for the MoE tier only if decode >= 50 t/s or >= 1.25x llama.cpp at equal quality with >= 1 GiB VRAM free, otherwise stay on llama.cpp experts-on-CPU plus MTP. Ceiling if it all fitted: Wondernutts measured ~106 t/s on a 608 GB/s B70 [A], so about 75-80 t/s scaled to the B580's 456 GB/s [D]. That is the prize, and the 12 GB limit is what blocks it.

## What is already on this box (read-only check)

| Item | Where | State |
|---|---|---|
| OpenVINO 2026.4.1 + GenAI 2026.4.1.0 + tokenizers 2026.4.1.0 | `engines/openvino/.venv` (Python 3.12, uv) | installed. No nncf, optimum-intel, torch, transformers in it (export is not possible here). |
| OVMS 2026.4.1 (OpenVINO backend 2026.4.1) | `engines/openvino/ovms/ovms/bin/ovms` (458 MB, needs `LD_LIBRARY_PATH=.../ovms/lib`) | installed. `--help` runs. GPU plugin `libopenvino_intel_gpu_plugin.so` and hetero plugin are in `lib/`. |
| Qwen3-4B-int4-ov | `models/openvino/Qwen3-4B-int4-ov` (2.2 GB, INT4_SYM, optimum 2.1.0.dev0) | only OpenVINO model present. Dense, not MoE. |
| Driver stack | pacman `intel-compute-runtime 26.31.39395.13-1`, `level-zero-loader 1.32.0-1` | present. Kernel 7.2.5 omarchy, `xe` driver. |
| B580 | PCI `0000:03:00.0` (8086:e20b, xe), `/dev/dri/renderD128`. The other two render nodes are NVIDIA (08:00.0) and the AMD iGPU (14:00.0). OpenVINO's GPU plugin only sees Intel, so plain `"GPU"` is the B580. | idle sysfs read says 2.5 GT/s x1 (power saving). research/00-plan.md records Gen4 x8 under load. Re-read under load in the plan. |
| Harness | `bench/ov-bench.py` (LLMPipeline only), `bench/results-openvino.py`, `bench/arc-vram.py`, mutex `bench/.gpu.lock` | exist. `ov-bench.py` uses `LLMPipeline`, which cannot load the qwen3_5_moe export (see Q5). |
| Disk / RAM | 787 GB free on /home, 61 GiB RAM (about 36 GiB available right now) | fine for downloads, not for converting a 35B (Q5). |

## 1. Does OpenVINO support qwen35moe (Qwen3.5/3.6 MoE, gated delta net) and MiniCPM-V-4.7?

**Qwen3.5/3.6 MoE: yes, since OpenVINO 2026.2.0 (released 2026-05-28), current stack 2026.4.1 is fine.**
- Native runtime + GenAI support for `qwen3_5_moe` (Gated DeltaNet) on CPU and GPU, tool calling extended to Qwen 3.5/3.6. Source: Cascadia issue 77 quoting the 2026.2 notes (https://github.com/labscommunity/cascadia/issues/77, mid 2026). 2026.3 and 2026.4 release notes list "Qwen3.5, Qwen3.6 ... only on CPUs & GPUs" and "hybrid attention models with linear state (CausalConv1D, GatedDeltaNet) for SDPA and PA backend; VLM models enabled: Qwen3.5, Qwen3.6" (https://docs.openvino.ai/2026/about-openvino/release-notes-openvino.html, read 2026-10-13).
- Intel's own numbers: Qwen3.6-35B-A3B int4, Core Ultra 7 368H iGPU, OpenVINO 2026.2, Paged Attention: 42-43 t/s, 23.2 ms per token at short context vs 23.7 ms at 1024 [A] (https://medium.com/openvino-toolkit/high-performance-moe-inference-qwen3-6-35b-a3b-on-an-ai-pc-with-openvino-cd253d8884ba). Use `ATTENTION_BACKEND="PA"`, and that article says the GPU is the recommended device.
- optimum-intel: PR 1689 "Support Qwen3.5, Qwen3.5-MoE and Qwen3.6" is in the release notes (https://github.com/huggingface/optimum-intel/releases). It needs transformers 5.2.x for Qwen3_5Moe. The PyPI optimum-intel 2.2.0 pins `transformers<5.6`.
- Export only works as `--task image-text-to-text` (optimum-intel issue 1721, 2026-05-05, https://github.com/huggingface/optimum-intel/issues/1721, I could not confirm it was closed). Consequence: load with `VLMPipeline` even for text. marfrit's repo states `LLMPipeline` fails with `Port for tensor name input_ids was not found` (https://huggingface.co/marfrit/Qwen3.6-27B-A3B-Coder-int4-awq-se-ov).

**Open issues that matter for us:**
- openvino.genai #3870: Qwen3.6-35B-A3B incoherent on larger prompts after optimum-intel PR 1735 dropped the ignored-scope patterns (B70, nightlies) (https://github.com/openvinotoolkit/openvino.genai/issues/3870). The official IR was re-uploaded 2026-09-25. Verify coherence at 4K and 32K in the plan.
- openvino.genai #3937: `enable_thinking=False` ignored on the INT4 IR, model still writes chain of thought (2026.2.0.0, B70) (https://github.com/openvinotoolkit/openvino.genai/issues/3937). Matters for Hermes no-think calls. Retest on 2026.4.1.
- openvino #36151: Qwen3.5-4B INT8 crashes with `CL_OUT_OF_RESOURCES` on long prompts on an Xe2 iGPU; INT4 is fine (https://github.com/openvinotoolkit/openvino/issues/36151). Stay on INT4.
- openvino #37736: second `generate()` hangs with `OFFLOAD_RATIO` on INT8 Qwen3-30B; INT4 control was clean (https://github.com/openvinotoolkit/openvino/issues/37736). Stay on INT4.
- OVMS #4428: SIGSEGV when a streaming client disconnects mid-generation, 2026.2.1, reproduced on a B580 and a B60 with Qwen3.6-27B (https://github.com/openvinotoolkit/model_server/issues/4428). A Hermes request timeout would kill the server. Not verified fixed in 2026.4.1.
- OVMS 2026.2 notes: prefix caching with linear-attention models (Qwen3.5/3.6) uses excessive memory (quoted in openvino #36151). Keep prefix caching off at first.

**MiniCPM-V-4.7: supported only on development builds, not on the installed 2026.4.1.**
- optimum-intel PR 2033 "Support MiniCPM-V-4.7-1B and 4.7-35B-A3B" merged 2026-10-07 into main (https://github.com/huggingface/optimum-intel/pull/2033). Not in PyPI 2.2.0.
- openvino.genai PR 4591 "[VLM] Support MiniCPM-V-4.7" merged 2026-10-08 into master. GenAI 2026.4.1.0 is dated 2026-10-01, so it is not in it (GitHub API check). Needs a nightly wheel.
- The OpenVINO org IR cards (created 2026-10-12) carry a banner "EXPERIMENTAL MODEL ... uses development versions of Optimum Intel and OpenVINO GenAI", need transformers 5.18.0, and say the GPU INT4 PagedAttention path needs openvino PR 38631 whose wheel inclusion is "unverified" (https://huggingface.co/OpenVINO/MiniCPM-V-4.7-35B-A3B-int4-ov). Architecture is a Qwen3.5 backbone plus SigLIP, so the qwen35moe findings carry over.

## 2. Ready-made OpenVINO IR repos (sizes summed from the HF tree API on 2026-10-13)

| Repo | Size | Notes |
|---|---|---|
| `OpenVINO/Qwen3.6-35B-A3B-int4-ov` | 18.09 GiB (language 16.75 GiB, MTP head 0.41 GiB, text embed 0.47, vision 0.41) | official, updated 2026-09-25, includes `openvino_mtp_model`. Needs OpenVINO >= 2026.2. Last-two-weeks downloads ~1000. |
| `OpenVINO/MiniCPM-V-4.7-35B-A3B-int4-ov` | 18.40 GiB | experimental, nightly only. No MTP file. |
| `OpenVINO/MiniCPM-V-4.7-35B-A3B-int8-ov` | 32.93 GiB | too big for this box's VRAM path. |
| `OpenVINO/MiniCPM-V-4.7-1B-int4-ov` | 1.26 GiB | dense 1.3B vision model, fits trivially. Not MoE. Handy as a vision helper. |
| `OpenVINO/Qwen3.5-35B-A3B-int4-ov` | 21.52 GiB | older sibling, skip. |
| `OpenVINO/Qwen3.6-27B-int4-ov` | 14.87 GiB | dense, not MoE. |
| `marfrit/Qwen3.6-27B-A3B-Coder-int4-awq-se-ov` | 13.75 GiB | expert-pruned (184 of 256 experts), code-calibrated AWQ+SE. A770 16 GB: 43 t/s vs 14.4 t/s llama.cpp SYCL [B]. Smaller, so needs a lower offload ratio. |
| `OpenVINO/Qwen3-30B-A3B-Instruct-2507-int4-ov` (also Qwen3-30B-A3B, Qwen3-Coder-30B-A3B) | 15.22 GiB | classic MoE, no hybrid layers. Best control for the offload mechanism. |
| `OpenVINO/gpt-oss-20b-int4-ov` | 11.76 GiB | text only. |
| `OpenVINO/gemma-4-26b-a4b-it-int4-ov` | 14.28 GiB | multimodal MoE. |
| `OpenVINO/LFM2-24B-A2B-int4-ov` | 11.61 GiB | |
| `OpenVINO/LFM2.5-8B-A1B-int4-ov` | **4.24 GiB** | fits with huge headroom. 1B active. |
| speculative heads: `circulus/Qwen3.6-35B-A3B-DFlash-ov-int4` 0.2 GiB, `WizardlyBump17/Qwen3.6-35B-A3B-DFlash-int4-ov` 0.19 GiB (WizardlyBump17 is the B580 owner from the Reddit thread), `circulus/Qwen3.6-35B-A3B-eagle3-ov-int4` 0.6 GiB | | DFlash is preview (Q4). EAGLE-3 fails on MoE targets (Q4). |

Not found on the Hub in OpenVINO format (searched 2026-10-13): ERNIE-4.5-21B-A3B, OLMoE, Ling-lite, SmallThinker, Granite MoE, DeepSeek-V2-Lite. Whether optimum-intel can export those architectures is unverified, so they are not candidates until someone checks `docs/source/openvino/models.mdx`. Odd community items: `Echo9Zulu/gpt-oss-7.2b-specialized-science-pruned-moe-only-9-experts-int4_asym-ov` (pruned science specialist, not general).

## 3. The 12 GB problem

Budget on this card: clinfo reports 11.33 GiB total (`bench/arc-vram.py`), the desktop holds about 1.4 GiB, so about 9.9 GiB is usable. Minus compute scratch (~0.8 GiB, my estimate) and KV. Qwen3.6 KV is small because only 10 of 40 layers are full attention with 2 KV heads of 256 dims: 20 KiB per token fp16, so 32K = 0.64 GiB, 262K = 5 GiB (config from the Cascadia issue, arithmetic mine). Linear-attention state is about 60 MiB. That leaves roughly 8.3-8.5 GiB for weights.

Weights split of the official IR: about 1.3 GiB non-expert (attention, shared expert, embeddings, lm_head) and about 16.5 GiB routed experts [D, from file sizes]. Resident experts must be about 7 GiB, so `OFFLOAD_RATIO` must be about **60-65 %**. For marfrit's pruned 13.75 GiB IR it is about 45 %.

What OpenVINO offers:
- **`OFFLOAD_RATIO` (GPU plugin, shipped 2026.3, 2026-08-04).** `LLMPipeline/VLMPipeline(dir, "GPU", OFFLOAD_RATIO=N)`. Keeps N % of eligible MoE expert weights off the GPU, fetched through an LRU cache. Needs XMX (`GPU_HW_MATMUL` in `OPTIMIZATION_CAPABILITIES`), silently does nothing otherwise (https://aweussom.github.io/your-intel-laptop-can-run-30b-models-now-no-nvidia-no-cloud-no-problem.html, 2026-08/09). B580 is Xe2 with XMX, so it should work, but I did not query the device.
  - Measured on an Arc 140V iGPU (unified memory) [B]: Qwen3-30B-A3B int4, ratio 30: 25.3 t/s, 50: 22.1, 90: 5.1. Qwen3.6-35B-A3B int4: 1.44 t/s resident (swapping) to 21.4 t/s at ratio 20 (https://huggingface.co/datasets/blairducrayoppat/openvino-arc140v-lunarlake). TTFT rose from 2.1 s to 21.9 s.
  - **The only discrete-card measurement** [B]: Arc Pro B60, Qwen3-30B-A3B int4: **50.8 t/s resident vs about 10.5 t/s at ratio 30**, copy engine 97 % busy, 3.2 GB in VRAM, 10.2 GB in host RAM; author says it "streams across the bus, not from disk" and "don't use offload on a discrete card" if the model fits (https://github.com/aweussom/NoLlama/blob/main/docs/BENCHMARKS.md, 2026-08-18). That implies roughly 3-4 GB/s effective, far under the PCIe link (my arithmetic: 0.31 GB/token extra traffic over ~75 ms extra per token).
  - Extrapolation to this box [D]: Qwen3.6 reads about 0.56 GB of expert weights per token (40 layers x 8 experts x ~1.76 MB). At ratio 60-65 with no LRU benefit that is about 0.35 GB per token, about 100 ms at 3.5 GB/s, so about 6-12 t/s plain decode. The LRU may help since routing is skewed, so treat 6-15 as the range. Prefill is the opposite: a 4K chunk touches almost every expert, so each chunk streams the offloaded ~10 GB, and 4K prefill could land anywhere from 500 to 3000 t/s depending on real bus throughput. Only a measurement settles this.
  - Open offload bugs (from research/01-strata.md, not re-checked today): openvino #38663 (ratio 100 fix), #38545 (slot-id buffer freed while kernels read it), #38584 (NaN without mmap, iGPU).
- **HETERO / AUTO.** HETERO only offers `PIPELINE_PARALLEL`, a layer-wise split into stages per device (https://docs.openvino.ai/2025/openvino-workflow/running-inference/inference-devices-and-modes/hetero-execution.html), not an expert split. Evidence it works poorly here: OVMS issue 4353 (2026-07-02) failed to load Qwen3.6-35B-A3B on 2x A770 with HETERO because a fused `MOECompressed` op hit the GPU backend (https://github.com/openvinotoolkit/model_server/issues/4353; status unknown), and a B580 owner says GPU+CPU in OpenVINO "tanks to 4 t/s" (https://www.reddit.com/r/IntelArc/comments/1sfme8u/, Reddit, ~April 2026, [C]). AUTO only picks a device or falls back (general OpenVINO behavior, not a split). So there is no llama.cpp style "attention on GPU, experts on CPU" mode.
- **KV cache on CPU / weight streaming:** no user-facing switch found. `KV_CACHE_PRECISION=u8` halves KV, and `SchedulerConfig.cache_size` (GB) sizes the paged cache.

**Models that fit fully resident in about 9.5 GB under OpenVINO int4:**
- `LFM2.5-8B-A1B-int4-ov` 4.24 GiB: fits with 5 GiB spare. No Arc dGPU number found. Bandwidth ceiling (1B active, ~0.6 GB per token at 456 GB/s) is several hundred t/s, so 100-200 t/s is plausible [D].
- `gpt-oss-20b-int4-ov` 11.76 GiB: does not fit beside the desktop. A B580 owner reports 88 t/s decode, "barely fits", crashes at about 3K context [C] (Reddit link above, ~April 2026). Needs `OFFLOAD_RATIO` about 20-25, which carries the PCIe penalty on a smaller share. llama.cpp is the safer engine for it.
- Anything 14-20B total at int4 lands at 8-11 GiB. None of ERNIE-4.5-21B, Ling-lite, OLMoE, SmallThinker exist as OV IR today, so they would need self-conversion with unverified exporter support.
- Dense helper: MiniCPM-V-4.7-1B (1.26 GiB) for vision.

## 4. Serving: OVMS and GenAI

- **OpenAI-compatible, yes, but at `/v3`, not `/v1`.** `/v3/chat/completions`, `/v3/completions`, `/v3/responses`, streaming supported (https://docs.openvino.ai/2026/model-server/ovms_demos_continuous_batching_agent.html). The Hermes custom-provider `base_url` is `http://127.0.0.1:8000/v3`, api key any string.
- **Tool calling:** `--tool_parser` (hermes3 and qwen3coder used in Intel's demos, gptoss exists), `--reasoning_parser qwen3`, optional `--enable_tool_guided_generation true`. Tool calling for Qwen 3.5/3.6 was added in 2026.2; 2026.4.1 notes say accuracy for Qwen3.5/3.6 with linear attention improved. A B580 + B60 fleet runs Qwen3.6-27B with `--tool_parser qwen3coder --reasoning_parser qwen3` (OVMS issue 4428 args). For Qwen3.6 the HF chat template is qwen3coder style tool XML, so start with `qwen3coder` and compare `hermes3` (needs a measured tool-call check, step 11).
- **Image input:** yes for VLMs with `--pipeline_type VLM_CB`; `image_url` as base64 data URL, or http URL if `--allowed_media_domains` lists the host (https://docs.openvino.ai/2026/model-server/ovms_demos_continuous_batching_vlm.html). Tools plus image together are demonstrated with Qwen3-VL-8B. Not tested for Qwen3.6-35B or MiniCPM-V-4.7 by anyone I found.
- **Locally installed `ovms --help` confirms:** `--pipeline_type {LM,LM_CB,VLM,VLM_CB,AUTO}`, `--plugin_config`, `--cache_size`, `--max_num_seqs`, `--max_num_batched_tokens`, `--enable_prefix_caching`, `--kv_cache_precision`, `--draft_source_model/--draft_model_path/--draft_device`. There is **no `--offload_ratio` flag**. `--plugin_config '{"OFFLOAD_RATIO":"60"}'` is the likely route (devnotes.page also warns not to invent a flag) and is unverified; fall back to a ~40-line GenAI-based server if it is ignored.
- **Speculative decoding:** MTP speculative decoding for Qwen3.5/3.6/3.8 and Gemma 4 on CPU and GPU landed in GenAI 2026.4.0 (2026-09-17), preview in OVMS (release notes link above). The official Qwen3.6 IR ships `openvino_mtp_model`. DFlash for Qwen3.6 on GPU is preview, 2.2x on HumanEval (90 t/s), 1.3x MT-Bench, on a Panther Lake iGPU [A] (https://huggingface.co/blog/ofirzaf/intel-dflash-ptl). Intel notes MoE speculation inflates active experts, so the gain is smaller than dense, and under offload extra experts mean extra PCIe traffic [D]. EAGLE-3 fails on MoE targets (`Port for tensor name last_hidden_state was not found`, openvino.genai #4390, 2026.3.1). Draft-model speculation with sampling has a crash/corruption bug (#4190). No public MTP-on-OpenVINO t/s number for any MoE on a discrete Arc card.
- Cold compile is long (204.5 s on a B60, srmiles finding 47 quoted in research/40), so always set `CACHE_DIR` / `--cache_dir`.

## 5. Install, conversion, and RAM

**Do not convert Qwen3.6 or MiniCPM here.** The official IRs exist, and Intel says self-converting a 35B "takes real RAM and real time" (Medium article above). BF16 Qwen3.6-35B-A3B is 64.6 GiB (https://lftw.dev/guides/moe-expert-offload-arithmetic), more than this box's 61 GiB RAM, so conversion would need tens of GiB of swap and I could not find a measured peak [D: expect 70-90 GiB]. Also, models saved with newer transformers store experts unfused and current exporters then silently randomize them (https://huggingface.co/Wondernutts/Ornith-1.0-35B-AEON-Ultimate-Uncensored-BF16-int4-ov), so pin transformers.

If a custom conversion is ever needed (recipe from the official model card and Intel article, not run):
```
uv venv engines/openvino/.venv-export --python 3.12
uv pip install --python engines/openvino/.venv-export/bin/python "optimum-intel[openvino]==2.2.0" "transformers==5.2.0" nncf torchvision pillow --extra-index-url https://download.pytorch.org/whl/cpu
# Qwen3.6 (official IR used INT4_ASYM, group 64, ratio 1.0, int8_sym backup, task must be image-text-to-text):
optimum-cli export openvino --model Qwen/Qwen3.6-35B-A3B --task image-text-to-text --weight-format int4 --group-size 64 --ratio 1.0 --trust-remote-code out/qwen36-35b-int4-ov
```
Versions on PyPI today: openvino-genai 2026.4.1.0, optimum-intel 2.2.0, nncf 3.4.0, transformers 5.19.0 (but optimum-intel 2.2.0 requires `transformers<5.6`, MiniCPM wants 5.18, so MiniCPM needs optimum-intel from git main).

**Runtime install** (no conversion tools needed):
- Qwen3.6, LFM2.5, gpt-oss: reuse `engines/openvino/.venv` (2026.4.1 already newer than the 2026.2 minimum). Add only `huggingface_hub` for `hf download`.
- MiniCPM-V-4.7: a second venv `.venv-nightly` with `--pre openvino openvino-tokenizers openvino-genai --extra-index-url https://storage.openvinotoolkit.org/simple/wheels/nightly`, and check `og.get_version()` is dated after 2026-10-08. Do not touch the working venv.
- Chat template caveat: `LLMPipeline` fails on these exports, use `VLMPipeline` (it accepts text only prompts).

## Ranked OpenVINO candidates for the B580

| # | Candidate | Fits? | Expected decode on this card | Evidence |
|---|---|---|---|---|
| 1 | `OpenVINO/LFM2.5-8B-A1B-int4-ov` (4.24 GiB) | fully resident | 100-200 t/s guess; quality tier is "small and fast", not Qwen-class | [D], no dGPU data. Fastest, safest first MoE test. |
| 2 | `OpenVINO/gpt-oss-20b-int4-ov` (11.76 GiB) | borderline, ctx cap ~3K | 88 t/s if it loads resident; with ratio 20-25 maybe 30-50 | [C] one B580 owner, 2026-04. Text only. |
| 3 | `marfrit/Qwen3.6-27B-A3B-Coder-int4-awq-se-ov` (13.75 GiB, pruned) | ratio ~45 % | 10-20 t/s plain [D]. 43 t/s on A770 16 GB resident [B] | Code specialist, lower ratio than the full model. |
| 4 | `OpenVINO/Qwen3.6-35B-A3B-int4-ov` (18.09 GiB) with MTP | ratio 60-65 % | 6-15 t/s plain, maybe 8-20 with MTP [D] | The decisive test. 42-43 t/s on a 368H iGPU [A], 106 t/s on a 32 GB B70 [A], none under 12 GB. |
| 5 | `OpenVINO/MiniCPM-V-4.7-35B-A3B-int4-ov` (18.40 GiB) | ratio ~65 % | same as #4 minus MTP | Experimental, nightly wheels; run only if #4 is worth it. |
| 6 | `OpenVINO/Qwen3-30B-A3B-Instruct-2507-int4-ov` (15.22 GiB) | ratio ~45 % | 10-20 t/s [D], 25-30 on iGPU [B] | Control for the offload mechanism without hybrid layers. Run only if #4 is ambiguous. |

For comparison the llama.cpp Qwen3.6-35B-A3B Q4_K_XL baseline here is decode ~40 t/s, prefill 4K ~480 t/s.

## Measurement plan (an agent can run this later)

Rules for every step: one test at a time. Start only when the Ornith benchmark has finished and `bench/quiet-run.sh` conditions hold (no bot runs, PSI memory avg60 < 0.3). Wrap runs in `flock -x bench/.gpu.lock nice -n 10 ionice -c2 -n7 ...`. Downloads use `ionice -c3 nice -n 19`. Check `python bench/arc-vram.py` before and after: free VRAM must stay >= 1 GiB (`free=` field), otherwise stop and raise the offload ratio. The B580 drives the desktop, so an OOM or `CL_OUT_OF_RESOURCES` can freeze the session (a B70 owner reports a hard lockup, openvino.genai #3870): save work, start at a high ratio and walk down. After each step run `journalctl -k --since -10min | grep -i -E 'xe|gpu|reset'` and abort on resets. Log rows with `bench/results-openvino.py` (columns engine, version, model, quant, prompt_tokens, ttft_ms, decode_tps, free_vram_mib, gpu_state). Workloads match llama.cpp: pp 4096, tg 128, plus a 32K prefill, 3 reps, first rep discarded (compile and LRU warm-up).

1. **Gate and baseline facts.** `free -g`, `cat /proc/pressure/memory`, `python bench/arc-vram.py`, `cat /sys/bus/pci/devices/0000:03:00.0/current_link_{speed,width}` while a GPU job runs (expect 16 GT/s x8). Record. Nothing else in this plan starts until this passes.
2. **Device sanity (no model).** With the existing venv: `core.get_property("GPU","OPTIMIZATION_CAPABILITIES")` must contain `GPU_HW_MATMUL`, and `FULL_DEVICE_NAME` must say B580. If `GPU_HW_MATMUL` is missing, `OFFLOAD_RATIO` is a silent no-op and the whole offload path is dead: stop at "OpenVINO can only run models that fit".
3. **T0 smoke on the existing 4B** (no download): `flock -x bench/.gpu.lock engines/openvino/.venv/bin/python bench/ov-bench.py --model models/openvino/Qwen3-4B-int4-ov --prompts 512,4096 --gen 128`. This also yields the first row in `results-openvino.tsv` (G7 in research/48) and proves driver, wheel and kernel 7.2 work.
4. **Add the VLM path to the bench.** Copy `ov-bench.py` to `ov-moe-bench.py`, swap `og.LLMPipeline` for `og.VLMPipeline(dir, "GPU", {"ATTENTION_BACKEND":"PA", "CACHE_DIR":"/home/nexuslink/.cache/ov-cache", "OFFLOAD_RATIO":R}, scheduler_config=sc)` where `sc = og.SchedulerConfig(); sc.cache_size = 1; sc.max_num_batched_tokens = 4096` (1 GB of KV covers 32K tokens for Qwen3.6 at fp16). Keep `perf_metrics.get_ttft()`, `get_tpot()`, `get_throughput()`. Property placement (kwargs vs config mapping) is the same gotcha `ov-bench.py` already documents. Add `--ratio` and `--mtp` flags. No other change.
5. **T1 LFM2.5-8B-A1B.** `hf download OpenVINO/LFM2.5-8B-A1B-int4-ov --local-dir models/openvino/LFM2.5-8B-A1B-int4-ov` (4.24 GiB, allowed size is fine after the Ornith run). Run ratio 0: pp 4096, tg 128, 32K prefill. Record t/s and free VRAM. Gate: decode >= 100 t/s means OpenVINO MoE is real on this card.
6. **T2 gpt-oss-20b.** Download (11.76 GiB). Try ratio 0 with a 2K context; expect free VRAM < 1 GiB, then ratio 20, 30. Compare against llama.cpp on the same weights class. Stop here if the best config is below llama.cpp.
7. **T3 Qwen3.6-35B-A3B, plain.** Download `OpenVINO/Qwen3.6-35B-A3B-int4-ov` (18.09 GiB; check RAM headroom for the page cache first, it should be about 17 GiB hot). Run ratios 70, 65, 60 in that order, one process each, stop going lower when free VRAM < 1 GiB. For each: cold TTFT (first request), warm decode over 128 tokens, pp 4096, 32K prefill, and `arc-vram.py`. Also read PCIe throughput if `intel_gpu_top` or xe fdinfo allows (copy engine busy %).
8. **Quality gate for T3.** Coherence at 4K and 32K prompts (needle from `bench/needle.py`), and an `enable_thinking=False` request (issue 3937). Record pass or fail. A fast but incoherent run is a fail.
9. **T3 with MTP.** Same best ratio, enable the MTP model through the GenAI 2026.4 speculative config (check `GenerationConfig` / pipeline docs of 2026.4.1 for the exact property name, I could not confirm it). Record accepted tokens, decode t/s. Optionally DFlash with `circulus/Qwen3.6-35B-A3B-DFlash-ov-int4`.
10. **Decision.** If best decode >= 50 t/s, or >= 1.25x the llama.cpp baseline (40 t/s) with prefill 4K >= 480 t/s and >= 1 GiB free: go to step 11. If 25-50 t/s: record it, keep llama.cpp as default, revisit after the next OpenVINO release. If < 25 t/s: write "does not beat llama.cpp on 12 GB" in research/00-plan.md and stop; do not run steps 11-12.
11. **OVMS serving smoke (only after step 10 passes).** `LD_LIBRARY_PATH=engines/openvino/ovms/ovms/lib engines/openvino/ovms/ovms/bin/ovms --rest_port 8000 --model_repository_path models/openvino --source_model <dir> --model_name qwen36-ov --task text_generation --pipeline_type VLM_CB --target_device GPU --tool_parser qwen3coder --reasoning_parser qwen3 --cache_dir ~/.cache/ov-cache --cache_size 1 --max_num_seqs 1 --plugin_config '{"OFFLOAD_RATIO":"<best>","ATTENTION_BACKEND":"PA"}'`. Then check: a chat completion, a tool call (compare `hermes3`), a base64 image request, and a deliberate client disconnect mid-stream (issue 4428 crash). Point Hermes at `http://127.0.0.1:8000/v3` through llama-swap or directly.
12. **T5 MiniCPM-V-4.7-35B** (only if T3 beat the gate): create `.venv-nightly`, confirm `og.get_version()` is after 2026-10-08, download the 18.40 GiB IR, rerun steps 7-8 plus a grounding check with the harness that scored the GGUF (synth 6/16, real 0/4 earlier).
13. **Write up.** One row per run in `bench/results-openvino.tsv`, a short results table appended to this file, and a verdict line in research/00-plan.md for the two-tier decision.

## Open questions I could not close

- Whether `OFFLOAD_RATIO` is accepted through OVMS `--plugin_config` (not in `--help`, unverified).
- Whether openvino #38663 and #38545 (offload bugs) and OVMS #4428 are fixed in 2026.4.1.
- Real expert-traffic behavior of the LRU on Qwen3.6 routing, which sets whether the 6-15 t/s extrapolation is pessimistic.
- Exact property name to switch on MTP in the GenAI 2026.4.1 Python API.
- Whether the idle PCIe reading (2.5 GT/s x1) retrains to Gen4 x8 under load (research/00-plan.md says yes).

## Sources (all read 2026-10-13)

- https://github.com/huggingface/optimum-intel/issues/1721 , /1754 , /pull/1634 , /pull/2033 , /releases
- https://github.com/openvinotoolkit/openvino.genai/issues/3870 , /3937 , /4390 , /4190
- https://github.com/openvinotoolkit/openvino/issues/36151 , /37736 ; https://github.com/openvinotoolkit/model_server/issues/4353 , /4428
- https://github.com/labscommunity/cascadia/issues/77
- https://docs.openvino.ai/2026/about-openvino/release-notes-openvino.html ; https://huggingface.co/blog/echarlaix/optimum-intel-v22
- https://medium.com/openvino-toolkit/high-performance-moe-inference-qwen3-6-35b-a3b-on-an-ai-pc-with-openvino-cd253d8884ba
- https://huggingface.co/blog/ofirzaf/intel-dflash-ptl
- https://github.com/aweussom/NoLlama/blob/main/docs/BENCHMARKS.md ; https://aweussom.github.io/your-intel-laptop-can-run-30b-models-now-no-nvidia-no-cloud-no-problem.html
- https://huggingface.co/datasets/blairducrayoppat/openvino-arc140v-lunarlake
- https://huggingface.co/OpenVINO (model API listings and file sizes), https://huggingface.co/Wondernutts (B70 numbers), https://huggingface.co/marfrit/Qwen3.6-27B-A3B-Coder-int4-awq-se-ov
- https://github.com/Wondernuttz/openvino/blob/arc-xe2-int4-2026.2/ARC-XE2-INT4.md (custom plugin, 2026-07-25; do not attribute its numbers to the stock plugin)
- https://docs.openvino.ai/2026/model-server/ (VLM, agentic, continuous batching, speculative decoding demos)
- https://www.reddit.com/r/IntelArc/comments/1sfme8u/ (B580 gpt-oss-20b anecdote)
- https://lftw.dev/guides/moe-expert-offload-arithmetic (BF16 and quant sizes of Qwen3.6-35B-A3B)
- Local: research/40-recipes.md card 5, research/01-strata.md, research/00-plan.md, bench/ov-bench.py, `ovms --help`, HF tree API.
