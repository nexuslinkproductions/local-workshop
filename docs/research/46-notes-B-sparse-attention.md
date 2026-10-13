# BRIEF-46 Workstream B: sparse / retrieval attention for Gemma 4 12B QAT on llama.cpp SYCL

Scope: read-only desk research. No GPU process started, bench/.gpu.lock not touched, engine source not modified.
Engine pin: `engines/llama.cpp-sycl-tip` @ 358a420ec. `engines/llama.cpp-prism-tip` @ e8fd209c9.
Target GGUF (header read only via bench/gguf-meta.py): `models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/gemma-4-12b-it-qat-q4_0.gguf`.

## 0. Facts from the target GGUF (measured from metadata, not from the brief)

| key | value | consequence |
|---|---|---|
| gemma4.block_count | 48 | |
| gemma4.attention.head_count_kv | per-layer array: 8 for SWA layers, **1 for layers 5,11,17,23,29,35,41,47** (0-based) | 8 global layers, 40 SWA layers, as the brief says |
| gemma4.attention.sliding_window_pattern | True x5 then False, repeated 8x | the False layers are the global ones |
| gemma4.attention.key_length / value_length | 512 (global) | |
| gemma4.attention.key_length_swa / value_length_swa | 256 (SWA) | |
| gemma4.attention.sliding_window | 1024 | |
| gemma4.attention.shared_kv_layers | 0 | no cross-layer KV sharing (the reuse path at llama-model.cpp:3198-3203 is inactive) |
| gemma4.context_length | 262144 | |
| gemma4.final_logit_softcapping | 30.0 | final-logit softcap only; **no attn_logit_softcapping key found** |
| gemma4.rope.freq_base / freq_base_swa | 1e6 / 1e4 | |

Source: `models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/gemma-4-12b-it-qat-q4_0.gguf` (kv=50, tensors=667). Also `bench/gguf-meta.py`.

Napkin KV math (computed here from the metadata above; the arithmetic is mine, the geometry is from the GGUF):

| KV type | global layers @256K (8 x 1 head x 512, K+V) | SWA layers @256K **if full-size** (40 x 8 x 256) | SWA layers windowed (~2048 cells) | global bytes read per decode token @64K |
|---|---|---|---|---|
| f16 | 4.00 GiB | 80.0 GiB | 0.63 GiB | 1.00 GiB (~2.4 ms @456 GB/s) |
| q8_0 | 2.12 GiB | 42.5 GiB | 0.33 GiB | 0.53 GiB (~1.3 ms) |
| q4_0 | 1.12 GiB | 22.5 GiB | 0.18 GiB | 0.28 GiB (~0.7 ms) |

Two consequences that change the brief's framing:

1. **The 256K "KV barely fits even at q4_0" observation does not match this geometry unless SWA is full-size.** With the default windowed SWA cache, the whole 256K KV is ~1.3 GiB at q4_0. Full-size SWA at q4_0 would be 22.5 GiB, which cannot fit on a 12 GB card. Either the run uses `--swa-full` (not found in bench/ or serve/ configs; `common/common.h:577` default is `swa_full=false`) or the "barely fits" is about buffers other than KV. **Check the server start log for the KV size lines before designing anything.**
2. **The depth penalty does not match global-layer bandwidth either.** Observed: 31 t/s at 3K (32.3 ms/token) vs 19.6 t/s at 64K (51.0 ms/token), a +18.8 ms delta. Global-layer reads at 64K account for 0.7 ms (q4_0) to 2.4 ms (f16). The delta only matches if the 40 SWA layers read full-context KV (q4_0 full-size SWA at 64K would add ~13 ms). That contradicts point 1, unless the run is full-size SWA at a context below 256K. The remaining explanation is kernel cost that scales with n_kv (dequant, mask reads, per-layer overhead) rather than bytes. **This is the first thing to measure (section 4, step R0).**

## 1. Methods inventory

Columns: method | idea | where it exists | applies to Gemma 4 (dense, no trained indexer)? | quality cost | effort (my estimate) | source

| Method | Idea | Where it exists | Applies to Gemma 4? | Quality cost | Effort | Source |
|---|---|---|---|---|---|---|
| **Quest** | Per KV page (16 tok) keep channel-wise min/max of K. Query-dependent upper bound on page score; attend only top-K pages. Metadata ~1/S of KV. | Paper + `mit-han-lab/Quest` (PyTorch). Not in llama.cpp. | **Yes.** Training-free. Use on the 8 global layers. Skip the first ~2 layers (paper: first two layers need ~full attention). | Paper reports negligible loss at its budgets on Llama-family models. **No Gemma result found.** | 2-4 wk SYCL prototype on existing sparse-FA gather (estimate) | https://arxiv.org/abs/2406.10774 ; https://homes.cs.washington.edu/~baris/public/quest.pdf (speedup 7.03x attn / 2.23x latency, abstract) |
| **InfLLM** | Evicted KV split into 128-token blocks; 4 representative tokens per block (scored by attention-weighted query sum); local 4K window + top-k blocks looked up per step; blocks offloaded to CPU with GPU LRU cache. | Paper (thunlp/InfLLM). Not in llama.cpp. | Yes (training-free). Needs representative-token scoring pass. | RetrievalAttention reports InfLLM 5.7 pt average loss on infinity-Bench (Llama-3-8B) and 42.8 pt loss on RULER 128K. Secondary read, not checked against PDF. | 3-5 wk | https://arxiv.org/html/2402.04617 ; numbers via https://arxiv.org/pdf/2409.10516 |
| **RetrievalAttention** | Keep static sink + recent window (640 tok) in GPU; rest of KV on CPU in an ANNS index built with prefill queries (fixes query/key OOD); retrieve top-100 (1-3% of data) per head; merge GPU/CPU partial softmax. | Paper only. | Yes (training-free) but index build + CPU ANNS is heavy. | Paper: near full-attention accuracy at 1-3% data. | Research project, 2-3 mo | https://arxiv.org/abs/2409.10516 |
| **MagicPIG** | LSH sampling (SimHash, K x L tables) instead of top-k; attention computed on CPU over sampled keys; sinks + local kept on GPU; recursive attention merge. | Paper + Infini-AI-Lab/MagicPIG. | Yes in principle. Needs a CPU attention path that does not exist in the SYCL engine. | Paper: beats TopK on aggregation tasks; sampling with estimator guarantees. | Research project | https://arxiv.org/abs/2410.16179 (54 ms/token, RTX 4090, 96K, Llama-3.1-8B, v4) |
| **H2O** | Keep "heavy-hitter" tokens by accumulated attention mass + recent window; evict the rest. | Paper (FMInference/H2O). Eviction, not retrieval. | Mechanically yes, but needs attention weights that FA kernels do not return. Destructive. | Paper: comparable at <20% budget on OPT/LLaMA/GPT-NeoX. Eviction loses needles when queries shift (RetrievalAttention Sec 2). | Low algorithmically, high on FA path | https://arxiv.org/pdf/2306.14048 |
| **SnapKV** (+ SnapKV-D) | Observation-window votes select prefix positions; prefill-focused; SnapKV-D extends to decode. | Paper (Li et al. 2024; arXiv ID not verified here) and reference code. | Eviction, same caveats as H2O. | Loses KV-retrieval task (0.5% vs 17.5% full, Llama-3-8B, per RetrievalAttention Table 2). | Low-medium | https://arxiv.org/pdf/2409.10516 ; https://arxiv.org/html/2512.12008v1 (SnapKV-D) |
| **StreamingLLM** | Sink tokens + sliding window; middle dropped. | Paper arXiv 2309.17453 (ID as cited in local KB source). | Trivial to add, but for global layers it throws away everything outside the window. | Worst on retrieval (RetrievalAttention: 20.2% vs 50.4% full on infinity-Bench, Llama-3-8B). | Trivial | https://arxiv.org/pdf/2409.10516 |
| **DSA lightning indexer** (DeepSeek-V3.2) | Learned per-layer indexer (64 heads x 128 dim, ReLU, FP8); top-2048 tokens per query; MLA attention over the selected set. | Model: DeepSeek-V3.2(-Exp). llama.cpp: `src/llama-kv-cache-dsa.{h,cpp}`, `ggml/src/ggml-sycl/lightning-indexer.cpp`. | **No.** Needs trained indexer weights. Gemma GGUF has no indexer tensors. Retrofit recipe: dense warm-up then sparse adaptation (~946B tokens in total per secondary summary). | Quality is preserved only after the retrofit. | Training project, not feasible locally | https://arxiv.org/abs/2512.02556 ; https://huggingface.co/docs/transformers/main/en/model_doc/deepseek_v32 |
| **MiniMax MSA** | Learned GQA block indexer; max-pool scores to 128-token blocks; top-16 blocks per query plus the local block forced in; `ggml_flash_attn_ext` over gathered blocks. | Upstream llama.cpp PR #24908 (commit b1d4c65) and PR #25113 (vision). Local: `src/llama-kv-cache-msa.*`, `src/models/minimax-m3.cpp`. | **No** as a model feature (needs trained indexer). **Mechanics reusable** (see section 2.3). | Model is trained for it. Dense fallback is out-of-distribution (PR text). | — | https://github.com/ggml-org/llama.cpp/commit/b1d4c6552489d27eb732c2804f189d9cc6ba99bd |
| **KVMem** (arXiv 2609.04852) | Full KV kept as paged blocks in host RAM (+NVMe). GPU holds a bounded working set (budget + gen_reserve). Each block summarized by Mean-K computed pre-RoPE. Selection by query vs Mean-K, once per agent step; selected set fixed during decode. FA kernel unmodified. | `kvmem/kvmem-llama.cpp` (llama.cpp patch set, CUDA; ROCm beta). Tested on Qwen3.6/3.8-27B. | **Architecturally yes** (Mean-K is training-free). Needs a SYCL port. Per-step selection is coarser than the per-token directive. | Paper: LongMemEval-S 85.6% (32K GPU window) vs 86.6% (full 256K); AgentLongBench 60.9 vs 59.5. Not tested on Gemma. | Port: weeks to months | https://arxiv.org/abs/2609.04852 ; https://github.com/kvmem/kvmem-llama.cpp (README, docs/architecture.md) |
| **Generic gather-based sparse FA** (llama.cpp mechanism, not a method) | If a graph sets `n_kv_max`, FA treats finite mask entries as the K/V set: compact indices, gather K/V rows, gather mask, run FA. | Local SYCL: `ggml/src/ggml-sycl/fattn-sparse.cpp`, off by default (`GGML_SYCL_SPARSE_FA=0`). Upstream: commits beed2f7, 50d50ba, 7fee670 (qwen4exp). Vulkan: b3daa07 (#29639). | **Yes, this is the reusable piece.** Any selection method that writes a sparse mask plugs into it. | Exact for the selected set. | Gemma graph change: small | section 2.4 |
| Pinned host KV (`--no-kv-offload --kv-cpu-pinned`) | Keep KV in pinned host RAM; attention still reads it. | GenerelSchwerz/llama.cpp wiki "Pinned Host KV". | Capacity tool only. Per-token reads still stream over the bus. | None | Low | https://github.com/GenerelSchwerz/llama.cpp/wiki/Pinned-Host-KV |
| Application-level section selection (Galahad "Blaise") | Keep documents outside the model; pass only the needed section (~668 tokens/question). | arXiv 2609.39358 (Gemma 4 31B, llama.cpp). Secondary read. | Yes, no kernel change. | Depends on the retriever. | Low | https://arxiv.org/pdf/2609.39358.pdf |
| Adjacent: persisted Q4 KV per agent (state save/restore) | Persist and restore whole-context KV; no per-token sparsity. | arXiv 2603.04428 (Gemma 3 12B, dense, GQA; 8 global + 40 SWA, same layout). | Yes for prefix reuse, not for decode cost. | PPL +0.7% (Gemma) at Q4 (paper). | Low | https://arxiv.org/html/2603.04428v1 |

Not found: any Gemma-family sparse-retrieval quality result. Any upstream llama.cpp PR adding Quest, InfLLM, RetrievalAttention, MagicPIG, H2O, SnapKV or StreamingLLM eviction. Search coverage was limited (about 10 queries); treat "not found" as "not seen", not as proof of absence.

## 2. llama.cpp MSA/DSA deep-dive and the arch-gate verdict

### 2.1 Where the cache classes are instantiated (sycl-tip; prism-tip is identical for MSA)

- `src/llama-model.cpp:2784-2802`: `LLM_ARCH_MINIMAX_M3` is the only arch that creates `llama_kv_cache_msa` (new at :2790).
- `src/llama-model.cpp:2806-2842`: `LLM_ARCH_GLM_DSA`, `LLM_ARCH_DEEPSEEK32` create `llama_kv_cache_dsa` (:2842). The MTP context for these archs is plain attention (comment at :2810-2812).
- `src/llama-model.cpp:2859-2883`: `LLM_ARCH_GLM5_NEXT` uses `llama_memory_hybrid_idx`.
- `src/llama-model.cpp:2903-2928`: `LLM_ARCH_HY_V4` uses `llama_kv_cache_dsa`.
- `src/llama-model.cpp:2945-2979`: `LLM_ARCH_DOTS3NOTE` uses `llama_kv_cache_dsa_iswa`.
- `src/llama-model.cpp:2996-3005`: `LLM_ARCH_DEEPSEEK4` (its own path).
- `src/llama-model.cpp:3094` and `:3153-3154`: `LLM_ARCH_QWEN4EXP` uses `llama_memory_hybrid_idx`. The comment at :3094 says "a null filter_idx means the GGUF has no indexer tensors".
- Gemma 4 (`LLM_ARCH_GEMMA4`, routed at `llama-model.cpp:153`) never reaches any of these. Its cache is the generic iSWA path, with KV reuse only for `n_layer_kv_from_start >= 2` (`llama-model.cpp:3198-3203`), which is inactive because `shared_kv_layers=0`.

### 2.2 Gating inside the model graph

- `src/models/minimax-m3.cpp:84-87`: indexer tensors are loaded (`index_q_proj`, `index_k_proj`, `index_q_norm`, `index_k_norm`). The Gemma 4 GGUF has none of these names, and the Gemma loader never requests them.
- `src/llama-arch.cpp:298-305`: indexer GGUF keys (`attention.indexer.*`). Not present in the Gemma 4 metadata above.
- `src/models/minimax-m3.cpp:27-33`: `msa_p` (block size, top-k blocks, local blocks) comes from the indexer GGUF keys.
- `src/llama-kv-cache-msa.h:14-30` and `.cpp:13-50`: a second `llama_kv_cache` (`kv_idx`) holds one indexer key head per layer. `kv_base` holds K/V. Both share ubatches and cell layout.
- `src/llama-kv-cache-dsa.h:15-31`: same pattern (`kv_mla` plus `kv_lid`).

### 2.3 Arch-gate verdict

**MSA and DSA cannot be reused as cache classes for Gemma 4.** They need per-layer learned indexer tensors and an indexer KV cache, neither of which exists in the Gemma 4 GGUF, and the loaders only create them for the listed archs.

**The selection mechanics can be reused**, because they do not depend on the learned weights:

- `src/models/minimax-m3.cpp:384-410` (decode branch): score each position through the indexer key cache with `ggml_mul_mat`; `ggml_pool_2d(MAX, blk)` to block scores; `ggml_top_k` for block indices; expand to position indices with `ggml_arange`; map position to cell with `pos_slot`; `ggml_get_rows` to gather K/V rows; build the F16 mask; call `build_attn_msa_fa` (`:176`). It runs one FA call per layer over `blk*K` gathered rows.
- For Gemma 4, the learned indexer score (`iq`·`ik`) can be replaced with a training-free score. Options: Quest page bounds (per-page min/max of K, computed at KV write) or KVMem-style Mean-K (computed pre-RoPE). Both use only the existing K cache. The rest of the pipeline (pool, top-k, gather, sparse FA) stays.

### 2.4 The generic sparse-FA path (the most useful find)

- `ggml/include/ggml.h:2505-2509`: `ggml_flash_attn_ext_set_n_kv_max`. Finite mask entries are the sparse K/V set. `n_kv_max` must bound the count.
- `src/llama-graph.cpp:2855-2906`: `build_attn_mha(..., n_kv_max, ...)` sets the op param. Callers that pass a non-zero `n_kv_max`: `src/models/deepseek4.cpp:759-760`, `src/models/glm5-next.cpp`, `src/models/qwen4exp.cpp`. **Gemma 4 passes none.** Its attention calls go through `build_attn` at `src/models/gemma4.cpp:274-279`.
- `ggml/src/ggml-sycl/ggml-sycl.cpp:144-146`: `g_ggml_sycl_enable_sparse_fa=0`, margin 256. `:464` reads env `GGML_SYCL_SPARSE_FA`. Documented as off in `research/13-speed-levers.md:273`.
- `ggml/src/ggml-sycl/fattn.cpp:284-286`: dispatch first tries the sparse path.
- `ggml/src/ggml-sycl/fattn-sparse.cpp:117-145` (`sparse_fa_applicable`): needs `n_kv_max > 0`, `max_bias == 0`, `logit_softcap == 0`, **decode only** (`Q->ne[1]==1`), `K->ne[3]==1`. Gemma 4 has no attn softcap key, so this holds if `hparams.attn_soft_cap` is false (not verified in code).
- `fattn-sparse.cpp:8-9`: `SPARSE_FA_PAD=256`, `SPARSE_FA_MIN_RATIO=2`.
- `fattn-sparse.cpp:~174-220` (`ggml_sycl_flash_attn_ext_sparse`): `sparse_fa_compact_mask` (scan the F16 mask, keep finite positions, atomic counter), `sparse_fa_gather_rows` for K and V (raw byte copy, per head), `sparse_fa_gather_mask`, then FA over the compacted set.
- Cost model: the gather copies selected rows, so selected K/V are read twice (gather + FA). The Vulkan implementation (commit b3daa07, #29639) gates on sparsity ratio: 2x for f16 K/V, **16x for quantized K/V** (measured by its authors on RDNA3/RDNA4, not on Xe2). At 256K with 2048 selected, the ratio is 128x, which clears either bar. At 64K it is 32x.

### 2.5 What is on disk vs upstream

- `llama-kv-cache-msa.{h,cpp}` are byte-identical in sycl-tip and prism-tip (diff checked). `llama-kv-cache-dsa.cpp` differs only in a try/catch in `state_read` (sycl-tip has the guard, prism-tip does not).
- So prism-tip gives no extra sparse capability over sycl-tip.

## 3. Upstream PR / fork survey

| Item | What | Status | Relevance |
|---|---|---|---|
| ggml-org/llama.cpp commit b1d4c65 (PR #24908) | MiniMax-M3 MSA (learned block-sparse). Later rewrite: "1 FA call per layer", block-level mask on CPU, decode graph reuse. | Merged (per commit text and release b10142). | Mechanics reference only (section 2.3). |
| PR #25113 | MiniMax-M3 vision (mtmd). | Merged (secondary read). | Not relevant. |
| commits beed2f7, 50d50ba, 7fee670 ("qwen4exp: gather-based sparse attention for QSA decode") | Upstream gather-based sparse FA for a learned indexer (QSA). | On upstream master per commit titles. | Same mechanism as 2.4, with a learned indexer. |
| ggml-org/llama.cpp issue #28734 | "decode slows linearly with context" (qwen4exp, CUDA). Root cause: top-k was a dense scan; fix = pass `top_k->ne[0]` as `n_kv_max` to trigger the sparse FA path. Reported 11 -> 41.8 tok/s at 250K on a fork. | Open issue, fork patches. | Confirms the sparse-FA trigger is `n_kv_max` plus a mask. |
| vulkan commit b3daa07 (#29639) | Sparse FA for quantized K/V with mask compaction; ratio gate 2x (f16) / 16x (quant). | Merged. | Best data on the gate cost model. Vulkan, not SYCL. |
| ik_llama.cpp commit 9da563d | GLM-DSA lightning indexer, batch-local (no decode indexer cache); decode degenerates with the stub. | Fork, partial. | Shows retrofit pitfalls: decode indexer cache is the hard part. |
| kvmem/kvmem-llama.cpp (+ arXiv 2609.04852) | Bounded GPU window + host block store + Mean-K query retrieval; FA unmodified; CUDA. | Active fork, source version 0.17.0. | Closest working prior art for the directive. |
| llama.cpp issue #27109 / PR #27140 (secondary) | Quant KV on CUDA silently fell back to CPU for FA; PR #27140 added q4_0/q4_1/q5_0/q5_1 to f16 dequant kernels. | Secondary read. | Check that q4_0 KV does not fall back to a slow path on SYCL. Not verified on SYCL. |
| PrismML llama.cpp issue #191 | q5_0 KV decode ~8x slower than q4_0 at long context (CUDA). | Open, unverified hypothesis. | Quant-KV decode can have pathological long-context costs. Verify our q4_0 path on SYCL. |

Not found in searches: any upstream PR or issue for Quest, InfLLM, RetrievalAttention, MagicPIG, H2O, SnapKV, StreamingLLM in llama.cpp or its forks (limited search).

## 4. Ranked recommendation for a prototype

**R0 (days, do first, no code in engine): decompose the depth penalty.** Napkin math says global-layer KV bytes at 64K explain under 3 ms/token. The observed penalty is ~19 ms. Before building retrieval, measure:

1. Server start log: the KV size lines for SWA and global caches. Confirm whether `--swa-full` is set and whether the cache is windowed. If the SWA cache is full-size, the fix is to window it (the default), not to build retrieval.
2. Decode at 64K with f16 / q8_0 / q4_0 KV. If q4_0 and f16 differ by little, bytes are not the limit.
3. Timing-only ceiling: restrict global-layer attention to a fixed 2K-token mask (quality ignored) and measure decode. This is the upper bound for any sparse method on global layers. A few-line graph change in `gemma4.cpp` plus setting `n_kv_max` (or `GGML_SYCL_SPARSE_FA=1`) is enough.

If (3) shows less than ~20% decode gain, retrieval on the global layers is not worth building for speed. The directive's memory goal is then the only reason to do it.

**R1 (weeks, if R0 shows global-layer cost matters): training-free Quest-style page selection on the 8 global layers, on the existing SYCL sparse-FA gather.**
- Keep the global KV on GPU. At q8_0 it is 2.1 GiB at 256K (table above), so no RAM tier is needed for the global layers. The RAM tier matters only if the SWA cache is full-size.
- Page size 16, min/max per (page, dim) for the single global KV head, computed at KV write. Metadata: 0.25 GiB at f16 for 256K (napkin).
- Score per query: sum over dims of max(q·min, q·max); one selection for all 16 query heads, since the global layers have 1 KV head (GQA factor 16). Take the union or the sum of per-head bounds; the choice is open.
- Quest's "first two layers need dense attention" finding is about the first two layers of its models, not about global layers. For Gemma the first global layer is layer 5. Keep it dense as a default and test whether that is needed (unverified for Gemma).
- Driver: `GGML_SYCL_SPARSE_FA=1`, set `n_kv_max` in the Gemma 4 global-layer build, decode only. Prefill stays dense.
- Eval: `bench/needle.py` and `bench/lc.py` already exist in LOCAL-AI-LAB. Run needle at 64K and 256K before and after. The quality bar must be set by Marcel; no Gemma reference exists.
- Effort estimate: 2-4 weeks for a working SYCL prototype plus eval. Risk: quality on Gemma is unknown.

**R2 (later, only if VRAM actually binds): KVMem-style host tier for the global layers.** Port `kvmem-llama.cpp` concepts (Mean-K block index, host block store, GPU window). It is CUDA-first; the SYCL port is weeks to months. Its per-agent-step selection is coarser than the per-token directive, so a per-token variant (R1 selection on a host-resident store) would be the actual research step.

**R3 (research, not now): InfLLM-style CPU-resident block units, or RetrievalAttention ANNS.** Both need CPU-side index build and search. Only worth it if R1 proves that selection quality holds but the global KV still does not fit.

**Not recommended for this brief:**
- DSA / MSA retrofits: require trained indexers. The DeepSeek retrofit recipe is ~946B tokens per secondary summary.
- MagicPIG: needs a CPU attention path the SYCL engine does not have.
- H2O / SnapKV: need accumulated attention weights, which FA kernels do not return. They also drop tokens the query may need later.
- StreamingLLM on global layers: drops the middle of the context.

**Caveat on the whole ranking:** R1 is only valuable if R0 shows that the per-token cost is attributable to global-layer attention over the full context. The GGUF geometry says global-layer bytes are small. Measure before committing.

## 5. Files touched

- Created: `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/research/46-notes-B-sparse-attention.md` (this file).
- Read only: engine source under `engines/llama.cpp-sycl-tip` and `engines/llama.cpp-prism-tip`; `bench/gguf-meta.py`; `research/13-speed-levers.md`; the Gemma 4 GGUF header (first MB, metadata only).
- Not started: any GPU process. `bench/.gpu.lock` untouched. No engine source modified.
