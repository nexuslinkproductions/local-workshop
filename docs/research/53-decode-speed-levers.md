# 53 - Decode speed levers: Ornith-1.5-9B and MiniCPM-V-4.7-35B-A3B at 256K on the B580

Date: 2026-10-13. Research only: no GPU jobs, no server, no downloads, no builds, no bench lock.
Engine read: `engines/llama.cpp-sycl-tip` at 358a420ec (build flags from `build/CMakeCache.txt`).
Tags: [Mu] measured on this box (file cited). [Me] measured by someone else (cited). [C] claimed by a
vendor, author or model card. [S] read in our source (file:line). [I] my inference, not measured.

## 0. Baseline to beat

- Ornith Q4_K_M, 256K, q4_0 KV, vision on CPU, `-ub 512 -b 512`, all weights on GPU: 46.2 t/s decode,
  29.5K prefill 1741 t/s, min free 987 MiB [Mu research/00-plan.md, entries 19:42 and 20:01].
- Ornith `-ub 256` `-t 16`: 50.9 t/s decode, 35.3 t/s after a 30K prompt, prefill 1156 at 30K, min free
  945 MiB [Mu bench/bakeoff42/logs/speed-push.tsv, row or-ub256]. Same file, `-t 12` at ub256: 55.9 t/s,
  35.0 after 30K, min free 774 MiB [Mu, row or-t12, single run].
- MiniCPM AD-Q4_K-IQ4_XS, 256K, q4_0 KV, ncmoe 28, vision on GPU, `-t 16`: 41.0 t/s, 29.3 after 30K,
  pp 664 [Mu speed-push.tsv, row mc-base28]. `-t 6`: 45.8 t/s (single run) [Mu, row mc-t6]. `-t 8`: 35.0
  (after-30K 7.8, an outlier) and `-t 12`: 39.5 [Mu, rows mc-t8, mc-t12].
- Hard limits: floor 750 MiB free; engine reset seen at 331 MiB; ncmoe 24 or lower at 262144 is unsafe
  [Mu research/00-plan.md, entries 20:20 and 21:00].
- Roofline: Ornith trunk is 5.62 GB, so 456 GB/s gives about 81 t/s weight-read ceiling [I]. We are at
  57 to 69 percent of it. Only speculation (one weight pass verifies several tokens) can exceed it [I].

## 1. Facts read from the files (not from notes)

- Ornith Q4_K_M header: 442 tensors. `blk.32` (the NextN/MTP block) has all 15 tensors: attn q/k/v/o,
  ffn gate/up/down, nextn eh_proj/enorm/hnorm/shared_head_norm, 144 MiB total [Mu, GGUF header read
  2026-10-13, models/llm/ornith-ai/Ornith-1.5-9B-GGUF/Ornith-1.5-9B-Q4_K_M.gguf].
- MTP tensors are skipped unless MTP is requested (`llama-model.cpp:3856-3872`, `TENSOR_SKIP` when
  `!ml.load_mtp`). So the 144 MiB only costs VRAM in MTP runs [S].
- Ornith KV: 8 attention layers (3, 7, ..., 31) x 4 KV heads x 256 x (K+V). q4_0 = 9.2 KB/token = 2.25 GiB
  at 256K; q8_0 = 4.25 GiB; f16 = 8 GiB [I from header]. Only q4_0 fits beside the weights, so KV type
  is not a free knob here (matches Marcel's rule).
- MiniCPM header: 40 layers, 10 attention layers (every 4th), 2 KV heads, no `nextn_predict_layers` key,
  so no MTP head [Mu]. Experts 17.45 GB = 436 MB per layer; non-expert 2.67 GB [Mu, header read]. One
  ncmoe step therefore frees 436 MB of VRAM [I].
- Ornith GDN: state size 128, 32 value heads, 16 key groups [Mu header].
- Conflict: protoLabsAI's card says stock Ornith GGUFs carry 0 of 760 `mtp.*` tensors and that a
  427-tensor file fails with "expected 442 got 427" [C huggingface.co/protoLabsAI/Ornith-1.5-9B-MTP-GGUF].
  Our file has 442, so the head is present. Its acceptance rate is unknown until measured.

## 2. Engine facts (tip 358a420ec)

- Build: GGML_SYCL_GRAPH=ON, DNN=ON, F16=ON, DEVICE_ARCH=bmg, GGML_NATIVE=ON. CPU weight repack is on by
  default; `-nr` turns it off [S build/CMakeCache.txt; common/arg.cpp:2424-2431; ggml/CMakeLists.txt:152].
- SYCL env defaults: ENABLE_OPT=1 (ggml-sycl.cpp:418), GRAPH=0 (:419), FA_ONEDNN=1 (:421), MKL_FA=1 (:423),
  FUSION=1 (:427), MMVQ_WIDE=1 (:429), SPARSE_FA=0 (:464). `GGML_SYCL_NO_PINNED` disables malloc_host
  (common.cpp:27).
- Reorder fast path (ENABLE_OPT) covers Q1_0, Q4_0, Q8_0, Q2_K to Q6_K. IQ4_XS is not in the list
  (ggml-sycl.cpp:4235-4249). Reorder is enabled only on Intel GPU (:240) [S].
- Decode FA routing: on bmg_g21/g31 a decode step (Q<=2) uses TILE for quantized KV and for GQA
  (fattn.cpp:260-278); VEC only otherwise [S]. Ornith (D=256, GQA 4) therefore runs flash_attn_tile<256>.
  No per-kernel profile of Ornith exists yet [I].
- oneDNN flash attention needs Q>=32 (fattn.cpp:135; fattn-onednn.cpp:15). It is prefill-only, zero decode
  effect [S].
- SYCL graph: GRAPH=1 measured -28% decode on Gemma (research/33-kernel-work.md, lines 12, 39, 172) [Mu].
  Upstream PR #28725 "Add SYCL graph record and replay" is still open [gh api, 2026-10-13].
- Level Zero immediate command lists: libsycl 2026.0 strings contain SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS,
  UR_L0_USE_IMMEDIATE_COMMANDLISTS and UR_L0_IMMEDIATE_COMMANDLISTS_BATCH_MAX (~/intel/oneapi/compiler/2026.0/lib/
  libur_adapter_level_zero.so) [S]. Defaults are not visible in strings. configs/sycl-env.sh sets none [S].
  On Gemma the GPU was busy 24.8 of 26.3 ms per token, so launch overhead is at most about 6 percent
  (research/33 line 12) [Mu].
- GDN kernel (src/ggml-sycl/gated_delta_net.cpp): one work-item per state column, warp reduce, serial token
  loop inside the kernel, grid (H, seqs, S_v/4), block 32x4, state read and written once per call. The
  launch code carries a "TODO: Add chunked kernel" comment [S]. Decode state traffic is about 2 MiB read
  and 2 MiB write per GDN layer per token, so about 100 MB per token and about 0.2 ms at 456 GB/s [I].
  The kernel is not the bandwidth limit, but it is not tuned for decode either.
- Correctness risk: upstream issue #29183 "[SYCL] DeltaNet kernel produces token soup on long prompts"
  (opened 2026-09-20, open) reports garbage above about 2K tokens on Qwen3.6 and Qwen3.8 over SYCL
  [C github.com/ggml-org/llama.cpp/issues/29183]. Our Ornith suite ran 29.5K prompts with no reported fault
  [Mu 00-plan, 20:01], but no 256K needle test on Ornith is recorded. Gate every lever on a 256K needle test.
- MoE cache: `--moe-cache-mib N` exists (common/arg.cpp:2780-2787). PRs 29887 and 30112 merged 2026-10-07
  and 10-08 [gh]. The code is device-generic (src/llama-moe-cache.cpp: LRU per layer group, host-resident
  weights only) [S]. At 512 MiB it holds about 300 experts, about 7 per layer against 8 active per token,
  so hit rate is likely low for a near-uniform router [I]. Each 436 MB of cache equals one whole layer moved
  to GPU, which removes that layer's CPU work and its host hop. Unless routing is strongly skewed, the same
  VRAM is worth more as a GPU layer [I]. Reported 1.6x and 2.2x gains are CUDA with a 6.4 GB cache
  [C research/51-recipes-from-posts.md, A3].
- MTP for qwen35: `graph_mtp` (src/models/qwen35.cpp:500-560) runs one full-attention block with its own KV
  (filter `il >= n_layer`, src/llama-model.cpp, MTP branch, approx. 2949-2974) [S]. Draft context equals
  target context (research/46-long-context-speed.md, WS-C), so the MTP compute buffer scales with ctx times
  ub. Measured 834 MiB on Gemma at 256K/ub512 [Mu research/46 section 2].
- Speculation types in tip: ngram-simple, ngram-map-k, ngram-mod, draft-mtp (common/speculative.cpp:76-83).
  Docs: MoE models need long drafts; dense models may lower n-min and n-max (docs/speculative.md:162-186) [S].
- Load and host memory: `-lm dio` is used (direct I/O). davetha found mmap page faults on CPU experts and
  that `--no-mmap` plus THP=always helps (prefill 83 to 197 t/s) [Me github.com/davetha/llama-moe-hybrid-tuning
  FINDINGS.md]. THP is already "always" here [Mu, /sys/kernel/mm/transparent_hugepage/enabled]. CPU governor
  is "powersave" [Mu]. davetha reports performance governor as a single-digit gain [Me].

## 3. Ornith-1.5-9B: ranked levers (all weights on GPU, q4_0 KV, 256K)

| # | lever | exact flag or env | mechanism on this box | expected gain (source) | VRAM cost | risk | one-point test |
|---|---|---|---|---|---|---|---|
| 1 | MTP self-speculation | `--spec-type draft-mtp --spec-draft-n-max 2` (then 3), `--spec-draft-type-k q4_0 --spec-draft-type-v q4_0` | Weights are read once per verify pass, so 2 to 3 drafted tokens ride one weight pass. Decode is bandwidth-bound (ceiling about 81 t/s) | Other Ornith heads: 1.06x (stock Q4_K_M, CUDA) to 1.77x (distilled head, Q8 on Blackwell) [C protoLabs card]. Expected here 1.1 to 1.4x [I] | head 144 MiB + draft KV 288 MiB + draft compute buffer (unmeasured). Floor is the limit: ub256 min free is 945 MiB, so MTP likely breaches 750 | VRAM breach or GPU reset (331 MiB precedent). Output not bit-identical at temp 0 [C] | Point `or-mtp2-ub256` in speed-push.sh with the gate lowered from 1150. Read acceptance from server log |
| 2 | Thread count matched to CCD1 | `-t 12` (cpus 6-11,18-23 = 12 logical CPUs) instead of `-t 16` | `-t 16` oversubscribes the 12 pinned logical CPUs; host sync threads compete | 50.9 to 55.9 t/s, single runs [Mu, speed-push.tsv rows or-ub256 and or-t12]. Expected +5 to 10 percent [I] | 0 | low | Or-t12 with ub256, 3 reps at depth 0 and 30K |
| 3 | Smaller batch and ubatch | `-ub 256 -b 256` | Smaller prefill compute buffer; decode is one token so decode speed barely depends on ub | +10 percent cross-run (50.9 vs 46.2) [Mu]. Prefill falls about 34 percent (1156 vs 1741 at 30K) [Mu] | frees about 0.1 to 0.2 GiB [I] | low; prefill cost | Run decode-only session at ub256 and compare |
| 4 | Q4_0 weights instead of Q4_K_M | Q4_0 GGUF (exists upstream [C NANI-Nithin card]) | Q4_0 is on the SYCL reorder fast path (ggml-sycl.cpp:4235); Q4_K_M is too. Smaller file frees VRAM for MTP | 0 to 10 percent [I]. No Ornith Q4_0 measurement exists | about 0.2 GB less than Q4_K_M [I] | quality change; needs Chief suite | Same flags, Q4_0 vs Q4_K_M, decode at 0 and 30K |
| 5 | n-gram speculation (CPU only) | `--spec-type ngram-mod --spec-ngram-mod-n-match 24 --spec-ngram-mod-n-min 8 --spec-ngram-mod-n-max 32` | Repeated text (code edits, tool-call JSON, invoice boilerplate) lets the target verify drafted tokens from history | 0 to 30 percent on repetitive prompts [I]. davetha found n-gram neutral on MoE [Me] | 0 (about 16 MB host RAM) | low; output checked by verify | Replay 10 Chief tool-call prompts, log acceptance |
| 6 | Launch overhead env flip | `UR_L0_USE_IMMEDIATE_COMMANDLISTS=0` vs `=1` | Per-kernel submission cost; about 6 percent ceiling from Gemma busy time [Mu research/33 line 12] | at most about 6 percent [I] | 0 | low | One decode run per setting |
| 7 | Exact FA decode kernel (depth) | Branch `lc46/fa-decode` at e632d64de (WIP, per research/46 section 5). Env knobs GGML_SYCL_FA_FORCE_VEC, _TILE_NCOLS1, _MIN_PB are NOT in tip [S] | Depth cost is kernel-bound. Ornith goes 50.9 to 35.3 t/s at 30K: +8.7 ms per token. KV bytes at 30K are 0.28 GB, which is 0.6 ms at 456 GB/s [I] | Gemma estimate +12 percent at 32K, +30 percent at 64K [Mu research/46 section 4b, not measured end to end] | 0 | WIP, unmeasured; correctness not reviewed | unitrace at 32K (lever 5 of the experiments below) |
| 8 | Sparse FA on global layers | `GGML_SYCL_SPARSE_FA=1` plus an `n_kv_max` patch not in tip [S, research/46 WS-B] | Restricts attention to top keys | Gemma ceiling +40 to +49 percent at 64K; output changes by design [Mu research/46 section 4] | 0 | quality change; patch needed | Deprioritized |
| 9 | GDN kernel rewrite | none exists | GDN is about 0.2 ms per token [I], so the ceiling is small | <1 percent [I] | 0 | effort high | Not recommended |

Not recommended for Ornith:
- SYCL graph (GRAPH=1): -28 percent on Gemma [Mu research/33].
- KV type change: f16 or q8_0 at 256K does not fit beside 5.6 GB of weights [I]. K q8_0 with V q4_0 would need about 3.3 GiB at 256K [I]. Both break the q4_0 hard requirement.
- IQ4_XS weights: not on the SYCL reorder list (ggml-sycl.cpp:4235) and i-quants are slower on Arc [Mu research/40 card 15].
- OpenVINO GenAI: no Ornith IR found. An IR exists for the base model OpenVINO/Qwen3.5-9B-int4-ov (INT4_ASYM, OV 2026.2 or newer) [C huggingface.co/OpenVINO/Qwen3.5-9B-int4-ov]. GenAI reports qwen35 GatedDeltaNet on GPU and MTP for Qwen3.5/3.6 in 2026.4.0 [C research/49-openvino-moe.md]. Needs a conversion and a measurement; not run.
- vLLM XPU INT4: third-party Ornith INT4 checkpoints exist (letechlead/Ornith-1.5-9B-INT4-W4A16-AutoRound, cyankiwi/Ornith-1.5-9B-AWQ-INT4) [C HF]. Blockers: vLLM XPU uses fp8 KV, which breaks the q4_0 rule [Me research/52-0xsero.md section 5]; vLLM issue #53211 reports AutoRound int4 emitting garbage under concurrency on a B70, with partial corruption on the 9B base [C github.com/vllm-project/vllm/issues/53211]; PMZFX reports vLLM XPU lacks the Qwen3.5 GDN kernels [C github.com/PMZFX/intel-arc-pro-b70-benchmarks]. Verdict: reject under current rules.

## 4. MiniCPM-V-4.7-35B-A3B: ranked levers (experts on CPU, 256K, q4_0 KV)

| # | lever | exact flag or env | mechanism on this box | expected gain (source) | VRAM cost | risk | one-point test |
|---|---|---|---|---|---|---|---|
| 1 | Threads = CCD1 physical cores | `-t 6` with cpus 6-11 (6 cores, one thread each) | Expert matmuls run on CPU threads; 16 threads on 12 logical CPUs oversubscribe | +11.7 percent, 45.8 vs 41.0, single run [Mu speed-push.tsv rows mc-t6, mc-base28]. Expected +5 to 12 percent [I] | 0 | low; t8 outlier shows run noise | mc-t6 at ncmoe 28, 3 reps at 0 and 30K |
| 2 | Fewer CPU expert layers | `--n-cpu-moe 26` with `--no-mmproj-offload` | Each layer moved to GPU removes that layer's CPU work and host hop | ncmoe 41, 36, 32, 28 gave 32.9, 38.4, 40.6, 42.9 t/s [Mu 00-plan, entry 20:20, NO_PINNED sweep]: about +0.8 t/s per layer [I]. min free 2465 MiB at ncmoe 28 [Mu tsv]. mmproj on CPU frees about 350 MiB on Gemma [Mu research/46 section 6] | 436 MB per layer; vision to CPU frees about 0.35 GB [I] | GPU reset seen at ncmoe 24 with 331 MiB free (20:20) | ncmoe 26 at 30K prefill first, floor 750, watchdog on |
| 3 | n-gram speculation | `--spec-type ngram-mod` as in Ornith lever 5 | CPU only | neutral on MoE [Me davetha FINDINGS.md] | 0 | low | One replay pass |
| 4 | Move expert cache to GPU | `--moe-cache-mib 512` | Hot experts on GPU; misses copy over PCIe 4.0 x8 | 0 to 10 percent [I]. cache points were skipped by VRAM gates in speed-push [Mu] | 512 MiB, about 1.2 layers | VRAM steal; likely low hit rate (section 2) | One point at ncmoe 28 with hit stats |
| 5 | CPU governor | `cpupower frequency-set -g performance` (needs root; ask Marcel) | Boost clocks for CPU expert work | single-digit percent [Me davetha] | 0 | low | Compare decode before and after |
| 6 | Speculation with MTP | none: no NextN head in this GGUF [Mu header] | n/a | n/a | n/a | n/a | Reject. DSpark exists only in the llama.cpp-omni fork [C research/51] |

Depth: 41.0 to 29.3 t/s at 30K is +9.7 ms per token. The 10 attention layers read about 0.17 GB of KV at
30K, which is well under 1 ms [I]. The depth cost is kernel-bound, the same finding as Ornith lever 7.

## 5. Expert placement and CPU topology notes

- `--n-cpu-moe N` (`-ot exps=CPU` family) puts the experts of N layers on CPU. Each CPU layer costs one
  GPU-to-CPU-to-GPU hop per token. The count of hops is what matters, not the bytes [I]. Per-tensor `-ot`
  (gate, up, down separately) does not reduce hops, it only changes bytes per layer [I]. I did not verify
  the layer ordering inside `llm_add_n_cpu_ffn_overrides` in arg.cpp.
- CPU expert bytes per token: 8 experts x 36 CPU layers x 1.70 MB = about 0.49 GB. At the measured pinned
  bandwidth of 63 GB/s that is about 7.7 ms, but the token takes about 24 ms. So the CPU path runs near
  20 GB/s, not at the memory limit [I]. A likely cause is one CCD's bandwidth (cpus 6-11,18-23 are one CCD).
  Not measured. Test with a stream run on that cpu set [I].
- NUMA: single node, so NUMA tuning does not apply [Me davetha]. `lscpu` not checked here.
- THP and no-mmap are already in place (section 2). Do not spend a run on them.

## 6. Top 6 experiments, in order (one point each, under bench/.gpu.lock, watchdog on, floor 750 MiB)

1. Ornith `-t 12 -ub 256 -b 256`, 3 reps at depth 0 and 30K, plus a 256K needle test. This is the baseline
   for everything below (expect 52 to 56 t/s).
2. Ornith MTP: `--spec-type draft-mtp --spec-draft-n-max 2`, then 3, with `-ub 256`. Log acceptance and min
   free. Accept only if decode is at least 1.15x, min free is at least 750 MiB, and the needle passes. This is
   the largest possible gain.
3. MiniCPM thread sweep at ncmoe 28 with vision on GPU: `-t 6`, `-t 12`, `-t 16`, 3 reps each at 0 and 30K.
4. MiniCPM `--n-cpu-moe 26` with `--no-mmproj-offload`, 30K prefill first, then decode. Expect +3 to 5 percent.
5. Unitrace decode profile at 32K for both models (harness of research/46 section 5). This sizes the FA share
   and decides whether the lc46/fa-decode kernel work is worth doing.
6. Ornith Q4_0 versus Q4_K_M at baseline flags (needs Marcel's approval for a download), plus the
   `UR_L0_USE_IMMEDIATE_COMMANDLISTS` flip if time allows. Q4_0 may free VRAM for MTP.

## Not done

- No GPU runs, no server, no downloads, no builds, no bench lock.
- The Ornith MTP head's quality (graft or original) is unknown; acceptance decides it.
- Level Zero immediate-command-list defaults were not confirmed from source.
- The GuC firmware version was not checked (davetha reports 70.58 to 70.65 removed instant faults on Battlemage).
