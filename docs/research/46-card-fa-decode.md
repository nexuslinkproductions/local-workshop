# Card 2: make Gemma 4's global-layer decode attention fast (BRIEF-46, exact kernel route)

Worktree: /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/engines/llama.cpp-sycl-dev. First: `git checkout -b lc46/fa-decode` from the current HEAD (243a5b4c7, keeps the LC46_GLOBAL_KEEP ceiling hack; do not remove it). Work ONLY in this worktree. Never touch engines/llama.cpp-sycl-tip.

## Measured facts (do not re-derive)
- Gemma 4 12B: 8 global layers (K/V head dim 512, 1 KV head, 16 query heads => GQA 16) + 40 SWA layers (head dim 256, 8 KV heads, window 1024). Single-token decode (Q->ne[1]==1).
- Decode t/s on the B580 (Xe2, 20 Xe cores) with f16 KV: 38.8 at depth 0, 34.3 at 8K, 28.2 at 32K, 25.9 at 64K. With the 8 global layers capped to 2K tokens it is flat ~36. So ALL the depth penalty is the global-layer FA kernel: 11 ms/token at 64K for 1 GiB of KV = ~90 GB/s effective vs 456 GB/s peak.
- unitrace (bench/logs/r46/prof/prof-f16.*.unitrace, f16 KV, depth 32768, 24 tokens): `flash_attn_tile<512,512,2,16,false,32>` 192 calls, avg 680 us (min 615, max 2565 us) = 5.4 ms/token over 8 layers at 32K (K+V = 64 MiB per layer per call => ~99 GB/s); SWA `flash_attn_tile<256,256,1,2,false,32>` 960 calls avg 63 us.
- Selection: ggml/src/ggml-sycl/fattn.cpp (~l.255-285): Q->ne[1]==1 && f16 K/V && gqa_opt_applies => TILE (VEC only when !gqa_opt_applies); quantised KV on BMG => TILE. Launch + split-K logic: fattn-common.hpp launch_fattn (~l.910-1190: `parallel_blocks`, `stream_k`, `blocks_per_wave` heuristics, combine kernel at ~l.786-830). Kernels: fattn-tile.hpp (tile), fattn-vec.hpp (vec).
- Hypotheses to test, in order: (a) parallel_blocks too small for 1 KV head x 64K tokens (only a few work-groups => low occupancy on 20 Xe cores); (b) ncols1=2/ncols2=16 tile wastes half its columns for a 1-token decode (try an ncols1=1 instantiation or ncols2=16 x ncols1=1); (c) VEC kernel is faster for this shape; (d) K-dequant cost for q4_0/q8_0 dominates the tile path (q4_0 is the slowest KV type, 20.2 t/s at 64K vs f16 25.9: so there is also a dequant-in-registers inefficiency).

## Task
1. Add runtime env knobs (default = current behaviour, byte-identical when unset): `GGML_SYCL_FA_FORCE_VEC=1` (use VEC for Q->ne[1]==1 decode whenever the VEC kernel supports the shape/type), `GGML_SYCL_FA_MIN_PB=<n>` (lower bound for parallel_blocks in launch_fattn for decode), plus whatever else your analysis says matters. Log the effective choice once per (D, n_kv bucket) at GGML_SYCL_DEBUG>=1 only.
2. Build `test-backend-ops` and add PERF cases (not correctness cases) for the Gemma global shape: hsk=hsv=512, nh=1, nr23={16,1}, nb=1, mask=true, kv in {8192, 32768, 65536}, K/V types f16, q8_0, q4_0, kv_view/permute like the existing KV-cache-style cases (see tests/test-backend-ops.cpp ~l.11605-11700 for the existing FLASH_ATTN_EXT list and l.11695 for a precedent). Same for the SWA shape hsk=hsv=256, nh=8 (1 KV head group GQA 2), kv=1024... only if cheap.
3. Measure with `test-backend-ops perf -o FLASH_ATTN_EXT -b SYCL0 -p <filter>` for each knob setting; record us/run and effective GB/s (K+V bytes / time) in a table. Find the best exact setting. If a code change (new instantiation, better split-K) is needed, implement it minimally; the results must stay numerically within test-backend-ops tolerances (run `test-backend-ops test -o FLASH_ATTN_EXT -b SYCL0` for hsk 64/128/256/512 once at the end; it must pass exactly as the unpatched build does).
4. Only if the best setting is a clear win (> 20 % kernel time at kv=32768 and no loss elsewhere) propose making it the default in code; otherwise leave default unchanged and just ship the knobs.
5. Commit on lc46/fa-decode. Write `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/research/46-patch-notes-fa-decode.md`: files, LOC, knob list, the perf table (before/after per kv and type), the test pass/fail result, and what you could not resolve.

## GPU rules (hard)
- You MAY use the GPU only through `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/r46-gpu.sh <timeout-seconds> <cmd...>` (takes the shared exclusive lock, runs the gates and the watchdog, kills on timeout). One GPU command at a time, each <= 300 s except the final correctness run (<= 900 s). Wait for the lock; do NOT bypass it, do NOT use --force, never touch bench/.gpu-reset-ack. If r46-gpu.sh exits 4 (xe reset/wedge) STOP immediately and report.
- Example: `bench/r46-gpu.sh 240 engines/llama.cpp-sycl-dev/build/bin/test-backend-ops perf -o FLASH_ATTN_EXT -b SYCL0 -p 'hsk=512'` (the oneAPI env is sourced by the script; the SYCL device is named SYCL0).
- Do not run llama-server/llama-bench; I measure the end-to-end t/s myself.

## Build (CPU; shared lock; -j 6; memory-capped)
```
cd /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/engines/llama.cpp-sycl-dev
set +u; . /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/configs/sycl-env.sh; set -u
CAP=12G ~/.local/bin/jobcap flock -s /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu.lock cmake --build build -j 6 --target llama-bench llama-server test-backend-ops
```
(build/ is already configured; the sycl-env.sh source is required, it carries the dnnl include path.)

## Finish
Kill every process you start; end your reply with `ps -eo pid,ppid,etime,args | grep -E 'ninja|icpx|llama|test-backend|cmake'` output. Stop and report if a single build step exceeds 40 min or the lock wait exceeds 2 h.
