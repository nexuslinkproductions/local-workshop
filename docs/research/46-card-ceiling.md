# Card: timing-only "global layers see 2K tokens" ceiling for Gemma 4 decode (BRIEF-46 R0.3)

Worktree: /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/engines/llama.cpp-sycl-dev, branch `lc46/ceiling-and-draft-ctx` (cut from 358a420ec). Work ONLY here.
Do NOT touch engines/llama.cpp-sycl-tip (a benchmark uses it), bench/.gpu.lock exclusive, or any GPU process. You may NOT run any model. Build only.

## Goal
An env-gated, QUALITY-IGNORING hack that lets Marcel measure the upper bound of what a sparse method on Gemma 4's 8 global layers could gain in decode. Output text will be wrong beyond the window; that is expected. Default behaviour with the env unset must be byte-for-byte unchanged.

## What to build
Env `LC46_GLOBAL_KEEP=N` (integer, 0/unset = off). When set and N>0, ONLY for single-token decode (n_tokens==1) and ONLY for the non-SWA ("base") attention layers of `LLM_ARCH_GEMMA4` (llama_kv_cache_iswa `kv_base`; Gemma 4 12B has 8 such layers of 48):
1. Mask: in `llama_kv_cache::set_input_kq_mask` (src/llama-kv-cache.cpp) for the base cache of an iswa pair, set to -INFINITY every cell whose pos is NOT in {pos < 4 (sinks)} ∪ {the N most recent positions of the query's sequence}. Everything else untouched. Prefill batches (n_tokens>1) stay dense.
2. n_kv_max: for those same layers pass `n_kv_max = N + 4 + 256` to the FA node (see `build_attn_mha(..., n_kv_max, ...)` at src/llama-graph.cpp ~2855-2906 and `ggml_flash_attn_ext_set_n_kv_max`, ggml/include/ggml.h:2505; callers that already pass it: src/models/deepseek4.cpp:759, qwen4exp.cpp). The iswa `build_attn` overload that Gemma 4 uses (src/models/gemma4.cpp:274) currently passes 0; plumb the value through with the smallest diff (e.g. read the env once in the graph context and apply only when `!hparams.is_swa(il)` and `n_tokens==1`).
3. The SYCL sparse path (ggml/src/ggml-sycl/fattn-sparse.cpp, applicable() at ~line 117, dispatch fattn.cpp:284) is only taken when env `GGML_SYCL_SPARSE_FA=1` is set at run time; do not change that default. Check by reading the code whether Gemma 4's global layers meet every `sparse_fa_applicable` condition (head dim 512, 1 KV head, GQA 16, K/V types q4_0/q8_0/f16, mask F16, no softcap). If a condition fails (e.g. head dim 512 not supported, quantised K/V not supported), report exactly which and make the minimal fix IF it is small; otherwise report the blocker.
4. Add a startup log line (LLAMA_LOG_WARN) when LC46_GLOBAL_KEEP is active, with N, so a log proves the hack was on.

## Build (CPU only; under the SHARED GPU lock, -j 6, memory-capped)
```
cd /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/engines/llama.cpp-sycl-dev
set +u; . /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh; set -u
cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DGGML_SYCL_F16=ON -DGGML_SYCL_DEVICE_ARCH=bmg -DDNNL_DIR=/home/nexuslink/intel/oneapi/dnnl/2026.0/lib/cmake/dnnl
CAP=12G ~/.local/bin/jobcap flock -s /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu.lock cmake --build build -j 6 --target llama-bench llama-server
```
The shared flock may wait a long time if a benchmark holds the exclusive lock; that is fine, wait. (Reference: research/11-sycl-build.md. A clean full build took ~4 min at -j 20; expect ~10-15 min.) If the build runs > 40 min with no progress, stop and report.

## Acceptance (you do these, no GPU)
- `git diff --stat` small (target < 120 lines). Commit on the branch with a clear message. Do not push.
- Build exits 0; `build/bin/llama-bench` and `llama-server` exist.
- With env unset the added code paths are inert (show by reading the diff, say which lines).
- Write a 10-line note `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/research/46-patch-notes-ceiling.md`: files, LOC, what is inert when unset, the sparse_fa_applicable verdict for Gemma 4 global layers (each condition: ok / fails + file:line), how to run (`LC46_GLOBAL_KEEP=2048 GGML_SYCL_SPARSE_FA=1 llama-bench ... -d 65536`).
- Kill every process you start; end your reply with the `ps -eo pid,ppid,etime,args | grep -E 'ninja|icpx|llama|cmake'` output.
