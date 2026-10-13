# BRIEF-46: sustainable fast tokens at every context length (Chief, Gemma 4 12B, B580)

Goal (Marcel): fast, steady decode and prefill from 4K to ~256K. Do NOT cram the full context onto the GPU.
Keep active, needed memory on the GPU and the rest in RAM. Read first: research/34-chief-256k.md
(WS1 VRAM table, ladder results), research/33-kernel-work.md, research/26 (MTP, thinking budget),
RESUME-after-reboot-3.md (directive section), and bench/lc.py, bench/chief256k-chain.sh, bench/needle.py.

## Known facts (measured today)
- All-GPU 262144 fits only with q4_0 KV at ub256 (min free ~1.05-1.22 GiB). Prefill depends on -ub
  (287/505/768 t/s at ub256/512/1024). Decode 31 t/s at 3K, 25 at 32K, 19.6 at 64K. MTP n3 = 2.25x
  but does not fit at 262144 (draft ctx sized to n_ctx).
- Plain -nkvo (all KV in RAM) earlier: decode 4-21 t/s.
- Gemma 4 mixes sliding-window layers (small local KV) with a few global layers (full-context KV).

## Workstreams
A. Hybrid placement (the core idea): weights + SWA-layer KV + compute buffers on GPU, global-layer KV
   (and only that) in host RAM. Find out if llama.cpp SYCL tip (engines/llama.cpp-sycl-tip, 358a420ec),
   ik_llama.cpp or another fork can place KV per layer or per tensor (look for per-layer KV offload,
   --override-tensor for KV, kv_unified/kv split code). If not possible, size the patch (files, LOC) and
   prototype it in engines/llama.cpp-sycl-dev on a branch. Measure decode/prefill at 8K-256K.
B. Read only what is needed: sparse / retrieval attention that pulls only relevant KV blocks per token
   (Quest-style block selection, InfLLM, RetrievalAttention, MagicPIG, any llama.cpp PR or fork). Report
   what exists on llama.cpp, quality cost, effort. Research first; prototype only if A stalls.
C. Keep MTP at long context: draft context smaller than target (e.g. draft ctx 8K-16K) if the code allows.
D. Cheap wins on the all-GPU baseline: -ub per context tier, q5_1 K / q4_0 V, --no-mmproj-offload,
   prompt-cache reuse across turns (-cram), and Chief compaction thresholds per tier.
Deliverable: a tiered serving plan (e.g. 64K fast id, 128K, 256K long id) with measured decode/prefill
at depth, needle 5/5 quality, VRAM floor >= 1 GiB, and the config diff ready for Marcel (not applied).

## Hard rules
- One GPU/CPU test at a time: `flock -x -w 7200 bench/.gpu.lock` (builds `flock -s`, -j 6 under jobcap).
- GPU jobs only after `systemctl --user is-active memwatch.timer` says active (cache monitor, BRIEF-45,
  is being built now). bench/gate.sh must pass; never --force; never touch bench/.gpu-reset-ack.
- Stop on any xe reset/oops, DEVICE_LOST, free VRAM < 1 GiB, psi > 1.0. Watchdog limits stay strict.
- Proof = measured numbers from logs you cite. Write research/46-long-context-speed.md incrementally.
- Fleet: you lead. Alternate child lanes with `lane ds4f|haiku|step` (run it right before each
  delegate_task call, restore `lane ds4f` at the end). Devin swe-2 is available as a free builder for
  code patches: `cd <worktree> && CAP=10G ~/.local/bin/jobcap devin -p --model swe-2-max
  --permission-mode dangerous --prompt-file <card.md>`; block on it (process_manage wait) until it exits,
  and verify its work with a different model. Builder never grades itself.
