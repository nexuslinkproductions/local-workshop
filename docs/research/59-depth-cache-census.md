# 59. Depth curve, buffer census, prompt cache (Devin E01, E02, E08)

Date: 2026-10-13, Arc B580, Ornith-1.5-9B Q4_K_M, q4_0 KV, mmproj on CPU, binary `engines/llama.cpp-sycl-tip` (commit 358a420ec). BASE flags from `serve/config.yaml` "ornith-chief".

Source conventions. `logs:N` means `bench/bakeoff42/logs/<file>:N`. For E01 and E08 the numbers come from one JSON record per request in `devin-E01-raw.jsonl` or `devin-E08-raw.jsonl`, so `raw:N` is that file, line N. All numbers are also in `bench/bakeoff42/logs/devin-e01-e02-e08.tsv` with the same source column.

## Bottom line

- **E01 (depth curve):** decode falls from 54.9 t/s at depth 0 to 10.3 t/s at 200K. Both needles pass (128K and 200K). Free VRAM never went below 1127 MiB, so no stop rule fired.
- **E02 (buffers):** going from 131K to 262K context adds 576 MiB of target compute buffer, not the predicted 512 MiB. MTP at n=2 with 65K context costs about 637 MiB extra on the B580 (weights, recurrent state, draft KV, and draft compute). The draft compute buffer alone is 320 MiB at 65K, so MTP at 262K would not fit the E18 budget of 0.5 GiB. That last part is an extrapolation, not a measurement.
- **E08 (prompt cache):** a divergent turn after an edit reached first token in 2.47 s by restoring checkpoint 8308 (`logs:426`). A full re-prefill of the same size took 9.48 s. The 3 s target is met at 11.2K context. The 26K case was not tested.
- No kernel reset or timeout since 21:43:45, checked before and after every experiment and at the end. No breach flag was written.

## Method

- One load per point, each under `flock -x -w 1800 bench/.gpu.lock` (`bench/bakeoff42/devin_run.sh`). Order: E02, then E01, then E08. The lock was free by 21:47:44, after another lane's SYCL build released it.
- Server: `serve/bakeoff-launch.sh 18199 <ctx> ...` with `BAKEOFF_EXTRA` set per point. Stopped by port pattern after each experiment. `pgrep` for `sycl-tip/build/bin/llama-server --port 18199` is empty at the end.
- VRAM guard: `bench/bakeoff42/vram-sampler.py` with `VRAM_FLOOR_MIB=750`, one CSV per point. Lowest reading across all CSVs: 1125 MiB (E08).
- `local-ai.service` stopped before the first experiment and started again after the last one. It is active on :18080.
- GPU time under lock: E02 0.6 min (21:47:44 to 21:48:19), E01 10.6 min (21:48:19 to 21:58:57), E08 1.5 min (21:58:57 to 22:00:29). About 13 min total, under the 75 min cap.

## E01: depth curve and needle

Filler: `research/**/*.md` concatenated, 482,271 tokens. The needle "The vault code is 4-7-1-9-3" (20 tokens) sits at token 32. Each depth is a prefix of one growing token sequence sent to `/completion` with `cache_prompt`, `temperature 0`, `n_predict 256`, `ignore_eos`. Each depth runs 2 warm-up decodes and 3 measured decodes. Depth 0 is 64 tokens.

| Depth | New tokens prefilled (`raw`) | Reused from cache | Prefill t/s | Decode t/s, reps 1 / 2 / 3 | Mean decode | Lowest free VRAM during depth |
|---|---|---|---|---|---|---|
| 0 (64 tok) | 64 (`raw:1`) | 0 | 175.8 (`raw:1`) | 54.90 / 55.64 / 54.08 (`raw:3,4,5`) | 54.87 | 1177 MiB |
| 8K | 8132 (`raw:6`) | 60 (`raw:6`) | 1216.6 (`raw:6`) | 46.19 / 46.40 / 46.26 (`raw:8,9,10`) | 46.29 | 1186 MiB |
| 32K | 24580 (`raw:11`) | 8188 (`raw:11`) | 1124.4 (`raw:11`) | 32.09 / 32.09 / 32.17 (`raw:13,14,15`) | 32.12 | 1178 MiB |
| 64K | 32772 (`raw:16`) | 32764 (`raw:16`) | 973.3 (`raw:16`) | 23.52 / 23.77 / 23.58 (`raw:18,19,20`) | 23.62 | 1184 MiB |
| 128K | 65540 (`raw:21`) | 65532 (`raw:21`) | 824.8 (`raw:21`) | 14.41 / 14.41 / 14.38 (`raw:23,24,25`) | 14.40 | 1178 MiB |
| 200K | 73732 (`raw:27`) | 131068 (`raw:27`) | 630.0 (`raw:27`) | 10.30 / 10.24 / 10.27 (`raw:29,30,31`) | 10.27 | 1127 MiB |

Every decode returned exactly 256 tokens (`predicted_n`, `raw:3` to `raw:31`).

**Comparison with the linear model in EXPERIMENTS.tsv (17.5 ms + 0.375 ms per 1K tokens).** Measured mean decode time per token: 18.2 ms at depth 0 and 97.4 ms at 200K. That fits about 18.2 ms + 0.40 ms per 1K, close to the model. Predicted vs measured t/s: 8K 49 vs 46.3, 32K 34 vs 32.1, 64K 24 vs 23.6, 128K 15 vs 14.4, 200K 11 vs 10.3. The model is 2 to 6% optimistic.

**Needle.**
- 128K: pass. Completion begins ` 4-7-1-9-3.` (`raw:26`). Prompt 31 new tokens, 131,068 reused, 2.1 s wall.
- 200K: pass. Completion begins ` 4-7-1-9-3.` (`raw:32`). Prompt 31 new tokens, 204,796 reused, 2.8 s wall.

Caveats:
- The needle test uses raw text, not the chat template, and there is one needle per depth. It rules out the gross SYCL GDN long-prompt failure at these two depths but does not grade long-context quality.
- The 8K to 200K decode outputs are plausible continuations of research text (for example `raw:29`, `raw:8`), not checked for correctness.
- Cache reuse stops just short of each boundary (8188, 32764, 65532, 131068). The server did not print checkpoint lines at default verbosity, so the checkpoint spacing is inferred, not logged.

## E02: buffer census (load only, `-lv 4`)

Source for every value is the server log, `logs/devin-E02-<tag>.log`, at the line shown. The "idle free" row is the arc-vram reading after load, from the TSV row.

| Buffer (MiB) | c131072 (`E02a`) | c262144 (`E02b`) | c65536 + MTP n2 (`E02c`) |
|---|---|---|---|
| SYCL0 model weights | 4812.25 (:165) | 4812.25 (:165) | 4956.24 (`mtp`:150) |
| SYCL_Host model weights | 545.62 (:166) | 545.62 (:166) | 545.62 (`mtp`:151) |
| SYCL0 KV, target | 1152.00 (:188) | 2304.00 (:187) | 576.00 (`mtp`:173) |
| SYCL0 recurrent state (RS) | 50.25 (:192) | 50.25 (:191) | 150.75 (`mtp`:177) |
| SYCL0 compute, target | 612.28 (:199) | 1188.28 (:198) | 324.28 (`mtp`:184) |
| SYCL_Host compute | 80.28 (:200) | 144.28 (:199) | 48.28 (`mtp`:185) |
| SYCL0 KV, MTP draft | n/a | n/a | 72.00 (`mtp`:207) |
| SYCL0 compute, MTP draft | n/a | n/a | 320.27 (`mtp`:216) |
| SYCL_Host compute, MTP draft | n/a | n/a | 40.27 (`mtp`:217) |
| CPU compute | 248.10 (:240) | 248.10 (:239) | 248.10 (`mtp`:255) |
| Idle free VRAM after load | 2973 | 1330 | 3203 |

Line numbers are in `logs/devin-E02-c131072.log`, `logs/devin-E02-c262144.log`, and `logs/devin-E02-c65536-mtp-n2.log`. `mtp` means that file. The MTP draft compute is reserved twice (`mtp`:216 and `mtp`:265, both 320.27 MiB).

**Predictions in EXPERIMENTS.tsv.**
- **Target compute +512 MiB from 131K to 262K (F1).** Measured +576 MiB (612.28 to 1188.28). That is 4.5 KiB per token, not 4. The direction holds but the size is 12% higher. The 1.16 GiB compute buffer at 262K does not show how much is FA scratch. That needs the E17 comparison.
- **MTP cost (F2).** At 65K, MTP adds about 637 MiB on SYCL0 over the same-context target: 144 MiB extra weights (`mtp`:150 vs :165), 100.5 MiB extra recurrent state (`mtp`:177 vs :192), 72 MiB draft KV (`mtp`:207), and 320 MiB draft compute (`mtp`:216). The MTP draft compute is almost the same as the target compute at 65K (320 vs 324 MiB), so the draft context reserves its own full-size scratch. If it scales with context like the target (4.5 KiB per token), it would be about 1.2 GiB at 262K. That is far above the 0.5 GiB limit in E18. This was not measured at 262K.

Caveat: these are reserved buffer sizes from `sched_reserve`. Actual use during prefill can differ.

## E08: prompt cache, 3-turn Chief-like session with an edit

Flags: `-ub 256 -b 256 --checkpoint-min-step 2048 --cache-ram 16384 -lv 4`, `/v1/chat/completions`, streaming, `enable_thinking` off, `temperature 0`, `max_tokens 160`. Time to first token (TTFT) is the first streamed content chunk.

Session:
- T1: an 8,146-token user message (an 8K slice of the research corpus) plus a question.
- T2: a second user message, a simulated tool result plus a question.
- T3: a third user message, another simulated tool result plus a question.
- T4 (the edit): the T2 message is changed by prefixing `[edited] ` at its start, so the prefix diverges at about token 8,308.
- T5 (extra, not in the plan): the T1 message is edited the same way, as a full re-prefill reference.

Simplification: tool results are plain user text, not the `tool` role, and the context is about 11K tokens, not 26K.

| Turn | TTFT (s) | New tokens prefilled | Reused from cache | Prefill (ms) | Source |
|---|---|---|---|---|---|
| T1, cold 8K | 6.46 | 8146 | 0 | 6446.46 | `raw:1` |
| T2, tool result | 1.31 | 1515 | 8305 | 1296.66 | `raw:2` |
| T3, follow-up | 1.07 | 1059 | 9979 | 1061.79 | `raw:3` |
| **T4, edit of earlier message** | **2.47** | 2797 | 8308 | 2462.32 | `raw:4` |
| T5, edit of first message (extra) | 9.48 | 11186 | 0 | 9417.36 | `raw:5` |

Log evidence:
- Checkpoints created during T1 to T3: positions 7889 to 11033 (`logs:336, 340, 362, 368, 371, 393, 398, 401`).
- T4 restored checkpoint 8307 (n_tokens 8308), which is exactly the divergence point (`logs:426`). It then erased five later checkpoints, at 9563 to 11033 (`logs:427` to `logs:431`).
- T5 found no usable checkpoint. All checkpoints were erased (`logs:481` to `logs:486`, `pos_next = 0`), and the full 11,186 tokens were re-prefilled.
- Host memory: MemAvailable 33,849 MiB before and 32,984 MiB after (TSV, `/proc/meminfo`). Prompt cache held 450 MiB (`logs:464`).

Against the E08 success criterion:
- Divergent turn TTFT under 3 s: met at 11.2K context (2.47 s). The 26K case was not tested.
- The restored checkpoint was at the divergence point, not 2K before it, so the restore was exact. The 2.47 s is still almost all prefill (2797 new tokens).
- Full re-prefill control: 9.48 s at 11.2K. The cache saves about 7 s at this size.

## Issues and notes

- Three TSV rows are false positives: `LEFTOVER_PROCESS` in E02b, E02c and the E01 cleanup. The check matched another lane's `speed-push` wrapper (pid 3806331), whose command line contains `build/bin/llama-server` text. I confirmed no sycl-tip server was running at the end and port 18199 was closed. The check was narrowed for E08, which has no such row.
- E02 `ready_s` is 2 to 4 s, likely because the model was already in page cache.
- E01 ran at default log verbosity, so checkpoint lines are missing. Its cache numbers are the only evidence of checkpoints there.
- Another lane's speed-push job (flock wait 7200 s) was queued on `bench/.gpu.lock` during this run. Its activity was not checked.
- No breach flag was written in any run, so the 750 MiB guard never fired.

## Files

- Harness: `bench/bakeoff42/devin_harness.py`, wrapper `bench/bakeoff42/devin_run.sh`.
- Raw: `bench/bakeoff42/logs/devin-E01-raw.jsonl`, `devin-E08-raw.jsonl`.
- Server logs: `devin-E02-c131072.log`, `devin-E02-c262144.log`, `devin-E02-c65536-mtp-n2.log`, `devin-E01-curve.log`, `devin-E08-chief.log`.
- VRAM CSVs: `devin-*-vram.csv`.
- TSV: `bench/bakeoff42/logs/devin-e01-e02-e08.tsv`.
- Chain log: `bench/bakeoff42/logs/devin-chain.out`.
