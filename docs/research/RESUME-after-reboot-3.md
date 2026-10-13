# RESUME after reboot 3 (2026-10-13 afternoon)

Reboot cause: kernel oops 13:17:46 (xe_shrinker inside kswapd0), kswapd0 dead, memory psi ~40 %.
bench/gate.sh gpu_reset_unacked now also matches "BUG: kernel|Oops:" (journal is per boot, so a clean
boot clears it automatically; do not create bench/.gpu-reset-ack).

## Order after boot
1. Check: `pgrep -x kswapd0`, `cat /proc/pressure/memory`, `journalctl -k -b | grep -E 'BUG|Oops|GT0'`
   all clean; Kingston C: is NOT mounted any more (it was read-only; remount ro only if YURI needs it).
2. Dispatch BRIEF-45 memory/cache monitor FIRST (Marcel asked; it guards everything else).
3. Re-dispatch, one GPU job at a time, alternating lanes with `lane ds4f|haiku|step`:
   - Chief prompt A/B (research/43, ~/.hermes/cache/scratch/43/ab.sh).
   - Model bake-off Gemma 4 vs Ornith-1.5-9B vs Ministral-3-14B (research/42, bench/bakeoff42/).
   - 256K ladder (research/34, bench/chief256k-chain.sh) after memwatch is live.
   - YURI-OS stage 1 (PROJECTS/YURI-OS/stages/01-store-search/RESUME.md): full-corpus index + proof.
   - GT 1030 STT (voice/gt1030-stt/, state file written by its agent).
4. Each agent wrote its own resume notes before the reboot; read those, not this summary, for
   exact commands.

## Open with Marcel
- British voice pick, MTP on permanently (needs 48K ctx or q4 KV: 995 MiB free at 64K), 256K job
  timeout raise.

## Marcel's directive for long context (before reboot)
Do not cram the full context onto the GPU. Keep the active, needed memory on the GPU and the rest in RAM.
Plan for the 256K lane:
1. Measure the hybrid that matches Gemma 4's layout: weights + sliding-window-layer KV on the GPU,
   global-layer KV in RAM. Check whether llama.cpp (SYCL tip, ik_llama.cpp, other forks) can place KV
   per layer or per tensor; if not, estimate the patch size.
2. Re-measure plain `-nkvo` (all KV in RAM) at 64K/128K/256K for the baseline: earlier decode 4-21 t/s.
3. Research retrieval/sparse attention that reads only the needed KV blocks from RAM per token
   (e.g. InfLLM, RetrievalAttention, MagicPIG, Quest-style block selection) and what runs on llama.cpp.
4. Report speed and needle quality for each against the all-GPU q4_0 ub256 config.
Known physics: full attention reads every KV entry per generated token; RAM (~60-80 GB/s DDR5 dual
channel) and PCIe are slower than B580 VRAM (~456 GB/s). The win comes from not reading cold KV
every token, so the split must follow what the model actually attends to.
