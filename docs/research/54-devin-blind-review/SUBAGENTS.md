# Sub-agents used

All nine ran in parallel on the `scout` profile (`~/.config/devin/agents/scout.md`: model `swe` = SWE-2, tools read/grep/glob/web_search/webfetch only, so none of them could start a process or touch the GPU).
Every brief repeated the hard rules: read-only, no `.env`, no greps over `models/` or `engines/*/build`, cite file:line, tag PROVEN/ASSUMED/UNKNOWN.
I checked the claims I rely on myself: source lines, logs, sysfs, journal, git ancestry, and a GGUF header read.
Where a scout was wrong or overconfident, that is noted under its entry.

General caveat: `LOCAL-AI-LAB/.ignore` lists `models/`, `engines/`, `**/*.gguf` and `**/build/`. Ripgrep-based tools therefore skip those paths silently. One scout (I) concluded the model files were missing; I re-read engine source myself with `rg --no-ignore`.

## A. SYCL flash-attention decode path
**Question:** On the B580 with q4_0 K/V, head dim 256 and GQA 4, which FA kernel does decode use? Does it convert K/V to f16? Does it split the KV range? Does n_kv track used cells? Which env vars exist? What does the dev tree change?

**Answer:**
- Decode with quantized KV on BMG is routed to TILE (`fattn.cpp:267-275`).
- Every TILE launch requests f16 K and V, and `launch_fattn` converts the whole K and V views with `to_fp16` on every call (`fattn-common.hpp:954-1016`). That gives ~2.3 GB of traffic per token at 30K instead of 0.28 GB.
- The scratch lives in the FA node's own allocation (`fattn.cpp:401-461`).
- TILE does split the KV range (parallel_blocks + combine), and n_kv is used cells padded to 256 (`llama-kv-cache.cpp:1280-1294`).
- It listed all `GGML_SYCL_*` env vars; none in the tip forces VEC.
- The dev tree (`engines/llama.cpp-sycl-dev`, e632d64de) adds `GGML_SYCL_FA_FORCE_VEC`, `GGML_SYCL_FA_MIN_PB`, `GGML_SYCL_FA_PB` and `GGML_SYCL_FA_TILE_NCOLS1`. VEC reads q4_0 natively (`fattn-vec.hpp:588-589`).

**My checks and corrections:**
- I verified the routing, the conversion and the reservation lines myself.
- I added that the reservation uses the full cache size (`llama-kv-cache.cpp:2813`), which makes the scratch ~1.0 GiB at 256K.
- I confirmed the dev library actually contains the knobs (strings in `libggml-sycl.so`, built 17:05).
- I tempered its "use FORCE_VEC" fix: PR #26689 (already an ancestor of the tip) moved BMG from VEC to TILE because VEC was slower at 32K.

## B. Vulkan path for Ornith
**Question:** In vulkan-tip, which FA path runs decode with q4_0 KV on Intel? Is q4_0 read natively, and is split_k used? Is GATED_DELTA_NET implemented? Which GGML_VK_* vars exist? Which SYCL-vs-Vulkan comparisons exist on this box? What is the status of issue #27638?

**Answer:**
- Decode uses coopmat2 FA with q4_0 read in the shader. split_k is used for long KV (`ggml-vulkan.cpp:1335-1336, 8094-8104, 8251-8264`). The f16 dequant path is prefill-only.
- GDN is implemented with an Intel-tuned serial shader, but has no chunked prefill path.
- vulkan-tip and sycl-tip are both at 358a420ec.
- Measured comparisons exist only for Qwen3.6 MoE and dense 27B models at depth 0. Vulkan decode was ~85-88% of SYCL, and Vulkan prefill much worse.
- Ornith has never run on Vulkan.
- #27638 is still open and affects prefill only.
- Verdict: one Vulkan slot is worth it as a measurement. It supplied a ready command line.

**My checks:** The scout assumed 16 query heads; my GGUF header read confirms `head_count = 16`, `head_count_kv = 4`. I did not re-verify the Vulkan line numbers myself.

## C. Harness and measurement validity
**Question:** Audit `speed-push.sh`, its TSV and logs:
- variance against the 1.05x rule
- probe design
- whole-card VRAM sampling
- the mc-nc30 paradox
- the Ornith VRAM budget
- priority and threads
- cross-harness baselines

**Answer:**
- Identical or-ub256 runs spread 50.9-60.3 t/s, so the t12/poll0/combo "wins" are inside noise. Only MiniCPM `-t 6` replicated.
- Decode is measured at 40-550 tokens of context; the after-30K figure is a single 128-token sample.
- The sampler wrote -1 for whole probe windows, and -1 could never breach. All MiniCPM and MTP min_free values come from load or teardown samples.
- mc-nc30 dropped 2.9 GB in under 2 s at its first request.
- The server logs at verbosity 3 contain no buffer-size lines.
- The 46.2 t/s baseline comes from `smoke.py`, not speed-push.
- It listed concrete harness fixes.

**My checks and corrections:**
- The scout called the cause of the -1 values unknown. I traced it: `arc-vram.py` prints negative free, and the sampler regex `free=(\d+)` cannot parse a minus sign. This means real overcommit, not process starvation.
- I matched the or-combo-mtp3 samples (-1, 3990, 497) to the 21:10:02 ccs reset in `journalctl -k`.
- The lab confirmed and fixed the same parse bug at 21:14-21:22 (research/00-plan.md:179).

## D. Prompt cache and checkpoints for the hybrid model
**Question:** How does this tip's llama-server reuse prompt state for qwen35 (checkpoints, cache-ram, cache-reuse, slot save)? What do the suite logs show about reuse and re-prefill? What happens on llama-swap ttl unload?

**Answer:**
- Defaults: `--ctx-checkpoints` 32, `--checkpoint-min-step` 8192, `--cache-ram` 8192 MiB (`arg.cpp:1701, 1709, 1719`). Checkpoints are created at user-message boundaries and near the end of the prompt, and store only recurrent state.
- When a new prompt diverges with no usable checkpoint, the server forces full re-processing.
- In the Ornith suite log, appended turns cost 0.19-0.5 s, while divergent turns re-processed 8K-26K tokens (4.3-15.5 s). The RAM cache evicted entries of up to 1.3 GiB.
- ttl 600 kills the server, and all cached state goes with it.
- Recommendations: `--checkpoint-min-step 2048`, a larger `--cache-ram`, a longer ttl, and no `--cache-reuse` on qwen35.

**My checks:** I confirmed the flag lines in `arg.cpp`, and spot-checked log line 59 (image prompt, 20.6 s) and line 93 (8,061 tokens re-processed in 4.3 s).

## E. Chief eval and Hermes config
**Question:**
- How is the 42-task suite scored, and is 30 vs 25-26 significant?
- What does the suite not cover?
- Non-secret Chief config.
- Server-side sampling compared with the Ornith card.
- Does the production llama-swap entry match the scored config?

**Answer:**
- Grading is deterministic (regex and file checks), with one run per model and no statistics. Two Gemma runs differed by 3 items.
- Paired McNemar: Ornith vs Gemma 6:1, p = 0.125; Ornith vs MiniCPM 7:1, p ~ 0.07.
- The suite has no vision, long-context, multi-turn or tool-call-parse items.
- Hermes sends no sampling fields, so `--temp 0 --repeat-penalty 1.05` applies; the Ornith card recommends temp 0.6-1.0, top_k 20, top_p 0.95 and repeat penalty 1.0.
- Hermes keeps the prompt prefix byte-stable.
- The production `ornith-9b` entry (q8_0 KV, vision encoder on GPU, ub1024) differs from the scored config and cannot fit.

**My checks:** The config part went stale during the review. At 21:28 the lab added `ornith-chief` with the measured shape and pointed Chief at it (`serve/config.yaml:149-168`; Chief `config.yaml:20`). The stale `ornith-9b` entry is still present. I did not open Chief's `.env`.

## F. OS, memory and xe driver settings
**Question:**
- Current sysfs/procfs values: THP, swap, zram, governor, B580 clocks, engine timeouts.
- Config files.
- Which tuning recommendations were applied.
- Compute vs compositor scheduling and SYCL queue priority.
- Reset mechanism and upstream fixes.

**Answer:**
- THP is always with defrag defer+madvise; swappiness 150; min_free 1 GiB; zram capped at 12 GiB.
- CPU governor powersave with EPP balance_performance.
- B580: min 1200 / max 2850 MHz; ccs and rcs job_timeout 5000 ms, preempt 640 ms, timeslice 1 ms.
- No `AQ_DRM_DEVICES` in the Hyprland config. ggml-sycl never sets a queue priority.
- Applied: sysctl, bfq, the THP and zram tmpfiles. Not applied: performance profile, clock floor, job_timeout.
- It pointed to commit 3feeb66 for the shrinker oops and ranked a kernel upgrade first.

**My checks and corrections:**
- `journalctl -k -b -1` shows the oops RIP in `xe_pt_zap_ptes`, reached through `__xe_shrinker_walk`, on a kernel built 14 Sep 2026.
- 3feeb66 (I fetched it) fixes `xe_pt_zap_ptes_entry` and dates from June 2026, so it is probably already in 7.2.5. I downgraded "upgrade the kernel" to "check the changelog and report upstream".
- I could not verify the other shrinker-walk fix (628f92b) it cited.
- I read `boot_vga` myself (card0 = 1), which confirms Hyprland renders on the B580.

## G. Outside recipes (web)
**Question:** Recent outside evidence for:
- SYCL vs Vulkan decode on Battlemage
- SYCL FA quantized-KV issues
- MTP on Intel
- Ornith card sampling
- hybrid prompt caching
- B580 xe stability

All with verified URLs.

**Answer:**
- Vulkan is at least as fast as SYCL for decode on a single B580 since Mesa 26.1 (llama.cpp discussion #27777).
- PR #26689 routed quantized-KV decode to TILE on BMG (+64% at 32K).
- MTP on SYCL can be a net loss because of kernel dispatch overhead (issue #23533). Acceptance collapses at certain `-c` values (#23658).
- The Ornith card's sampling settings, with a protoLabs study showing greedy decoding degenerates most at low bit widths.
- Checkpoint flag defaults and related bugs.
- Commits and issues on B580 hangs and engine resets.
- Five recipes.

**My checks and corrections:**
- The scout said it could not check whether d077b4c is in the tip, because `.ignore` hid the source. I checked: it is an ancestor (`git merge-base` rc=0).
- Its recipe `--spec-draft-ctx-size` does not exist in this tip: the draft context is hard-set to the target's n_ctx (`common/speculative.cpp:2617-2618`), and `arg.cpp` has no such flag.
- Its sampler recipe uses presence penalty 1.5 for tool use. I kept the card's precise profile (presence 0) as the second step after simply dropping the repeat penalty.

## H. Research-notes lever audit
**Question:** Which speed levers in the notes were measured vs assumed? Which were dropped on weak evidence? Where do notes contradict data? What is known about decode at depth and the lc46/fa-decode branch? What high-value items never got a GPU slot?

**Answer:**
- A full lever table. Many levers were measured only on Gemma, a dense model with sliding-window attention: SYCL graph -28%, KV type at depth, MTP 2.2x at 8K and 2.8x at 64K, ub sweeps.
- The research/13 and research/18 sweeps (73 configs) were never run.
- Contradictions:
  - The "no nextn head" skip vs the header read. This was a harness bug the lab fixed at 21:05.
  - The `-lm none` claims.
  - Drifting MTP multipliers.
  - The VRAM floor quoted as 750, 900 or 1 GiB in different places.
- Depth data exists only for Gemma (37 -> 20 t/s from d0 to 64K with q4_0 KV; the global-layer FA runs at ~22% of bandwidth) and for Ornith/MiniCPM up to 30K.
- The lc46/fa-decode branch was killed before measurement.
- Never run: the FA kernel measurement, MTP at 64K with the vision encoder on CPU, the 262K depth ladder, the moe-cache sweep, OpenVINO, n-gram speculation.

**My checks:** I spot-checked the Gemma depth numbers against research/46 and research/34:72-75.

## I. Model and quant choices
**Question:**
- Which LLM + vision-encoder pairs are on disk?
- For vision-capable 256K candidates: VRAM fit and decode.
- Bandwidth math for Q4_0, Q3, smaller VLMs and DFlash, with Ornith quants on Hugging Face.
- Vision encoder variants and image encode time.
- Quant quality data.

**Answer:**
- Roofline: Q4_K_M ~81 t/s, Q4_0 ~83, Q3_K_M ~93.
- Verified Hugging Face quants: bartowski Q4_0 5.48 GB and Q3_K_M 4.92 GB, with f16 and bf16 vision encoders; protoLabs with bundled MTP heads; the audreyt DFlash draft is for the DS4 runtime, not stock llama.cpp; NANI quants lack the MTP layer.
- The only Ornith vision timing is ~21 s with the encoder on CPU, against ~2.1 s for Gemma on GPU.
- No quant-quality (KLD) data exists for Ornith.
- Shortlist: Q4_0, Q3_K_M, built-in MTP, protoLabs IQ3_M, and Qwen3-VL-4B as a fast tier.

**My checks and corrections:**
- Its headline "models/llm contains zero .gguf files" is wrong: `ls` shows the Ornith Q4_K_M (5,780,090,816 B), the BF16 vision encoder, and both MiniCPM files. Its glob was filtered by `.ignore`.
- Its claim that ub256 caps Ornith screenshots at 256 tokens is not supported. The cap applies only to non-causal projectors or mixed batches (`server-context.cpp:1286-1299`), and the Ornith ub256 log shows no cap warning, only the Qwen-VL 1024-token advice (`speedpush-or-ub256.server.log:21-22`).
