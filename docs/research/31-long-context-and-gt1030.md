# 31 — Long context (128K–256K) on the B580, KV-in-RAM, GT 1030 jobs, Chief compaction

Status: RESEARCH ONLY. No GPU job, no model run, no config or Hyprland file changed. Only this file was written.
Written 2026-10-13 by research subagent. Constraint from Marcel: main monitor stays on the B580 (DP-1).
Secondary monitors DP-2 and HDMI-A-3 move to the GT 1030 (DP-7, HDMI-A-6). AMD iGPU (DP-4/5/6, HDMI-A-5) is the XREAL glasses.

Legend: [SRC] = read from a file or source line this session. [WEB] = verified via web search this session.
[EST] = my arithmetic or estimate, not measured. [UNVERIFIED] = not checked.

---

## 0. Facts used (all cited)

| # | Fact | Source |
|---|---|---|
| F1 | Gemma 4 12B QAT Q4_0 GGUF, 48 blocks, 16 attention heads, `key_length` 512 / `value_length` 512 on global layers, 256 on SWA layers | [SRC] GGUF header parsed read-only: `models/llm/google/gemma-4-12B-it-qat-q4_0-gguf/gemma-4-12b-it-qat-q4_0.gguf` |
| F2 | 8 global layers with 1 KV head; 40 SWA layers with 8 KV heads; `sliding_window` 1024; `shared_kv_layers` 0 | [SRC] same GGUF header |
| F3 | Global-layer KV per token at q8_0 = 8 × 512 × 2 × 34/32 B = **8.7 KB/token** | [EST] from F1/F2 and q8_0 block size |
| F4 | SWA KV is window-sized, not n_ctx-sized, unless `--swa-full`; the default is `swa_full = false` | [SRC] `engines/llama.cpp-sycl-tip/common/common.h:577` |
| F5 | Measured VRAM at ctx 65536: model_vram 8446 MiB, free 2437 MiB. At ctx 131072: 9280 MiB, free 1620 MiB. Device total = 12288 MiB | [SRC] `~/.hermes/cache/scratch/ctx-sweep.jsonl`, lines 1–2 |
| F6 | Slope between those two points = 834 MiB / 65536 tokens ≈ **13.3 KB per context token** | [EST] from F5 |
| F7 | 13.3 KB/token decomposes as: KV 8.7 KB + global KQ mask 2 KB (n_kv × n_ubatch 1024 × F16) + F16 staging reserve 2 KB (`need_K`/`need_V` = nelements of the K/V cache view, `fattn.cpp` `ggml_sycl_fattn_get_extra`). Sum 12.8 KB, within 4% of the measured slope | [SRC] `ggml/src/ggml-sycl/fattn.cpp:~420–450`; [EST] the decomposition |
| F8 | Runtime attention view size is **used-cell based**, not n_ctx: `get_n_kv` = pad(cells.used_max_p1()) capped by cells.size | [SRC] `src/llama-kv-cache.cpp:1280–1290` |
| F9 | So at runtime a 32K prefill builds the same FA/mask graph at ctx 65536 and ctx 131072. The only ctx-dependent differences are the reserved allocations (F7) and VRAM headroom | [SRC] F8 + [EST] |
| F10 | `-nkvo` (`--no-kv-offload`) sets `offload_kqv=false`. Then "all nodes between the KV store and the attention output are run on the CPU" | [SRC] `common/arg.cpp:2418–2421`, `src/llama-graph.cpp:2986–2988` |
| F11 | MKL FA path (taken for `Q ne[1] ≥ 32`, `K ne[1] ≥ 1024`, D=512 `standard_shape`): KV is processed in chunks of 8192 with online softmax; Q-tile 8192 rows | [SRC] `fattn.cpp:~158–175`, `fattn-mkl.cpp:18,26,398–404` |
| F12 | Crash error at 131072 is `UR_RESULT_ERROR_DEVICE_LOST` (error 20), surfaced at a stream wait. Not `OUT_OF_RESOURCES`, which is what a plain VRAM OOM would report | [SRC] `ctxsweep-131072.log` |
| F13 | Kernel log, previous boot: 10:43:04 `page allocation failure … ThreadPoolForeground`, Node 0 Normal free below min watermark, zram swap active. 10:43:08 `GT0: Engine reset: engine_class=ccs … Timedout job … in llama-server`, then `Fault response: Unsuccessful -ENOENT` | [SRC] `journalctl -b -1 -k` |
| F14 | 10:48:17 `GT0: Kernel-submitted job timed out` in `guc_exec_queue_timedout_job`, then `device wedged, needs recovery` | [SRC] `journalctl -b -1 -k` |
| F15 | ccs `job_timeout_ms` = 5000 (min 1, max 10000); `preempt_timeout_us` = 640000 | [SRC] `/sys/class/drm/card0/device/tile0/gt0/engines/ccs/` |
| F16 | Measured throughput at ctx 65536: prefill 606–707 t/s, 3K–32K prompts, zero resets (builder's ramp, user report) | [SRC] user out-of-band message, `research/27` ramp section |
| F17 | Decode 32 t/s at ctx 65536, short prompt | [SRC] `RESUME-after-reboot-2.md`, `ctx-sweep.jsonl` |
| F18 | Only xe render/compute device for llama is card0 = B580 (`03:00.0`, device name Intel Arc B580). `sycl-ls`: `level_zero:0` Arc B580, driver 1.17.39395 | [SRC] `sycl-ls` |
| F19 | `ggml-sycl` max single alloc from `get_max_mem_alloc_size()`; the 60% workaround applies only to BMG-G31, not BMG-G21 (B580) | [SRC] `ggml-sycl.cpp:1172–1190` |
| F20 | Monitors: DP-1 Samsung LC27G7xT 2560x1440 (main), DP-2 HP E24i G4 1920x1200, HDMI-A-3 HP Z24n G3 1920x1200, all on card0. GT 1030 = card2 with DP-7 and HDMI-A-6, both disconnected. iGPU = card1 with DP-4/5/6 and HDMI-A-5, all disconnected now | [SRC] `hyprctl monitors`, `/sys/class/drm/card*-*/status` |
| F21 | GT 1030 max memory clock 3004 MHz (64-bit GDDR5 ≈ 48 GB/s), driver 580.178.04, CUDA 13.0 reported by driver | [SRC] `nvidia-smi -q` |
| F22 | CUDA 13.0 removes offline compilation for cc < 7.5 (Maxwell, Pascal, Volta). Driver branch 580 is the last that supports them, LTS to mid-2028. CUDA 12.9 is the last toolkit that still builds sm_61 | [WEB] NVIDIA developer blog "Navigating GPU Architecture Support" |
| F23 | PyTorch RFC for release 2.15 proposes dropping CUDA 12.6 builds, which drops sm_50/60/70 binaries. This is a proposal, not a shipped release | [WEB] pytorch/pytorch#190385 |
| F24 | Hyprland: `AQ_DRM_DEVICES` is a colon list in priority order. The first card is the primary renderer. Every card that drives a monitor must be in the list. Symlinks are required for paths with colons (`by-path`) | [WEB] wiki.hypr.land Multi-GPU |
| F25 | Hyprland FAQ (community dots, not official): `AQ_FORCE_LINEAR_BLIT=0` and `AQ_MGPU_NO_EXPLICIT=1` are the usual fixes for NVIDIA monitors in multi-GPU setups | [WEB] Hyprland-Dots FAQ_NVIDIA |
| F26 | Chief profile: `model.context_length: 65536`; `auxiliary.compression` pinned to `custom` / `gemma4-12b` on 127.0.0.1:18080; no top-level `compression:` block (defaults apply) | [SRC] `~/.hermes/profiles/chief/config.yaml` |
| F27 | Hermes minimum context = 64,000 | [SRC] `agent/model_metadata.py:272` |
| F28 | Compression keys and defaults: `threshold` 0.50, `target_ratio` 0.20, `protect_first_n` 3, `protect_last_n` 20, `threshold_tokens` (absolute cap, clamped to window), `tail_mode` lean, `min_tail_user_messages` 1, `max_attempts` 3, `idle_compact_after_seconds` 0, `proactive_prune_tokens` 0, `enabled` true | [SRC] `agent/agent_init.py:1459–1560`, `agent/context_compressor.py:2804–2844`, `hermes_cli/config.py:3075–3081` |
| F29 | Summary budget = threshold_tokens × target_ratio | [SRC] `agent/context_compressor.py:2237` |
| F30 | Hypr config is in `~/.config/hypr/hyprland.lua` (`hl.env(...)`); workspace rules use `desc:` (monitor description), so they survive a connector rename | [SRC] `hyprland.lua`, `hyprmoncfg-monitors.lua` |

Correction to the orchestrator premise: VRAM **is** a real constraint at 256K. Extrapolating F6 (13.3 KB/token) from 65K to 262144:
model_vram ≈ 8446 + 196608 × 13.3 KB ≈ **10,950 MiB**. Add the desktop baseline of about 1,400 MiB (F5 `vram_before`) and the total is about **12,350 MiB against 12,288**. So 256K at -ub 1024 with the current desktop does not fit, by roughly 60 MiB. [EST, two-point extrapolation]

---

## 1. Crash root cause — evidence-ranked hypotheses

The user's new data point changes the ranking. At 65536 the same prompt sizes (3K–32K prefill, -ub 1024) ran with zero resets, and the kernels are identical (F8, F9). So a pure "this prefill is too big" explanation is not enough. Something that depends on n_ctx must be involved. Only VRAM headroom and reservation sizes depend on n_ctx at runtime.

### H1 (rank 1). ctx-linear reservations shrink VRAM headroom; the resulting memory pressure or migration slows the one long GPU job until it trips the 5 s job timeout (or trips it directly). [Combined H1 + H2 mechanism]
- For: the only runtime difference between the 65K and 131K runs is placement and headroom (F8, F9). Free VRAM falls from 2437 to 1620 MiB at load (F5). The reserve grows at 13.3 KB/token (F6, F7). A plain OOM would give OUT_OF_RESOURCES; the error is DEVICE_LOST (F12). That fits a GPU job that stalls or faults, not an allocation that fails cleanly. The 1 GiB STOP rule in RESUME was written for exactly this.
- Against / open: nothing shows eviction has happened yet. Headroom at 131K is still 1.6 GB at load.
- Confirm: during a 32K prefill at ctx 131072 and at 65536 (same prompt), sample VRAM every 1 s from DRM fdinfo (`drm-resident-vram0`, `drm-total-vram0`) and record GPU job durations from the drm scheduler tracepoints (`gpu_scheduler:drm_run_job` / `drm_sched_process_job`; check with `ls /sys/kernel/tracing/events/gpu_scheduler`). If durations at 131K are larger than at 65K for identical work, H1 is confirmed. If not, H1 is out.
- Falsify: same prompt, same ctx, lower -ub. If 131K passes at -ub 256 but dies at -ub 1024, the cause is per-job time (H2 is live and H1 is the trigger).

### H2 (rank 2). One long submission exceeds the 5 s xe job timeout. [Conditional]
- Estimate [EST]: per 1024-token ubatch, the dense work is about 24 TFLOP (12B params × 2). The observed 606–707 t/s implies about 1.5–1.7 s per ubatch on average, so the dense part is well under 5 s. The attention work for the last ubatch at n_kv 32K is 8.8 TFLOP (16 heads × 8 global layers × 2048 FLOP per query–key pair × 1024 × 32768). It only reaches 5 s if SYCL FA runs at about 3 TFLOPS or less and the whole ubatch is one job. Both are unknown.
- Against: the same kernels survived at ctx 65536 (F16). A timeout would have to be right at the edge and tipped by noise. Trace data would decide this. Note F11: the MKL path chunks KV, so a single kernel is shorter than the whole ubatch.
- Confirm: the job durations from H1's trace. If the max job duration at 65K is ≥ 3.5 s, H2 is live.
- Stop-gap (reversible, not a fix): `sudo sh -c 'echo 10000 > /sys/class/drm/card0/device/tile0/gt0/engines/ccs/job_timeout_ms'` (F15 max is 10000). Restore 5000 after. It only changes when the reset fires. It does not fix a real slowdown.

### H3 (rank 3, 256K-specific). A single KV buffer crosses 2 GiB and an int32 byte offset or size overflows.
- Estimate [EST]: global K+V at 262144 = 8.7 KB × 262144 ≈ 2.28 GB. That is above 2^31 bytes (2.147 GB). The crossover is near 246K tokens. At 131072 the total is about 1.14 GB global plus 0.18 GB SWA, well below 2^31.
- Static check: the MKL path uses `int` for n_kv, n_queries and heads, all small at these sizes (F11). I did not find an int32 product that reaches 2^31 at ctx 131072. The earlier "n_kv × ub × H = 2^31" coincidence needs an n_kv of 131072 at runtime, which F8 rules out.
- Verdict: does not explain the 131K crash. Possible for 262K. Test: none needed before the 262K load gate. Read the buffer sizes in the load log at 262144 (needs a load, so gated).
- `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1` (research/18 §4) matters only if a single allocation is above the device max alloc. The largest single allocation at 131K is about 1.1 GB, and the device max alloc is [UNVERIFIED]. Cheap to try at 262K if a load error names an allocation size. No evidence for it at 131K.

### H4 (rank 4 for 131K; rank 2 for the 262K load crash). Host memory pressure stalls a host-side path, and the GPU then faults on memory it can no longer reach.
- For: F13. Page allocation failure, direct reclaim, zram in use, 4 s before the GPU engine reset. The `-ENOENT` faults that follow a reset suggest the GPU touched memory that was no longer mapped.
- Against: the psi/watchdog event happened during the 262K load. At 131K the 10:48 wedge was during prefill and no memory event is recorded for it.
- Confirm: at load, sample `/proc/pressure/memory` and `MemAvailable` once per second. Keep `bench/watchdog.sh` on.

### H5 (ruled out at runtime, kept for the record).
- KQ mask sized by n_ctx × ub: at runtime the mask is sized by used-cell n_kv (F8). It is n_ctx-sized only in the worst-case reservation (F7). Not a runtime overflow.
- SWA cache sized by n_ctx: no. It is window-sized, and `swa_full` defaults to false (F4).
- Single allocation over 4 GiB: no. The largest allocation is about 1.1 GB at 131K (H3).

### Ranking, one line each
1. H1 + H2 together: n_ctx-linear reservations eat VRAM headroom, and the kernel then slows or stalls past 5 s. It explains "same kernels, dies only at 128K".
2. H4: host pressure, for the 262K load.
3. H3: 2 GiB KV buffer, 262K only.
4. H5: excluded.

---

## 2. Safe test ladder for 128K / 256K (design only; not executed; GPU-gated)

Nothing in this section runs now. Each GPU step needs Marcel's approval, plus the normal gate (`bench/gate.sh`, `bench/watchdog.sh`, `jobcap`, `gpu_reset_unacked`).

### 2.0 Before any GPU step (no GPU)
- Confirm the drm scheduler tracepoints exist: `ls /sys/kernel/tracing/events/gpu_scheduler` [UNVERIFIED].
- Move the two secondary monitors (see 2.4). This is Marcel's hands-on step. It also changes the B580 VRAM baseline, so re-measure `vram_before` afterwards.

### 2.1 Ladder (one variable per step; ramp prompt sizes 4K → 8K → 16K → 32K)
| step | ctx | -ub | KV | purpose | pass / stop |
|---|---|---|---|---|---|
| S0 | 65536 | 1024 | GPU | baseline. Record max job duration and min VRAM free during the 32K prefill, using the tracepoints in H1 | pass = no reset, free ≥ 1.0 GiB |
| S1 | 131072 | 1024 | GPU | reproduce the crash with tracing on. Same prompt as the 131K crash | expected to die. Record the trace up to the failure. If it does not die, rerun S1 twice |
| S2 | 131072 | 256 | GPU | per-job work ÷4. If it passes, H2 is part of the story. If it dies, H1 dominates | pass = no reset, free ≥ 1.0 GiB, max job ≤ S0 max job |
| S3 | 131072 | 1024 | `-nkvo` | removes the ctx-linear VRAM term (F7). If it passes, H1 is confirmed | pass = no reset; expect a slower prefill (section 3) |
| S4 | 262144 | 256 | `-nkvo` | load only (no prompt) first. Watch psi and MemAvailable. Then the same ramp | stop on psi_mem_full avg10 > 1.0 or any reset |

Launch pattern (from `serve/gemma4-12b-launch.sh`, flags as used today):
`llama-server --host 127.0.0.1 --port <p> --device SYCL0 -ngl 99 -c <ctx> -np 1 -t 16 -fa on -ctk q8_0 -ctv q8_0 -b 1024 -ub <ub> -lm dio -fit off` [SRC]
- Add `-nkvo` for S3 and S4.
- Do not add `--swa-full`. It is off by default (F4).
- Check `llama-server --help` for `--mmproj-device` before using it [UNVERIFIED on this build].

### 2.2 Stop conditions (any one → kill the server, report, do not retry)
- Any of: `GT0: Engine reset`, `Timedout job`, `Kernel-submitted job timed out`, `device wedged`, `Fault response`, `DEVICE_LOST` (grep `journalctl -k --since <start>` and the server log).
- Free VRAM < 1.0 GiB (F5 STOP rule).
- `psi_mem_full avg10 > 1.0` (watchdog).
- Never create `bench/.gpu-reset-ack` yourself. Only a human does, after a reset.

### 2.3 Timeout setting (reversible, optional)
`sudo sh -c 'echo 10000 > /sys/class/drm/card0/device/tile0/gt0/engines/ccs/job_timeout_ms'` (max 10000, F15). Restore with `echo 5000 …`. Use only as a diagnostic after S0, not as the fix. A longer timeout also means a true hang takes 10 s to recover from.

### 2.4 Secondary monitors to the GT 1030 (Marcel's cables) and Hyprland multi-GPU
Constraint: the main monitor stays on the B580. The secondaries DP-2 and HDMI-A-3 move to the GT 1030 DP-7 and HDMI-A-6 (F20). The iGPU stays on the XREAL glasses.

Steps:
1. Physically: move the DP-2 cable (HP E24i) to GT 1030 DP-7, and the HDMI-A-3 cable (HP Z24n) to GT 1030 HDMI-A-6. Check: `cat /sys/class/drm/card2-DP-7/status` and `card2-HDMI-A-6/status` show `connected`.
2. Stable card paths (by-path names contain colons, which Aquamarine cannot parse, F24):
   ```
   ln -sf /dev/dri/by-path/pci-0000:03:00.0-card ~/.config/hypr/card-b580
   ln -sf /dev/dri/by-path/pci-0000:08:00.0-card ~/.config/hypr/card-gt1030
   ln -sf /dev/dri/by-path/pci-0000:14:00.0-card ~/.config/hypr/card-igpu
   ```
   (The by-path links exist and map to card0, card2, card1 this boot, F20.)
3. In `~/.config/hypr/hyprland.lua`, add (use the full path, not `~`, F24):
   ```lua
   local h = os.getenv("HOME") .. "/.config/hypr/"
   hl.env("AQ_DRM_DEVICES", h.."card-b580:"..h.."card-gt1030:"..h.."card-igpu")
   ```
   Test A (Marcel's order, B580 first). Test B, if the GT 1030 screens freeze during a B580 reset: `card-igpu:card-gt1030:card-b580`. The reason: with the B580 as primary renderer, the compositor may wait on the B580 and freeze every screen. That is unverified and is the thing to measure. If uwsm is used, put the export in `~/.config/uwsm/env-hyprland` instead (F24) [UNVERIFIED whether uwsm is used].
4. Only if the GT 1030 monitors flicker or do not update, try one at a time: `AQ_FORCE_LINEAR_BLIT=0`, then `AQ_MGPU_NO_EXPLICIT=1` (F25, community, not official).
5. Relog Hyprland. `hyprctl monitors` should show the two secondaries as DP-7 and HDMI-A-6. Workspaces 2, 3, 8, 9 should follow via `desc:` (F30).
6. Check that the B580 VRAM baseline dropped (`vram_before`) and that the GT 1030 shows about tens of MB in use (`nvidia-smi`).

Isolation test: it can only be observed at the next natural B580 reset, because a reset cannot be triggered safely. Until then, record the GT 1030 outputs for at least a day for flicker or driver errors.

Note: this is a Hyprland config change. It was not applied. Marcel or an approved step does it.

---

## 3. KV-in-RAM (`-nkvo`): what it does and what it costs

Code path [SRC]:
- `-nkvo` → `offload_kqv=false` (`common/arg.cpp:2418–2421`).
- `src/llama-graph.cpp:2986–2988`: every node from the KV store to the attention output is pinned to the CPU backend. The FA op runs on CPU. Weights and the dense matmuls stay on the B580.
- Result: no SYCL FA kernel and no device-side FA reserve. The H1 mechanism is gone, and so is the long GPU job (H2).

VRAM [EST]:
- Removes the 8.7 KB/token global KV (F3) and the device FA reserves (F7).
- Estimated VRAM at 262144 with `-nkvo`: weights ~6.5 GiB + compute ~0.3–0.6 GiB, so about 7–7.5 GiB used out of 12 GiB. About 4.5 GiB free. (The 6.5 GiB weight figure is from research/22 and F-table; it is not re-measured here.)

RAM [EST]:
- KV at 262144: 2.28 GB global + 0.18 GB SWA = about 2.5 GB, held as anonymous memory. With 61 GiB DDR5 that is affordable. But zram (61.8 GiB, research/14) also lives in RAM, and F13 shows what happens when reclaim starts. Keep KV RAM under about 4 GB.

Speed cost [EST, with assumed CPU throughput 0.3–1 TFLOPS effective for 16 Zen 4 threads and q8 dequant; neither measured]:
- Decode: attention work per token = 262144 × N FLOP (8 global layers × 16 heads × 2048 FLOP per pair). Extra per token ≈ 17–57 ms at 65K, 34–115 ms at 131K, 69–230 ms at 262K. Current decode is about 31 ms. Predicted decode: 65K ≈ 11–21 t/s, 131K ≈ 7–15 t/s, 262K ≈ 4–10 t/s. Bandwidth alone (0.57 GB/token at 65K over ~60 GB/s) is ~10 ms and is not the limit; compute is.
- Prefill is the real cost: CPU attention for a P-token prompt ≈ 131072 × P² FLOP. At P = 4K that is about 2–7 s extra. At P = 32K it is about 137–460 s extra, against about 55 s today. So `-nkvo` is a decode-heavy, short-prompt mode. Keeping prompts short (compaction, section 5) is what makes it tolerable.

SYCL-specific caveats:
- None of the FA path runs on SYCL under `-nkvo`, which is the safety gain.
- The SYCL op-offload threshold (`offload_op`, `ggml-sycl.cpp:7128`) is not the deciding factor, because `set_tensor_backend` pins the nodes explicitly.

Hybrid options (ranked):
1. Two llama-swap entries, one model file: `gemma4-12b` (GPU KV, ctx 65536, proven) and `gemma4-12b-long` (`-nkvo`, ctx up to 262144). Only one runs at a time. Switching costs a reload (the GGUF is 7 GB; page cache keeps it warm if `-lm mmap`, but `-lm dio` bypasses the cache, see section 6). [EST]
2. `--override-tensor` for KV only: not evaluated (no source read this session) [UNVERIFIED].
3. ik_llama.cpp (`engines/ik_llama.cpp` exists): not evaluated this session [UNVERIFIED]. Do not rely on it for this.
4. Partial: KV for only some layers on host. Not supported by the flag, as far as I read. [UNVERIFIED]

---

## 4. GT 1030 job ranking

Facts [SRC/WEB]:
- 2 GB GDDR5, 64-bit, about 48 GB/s (F21). cc 6.1 (sm_61), no tensor cores (research/17). FP16 runs at 1/64 of FP32 on GP108 [EST, architecture rate, unmeasured here].
- Toolchain: CUDA 12.9 is the last toolkit with sm_61 offline compile. Driver 580 is the last branch with pre-7.5 support, LTS to mid-2028 (F22). The PyTorch 2.15 RFC drops Pascal from CUDA 13 builds (F23). This is a proposal, so use the last CUDA 12.6 PyTorch build if PyTorch is needed.
- VRAM budget: 2048 MiB minus the display framebuffers (tens of MB) and the CUDA context (about 0.3 GB typical [UNVERIFIED]). That leaves about 1.5 GB for jobs.

| rank | job | why | size | verdict |
|---|---|---|---|---|
| 1 | Display for DP-2 and HDMI-A-3 | Keeps two screens alive if the B580 wedges. Tens of MB. Zero compute risk | — | **Do it** (section 2.4) |
| 2 | STT: whisper.cpp CUDA, `small` or `large-v3-turbo` q5_0 | Clearest AI job for this card. Takes STT off the CPU. Turbo q5_0 ≈ 0.6 GB | 0.5–0.6 GB | **Do it** once the CUDA build exists (research/17 §2 recipe: CUDA 12.9, `CMAKE_CUDA_ARCHITECTURES=61`) |
| 3 | Fallback brain: ≤1.5B instruct, Q4 | Keeps Chief answering while the B580 is wedged. Decode bounded by 48 GB/s, about 20–35 t/s [EST] | 0.4–1.0 GB | **Worth it as resilience**. Only one of (2) and (3) fits comfortably with display |
| 4 | mmproj (vision projector) on GT 1030: `--mmproj-device CUDA0` (research/17) | Frees 0.16 GiB on the B580 and moves vision encoding off the brain card | 0.16 GiB | **Good small win**, after the CUDA build. Check the flag exists first |
| 5 | Embeddings (MiniLM/bge-small class) | Tiny. CPU is fine | <0.2 GB | CPU first. GPU optional |
| 6 | Kokoro TTS (82M) | CPU is fine. Chief currently uses piper (`chief/config.yaml` `tts.provider: piper`). Little gain | ~0.3 GB | Later. Needs PyTorch on cu126 |
| 7 | Wake word (openWakeWord-class ONNX) | Under 5 MB, realtime on CPU | — | CPU. The GPU is overkill |

Not sensible:
- Gemma 12B on the GT 1030. 6.5 GB does not fit in 2 GB.
- MTP speculative draft across GPUs (`--spec-draft-device`, research/17). The 242 MB draft fits, but verify steps sync across devices every token. The benefit is unmeasured. The B580 is the bottleneck, so the GT 1030 gains little. It also puts more load on the display card. Revisit only after the long-context gate.
- Layer or row split between B580 and GT 1030. 456 GB/s against 48 GB/s is badly matched, and the split assumes one model per backend (research/17 §3).
- Parakeet 0.6B: fp16 is about 1.2 GB, and the NeMo/PyTorch sm_61 path is fragile. whisper.cpp covers STT better here.
- Whisper large-v3 full fp16 (about 3 GB). Does not fit.

---

## 5. Chief auto-compaction settings

Keys and defaults (F28): `threshold` 0.50 (fraction of context), `threshold_tokens` (absolute cap, clamped to the window), `target_ratio` 0.20, `protect_first_n` 3, `protect_last_n` 20, `tail_mode` lean, `min_tail_user_messages` 1, `max_attempts` 3, `idle_compact_after_seconds` 0, `proactive_prune_tokens` 0, `enabled` true.

Important: the compaction itself is a Gemma call on the same B580 (`auxiliary.compression` is pinned to `gemma4-12b`, F26). So the summary prefill is up to `threshold_tokens`. At 256K, `threshold` 0.50 alone would mean a 131K prefill for the summary. That is the case that crashed. So `threshold_tokens` must be set explicitly.

Proposal:

64K (now, F16 ceiling is 32K prefill):
- `compression.enabled: true`
- `compression.threshold: 0.50` (fires at 32768 of 65536)
- `compression.threshold_tokens: 32768` (explicit, so the summary prefill ≤ 32K)
- `compression.target_ratio: 0.20` (summary budget ≈ 6.5K tokens, F29)
- `compression.protect_first_n: 3`, `protect_last_n: 20`, `tail_mode: lean`, `min_tail_user_messages: 1`, `max_attempts: 3`
- `compression.idle_compact_after_seconds: 0` (opt-in only)

256K (only after the gate in section 2 passes at 262144):
- `model.context_length: 262144` and `providers.local-ai.context_length: 262144`
- Keep `threshold_tokens: 32768` until a 48K prefill passes at 262144 under the gate. Then raise it to 49152. Never raise it past the verified prefill ceiling.
- Use `gemma4-12b-long` (`-nkvo`, section 3) for this profile if the GPU-KV 256K path still fails.

Setting the keys: use `hermes config set …` with the chief profile active, not sed (config.yaml is guarded, per BRIEF-27) [SRC: brief]. Not applied in this session. Hermes docs (https://hermes-agent.nousresearch.com/docs) were not fetched; the keys above are from source.

---

## 6. Hardware allocation map (use all hardware, within safe limits)

| device | spec | role | failure domain | notes |
|---|---|---|---|---|
| Arc B580 (`card0`, `03:00.0`) | 12 GB VRAM, xe | Gemma 12B brain (chat, tools, grounding). DP-1 main monitor | A (llama + main screen) | Keep weights only if the 256K gate is not yet passed. `mmproj` moves to GT 1030 later |
| GT 1030 (`card2`, `08:00.0`) | 2 GB GDDR5, 48 GB/s, sm_61 | DP-2 and HDMI-A-3 screens. STT (whisper.cpp). Optional ≤1.5B fallback brain. Later: mmproj | B (secondary screens, aux jobs) | ~1.5 GB free for jobs after display |
| AMD Raphael iGPU (`card1`, `14:00.0`, RADV, shares system RAM) | small RDNA2 iGPU | XREAL glasses (DP-4/5/6, HDMI-A-5). Candidate Hyprland render device (test B, 2.4). Candidate mmproj host via Vulkan | C (glasses) | Compute size unverified here: public Ryzen 7000 spec suggests about 2 CUs [UNVERIFIED]. Check `vulkaninfo --summary` (read-only) before planning |
| CPU Ryzen 9 7900X (12C/24T, 2 CCDs) | | Piper TTS (current), wake word, embeddings, Kokoro later. CPU attention if `-nkvo`. Fallback if GPUs die | — | Pin voice to CCD1. research/14 pins Gemma jobcap to CPUs 6–11 and 18–23 |
| RAM 61 GiB DDR5-6000 | | KV overflow (~2.5 GB at 256K). Page-cache prewarm of model files | — | zram 61.8 GiB is also RAM (research/14). Keep anon memory low (F13) |

Notes on prewarm: `-lm dio` (current launch) uses direct IO and bypasses the page cache, so prewarming the GGUF helps only with `-lm mmap`. Pick one. Prewarm with `cat <file> > /dev/null` (or `vmtouch` if installed [UNVERIFIED]).

Allocation rule: the B580 is the only card with a verified-safe long-context path, and it is also the only card that can take down the brain. Put the things that must survive (screens, fallback, STT, glasses) on the other cards, and keep llama on the B580 alone.

---

## 7. Self-check

| section | status | reason |
|---|---|---|
| 0 Facts | PASS | each fact cites a file, command or web source. Estimates are marked [EST] |
| 1 Crash root cause | PASS (analysis) | ranked hypotheses with the test for each. Not confirmed: needs the S0/S1 trace on the GPU |
| 2 Test ladder + monitors | PASS as design, NOT executed | GPU steps not run (constraint). Hyprland and cables not changed. Isolation can only be observed at a natural reset |
| 3 KV-in-RAM | PASS with caveats | code path cited (F10). Speed numbers are estimates from an assumed CPU throughput. `ik_llama.cpp` and `--override-tensor` not evaluated |
| 4 GT 1030 ranking | PASS | sm_61 and CUDA 12.9 / driver 580 support verified [WEB]. Job sizes and FP16 rate are estimates |
| 5 Chief compaction | PASS (source) | keys verified in source. Not applied to the live profile |
| 6 Hardware map | PASS with one gap | iGPU compute size [UNVERIFIED] |
| Correction on VRAM at 256K | PASS | two-point extrapolation (F5/F6), stated as [EST] |

Nothing was applied: no config, no Hyprland file, no cables, no sysfs write, no GPU run. The only file written is this one.
