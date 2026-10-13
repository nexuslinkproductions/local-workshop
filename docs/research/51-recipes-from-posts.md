# 51 - Recipes from @Oluwaphilemon1 posts, and MiniCPM-V-4.7 vs Qwen MoE evidence

Written 2026-10-13. Web only: no downloads, no GPU use, no installs.
Tags: [V] vendor claim. [M] author-measured, self-reported. [I] independent third party. [O] our own notes. [X] my extrapolation, not measured.

## Scope and gaps

- x.com is readable one status page at a time. Post dates come from the tweet ID timestamp (ID >> 22, plus the Twitter epoch).
- Newest FHILY post found: 2026-09-25. None found from 2026-09-26 to 2026-10-13, so the account timeline is incomplete.
- Not repeated (already read): the Qwen3.8-35B-A3B distill on a 3060 (status 2100374395482939401, 2026-09-17) and the Strata 94 t/s run on a 5070.
- No independent head-to-head of MiniCPM-V-4.7-35B-A3B vs Qwen3.6-35B-A3B found on Reddit, HF discussions, GitHub or Chinese sources as of 2026-10-13.

## Section A: recipes to translate to the Arc B580

### A1. Expert-on-CPU prefill knobs (SYCL, B580)

- Source: github.com/davetha/llama-moe-hybrid-tuning (README, BENCHMARKS.md, FINDINGS.md; undated, fetched 2026-10-13). Not from the account, but the closest B580 recipe found.
- Setting: Arc B580 12 GB, SYCL, Qwen3.6-35B-A3B Q4_K (~20 GB), `-ngl 999 -ot exps=CPU`, 256K, EPYC host with 512 GB RAM.
- Claimed [M]: pp4096 83 t/s (default mmap) -> 197 (`--no-mmap`) -> 527 (`-ub/-b 2048`) -> 637 (`-ub/-b 4096`, THP, boost). Decode flat at 37-39 t/s.
- Apply: our SYCL line already runs `-ub 1024` and `-lm none` (research/00-plan.md, 10-13 rows: pp about 480 t/s at 4K, tg 40 t/s at ncmoe30). Confirm `-lm none` maps to no-mmap with `llama-server --help`. Then test `-ub 2048` only, gated by a real large prefill (davetha's warning: the fit estimator lies).
- Expected [X]: prefill +10-30% over our 480 t/s. Decode unchanged. Our notes show Vulkan prefill plateaus near 280 t/s, so this is SYCL-only.

### A2. Memory headroom and batch rules for a MoE on tight VRAM

- Source: x.com/Oluwaphilemon1/status/2100204861979574381 (2026-09-16). Setup: 2x RTX 3090, 128 GB system RAM, Qwen3.8-Flash-Next.
- Claimed [M, relayed third party]: 300-600 t/s prefill, 40-50 t/s decode.
- Knobs named: q8_0 KV, `--n-cpu-moe` (our `-ncmoe`), `-b`/`-ub` at 2048-4096 for prefill, leave several GB of VRAM unused, bind NUMA, Linux preferred. The post also names `--moe-stream`; I could not confirm that flag upstream, so do not copy it.
- Apply: the transferable part is the rule, not the numbers. Keep our fit margin (ncmoe30 leaves 1890 MiB; the rule is >= 1 GiB free). Try q8_0 KV only if a fit test shows it frees room for a lower ncmoe.
- Expected [X]: no new decode gain beyond A1 and A3.

### A3. Expert LRU cache in VRAM (upstream llama.cpp, not the account)

- Source: llama.cpp PR 29887, merged as PR 30112 (commit c811cb8, 2026-10-08). Flag per PR text: `--moe-cache-mib N`. Confirm in `llama-server --help` on our tip 358a420ec.
- Claimed [I]: YouTube reviewer relaying llama.cpp's benchmark, Qwen3.8-Flash-Next Q4_0 (~94 GB): RTX 4090 25 -> 39.4 t/s (6.4 GB cache) -> 40.7; RTX 5090 30.8 -> 54.5 (6.4 GB) -> 67.8 (18.6 GB). Source: youtube.com/watch?v=hJGryeKoCEg (undated, after 2026-10-08).
- Independent test [I]: Reddit r/LocalLLaMA thread 1x03xkc (9070 XT, Vulkan, gemma4 26B-A4B): cache 0 gives 59.3 t/s decode and 870 pp; 8000 MiB gives 76.9 t/s and 409 pp; 12000 MiB drops to 42.6 t/s. The cache has a sweet spot. Too big hurts.
- Apply: sweep 500-2000 MiB on the Qwen3.6 SYCL line. Our notes already queue "moe-cache" (research/00-plan.md, 10-13 row). Commit titles say HIP/CUDA; Vulkan reportedly works; SYCL is unverified.
- Expected [X]: +10-30% decode if SYCL works and the hit rate is high. Prefill may fall.

### A4. MTP drafter on the dense candidate (Gemma 4 12B), not on the MoE

- Source: huggingface.co/srmiles/gemma-4-12B-it-assistant-GGUF (undated; measured on Arc Pro B60 24 GB, llama.cpp SYCL b10215+).
- Command as posted [M]: `llama-server -m gemma-4-12B_q4_0-it.gguf --model-draft gemma-4-12B-it-assistant-official.bf16.gguf --spec-type draft-mtp --spec-draft-n-max 3 -ngl 99 -c 8192 -fa on -ub 2048 -b 2048 --jinja --reasoning off`
- Claimed [M]: decode 70.4 t/s, draft acceptance 69.7%, prefill 1053 t/s at 2K, 8.5 GiB VRAM (target plus BF16 drafter). Posted +257% decode vs no drafter on the same card.
- Apply: Gemma 4 12B is on our candidate list. The 8.5 GiB total suggests the pair fits in 12 GB, but check the drafter size first.
- Baselines [X]: a TrendPulse blog (undated, unverified) reports Gemma 4 12B Q4_K_M at ~41 t/s on B580. The B60 numbers imply ~27 t/s without a drafter. Expect 40-60 t/s with the drafter on B580.
- Warning [M]: davetha measured `draft-mtp` at -19% decode on Qwen3.6-35B-A3B with experts on CPU (FINDINGS.md). MTP is not a free win on a CPU-expert MoE.

### A5. Ternary 27B that fits fully in 12 GB (not translated: fork-locked)

- Source: x.com/Oluwaphilemon1/status/2101827489236467745 (2026-09-21): RTX 3060 12 GB, PrismML 5.9 GB ternary Qwen3.8-27B, 262K, 13-26 t/s, PrismML llama.cpp fork.
- Also x.com/Oluwaphilemon1/status/2103282518103343252 (2026-09-25): Bonsai 2 27B on a 3060, Hermes agent, 125K, ~22-26 t/s average over a 5-hour build. No flags posted.
- Verdict: not translatable today. It needs the PrismML fork and no SYCL path is documented. Test only if Marcel wants a fork.

### A6. Not translatable (skipped)

- status 2096794721288847676 (2026-09-07, older than the window): Qwen3.8-27B UD-Q3_K_XL on RTX 5070 Ti 16 GB with beellama.cpp, Kvarn3 KV and MTP n=2 at 96K, up to 75 t/s. Fork-specific. Its general lesson (CPU offload of a dense model costs more than a lower quant) does not apply to our MoE line.
- status 2100409183115821394 (2026-09-17): Qwen3.8-27B UD-Q4_K_XL on a 4090, 40.7 t/s decode. No flags posted.
- status 2099810586917806186 (2026-09-15): Halogen engine on Strix Halo. Different hardware and runtime.

## Section B: MiniCPM-V-4.7-35B-A3B vs Qwen MoE evidence

| # | Claim | Source (date) | Type | What it means for us |
|---|---|---|---|---|
| 1 | Instruct mode: higher overall score in less inference time than Qwen3.6 35B-A3B. "First MoE in the MiniCPM-V series" | huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B (page updated 2026-10-13) | V | Only claim naming a Qwen MoE. No per-benchmark table in the text I could read (charts are images). |
| 2 | 13+ tok/s on iPhone 17 Pro Max with ~3 GB; LES expert prefetch and DSpark | same HF card | V | LES lives in the tc-mb/llama.cpp-omni fork, not mainline. Phone storage streaming does not transfer to a PC. |
| 3 | OCR bench 91.2 vs 83.9; OmniDocBench 94 vs ~80; chart 75.6 vs 70.7 | youtube.com/watch?v=JYTXQ7oFTLA (undated, Oct 2026), relaying OpenBMB | V (relayed) | Compared against Qwen 3.8 27B, not the Qwen MoE. Vision and OCR only. |
| 4 | 11-task personal test: MiniCPM 35B-A3B ~9.5/11, Qwen3.8 Flash-Next ~10/11, MiniCPM 4.7 1B ~8/11, 4.6 ~7/11. Median reply ~3.5 s vs ~7.5 s | same video (single reviewer) | I (n=1) | Closest independent data point. Half a point behind a stronger Qwen, and faster. Not the Qwen3.6 MoE we run. |
| 5 | Gauge read (true 73 PSI): MiniCPM 35B said 70, Qwen never answered in 44 s. Dot count: only Qwen exact | same video | I (n=1) | Shows a speed vs accuracy trade. Not a ranking. |
| 6 | Quant vs BF16 (2x H100, held-out text). Q4_K_M 21.2 GB KL 0.0446, top-1 92.2%. AD-Q4_K-IQ4_XS 20.1 GB KL 0.0197, 94.9%. AD-Q5_K-Q4_K 22.1 GB KL 0.0150, 95.5%. AD-IQ3_S-IQ3_XXS 15.5 GB KL 0.0638, 90.8%. AD-IQ2_XS-IQ2_XXS 11.3 GB KL 0.219, 83.2% | huggingface.co/AtomicChat/MiniCPM-V-4.7-35B-A3B-GGUF (updated 2026-10-12) | M (quant vendor, raw logs published) | Best measured quants found. Their 12 GB row assumes full GPU residency. With experts on CPU, the 12 GB limit moves to attention plus KV, so an IQ4-class file may fit [X]. Verify with a fit test. |
| 7 | No Qwen3.6-35B KL table with the same reference and text found | searched 2026-10-13 | n/a | Do not compare KL numbers across reference sets. |
| 8 | Speed on our box: MiniCPM 35B not measured. Qwen3.6 35B on SYCL: ~40 t/s decode at ncmoe30 | research/00-plan.md (10-13 rows) | O | 40 t/s is the bar. The 45-65 t/s estimate in 50-candidate-watch is unmeasured [X]. |
| 9 | Qwen3.6-35B on B580 SYCL: tg 37-38 t/s, pp 480-637 t/s with experts on CPU | davetha repo (undated) | M | Consistent with our 40 t/s. |
| 10 | draft-mtp on Qwen3.6-35B-A3B: about -19% decode on B580 | davetha FINDINGS.md (undated) | M | Negative on our exact hardware and layout. |
| 11 | MTP on a Qwen MoE with GPU-resident weights: ~1.4x decode (Strix Halo, PR 22673) | llmrequirements.com (2026-07-01) | I | Gains depend on expert placement. Not our layout. |
| 12 | DSpark draft exists for MiniCPM 4.7 35B; the card says it runs in the llama.cpp-omni fork | HF card (2026-10-13) | V | Conflict: llama.cpp master docs/speculative.md lists `draft-dspark`, but the Jetson AI Lab tutorial (undated) says llama.cpp does not support DSpark yet. Treat mainline DSpark as unverified. |
| 13 | Needs llama.cpp at or after commit 69f201a (PR 29416, merged 2026-10-10). Older builds run text only and misplace image tokens. Tested on b11574 | HF AtomicChat card; github.com/ggml-org/llama.cpp/pull/29416 | M | Our tip already carries b11551 per research/50. Verify with `--help` and a vision smoke test. |
| 14 | With `--jinja`, answers start in thinking mode. Disable per request with `chat_template_kwargs` `enable_thinking: false` | HF AtomicChat card | M | Matters for Chief tool-call latency. |
| 15 | Upload on 2026-10-06 had no README or licence. Card now says Apache-2.0 | orcarouter.ai article (undated, about a week after upload); HF card (2026-10-13) | I | Licence gap closed on the card. Read the card before shipping. |
| 16 | Stack overflow in the MiniCPM-V position-bucket code via a crafted mmproj (pre-4.7 code path) | github.com/ggml-org/llama.cpp/issues/27166 (2026-08-15) | I | Load only mmproj files from trusted sources. The 4.7 path was not checked. |
| 17 | transformers CI failure for minicpmv4_7 | github.com/huggingface/transformers/issues/49492 (2026-10-10) | I | A hub repo name problem in CI, not a model bug. Ignore for us. |

Verdict: the "better and more efficient than Qwen MoE" line in the feed is vendor-led. The only independent test found is one reviewer, 11 tasks, against Qwen3.8 Flash-Next (not the Qwen3.6 MoE we run). Its clearest edge is speed per answer and visual-token efficiency, not text quality. A second video (zFJiwyhDFrA) claims a local run, but I only read its intro. Nobody found tested MiniCPM-V-4.7 on text-only agent or tool-call work, which is what the Chief suite measures. Promising, unproven for our workload.

## Section C: three experiments for the queue

### C1. MiniCPM-V-4.7-35B-A3B vs Qwen3.6-35B-A3B on the Chief suite

- Setup: same Q4-class quant for both (both >= 3-bit, per Marcel's rule), same SYCL line (ncmoe30, `-ub 1024`), same prompts. MiniCPM only on llama.cpp >= 69f201a, with `enable_thinking` false per request for the suite.
- Measure: Chief suite score (Ornith-1.5-9B is 29/42), tool-call JSON validity, decode and prefill at 4K, plus a 20-image OCR and chart set with the F16 mmproj.
- Gate: >= 30/42 at >= 35 t/s decode. Otherwise drop MiniCPM from the MoE tier.
- Run under `bench/.gpu.lock` with no bot launches (rule in research/00-plan.md).

### C2. Expert cache sweep on the Qwen3.6 SYCL line (A3)

- First confirm `--moe-cache-mib` exists on tip 358a420ec (`llama-server --help | grep -i moe-cache`). If absent, drop C2 and note that SYCL lacks it.
- Sweep 0, 500, 1000, 1500, 2000 MiB at ncmoe30. Record tg at 0 and 8K depth, pp at 4K, and the fit margin.
- Gate: +15% decode with >= 1 GiB free and identical greedy output on 5 prompts.

### C3. Gemma 4 12B with the MTP drafter on B580 SYCL (A4)

- Once the lab run is approved, fetch the srmiles BF16 assistant drafter (check size and licence first).
- Compare no drafter vs `--spec-type draft-mtp` at `--spec-draft-n-max` 2 and 3, with `-ub 2048 -b 2048`, on the same 10 prompts at temperature 0.
- Gate: >= 1.4x decode and byte-identical greedy output on all 10 prompts. Any drift means reject the drafter.

## Section D: not verified

- Full account timeline (see Scope). The FHILY posts above are the ones the index surfaced.
- `--moe-stream` and any SYCL support for `--moe-cache-mib` (only the PR text and Vulkan reports were read).
- draft-mtp for Gemma 4 12B on B580 (only B60 numbers exist).
- Any B580 number for MiniCPM-V-4.7 (none exists in what I found).
- MiniCPM's per-benchmark table (the vendor chart images were not read).
