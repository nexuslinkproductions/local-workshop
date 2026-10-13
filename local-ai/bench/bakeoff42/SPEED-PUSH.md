# SPEED-PUSH — decode speed sweep, both models at 256K / q4_0 KV

Built, not run. Start it only after the current measured run has released `bench/.gpu.lock`.

    bash bench/bakeoff42/speed-push.sh --dry-run          # every point's argv, no GPU, no lock
    bash bench/bakeoff42/speed-push.sh --selftest         # gate-rule asserts on a temp TSV
    bash bench/bakeoff42/speed-push.sh [--only RE] [--skip RE]   # real run, one point per flock

Each point: `flock -x bench/.gpu.lock` -> `gate_check` -> `io_quiet_wait` -> `mem_guard` -> `vram-sampler.py`
(free < 900 MiB writes BREACH and kills the server) -> server via watchdog/ionice/jobcap on CCD1 -> probe -> row.
Every point is pinned to CCD1 (6-11,18-23), like production serving, so the baseline already runs 16 threads on 12 CPUs.
Thread points pass `-t N -tb 16`: only decode threads change, prefill stays as in the baseline.

## Probe (same for all points)
Warm-up, 3 x 256-token greedy decode on a fixed essay prompt (median -> `decode_tps`), 128-token greedy answer to a
fixed prompt (sha256[:12] -> `greedy_output_sha`), then ONE ~30K-token request (size calibrated with `/tokenize`):
its `prompt_per_second` -> `prefill_tps`, its decode -> `decode_tps_after_30k`. `note` carries `pp=<tokens>` and,
for MTP, `accept=<accepted>/<drafted>`. Thinking is off (`enable_thinking:false`), `cache_prompt:false`.

## Points (in run order) — expected effect
| label | tests | expected (source) |
|---|---|---|
| or-base | Ornith baseline, ub 512 | 46.2 t/s, free 954-987 MiB (bakeoff) |
| or-mtp1/2/3 | `--spec-type draft-mtp --spec-draft-n-max N` | dense ~2x (Gemma MTP, research/51). **Predicted to SKIP**: the MTP ctx has n_ctx 256K (speculative.cpp) = 4 kv-heads x 256 x 2 x 262144 x 0.5625 B = 288 MiB at q4_0 (1 GiB at the f16 default, so the script forces `--spec-draft-type-k/v q4_0`). 954 - 288 < 900, so the gate (base free >= 1200) skips it. |
| or-t8, or-t12 | decode threads 8 / 12 vs 16 | 16 threads on 12 CPUs oversubscribes; fewer may win a few % (hypothesis, no source) |
| or-poll0 | `--poll 0` vs default 50 | 0xsero runs `--poll 50` (research/52); effect on SYCL decode unknown |
| mc-base28 | MiniCPM ncmoe 28 | 42.9 t/s, pp4k 780, free 2739 MiB (sweep) |
| mc-nc30 | ncmoe 30 | ~40 t/s (sweep: 32 -> 40.6); base for the cache points |
| mc-nc26 | ncmoe 26 | ~+3 t/s extrapolated; ncmoe 24 reset the GPU. Runs only if mc-base28 free >= 2500 |
| mc-cache512/1024/1536 | `--moe-cache-mib N` at ncmoe 30 | CUDA 1.6-2.2x (research/40, 51), Vulkan 59 -> 77 t/s with a sweet spot; SYCL unverified. Each runs only if predicted free (prev nc30 free - N) >= 1500 |
| mc-t6/t8/t12 | decode threads vs 16 | CPU experts are memory-bound (pinned 12T = 63 GB/s, research/40); fewer threads may match |
| mc-pinned | `GGML_SYCL_NO_PINNED` unset | decode ~equal; load stalls memory (peak PSI 10-17%) and may trip the watchdog (row = fail, fine). ONE point. Skip with `--skip pinned` if the desktop must stay calm |
| mc-mtp1 | draft-mtp n-max 1 | -19% on a B580 for MoE with CPU experts (davetha, research/51). **Auto-skips**: the gguf has no `nextn` head (checked in its header) |

Gate rule: `LBL:MIN` means the last row of LBL is `ok` with `min_free_mib >= MIN`; MIN = 1500 (ornith: 900) + the VRAM the
point adds. A gated point that cannot run gets a `skip` row with the reason. Nothing descends below 1500 MiB predicted free
on MiniCPM; Ornith's baseline is already under 1500, so its guard is the 900 MiB breach.

## Reading `logs/speed-push.tsv`
Columns: time, model, label, flags, load_s, decode_tps, decode_tps_after_30k, prefill_tps, min_free_mib,
greedy_output_sha, status (ok / fail / skip), note. Compare each row with its model's baseline row (`or-base`, `mc-base28`);
later reruns append, the last row per label wins. Per-point logs: `logs/speedpush-<label>.server.log`, `.probe.err`,
`vram-speedpush-<label>.csv`, `BREACH-speedpush-<label>`. `note` flags `free<1500`, `BREACH ...`, `KLOG-HITS=n`.
Exit 5 = kernel log showed ABORT / Engine reset / wedged / Timedout job: stop, report, ack with `touch bench/.gpu-reset-ack`.

## Activation rule (keep a change only if ALL hold)
1. `decode_tps` >= baseline x 1.05 (and `decode_tps_after_30k` not worse).
2. `greedy_output_sha` equals the baseline's, OR tool-call validity is unchanged on the Chief suite.
3. `min_free_mib` >= 900 (Marcel's floor), status `ok`.
4. No ABORT / engine reset in `journalctl -k` during the point (the script reports `KLOG-HITS`).
Then change the production launcher (serve/bakeoff-launch.sh, run-minicpm.sh serve mode), not this script.
