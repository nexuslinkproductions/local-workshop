# BRIEF-46 Workstream A — Per-layer / per-tensor KV cache device placement (external survey)

Scope: does ANY engine expose per-layer or per-tensor KV cache device placement (some layers' KV in host RAM, others on GPU), or a host-RAM KV tier with GPU-side attention? Desk research + on-disk source reading only. No GPU jobs run, no engine source modified.

---

## 1. On-disk engine verdicts

### engines/ik_llama.cpp (Intel ik fork, HEAD `2959611`)

Verdict: **no per-layer KV device placement.** Single global bool, per-layer KV *quant* yes, per-layer KV *device* no.

- No `src/llama-kv-cache.cpp`; cache lives in `src/llama.cpp`. `llama_kv_cache_init` at `src/llama.cpp:1228-1243` takes one `bool offload` (line 1235) used for all layers.
- Per-layer buffer selection: `src/llama.cpp:1462` — `offload ? ctx_map.at(model.buft_layer[i].buft) : cache.ctxs.front()` (and `src/llama.cpp:1573`). `buft_layer[i]` is decided **only** by `-ngl` / device splits: CPU for non-offloaded layers at `src/llama.cpp:4676`, GPU assignment at `src/llama.cpp:4979` and `src/llama.cpp:5002-5005`. Nothing per-layer beyond that.
- Call site: `src/llama.cpp:9778` passes `cparams.offload_kqv` (global).
- `-ot/--override-tensor` cannot reach KV: overrides are regex-matched **only against GGUF-file weight tensors at load time** in `src/llama-load-tensors.cpp:275-281` and `src/llama-load-tensors.cpp:476-478` (`get_context_for_tensor`). The `cache_k_l%d` / `cache_v_l%d` tensors do not exist in the file — they are created later at context init from `buft_layer`/`dev_layer` only. The override flag's only KV-adjacent use is disabling pipeline parallelism: `src/llama.cpp:9921`, `src/llama.cpp:10023-10026`.
- ik *does* have per-layer KV **quant**: `-ctk-first/--cache-type-k-first TYPE,N` (also `-ctk-last`, `-ctv-first`, `-ctv-last`), parsed in `common/common.cpp:2046-2068`, help at `common/common.cpp:3532-3534`, applied per layer in `src/llama.cpp:1575-1596`. Also `--swa-compress` (per-layer SWA row compaction, `src/llama.cpp:1266-1301`) and `-nkvo/--no-kv-offload` (`common/common.cpp:2027,3528`) — both global, not per-layer.
- `split_cache` KV replication across multiple GPUs (`src/llama.cpp:1319-1335`) is multi-device replication, not CPU/GPU placement.

### engines/llama.cpp-prism-tip (PrismML fork, HEAD `e8fd209c9`)

Verdict: **no per-layer KV device placement.** Standard upstream layout.

- `src/llama-kv-cache.cpp:65-71` ctor takes one `offload` bool; `src/llama-kv-cache.cpp:216-221`: `if (offload) { auto * dev = model.dev_layer(il); buft = ggml_backend_dev_buffer_type(dev); }`.
- `dev_layer` set only from `-ngl`/splits: `src/llama-model.cpp:1637-1639`, getter `src/llama-model.cpp:2434-2435`.
- `-nkvo` exists (`common/arg.cpp:2404`), global only. No fork-specific KV placement flag found.

### engines/llama.cpp-vulkan-tip (HEAD `358a420ec` — same upstream commit as the SYCL tip referenced by the brief)

Verdict: **no per-layer KV device placement.** Quick check confirms the same code path the SYCL tip runs.

- `src/llama-kv-cache.cpp:216-221` (same `offload → dev_layer(il)` logic as prism); `dev_layer` from `-ngl` only: `src/llama-model.cpp:1670-1676`, `src/llama-model.cpp:2657-2659`.
- ISWA (Gemma 4 path): one `offload` bool threaded into **both** sub-caches — `src/llama-kv-cache-iswa.cpp:95-107` (`kv_base` with `filter_base` = non-SWA layers, `kv_swa` with `filter_swa` = SWA layers; filters at `src/llama-kv-cache-iswa.cpp:51-64`). Confirms the brief: no split between global and SWA layers.
- Upstream KV quant is global only (`-ctk/-ctv`, `common/arg.cpp:2440`); the per-layer `TYPE,N` variants are ik-only.

---

## 2. Upstream llama.cpp PR / issue survey

- **No PR or issue extends `-ot/--override-tensor` to runtime KV tensors** (`cache_k_l%d` / `cache_v_l%d`): not found. Searches: `repo:ggml-org/llama.cpp KV cache offload per layer override tensor cache_k cache_v` (1 hit), `repo:ggml-org/llama.cpp per-layer KV cache device placement CPU GPU hybrid` (86 hits, none on-topic), `repo:ggml-org/llama.cpp override-tensor KV cache tensor placement device` (26 hits, none on-topic).
- **PR #24566** ("EXPERIMENT: meta: key external view cache by backend context", open) is a ggml **meta-backend split-buffer** fix for multi-GPU logs — not KV placement.
- **Issue #23855** "Allow 'spill-over KV cache', 'KV-cache GPUs' and 'MoE GPUs'" — exactly this feature request (KV on separate GPUs or RAM while compute stays on fast GPUs; proposed `--kv-spill` / `--kv-device`). **Closed 2026-08-04 as `not_planned`** (stale bot), labels `enhancement, stale`. No PR closed it. https://github.com/ggml-org/llama.cpp/issues/23855
- **Issue #28115** proves the flag is a single global bool in practice: with `--no-kv-offload`, the MTP draft-model KV is *also* forced to RAM and copied to VRAM every draft step (`llama_kv_cache: CPU KV buffer size = 2048.00 MiB # MTP draft (the bug)`); there is no way to keep just the draft KV on GPU. https://github.com/ggml-org/llama.cpp/issues/28115
- Only indirect per-layer effect upstream: with `-ngl < n_layer`, layers beyond `-ngl` have `dev_layer = CPU`, so their **KV also lands on CPU** — but the weights move with it (contiguous ranges), which is the opposite of what Workstream A wants (weights on GPU, global-layer KV on RAM).

---

## 3. Forks / other engines — hybrid-KV table

| Engine | Mechanism | Granularity | Host KV + GPU attention? | Citation |
|---|---|---|---|---|
| **GenerelSchwerz/llama.cpp** (`llama/main` @ `a6225cd`, also `llama/dev`, `beellama/main`, `moe-cache`) | `--no-kv-offload --kv-gpu-layers N`: first N independently-owned attention-KV layers stay device-resident, rest on host | **per layer (count of first N)** | partial: GPU-resident layers read on GPU; host layers' attention still computed on accelerator when the memory layout supports partial KV | code below; wiki: https://github.com/GenerelSchwerz/llama.cpp/wiki/Partial-Target-KV-Residency (design PR 28) |
| same fork | `--no-kv-offload --kv-cpu-pinned`: all KV in accelerator-visible **pinned host** memory; attention compute stays on accelerator | all layers | **yes, by design** ("use pinned host buffers for CPU-resident KV cache storage when available; with operation offload enabled, attention compute can remain on the accelerator") | https://github.com/GenerelSchwerz/llama.cpp/wiki/Pinned-Host-KV (design PR 25) |
| upstream / ik / prism / vulkan / sycl | single global `offload_kqv` bool; per-layer device follows `-ngl` | global | only all-or-nothing (`-nkvo`) | §1 citations |
| vLLM | `OffloadingConnector` (`CPUOffloadingSpec` / `TieringOffloadingSpec`): completed GPU KV **blocks** copied to pinned host RAM, promoted back on demand, async DMA transfers | per block (64-token blocks), all layers | attention runs on GPU after promotion; CUDA/ROCm/XPU only, GQA/MHA only (MLA unsupported) | https://docs.vllm.ai/en/stable/features/kv_offloading_usage/ ; `--kv-offloading-backend native --kv-offloading-size 64` in https://docs.vultr.com/public/doc-assets/pdfs/collection_item/inference-cookbook-rocm-optimization-kv-cache-offloading.pdf |
| LMCache (vLLM connector) | pinned CPU RAM tier (chunk 256 tokens, LRU), + disk/remote tiers | per chunk, all layers | yes (via vLLM promotion) | https://docs.lmcache.ai/kv_cache/storage_backends/cpu_ram.html |
| SGLang | HiCache: L1 GPU / L2 host / L3 storage radix tiers; `--enable-hierarchical-cache`, `--hicache-ratio`, `--hicache-size` | per page, all layers | yes (pages promoted to GPU for compute) | https://github.com/sgl-project/sglang/blob/main/docs/docs/advanced_features/hicache_best_practices.mdx |
| ktransformers | YAML injection places **modules** per layer-range on CPU/GPU (experts CPU, attention+KV GPU); balance-serve `kvc2` adds GPU-CPU-Disk 3-tier KV storage (`gpu_only: false`, `cpu_memory_size_GB`) | module-level in principle; KV tier is page/capacity | no — attention op and its KV move together | https://deepwiki.com/kvcache-ai/ktransformers/5.3-training-configuration , https://deepwiki.com/kvcache-ai/ktransformers/6.3-multi-gpu-inference , https://github.com/kvcache-ai/ktransformers/blob/main/doc/en/prefix_cache.md |
| TensorRT-LLM | `KvCacheConfig(host_cache_size=…)` / `kv_cache_host_memory_bytes`: evicted blocks copied to host RAM, onboarded when reused | per block, all layers | yes (block promoted back to GPU before reuse) | https://nvidia.github.io/TensorRT-LLM/advanced/kv-cache-reuse.html ; https://nvidia.github.io/TensorRT-LLM/1.3.0rc26/examples/llm_kv_cache_offloading.html |
| kvmem/kvmem-llama.cpp | bounded GPU KV working set + host store + query-based retrieval; "reselection transfers only blocks that changed" | page/capacity tier, all layers | partial (recall selected pages to GPU) | https://github.com/kvmem/kvmem-llama.cpp (README) |
| Coryyi/llama-cpp-kvmem | tiered KV paging prototype: `--tiered-kv`, `--tiered-kv-pin/hot/page/recall/query` | page tier, all layers | partial (selective recall) | https://github.com/Coryyi/llama-cpp-kvmem (README) |
| ExLlamaV2 | quantized caches only (FP16/Q8/Q6/Q4) | cache-wide precision | not found | https://github.com/turboderp-org/exllamav2/blob/master/doc/qcache_eval.md |
| LMDeploy | per-layer KV placement / host-KV tier | — | **not found** | — |

### GenerelSchwerz fork — exact code evidence (shallow clone, branch `llama/main`, HEAD `a6225cd`)

- `--kv-gpu-layers N`: `common/arg.cpp:2450-2461` — "with --no-kv-offload, keep the **first N** independently owned attention KV layers device-resident **for standard and direct hybrid caches**. Unsupported specialized caches ignore this option". Params: `src/llama-cparams.h:19`, `include/llama.h:368`.
- Placement decision: `src/llama-kv-cache.cpp:290` — `const bool layer_offload = offload || n_gpu_resident < placement.gpu_resident_layers;` then GPU buft if `layer_offload` else host buft (`src/llama-kv-cache.cpp:291-301`); host buft can be pinned: `llama_kv_cache_get_host_buft()` at `src/llama-kv-cache.cpp:21-36` (`ggml_backend_dev_host_buffer_type`). Startup log: `src/llama-kv-cache.cpp:342-345`.
- Support gate: `src/llama-context.cpp:407-412` — warns "partial GPU KV residency is not supported for this memory layout; ignoring kv_gpu-layers" unless `memory->get_supports_partial_kv()`.
- Support matrix: `llama_kv_cache` → true (`src/llama-kv-cache.h:20,137`); `llama_memory_hybrid` → true (`src/llama-memory-hybrid.h:64-66`); **`llama_kv_cache_iswa` (Gemma-3n/Gemma-4 SWA path) → NOT supported**: class derives `llama_memory_i` without override (`src/llama-kv-cache-iswa.h:14`), base default false (`src/llama-memory.h:111-113`), and every ISWA instantiation receives `specialized_placement` with `gpu_resident_layers = 0` forced (`src/llama-model.cpp:2285-2286`, instantiations at `2492/2508`, `2534/2550`, `2724/2740`, `2742/2758`).
- `--kv-cpu-pinned`: `common/arg.cpp:2424-2431`; attention-compute separation: `src/llama-context.cpp:125` — `cparams.offload_attn_compute = params.offload_kqv || (params.op_offload && params.kv_cpu_pinned);` applied in the graph at `src/llama-graph.cpp:2736-2740`. Also `--spec-draft-kv-gpu-layers` (`common/arg.cpp:4156-4164`) for independent draft-KV residency.
- Caveats: fork is CUDA-first ("CUDA is the most extensively validated path"); SYCL is untested there. A SYCL host buffer type **does exist** in the toolchain (`ggml/src/ggml-sycl/ggml-sycl.cpp:1790` `ggml_backend_sycl_host_buffer_type_for_device` in `engines/llama.cpp-sycl-tip-2026.1`), so a SYCL port of `--kv-cpu-pinned` is plausible — not verified.

---

## 4. Direct answer

**Is per-layer KV placement available off the shelf? No — not on the SYCL/long-context path we need.**

- Upstream llama.cpp and all three on-disk forks (ik, prism, vulkan) expose exactly one global switch, `offload_kqv` (`-nkvo/--no-kv-offload`), threaded identically into both the global (`kv_base`) and SWA (`kv_swa`) caches. Per-layer *KV quant* exists (ik `-ctk-first/-ctk-last/...`); per-layer *KV device* does not. `-ot` cannot target `cache_k_l*`/`cache_v_l*` in any engine or PR found.
- **Closest existing mechanism, ranked:**
  1. **GenerelSchwerz/llama.cpp `llama/main` (or `llama/dev`): `--no-kv-offload --kv-gpu-layers N`** — the only found implementation of a true per-layer KV device split (first N owned attention-KV layers on GPU, rest host). **Blocker for Gemma 4:** the feature is explicitly disabled for ISWA (sliding-window) caches — Gemma 4 is ISWA, so `--kv-gpu-layers` is inert there (`specialized_placement.gpu_resident_layers = 0`). Works today for non-SWA dense models.
  2. **Same fork: `--no-kv-offload --kv-cpu-pinned`** — all-KV-in-pinned-host-RAM with attention compute still on the accelerator; composes with SWA/ISWA caches and is the closest thing to the Workstream-A target, but it is all-layers, not "8 global layers in RAM, SWA KV on GPU".
  3. Upstream's implicit split (`-ngl < n_layer` puts tail layers' weights *and* KV on CPU) — wrong direction for this goal.
  4. vLLM/LMCache/SGLang/TRT-LLM/kvmem all provide host-RAM KV tiers, but per **block/page** (capacity tier), never per layer, and none run SYCL/Gemma-4 in this lab.
- Upstream declined the exact feature request (issue #23855, closed `not_planned`), so no roadmap support from ggml-org.
- Practical consequence for Workstream A: on SYCL today the options are (a) global `-nkvo` (all KV in RAM, attention on GPU — slow at deep context), (b) `-ngl` trade (weights+KV together), (c) port the fork's split logic into the SYCL tip (the fork shows the shape: a placement plan + per-layer buft choice in `llama_kv_cache`), or (d) KV quant/compression instead.
