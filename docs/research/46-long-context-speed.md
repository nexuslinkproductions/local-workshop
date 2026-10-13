# 46 — Sustainable fast tokens from 4K to 256K (Chief, Gemma 4 12B QAT, B580)

Brief: `research/BRIEF-46-long-context-speed.md`. Started 13:45 by lead `deleg_c5b308f1` (interrupted 14:23, no report); resumed by this lead.
Status: IN PROGRESS. Written incrementally. Nothing applied to `serve/config.yaml` or the Chief profile.
Engine: `engines/llama.cpp-sycl-tip` @ 358a420ec, `build/bin`. Note: `engines/llama.cpp-sycl-dev` named in the brief does not exist on disk.

## 0. Recovered from the previous lead (sources: `~/.hermes/cache/delegation/live/deleg_c5b308f1/task-0.log`, `research/46-notes-A-external.md`, `research/46-notes-B-sparse-attention.md`)

### WS-A: per-layer KV placement (desk + source reading, verified by lead via grep)
- **Not available off the shelf on SYCL.** SYCL tip, Vulkan tip, prism-tip, ik_llama.cpp: one global `offload_kqv` bool (`-nkvo`). In `llama-kv-cache.cpp:216-221` KV follows `model.dev_layer(il)` (set by `-ngl` only). Gemma 4 = `llama_kv_cache_iswa` = two `llama_kv_cache` objects (`kv_base` global layers, `kv_swa` SWA layers, `llama-kv-cache-iswa.cpp:95-107`) that get the same `offload` bool. `-ot` cannot reach `cache_k_l*`/`cache_v_l*` (ik: `llama-load-tensors.cpp:275-281`).
- Upstream issue #23855 (spill-over KV / KV-device) closed `not_planned`. Issue #28115: with `-nkvo` the MTP draft KV is also forced to RAM.
- Only true per-layer KV device split found: **GenerelSchwerz/llama.cpp** `--no-kv-offload --kv-gpu-layers N` (first N layers on GPU), plus `--kv-cpu-pinned` (all KV in pinned host RAM, attention still computed on accelerator, `llama-context.cpp:125`). **Both inert for ISWA** (`specialized_placement.gpu_resident_layers = 0`, `llama-model.cpp:2285`). CUDA-first, SYCL untested. A SYCL host buffer type exists (`ggml-sycl.cpp:1790`).
- Block/page host KV tiers exist in vLLM, LMCache, SGLang HiCache, TRT-LLM, kvmem-llama.cpp (CUDA); none per-layer, none SYCL/Gemma.
- Patch size (previous lead did not finish this estimate; mine in §3).

### WS-B: sparse / retrieval attention
- Gemma 4 GGUF geometry (measured from header): 48 layers, 8 global (every 6th: 5,11,...,47; 1 KV head, key/value len 512), 40 SWA (8 KV heads, len 256, window 1024), no shared KV, no attn softcap key.
- **MSA/DSA cache classes are arch-gated** (MiniMax-M3, GLM-DSA, DeepSeek-3.2/4, HY-V4, DOTS3NOTE, GLM5-Next, Qwen4exp) and need trained indexer tensors Gemma lacks. Not reusable as-is; selection mechanics (pool, top-k, gather, sparse FA) are reusable.
- **`GGML_SYCL_SPARSE_FA` exists (default 0)**: `ggml/src/ggml-sycl/fattn-sparse.cpp` (lead verified file present, 9750 B). Needs `n_kv_max > 0` set on the FA node, `max_bias == 0`, no logit softcap, decode only (`Q->ne[1]==1`); it compacts finite mask entries, gathers K/V rows, runs FA over them. **Gemma 4 passes no `n_kv_max`** (`gemma4.cpp:274-279` goes through `build_attn`), and its global-layer mask is dense, so setting the env var alone does nothing.
- Training-free candidates that fit: Quest-style page min/max on the 8 global layers (2-4 wk est.), KVMem Mean-K (CUDA, port weeks-months). Not recommended: DSA/MSA retrofit (training), MagicPIG, H2O/SnapKV, StreamingLLM on global layers. No Gemma-family sparse quality result exists.
- **Premise-changing napkin math** (from GGUF metadata): windowed SWA cache + global layers at 256K = 1.1 GiB (q4_0) / 2.1 GiB (q8_0) / 4 GiB (f16). Global KV bytes read per decode token at 64K = 0.7-2.4 ms; observed depth penalty 31 -> 19.6 t/s (32.3 -> 51.0 ms) = +18.8 ms. So the penalty is mostly **kernel compute that scales with n_kv** (dequant, mask, FA), not KV bandwidth, and parking global KV in RAM would not remove it (it would add PCIe traffic). The 256K VRAM squeeze is dominated by the n_ctx-linear compute buffer (681-1185 MiB) and weights, not KV (WS1 table in `research/34-chief-256k.md`).
- Decision rule from B: run the R0 timing-only ceiling before building anything; if restricting global layers to 2K gives < 20 % decode gain, sparse retrieval is not worth it for speed.

### WS-C: MTP at long context (lead verified in source)
- `common/speculative.cpp:2617-2618`: `cparams.n_ctx = llama_n_ctx(ctx_tgt)` — draft context hard-sized to target ctx, no flag. At 262144 draft adds ~1 GiB compute buffers (free 81 MiB at ub512, 431 MiB at ub128/q4 draft; `research/34`). A smaller draft ctx needs a one-line patch (plus an MTP-specific cap on positions; to be checked, see §3).

### Existing measured data (all from `research/34-chief-256k.md`, logs in `bench/logs/chief256k/`)
Decode q4_0 KV (no MTP): 31 t/s at 3K, 28 at 15K, 25 at 32K, 19.6 at 64K. Prefill is set by -ub: ub256 ~290, ub512 ~505, ub1024 ~768 t/s. 256K with >= 1 GiB free: only q4_0 KV at ub256 (min 1221 MiB) or q5_1:q4_0 ub256 (1035); `--no-mmproj-offload` saves ~350 MiB; MTP does not fit at 262144.

## 1. Plan for new measurements (this session)
1. R0: decode t/s at depth (0, 8K, 16K, 32K, 64K, 128K) via `llama-bench -d`, KV f16/q8_0/q4_0, ub as per tier. Decomposes bytes vs compute.
2. `-nkvo` at depth, to size the cost of "all KV in RAM".
3. Timing-only sparse ceiling on global layers (small patch, Devin if needed).
4. MTP draft-ctx cap (patch + fit/tokens measurement).
5. Tier table with needle 5/5 and VRAM floor.

(Sections below are appended as results arrive.)

## 2. WS-C resolved by this lead: the MTP draft context has no KV of its own to shrink
Source: `bench/logs/chief256k/g1-262k-q4-ub512-mmcpu-mtpq4.server.log` lines 326-356, 430; `engines/llama.cpp-sycl-tip/src/llama-context.cpp:230-247`, `common/speculative.cpp:1470 is_mem_shared`.
- The Gemma 4 MTP head (`gemma4-assistant`, `shared_kv_layers = 4`) is created with `ctx_other = ctx_tgt` and **shares the target's KV buffers** ("layer 3: sharing with layer 47", "layer 0..2: sharing with layer 46"; no `KV buffer size` line for the draft context). So a smaller draft `n_ctx` (the idea in WS-C, and `speculative.cpp:2617` setting `cparams.n_ctx = llama_n_ctx(ctx_tgt)`) would save nothing: the draft attends the target cache at its full n_kv.
- What MTP actually costs at long context is one extra **compute buffer**, scaling with n_ctx x ub: SYCL0 833.78 MiB + SYCL_Host 273.79 MiB at 262144/ub512 (target's own: 848.80 + 288.81). This is the whole 262K MTP failure (free 81 MiB). It scales down with ctx and ub (see target buffers at 131072 ub512: 465 MiB; 65536 ub512: 273 MiB), so MTP should fit at <=131072 with ub512; to be measured (tier table).
- Not a patch candidate; no Devin lane spent on it.

## 3. R0 — decode at depth, KV type as the variable (measured 14:27-14:50 today)
Harness: `bench/r46-depth.sh` (lock, gates, watchdog, jobcap, VRAM 2 s sampling) + `bench/r46-fill.py` (fills missing cells, retries watchdog aborts). `llama-bench -p 0 -n 64 -d <depth> -r 2 -fa on -ub 512 -b 1024 -lm dio`, engine `llama.cpp-sycl-tip` 358a420ec, model gemma-4-12b-it-qat-q4_0, mmproj not loaded, no MTP. Logs `bench/logs/r46/r0-*.jsonl` (+ `.vram`, `.err`). Std over 2 reps; other agents shared the box (a Devin SYCL build ran from ~14:45), so std up to 3 t/s on single cells.

| KV | d=0 | d=8K | d=32K | d=64K | log |
|---|---|---|---|---|---|
| f16 | 38.81 | 34.32 | 28.21 | 25.86 | `r0-f16-ub512.jsonl` |
| q8_0 | 36.62 | 29.90 | 26.34 | 21.85 | `r0-q8_0-ub512.jsonl` (d0, 8K; run killed by watchdog io-PSI 1.58) + `r0-q8_0-a1791895848.jsonl` (32K, 64K; two earlier attempts also watchdog-killed on other agents' disk IO, watchdog not loosened) |
| q4_0 | 37.04 | 27.52 | 24.60 | 20.23 | `r0-q4_0-ub512.jsonl` |

Reading:
- **f16 KV is the fastest at every depth and q4_0 the slowest** (64K: 25.9 vs 20.2 t/s, +28 %). The brief's "19.6 t/s at 64K" is the quantized-KV dequant cost, not KV bandwidth: q4_0 has 1/4 the bytes of f16 and still loses.
- Depth penalty, f16: 25.8 ms -> 38.7 ms per token at 64K = +12.9 ms, of which global-layer bytes (1 GiB f16 at 64K, ~2.4 ms at 456 GB/s) explain <20 %. The rest scales with n_kv in the kernels, consistent with workstream B's reading. Sparse/gather on the global layers is the only lever that attacks it (timing ceiling in §5).
- f16 KV at 64K leaves min 1079 MiB free (`r0-f16-ub512.vram`, desktop included) with no mmproj: right at the 1 GiB floor, so f16 is a 64K-tier option only with `--no-mmproj-offload`/ub512, not for 128K+.

## 4. Timing-only ceiling: global layers see 4 sinks + 2048 recent tokens (measured 16:3x)
Patch: branch `lc46/ceiling-and-draft-ctx` @ 243a5b4c7 in `engines/llama.cpp-sycl-dev` (built by Devin swe-2-max from `research/46-card-ceiling.md`, 46 LOC in `llama-kv-cache.{h,cpp}`, `llama-graph.cpp`; notes `research/46-patch-notes-ceiling.md`). Env `LC46_GLOBAL_KEEP=N` (decode only, non-SWA layers of Gemma 4) + `GGML_SYCL_SPARSE_FA=1`. Review by a different model (haiku-5-5, `~/.hermes/cache/delegation/live/deleg_640f0718/task-0.log`): mask drop, scope (base cache only, decode only), env-unset inertness all correct; caveat: sparse path silently falls back to dense when n_kv < 2*PAD(N+516,256) (~5.6K for N=2048), fine at >= 8K. Output text is wrong by design (quality ignored); this is the speed upper bound for any exact-selection sparse method on the 8 global layers.

f16 KV, ub512, llama-bench -p 0 -n 64 -r 2 (log `bench/logs/r46/ceil2k-f16-a1791896312.jsonl`):

| depth | dense (R0) | global layers capped to 2K | gain |
|---|---|---|---|
| 8K | 34.32 | 35.59 | +4 % |
| 32K | 28.21 | 36.16 | +28 % |
| 64K | 25.86 | 36.09 | +40 % |

The curve is flat at ~36 t/s from 8K to 64K: **the whole depth penalty comes from the 8 global layers**; the 40 SWA layers cost nothing extra at depth. At 64K the 8 global layers cost ~11 ms/token in f16 (38.7 vs 27.7 ms) for 1 GiB of KV, i.e. ~90 GB/s effective against 456 GB/s peak: the decode FA kernel for D=512 / 1 KV head / GQA 16 is far from bandwidth-bound. Two ways to reclaim it: (a) an exact kernel fix (split-K / better occupancy / kernel choice for this shape; research/33 item 7 "long-context decode attention", never measured above 4K until now), (b) approximate selection (Quest-style pages) on the same sparse-FA path. (a) has no quality cost and helps every depth; (b) is bounded by the ceiling above.

## 5. Workstream A measured: all KV in host RAM (`-nkvo 1`, attention on CPU) — the hybrid idea, at its cheapest implementation
q4_0 KV, ub512, same harness (log `bench/logs/r46/nkvo-q4_0-a1791898840.jsonl`, `.vram`). Because the SWA cache is windowed (0.13-0.18 GiB), `-nkvo` at depth is effectively "global-layer KV in RAM": it is the best-case proxy for the per-layer patch.

| depth | q4_0 KV on GPU (R0) | q4_0 KV in RAM (-nkvo) | min free VRAM, GPU / RAM |
|---|---|---|---|
| 0 | 37.04 | 34.50 | |
| 8K | 27.52 | 19.54 | |
| 32K | 24.60 | 14.48 | |
| 64K | 20.23 | 11.23 | 2035 / 2387 MiB |

- RAM-resident KV is 1.8x slower at 64K and frees only ~350 MiB of VRAM there (KV is small; the VRAM pressure at 256K is the n_ctx-linear compute buffer, 0.7-1.2 GiB, which does not move to RAM). Combined with §4 (the cost is attention compute on 8 layers, not bytes) a per-layer host-KV patch (kv_base on host, SWA on GPU: ~50 LOC in `llama-kv-cache-iswa.cpp`, a cparam + `common/arg.cpp` flag + graph backend pin for the base layers, 6 files) cannot beat the numbers above and would only buy a capacity tier. **Not built.** The GenerelSchwerz `--kv-cpu-pinned` route (GPU attention over pinned host KV) would read 0.28-1.1 GiB per token over PCIe 4.0 x8 (~13-14 GB/s practical => 20-80 ms/token at 64K-256K, q4_0): worse than both options above on this card.

### 4b. Ceiling for q4_0 KV and kernel profile
q4_0 KV, ceiling (`bench/logs/r46/ceil2k-q4_0-a1791902395.jsonl`): 8K 31.76 / 32K 31.56 / 64K 30.12 t/s vs dense 27.52 / 24.60 / 20.23 (+15 / +28 / +49 %). Flat-ish again; remaining slope is the 1K-window SWA layers plus quantised-K write cost. The ceiling for f16 is 36 t/s, q4_0 30 t/s: **f16 KV is worth ~6 t/s over q4_0 at any depth once global attention is capped**, and the quantised-KV decode kernel is the slow part even without depth.
Proof the sparse path ran: flat curve (a masked-but-dense run would sit on the dense line); the explicit `[FA-SPARSE]` debug-log run (`GGML_SYCL_SPARSE_FA_DEBUG=1`, `bench/logs/r46/ceil2k-proof`) was queued but cancelled when Marcel paused GPU work for the bake-off. **Not yet proven by log line.**

unitrace per-kernel (`bench/logs/r46/prof/prof-{f16,q4_0}.*.unitrace`, depth 32768, 24 decode tokens, profiler slows decode to 23.9 / 19.9 t/s; prefill kernels dominate totals, decode kernels read by name):

| kernel | f16 KV | q4_0 KV |
|---|---|---|
| global FA `flash_attn_tile<512,512,2,16>` (8 layers/token) | 192 calls, avg 680 us, max 2565 us => 5.4 ms/token, ~99 GB/s | 200 calls, avg 825 us, max 4057 us => 6.6 ms/token, ~21 GB/s of K+V actually streamed |
| SWA FA `flash_attn_tile<256,256,1,2>` (40 layers/token) | 960 calls avg 63 us => 2.5 ms/token | 960 calls avg 47 us |
| launch_fattn host side | 12 us / 3 us per call | 30 us / 3 us |

So at 32K the 8 global-layer kernels cost 5.4 ms (f16) of a 35.4 ms token and ~11 ms at 64K; at ~100 GB/s they run at ~22 % of the card's 456 GB/s. That is the exact-kernel prize (research/33 item 7): roughly +12 % decode at 32K, +30 % at 64K, more at 256K, no quality loss. Devin lane 2 (`research/46-card-fa-decode.md`, Fusion Sonnet+SWE-2) started it: env knobs `GGML_SYCL_FA_FORCE_VEC`, `GGML_SYCL_FA_TILE_NCOLS1`, `GGML_SYCL_FA_MIN_PB` + test-backend-ops perf cases, branch `lc46/fa-decode` commit e632d64de (67 LOC, **WIP, unmeasured, unreviewed**; Devin was killed when GPU work was paused, its tail 2 GPU waiters were killed with it).

## 6. Measured tier table (lc.py sessions, server, prompt cache bypassed for the ladder, `--single` = follow-up question on the cached prefix)
Harness `bench/lc.py` via `bench/r46-tiers.sh` (one lock per session), summary `bench/r46-summary.py`. Logs `bench/logs/chief256k/<label>.{json,server.log,stepN.json}`. Prefill/decode are server timings of the needle request itself. Desktop and other agents share the card; min-free values moved by ±300 MiB between sessions today (the 131K row had 1689 MiB free here vs 1620 in the 12:18 WS1 run).

| tier | config | prompt tok | prefill t/s | decode t/s | cached follow-up: new tok / ms / decode t/s | needle multi / single | min free MiB |
|---|---|---|---|---|---|---|---|
| 64K now (baseline) | q8_0, ub1024, mmproj GPU, no MTP, `s-65k-q8-ub1024-base` | 6788 | 767 | 28.6 | 44 / 874 / 28.5 | 5/5, 5/5 | 1410 |
| | | 31225 | 800 | 24.3 | 43 / 825 / 24.4 | 5/5, 5/5 | 1410 |
| | | 59007 | 753 | 21.1 | 41 / 858 / 21.0 | 5/5, 5/5 | 1410 |
| 64K + MTP n3 | q8_0, ub1024, mmproj GPU, `s-65k-q8-ub1024-mtp` | | | | | | **758: fails the 1 GiB floor, session stopped** |
| 64K + MTP n3 | q8_0, **ub512**, mmproj GPU, `s-65k-q8-ub512-mtp` | 6788 | 489 | **83.1** | 44 / 870 / 76.1 | 5/5, 5/5 | 1072 |
| | | 31225 | 518 | **67.4** | 43 / 838 / 63.2 | 5/5, 5/5 | 1060 |
| | | 59007 | | | | | **916: stopped at the floor** (mmproj on GPU) |
| 128K | q4_0, ub512, mmproj CPU, no MTP, `q-131k-q4-ub512` | 31225 | 519 | 24.6 | 43 / 833 / 24.5 | 5/5, 5/5 | 1779 |
| | | 64556 | 490 | 20.8 | 44 / 886 / 21.1 | 5/5, 5/5 | 1689 |
| | | 126452 | 449 | 15.7 | 44 / 944 / 15.8 | 5/5, **4/5** | 1689 |
| 128K + MTP | q4_0, ub512, mmproj CPU, `s-131k-q4-ub512-mtp` | | | | | | **946 at 32K: fails the floor** (loaded 1073) |
| 256K | q4_0, ub256, mmproj CPU (from research/34, not re-run: q-262k-q4-ub256 was queued, cancelled) | 31692 | 289 | 24.3 | | 5/5 | 1056-1162 |

Reading:
- **MTP n3 at 64K is 2.8-2.9x decode (83 / 67 t/s vs 28.6 / 24.3) and the cached-prefix turns keep it (76 / 63)**; it needs ub512 (not ub1024) and, to clear the floor at 60K prompt, `--no-mmproj-offload` (mmproj on GPU costs ~350 MiB; session `s-65k-q8-ub512-mtp-mmcpu` was queued to prove it, **not run**). Prefill is 489-518 t/s at ub512 vs 750-800 at ub1024 (-35 %): MTP costs prefill speed via ub.
- MTP at 128K does not fit at ub512 (946 MiB min). ub256 (`s-131k-q4-ub256-mtp`) queued, not run; expected ~+200 MiB from the draft + target compute buffers (361 + ~350 MiB at ub256 vs 465 + 450 at ub512), unproven.
- Cached-prefix follow-up turns cost 0.83-0.94 s for ~43 new tokens at every depth up to 126K: prompt-cache reuse (`-cram`) works and is the cheap long-context win for chat; the cost is the ~20 ms/token small-batch prefill, not the depth.
- 128K q4_0 single-needle recall 4/5 at 126K (multi 5/5): the only quality dent seen; one miss, within what `needle.py` single-question noise allows, but it is the quality edge for q4_0 KV at 128K.

## 7. Verdict per workstream
- **A (hybrid GPU/RAM KV): rejected by measurement.** All KV in RAM = 1.8x slower at 64K, frees ~350 MiB; global KV is only 1.1-2.1 GiB at 256K; the 256K VRAM squeeze is weights (6.6 GiB) + n_ctx-linear compute buffer, which cannot move. No fork supports it for Gemma 4 anyway (§0). Capacity framing of the directive is already satisfied by the sliding-window cache + q4_0 global KV.
- **B (sparse attention): ceiling measured, quality not.** Capping global layers to 2K tokens gives +40 % (f16) / +49 % (q4_0) at 64K; flat curve to 64K. Real Quest-style selection would land between dense and this ceiling at an unmeasured quality cost (no Gemma result in the literature, notes B). Prototype cost 2-4 weeks.
- **C (MTP at long ctx): the draft shares the target KV; there is no draft-context knob to turn** (§2). Working MTP tier = 64K at ub512 (+ mmproj on CPU for headroom); 128K needs ub256 (untested).
- **D cheap wins:** ub per tier (ub1024 only for the vision-heavy 64K non-MTP id), q8_0 -> f16 KV at <=64K where VRAM allows (+3.5 t/s at 32K, +4 at 64K vs q8_0; min free 1079 MiB at 64K, so only with mmproj on CPU), `--no-mmproj-offload` on every id that does not need screenshots, prompt-cache reuse already effective, MTP n3 at 64K (2.8x).
- **New, not in the brief:** the exact decode-attention kernel for the 8 global layers runs at ~22 % of bandwidth; fixing it is the one lever that speeds every depth without a quality trade (§4b).

## 8. Proposed config (NOT applied; `serve/config.yaml` and the Chief profile untouched)
Ids in llama-swap terms; all with `--no-mmproj-offload` except where vision must be fast. Only measured rows are marked measured.
```
gemma4-12b        (fast, 64K)  -c 65536 -ctk q8_0 -ctv q8_0 -ub 512 -b 1024 --no-mmproj-offload
                               -md mtp-gemma-4-12B-it.gguf -ngld 99 --spec-draft-device SYCL0 --spec-type draft-mtp --spec-draft-n-max 3
                               # measured with mmproj on GPU: 83/67 t/s at 7K/31K, needles 5/5; floor failed at 59K (916 MiB)
                               # with mmproj CPU the floor should clear: s-65k-q8-ub512-mtp-mmcpu NOT RUN yet
                               # keep ub1024 + no MTP + mmproj GPU as the vision/rollback id: 28.6/24.3/21.1 t/s, floor 1410
gemma4-12b-128k   (new)        -c 131072 -ctk q4_0 -ctv q4_0 -ub 512 -b 1024 --no-mmproj-offload -fit off -lm dio, no MTP
                               # measured: 24.6/20.8/15.7 t/s at 31K/65K/126K, prefill 519/490/449, floor 1689, needles 5/5 (single 4/5 at 126K)
gemma4-12b-long   (new, 256K)  -c 262144 -ctk q4_0 -ctv q4_0 -ub 256 -b 1024 --no-mmproj-offload, no MTP
                               # from research/34: 24.3 t/s at 32K, prefill 289, floor 1056-1162; 64K+ steps at 262144 still unmeasured
Chief compaction thresholds: 64K id 32768 (unchanged); 128K id 65536 (cached follow-up turns stay ~0.9 s, a 65K summary prefill ~2.2 min at 490 t/s); 256K id 32768 until the 64K step at 262144 is measured.
```
Rollback: all three are additive ids; the current `gemma4-12b` block is kept as `gemma4-12b-vision`.

## 9. Open decisions for Marcel
1. Apply the MTP 64K id once `s-65k-q8-ub512-mtp-mmcpu` confirms the floor (one 10-minute session after the bake-off).
2. Fund the exact-kernel work (research/33 item 7, Devin branch `lc46/fa-decode` e632d64de is a WIP start): up to +30 % at 64K and more at 256K, no quality cost. vs. Quest-style selection (2-4 weeks, unmeasured quality, ceiling +40-49 % at 64K). Recommend the kernel first.
3. Floor policy: f16 KV at 64K and MTP at 128K both sit at 0.9-1.1 GiB; accept 0.9 GiB or keep >= 1.0 and use the slower configs above.
4. 128K q4_0 single-needle 4/5 at 126K: acceptable, or require q5_1:q4_0 (not measured in this pass).

## 10. Not done / interrupted (honest list)
- Cancelled at Marcel's request for the bake-off: `q-262k-q4-ub256` (256K needle ladder), `s-65k-q8-ub512-mtp-mmcpu`, `s-131k-q4-ub256-mtp`, ceiling `[FA-SPARSE]` proof run, Devin kernel measurements. Resume: `TMPDIR=~/.hermes/cache/scratch bench/r46-tiers.sh bench/logs/chief256k/r46.chain` (the chain file still lists them; remove the 4 finished lines first).
- One xe `GT0: Fault response -ENOENT` (BCS copy engine, ASID 165) at 14:49:46, coincident with the watchdog SIGTERM of my llama-bench run (io PSI 1.06). No reset/wedge/timeout; ~2 h of runs afterwards clean. Not acked, not touched. Watchdog was never loosened; three of my runs were killed by other agents' disk IO and re-run.
- Dev worktree `engines/llama.cpp-sycl-dev` (new, branch `lc46/fa-decode`) holds the build; process census at end: no devin, ninja, llama or r46 processes of mine.
