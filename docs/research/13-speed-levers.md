# 13 — Every speed lever for hybrid GPU+CPU MoE on the Arc B580, ranked

Engine: `engines/llama.cpp-vulkan-tip` @ `358a420ec` (and `engines/llama.cpp-sycl-tip`
@ same commit, both built). Everything below is read from that source tree and from
`--help` of those exact binaries. No model was loaded, no benchmark run (another agent
owns the GPU). `--help`/`--list-devices`/`llama-gguf r` only.

Deliverable of this file: the catalogue (§2–§4) + a ranked one-variable sweep whose
configs are in `bench/configs/levers/L*.env` (generated together with this file).
Run one config at a time with `bench/matrix-server.sh --cfg configs/levers/<f>.env`
(decode tok/s + TTFT) or `bench/matrix-bench.sh run --cfg …` where the flag is
llama-bench-compatible.

## 1. The two targets, as this engine sees them

| | Flash-Next IQ3_XXS (ISTA) | Qwen3.6-35B-A3B UD-Q4_K_XL (unsloth) |
|---|---|---|
| arch | `qwen4exp` (`src/models/qwen4exp.cpp`) | `qwen35moe` (`src/models/qwen35moe.cpp`) |
| blocks | 48 (`blk.0`–`blk.47`, read from the GGUF) | 48 (per the existing matrix config) |
| MoE | 512 experts/layer, 10 used + 1 shared | A3B, experts + shared expert |
| expert tensor names | `ffn_gate_up_exps`, `ffn_down_exps` (fused) | `ffn_gate_exps`/`ffn_up_exps`, `ffn_down_exps` |
| linear-attn layers | 36 Gated DeltaNet + 12 full QSA | hybrid linear-attn layers |
| n-gram table | `qwen4exp.ple.*` + `blk.1.ple_*` tensors (`qwen4exp.cpp:106-125`) | none |
| MTP/NextN | arch supports it (`qwen4exp.cpp:289-300`, `graph_mtp` at `:526`) — **not present in the local shard 1**; shard 2 not downloaded | arch supports it (`qwen35moe.cpp:106-138`) — **not present in the local GGUF** |
| local file | shard 1 of 2 present (4.77 GB), shard 2 (the ~28.8 GB table) missing | complete (22.4 GB) |

Both are read as *host* expert weights when `-ncmoe` puts them on CPU — that is the
precondition for the MoE cache (§2.1) and the whole point of this file.

Two facts that decide the ranking:
1. On a hybrid MoE, decode cost is dominated by re-reading the routed experts from
   RAM every token; prefill cost is dominated by the dense/attention matmuls that do
   fit in VRAM. So **expert residency and the hot-expert cache move decode; batch
   size threads and KV type move prefill.**
2. `--moe-cache-mib` (a GPU LRU of the CPU-resident experts) exists in this build. It
   is the lever with the highest ceiling that did not exist in `b11222`, and it is
   invisible to every generic llama.cpp tuning guide.

## 2. Levers that move decode (ranked by ceiling)

### 2.1 `--moe-cache-mib N` — hot-expert VRAM cache  ⭐ highest ceiling

```
--moe-cache-mib 2048          # MiB of expert slots on the GPU
```
* Source: `common/arg.cpp:2780`; impl `src/llama-moe-cache.cpp` (whole file);
  wired at `src/llama-context.cpp:551`, used in the graph at
  `src/llama-graph.cpp:1665` (`ggml_mul_mat_id(ctx0, moe_cache->get_experts(w), …)`)
  and `:2286`/`:2492-2525` (`build_moe_cache_slots`).
* What it does: for the layers whose experts are **host (CPU) weights**
  (`llama_moe_cache_is_host_weight`, `llama-moe-cache.cpp:145`), it keeps an LRU of
  `n_slots` expert copies in VRAM and replaces the `mul_mat_id` weight with a slot
  view. Decode then reads its ~11 routed experts from VRAM instead of RAM.
* Applies to: both models (both have MoE expert tensors that `-ncmoe`/`-cmoe` put on
  CPU). Backends: any device backend; on this box meant for Vulkan0 (and SYCL0).
* Direction: **decode ↑ substantially** — the ceiling is the fraction of routed
  experts that fit; `llama-moe-cache.cpp:591` logs per-layer hit rate, so the effect
  is measurable per run (`hits/misses` on stderr).
* Bypassed for large batches: `get_slot_map` returns `nullptr` when
  `n_tokens > 32` or `n_tokens*n_expert_used > n_slots`
  (`llama-moe-cache.cpp:470-478`, `max_batch = 32` at `:500`) — **prefill is
  unaffected**, by design ("large batches … would evict the experts used in
  generation").
* Cost: the cache bytes are allocated on the device at load
  (`llama-moe-cache.cpp:406-449`) and come out of the same VRAM budget as layers, and
  `pipeline_parallel` is force-disabled when it is on (`llama-context.cpp:523`).
* Risks: (a) load failure — `"failed to allocate the MoE cache buffers"`
  (`llama-moe-cache.cpp:410`) if the cache + the layer placement do not fit;
  (b) it does nothing unless experts are host weights — `--moe-cache-mib` with
  `-ngl 99 -ncmoe 0` is a no-op;
  (c) more cache means fewer GPU layers unless `-ncmoe` is raised to compensate.

### 2.2 `--n-cpu-moe N` / `--cpu-moe` — expert residency  ⭐ biggest known lever

```
-ncmoe 44          # first 44 layers' experts stay in CPU RAM
-cmoe              # all expert weights in CPU RAM
```
* Source: `common/arg.cpp:2770` (`-ncmoe`), `:2763` (`-cmoe`); expansion
  `common/common.h:1251` (`llm_add_n_cpu_ffn_overrides` → one regex per layer
  `blk\.<i>\.ffn_(up|down|gate|gate_up)_(ch|)exps`, buffer `CPU`).
* Applies to: both. Backends: placement is backend-agnostic; the GPU that receives
  the non-CPU expert layers is `Vulkan0` (or `SYCL0`).
* Direction: **lower N = decode ↑** (more experts read from VRAM) until VRAM is
  exhausted; each layer moved back to RAM costs a PCIe read of that layer's experts
  per token. Prefill also improves slightly via the dense/attention share.
* Risks: OOM or, worse, silent over-commit: at `-ngl 48`/64K KV the xe driver let the
  process reach `used=12377 MiB / 11605 MiB` with no error and then wedge
  (`research/10-test-matrix.md`). Probe headroom ≥ 300 MiB before trusting a row.

### 2.3 `-ot` — arbitrary tensor→buffer placement

```
-ot '\.ffn_(up|down|gate|gate_up)_(ch|)exps=CPU'      # == -cmoe
-ot 'blk\.4[67]\.ffn_down_exps=CPU'                   # narrow, one tensor
```
* Source: `common/arg.cpp:2757` (`parse_tensor_buffer_overrides`, `:252`); applied in
  `src/llama-model-loader.cpp:1235-1258`.
* **Order rule:** overrides are scanned in command-line order and the **first**
  `regex_search` hit wins (`llama-model-loader.cpp:1237-1258`, `break` on match).
  `matrix-server.sh` emits `-ncmoe` *before* `EXTRA`, so an `-ot` in `EXTRA` only
  wins for layers that `-ncmoe` did not already claim (i.e. `blk.<i>` with
  `i >= NCMOE`). Use `-ot` *instead of* `-ncmoe` when you want a non-prefix split.
* Buffer names are the registered backend buffer-type names (`CPU`, `Vulkan0`,
  `SYCL0`), from `ggml_backend_buft_name`.
* Direction: whatever the placement does; the value here is (a) non-contiguous splits,
  (b) pinning `token_embd`/`output`/`attn_*` explicitly to free VRAM for experts.
* Risk: same as §2.2, plus an upstream warning that CPU overrides + mmap is
  suboptimal (`llama-model-loader.cpp:1244-1249` — see §3.1).
* Note: `-ncffn`/`--n-cpu-ffn` (`arg.cpp:2790`) matches only the **dense** FFN regex
  `\.ffn_(up|down|gate)\.` (`common.h:1241`) and the shared-expert tensors are named
  `ffn_*_shexp`, so **`-ncffn` is a no-op for both of these archs**. Catalogued, not
  swept.

### 2.4 Speculation — `--spec-type` (10 variants in this build)

```
--spec-type none,draft-simple,draft-eagle3,draft-mtp,draft-dflash,draft-dspark,ngram-simple,ngram-map-k,ngram-map-k4v,ngram-mod,ngram-cache
```
Source: type table `common/speculative.cpp:75-83`; `arg.cpp:392` (help).
Two families:

**(a) Draft-model based** — `draft-simple`, `draft-eagle3`, `draft-mtp`,
`draft-dflash`, `draft-dspark`. All are gated on a draft context existing:
`add_config_if_enabled(DRAFT_MTP, params.draft.ctx_dft != nullptr)`
(`common/speculative.cpp:2709-2713`).

* **`draft-mtp` self-speculation (no `-md`)**: when `--spec-type draft-mtp` is given
  with no draft model, `common/speculative.cpp:2646-2665` creates the MTP draft
  context **on the target model's own weights** ("creating MTP draft context against
  the target model"), and `common/common.cpp:1268` documents `.shares_model =
  !has_draft // an MTP context runs on the weights of the main model`. It needs the
  GGUF to actually carry the NextN block: `hparams.n_layer_nextn` from
  `LLM_KV_NEXTN_PREDICT_LAYERS` (`src/llama-model.cpp:1380`), `qwen4exp.cpp:289-300`,
  `qwen35moe.cpp:132-138`. **Verify before sweeping:**
  `llama-gguf <file> r | grep -c nextn` → 0 means it cannot work.
* `-md <mtp.gguf> --spec-type draft-mtp` for a model file without the head. The
  auto-detect at `common/speculative.cpp:2373-2385` picks `draft-mtp` when the draft
  GGUF has `blk.<last>.nextn.eh_proj.weight`, and `dflash`/`dspark` from the `dflash`
  arch (Markov head ⇒ dspark). **No MTP GGUF is on this box** (unsloth
  `MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf` 2.60 GiB, ggml-org
  `mtp-…-Q4_0.gguf` 2.05 GiB): download needed.
* Direction: decode ↑ in proportion to acceptance length; prefill unchanged (the
  drafted block is verified in one target pass). Risk: startup assert (#29811),
  `--kv-unified`/`-np>1` incompatibility (#30368 in the older build — source still
  refuses nothing here, so keep `-np 1 --no-kv-unified`), extra VRAM for the MTP
  context, and the `n_embd` width must match the target's `n_embd_out`
  (`common/speculative.cpp:1435-1437` asserts).

**(b) n-gram (no draft model, no VRAM)** — these apply to **any** model and are the
only speculation available today.
* `ngram-simple` (`ngram_simple.size_n/.size_m/.min_hits`, `arg.cpp:4325-4351`),
  `ngram-map-k` (key-only; `arg.cpp:4356-4382`), `ngram-map-k4v`
  (`arg.cpp:4387-4413`), `ngram-mod` (`n_min`/`n_max`/`n_match`, `arg.cpp:4294-4320`),
  `ngram-cache` (`arg.cpp` `-lcs`/`-lcd` at `:1631`/`:1638`,
  impl `common/speculative.cpp:2126-2160`, draft length fixed at 8, `:2276`).
* `--spec-default` (`arg.cpp:4758`) = `ngram-mod` with `n_match=24, n_min=48,
  n_max=64`; the same option documents the author's own favourite untested preset
  (`ngram-map-k4v` size-n 8 / size-m 24 / min-hits 2).
* `ngram-cache` needs lookup-cache files built from a corpus
  (`llama-lookup-create`, binaries present) and passed as
  `-lcs <static.gguf> -lcd <dynamic.gguf>`. It starts empty if the file is absent
  (`arg.cpp:1631` only stores a path), so a missing file is a silent no-gain.
* Direction: decode ↑ on copy-heavy/repetitive/structured output (summarisation,
  translation, extraction, code), **~0 on free prose**. Cost is CPU work per token,
  which competes with the CPU expert matmuls; prefill unchanged.
* Risk: low. Worst case is a small decode loss plus CPU contention.

### 2.5 Speculation tuning knobs

| flag | file:line | note |
|---|---|---|
| `--spec-draft-n-max N` (default 3) | `arg.cpp:4161` | tokens drafted per step; too high wastes verification |
| `--spec-draft-n-min N` | `arg.cpp:4171` | early-exit threshold |
| `--spec-draft-p-min P` | `arg.cpp:4371` region | greedy minimum acceptance |
| `--spec-draft-p-split P` (0.10) | `arg.cpp:4368` region | explore/exploit split |
| `--spec-synth-len`, `--spec-synth-rates` | `arg.cpp:4357-4362` | synthetic acceptance model — **do not use for real measurements**, it fabricates acceptance |
| `-md`/`--spec-draft-model`, `-ngld`/`--spec-draft-ngl`, `-otd`, `-ncmoed`, `-ctkd`/`-ctvd`, `-Cd`, `-td`, `--spec-draft-device` | `arg.cpp:4125-4280` | draft head placement/threads/KV; the MTP head is small, put it on the GPU (`-ngld 99`) |
| `--spec-draft-sampling greedy\|probabilistic` | help | greedy = argmax draft |

## 3. Levers that move prefill (and free VRAM for §2)

### 3.1 Load mode — `-lm auto|none|mmap|mlock|mmap+mlock|dio`  (`arg.cpp:2694`)

`--no-mmap` no longer exists in this build; it is `-lm none`.
* With CPU expert overrides the loader itself warns:
  *"tensor overrides to CPU are used with mmap enabled - consider using --load-mode
  none for better performance"* (`llama-model-loader.cpp:1244-1249`). `-lm none` puts
  the host experts in anonymous RAM instead of the page cache, which stops the kernel
  from evicting exactly the expert pages decode needs.
* `mlock`/`mmap+mlock` pin the host experts; on a 61 GiB box with ~15 GiB already used
  and a 40+ GiB host-expert set this is a **real OOM risk** — measure `MemAvailable`
  first. Direction: decode stability ↑, load time ↑.
* `dio` (DirectIO) is for SSD-streamed weights; incompatible with the row-on-demand
  path of `--lazy-mode`. Risk: needs alignment/readahead care, untested here.
* No THP flag exists: THP is already `[always]` on this box and llama.cpp only issues
  `MADV_WILLNEED`/`POSIX_MADV_RANDOM` (`src/llama-mmap.cpp:508-523`, `:877`). Nothing
  to sweep; the OS setting is already the favourable one.

### 3.2 `--lazy-mode on|auto|off` (`arg.cpp` `-lzm`) — Flash-Next only

* `TENSOR_READ_LAZY` on the PLE/table tensors: `on` reads rows from disk on demand,
  `auto` only for tensors > 4 GiB. Applies to `qwen4exp` PLE (`qwen4exp.cpp:106-125`)
  and to nothing in `qwen35moe`.
* Direction: RAM ↓ (the 28.8 GB table stays out of RSS), prefill/decode neutral if the
  table is read sequentially; **decode ↓ if the table is touched every token** (SSD
  latency on the critical path). Requires mmap. Risk: exactly that.

### 3.3 Batches and threads

| lever | syntax | direction | risk |
|---|---|---|---|
| batch threads | `-tb N` (`arg.cpp`), `--poll-batch` | prefill ↑ with N, up to memory bandwidth | rayon 7900X: >12 threads spans both CCDs |
| threads | `-t N` (harness var `THREADS`) | CPU-expert matmul ↑ | contention with the GPU feeder |
| CCD pinning | `-t 12 -C 0x00000fff --cpu-strict 1` (`-Cr`, `--cpu-strict`, `arg.cpp`) | lower variance, avoids CCD-to-CCD hop | can starve the copy threads |
| priority/poll | `--prio -1..3`, `--poll 0..100` | decode jitter ↓ | `realtime` on a desktop is a foot-gun |
| ubatch | `-ub N` (512 default) | prefill ↑ larger ub; **smaller ub frees the compute buffer for expert layers** | ub > 512 needs `-b` ≥ ub |
| kv offload | `-kvo`/`--no-kv-offload` | `--no-kv-offload` frees VRAM for experts, decode ↓ (KV over PCIe) | mixed |
| op offload | `--no-op-offload` | control probe | small ops off-GPU are usually harmful |
| devices | `-dev Vulkan0` | **always** — `Vulkan1` is the Ryzen iGPU | never bench Vulkan1 |
| no host buffer | `--no-host` | "bypass host buffer allowing extra buffers" | low value, catalogued |
| `-fit on/-fitt/-fitc` | `arg.cpp` | auto-adjust unset args to fit | optimises for *fitting*, not for decode; subsumed by §2.2 |

### 3.4 KV cache

* Non-FA rejects quantized V outright (`src/llama-context.cpp:558`), so `-ctk/-ctv`
  quantized requires `-fa on`.
* Vulkan FA accepts `f32, f16, bf16, q8_0, q5_1, q5_0, q4_1, q4_0, iq4_nl` for K and V
  (`ggml/src/ggml-vulkan/ggml-vulkan.cpp:15511-15528`); the K/V bf16/non-bf16 pairing
  must match.
* Direction: `f16` = quality reference / most VRAM; `q8_0` ≈ no measurable loss;
  `q4_0` frees the most VRAM, which **allows a lower `-ncmoe`** — that is the real
  decode mechanism for a KV lever on a hybrid MoE (KV bytes are cheap, expert bytes
  are not). Risk: quality at `q4_0`, and Flash-Attention-only.
* `--swa-full` (`arg.cpp`) only applies to models with sliding-window layers; neither
  target arch is windowed (GDN/linear-attn + full QSA), so **it is a no-op here**.
  The prompt-reuse levers that do apply are `-ctxcp/--ctx-checkpoints`
  (server help:436) and `--cache-reuse N` help:611 — they move **TTFT**, not tok/s.
* `--kv-unified`/`-kvu` (server help:447) is on by default when `-np` is auto. It is
  incompatible with `draft-mtp` per #30368, so draft sweeps must add
  `--no-kv-unified -np 1`.

### 3.5 Backend/engine environment

Vulkan (all of these are read in `ggml/src/ggml-vulkan/ggml-vulkan.cpp`):

| env var | line | effect |
|---|---|---|
| `GGML_VK_FORCE_MMVQ=1` / `GGML_VK_DISABLE_MMVQ=1` | 4912-4914 | force/disable the quantized mat-vec path used by decode |
| `GGML_VK_ALLOW_SYSMEM_FALLBACK=1` | 4015 | let a >VRAM allocation spill to host-visible memory **instead of failing** — for Arc this is a plausible way to offload more layers than fit, at a bandwidth cliff |
| `GGML_VK_PREFER_HOST_MEMORY=1` | 4009 | prefer host memory for device buffers |
| `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM` | 4012 | opposite direction |
| `GGML_VK_DISABLE_COOPMAT2`, `…COOPMAT2_DECODE_VECTOR`, `…COOPMAT`, `…DOT2`, `…INTEGER_DOT_PRODUCT`, `…BFLOAT16`, `…F16`, `…OCP_FP4`, `…MULTI_ADD` | 4056-4094, 4996, 4502-4508 | kernel-path controls; `DISABLE_COOPMAT2_DECODE_VECTOR` is the interesting decode one (A/B it) |
| `GGML_VK_DISABLE_FUSION=1`, `GGML_VK_DISABLE_GRAPH_OPTIMIZE=1` | 4901, 4018 | disable graph fusion/optimisation (diagnostic baselines) |
| `GGML_VK_ASYNC_USE_TRANSFER_QUEUE=1`, `GGML_VK_DISABLE_ASYNC=1`, `GGML_VK_SERIALIZE_SUBMISSIONS=1` | 4882-4899 | async/queue behaviour — the expert-upload path is copy-heavy |
| `GGML_VK_ENABLE_MEMORY_PRIORITY=1` | 4094 | memory-priority extension |
| `GGML_VK_MAX_NODES_PER_SUBMIT=N`, `GGML_VK_SUBALLOCATION_BLOCK_SIZE=N`, `GGML_VK_FORCE_MAX_BUFFER_SIZE=N`, `GGML_VK_FORCE_MAX_ALLOCATION_SIZE=N` | 4259, 4206, 4196, 4186 | fragmentation/submission tuning for big graphs |
| `GGML_VK_DISABLE_DESCRIPTOR_REUSE=1`, `GGML_VK_DEBUG_MARKERS=1` | 4903, 5205 | diagnostics |

SYCL (`ggml/src/ggml-sycl/ggml-sycl.cpp:418-451`, defaults in brackets), needs
`set +u; source …/oneapi-env.sh; LD_LIBRARY_PATH=$DNNL` (already encoded in
`bench/configs/sycl-env.sh`), device name `SYCL0`:

| env var | default | effect |
|---|---|---|
| `GGML_SYCL_ENABLE_GRAPH` | **0** | SYCL graph capture — off by default, the first thing to try |
| `GGML_SYCL_ENABLE_FUSION` | 1 | kernel fusion |
| `GGML_SYCL_ENABLE_FLASH_ATTN` | 1 | FA path |
| `GGML_SYCL_FA_ALL_QUANTS`, `GGML_SYCL_FA_ONEDNN`, `GGML_SYCL_FA_ONEDNN_MIN_Q/MAX_KV`, `GGML_SYCL_ENABLE_MKL_FA` | 1 | oneDNN FA variants |
| `GGML_SYCL_FORCE_MMQ` | – | force the MMQ path (decode) |
| `GGML_SYCL_PRIORITIZE_DMMV` | 0 | prioritize dequant-mat-vec |
| `GGML_SYCL_MMVQ_WIDE` | 1 | wide MMVQ |
| `GGML_SYCL_SPARSE_FA` / `…_MARGIN` | 0 / 256 | sparse FA |
| `GGML_SYCL_ENABLE_OPT`, `…_VMM`, `…_ESIMD`, `…_HOST_PINNED_MEM` | 1 | misc; `HOST_PINNED_MEM` matters for a host-expert model |
| `GGML_SYCL_USE_ASYNC_MEM_OP`, `GGML_SYCL_UPLOAD_STAGING_SLOTS` | 1 / 4 | upload staging — relevant to expert uploads |
| `GGML_SYCL_MAX_STREAMS`, `GGML_SYCL_HOST_MEM_FALLBACK`, `GGML_SYCL_MEM_POOL_*`, `GGML_SYCL_USM_SYSTEM`, `GGML_SYCL_USE_LEVEL_ZERO_API` | – | memory-pool/stream tuning |

Known blockers for SYCL on this box (from `research/02`, still open upstream):
bad output on B580 for `qwen35moe` (#28728), TP on SYCL (#28100), slow SYCL MTP
(#27373). **Measure SYCL on the dense model first**; treat the two MoE targets as
"expected broken" until a SYCL row proves otherwise.

## 4. Ranked one-variable sweep

Configs: `bench/configs/levers/L<nn>-<slug>.{fn,q35}.env`, `fn` = Flash-Next
IQ3_XXS, `q35` = Qwen3.6-35B-A3B. Each file is `L00-*-base.env` with **exactly one**
variable changed (the generator asserts this). Baselines: `.fn` = `-ngl 99 -ncmoe 44
-c 65536 q8_0 KV -t 16`; `.q35` = `-ngl 99 -ncmoe 48 -c 65536 q8_0 KV -t 16`.

Every row is measured with `matrix-server.sh` (decode tok/s at 4K and 32K + TTFT);
spec rows **must** be server rows — `--spec-*`/`-md` are not registered for
`llama-bench`. Keep `MemAvailable ≥ 48 GiB` before the `.fn` loads and compare only
`free=`-similar, same `clean`/`game-open` rows.

| # | config | change vs base | expected direction | why it is ranked here |
|---|---|---|---|---|
| L01 | `L01-moe-cache2048` | `--moe-cache-mib 2048` | decode ↑↑ | only new VRAM-resident expert path; hit rate logged |
| L02 | `L02-moe-cache6144` | `--moe-cache-mib 6144` | decode ↑↑ (if it fits) | larger cache; needs ncmoe raised to make room |
| L03 | `L03-ncmoe-m2` | `-ncmoe` −2 | decode ↑ | one more expert layer on GPU |
| L04 | `L04-ncmoe-m4` | `-ncmoe` −4 | decode ↑ | the actual placement edge; watch headroom |
| L05 | `L05-ncmoe-p4` | `-ncmoe` +4 | decode ↓ (control) | proves the direction and makes room for L02 |
| L06 | `L06-cmoe-cache4096` | `-cmoe` + `--moe-cache-mib 4096` | decode ?, VRAM ↓ | all experts in RAM, max cache: the "RAM experts, VRAM hot set" regime |
| L07 | `L07-ot-exps-cpu` | `-ot '\\.ffn_(up\|down\|gate\|gate_up)_(ch\|)exps=CPU'` | == `-cmoe` | documents the `-ot` order rule with a known-answer row |
| L08 | `L08-load-none` | `-lm none` | decode ↑ / RSS ↑ | upstream's own advice for CPU-override tensors |
| L09 | `L09-load-mmap-mlock` | `-lm mmap+mlock` | decode stability ↑ | only with `MemAvailable` headroom |
| L10 | `L10-lazy-on` | `-lzm on` | RAM ↓, decode ↓? | `.fn` only; the 28.8 GB table |
| L11 | `L11-spec-mtp-self` | `--spec-type draft-mtp` | decode ↑↑ if the head exists | `.fn` only; **verify `nextn` tensors first** |
| L12 | `L12-spec-mtp-md` | `-md <mtp.gguf> --spec-type draft-mtp` | decode ↑↑ | `.fn` only; **needs the 2.6 GiB MTP download** |
| L13 | `L13-spec-mtp-nmax6` | L12 + `--spec-draft-n-max 6` | decode ↑ if acceptance holds | tune after L12 |
| L14 | `L14-spec-ngram-mod` | `--spec-type ngram-mod` | decode ↑ on copy-heavy text | works on both, today, no extra weights |
| L15 | `L15-spec-ngram-mod-nmatch32` | `+ --spec-ngram-mod-n-match 32` | ± | lookup length |
| L16 | `L16-spec-ngram-mod-nmax32` | `+ --spec-ngram-mod-n-max 32` | ± | draft length |
| L17 | `L17-spec-ngram-simple` | `--spec-type ngram-simple` | ± | cheapest variant |
| L18 | `L18-spec-ngram-map-k` | `--spec-type ngram-map-k` | ± | key-only map |
| L19 | `L19-spec-ngram-map-k4v` | `--spec-type ngram-map-k4v` | ± | the author's commented preset target |
| L20 | `L20-spec-ngram-cache` | `--spec-type ngram-cache -lcs <cache>` | decode ↑↑ on summarise/translate | needs the cache built (`llama-lookup-create`) |
| L21 | `L21-spec-default` | `--spec-default` | == ngram-mod defaults | sanity row for the shorthand |
| L22 | `L22-threads12` | `-t 12 -tb 12` | prefill ↓/±, variance ↓ | one CCD |
| L23 | `L23-threads24` | `-t 24 -tb 24` | prefill ↑ | both CCDs, 2 SMT threads each |
| L24 | `L24-pin-ccd0` | `-t 12 -C 0x00000fff --cpu-strict 1` | variance ↓ | strict placement |
| L25 | `L25-ub256` | `-ub 256` | prefill ↓, VRAM ↓ | smaller compute buffer ⇒ room for experts |
| L26 | `L26-ub1024` | `-ub 1024` | prefill ↑ | if VRAM allows |
| L27 | `L27-kv-f16` | `KV=f16` | VRAM ↑, decode = | quality reference |
| L28 | `L28-kv-q4_0` | `KV=q4_0` | VRAM ↓ ⇒ ncmoe ↓ | the KV lever that pays off |
| L29 | `L29-no-kv-unified` | `--no-kv-unified` | None alone | prerequisite for L11-L13 |
| L30 | `L30-no-op-offload` | `--no-op-offload` | ± | control probe |
| L31 | `L31-np2` | `-np 2` | prefill ↑ under concurrency, decode ↓ | shows the batching trade; breaks `draft-mtp` |
| L32 | `L32-env-vk-mmvq` | `ENVSH=…/env-vk-mmvq.sh` (`GGML_VK_FORCE_MMVQ=1`) | decode ± | kills the mmvq autotune result |
| L33 | `L33-env-vk-sysmem` | `ENVSH=…/env-vk-sysmem.sh` (`ALLOW_SYSMEM_FALLBACK` + `PREFER_HOST_MEMORY`) | decode ↓, fits more | the "oversubscribe VRAM" experiment |
| L34 | `L34-engine-sycl` | `BINDIR` = sycl-tip + `ENVSH=configs/sycl-env.sh` + `DEVICE_NAME=SYCL0` | ? | second backend, same flags |
| L35 | `L35-env-sycl-graph` | L34 + `GGML_SYCL_ENABLE_GRAPH=1` | decode ↑? | graph capture is off by default |

Order of execution (cheapest decisive rows first): L01 → L03 → L04 → L08 → L10 →
L14 → L20 → L11 (after verifying `nextn`) → L28 → L22/L23 → L25/L26 → L29 → L34/L35 →
L02/L06/L12/L13 as the VRAM/tuning follow-ups. Stop adding a lever when the row it
changes is within the noise of `REPS=3` on a `clean` GPU.

### Configs in this file that need a prerequisite

* `L11`/`L12`/`L13`: the MTP head. Check first:
  `engines/llama.cpp-vulkan-tip/build/bin/llama-gguf <fn.gguf> r | grep -c nextn`
  (currently **0** for the local shard 1; shard 2 is not downloaded, so the head may
  or may not be in it — do not assume). For `L12` the file itself must be downloaded.
* `L20`: `-lcs /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/levers/ngram-cache.gguf`
  does not exist yet; build it with `llama-lookup-create -m <model> -f <corpus.txt> -o <file>`.
* `L34`/`L35`: oneAPI env must be sourced in the same shell (the `ENVSH` file does it).

## 5. Catalogued, deliberately not swept

| lever | why not |
|---|---|
| `-ncffn N` | no-op on both archs: dense-only regex `common.h:1241` vs `ffn_*_shexp` names |
| `--swa-full` | neither arch has SWA layers |
| `-fit on/-fitt/-fitc` | optimises for fitting, not for decode; the `-ncmoe` sweep is the real placement control |
| `-fa off` | Vulkan FA is the fast path and the only way to a quantized V cache (`llama-context.cpp:558`) |
| `--no-host` | "bypass host buffer" — small, unmeasurable on this workload |
| `-ctxcp`, `--cache-reuse`, `-cram` | TTFT/prefix-reuse levers, not tok/s |
| `--numa isolate/distribute` | single socket, 2 CCDs; `-C`/`--cpu-strict` covers it |
| `--prio`/`--poll`/`--poll-batch` | jitter, not throughput; add only if the decode stddev is too wide |
| `draft-eagle3`, `draft-dflash`, `draft-dspark` | no compatible draft GGUF on this box (the `dflash` arch is a separate model file) |
| `--spec-synth-len/-rates` | **fabricates** acceptance — never for measured comparisons |
| remaining `GGML_VK_*` / `GGML_SYCL_*` | catalogued in §3.5; add individually only if L32/L33/L35 show the backend is the bottleneck |

## 6. Honest gaps in this file

* Nothing measured — no model loaded, no benchmark run (as instructed).
* The local Flash-Next file is **shard 1 of 2**; everything about the PLE table and
  the MTP block is read from the arch source, not from that file. Re-verify against
  shard 2 when it lands.
* `qwen35moe.block_count = 48` is taken from the existing matrix config, not read from
  the GGUF (the metadata reader here prints keys only).
* The `-ot` order rule (§2.3) and the `-moe-cache-mib` bypass threshold (§2.1) are
  read from source; no runtime row confirms them yet — L06/L07 exist to be that row.
* `--moe-cache-mib` hit-rate numbers, the MTP acceptance length, and the SYCL
  correctness question are all unanswered until the GPU is free.
