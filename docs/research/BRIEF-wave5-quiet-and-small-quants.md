# Brief: wave 5, quiet mode + small quants (handoff, 2026-10-13 ~08:40)

You continue a local-LLM test campaign on Marcel's desktop PC. The previous runner was
stopped mid-task (lane switch, not a failure). Pick up from its files; do not redo work.

## Box
Ryzen 9 7900X (CCD0 = CPUs 0-5,12-17, CCD1 = 6-11,18-23), 61 GiB RAM, Intel Arc B580 12 GB
(it ALSO drives Marcel's 3 monitors). Workspace: /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB.
Read first: research/10-test-matrix.md (sections 2.4-2.6, GPU reset), research/00-plan.md
(last 10 decision-log rows), research/21-small-quants.md (when it exists).

## TOP RULE: never disturb Marcel's desktop
His PC froze (cursor/typing) during earlier tests. Cause, proven: memory/IO stalls
(PSI memory full 50 s, io full 170 s since boot; kernel page allocation failure 07:13:59)
from loading 20-37 GB GGUFs through the page cache with `-lm none`, pushing the desktop
into zram. Root tweaks are applied (zram mem_limit 12G, THP defrag defer+madvise;
swappiness stays 150). Every model run MUST:
1. go through bench/watchdog.sh (kills the job if PSI memory/io `full avg10` > 1.0 or
   MemAvailable < 6 GiB, writes an ABORT-LAG row). It was written but NOT yet proven:
   prove it first with a FAKE load (python allocating RAM inside a jobcap scope, low
   thresholds), no model.
2. pass a pre-load guard: refuse if MemAvailable < (model bytes kept in RAM + 8 GiB);
   write a SKIPPED-MEM row.
3. load with `-lm dio` (fallback mmap only if dio errors); jobcap CAP = RAM need + 3G.
4. run quiet: `CPUS=6-11,18-23 CPUW=20` via ~/.local/bin/jobcap (taskset pin + CPUWeight;
   verified working). bench/quiet-run.sh + bench/lag-probe.py exist for the -t A/B.
5. record PSI `full total` deltas (memory, io) and MemAvailable min for every test.
Also: one test at a time (`flock -x bench/.gpu.lock`); bench/gate.sh refuses while ARC
Raiders runs (never --force); UI-Venus (qwen3vl_moe) NEVER on SYCL (reset the GPU twice);
after each test grep `journalctl -k --since <start>` for 'GT0: reset'/'DEVICE_LOST' ->
GPU-RESET row, stop. Never leave a llama-server running.

## Order
1. Prove watchdog (fake load). 2. Finish grounding scoring fix: bench/grounding-score.py
   exists, selftest passes; wire it into grounding-test.sh, re-score the 08:25/08:30 Qwen
   crop rows from the audit dumps (~/.hermes/cache/scratch/gt-dump-*.tsv) with no model
   load, mark the 08:34:26 UI-Venus quadrant row VOID (orchestrator killed that server).
3. Quiet A/B on the Qwen3.6 daily driver: -lm dio vs none, then threads A (-t16 unpinned)
   / B (CCD1, -t12, CPUW 20) / C (CCD1 physical 6-11, -t6, CPUW 20): pp4096, tg128, PSI
   deltas, lag-probe p99. Winner (< 5% loss, PSI near idle) becomes default in all bench
   configs and serve/config.yaml.
4. Small quants (files listed verified in research/21-small-quants.md): per file RAM use,
   PSI, pp4096, tg128, screenshot prefill, tool-call smoke, grounding synthetic + live
   desktop (no crop, one convention); sweep --n-cpu-moe down under the fit rule (>= 1.2 GiB
   VRAM free after a 4K prompt). Compare to the bigger sibling.
5. Then the old queue: oneAPI 2026.1 engine vs 2026.0, Qwen3.6 MTP decode.

## Output
Append rows to bench/results-matrix.tsv; update research/10-test-matrix.md ('Quiet mode'
and 'Small quants' sections) after each step. Write files incrementally.

Self-check (mandatory): re-read every file you wrote, rerun every check, and list each
acceptance item as PASS or FAIL with evidence. Confirm no llama-server is running at the end.
