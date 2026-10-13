# Blind review: Chief on the Arc B580 (Ornith-1.5-9B, 256K, q4_0 KV)

Reviewer: Devin, read-only. No GPU use, no server, no edits outside `out/`. Evidence snapshot: 2026-10-13, 21:04 to 21:40 by the system clock. Some notebook entries carry later time labels, e.g. "21:45" at research/00-plan.md:182.
Paths are relative to `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB` unless absolute. Engine source paths are under `engines/llama.cpp-sycl-tip/` unless stated.
Tags: [M] measured on this box (file cited), [S] read in source or config, [I] my inference, [W] outside source (URL).

The lab kept working while I read, and four files changed during the review: `bench/bakeoff42/vram-sampler.py` (21:14, parse fix), `bench/bakeoff42/speed-push.sh` (21:18), `serve/config.yaml` (21:28, new `ornith-chief` entry) and `/home/nexuslink/.hermes/profiles/chief/config.yaml` (21:28, Chief now uses `ornith-chief`).
I found the VRAM-guard bug (F3) before I read the lab's 21:22 note on it (research/00-plan.md:179). I keep it below because some gaps are still open. Line numbers for `speed-push.sh` refer to the 21:05 version I read.

## 0. Summary

- The goal is "256K always", but every decode number used for decisions was taken about 300 tokens into the context. Ornith slows from 17.5 to 29.0 ms per token between 300 tokens and 30K tokens of context. The cause is a SYCL flash-attention design choice: the whole KV cache is converted to f16 on every token. The same choice also reserves about 1 GiB of VRAM at 256K. Fixing it is the largest lever for both speed and memory.
- VRAM limits everything else: MTP, `-ub 512`, and running the vision encoder on the GPU all need memory the card does not have. The desktop takes 1.75 GB on the same card. The two GPU resets today both happened at VRAM overcommit, while the safety guard was blind.
- Vision costs about 20 s per screenshot and is in no eval. Prompt state is thrown away by the 600 s idle unload and by watchdog kills that react to other processes.
- Most of tonight's speed "wins" are inside run-to-run noise. The only win that replicated is MiniCPM `-t 6`. The eval also cannot separate the models statistically.

## 1. Findings ranked by expected impact

### F1. Decode slows sharply with context depth because SYCL converts all of K and V to f16 on every token (impact: very high)
- [M] Ornith, production shape (256K, q4_0 KV, ub256):
  - At ~300 tokens: 256 tokens decoded at 17.55 ms each, 56.99 t/s (`bench/bakeoff42/logs/speedpush-or-ub256.server.log:42`).
  - After a 30,356-token prompt: 29.03 ms each, 34.44 t/s (same log:180).
  - So 30K tokens of context add 11.5 ms per token. MiniCPM shows the same shape: 40.29 -> 31.42 t/s (`bench/bakeoff42/logs/speed-push.tsv:49`).
- [S] The code path:
  - On BMG, decode with quantized KV is routed to the TILE kernel (`ggml/src/ggml-sycl/fattn.cpp:267-275`).
  - Every TILE launch passes need_f16_K=true and need_f16_V=true (`ggml/src/ggml-sycl/fattn-tile.hpp:1087-1145`, last three args `true, true, false`).
  - `launch_fattn` then runs `to_fp16` over `ggml_nelements(K)` and `ggml_nelements(V)`, i.e. the whole view, on every call and in every one of the 8 attention layers (`ggml/src/ggml-sycl/fattn-common.hpp:954-1016`).
  - `n_kv` is the number of used cells padded to 256 (`src/llama-kv-cache.cpp:1280-1294`), so this cost grows linearly with depth.
- [I] Traffic at 30K depth:
  - 8 layers x 30,720 x 4 heads x 256 x 2 (K and V) = 503M elements.
  - Read the q4_0 (0.28 GB), write f16 (1.0 GB), then TILE reads the f16 again (1.0 GB): about 2.3 GB per token, against 0.28 GB if q4_0 were read directly.
  - At 456 GB/s that is about 5 ms of pure traffic. Add launch and combine overhead and it is within 2x of the measured +11.5 ms.
- [S] The f16 scratch is part of the FA node's allocation size (`ggml/src/ggml-sycl/fattn.cpp:401-461`). The graph is reserved with n_kv equal to the full cache size (`src/llama-kv-cache.cpp:2813`).
  - For Ornith that is 262,144 x 4 x 256 x 2 x 2 B = 1.0 GiB of VRAM, held from load time even for a 2K-token chat.
  - This matches the lab's own measured slope for Gemma, "F16 staging 2 KB/token" (research/00-plan.md:105). A Gemma global layer is 1 head x 512 x 2 x 2 B = 2 KiB per token.
- [I] Linear extrapolation (not measured): ~15 t/s at 128K depth and ~11 t/s at 200K. Ornith decode beyond 30K depth has never been measured. Even for Gemma, 64K depth at ctx 262144 is recorded as untested (research/34-chief-256k.md:72).
- [S] PR #26689 (commit d077b4c), which moves quantized decode on BMG to TILE, is already an ancestor of 358a420ec (checked with `git merge-base --is-ancestor`). So this slow path is the post-fix state; that PR measured TILE 1.6x faster than VEC at 32K [W https://github.com/ggml-org/llama.cpp/pull/26689]. VEC does read q4_0 natively (`ggml/src/ggml-sycl/fattn-vec.hpp:588-589`) but is evidently slow on Xe2.
- [S] Vulkan reads q4_0 K/V inside its coopmat2 FA shader and splits long KV ranges across workgroups (`engines/llama.cpp-vulkan-tip/ggml/src/ggml-vulkan/ggml-vulkan.cpp:8094-8104, 8251-8264`). There, f16 dequant is used only for prefill. Ornith has never run on Vulkan.
- What to do, cheapest first:
  - (a) Run one Vulkan A/B of the production flags (E03).
  - (b) Use the existing dev build. It already has `GGML_SYCL_FA_FORCE_VEC` and `GGML_SYCL_FA_MIN_PB` (`engines/llama.cpp-sycl-dev/ggml/src/ggml-sycl/fattn.cpp:263-266`; strings present in `engines/llama.cpp-sycl-dev/build/bin/libggml-sycl.so`, built 17:05) (E04, E05).
  - (c) The real fix: dequantize q4_0 inside the TILE kernel's K/V tile loader instead of in a separate whole-view pass (E17). This removes ~2 GB per token of traffic at 30K and frees the 1.0 GiB reservation, plus the same again in the MTP draft context (F2). Expected decode right after a 30K prompt: ~45-50 t/s instead of ~34 [I], with bigger gains deeper.

### F2. VRAM is the binding limit: the desktop and the f16 scratch use what MTP, ub512 and GPU vision need (impact: high)
- [M] The desktop alone uses 1,749 MiB of B580 VRAM: `bench/arc-vram.py` at 21:12 with no llama-server running gave free=9857 of 11605. Free VRAM at idle swung between 9,446 and 10,092 MiB across runs (`bench/bakeoff42/logs/vram-speedpush-or-base.csv:2` vs `challengers.log:2,25,45,56`).
- [M] Ornith at 256K/ub256 leaves 945-1,124 MiB free (`speed-push.tsv:32,42,55,60`). ub512 breached the floor in all three attempts (`speed-push.tsv:2,22,38`).
- [M] MTP at 256K needs about 1.6-1.8 GB more. With the fixed guard, free VRAM was -542, -566 and -495 MiB (`speed-push.tsv:61-63`; research/00-plan.md:180,182).
- [I] My VRAM accounting for Ornith at 256K/ub256 comes to ~8.8 GiB. Against ~9.6-9.9 GiB of idle free that leaves ~1 GiB, which is what was measured.

  | item | size | how derived |
  |---|---|---|
  | weights | ~5.24 GiB | 5,780,090,816 B file minus the unused 144 MiB MTP block `blk.32` (`speedpush-or-ub256.server.log:5-19`) |
  | KV q4_0 | 2.25 GiB | 8 layers x 2,048 x 0.5625 B x 262,144 |
  | f16 scratch | 1.0 GiB | F1 |
  | GDN state | ~0.05 GiB | |
  | other compute | ~0.2-0.3 GiB | |
- [I] Why MTP costs so much:
  - The draft context gets n_ctx equal to the target's (`common/speculative.cpp:2617-2618`).
  - If its attention runs on the GPU it reserves its own f16 scratch: 1 layer x 262,144 x 4 x 256 x 2 x 2 B = 1.0 GiB. Add the draft KV (288 MiB), a vocab-sized logits buffer (248K vocab) and the 144 MiB head, and the total is ~1.6-1.7 GiB.
  - The lab currently suspects a duplicated output head instead (research/00-plan.md:182). My explanation does not cover the -nkvo case cleanly (MTP still cost 1.8 GB there), so it is a hypothesis.
  - A load with `-lv 4` that prints per-context buffer sizes settles it (E02).
- [S] Hyprland renders on the B580: `AQ_DRM_DEVICES` is not set (`~/.config/hypr/hyprland.lua:33` sets only `__GLX_VENDOR_LIBRARY_NAME`, per scout F) and the B580 is the boot VGA (`/sys/class/drm/card0/device/boot_vga` = 1).
  - The earlier display split failed because of the legacy NVIDIA driver (research/00-plan.md:106), not the AMD iGPU.
  - The Hyprland wiki documents using an iGPU as primary renderer on desktops [W https://wiki.hypr.land/Configuring/Advanced-and-Cool/Multi-GPU/].
- What to do:
  - E13: one evening with the Raphael iGPU as primary renderer (both cards listed, iGPU first, stable udev symlinks as the wiki advises).
    - Expected: +1.3-1.7 GiB free on the B580. The compositor stops sharing the B580 with compute, so both desktop lag and the blast radius of a reset drop.
    - Risks: the 2-CU iGPU may stutter at 144 Hz, and monitors wired to the B580 need a cross-GPU copy.
    - Rollback: remove one env line.
  - F1(c) frees 1.0 GiB in the target and ~1.0 GiB in the draft. Either change alone makes ub512 fit; both together make MTP n2 fit with margin.

### F3. The VRAM guard was blind exactly when VRAM ran out; the 21:10 reset happened under it (impact: high, partly fixed)
- [M] The bug:
  - `bench/arc-vram.py:53,61` prints a negative free value once summed client VRAM exceeds its 11,605 MiB constant.
  - The sampler regex `free=(\d+)` turned every negative reading into -1, and `0 <= fr` meant -1 never counted as a breach (`vram-sampler.py:13,21` before the 21:14 fix).
  - `speed-push.sh:218` also dropped negative samples when computing min_free.
- [M] What that hid:
  - mc-base28: 38 of 45 samples were -1, covering the whole probe window (`vram-speedpush-mc-base28.csv`).
  - mc-nc30 started with 836 MiB more headroom and still fell from 3,573 to 651 MiB at its first request (`vram-speedpush-mc-nc30.csv`). So mc-base28 almost certainly went negative at the same moment.
  - or-combo-mtp3 read -1, then 3,990, then 497 MiB (`vram-speedpush-or-combo-mtp3.csv`). Then the kernel logged "Engine reset: engine_class=ccs ... Timedout job ... in llama-server" at 21:10:02 (`journalctl -k`, this boot).
  - The 20:16 reset was also at overcommit (research/00-plan.md:169).
- [S] Still open:
  - The guard measures the whole card every 2 s, with gaps of up to 6 s under load (`vram-speedpush-mc-t8.csv:24,52`, per scout C).
  - A 2.9 GB allocation jump happens in under 2 s (mc-nc30), and each sample spawns a Python process that walks all of /proc.
  - Fix: use `arc-vram.py --json` per client, sample every 1 s, and kill on a sudden allocation jump as well as on the floor (E22).
- Consequence: every MiniCPM min_free value and every MTP speed number in the TSV was taken while VRAM was overcommitted into GTT. Do not run research/53's MiniCPM ncmoe 26 lever (`research/53-decode-speed-levers.md:115`).

### F4. Vision costs about 20 s per screenshot and is in no eval (impact: high for computer use)
- [M] Ornith timings:
  - In the suite run, a 2,061-token image prompt took 20.6 s, 99.9 t/s (`bench/bakeoff42/logs/llama-swap-ornith-9b.log:59`).
  - In the swap smoke test, one describe took 21.33 s (`bench/bakeoff42/logs/swap-ornith-9b.json`).
- [S] The vision encoder runs on the CPU in BF16 (`--mmproj-cpu`, `serve/config.yaml:159`) with the `-t` thread count (`tools/server/server-context.cpp:1160`). Those threads are pinned to 12 logical CPUs with CPUWeight 20 (`serve/bakeoff-launch.sh:10`).
- [M] For comparison, Gemma with its vision encoder on the GPU encoded a screenshot in ~2.1 s (`bench/results-matrix.tsv:141-149`, per scout I).
- [M] The server warns that Qwen-VL grounding needs at least 1,024 image tokens (`speedpush-or-ub256.server.log:21-22`). A 1920x1080 screenshot is ~2,040 tokens, so cutting the budget below 1,024 to save time hurts grounding.
- [S] The 42-task suite contains no image item (`evals/chief/suite.yaml`, per scout E).
- What to do:
  - Measure encode time against threads and pinning, and `--image-max-tokens 1024` for describe-only calls (E07).
  - Keep the 2-stage crop-zoom (`serve/screen_locate.py`) for grounding, because each crop costs far fewer tokens.
  - The vision encoder on the GPU only fits after F2 frees VRAM.
    - The BF16 file is 0.86 GiB.
    - An F16 version exists in bartowski/Ornith-1.5-9B-GGUF (per scout I) [W https://huggingface.co/bartowski/Ornith-1.5-9B-GGUF].

### F5. Lag from lost prompt state: idle unload, watchdog kills caused by other processes, checkpoint spacing (impact: high for "never lagging")
- [M] Appending to a conversation reuses the cached prefix well: 27-28 new tokens took 0.19-0.36 s (`llama-swap-ornith-9b.log:107,325`, per scout D).
- [M] A conversation that diverges from the cache is expensive:
  - 8,061 tokens re-processed in 4.3 s (log:93).
  - 26,655 tokens re-processed in 15.5 s (log:261, 831).
- [S] Idle unload:
  - `ttl` is 600 s for ornith-chief (`serve/config.yaml:162`; `globalTTL` at :23).
  - After 10 idle minutes llama-swap kills the server, and the KV cache, checkpoints and the 8 GiB RAM prompt cache all go with it.
  - [I] At ~1,200 t/s, rebuilding a 100K-token conversation takes ~80 s.
- [S] Watchdog:
  - It acts on global `/proc/pressure` (`bench/watchdog.sh:50-52`), so disk IO from any other process kills a healthy server.
  - The lab already measured the server's own cgroup IO pressure at 0.18 while global pressure was 1.01-1.47 (research/34-chief-256k.md:78).
  - Each kill means a cold reload plus a full re-prefill.
- [S] Checkpoint flags are at their defaults:
  - `--ctx-checkpoints` 32 (`common/arg.cpp:1701`).
  - `--checkpoint-min-step` 8192 (:1709).
  - `--cache-ram` 8192 MiB (:1719).
  - The RAM cache evicted entries of up to 1.3 GiB in the suite run (`llama-swap-ornith-9b.log:1571-1573`, per scout D).
- What to do:
  - Set ttl 0 (never unload) or several hours for ornith-chief. `serve/gate-run.sh` already protects gaming.
  - Have the watchdog read the server scope's own `memory.pressure` and `io.pressure` (E20). Keep MemAvailable as a global trip.
  - Add `--checkpoint-min-step 2048 --cache-ram 16384` (E08).
  - Do not use `--cache-reuse` on qwen35: recurrent state cannot be shifted (`src/llama-memory-recurrent.cpp:334-362`, per scout D).

### F6. Production config drifted from the measured config (impact: medium, mostly fixed during review)
- Before 21:28:
  - Chief used gemma4-12b.
  - The only Ornith entry ran q8_0 KV, the vision encoder on the GPU and -b/-ub 1024 at 262,144 (`serve/config.yaml:135-147`, `serve/bakeoff-launch.sh:17-18`). [I] That cannot fit: 5.24 + 4.25 (KV) + 1.0 (scratch) + 0.86 (vision encoder) GiB exceeds the ~9.9 GiB free.
  - The scored run used q4_0, `--mmproj-cpu` and ub512 (`bench/bakeoff42/config.suite-ornith-9b.yaml:14`; research/00-plan.md:166).
- Now `ornith-chief` (`serve/config.yaml:149-168`) uses the speed-push shape with ub256.
  - The old `ornith-9b` q8_0 entry can still be loaded, and its comment (:131-134) still describes a 32K setup. Remove or fix it so no eval run or alias can start it.
  - ub256 was never scored on the suite (the 30/42 run used ub512).
  - ub256 also costs prefill speed: 1,741 -> ~1,230 t/s at 30K (research/00-plan.md:165 vs `speed-push.tsv:55`).

### F7. Sampling contradicts the model card (impact: medium, cheap to test)
- [S] Every launch uses `--temp 0 --repeat-penalty 1.05` (`serve/bakeoff-launch.sh:19`). Hermes sends no sampling fields, so these settings apply (per scout E: Hermes `transports/chat_completions.py:367-372`).
- [W] The Ornith model card recommends temp 1.0, top_p 0.95, top_k 20 and presence penalty 1.5 for general use; temp 0.6 and presence 0 for precise or coding work; repetition penalty 1.0 (https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF).
- [W] A degeneration study found greedy decoding the worst sampler for this family at very low bit widths, but clean at IQ4_XS and above (https://huggingface.co/protoLabsAI/Ornith-1.5-9B-MTP-GGUF/discussions/4).
- [I] A repeat penalty over prompt plus output penalizes `{`, `"` and repeated JSON keys, which is what tool calls are made of. Drop it first (E11), then try the card's precise profile (E12). Each needs repeat runs.

### F8. Most speed-sweep "wins" are noise, and the baseline was never measured in the same harness (impact: medium, process)
- [M] Run-to-run noise:
  - Four identical or-ub256 runs gave 50.89, 60.29, 56.98 and 50.48 t/s (`speed-push.tsv:32,42,55,60`), a 19% range.
  - Within one run, the first 256-token request ran at 42.17 t/s and the next ones at ~56 (`speedpush-or-t12.server.log:43`). The single 8-token warm-up (`speed-push.sh:165`) is not enough.
- [M] or-t12 55.85, or-poll0 57.46/58.13 and or-combo 57.87 (`speed-push.tsv:36,37,45,46`) all fall inside the ub256 spread. The comment above the or-combo points (`speed-push.sh:42`) stacked them against the lowest ub256 run.
- [M] or-base (ub512) never produced a number (`speed-push.tsv:2,22,38`). "ub256 decodes 10% faster" (`research/53-decode-speed-levers.md:95`) therefore compares speed-push against `smoke.py`'s single 128-token log parse (research/00-plan.md:165; `smoke.py:38-49`, per scout C).
- [M] The only replicated win with non-overlapping results is MiniCPM `-t 6`: 45.78/45.36 vs 41.00/40.29 t/s (`speed-push.tsv:18,54` vs 12,49).
- [S] How decode is measured:
  - `decode_tps` is taken 40-550 tokens into the context.
  - `decode_tps_after_30k` is a single 128-token sample (`speed-push.sh` probe(), lines 150-179).
  - No GPU clock, CPU load or desktop state is recorded per point.

### F9. The eval cannot separate the candidates and misses the requirements (impact: medium)
- [M] Paired results (computed by scout E from `bench/bakeoff42/logs/suite-*.out`):
  - Ornith 30/42 vs Gemma 25/42: 6 items favour Ornith, 1 favours Gemma, exact McNemar p = 0.125.
  - Ornith vs MiniCPM 24/42: 7 vs 1, p ~ 0.07.
  - Two Gemma runs at temp 0 differed by 3 items.
- [S] Missing:
  - Image items.
  - Prompts above ~30K tokens.
  - Multi-turn and post-compaction items.
  - Tool-call parse rate (`evals/chief/run_suite.py:44-101,176-188`).
- Ornith is a sensible pick (it is also 2x faster than Gemma), but the scores should not be quoted as a ranking.

### F10. Driver and kernel exposure (impact: medium for reliability)
- [M] Both resets today were ccs "Timedout job" in llama-server during overcommit (`journalctl -k`: 20:16:23 and 21:10:02). `ccs job_timeout_ms` is 5000 (`/sys/class/drm/card0/device/tile0/gt0/engines/ccs/job_timeout_ms`, per scout F).
- [M] The 13:17 oops was kswapd0 crashing in `xe_pt_zap_ptes`, reached via `__xe_shrinker_walk` and `xe_shrinker_scan`, on 7.2.5-3-omarchy built 14 Sep 2026 (`journalctl -k -b -1`, around lines 1687-1721).
- [W] Upstream commit 3feeb66 fixes a NULL dereference in `xe_pt_zap_ptes_entry`, dated June 2026 (https://github.com/torvalds/linux/commit/3feeb667197bd58a17f4edfdbcad249ffcb3c864).
  - [I] That fix is probably already in 7.2.5, so this oops is likely a different or still-unfixed path.
  - Scout F also reported a shrinker-walk fix said to land in 7.2.7+. I could not verify it.
- [M] GuC firmware is 70.72.1 (`journalctl -k`).
- What to do:
  - The real guard against resets is not overcommitting (F2, F3).
  - Send the oops trace and devcoredump to drm/xe.
  - Check the omarchy kernel changelog for xe shrinker fixes.
  - Do not raise job_timeout_ms; that only hides the symptom longer.

### F11. CPU side of an all-GPU model (impact: low-medium, desktop smoothness)
- [S] Ornith runs `-t 16` (`serve/bakeoff-launch.sh:17`) on 12 pinned logical CPUs with default polling (`common/arg.cpp:1577`).
- [M] Decode does not depend on thread count: or-t8 gave 57.24/56.85/55.02 t/s in its first three requests before it breached (`speedpush-or-t8.server.log`), and poll 0 lost nothing (`speed-push.tsv:37,45`).
- [S] Vision encoding on the CPU does use `-t` (`tools/server/server-context.cpp:1160`), so do not simply lower it.
- Recommendation: `-t 12 --poll 0`. That stops oversubscribing the 12 pinned CPUs and stops threads spinning between tokens (E06). Measure it with `bench/lag-probe.py` on CCD0.

### F12. A speedup that costs no VRAM has not been tried (impact: low-medium)
- [S] n-gram speculation exists in this tip (`common/arg.cpp:4284-4314`) and was proposed in `research/53-decode-speed-levers.md:97`. It was never run.
- [I] It drafts from earlier text, which suits tool-call JSON and file edits, and costs only host RAM. VRAM is the binding limit, so it is the only speculation available at 256K today. MTP's verify path changed the greedy output hash (`speed-push.tsv:56` vs 55), so check tool-call validity, not hashes (E10).

## 2. What I would do in the next 2 hours of GPU time (ordered)
Rules for every point:
- One load per point under `bench/.gpu.lock`, with the fixed guard on.
- Three interleaved reps (A B A B A B) for every decode comparison.
- Two 256-token warm-up requests.
- Log act_freq and idle free VRAM per point.

Steps:
1. **E01, depth curve (25 min).** Run `ornith-chief` exactly as deployed and measure decode at depth 0, 8K, 32K, 64K, 128K and 200K in one growing session, plus a needle test at 128K and 200K.
   - This is the speed Chief actually runs at, and nobody has measured it.
   - It also checks the SYCL Gated DeltaNet long-prompt bug (`research/53-decode-speed-levers.md:67-70`).
2. **E02, buffer census (5 min).** Load with `-lv 4` at ctx 131072 and 262144, then MTP n2 at ctx 65536. No prompts.
   - Confirms or refutes the 1.0 GiB scratch (F1) and the MTP cost (F2).
3. **E03, Vulkan A/B (20 min).** Same flags, vulkan-tip binary, `--device Vulkan0`.
   - Measure decode at 0, 32K and 64K, one 30K prefill, and VRAM.
   - If at least 1.5 GiB stays free, repeat at ub512.
4. **E04 and E05, dev build (15 min).** `GGML_SYCL_FA_FORCE_VEC=1`, then add `GGML_SYCL_FA_MIN_PB=8`. Decode at 0, 32K and 64K.
5. **E06, threads (15 min).** `-t 12 --poll 0` against `-t 16`, interleaved, with `lag-probe.py` pinned to CCD0.
6. **E07, vision time to first token (15 min).** One fixed screenshot, comparing pinned and unpinned encode threads and `--image-max-tokens 1024`.
7. **E08, prompt cache (20 min).** `--checkpoint-min-step 2048 --cache-ram 16384 -lv 4`. Replay a 3-turn Chief session with one compaction-like divergence and record TTFT and the checkpoint log lines.

Outside these 2 hours:
- E11 and E12, sampling on the suite (3 reps each, ~22 min per rep).
- E13, desktop rendering on the iGPU (needs Marcel at the desk).
- E17, the TILE kernel patch.
- E21, extending the eval.

## 3. What you are doing wrong
1. **Tuning for the wrong context length.** The goal is 256K always, and Chief's first prompt is already 7-8K tokens (research/00-plan.md:140), yet decisions use decode measured ~300 tokens in. The depth cost (F1) is larger than any flag tested tonight.
2. **Deciding from single runs.** The activation rule is a 1.05x gain, but run-to-run noise is about +-9%, and the baselines came from a different harness (F8).
3. **Running at ~1 GB of VRAM headroom on purpose, on a card shared with the desktop.** Headroom was measured for the whole card with a guard that failed open (F2, F3). Both resets today came from overcommit.
4. **Carrying conclusions across models and backends.**
   - Gemma's 2.2x MTP gain, SYCL graph -28% and the KV-type depth tables (research/46) were measured on a dense model with sliding-window attention.
   - CUDA and vLLM numbers from other cards are written up as expected gains (`research/53-decode-speed-levers.md:76-77, 93`).
5. **Letting an eval that misses the requirements pick the model.** It has no vision, no long-context and no tool-call-validity items, and n=42 with one run per model (F9).
6. **Sampling against the model card** (F7).
7. **Treating idle unloads and watchdog restarts as free.** Each one costs a full cold prefill (F5).
8. **Changing things while measuring.** Too many agents and edits run on the box during measured runs: research/00-plan.md:138, 149 and 152 record tainted runs and a waiter matching its own process. During this 35-minute review, four files that control runs or production changed.
9. **Trusting a back-of-envelope VRAM estimate.** The MTP estimate of 288 MiB (`bench/bakeoff42/SPEED-PUSH.md:24`) was about 6x too low, and MTP rows were accepted with min_free values taken while the card was idle (`speed-push.tsv:56-58`).

## 4. Numbers I do not trust
| number | where | why |
|---|---|---|
| MTP 66.6 / 63.6 / 60.1 t/s | `speed-push.tsv:56-58` | measured while overcommitted into GTT (the same point later showed free -542 MiB at load, :61); min_free 9,462 etc. are idle samples |
| MiniCPM min_free 2,465 / 2,743 MiB at ncmoe 28 | `speed-push.tsv:12,49` | taken before the first request only; the probe window was blind (`vram-speedpush-mc-base28.csv`) |
| "ub256 decodes 10% faster" | `research/53-decode-speed-levers.md:95` | ub512 was never measured in speed-push; 46.2 t/s comes from another harness (`smoke.py`) |
| or-t12, or-poll0, or-combo "wins" | `speed-push.tsv:36,37,45,46` | inside the 50.5-60.3 spread of identical ub256 runs |
| "Decode ~57 t/s" for Chief | `serve/config.yaml:151` | measured ~300 tokens in; median of 4 runs is ~54; after a 30K prompt it is ~34 |
| "256K works" | research/00-plan.md:165-166 | the allocation works; use beyond 30K depth is unmeasured for Ornith, and there is no needle test |
| desktop VRAM 1.4 GB | BRIEF.md:13 | measured 1,749 MiB at idle at 21:12 (`bench/arc-vram.py`); drifts by several hundred MiB |
| 30/42 vs 25-26/42 | research/00-plan.md:166 | McNemar p ~ 0.13; about 3 items of run-to-run noise |
| mc-t8 35.0 / 7.75 t/s | `speed-push.tsv:19` | a stall in the middle of the request, not a config property (`speedpush-mc-t8.server.log:88-92`, per scout C) |
| "MTP draft cache ~288 MiB" | `SPEED-PUSH.md:24` | measured cost is 1.6-1.8 GB (`speed-push.tsv:61-63`) |
| vision 21.33 s | `swap-ornith-9b.json` | a single sample; the only Ornith vision timing besides `llama-swap-ornith-9b.log:59` |
| arc-vram "total" 11,605 MiB | `bench/arc-vram.py:17` | a constant taken from clinfo, not the driver's real limit; "free" is relative to it |

## 5. Keep these
- Direct-IO model loads (`-lm dio`), the bfq scheduler with ionice, and the per-point flock.
- `gate.sh` refusing GPU jobs after a reset, and memwatch.
- q4_0 KV with the vision encoder on the CPU at 256K, and the 2-stage crop-zoom.
- Hermes' byte-stable prompt prefix (per scout E: `system_prompt.py:489-525`). It is what makes prompt-cache reuse work at all.
