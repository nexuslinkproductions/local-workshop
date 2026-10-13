# 34 — Source/log notes: why Gemma 4 12B SYCL dies at ctx 131072/262144

Read-only investigation 2026-10-13. No GPU job, no server start, no sudo, nothing else written.
Engine: `engines/llama.cpp-sycl-tip`. Model hparams verified from the GGUF header this session.

## A. The sweep logs do NOT contain buffer sizes

`~/.hermes/cache/scratch/ctxsweep-{65536,131072,262144}.log` were written at `verbosity = 3`
(`ctxsweep-131072.log:2`). In this build, `LLAMA_LOG_INFO` maps to `LOG_LEVEL_TRACE = 4`
(`common/log.cpp:532-543`, `common/log.h:24-32`), so every INFO line — including
`llama_kv_cache: … KV buffer size` (`src/llama-kv-cache.cpp:291`) and
`sched_reserve: … compute buffer size` (`src/llama-context.cpp:840`) — is suppressed below verbosity 4.
`ctx-sweep.py:82-84` greps exactly those lines; the `kv_log` field is `""` in every jsonl row,
confirming they are absent. (The `research04/probe2-*.log` files do contain them because they ran at
`verbosity = 4`.) **To get the real numbers the sweep must be re-run with `-lv 4`.**

## B. What is n_ctx-sized vs used-cell-sized

| thing | sized by | source |
|---|---|---|
| KV cache tensor allocation (full layers) | `kv_size` = n_ctx | `src/llama-kv-cache.cpp:233-234` |
| KV cache tensor allocation (SWA layers) | `kv_size` = n_swa = 1024 | same + `common/common.h:577` `swa_full=false` |
| attention K/V **view** at runtime | used cells: `get_n_kv = min(cells.size(), max(256, PAD(used_max_p1,256)))` | `src/llama-kv-cache.cpp:1280-1293` |
| KQ mask / FA staging in the **runtime** graph | used cells (`n_kv`) | `src/llama-graph.cpp:35,42` |
| KQ mask / FA staging in the **reserve** graph | **full `kv_size` = n_ctx** | `src/llama-kv-cache.cpp:2811-2813` (`init_full` ctor sets `n_kv = kv->get_size()`), `src/llama-context.cpp:746,994` (`n_tokens = min(n_ctx, n_ubatch)=1024`) |
| SYCL FA F16 staging reserve | `need_K/need_V = ggml_nelements(K/V)`, `need_Q/out = H·q·d` | `ggml/src/ggml-sycl/fattn.cpp:430-454` |

So the *runtime* attention work is used-cell-sized (same kernels at 65K and 131K), but the
**reserved** compute buffer grows with n_ctx because `sched_reserve` builds its worst-case graph
with `n_kv = full kv_size`. That is the n_ctx-linear term on top of the KV itself.

## C. Exact numbers (GGUF: 48 blocks, 8 full layers 1 KV head dim 512, 40 SWA layers 8 KV heads dim 256, window 1024)

q8_0 = 34 B/32 elem. Per global layer K @262144 = 512·262144/32·34 = **142,606,336 B = 136.0 MiB**.

| ctx | global K+V (8 layers) | SWA K+V (40 layers, fixed) | KV self | reserve: KQ mask (n_ctx·1024·2B) | reserve: SYCL FA staging (2·512·n_ctx·2B) | KV+reserve |
|---|---|---|---|---|---|---|
| 65536 | 544.0 MiB | 170.0 MiB | 714.0 MiB | 128.0 MiB | 128.0 MiB | 970 MiB |
| 131072 | 1088.0 MiB | 170.0 MiB | 1258.0 MiB | 256.0 MiB | 256.0 MiB | 1770 MiB |
| 262144 | 2176.0 MiB | 170.0 MiB | 2346.0 MiB | 512.0 MiB | 512.0 MiB | 3370 MiB |

**fit VRAM(ctx) = a + b·ctx**, b = 12.5 KiB/token (8.5 KV + 2.0 mask + 2.0 staging).
Measured b (jsonl lines 1-2) = 834 MiB / 65536 = **13.0 KiB/token** — model is within 4%.

## D. Limits crossed at 262144

- Single KV buffer (one allocation per device, all layers) = **2346 MiB = 2.29 GiB > 2^31 B**.
  Global K+V alone = 2176 MiB = 1.06 GiB… i.e. > 2 GiB. Buffer 2^31 crossover ≈ 226k tokens;
  global-only ≈ 247k tokens. q4_0 halves it: global K+V = 1152 MiB, total ≈ 1242 MiB (under 2 GiB).
- No int32 overflow found: `n_kv` is `int32_t` (`src/llama-kv-cache.h:472`), 262144 fits;
  FA `n_kv_max` asserted ≤ INT32_MAX (`src/llama-graph.cpp:2905`); `ggml_nelements` values
  (mask 268M, FA K 134M) are < 2^31. Buffer size is `size_t`.
- `max_mem_alloc_size`: B580 OpenCL reports 12,168,933,376 B (11.33 GiB, `clinfo`), so 2.29 GiB is
  well under. `GGML_SYCL_HOST_PINNED_MEM_2G` default 0 (`ggml-sycl.cpp:141,460`), so the 2 GiB cap
  is NOT active. **BMG-G31 60 % workaround does not apply**: B580 is BMG-G21 (`is_bmg_g31_arch`
  `ggml-sycl.cpp:1173-1174`; FA kernel picks TILE for g21 `fattn.cpp:271`; kernel log "battlemage
  (device ID e20b)").
- `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS` would only matter if a single alloc exceeded
  max_mem_alloc_size. Nothing here does at 131072; at 262144 the KV buffer is 2.29 GiB vs ~11 GiB.

## E. mmproj / MTP (question 4)

- `--no-mmproj-offload` sets `mmproj_use_gpu=false` (`common/arg.cpp:2603-2610`);
  `-mmdev/--mmproj-device DEVICE` picks the device, `none` = don't offload; **default follows
  `--device`** (`common/arg.cpp:2611-2630`, `:893-895`). So today's run puts the projector on SYCL0.
  mmproj file = 175,115,616 B = 167.0 MiB.
- MTP draft KV **is separately controllable**: `-ctkd/-ctvd` (`common/arg.cpp:4110-4132`),
  default `GGML_TYPE_F16` (`common/common.h:593-594`). The draft context is sized to the **target**
  n_ctx: `cparams.n_ctx = llama_n_ctx(ctx_tgt)` (`common/speculative.cpp:2618`).
- MTP draft GGUF (`unsloth/.../mtp-gemma-4-12B-it.gguf`, arch `gemma4-assistant`): 4 blocks,
  `head_count_kv=[8,8,8,1]`, pattern `[T,T,T,F]` → 1 full layer (1 head ×512) + 3 SWA (8×256, win1024).
  Draft KV @262144: **f16 = 536.0 MiB**, q8_0 = 284.8 MiB, q4_0 = 150.8 MiB. (Not used in the sweep —
  the launch script has no `-md`.)

## F. Crash timeline (journal)

- **-b -2 (boot 09:45-10:55):** 10:43:04 `page allocation failure` (ThreadPoolForeground, order 0,
  zram active, anon 13.3 GB, gpu_active 3.76 GB). 10:43:08 `GT0: Engine reset ccs`, `Timedout job
  seqno=4294967173 … in llama-server [346681]` (the **262144** run), coredump created; 10:43:13-14
  repeated `Faulted Address … FaultLevel 2 ccs` / `Fault response: Unsuccessful -ENOENT/-EINVAL`.
  10:48:11 second reset, `Timedout job seqno=4294967206 … in llama-server [375493]` (the **131072**
  run); 10:48:16 `guc_exec_queue_timedout_job`, `reset queued`, `Kernel-submitted job timed out`,
  `device wedged, needs recovery`.
- **-b -1 (boot 10:56-11:48):** 11:37:52 `llama-server[241088]: segfault at 1ca66 … CPU 11`;
  11:38:55 `llama-server[249658]: segfault … in libsycl.so.9.0.0`. Zero GT0 reset/wedge lines.
- devcoredump dir `/sys/class/drm/card0/device/devcoredump/` **does not exist** now. Cores exist under
  `/var/lib/systemd/coredump/` (llama-server @10:48 pid 375493 = 130 MB; Hyprland; QSGRenderThread)
  but are `-rw-r----- root`, not readable without sudo.

## G. What to measure on the GPU next (ranked)

1. Re-run the sweep at `-lv 4` (load only, ctx 65536 then 131072) and read the real
   `llama_kv_cache: SYCL0 KV buffer size` + `sched_reserve: SYCL0 compute buffer size` lines. This
   closes the 4 % gap between the model (12.5 KiB/token) and the measured slope (13.0).
2. One 131072 load-only run at `-ctk q4_0 -ctv q4_0` to confirm the KV term halves.
3. drm scheduler tracepoints (`gpu_scheduler:drm_run_job` / `drm_sched_process_job`) during a 32K
   prefill at 65536 vs 131072 → max GPU job duration vs the 5 s `job_timeout_ms`.
4. Per-second VRAM + `/proc/pressure/memory` during the same prefill (H1/H4).
5. If a load error names an allocation size, try `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1`
   (only relevant if a single alloc exceeds ~11 GiB; not expected here).
