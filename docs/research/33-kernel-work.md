# 33 — Kernel work on the B580 (and GT 1030): evidence base

Date: 2026-10-13. Engine: `engines/llama.cpp-sycl-tip` @ 358a420ec (SYCL, oneAPI 2026.0, Arc B580 / BMG, Level Zero 1.17).
Model: Gemma 4 12B QAT Q4_0 (`models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/`), MTP head `mtp-gemma-4-12B-it.gguf`.
Config as in the harness: `-t 16 -fa 1 -ctk q8_0 -ctv q8_0 -b/-ub 1024 -ngl 99 --device SYCL0`.
No engine source was modified. All raw logs: `bench/logs/kprof33-20261013-120705/` (scripts `run-prof{,2,3,4}.sh` copied there, `summary.json` = parsed tables).

## Bottom line

- **Decode (the chat path): 66% of token time is one kernel family, the Q4_0 batch-1 matvec, already at ~78% of the 456 GB/s peak in-kernel.** Realistic decode gain from kernel work is ~10% from the matvec and ~10–15% from fusing the ~1,700 small kernels per token. Not a 2× project.
- **Prefill (4K): 29–42% is weight dequantization to f16 that runs once per ubatch per matrix, plus a oneDNN GEMM.** The cheapest win is a config change (`-ub 2048`, +9% measured). The real kernel fix (XMX dequant-GEMM for wide N, Q4_0) is a large project and overlaps upstream open PR #29864.
- **Launch overhead is not the decode problem on this build.** GPU busy time per token ≈ 24.8 ms of 26.3 ms wall. `GGML_SYCL_ENABLE_GRAPH=1` makes decode 28% slower, so keep it off.
- **The 38% bandwidth figure in RESUME does not reproduce.** Clean numbers give ~58% effective (see §2).
- **Watch-out, live now:** another agent's `llama-server -c 262144` (pid 199155, watchdog pid 198927, label `lc-g1-262k-q4-ub512-mmnone`) is running. RESUME bans 262144 without Marcel's approval. I did not touch it.

## 1. Profiling tools (user space, no sudo)

| Tool | Status | Use |
|---|---|---|
| VTune | Not installed. `~/intel/oneapi` has only compiler, dpcpp, mkl, dnnl, tbb, umf, tcm, dev-utilities. Full base kit not fetched. | Not used |
| `sycl-trace` (compiler 2026.0) | Present. Host-side UR/L0/SYCL call tracing; `--help` shows no device kernel timing. | Not used for timing |
| `ZE_ENABLE_TRACING_LAYER` / system `libze_tracing_layer.so` | API-call tracing only, no device timestamps. | Not used |
| pti-gpu `onetrace` | Deprecated upstream ("use unitrace"). | Not used |
| **pti-gpu `unitrace`** (commit 6c0d6b0b, 2026-09-28) | **Built in user space**, L0-only (`-DBUILD_WITH_{XPTI,ITT,OMP,OPENCL,MPI}=0`). Binary: `~/.hermes/cache/scratch/kprof/pti-gpu/tools/unitrace/build/unitrace`. Gives per-kernel device time (`-d`) and a full device timeline (`-t`). | **Chosen** |
| GGML op timing | Not present. `GGML_SYCL_*` env flags cover debug/XMX/FA selection, not timing. | Not used |

Lightest option that gives per-kernel GPU time: unitrace `-d`. Overhead: profiled decode ran at 22.5 t/s vs 38.0 clean. Per-kernel durations line up with clean timing (see the reconciliation in §2), so shares are usable.

## 2. Profile results

Logs: `bench/logs/kprof33-20261013-120705/`. All runs under the GPU lock via `bench/watchdog.sh`; one session per run. "Load" = weight upload + weight reorder at model load (6.97 GB, 1,326 of 1,445 H2D copies happen before the first kernel, `timeline-n8.172817.unitrace`). I excluded load time from shares.

### Clean (unprofiled) throughput

| Config | Result | Log |
|---|---|---|
| Decode tg128, base | **37.98 ± 1.18 t/s** (26.3 ms/token) | `clean-decode-base.log` |
| Decode tg128, `GGML_SYCL_UPLOAD_STAGING_SLOTS=0` | 36.24 ± 0.96 (no gain, within noise) | `ab-staging0.log` |
| Decode tg128, `GGML_SYCL_ENABLE_GRAPH=1` | **27.29 ± 1.77** (−28%) | `ab-graph1.log` |
| Prefill pp4096, ub 512 / 1024 / 2048 | 1131 ± 17 / **1569 ± 47** / 1708 ± 64 t/s | `clean-pp4k-ub512.log`, `clean-prefill-4k.log`, `clean-pp4k-ub2048.log` |
| MTP n=3 (llama-cli, one run) | gen **91.7 t/s**, prompt 40.9 t/s | `clean-mtp3.log` |

### Decode, 128 tokens, base — per-kernel (compute time 3,172 ms over 128 tokens = 24.8 ms/token)

Source: `decode-base.112278.unitrace`.

| # | Kernel | Share | Calls | Avg | Notes |
|---|---|---|---|---|---|
| 1 | `reorder_mul_mat_vec_q4_0_q8_1_sycl` (Q4_0 matvec, batch 1) | **69.8%** | 41,984 (328/token) | 52.8 µs | 6.13 GB/token weights → **354 GB/s in-kernel (78% of 456)** |
| 2 | `dequantize_mul_mat_vec_q6_K_sycl_reorder_esimd` (lm_head = tied token_embd, Q6_K, 787.5 MiB) | 8.2% | 128 | 2,025 µs | **408 GB/s (89% of peak)** |
| 3 | `lauch_kernel<flash_attn_tile<256,256,…>>` | 3.6% | 5,120 | 22.2 µs | 40 SWA layers |
| 4 | `rms_norm_mul_f32_sycl` | 2.7% | 12,288 | 7.0 µs | |
| 5 | `lauch_kernel<flash_attn_tile<512,512,…>>` | 2.4% | 1,024 | 75.6 µs | 8 global layers |
| 6 | `quantize_row_q8_1_sycl<…soa>` | 2.3% | 41,984 | 1.7 µs | activation quantize per matvec |
| 7 | `set_rows_sycl_q<float,long,block_q8_0,32>` | 1.9% | 12,288 | 4.9 µs | KV write |
| 8 | `rms_norm_mul_add_f32_sycl` | 1.8% | 12,160 | 4.7 µs | |
| 9 | `dequantize_block_sycl<32,1,dequantize_q8_0>` | 1.5% | 12,288 | 3.8 µs | KV dequant |
| 10 | `rms_norm_mul_f32_sycl` (variant) | 1.5% | 12,544 | 3.7 µs | |
| 11 | `rope_neox_sycl<true,float,float>` | 0.8% | 10,240 | 2.6 µs | |
| 12 | `rms_norm_f32_sycl` | 0.8% | 6,144 | 4.3 µs | |
| 13 | `launch_fwht<512,float>` | 0.6% | 2,048 | 10.0 µs | Hadamard transform |
| 14 | `bin_bcast_sycl` | 0.5% | 6,272 | 2.3 µs | |
| 15 | `launch_fwht<256,float>` | 0.3% | 10,240 | 1.1 µs | |

Per token: ~1,675 kernel launches. Per-token budget (clean 26.3 ms): Q4_0 17.3 ms, Q6_K lm_head 2.0 ms, FA tile 1.5 ms, everything else ~5.5 ms.

Reconciliation: GPU compute per token 24.8 ms vs clean wall 26.3 ms, so the GPU is busy ~94% of the decode loop. Launch and host gaps are small. The 3,485 H2D copies in the decode profile are the model upload (6.97 GB in 8 MB chunks). The only per-token copies are ≤15 KB and sum to negligible time (`timeline-n8.172817.unitrace`).

### Prefill, 4096 tokens, ub 1024 — per-kernel (compute 2,527 ms)

Source: `prefill-4k.113176.unitrace`.

| # | Kernel | Share | Calls | Avg | Notes |
|---|---|---|---|---|---|
| 1 | `gemm_kernel` (oneDNN library GEMM, f16) | **32.1%** | 1,300 | 624 µs | 325 matmuls × 4 ubatches |
| 2 | `dequantize_block_sycl<32,2,dequantize_q4_0>` (Q4_0 → f16 weights, every ubatch) | **28.8%** | 1,300 | 560 µs | |
| 3 | `micro_sdpa` (oneDNN SDPA prefill attention) | 7.6% | 192 | 1,001 µs | |
| 4 | `ggml_sycl_op_unary_gated<geglu>` | 7.4% | 192 | 968 µs | ~195 GB/s effective, ~43% of peak |
| 5 | `convert_unary_nc_sycl<float,half>` (activation F32→f16) | 7.3% | 1,300 | 143 µs | |
| 6 | `rms_norm_mul_add_f32_sycl` | 3.6% | 380 | 238 µs | |
| 7 | `rms_norm_mul_f32_sycl` | 2.4% | 392 | 158 µs | |
| 8 | `cont_to_f16_sycl<float>` | 1.9% | 192 | 245 µs | SDPA input |
| 9 | `permute_sdpa_out_sycl` | 1.8% | 192 | 242 µs | SDPA output |
| 10–15 | norms, set_rows, rope, fwht, bin_bcast | ~6% | | | |

Dequant share vs ubatch size (same 4K prompt; `prof-pp4k-ub512.176161.unitrace`, `prefill-4k…`, `prof-pp4k-ub2048.177537.unitrace`):

| ubatch | dequant share | dequant total | gemm share | clean t/s |
|---|---|---|---|---|
| 512 | 42.0% | 1,409 ms (2,600 calls) | 28.1% | 1131 |
| 1024 | 28.8% | 728 ms (1,300) | 32.1% | 1569 |
| 2048 | 15.7% | 349 ms (650) | 38.8% | 1708 |

Dequant time scales linearly with the number of ubatches, as expected for dequant-then-GEMM. GEMM time is roughly constant per token.

### MTP n=3 — per-kernel (compute 2,108 ms, includes prompt processing)

Source: `decode-mtp3.146755.unitrace` (llama-cli, 128 generated tokens). Full table in `summary.json`.

| Kernel | Share | Calls | Avg |
|---|---|---|---|
| `reorder_mul_mat_vec_q4_0_q8_1_sycl_ncols<4>` (verify, batch 4) | 36.5% | 13,776 | 55.9 µs |
| `dequantize_row_q4_0_sycl_reorder<half>` (prompt, batch >8) | 32.1% | 328 | 2,064 µs |
| `reorder_mul_mat_vec_q6_k_q8_1_sycl_ncols<4>` (lm_head, batch 4) | 6.0% | 41 | 3,099 µs |
| `reorder_mul_mat_vec_q4_0_q8_1_sycl` (draft head, batch 1) | 4.0% | 2,840 | 29.7 µs |
| `gemm_kernel` (prompt) | 2.9% | 328 | 186 µs |

Derived (inferred, not directly measured):
- 41 lm_head calls → **41 verify steps**. 128 tokens / 41 = **~3.1 tokens per verify step**, so ~2.1 of 3 drafts accepted.
- Clean: 128 tokens / 91.7 t/s = 1.40 s / 41 steps = **34 ms per verify step**, vs 26.3 ms per plain decode step. Net 2.4× over base (91.7 / 37.98).
- lm_head at batch 4 costs 3.10 ms vs 2.03 ms at batch 1 (+1.07 ms/step ≈ 3% of step). Q4_0 at batch 4 costs 55.9 µs vs 52.8 µs at batch 1, so verify reuses weights well.
- Unexplained: the prompt dequant runs 2.06 ms per call here vs 0.56 ms per call in the 4K prefill. Not investigated. A short prompt pays ~0.6 s of dequant once (clean prompt speed 40.9 t/s).

### Bandwidth check

- Q4_0 matvec: 6.13 GB/token (328 tensors, 5.71 GiB) / 17.3 ms = 354 GB/s in-kernel (78%).
- Whole token: 6.96 GB (Q4_0 + Q6_K lm_head) / 26.3 ms = **265 GB/s = 58%** of 456. RESUME's 38% does not reproduce from these logs. The gap to 100% is non-matmul time (~27% of token), not the matvec.

## 3. Hot kernels → source, and XMX/DPAS status

Paths under `engines/llama.cpp-sycl-tip/ggml/src/ggml-sycl/`.

| Hot kernel | Source | Engine | XMX/DPAS? |
|---|---|---|---|
| Q4_0 batch-1 matvec `reorder_mul_mat_vec_q4_0_q8_1_sycl[_ncols<N>]` | `mmvq.cpp:60–113` (template with `rows_per_sg`), `:802–848` (entry + ncols switch). Dot via `dpct::dp4a` in `vecdotq.hpp:190–264` | SIMD int8 dot (dp4a) | **No** |
| Activation quant `quantize_row_q8_1_sycl<…soa>` | `quantize.hpp` | SIMD | No |
| Q6_K lm_head (batch 1) `dequantize_mul_mat_vec_q6_K_sycl_reorder_esimd` | `dmmv.cpp:1874–1884` (ESIMD, `GGML_SYCL_ENABLE_ESIMD=1`) | ESIMD | No |
| Q6_K lm_head (batch 4, verify) `reorder_mul_mat_vec_q6_k_q8_1_sycl_ncols<4>` | `mmvq.cpp` | SIMD | No |
| Prefill weight dequant `dequantize_block_sycl<32,2,…q4_0>` | `convert.cpp:29`, reorder variant `convert.cpp:155` | SIMD (memory-bound writes of f16) | No |
| Prefill GEMM `gemm_kernel` | **Not in ggml-sycl source**: oneDNN kernel reached via `DnnlGemmWrapper::row_gemm` | oneDNN | Likely (library); **not verified here** |
| Fused dequant-GEMM (joint_matrix) | `fused-gemm.cpp` (11 joint_matrix hits), gate `fused-gemm.hpp:8` (`GGML_SYCL_FG_MAX_N = 64`), type list `fused-gemm.cpp:959–971`, call site `ggml-sycl.cpp:3135` | **XMX** | Yes |
| mmq (Q4_0 MMQ) | `mmq.cpp:1343–1351…` | `SYCL_USE_XMX` only changes tile constants; **no joint_matrix in mmq.cpp** | No |
| Prefill attention `micro_sdpa` (+ `cont_to_f16_sycl`, `permute_sdpa_out_sycl`) | `fattn-onednn.cpp`, selection `fattn.cpp:250–285`, `:387–` | oneDNN Graph SDPA | Likely (library); not verified |
| Decode attention `flash_attn_tile<D,…>` | `fattn-tile.cpp`, `fattn-tile.hpp` (0 joint_matrix/dpas hits). Chosen for quantized KV on BMG (`fattn.cpp:266–272`) | SIMD | No |
| `rms_norm_mul*`, `rms_norm_mul_add*` | `norm.cpp` | SIMD | No |
| `rope_neox_sycl` | `rope.cpp:318–452` (`nd_range<3>` parallel_for) | SIMD | No |
| softmax | `softmax.cpp:218–244` (`reqd_sub_group_size`) | SIMD | No |
| GEGLU | `element_wise.cpp:1020` (`ggml_sycl_op_geglu`), separate from matmul | SIMD | No |
| `launch_fwht`, `set_rows_sycl_q` | `fwht.cpp`, `set_rows.cpp` | SIMD | No |

Env defaults that matter (from `ggml-sycl.cpp` and the run logs): `GGML_SYCL_ENABLE_GRAPH=0` (`ggml-sycl.cpp:419`), `GGML_SYCL_FA_ONEDNN=1`, `GGML_SYCL_ENABLE_MKL_FA=1`, `GGML_SYCL_ENABLE_FUSION=1`, `GGML_SYCL_MMVQ_WIDE=1`, `GGML_SYCL_UPLOAD_STAGING_SLOTS=4`.

### Upstream llama.cpp since 358a420ec

Searched GitHub (ggml-org/llama.cpp) for SYCL, Battlemage/B580, flash-attn, rope, softmax, Q4_0 MMVQ/DMMV, MTP. Subagent search; four rows spot-checked against the GitHub API (titles, state, size match).

| PR | State | Title / relevance | Link |
|---|---|---|---|
| **#29864** | open (2026-10-02, +1150/−5) | "Multi-column on Intel XMX matrix engines refactored". **Same area as our prefill XMX gap.** | https://github.com/ggml-org/llama.cpp/pull/29864 |
| **#28725** | open (+387/−69) | "Add SYCL graph record and replay". Relevant to the graph-mode slowdown measured here. | https://github.com/ggml-org/llama.cpp/pull/28725 |
| **#30374** | open (2026-10-12, +42/−55) | "sycl: fix prompt-processing regression after Q4_0/Q8_0 weight reorder". Touches our Q4_0 prefill path. | https://github.com/ggml-org/llama.cpp/pull/30374 |
| **#30430** | open (post-cutoff, +262/−21) | "sycl: fix get_rows on reordered quantized weights" (fixes issue #30428). **Check:** Gemma's token_embd (Q6_K, tied) is reordered at load in our runs. | https://github.com/ggml-org/llama.cpp/pull/30430 |
| #30226 | open (2026-10-09) | "sycl: Q4_K MMVQ wide row pairing". Q4_K only, but the same rows-per-subgroup lever as our Q4_0 matvec. | https://github.com/ggml-org/llama.cpp/pull/30226 |
| #29338 | merged 2026-10-12 (already in base) | DMMV row-tail guard | https://github.com/ggml-org/llama.cpp/pull/29338 |
| #30156 | open | Device-side MoE scheduler. MoE only, not our dense model. | https://github.com/ggml-org/llama.cpp/pull/30156 |

No post-cutoff PRs touch SYCL flash-attention, rope, softmax, or Q4_0 MMVQ. No non-US sources found. Battlemage-only post-cutoff PR #30431 is Vulkan-only.

## 4. Ranked kernel-work opportunities

Gains are ceilings from the measured shares, not forecasts. Each needs a before/after run under the harness before it counts.

| Rank | Opportunity | Basis (measured) | Realistic gain | Risk | Effort | Path |
|---|---|---|---|---|---|---|
| 1 | **Prefill `-ub 2048`** (config only) | 1569 → 1708 t/s clean | **+9% prefill** | Compute-buffer VRAM not measured; run under the RESUME ramp rule (VRAM sampling) | None | Gate, then one run at 65536 ctx |
| 2 | **Q4_0 batch-1 matvec: more bandwidth** (rows-per-subgroup, work-group size, vdr) | 17.3 ms/token at 78% of peak | Matvec 17.3 → ~15 ms if 90% → **~+10% decode** | Low: dot math unchanged, `test-backend-ops` catches errors | Medium | Env flag `GGML_SYCL_MMVQ_*` in `engines/llama.cpp-sycl-dev`; A/B with `test-backend-ops perf -o MUL_MAT` and the harness. Analogue: #30226 |
| 3 | **Decode small-kernel fusion** (rms_norm+mul+add with quantize_q8_1; rope/set_rows) | ~5.5 ms/token non-matmul, ~1,675 launches/token | **~+10–15% decode** | Medium: quantize fusion changes numerics unless bit-identical | Medium–high | Start with quantize_q8_1 folded into the norm output; flag-gated |
| 4 | **Prefill GEGLU vectorize** (or fuse into the up-GEMM epilogue) | 7.4% of prefill, ~43% of peak | **~+5–7% prefill** | Low | Low (vectorize) to medium (fuse) | `element_wise.cpp:1020`; flag-gated |
| 5 | **Prefill weight dequant** (wide-N XMX dequant-GEMM; the existing fused path stops at N ≤ 64) | 29% at ub1024, 42% at ub512 | Up to ~+30–40% prefill (ceiling) | High: needs A-dequant amortized over N tiles | High | **Overlaps #29864.** Track or contribute there rather than fork. Small variant: add Q4_0 to `fused-gemm.cpp:959–971` for N ≤ 64 (one case + `fg_plain_ok`); helps only 9–64-token prompts |
| 6 | **MTP verify lm_head Q6_K at batch 4** | +1.07 ms/verify step (~3% of 34 ms) | ~3% MTP | Low | Low | Small patch to the `ncols<4>` Q6_K path; low value |
| 7 | **Long-context decode attention** (`flash_attn_tile`, split-K for occupancy) | Only ~6% now at ~4K context. **Not measured above 4K.** | Unknown until measured | Medium | Medium–high | Measure at 16K/32K first, under a Marcel-approved ladder |
| – | GRAPH=1 | −28% (27.3 vs 38.0) | Negative | – | – | Keep off. Upstream #28725 may change this |
| – | UPLOAD_STAGING_SLOTS=0 | No gain | 0 | – | – | Ignore |

### The 5 s xe job-timeout hypothesis

RESUME suspects a long flash-attention job exceeding the 5 s timeout during a 32K prefill. Evidence from these runs:
- Largest measured attention kernel: `micro_sdpa` max **3.5 ms** at 4K context, ub 1024. Linear extrapolation to 32K context is ~28 ms per call. Two orders of magnitude under 5 s.
- The RESUME crash log shows "Fault response: Unsuccessful -ENOENT" (GPU page faults), which points more at memory pressure than kernel length.
- **Not verified:** nothing above 4K was profiled. Splitting the FA job would not help if the cause is memory. Measure 16K/32K per-kernel max under the VRAM-sampling ladder before changing FA.

## 5. GT 1030 (sm_61) CUDA side

Not measured here. Spec from `research/17-gt1030-plan.md`: GP108, 384 cores, 2 GB, **48 GB/s**, no tensor cores, cc 6.1 (dp4a available). FP16 on consumer Pascal runs at a small fraction of FP32 (roughly 1/64; general NVIDIA spec knowledge, not checked). ggml-cuda's Pascal paths are dp4a MMQ/MMVQ and FP32 kernels. Whisper CUDA built: `logs-gt1030/build-whisper-cuda.log` ends `BUILD_OK`.
Verdict: **not worth kernel work now.** At 48 GB/s and 2 GB, decode is bandwidth-capped far below the B580, and the only plausible job is a whisper encoder offload where stock ggml-cuda is already the right code path. Measure first, then decide.

## 6. Self-check

- Every number above has a log path (see §2 headers and `summary.json`).
- GPU lock: both of my run sessions exited (`EXIT=0` in `~/.hermes/cache/scratch/kprof/run-prof{,2,3,4}.log`). The lock is currently held by another agent. Not mine.
- No server left running by me. The one live `llama-server` is another agent's (§0).
- No kernel reset this boot: `journalctl -k -b | grep -cE 'GT0: Engine reset|device wedged|Timedout job|DEVICE_LOST|devcoredump'` → **0**. The `GT0` lines that match `GT0|wedged|DEVICE_LOST` are the three boot-time GuC/ccs init lines only.
- `bench/.gpu-reset-ack` not created. No `--force`.
- No engine source modified. Files created: this doc; `bench/logs/kprof33-20261013-120705/` (logs, scripts, `summary.json`); unitrace build in the scratch directory.

## Next steps (not done)

1. Gate and run `-ub 2048` at ctx 65536 with VRAM sampling. Decide whether to make it the default for prefill.
2. Build `engines/llama.cpp-sycl-dev` (copy, not the tip) and prototype rank 2 (Q4_0 mmvq) behind an env flag. A/B with `test-backend-ops perf -o MUL_MAT` and the harness.
3. Check #30430 against our tied Q6_K token_embd before relying on GET_ROWS.
4. Decide with Marcel whether to contribute to #29864 (prefill XMX) rather than fork.
5. Profile 16K and 32K only under Marcel's approved ladder.
