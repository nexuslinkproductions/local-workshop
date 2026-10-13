# 34 — Chief at 256K context (program lead log)

Status: IN PROGRESS, started 2026-10-13 12:00 CEST. Written incrementally. Harness: `bench/lc.py` (one locked
server session), `bench/chief256k-chain.sh` (session chain), `bench/needle.py` (needle test, leaf-written, selftest
passes). Per-session logs: `bench/logs/chief256k/<label>.{json,server.log,stepN.json}`.

Constraints found at start: `job_timeout_ms` (root-owned 0644) cannot be written without sudo, and `sudo -n` asks for a
password in this session, so the 10000 ms retry is only possible if Marcel runs it. drm_sched tracepoints
(`/sys/kernel/tracing`) are root-only: job duration is bounded by the gap between server `prompt processing progress`
lines (one per ubatch) instead. Source/log reading by leaf: `research/34-notes-source-reading.md`.

## WS1 — VRAM budget (load + one 8-token request, no big prompt)

`free` = MiB free of 11605 total as seen by DRM fdinfo (`bench/arc-vram.py`); it includes the desktop (~1.5 GiB) and moves ±100–150 MiB between runs because other agents/the desktop share the card (see `before` column). Buffer sizes are from the server `-lv 4` log (`SYCL0 KV buffer`, `SYCL0 compute buffer`). Logs: `bench/logs/chief256k/<label>.{json,server.log}`. Target: >= 1024 MiB free (min column).

| ctx | KV K:V | -ub | mmproj | MTP | KV bufs MiB (global+SWA) | compute MiB | free before | free after load | min free | label |
|---|---|---|---|---|---|---|---|---|---|---|
| 65536 | q8_0 | 512 | gpu | n | 544.00+255.00 | 272.80 | None | 1826 | **1713** | g1-65k-q8-ub512 |
| 65536 | q8_0 | 1024 | gpu | n | 544.00+340.00 | 417.33 | None | 1619 | **1507** | g1-65k-q8-ub1024 |
| 131072 | q4_0 | 512 | gpu | n | 576.00+135.00 | 464.80 | None | 1732 | **1620** | g1-131k-q4-ub512 |
| 131072 | q5_1 | 512 | cpu | n | 768.00+180.00 | 464.80 | None | 1776 | **1664** | g1b-131k-q51-ub512-mmcpu |
| 131072 | q8_0 | 256 | cpu | n | 1088.00+212.50 | 360.92 | None | 1564 | **1451** | g1b-131k-q8-ub256-mmcpu |
| 131072 | q8_0 | 512 | gpu | n | 1088.00+255.00 | 464.80 | None | 1084 | 972 | g1-131k-q8-ub512 |
| 262144 | q4_0 | 128 | cpu | y | 1152.00+112.50 | 597.10 | None | 543 | 431 | g1b-262k-q4-ub128-mmcpu-mtpq4 |
| 262144 | q4_0 | 256 | cpu | n | 1152.00+112.50 | 680.92 | None | 1333 | **1221** | g1b-262k-q4-ub256-mmcpu |
| 262144 | q4_0 | 256 | cpu | y | 1152.00+112.50 | 680.92 | None | 372 | 260 | g1b-262k-q4-ub256-mmcpu-mtpq4 |
| 262144 | q4_0 | 512 | cpu | n | 1152.00+135.00 | 848.80 | None | 1139 | **1027** | g1-262k-q4-ub512-mmcpu |
| 262144 | q4_0 | 512 | cpu | y | 1152.00+135.00 | 848.80 | None | 81 | 81 | g1-262k-q4-ub512-mmcpu-mtpq4 |
| 262144 | q4_0 | 512 | cpu | y | 1152.00+135.00 | 848.80 | None | 86 | 86 | g1-262k-q4-ub512-mmcpu-mtpq8 |
| 262144 | q4_0 | 512 | gpu | n | 1152.00+135.00 | 848.80 | None | 779 | 667 | g1-262k-q4-ub512-mmgpu |
| 262144 | q4_0 | 512 | none | n | 1152.00+135.00 | 848.80 | None | 1149 | **1033** | g1-262k-q4-ub512-mmnone |
| 262144 | q4_0 | 1024 | cpu | n | 1152.00+180.00 | 1185.33 | None | 784 | 672 | g1-262k-q4-ub1024-mmcpu |
| 262144 | q5_1 | 256 | cpu | n | 1536.00+150.00 | 680.92 | None | 906 | 794 | g1b-262k-q51-ub256-mmcpu |
| 262144 | q5_1 | 512 | cpu | n | 1536.00+180.00 | 848.80 | None | 718 | 606 | g1-262k-q51-ub512-mmcpu |
| 262144 | q5_1:q4_0 | 256 | cpu | n | 1344.00+131.25 | 680.92 | 10102 | 1148 | **1035** | g1c-262k-q51:q4-ub256 |
| 262144 | q8_0 | 256 | cpu | n | 2176.00+212.50 | 680.92 | None | 202 | 89 | g1b-262k-q8-ub256-mmcpu |
| 262144 | q8_0 | 512 | cpu | n | 2176.00+255.00 | 848.80 | None | 3 | 3 | g1-262k-q8-ub512-mmcpu |
| 262144 | q8_0:q4_0 | 256 | cpu | n | 1664.00+162.50 | 680.92 | 10100 | 780 | 668 | g1c-262k-q8:q4-ub256 |

Findings:
- Model weights 6637.7 MiB (SYCL0) + 787.5 MiB host. mmproj on GPU costs ~350 MiB (262K q4 ub512: 779 vs 1139 free with `--no-mmproj-offload`); `--no-mmproj-offload` (projector on CPU) is the cheap win. `--no-mmproj` saves only 10 MiB more.
- KV (global layers) at 262144: q4_0 1152 MiB, q5_1 1536, q8_0 2176 (+ SWA 135–255, depends on -ub). Matches the leaf's source-reading arithmetic (`research/34-notes-source-reading.md`).
- The reserved compute buffer is n_ctx-linear and -ub-dependent: 262144 ub1024 1185, ub512 849, ub256 681, ub128 597 MiB; 131072 ub512 465 / ub256 361; 65536 ub1024 417 / ub512 273. So the extra reserve is ~0.5 GiB at 262K whatever -ub is.
- **256K with >= 1.0 GiB free: only q4_0 KV with -ub 256 (min 1221 free, or ub512 at 1027–1139 which is on the edge) or q5_1:q4_0 at ub256 (1035). q5_1 (794–906) and q8_0 (89–202, ub512 3 MiB) do not fit. MTP does not fit at 262K at all**: the draft context is sized to n_ctx and adds two more compute buffers (ub512: 1058 MiB extra, free 81; even ub128+q4_0 draft KV leaves 431).
- 131072: q8_0 fits at ub256 (1451) but not ub512 (972); q4_0/q5_1 fit at ub512 (1620+).
- Not measured: MTP at 131072/65536 budget (S-chain below).

## WS2/WS4/WS5 partial — ladder + needle (5 needles, thinking off, prompt cache bypassed). Runs under the default 5000 ms job timeout; no GPU fault in any run

| session | prompt tokens | prefill s | prefill t/s | decode t/s (after that prompt) | needle 5 | log |
|---|---|---|---|---|---|---|
| g2-131k-q4-ub512 | 2650 | 9.685 | 395 | 30.9 | 5/5 | `bench/logs/chief256k/g2-131k-q4-ub512.step4096.json` |
| g2-131k-q4-ub512 | 6788 | 17.14 | 486 | 30.0 | 5/5 | `bench/logs/chief256k/g2-131k-q4-ub512.step8192.json` |
| g2-131k-q4-ub512 | 14713 | 31.412 | 522 | 28.3 | 5/5 | `bench/logs/chief256k/g2-131k-q4-ub512.step16384.json` |
| g2-131k-q4-ub512 | 31692 | 65.146 | 517 | 25.0 | 5/5 | `bench/logs/chief256k/g2-131k-q4-ub512.step32768.json` |
| g2-131k-q4-ub512 | 64568 | 139.157 | 481 | 19.6 | 5/5 | `bench/logs/chief256k/g2-131k-q4-ub512.step65536.json` |
| g2-262k-q4-ub256 | 2650 | 13.347 | 261 | 28.9 | 5/5 | `bench/logs/chief256k/g2-262k-q4-ub256.step4096.json` |
| g2-262k-q4-ub256 | 6788 | 27.27 | 283 | 29.4 | 5/5 | `bench/logs/chief256k/g2-262k-q4-ub256.step8192.json` |
| g2-262k-q4-ub256 | 14713 | 54.775 | 286 | 26.8 | 5/5 | `bench/logs/chief256k/g2-262k-q4-ub256.step16384.json` |
| g2-262k-q4-ub256 | 31692 | 113.664 | 289 | 24.3 | 5/5 | `bench/logs/chief256k/g2-262k-q4-ub256.step32768.json` |
| p-262k-q4-ub256-rerun | 2650 | 12.703 | 270 | 32.1 | 5/5 | `bench/logs/chief256k/p-262k-q4-ub256-rerun.step4096.json` |
| p-262k-q4-ub256-rerun | 6788 | 26.002 | 296 | 31.1 | 5/5 | `bench/logs/chief256k/p-262k-q4-ub256-rerun.step8192.json` |
| p-262k-q4-ub256-rerun | 15015 | 52.631 | 303 | 29.0 | 5/5 | `bench/logs/chief256k/p-262k-q4-ub256-rerun.step16384.json` |
| p-262k-q4-ub256-rerun | 32042 | 113.291 | 293 | 24.3 | 5/5 | `bench/logs/chief256k/p-262k-q4-ub256-rerun.step32768.json` |
| p-65k-q8-ub1024 | 14714 | 22.622 | 768 | 25.8 | 5/5 | `bench/logs/chief256k/p-65k-q8-ub1024.step16384.json` |
| p-65k-q8-ub256 | 14587 | 53.972 | 287 | 27.8 | 5/5 | `bench/logs/chief256k/p-65k-q8-ub256.step16384.json` |
| p-65k-q8-ub512 | 14714 | 32.314 | 505 | 28.1 | 5/5 | `bench/logs/chief256k/p-65k-q8-ub512.step16384.json` |
| p-131k-q4-ub256 | 14908 | 53.37 | 297 | 27.8 | 5/5 | `bench/logs/chief256k/p-131k-q4-ub256.step16384.json` |

Notes:
- 131072 ctx, q4_0 KV, -ub 512, mmproj on CPU: ladder 4K→64K passed, 5/5 needles at every step, min VRAM free 1868 MiB, max 1024-token chunk 2.39 s at n_past 59K (one chunk = 2 ubatches; so a single job < 1.2 s ≪ 5 s). No fault.
- 262144 ctx, q4_0 KV, -ub 256, mmproj on CPU: 4K, 8K, 16K, 32K steps passed with 5/5 needles (32K: 113 s, 283 t/s), min free 1056–1162 MiB; 64K step was reached once and killed by the watchdog (global io PSI 1.01), so **64K at 262144 is untested**. No GPU fault, no journal line.
- **Prefill speed is set by -ub, not by ctx or KV size**: at a 16K prompt, ub256 = 287/297/287 t/s at ctx 65K/131K/262K; ub512 = 505 t/s and ub1024 = 768 t/s at ctx 65K. So 256K at ub256 costs ~2.5× the prefill time of ub1024; ub384/512 are the VRAM-vs-speed trade at 262144 (ub512 leaves 983–1139 MiB: borderline).
- Image token budget is capped to `-ub` by the server (`cap image_max_tokens (original=1120) to 512 (n_ubatch = 512)`), so the long id loses screenshot detail (ub256 → 256 tokens). Keep the 64K fast id at ub1024 for vision.
- Decode (no MTP, q4_0): 31 t/s at 3K, 28 at 15K, 25 at 32K, 19.6 at 64K prompt depth.

## Watchdog aborts (ABORT-LAG) — not the server, not the GPU
Rows: `bench/logs/chief256k/watchdog-rows.tsv` (psi_io_full 1.10/1.50/1.06/1.09/1.30/1.13/1.01; one psi_mem_full 6.20 at a 65K load, while another agent was loading). Attribution added to `lc.py` (`attrib` in every session json): the server's cgroup io.pressure full max 0.18, server disk reads 723 MiB (the model load), writes 0 MiB, cgroup RAM 0.8–2.0 GiB, while global io PSI reached 1.01–1.47. Disk culprits sampled from /proc/*/io: `cargo test -j 12 haze-desktop` (read 83 + write 113 MB/s), a `grep -rl` at 1.1 GB/s, GT 1030 whisper tests, and the Hermes backend python (pid 12447). The watchdog was **not loosened** (I briefly set 2.5 for ~2 runs at 12:38, reverted to 1.0 default at ~12:41; `LC_PSI_MAX` env can override, default 1.0). `lc.py` now waits for io full avg10 < 0.3 before each launch and the chain retries a session up to 5× on a watchdog abort.

## STOPPED 13:17 by the orchestrator
Kernel oops 13:17:46 in `xe_shrinker_scan` inside kswapd0 (kswapd0 dead, memory pressure high, reboot needed). Not caused by my sessions: none of mine was running (my last session ended ~13:09 and my queued chain, waiting for the lock behind other agents, was killed). Journal this boot has **no** `GT0: Engine reset / wedged / DEVICE_LOST / Timedout` line; the xe shrinker oops is a host-memory/xe-shrinker bug, relevant to the earlier hypothesis H4 (host memory pressure) and to anything that fills `buff/cache` (50 GiB cache now). A zombie `[llama-server] <defunct>` (pid 607922) is another agent's.

## NOT DONE (needs a reboot + the lock)
WS2 262144 64K step, WS3 `-nkvo` entry, WS4 quality by KV type at 32K..256K, WS5 MTP/prompt-cache timings, perplexity per KV type, and applying a config. Nothing was applied to `serve/config.yaml` or the Chief profile.

### Resume (after reboot, with the lock; each chain stops on a GPU fault with exit 4)
```
cd ~/NEXUS_AI_CENTER/LOCAL-AI-LAB
# 1) finish the 262144 ladder + ub trade (budget loads, then ladder)
flock -x -w 7200 bench/.gpu.lock env LC_LOCKED=1 bash bench/chief256k-chain.sh bench/logs/chief256k/g2d.chain
# 2) quality <=128K per KV type (q8_0, q5_1, q5_1:q4_0, q4_0), then 256K for q4_0 and q5_1:q4_0
flock -x -w 7200 bench/.gpu.lock env LC_LOCKED=1 bash bench/chief256k-chain.sh bench/logs/chief256k/q1.chain
flock -x -w 7200 bench/.gpu.lock env LC_LOCKED=1 bash bench/chief256k-chain.sh bench/logs/chief256k/q256.chain
# 3) -nkvo fallback (262144, q8_0 KV in RAM, -t 12), 4) speed + MTP + prompt-cache reuse at 65K/131K
flock -x -w 7200 bench/.gpu.lock env LC_LOCKED=1 bash bench/chief256k-chain.sh bench/logs/chief256k/n.chain
flock -x -w 7200 bench/.gpu.lock env LC_LOCKED=1 bash bench/chief256k-chain.sh bench/logs/chief256k/s.chain
```
Not yet run: `llama-perplexity -f bench/logs/chief256k/ppl.txt -c 2048 -fa on -ctk X -ctv X` for f16/q8_0/q5_1/q4_0 (under the lock, `-ngl 99 --device SYCL0`). `job_timeout_ms` retry needs Marcel: `sudo sh -c 'echo 10000 > /sys/class/drm/card0/device/tile0/gt0/engines/ccs/job_timeout_ms'` (this session has no sudo); it was never needed, since no step failed on the 5000 ms default.

## Proposed config (provisional: passed WS1 and the ladder to 32K at 262144 / 64K at 131072, not yet WS4/WS5)
- `gemma4-12b` (fast, unchanged): ctx 65536, q8_0 KV, -ub 1024, mmproj on GPU, thinking per id. MTP (2.25×) at 65536 not yet re-measured under the lc harness (`s.chain`).
- `gemma4-12b-long` (new, not applied): `-c 262144 -ctk q4_0 -ctv q4_0 -ub 256 (384/512 if the budget chain shows >=1.0 GiB) -b 1024 --no-mmproj-offload -fit off -lm dio`, no MTP, vision budget only 256 image tokens. Min VRAM free ~1.05–1.22 GiB. Chief compaction for that id: `threshold_tokens: 32768` stays (summary prefill ~2 min at 283 t/s); raise to 49152 only after the 64K step passes at 262144.
- Rollback: nothing applied; `serve/config.yaml` and `~/.hermes/profiles/chief/config.yaml` untouched.

## Self-check at stop
lock: my chain killed, no GPU job of mine running; no server of mine alive (only another agent's defunct zombie); `job_timeout_ms` = 5000 (never changed); `.gpu-reset-ack` not created; kernel lines this boot: no GT0 reset/wedge/DEVICE_LOST/Timedout, one unrelated xe_shrinker/kswapd oops at 13:17:46 (see above).
