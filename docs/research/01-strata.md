# Strata (Qwen3.8 Flash-Next) on Intel Arc B580, and Arc expert-offload alternatives

Checked 2026-10-12 against Niko1221/Strata at commit a0116b2 (main) [1][2]. Local probes were read-only. Nothing was built, downloaded or run.

## Verdict

- **Strata runs on B580: INCONCLUSIVE.** It has run on a B580 once, under WSL2 with local patches: 2-bit and Coder builds, 13.6-22.6 tok/s decode, and "device loss has also been observed" [9]. Nothing exists for native Linux, and nothing exists at 3-bit. The installer says other Arc cards are "untested" [6].
- **Vulkan: NOT SUPPORTED.** No Vulkan code on main outside `bench/results` (CMake, setup, sources), and the `--backend` choices are `cuda`, `hip`, `sycl` [6][8]. The only Vulkan work is open PR #2060, a vision-encoder path for Linux AMD [13].
- **OpenCL: NOT SUPPORTED.** Only a CPU test device (`ONEAPI_DEVICE_SELECTOR=opencl:cpu`) [3] and comments.
- **SYCL/oneAPI: YES, experimental.** Linux only, Docker-based setup [3][7].
- **CPU: helper only.** No CPU backend [6].

Provenance is inconsistent. [3] says the maintainers "have no Intel GPU", yet its table credits "Strata maintainers" with B70 and A750 test machines, and [4] describes a "B70 VM". Treat those numbers as maintainer claims.

## 1. Backends (repo at a0116b2)

| Backend | Status | Evidence |
|---|---|---|
| CUDA | main engine | README: "NVIDIA or AMD graphics card (12 GB or more)" [2] |
| HIP (AMD) | wave32 RDNA targets | CMake: "Build the HIP targets for wave32 AMD GPUs (gfx1100, gfx1201; gfx1012/gfx1030 unvalidated)" [8] |
| SYCL (Intel) | experimental, default OFF | CMake: "EXPERIMENTAL: build the Intel Arc (SYCL) engine from sycl/ - docs/INTEL_ARC.md" [8] |
| Vulkan | none for LLMs | My grep of the clone: 36 "vulkan" lines in 8 files, all under `bench/results/` (llama.cpp baselines, build flags set OFF) |
| OpenCL | none | DPCT comments ("OpenCL C 1.2 standard"), `GGML_OPENCL:BOOL=OFF` flags, the CPU test device [3] |
| CPU | helper only | "the CPU computes the others" on the non-streaming A750 path [4] |

## 2. Intel Arc status

- Port by maxfridbe, PR #423 [9]. A maintainer comment on 2026-10-04 says "Merged into 0.1.39 as the experimental Intel Arc engine" [9]. The PR API still shows `state: closed`, `merged_at: null`.
- Installer status: "supported since 0.1.40.2 on Linux, tested on an Arc Pro B70 (xe) and an Arc A750 (i915); other Arc cards and driver versions are untested" [6].
- Linux only: "the SYCL port runs on Linux only" [7]. No Windows setup: "the Intel Arc engine has no Windows setup yet" [6].
- B580 is recognised: PCI id `e20b` = "Arc B580", 12.0 GB [7]. Build target `bmg-g21` [3][4].
- Open related items: B580 tensor-parallel request #1861 [15]; native Windows B580 port #1552 [16]; device loss on a 2x B70 layer split #2157 [14].
- Discussions are disabled [1].
- Class: experimental, community-tested. B580 evidence is community-only.

## 3. Recipe: Flash-Next 3-bit, 12 GB VRAM + 64 GB RAM (not run)

Model files, ISTA-DASLab GGUF at pinned revision `ed59f92...` [18][19][20]:

| Build | Shard 1 | Shard 2 | Setup download |
|---|---|---|---|
| IQ3_XXS [19] | `IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf` (47,039,860,096 B) | `...-00002-of-00002.gguf` (28,800,138,432 B) | 75.8 GB [6] |
| IQ3_S [20] | `IQ3_S/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf` (54,817,524,224 B) | same shard 2 (identical LFS hash) | 83.6 GB [6] |

- Shard 2 is the 28.8 GB per-layer embedding table, read by row [4].
- Optional vision projector: `mmproj-Qwen3.8-Flash-Next-BF16.gguf`, 907,543,008 B [18]. The MTP draft (~6 GB) is fetched on first start [5]. Base model: Qwen/Qwen3.8-Flash-Next, license "other" [21].
- RAM asks: 60 GB (IQ3_XXS) and 62 GB (IQ3_S, "needs a 64 GB PC with little else running") [6]. Expert arenas: 42.9 GB and 50.3 GB [6]. This box has 61 GiB total.
- VRAM: B580 is 12.0 GB, not below the 12 GB "small card" cutoff, so the reserve is 1,024 MiB up to 32K context [7].

Commands, from [3][4]. Not executed here:

```sh
git clone https://github.com/Niko1221/Strata && cd Strata
docker build -t strata-sycl-dev sycl/tools            # ~6 min, 13 GB image
H=$(basename "$PWD")
docker run --rm -u $(id -u):$(id -g) -v "$PWD/..:/work" -e AOT=bmg-g21 -e REPO=/work/$H \
  -e BUILD_DIR=/work/$H/build-sycl-aot strata-sycl-dev "cd /work/$H && bash sycl/tools/build.sh strata"
./setup.sh --backend sycl --model IQ3_XXS --context 32768 --port 8085   # or --model IQ3_S
# later starts: run-<model>.sh (created by setup), or ./setup.sh --backend sycl again
```

Rules from the docs:
- Keep about 1.5 GB of VRAM free. On xe, over-allocation spills to RAM and can livelock the machine until a watchdog reset [4].
- `SYCL_CACHE_PERSISTENT=0` (set by the start script) [4]. `STRATA_VERIFY_NO_HOST=1` is required when experts sit in the host mirror (the wrapper sets it) [4].
- If answers come back empty, send `reasoning_effort: none` [4].

What to expect on 12 GB: most experts live in a pinned host mirror that the GPU reads over PCIe. The CPU does not compute them on this path [4]. The closest tested case is the B70 (32 GB) with 11.5k of 24.6k experts on-card and 60 GB RAM; its mirror is about 26 GB, derived from [4] (13,076 experts x 1.97 MB). The B580 mirror would be tens of GB; that is my estimate, not a measurement. The A750 failed on one pinned allocation above ~3 GiB, while the installer says xe builds the mirror in chunks [4][7].

## 4. Reported tok/s (as published, not reproduced)

B580 rows come from PR #423, comment 5969166342 [9].

| Build / config | Hardware | Result | Source |
|---|---|---|---|
| IQ2_XS, 108-token code prompt | B580 12 GB, WSL2 Ubuntu 24.04, ~56 GiB RAM | decode 21.0 (prefill 30.4) | [9] |
| IQ2_XS, 2,102-token prompt | same | decode 22.6 (prefill 89.0) | [9] |
| Coder IQ1_M, tuned, 2,102-token | same | decode 17.3 (prefill 159.9) | [9] |
| IQ3_S, 11.5k/24.6k experts on-card | Arc Pro B70 32 GB, xe, 60 GB RAM | decode 30.5 prose / 40.8 code; 4K prefill 980-1,002 | [4] |
| IQ2_XS, all 512 experts | Arc Pro B65 32 GB, xe, 128 GB DDR4 | decode 40.4-41.3 (6 local patches); 43.5 official v0.1.40.2 | [10][11] |
| Coder IQ1_M, all experts in VRAM | 2x Arc Pro B60 24 GB, layer split | decode 56.6 | [3][12] |
| Coder IQ1_M, 4,042/12,288 experts mirrored | 1x Arc Pro B60 24 GB | decode 11.9 | [3] |
| IQ3_XXS, RAM arena (no streaming) | Arc A750 8 GB, i915, 64 GB RAM | decode ~10-15 | [4] |
| IQ3_S / IQ3_XXS (reference) | RTX 5070 12 GB, 64 GB RAM | 53 / 62 tok/s, short chat | [2] |

No B580 number exists for any 3-bit build.

## 5. OpenAI-compatible server

Yes. Base URL `http://127.0.0.1:8080/v1`; Anthropic at `/v1/messages`; Responses at `/v1/responses` [2]. The Intel port keeps "OpenAI and Anthropic APIs, streaming, tool calls, MCP and the web app all unchanged" [4]. Use the `--port` you set (8085 in the docs).

## 6. Local probes (this machine, read-only)

- B580 at `03:00.0`, `[8086:e20b]`, driver `xe`; `/dev/dri/renderD128` present.
- `llama-server --list-devices`: `Vulkan0: Intel(R) Arc(tm) B580 Graphics (BMG G21) (12216 MiB, 4156 MiB free)`. vulkaninfo: Mesa 26.2.2.
- Docker installed; user in the `docker` group. `ocloc` present; `icpx` and `sycl-ls` absent (not needed for the Docker route).
- /home: 1,022 GB free. RAM: 61 GiB total, 26 GiB used at probe time.
- The B580 has 4.1 GB VRAM free because another job holds it: `llama-bench` (PID 1102970) and a GPU bench lock (`bench/.gpu.lock`). I did not touch either. Wait for them before any B580 test.

## 7. Alternatives that do the same trick on Intel Arc

"The trick" means the GPU runs attention and dense layers while expert weights sit in CPU RAM, optionally with a GPU cache of hot experts.

| Engine | Arc backend | Expert offload | Arc evidence | Status |
|---|---|---|---|---|
| llama.cpp | Vulkan and SYCL | `--cpu-moe`, `--n-cpu-moe N`, `--moe-cache-mib N` | B580 SYCL 39 tok/s vs 16.4 Vulkan; B580 SYCL ~38 tok/s decode | upstream, active; best candidate |
| KoboldCpp | Vulkan (`--usevulkan`) | `--moecpu [N]` | none found | active (pushed 2026-10-12) |
| LM Studio | Vulkan runtime | "Force Model Expert Weights onto CPU" | none found | GUI app over llama.cpp |
| OpenVINO GenAI | GPU plugin, XMX only | `OFFLOAD_RATIO=N` (2026.3) | Arc 140V iGPU only | new, open bugs |
| IPEX-LLM FlashMoE | llama.cpp on SYCL | experts in CPU RAM | docs list B580 | archived (last push 2026-01-28) |
| KTransformers | PyTorch XPU | hybrid CPU/GPU MoE | docs list B580 | Beta, 2025 pins, no serving |

### llama.cpp (Vulkan and SYCL)

- Flags in master: `-cmoe/--cpu-moe` ("keep all Mixture of Experts (MoE) weights in the CPU"), `-ncmoe/--n-cpu-moe N`, and `--moe-cache-mib N` ("GPU cache size in MiB for the MoE experts kept in the CPU") [22][23]. The multi-GPU split is described in the flag help [22]; the PR for it, "support MoE cache over multiple GPUs" (#30112), is closed [27].
- The local tip build (`llama.cpp-vulkan-tip`, commit 358a420ec, `GGML_VULKAN=ON`, `GGML_SYCL=OFF`) prints all three flags in `--help` and lists the B580 as `Vulkan0` (local).
- Arc support: SYCL docs list the "Arc Series" [24]. A Vulkan log sample shows Intel graphics [25]. Arch users report Vulkan builds working on Arc A750 [52].
- B580 SYCL with `--cpu-moe -ngl 99 -c 8192`, Qwen3.6-35B-A3B UD-Q3_K_M (16.6 GB), i7-14700, 32 GB DDR5: ~39 tok/s, vs 16.4 tok/s on Vulkan. The Vulkan config is not stated [48].
- B580 SYCL with `-ngl 999 -ot "exps=CPU" --no-mmap -b 4096 -ub 4096`, Qwen3.6-35B-A3B Q4_K, EPYC host with 512 GB DDR4: prefill ~637 tok/s, decode ~38 tok/s, "memory-bandwidth-bound on the CPU experts" [47]. Different host from yours; the decode number is the one to compare.
- The Strata video, secondhand, calls llama.cpp's expert cache a draft PR [17]. Master now has `--moe-cache-mib` [22][23], so that gap has narrowed.
- Risks: Vulkan MUL_MAT_ID device loss on Arc A770 at small batch sizes, open [26]. SYCL bad output on Qwen3.6 35B A3B, open [29]. SYCL IQ3 code path still an open PR [28].
- Not tested by me on Flash-Next.

### KoboldCpp (Vulkan)

- README: `--usevulkan` for "AMD, Nvidia, Intel GPUs" [32]. The build table lists Vulkan, CUDA and ROCm (HIPBLAS); no SYCL [32].
- v1.97.4: "Allow MoE layers to be easily kept on CPU with `--moecpu (layercount)` flag. Using this flag without a number will keep all MoE layers on CPU" [31].
- No Arc numbers found.

### LM Studio (Vulkan runtime)

- Since 0.3.23: "Force Model Expert Weights onto CPU", described as "utilizing the same underlying technology as `llama.cpp`'s `--n-cpu-moe`" [30].
- A third-party explainer says Intel Arc runs on the Vulkan runtime [49]. A Reddit user reports the toggle is all-or-nothing [50].
- No Arc numbers found.

### OpenVINO GenAI (GPU plugin, XMX only)

- `OFFLOAD_RATIO` streams MoE expert weights through an LRU cache [44]. Shipped in OpenVINO 2026.3 [46].
- Needs XMX: `GPU_HW_MATMUL` must appear in `OPTIMIZATION_CAPABILITIES`, otherwise the property is a silent no-op [43][45].
- Open primary items in openvinotoolkit/openvino: #38663, ratio-100 fix [39]; #38545, slot-id buffer freed while kernels still read it [40].
- Also open: #37736, a second `generate()` hangs at ratio 75 on Arc 140V [41]; #38584, NaN output without mmap [42].
- Measured on Arc 140V (Lunar Lake iGPU, 32 GB unified): Qwen3.6-35B-A3B int4 went from 1.44 to 21.4 tok/s at ratio 20, by removing paging [46]. No B580 data point found.

### IPEX-LLM FlashMoE (archived)

- README: FlashMoE runs DeepSeek V3/R1 671B and Qwen3MoE 235B "with just 1 or 2 Intel Arc GPU (such as A770 or B580)" [35].
- Quickstart: needs 380 GB (DeepSeek) or 128 GB (Qwen3MoE 235B) of CPU memory and is "built on top of llama.cpp llama-cli" [37]. Portable zip verified on Arc B-series [38].
- Archived: "Patches to this project are no longer accepted by Intel" [35][36].

### KTransformers (Intel XPU, Beta)

- Intel Arc support since 2025-05-14 [33]. Hybrid MoE: "hot experts on GPU, cold experts on CPU" [33].
- Intel doc: "tested and developed using ... Intel Arc GPUs (such as A770 and B580)" [34]. Needs PyTorch XPU and IPEX-LLM 2025 pins [34].
- "Serving function is not supported on Intel GPU platform for now" [34]. No OpenAI-compatible server on Intel.

### Excluded (CUDA only)

- ninfer-offload runs Flash-Next with routed experts on CPU, but only on RTX 40-series and RTX 5090 cards. Its own numbers: 21.7-25.5 tok/s on an RTX 4060 Ti 16 GB with expert cache and MTP [51].

### Practical call for this box

1. Test first: `llama.cpp-vulkan-tip` on `Vulkan0` (the B580), with `--cpu-moe` or `--n-cpu-moe N` plus `--moe-cache-mib`. Load the Flash-Next IQ3 GGUF there. Not tested by me.
2. The 39 tok/s SYCL number came from a SYCL llama.cpp build [48]. This box's tip build is Vulkan-only, so SYCL would mean building one.
3. The Strata SYCL port is the only option with Flash-Next-specific expert caching. It is untested on B580.
4. Before any OpenVINO try, check `GPU_HW_MATMUL` on this card [43].

## Sources

[1] https://api.github.com/repos/Niko1221/Strata — Niko1221/Strata repo metadata (GitHub API)
[2] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/README.md — Strata README at a0116b2
[3] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/docs/INTEL_ARC.md — Strata docs/INTEL_ARC.md at a0116b2
[4] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/docs/INTEL.md — Strata docs/INTEL.md at a0116b2
[5] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/docs/MODELS.md — Strata docs/MODELS.md at a0116b2
[6] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/setup.py — Strata setup.py at a0116b2
[7] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/sycl/setup_intel.py — Strata sycl/setup_intel.py at a0116b2
[8] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/CMakeLists.txt — Strata CMakeLists.txt at a0116b2
[9] https://github.com/Niko1221/Strata/pull/423 — Strata PR #423 (Intel SYCL port)
[10] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/bench/results/2026-10-05-community-arc-b65/README.md — Strata bench: Arc Pro B65 (v0.1.40 + local patches)
[11] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/bench/results/2026-10-07-community-arc-b65-v01402/README.md — Strata bench: Arc Pro B65, v0.1.40.2 official
[12] https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/bench/results/2026-10-04-community-2x-arc-pro-b60/README.md — Strata bench: 2x Arc Pro B60
[13] https://github.com/Niko1221/Strata/pull/2060 — Strata PR #2060 (open): Vulkan image encoder, Linux AMD
[14] https://github.com/Niko1221/Strata/issues/2157 — Strata issue #2157 (open): 2x B70 DEVICE_LOST
[15] https://github.com/Niko1221/Strata/issues/1861 — Strata issue #1861 (open): tensor parallel on Arc B580
[16] https://github.com/Niko1221/Strata/issues/1552 — Strata issue #1552 (open): native Windows port for Arc B580
[17] https://youtu.be/m0VHx73SAG0 — YouTube: Strata 125B 6x faster than llama.cpp (transcript)
[18] https://huggingface.co/api/models/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/tree/ed59f92082b1e93c0e96d60a8b11aab089b52f09 — HF tree: ISTA-DASLab GGUF repo root @ed59f92
[19] https://huggingface.co/api/models/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/tree/ed59f92082b1e93c0e96d60a8b11aab089b52f09/IQ3_XXS — HF tree: IQ3_XXS shards @ed59f92
[20] https://huggingface.co/api/models/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/tree/ed59f92082b1e93c0e96d60a8b11aab089b52f09/IQ3_S — HF tree: IQ3_S shards @ed59f92
[21] https://huggingface.co/api/models/Qwen/Qwen3.8-Flash-Next — HF API: Qwen/Qwen3.8-Flash-Next
[22] https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/README.md — llama.cpp tools/server/README.md (master)
[23] https://raw.githubusercontent.com/ggml-org/llama.cpp/master/common/arg.cpp — llama.cpp common/arg.cpp (master)
[24] https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/backend/SYCL.md — llama.cpp docs/backend/SYCL.md (master)
[25] https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/build.md — llama.cpp docs/build.md (master)
[26] https://github.com/ggml-org/llama.cpp/issues/30240 — llama.cpp #30240 (open): Vulkan MUL_MAT_ID device lost on Arc A770
[27] https://github.com/ggml-org/llama.cpp/pull/30112 — llama.cpp #30112 (closed): MoE cache over multiple GPUs
[28] https://github.com/ggml-org/llama.cpp/pull/29107 — llama.cpp #29107 (open): sycl IQ3 code reorder
[29] https://github.com/ggml-org/llama.cpp/issues/28728 — llama.cpp #28728 (open): SYCL bad output on Qwen3.6 35B A3B
[30] https://lmstudio.ai/blog/lmstudio-v0.3.23 — LM Studio 0.3.23 blog: force MoE expert weights onto CPU
[31] https://github.com/LostRuins/koboldcpp/releases/tag/v1.97.4 — KoboldCpp v1.97.4 release notes (--moecpu)
[32] https://raw.githubusercontent.com/LostRuins/koboldcpp/concedo/README.md — KoboldCpp README (--usevulkan, build table)
[33] https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/README.md — KTransformers README
[34] https://raw.githubusercontent.com/kvcache-ai/ktransformers/main/doc/en/xpu.md — KTransformers doc/en/xpu.md (Intel GPU Beta)
[35] https://raw.githubusercontent.com/intel-analytics/ipex-llm/main/README.md — ipex-llm README (archived notice; FlashMoE)
[36] https://api.github.com/repos/intel-analytics/ipex-llm — ipex-llm repo metadata (API: archived=true)
[37] https://raw.githubusercontent.com/intel-analytics/ipex-llm/main/docs/mddocs/Quickstart/flashmoe_quickstart.md — ipex-llm FlashMoE quickstart
[38] https://raw.githubusercontent.com/intel-analytics/ipex-llm/main/docs/mddocs/Quickstart/llamacpp_portable_zip_gpu_quickstart.md — ipex-llm llama.cpp portable zip (Intel GPU)
[39] https://github.com/openvinotoolkit/openvino/pull/38663 — OpenVINO PR #38663 (open): OFFLOAD_RATIO=100 MoE
[40] https://github.com/openvinotoolkit/openvino/pull/38545 — OpenVINO PR #38545 (open): MoE offload slot-id buffer
[41] https://github.com/openvinotoolkit/openvino/issues/37736 — OpenVINO #37736: second generate() hangs with OFFLOAD_RATIO (Arc 140V)
[42] https://github.com/openvinotoolkit/openvino/issues/38584 — OpenVINO #38584: OFFLOAD_RATIO NaN without mmap
[43] https://huggingface.co/aweussom/LFM2-8B-A1B-int4-ov — HF card (3rd party): OFFLOAD_RATIO works only on XMX GPUs
[44] https://devnotes.page/posts/how-to-run-moe-models-on-openvino-with-disk-streaming — devnotes (3rd party): OpenVINO offload_ratio
[45] https://dev.to/tommy_leonhardsen_81d1f4e/your-intel-laptop-can-run-30b-models-now-no-nvidia-no-cloud-no-problem-2oc2 — dev.to (3rd party): OpenVINO MoE offload on Arc 140V
[46] https://huggingface.co/datasets/blairducrayoppat/openvino-arc140v-lunarlake — HF dataset (3rd party): OpenVINO offload numbers, Arc 140V
[47] https://raw.githubusercontent.com/davetha/llama-moe-hybrid-tuning/master/README.md — davetha/llama-moe-hybrid-tuning README (B580 SYCL, experts on CPU)
[48] https://medium.rebeauty-writing.com/tag/focus?action=show&id=5c3c357d3411 — B580 SYCL --cpu-moe 39 vs 16.4 tok/s (mirror of medium.com/@louisduran post)
[49] https://runaihome.com/blog/lm-studio-not-using-gpu-offload-slow-fix-2026 — runaihome (3rd party): LM Studio Vulkan runtime for AMD/Intel
[50] https://www.reddit.com/r/LocalLLaMA/comments/1mr7m2r/lm_studio_now_supports_llamacpp_cpu_offload_for — Reddit (user report): LM Studio CPU-MoE toggle all-or-nothing
[51] https://github.com/1872183316/ninfer-offload — ninfer-offload (CUDA-only Flash-Next offload; excluded)
[52] https://sbonner0.github.io/posts/intel-arc — sbonner0 (3rd party): Arc A750 on Arch, llama.cpp Vulkan/SYCL
